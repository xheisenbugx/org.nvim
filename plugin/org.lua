-- org.nvim entry point. Heavy modules load lazily on first use.
if vim.g.loaded_org_nvim then
  return
end
vim.g.loaded_org_nvim = true

vim.filetype.add({
  extension = { org = "org", org_archive = "org" },
})

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
