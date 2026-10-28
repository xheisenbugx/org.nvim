-- org.nvim syntax. Replaces Neovim's bundled syntax/org.vim. Org buffers are
-- drawn by the parser highlighter (org.ui.highlight); the syntax only
-- includes the Vim syntax of src block languages tree-sitter doesn't draw.
-- A buffer that sets 'syntax' to org without being an org buffer (the drill
-- window) gets the parser highlighter too.
if vim.b.current_syntax then
  return
end

local ok, err = pcall(function()
  local buf = vim.api.nvim_get_current_buf()
  require("org.syntax").apply(buf)
  require("org.syntax").attach_decorations(buf)
end)
if not ok then
  vim.notify("org.nvim syntax: " .. tostring(err), vim.log.levels.ERROR)
end
vim.b.current_syntax = "org"
