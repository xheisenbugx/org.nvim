-- Global capture hooks (User autocmds), org-capture-string and
-- org-capture-use-agenda-date.
local capture = require("org.capture")
local config = require("org.config")
local utils = require("org.utils")
local date = require("org.date")
vim.g.org_test = true

local function tmpfile(lines)
  local p = vim.fn.tempname() .. ".org"
  utils.writefile(p, lines)
  return p
end

local function run(fn, ...)
  local res
  local args = { ... }
  ok(utils.run(function()
    res = { fn(unpack(args)) }
  end), "coroutine did not finish")
  return unpack(res or {})
end

local function listen(events)
  local ids = {}
  for _, pat in ipairs({ "OrgCapturePrepareFinalize", "OrgCaptureBeforeFinalize", "OrgCaptureAfterFinalize" }) do
    ids[#ids + 1] = vim.api.nvim_create_autocmd("User", {
      pattern = pat,
      callback = function(ev)
        events[#events + 1] = { pat, ev.data }
      end,
    })
  end
  return function()
    for _, id in ipairs(ids) do
      vim.api.nvim_del_autocmd(id)
    end
  end
end

describe("capture hooks (org-capture-*-finalize-hook)", function()
  it("fires prepare, before and after events after the template functions", function()
    local p = tmpfile({ "* Inbox" })
    config.setup({})
    local events = {}
    local stop = listen(events)
    local buf = run(capture.capture, {
      target = p,
      headline = "Inbox",
      template = "* TODO %?",
      prepare_finalize = function()
        events[#events + 1] = { "tpl-prepare" }
      end,
      before_finalize = function()
        events[#events + 1] = { "tpl-before" }
      end,
      after_finalize = function()
        events[#events + 1] = { "tpl-after" }
      end,
    })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* TODO Hooked" })
    local dbuf, dline = run(capture.finalize, buf, { jump = false })
    stop()
    local names = vim.tbl_map(function(e)
      return e[1]
    end, events)
    eq({
      "tpl-prepare",
      "OrgCapturePrepareFinalize",
      "tpl-before",
      "OrgCaptureBeforeFinalize",
      "tpl-after",
      "OrgCaptureAfterFinalize",
    }, names)
    eq(buf, events[2][2].buf)
    eq({ bufnr = dbuf, line = dline }, events[4][2])
    eq("** TODO Hooked", vim.api.nvim_buf_get_lines(dbuf, dline - 1, dline, false)[1])
    eq({ bufnr = dbuf, line = dline }, events[6][2])
  end)

  it("fires before and after for immediate_finish templates", function()
    local p = tmpfile({ "* Inbox" })
    config.setup({})
    local events = {}
    local stop = listen(events)
    run(capture.capture, { target = p, template = "* Quick", immediate_finish = true })
    stop()
    eq("OrgCaptureBeforeFinalize", events[1][1])
    eq("OrgCaptureAfterFinalize", events[2][1])
    eq(2, #events)
  end)

  it("fires prepare and after (aborted) but not before when the capture is killed", function()
    local p = tmpfile({ "* Inbox" })
    config.setup({})
    local events = {}
    local stop = listen(events)
    local buf = run(capture.capture, { target = p, template = "* X" })
    capture.kill(buf)
    stop()
    eq(2, #events)
    eq("OrgCapturePrepareFinalize", events[1][1])
    eq(true, events[1][2].aborted)
    eq("OrgCaptureAfterFinalize", events[2][1])
    eq(true, events[2][2].aborted)
  end)
end)

describe("capture_string (org-capture-string)", function()
  it("asks for the initial text and captures it as %i", function()
    local p = tmpfile({ "* Inbox" })
    config.setup({
      capture = { templates = { n = { template = "* %i", target = p, headline = "Inbox", immediate_finish = true } } },
    })
    local orig_input, orig_menu = utils.input, require("org.ui").menu
    local prompt
    utils.input = function(opts)
      prompt = opts.prompt
      return "Typed text"
    end
    require("org.ui").menu = function()
      return "n"
    end
    run(capture.capture_string)
    utils.input, require("org.ui").menu = orig_input, orig_menu
    eq("Initial text: ", prompt)
    eq({ "* Inbox", "** Typed text" }, vim.api.nvim_buf_get_lines(utils.find_buffer(p), 0, -1, false))
  end)

  it("uses a given template key and stops when the prompt is cancelled", function()
    local p = tmpfile({ "* Inbox" })
    config.setup({
      capture = { templates = { n = { template = "* %i", target = p, headline = "Inbox", immediate_finish = true } } },
    })
    run(capture.capture_string, "Given", "n")
    eq({ "* Inbox", "** Given" }, vim.api.nvim_buf_get_lines(utils.find_buffer(p), 0, -1, false))
    local orig_input = utils.input
    utils.input = function()
      return nil
    end
    eq(nil, (run(capture.capture_string)))
    utils.input = orig_input
  end)
end)

describe("capture.use_agenda_date (org-capture-use-agenda-date)", function()
  local view = require("org.agenda.view")
  local path = vim.fn.tempname() .. ".org"
  local today = date.today()
  local tomorrow = today:add(1, "d")

  local function open_week()
    utils.writefile(path, {
      "* TODO Meeting",
      "  SCHEDULED: <" .. tomorrow:to_string({ brackets = false }) .. " 14:30>",
    })
    require("org.agenda").open_agenda({ span = 3, anchor = today:days() })
  end

  local function prompt_opts(count)
    local orig = require("org.ui").menu
    local got
    require("org.ui").menu = function()
      return nil
    end
    local orig_view = view.cursor_date
    local seen
    view.cursor_date = function(with_time)
      seen = with_time
      return orig_view(with_time)
    end
    local opts = { count = count }
    run(capture.prompt, opts)
    got = opts
    view.cursor_date = orig_view
    require("org.ui").menu = orig
    return got, seen
  end

  local function goto_meeting()
    for l, it in pairs(view.state.line_items) do
      if it.title:match("Meeting") then
        vim.api.nvim_win_set_cursor(0, { l, 0 })
        return
      end
    end
    error("no Meeting line")
  end

  it("is off by default: the global capture ignores the agenda date", function()
    config.setup({ agenda_files = { path } })
    open_week()
    goto_meeting()
    local opts = prompt_opts(0)
    eq(nil, opts.date)
    view.quit(true)
  end)

  it("uses the date at point, and with count 1 the item's time", function()
    config.setup({ agenda_files = { path }, capture = { use_agenda_date = true } })
    open_week()
    goto_meeting()
    local opts, with_time = prompt_opts(0)
    eq(tomorrow:days(), opts.date:days())
    eq(nil, opts.date.hour)
    eq(false, with_time)
    opts, with_time = prompt_opts(1)
    eq(true, with_time)
    eq(tomorrow:days(), opts.date:days())
    eq(14, opts.date.hour)
    eq(30, opts.date.min)
    view.quit(true)
  end)
end)
