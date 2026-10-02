describe("config.setup", function()
  local config = require("org.config")
  local saved

  before_each(function()
    saved = vim.deepcopy(config.opts)
  end)

  after_each(function()
    config.setup(saved)
  end)

  it("merges partial nested tables over the defaults", function()
    config.setup({ clock = { history_length = 9 }, agenda = { time_grid = { enabled = false } } })
    eq(9, config.opts.clock.history_length)
    eq(config.defaults.clock.mode_line_total, config.opts.clock.mode_line_total)
    eq(false, config.opts.agenda.time_grid.enabled)
    eq(config.defaults.agenda.time_grid.times, config.opts.agenda.time_grid.times)
  end)

  it("replaces list options instead of merging them", function()
    config.setup({ todo_keywords = { "A | B" }, notifications = { reminder_time = { 5 } } })
    eq({ "A | B" }, config.opts.todo_keywords)
    eq({ 5 }, config.opts.notifications.reminder_time)
  end)

  it("keeps the defaults of a dict option given as {}", function()
    config.setup({ log_note_headings = {} })
    eq(config.defaults.log_note_headings, config.opts.log_note_headings)
  end)

  it("starts from the defaults again when called twice", function()
    config.setup({ tags_column = -50, clock = { history_length = 9 } })
    config.setup({ clock = { persist = "clock" } })
    eq(config.defaults.tags_column, config.opts.tags_column)
    eq(config.defaults.clock.history_length, config.opts.clock.history_length)
    eq("clock", config.opts.clock.persist)
  end)

  it("rejects a scalar for an option section with a clear error", function()
    local before = vim.deepcopy(config.opts)
    local success, err = pcall(config.setup, { clock = true })
    eq(false, success)
    ok(tostring(err):find("option `clock` must be a table, got boolean", 1, true))
    -- nothing was applied
    eq(before, config.opts)
    ok(not pcall(config.setup, "~/org"))
  end)
end)
