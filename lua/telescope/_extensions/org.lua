-- telescope.nvim extension: `:Telescope org <picker>` after
-- `require("telescope").load_extension("org")`. Telescope loads this file
-- itself, so it only runs when telescope is installed. These are org.nvim's
-- `pick_*` pickers, shown with telescope whatever the `picker` option says
-- (`:h org-pickers`).

-- telescope's options (`:Telescope org headlines theme=dropdown`) go over
-- `picker_opts.telescope`
local function run(fn)
  return function(topts)
    require("org.utils").run(require("org.pickers.sources")[fn], { backend = "telescope", backend_opts = topts })
  end
end

return require("telescope").register_extension({
  exports = {
    org = run("headlines_all"),
    headlines = run("headlines"),
    headlines_all = run("headlines_all"),
    tags = run("tag"),
    set_tags = run("set_tags"),
    agenda = run("agenda_day"),
    agenda_week = run("agenda_week"),
    todo = run("todo"),
    agenda_files = run("agenda_file"),
    capture_templates = run("capture_template"),
  },
})
