-- org.nvim syntax. Generated per buffer so in-buffer #+TODO keywords and
-- src block languages are highlighted. Replaces Neovim's bundled syntax/org.vim.
if vim.b.current_syntax then
  return
end

local ok, err = pcall(function()
  require("org.syntax").apply(vim.api.nvim_get_current_buf())
end)
if not ok then
  vim.notify("org.nvim syntax: " .. tostring(err), vim.log.levels.ERROR)
end
vim.b.current_syntax = "org"
