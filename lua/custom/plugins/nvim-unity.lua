---@mod nvim_unity_roslyn_ls
---@brief Modern Neovim 0.11+ LSP configuration for Unity + Roslyn LS.

local M = {}

--------------------------------------------------------------------------------
-- NEOVIM UNITY GLOBALS (module-scoped, no global pollution)
--------------------------------------------------------------------------------

---@class UnityRoslynConfig
---@field curr_unity_project_root_dir string?
---@field user_supplied_project_root_dir string?
---@field benchmark_roslyn_ls boolean
---@field analyzer_diagnostic_scope "openFiles"|"fullSolution"|"none"
---@field compiler_diagnostic_scope "openFiles"|"fullSolution"|"none"

---@type UnityRoslynConfig
M.config = {
  curr_unity_project_root_dir = nil,
  user_supplied_project_root_dir = nil,
  benchmark_roslyn_ls = false,
  analyzer_diagnostic_scope = 'openFiles',
  compiler_diagnostic_scope = 'openFiles',
}

--------------------------------------------------------------------------------
-- ROSLYN LS BENCHMARKING
--------------------------------------------------------------------------------

---@type integer? Start time in seconds (uv.gettimeofday precision)
local benchmark_start_time

local function log_benchmarking_settings()
  local settings = {
    os = vim.uv.os_uname().sysname,
    dotnet_analyzer_diagnostics_scope = M.config.analyzer_diagnostic_scope,
    dotnet_compiler_diagnostics_scope = M.config.compiler_diagnostic_scope,
  }

  local indent = vim.bo.expandtab and (' '):rep(vim.o.shiftwidth) or '\t'
  local msg = '[benchmark] started textDocument/diagnostic with settings: ' .. vim.json.encode(settings, { indent = indent })

  vim.notify(msg, vim.log.levels.INFO)
  vim.lsp.log.error(msg) -- Error level used to bypass log filtering
end

local function mark_benchmark_start()
  if not M.config.benchmark_roslyn_ls then return end

  local secs, microsecs = vim.uv.gettimeofday()
  benchmark_start_time = secs + microsecs * 0.001 * 0.001
  log_benchmarking_settings()
end

---@param bufnr integer
---@param elapsed_seconds number
local function notify_benchmark_done(bufnr, elapsed_seconds)
  local msg = string.format('[benchmark] textDocument/diagnostic for bufnr %d done in: %.3fs', bufnr, elapsed_seconds)
  vim.notify(msg, vim.log.levels.INFO)
  vim.lsp.log.error(msg)
end

--------------------------------------------------------------------------------
-- ROSLYN LS HANDLERS (exported for testability)
--------------------------------------------------------------------------------

---@type table<string, lsp.Handler>
M.roslyn_handlers = {}

