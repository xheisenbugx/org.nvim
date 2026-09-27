local archive = require("org.archive")
local capture = require("org.capture")
local clock = require("org.clock")
local config = require("org.config")
local date = require("org.date")
local refile = require("org.refile")
local utils = require("org.utils")

vim.g.org_test = true

describe("capture, archive and refile data preservation", function()
  local dir, buffers
  with_config({ archive_save_context_info = {}, archive_location = "%s_archive::" })
  before_each(function()
    -- Other buffer specs leave modified scratch buffers with bufhidden=wipe.
    -- Discard that fixture before switching to this test's file buffer.
    vim.cmd("enew!")
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    buffers = {}
  end)
  after_each(function()
    if clock.state then
      clock.clock_cancel()
    end
    for buf in pairs(capture.sessions) do
      capture.kill(buf)
    end
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)

  local function file(name, lines, visible)
    local path = dir .. "/" .. name .. ".org"
    utils.writefile(path, lines)
    local buf = utils.load_buffer(path)
    buffers[#buffers + 1] = buf
    if visible then
      vim.api.nvim_set_current_buf(buf)
    end
    return buf, path
  end

  local function run(fn, ...)
    local result, args = nil, { ... }
    ok(utils.run(function()
      result = { fn(unpack(args)) }
    end))
    return unpack(result or {})
  end

  it("aborts only capture-created headings and keeps unrelated target edits", function()
    local target, path = file("capture", { "* Inbox" }, true)
    local buf = run(capture.capture, { template = "* Note", target = path, headline = "New" })
    vim.api.nvim_buf_set_lines(target, -1, -1, false, { "* Unrelated unsaved work" })
    capture.kill(buf)
    eq({ "* Inbox", "* Unrelated unsaved work" }, buf_lines(target))
    eq(true, vim.bo[target].modified)
  end)

  it("keeps user text added below a capture-created heading on abort", function()
    local target, path = file("capture-child", { "* Inbox" }, true)
    local buf = run(capture.capture, { template = "* Note", target = path, headline = "New" })
    vim.api.nvim_buf_set_lines(target, -1, -1, false, { "** User child", "valuable body" })
    capture.kill(buf)
    eq({ "* Inbox", "* New", "** User child", "valuable body" }, buf_lines(target))
  end)

  it("keeps edits in a target newly loaded by a capture on abort", function()
    local path = dir .. "/new-target.org"
    utils.writefile(path, { "* Inbox" })
    local buf = run(capture.capture, { template = "* Note", target = path, headline = "New" })
    local target = capture.sessions[buf].ctx.loc.bufnr
    buffers[#buffers + 1] = target
    vim.api.nvim_buf_set_lines(target, -1, -1, false, { "* Unrelated unsaved work" })
    capture.kill(buf)
    ok(vim.api.nvim_buf_is_valid(target))
    eq({ "* Inbox", "* Unrelated unsaved work" }, buf_lines(target))
  end)

  it("removes an unused capture date tree while retaining earlier and later edits", function()
    local target, path = file("capture-datetree", { "* Inbox" }, true)
    vim.api.nvim_buf_set_lines(target, 0, 1, false, { "* Unsaved Inbox" })
    local buf = run(capture.capture, { template = "* Note", target = path, datetree = true }, {
      date = date.parse("<2026-09-27 Sun>"),
    })
    vim.api.nvim_buf_set_lines(target, -1, -1, false, { "* Later unsaved work" })
    capture.kill(buf)
    eq({ "* Unsaved Inbox", "* Later unsaved work" }, buf_lines(target))
    eq(true, vim.bo[target].modified)
  end)

  it("refuses to archive a subtree into itself or one of its children", function()
    for _, heading in ipairs({ "* Task", "** Archive" }) do
      local lines = { "* Task", "valuable body", "** Archive", "archive body", "** Other", "other body" }
      local source = file("archive-self" .. #heading, lines, true)
      config.opts.archive_location = "::" .. heading
      local success, result = pcall(archive.archive_subtree, { bufnr = source, lnum = 1 })
      ok(not success or result == nil, "archiving inside the source must fail")
      eq(lines, buf_lines(source))
    end
  end)

  it("does not remove a source subtree when saving its archive fails", function()
    local lines = { "* Task", "valuable body" }
    local source = file("archive-source", lines, true)
    local target, path = file("archive-readonly", { "* Existing archive" })
    vim.bo[target].readonly = true
    config.opts.archive_location = path .. "::"
    local success, result = pcall(archive.archive_subtree, { bufnr = source, lnum = 1 })
    ok(not success or result == nil)
    eq(lines, buf_lines(source))
    eq({ "* Existing archive" }, utils.readfile(path))
  end)

  it("refuses to archive an ancestor into its own date tree", function()
    local lines = { "* 2026", "valuable body", "** 2026-09 September", "*** 2026-09-27 Sunday", "day body" }
    local source = file("archive-datetree-self", lines, true)
    config.opts.archive_location = "::datetree/"
    local real_today = date.today
    date.today = function()
      return date.parse("<2026-09-27 Sun>")
    end
    local success, result = pcall(archive.archive_subtree, { bufnr = source, lnum = 1 })
    date.today = real_today
    ok(not success or result == nil)
    eq(lines, buf_lines(source))
  end)

  it("does not remove a source subtree when saving a hidden refile target fails", function()
    local lines = { "* Task", "valuable body" }
    local source = file("refile-source", lines, true)
    local target, path = file("refile-readonly", { "* Target" })
    vim.bo[target].readonly = true
    local dest = { bufnr = target, lnum = 1, path = "Target", label = "Target" }
    eq(nil, refile.refile({ bufnr = source, lnum = 1 }, { dest = dest }))
    eq(lines, buf_lines(source))
    eq({ "* Target" }, utils.readfile(path))
    eq({ "* Target" }, buf_lines(target))
    vim.bo[target].readonly = false
    ok(refile.refile({ bufnr = source, lnum = 1 }, { dest = dest }))
    eq({ "* Target", "** Task", "valuable body" }, utils.readfile(path))
  end)

  it("keeps a capture open after a write failure and retries without duplication", function()
    local target, path = file("capture-readonly", { "* Inbox" }, true)
    vim.bo[target].readonly = true
    local buf = run(capture.capture, { template = "* Precious", target = path, headline = "Inbox" })
    pcall(capture.finalize, buf, { jump = false })
    ok(capture.sessions[buf], "write failure must keep the capture open")
    eq({ "* Precious" }, buf_lines(buf))
    eq({ "* Inbox" }, utils.readfile(path))
    vim.bo[target].readonly = false
    ok(run(capture.finalize, buf, { jump = false }))
    eq({ "* Inbox", "** Precious" }, utils.readfile(path))
  end)

  it("keeps moved ID locations at the source after a failed refile or archive save", function()
    local lines = { "* Task", ":PROPERTIES:", ":ID: preservation-test-id", ":END:", "valuable body" }
    local source, source_path = file("id-source", lines, true)
    local target, target_path = file("id-target", { "* Target" })
    vim.bo[target].readonly = true
    local id = require("org.id")
    id.register_lines(lines, source_path)
    local found = id.find("preservation-test-id")
    local filename = found.filename
    eq(
      nil,
      refile.refile({ bufnr = source, lnum = 1 }, {
        dest = { bufnr = target, lnum = 1, path = "Target", label = "Target" },
      })
    )
    eq(filename, id.find("preservation-test-id").filename)
    config.opts.archive_location = target_path .. "::"
    eq(nil, archive.archive_subtree({ bufnr = source, lnum = 1 }))
    eq(filename, id.find("preservation-test-id").filename)
  end)

  it("reports a save failure instead of suppressing the write error", function()
    local target, path = file("save-readonly", { "* Original" }, true)
    vim.bo[target].readonly = true
    vim.api.nvim_buf_set_lines(target, 0, -1, false, { "* Unsaved" })
    local saved, err = utils.save_buffer(target)
    eq(false, saved)
    ok(err:match("^E45:") and not err:find("\n"), err)
    eq({ "* Original" }, utils.readfile(path))
    eq({ "* Unsaved" }, buf_lines(target))
  end)

  it("does not finalize clock state or last-stored position before a capture is saved", function()
    local target, path = file("capture-clock-readonly", { "* Inbox" }, true)
    vim.bo[target].readonly = true
    local last = refile.last_stored
    local buf = run(capture.capture, {
      template = "* Precious",
      target = path,
      headline = "Inbox",
      clock_in = true,
      clock_keep = true,
    })
    eq(nil, run(capture.finalize, buf, { jump = false }))
    eq(nil, clock.state)
    eq(last, refile.last_stored)
    ok(capture.sessions[buf])
    vim.bo[target].readonly = false
    ok(run(capture.finalize, buf, { jump = false }))
    eq("Precious", clock.state.title)
    eq(1, select(2, table.concat(utils.readfile(path), "\n"):gsub("%*%* Precious", "")))
    ok(table.concat(utils.readfile(path), "\n"):find("CLOCK:", 1, true))
  end)

  it("keeps the target modified when it was written during an aborted capture", function()
    local target, path = file("saved-mid", { "* Inbox" }, true)
    local buf = run(capture.capture, { template = "* Note", target = path, headline = "New" })
    eq(true, utils.save_buffer(target))
    capture.kill(buf)
    eq({ "* Inbox" }, buf_lines(target))
    eq({ "* Inbox", "* New" }, utils.readfile(path))
    eq(true, vim.bo[target].modified)
  end)

  it("warns instead of raising when a refile copy cannot save a hidden target", function()
    local src = file("copy-src", { "* Task", "body" }, true)
    local target = file("copy-ro", { "* Target" })
    vim.bo[target].readonly = true
    local warned
    local notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warned = msg
      end
    end
    local done, err = pcall(refile.refile_copy, { bufnr = src, lnum = 1 }, {
      dest = { bufnr = target, lnum = 1, path = "Target", label = "Target" },
    })
    vim.notify = notify
    ok(done, err)
    ok(warned and warned:find("E45:", 1, true), warned)
    eq({ "* Task", "body" }, buf_lines(src))
  end)

  it("keeps saving the other agenda buffers after one write fails", function()
    local a = file("save-a", { "* A" })
    local b, bpath = file("save-b", { "* B" })
    vim.bo[a].readonly = true
    vim.api.nvim_buf_set_lines(a, -1, -1, false, { "edit" })
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "edit" })
    local notify = vim.notify
    vim.notify = function() end
    local done, err = pcall(require("org.agenda.view").actions.save_all)
    vim.notify = notify
    ok(done, err)
    eq({ "* B", "edit" }, utils.readfile(bpath))
  end)
end)
