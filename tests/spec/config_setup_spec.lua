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

describe("org.setup called again", function()
  local config = require("org.config")
  local saved

  before_each(function()
    saved = vim.deepcopy(config.opts)
  end)

  after_each(function()
    require("org").setup(saved)
  end)

  local function mapped(lhs, buf)
    local key = vim.keycode((lhs:gsub("<leader>", vim.g.mapleader)))
    local maps = buf and vim.api.nvim_buf_get_keymap(buf, "n") or vim.api.nvim_get_keymap("n")
    for _, m in ipairs(maps) do
      if vim.keycode(m.lhs) == key then
        return m.desc
      end
    end
  end

  it("replaces the global and buffer keymaps of the previous call", function()
    local buf = org_buffer({ "* Heading" }, { 1, 0 })
    ok(mapped("<leader>oa"))
    ok(mapped("<leader>ohy", buf))
    require("org").setup({ mappings = { global = { agenda = false }, org = { copy_subtree = "<leader>oY" } } })
    eq(nil, mapped("<leader>oa"))
    eq(nil, mapped("<leader>ohy", buf))
    ok(mapped("<leader>oY", buf))
  end)

  it("leaves a key the user mapped since alone", function()
    vim.keymap.set("n", "<leader>oa", "<Nop>", { desc = "mine" })
    require("org").setup({ mappings = { global = { agenda = false } } })
    eq("mine", mapped("<leader>oa"))
    vim.keymap.del("n", "<leader>oa")
  end)
end)
