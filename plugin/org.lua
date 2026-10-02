-- org.nvim entry point. Heavy modules load lazily on first use.
if vim.g.loaded_org_nvim then
  return
end
vim.g.loaded_org_nvim = true
if vim.fn.has("nvim-0.11") == 0 then
  vim.notify("org.nvim requires Neovim 0.11 or later", vim.log.levels.ERROR)
  return
end

-- Registered when vim.filetype first loads (the first file Neovim opens),
-- so starting Neovim without a file does not load it.
require("org.lazy").on_load("vim.filetype", "org", function(filetype)
  filetype.add({
    extension = { org = "org", org_archive = "org" },
    -- the Emacs mode line `-*- mode: org -*-` (see insert_mode_line_in_empty_file),
    -- which wins over the extension like in Emacs
    pattern = {
      [".*"] = {
        function(_, bufnr)
          local first = bufnr and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
          local lower = first:lower()
          if lower:match("%-%*%-.*mode:%s*org[%s;]") or lower:match("%-%*%-%s*org%s*%-%*%-") then
            return "org"
          end
        end,
        { priority = 0 },
      },
    },
  })
end)

-- `:Org` is available even before setup() (it triggers default setup).
vim.api.nvim_create_user_command("Org", function(opts)
  require("org").ensure_setup()
  require("org.commands").run(opts)
end, {
  nargs = "*",
  range = true,
  complete = function(...)
    return require("org.commands").complete(...)
  end,
  desc = "org.nvim commands",
})
