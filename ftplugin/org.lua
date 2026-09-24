-- Buffer setup for org files. Replaces Neovim's bundled ftplugin/org.vim.
if vim.b.did_ftplugin then
  return
end
vim.b.did_ftplugin = 1
require("org.buffer").attach(vim.api.nvim_get_current_buf())
