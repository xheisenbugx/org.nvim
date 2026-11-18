local utils = require("org.utils")
local log = require("org.log")

local function stub(tbl, name, value)
  local orig = tbl[name]
  tbl[name] = value
  return function()
    tbl[name] = orig
  end
end

--- Collect what utils.notify shows while `fn` runs.
local function notified(fn)
  local out = {}
  local restore = stub(utils, "notify", function(msg, level)
    out[#out + 1] = { msg = msg, level = level }
  end)
  local ok, err = pcall(fn)
  restore()
  assert(ok, err)
  return out
end

describe("session log (org.log)", function()
  before_each(function()
    log.clear()
  end)

  it("keeps entries with their time, level, place, message and count", function()
    log.add("error", "here", "boom", "trace")
    local e = log.entries[1]
    eq({ "error", "here", "boom", "trace", 1 }, { e.level, e.where, e.msg, e.trace, e.count })
    ok(math.abs(e.time - os.time()) <= 1)
    eq(1, log.counts.error)
  end)

  it("counts up the last entry when the same failure comes again", function()
    log.add("error", "here", "boom")
    log.add("error", "here", "boom")
    log.add("error", "there", "boom")
    eq(2, #log.entries)
    eq(2, log.entries[1].count)
    eq(3, log.counts.error)
  end)

  it("keeps only the last max entries", function()
    local max = log.max
    log.max = 3
    for i = 1, 5 do
      log.add("error", "here", "error " .. i)
    end
    log.max = max
    eq(
      { "error 3", "error 4", "error 5" },
      vim.tbl_map(function(e)
        return e.msg
      end, log.entries)
    )
    eq(5, log.counts.error)
  end)
end)

describe("utils.try", function()
  before_each(function()
    log.clear()
  end)

  it("returns what the function returns, and logs nothing", function()
    eq({ true, 1, nil, 3 }, { utils.try("x", function(a, b)
      return a, nil, b
    end, 1, 3) })
    eq(0, #log.entries)
  end)

  it("returns false and the error like pcall, and logs it with its traceback", function()
    local function failing()
      error("broken cookie")
    end
    local okay, err = utils.try("lists: statistics", failing)
    eq(false, okay)
    ok(tostring(err):find("broken cookie", 1, true))
    local e = log.entries[1]
    eq({ "error", "lists: statistics" }, { e.level, e.where })
    ok(e.msg:find("broken cookie", 1, true))
    ok(e.trace:find("stack traceback:", 1, true), e.trace)
    ok(e.trace:find("log_spec.lua:%d+: in function"), e.trace)
  end)

  it("keeps a table error as it is", function()
    local obj = { code = 1 }
    local okay, err = utils.try("x", error, obj)
    eq(false, okay)
    eq(obj, err)
    eq(1, #log.entries)
  end)

  it("doesn't log a cancelled action (utils.abort)", function()
    eq(false, (utils.try("x", utils.abort)))
    eq(0, #log.entries)
  end)

  it("logs the inner failure of a nested try with its own traceback", function()
    utils.try("outer", function()
      utils.try("inner", error, "deep")
      error("shallow", 0)
    end)
    eq({ "inner", "outer" }, { log.entries[1].where, log.entries[2].where })
    eq("shallow", log.entries[2].msg)
  end)
end)

describe(":Org log", function()
  before_each(function()
    log.clear()
  end)

  it("shows the versions and the entries, newest last, and closes with q and <Esc>", function()
    utils.try("first: place", error, "older failure", 0)
    utils.try("second: place", error, "newer failure", 0)
    local wins = #vim.api.nvim_list_wins()
    vim.cmd("Org log")
    local buf = vim.api.nvim_get_current_buf()
    eq("org-log", vim.fs.basename(vim.api.nvim_buf_get_name(buf)))
    eq(wins + 1, #vim.api.nvim_list_wins())
    local lines = buf_lines(buf)
    local text = table.concat(lines, "\n")
    ok(text:find("org.nvim : " .. require("org.version").string(true), 1, true), text)
    ok(text:find("Neovim   : NVIM v", 1, true), text)
    ok(text:find("OS       : " .. vim.uv.os_uname().sysname, 1, true), text)
    ok(text:find("Logged   : 2 error(s)", 1, true), text)
    local first = text:find("ERROR first: place", 1, true)
    local second = text:find("ERROR second: place", 1, true)
    ok(first and second and first < second, text)
    ok(text:find("    newer failure", 1, true), text)
    ok(text:find("stack traceback:", 1, true), text)
    eq(false, vim.bo[buf].modifiable)
    -- the cursor on the newest entry's end
    eq(#lines, vim.api.nvim_win_get_cursor(0)[1])
    for _, key in ipairs({ "q", "<Esc>" }) do
      local map = vim.fn.maparg(key, "n", false, true)
      eq(buf, map.buffer == 1 and buf or nil, key)
    end
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
    eq(wins, #vim.api.nvim_list_wins())
    vim.cmd("Org log")
    vim.api.nvim_feedkeys("q", "x", false)
    eq(wins, #vim.api.nvim_list_wins())
  end)

  it("says when nothing was logged", function()
    vim.cmd("Org log")
    ok(vim.tbl_contains(buf_lines(0), "Nothing logged this session."))
    vim.cmd("close")
  end)

  it("is counted in the bug report and :checkhealth org", function()
    local health = require("org.health")
    local function core()
      local out = {}
      local h = setmetatable({}, {
        __index = function(_, kind)
          return function(msg, advice)
            out[#out + 1] = kind .. ": " .. msg .. (advice and (" | " .. table.concat(advice, " ")) or "")
          end
        end,
      })
      health.check_core(h)
      return table.concat(out, "\n")
    end
    ok(core():find("ok: no errors logged this session", 1, true))
    ok(not table.concat(require("org.bug_report").body(false), "\n"):find("Log     :", 1, true))
    utils.try("x", error, "boom")
    local out = core()
    ok(out:find("warn: 1 error(s) caught and logged this session | `:Org log`", 1, true), out)
    ok(out:find("see :h org-log", 1, true), out)
    ok(table.concat(require("org.bug_report").body(false), "\n"):find("Log     : 1 error(s)", 1, true))
  end)
end)

describe("failures that used to pass without a word", function()
  local dir
  before_each(function()
    log.clear()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
  end)
  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("reports a bookmark that can't be saved", function()
    -- stdpath("data")/org/bookmarks.json is a directory here: it can't be written
    local data = dir .. "/data"
    vim.fn.mkdir(data .. "/org/bookmarks.json", "p")
    local stdpath = vim.fn.stdpath
    local restore = stub(vim.fn, "stdpath", function(what)
      return what == "data" and data or stdpath(what)
    end)
    local buf = org_buffer({ "* Captured" })
    vim.api.nvim_buf_set_name(buf, dir .. "/notes.org")
    local msgs = notified(function()
      require("org.bookmarks").set("last_capture", buf, 1)
    end)
    restore()
    eq(1, #msgs, vim.inspect(msgs))
    eq(vim.log.levels.ERROR, msgs[1].level)
    ok(msgs[1].msg:find("^Could not save the bookmark org%-capture%-last%-stored: org: cannot write "), msgs[1].msg)
    -- the path once, not again in io.open's reason
    eq(1, select(2, msgs[1].msg:gsub("bookmarks%.json", "")), msgs[1].msg)
    eq("bookmarks: save org-capture-last-stored", log.entries[1].where)
  end)

  it("still saves a bookmark that can be", function()
    local data = dir .. "/data"
    local stdpath = vim.fn.stdpath
    local restore = stub(vim.fn, "stdpath", function(what)
      return what == "data" and data or stdpath(what)
    end)
    local buf = org_buffer({ "* Captured" })
    vim.api.nvim_buf_set_name(buf, dir .. "/notes.org")
    local msgs = notified(function()
      require("org.bookmarks").set("last_capture", buf, 1)
    end)
    local saved = require("org.bookmarks").get("org-capture-last-stored")
    restore()
    eq({}, msgs)
    eq(1, saved and saved.lnum)
    eq(0, #log.entries)
  end)

  it("logs a statistics cookie update that fails after an archive", function()
    local restore = stub(require("org.lists"), "update_parent_todo_statistics", function()
      error("cookie trouble")
    end)
    local buf = org_buffer({ "* Parent [0/1]", "** DONE Child", "* Other" }, { 2, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/a.org")
    notified(require("org.archive").archive_to_sibling)
    restore()
    local e = log.entries[#log.entries]
    ok(e and e.where == "archive: update TODO statistics", vim.inspect(log.entries))
    ok(e.msg:find("cookie trouble", 1, true))
  end)
end)

describe("User autocmds org fires (utils.user_event)", function()
  local group
  before_each(function()
    log.clear()
    group = vim.api.nvim_create_augroup("org.log.spec", { clear = true })
  end)
  after_each(function()
    vim.api.nvim_del_augroup_by_id(group)
  end)

  it("passes the data and leaves v:errmsg alone", function()
    local got
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "OrgSpecEvent",
      callback = function(ev)
        got = ev.data
      end,
    })
    vim.v.errmsg = "earlier"
    utils.user_event("OrgSpecEvent", { a = 1 })
    eq({ a = 1 }, got)
    eq("earlier", vim.v.errmsg)
    eq(0, #log.entries)
  end)

  it("logs an error in a handler and goes on with the command", function()
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "OrgPriorityChanged",
      callback = function()
        error("handler bug")
      end,
    })
    local buf = org_buffer({ "* TODO Task" }, { 1, 0 })
    -- (silent!: Neovim shows the handler's error itself)
    vim.cmd("silent! lua require('org.priority').set(nil, 'A')")
    eq("* TODO [#A] Task", buf_lines(buf)[1])
    local e = log.entries[1]
    ok(e and e.where == "User OrgPriorityChanged (a handler)", vim.inspect(log.entries))
    ok(e.msg:find("handler bug", 1, true), e.msg)
  end)

  it("warns and logs when the event can't be fired", function()
    local done = false
    local msgs = notified(function()
      local timer = assert(vim.uv.new_timer())
      timer:start(0, 0, function()
        -- a fast event: no autocommands there
        utils.user_event("OrgSpecFast", { x = 1 })
        timer:close()
        done = true
      end)
      vim.wait(1000, function()
        return done
      end)
      vim.wait(50)
    end)
    eq(1, #msgs, vim.inspect(msgs))
    eq(vim.log.levels.WARN, msgs[1].level)
    ok(msgs[1].msg:find("^Could not run the User OrgSpecFast autocommands: .*see :Org log"), msgs[1].msg)
    eq("User OrgSpecFast", log.entries[1].where)
  end)
end)
