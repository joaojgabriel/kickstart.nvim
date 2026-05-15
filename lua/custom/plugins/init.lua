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
end

-- File navigation
do
  vim.pack.add { gh 'stevearc/oil.nvim' }
  require('oil').setup {}
  vim.keymap.set('n', '-', '<CMD>Oil<CR>', { desc = 'Open parent directory' })
end
