-- You can add your own plugins here or in other files in this directory!
--  I promise not to create any merge conflicts in this directory :)
--
-- See the kickstart.nvim README for more information

-- Iterate over all Lua files in the plugins directory and load them
local plugins_dir = vim.fs.joinpath(vim.fn.stdpath 'config', 'lua', 'custom', 'plugins')
for file_name, type in vim.fs.dir(plugins_dir) do
  if type == 'file' and file_name:match '%.lua$' and file_name ~= 'init.lua' then
    local module = file_name:gsub('%.lua$', '')
    require('custom.plugins.' .. module)
  end
end
---
---@param repo string
---@return string
local function gh(repo) return 'https://github.com/' .. repo end

vim.keymap.set('n', '<leader>cd', ':cd %:p:h<CR>', { desc = 'cd to current buffer' })

-- Git integration
vim.pack.add { gh 'tpope/vim-fugitive' }

-- Terminal
do
  vim.pack.add { gh 'akinsho/toggleterm.nvim' }
  require('toggleterm').setup {}
  vim.keymap.set('n', '<leader>tt', '<cmd>ToggleTerm<CR>', { desc = '[T]oggle [T]erminal' })
end

-- File navigation
do
  vim.pack.add { gh 'stevearc/oil.nvim' }
  require('oil').setup {}
  vim.keymap.set('n', '-', '<CMD>Oil<CR>', { desc = 'Open parent directory' })
end

-- Package cleaning
do
  vim.api.nvim_create_user_command('VimPackClean', function()
    local plugins = vim.pack.get()
    local inactive_names = {}

    for _, pkg in ipairs(plugins) do
      if not pkg.active then table.insert(inactive_names, pkg.spec.name) end
    end

    if #inactive_names > 0 then
      print('Cleaning inactive packages: ' .. table.concat(inactive_names, ', '))
      vim.pack.del(inactive_names)
    else
      print 'No inactive packages to clean.'
    end
  end, {})
end

-- Godot
do
  vim.pack.add {
    'https://github.com/Mathijs-Bakker/godotdev.nvim',
    'https://github.com/mfussenegger/nvim-dap',
    'https://github.com/rcarriga/nvim-dap-ui',
    'https://github.com/nvim-treesitter/nvim-treesitter',
  }
end