--- Called when Roslyn finishes project initialization. Requests diagnostics
--- for all buffers currently attached to the client.
---
--- so LuaLS sees distinct names and stops warning about duplicates.
---@param _err lsp.ResponseError?
---@param _result any
---@param ctx lsp.HandlerContext
M.roslyn_handlers['workspace/projectInitializationComplete'] = function(_err, _result, ctx)
  vim.notify('Roslyn project initialization complete', vim.log.levels.INFO)

  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if not client then return end

  -- Equivalent, non-deprecated: read the client's own attached_buffers table.
  local buffers = vim.tbl_keys(client.attached_buffers)
  local method = vim.lsp.protocol.Methods.textDocument_diagnostic

  if M.config.benchmark_roslyn_ls then
    local msg = string.format('[benchmark] textDocument/diagnostics request completion time for %d buffers', #buffers)
    vim.notify(msg, vim.log.levels.INFO)
    vim.lsp.log.error(msg)
  end

  for _, buf in ipairs(buffers) do
    ---@type lsp.Handler?
    local handler
    if M.config.benchmark_roslyn_ls then
      handler = function(err, res, hctx)
        local default = client.handlers[method] or vim.lsp.handlers[method]
        if default then default(err, res, hctx) end

        local secs, microsecs = vim.uv.gettimeofday()
        local elapsed = (secs + microsecs * 0.001 * 0.001) - (benchmark_start_time or 0)
        notify_benchmark_done(hctx.bufnr, elapsed)
      end
    end

    local ok = client:request(method, { textDocument = vim.lsp.util.make_text_document_params(buf) }, handler, buf)

    if not ok then vim.notify(('[C# LS] failed to request diagnostics for buffer: %s'):format(vim.api.nvim_buf_get_name(buf)), vim.log.levels.ERROR) end
  end
end

--- Handles the (legacy) project-needs-restore notification by asking Roslyn
--- to run `dotnet restore`.
---
--- with the handler above.
---@param _err lsp.ResponseError?
---@param result any
---@param ctx lsp.HandlerContext
---@return vim.NIL
M.roslyn_handlers['workspace/_roslyn_projectNeedsRestore'] = function(_err, result, ctx)
  local client = vim.lsp.get_client_by_id(ctx.client_id)
  if not client then return vim.NIL end

  -- the LSP spec, so LuaLS rejects it against the typed union in client:request.
  ---@diagnostic disable-next-line: param-type-mismatch
  client:request('workspace/_roslyn_restore', result, function(err, response)
    if err then
      vim.notify(err.message, vim.log.levels.ERROR)
      vim.lsp.log.error(err.message)
    end

    local has_errors = false
    if response then
      for _, item in ipairs(response) do
        if string.find(item.message, 'error%s*MSB%d%d%d%d') then
          vim.lsp.log.warn(item.message)
          vim.notify(item.message, vim.log.levels.WARN)
          has_errors = true
        end
      end
    end

    if not has_errors then
      vim.notify('dotnet restore completed successfully', vim.log.levels.INFO)
    else
      vim.notify('dotnet restore completed with errors - see LSP log', vim.log.levels.WARN)
    end
  end)

  return vim.NIL
end

--- Warns the user about unresolved dependencies.
---@return vim.NIL
M.roslyn_handlers['workspace/_roslyn_projectHasUnresolvedDependencies'] = function()
  vim.notify('Detected missing dependencies. Run `dotnet restore` command.', vim.log.levels.ERROR)
  return vim.NIL
end

--- Informs the user that Razor is not supported.
M.roslyn_handlers['razor/provideDynamicFileInfo'] = function()
  vim.notify('Razor is not supported.\nPlease use https://github.com/tris203/rzls.nvim', vim.log.levels.WARN)
end

--------------------------------------------------------------------------------
-- PROJECT ROOT DISCOVERY (split into testable helpers)
--------------------------------------------------------------------------------

--- Finds the Unity project root by walking parent directories looking for an
--- `Assets` folder.
---@param bufnr integer
---@return string? root_dir
local function find_unity_root(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  for dir in vim.fs.parents(bufname) do
    if vim.fn.isdirectory(vim.fs.joinpath(dir, 'Assets')) == 1 then return dir end
  end
  return nil
end

--- Resolves the root directory for the given buffer, handling Unity projects,
--- user-supplied roots, and falling back to single-file mode.
---@param bufnr integer
---@param on_dir fun(root_dir?: string)
local function project_root_dir_discovery(bufnr, on_dir)
  -- 1. User-supplied root takes absolute priority
  if M.config.user_supplied_project_root_dir then
    vim.notify('[C# LS] using user-supplied Unity project root dir: ' .. M.config.user_supplied_project_root_dir, vim.log.levels.INFO)
    on_dir(M.config.user_supplied_project_root_dir)
    return
  end

  -- 2. Unity project detection
  local unity_root = find_unity_root(bufnr)
  if unity_root then
    local current = M.config.curr_unity_project_root_dir
    if current then
      if current == unity_root then
        on_dir(unity_root)
      else
        vim.notify(
          ('[C# LS] C# file belongs to a different Unity project (%s) than the active one (%s). LS disabled for this buffer.'):format(unity_root, current),
          vim.log.levels.WARN
        )
      end
      return
    end

    M.config.curr_unity_project_root_dir = unity_root
    on_dir(unity_root)
    return
  end

  -- 3. Non-Unity: look for .sln[x] or .csproj
  local sln_root = vim.fs.root(bufnr, function(name, _) return name:match '%.sln[x]?$' ~= nil end)

  local project_root = sln_root or vim.fs.root(bufnr, function(name, _) return name:match '%.csproj$' ~= nil end)

  if project_root then
    on_dir(project_root)
    return
  end

  -- 4. Single-file mode
  on_dir(vim.api.nvim_buf_get_name(bufnr))
  vim.notify('[C# LSP] failed to find root directory - LS is running in single-file mode.', vim.log.levels.WARN)
end

--------------------------------------------------------------------------------
-- LSP SETUP (called once from init.lua)
--------------------------------------------------------------------------------

---@type lsp.ClientCapabilities
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.textDocument.diagnostic.dynamicRegistration = true

local log_level_map = {
  [vim.log.levels.OFF] = 'None',
  [vim.log.levels.TRACE] = 'Trace',
  [vim.log.levels.DEBUG] = 'Debug',
  [vim.log.levels.INFO] = 'Information',
  [vim.log.levels.WARN] = 'Warning',
  [vim.log.levels.ERROR] = 'Error',
}

---@type vim.lsp.Config
local roslyn_ls_config = {
  name = 'roslyn_ls',
  offset_encoding = 'utf-8',
  cmd = {
    'roslyn-language-server',
    '--logLevel=' .. (log_level_map[vim.lsp.log.get_level()] or 'Information'),
    -- Replacement: `vim.lsp.log.get_filename()`.
    '--extensionLogDirectory=' .. vim.fs.dirname(vim.lsp.log.get_filename()),
    '--stdio',
  },
  filetypes = { 'cs' },
  handlers = M.roslyn_handlers,
  root_dir = project_root_dir_discovery,
  capabilities = capabilities,
  settings = {
    ['csharp|background_analysis'] = {
      dotnet_analyzer_diagnostics_scope = M.config.analyzer_diagnostic_scope,
      dotnet_compiler_diagnostics_scope = M.config.compiler_diagnostic_scope,
    },
    ['csharp|inlay_hints'] = {
      dotnet_enable_inlay_hints_for_parameters = true,
      dotnet_enable_inlay_hints_for_literal_parameters = true,
      dotnet_enable_inlay_hints_for_indexer_parameters = true,
      dotnet_enable_inlay_hints_for_object_creation_parameters = true,
      dotnet_enable_inlay_hints_for_other_parameters = true,
      dotnet_suppress_inlay_hints_for_parameters_that_differ_only_by_suffix = true,
      dotnet_suppress_inlay_hints_for_parameters_that_match_method_intent = true,
      dotnet_suppress_inlay_hints_for_parameters_that_match_argument_name = true,
      csharp_enable_inlay_hints_for_types = true,
      csharp_enable_inlay_hints_for_implicit_variable_types = true,
      csharp_enable_inlay_hints_for_lambda_parameter_types = true,
      csharp_enable_inlay_hints_for_implicit_object_creation = true,
      csharp_enable_inlay_hints_for_collection_expressions = true,
    },
    ['csharp|symbol_search'] = {
      dotnet_search_reference_assemblies = true,
    },
    ['csharp|completion'] = {
      dotnet_show_name_completion_suggestions = true,
      dotnet_provide_regex_completions = true,
      dotnet_show_completion_items_from_unimported_namespaces = false,
      dotnet_trigger_completion_in_argument_lists = true,
    },
    ['csharp|code_lens'] = {
      dotnet_enable_references_code_lens = true,
      dotnet_enable_tests_code_lens = true,
    },
    ['csharp|projects'] = {
      dotnet_binary_log_path = nil,
      dotnet_enable_automatic_restore = true,
      dotnet_enable_file_based_programs = true,
      dotnet_enable_file_based_programs_when_ambiguous = true,
    },
    ['csharp|navigation'] = {
      dotnet_navigate_to_decompiled_sources = true,
      dotnet_navigate_to_source_link_and_embedded_sources = true,
    },
    ['csharp|highlighting'] = {
      dotnet_highlight_related_json_components = true,
      dotnet_highlight_related_regex_components = true,
    },
  },
  on_init = {
    function(client)
      local root_dir = client.config.root_dir
      if not root_dir then
        vim.notify('[C# LSP] Roslyn LS initialized without a root directory.', vim.log.levels.WARN)
        return
      end

      mark_benchmark_start()

      -- Prefer solution files
      for entry, kind in vim.fs.dir(root_dir) do
        if kind == 'file' and (vim.endswith(entry, '.sln') or vim.endswith(entry, '.slnx')) then
          local sln_path = vim.fs.joinpath(root_dir, entry)
          vim.notify('Initializing: solution ' .. sln_path, vim.log.levels.INFO)
          ---@diagnostic disable-next-line: param-type-mismatch
          client:notify('solution/open', { solution = vim.uri_from_fname(sln_path) })
          return
        end
      end

      -- Fall back to project files
      local projects = {}
      for entry, kind in vim.fs.dir(root_dir) do
        if kind == 'file' and vim.endswith(entry, '.csproj') then table.insert(projects, vim.fs.joinpath(root_dir, entry)) end
      end

      if #projects > 0 then
        vim.notify('Initializing: projects', vim.log.levels.INFO)
        ---@diagnostic disable-next-line: param-type-mismatch
        client:notify('project/open', {
          projects = vim.tbl_map(vim.uri_from_fname, projects),
        })
      else
        vim.notify('[C# LSP] no solution/.csproj files were found', vim.log.levels.ERROR)
      end
    end,
  },
  detached = false, -- Ensure the LS is killed if Neovim crashes
}

-- Register and enable
vim.lsp.config('roslyn_ls', roslyn_ls_config)
vim.lsp.enable 'roslyn_ls'

return M
