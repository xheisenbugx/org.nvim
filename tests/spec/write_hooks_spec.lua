-- org.write_hooks: pre/post-write hooks run by `:w` and by org's own saves
-- (utils.save_buffer) alike.
local config = require("org.config")
local utils = require("org.utils")
local hooks = require("org.write_hooks")
local crypt = require("org.crypt")
vim.g.org_test = true

local api = vim.api
local BEGIN = "-----BEGIN PGP MESSAGE-----"

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function read(path)
  local fd = assert(io.open(path, "rb"))
  local s = fd:read("*a")
  fd:close()
  return s
end

local function run(fn, ...)
  local res
  local args = { ... }
  local finished = utils.run(function()
    res = { fn(unpack(args)) }
  end)
  ok(finished, "coroutine did not finish")
  return unpack(res or {})
end

--- A buffer for `path` (written with `lines`), loaded and not shown.
local function hidden(path, lines)
  utils.writefile(path, lines)
  return utils.load_buffer(path)
end

describe("write hooks", function()
  local names = {}
  local function reg(name, hook)
    names[#names + 1] = name
    hooks.register(name, hook)
  end
  after_each(function()
    for _, n in ipairs(names) do
      hooks.unregister(n)
    end
    names = {}
  end)

  it("runs pre hooks in order and post hooks in reverse, with per-hook state", function()
    local log = {}
    for _, h in ipairs({ { "b", 20 }, { "a", 10 }, { "c", 20 } }) do
      reg("t-" .. h[1], {
        order = h[2],
        pre = function(_, ctx)
          ctx.state.name = h[1]
          log[#log + 1] = "pre " .. h[1] .. " " .. ctx.source
        end,
        post = function(_, ctx)
          log[#log + 1] = "post " .. ctx.state.name .. " " .. tostring(ctx.ok)
        end,
      })
    end
    local path = tmpdir() .. "/x.org"
    local buf = hidden(path, { "* A" })
    api.nvim_buf_set_lines(buf, 0, -1, false, { "* B" })
    eq(true, (utils.save_buffer(buf)))
    eq({
      "pre a save_buffer",
      "pre b save_buffer",
      "pre c save_buffer",
      "post c true",
      "post b true",
      "post a true",
    }, log)
    log = {}
    api.nvim_buf_set_lines(buf, 0, -1, false, { "* C" })
    api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    eq("pre a write", log[1])
    eq("post a true", log[6])
    eq({ "* C" }, utils.readfile(path))
  end)

  it("skips hooks for other filetypes", function()
    local seen = 0
    reg("t-ft", {
      filetype = "markdown",
      pre = function()
        seen = seen + 1
      end,
    })
    local path = tmpdir() .. "/x.org"
    local buf = hidden(path, { "* A" })
    api.nvim_buf_set_lines(buf, 0, -1, false, { "* B" })
    utils.save_buffer(buf)
    eq(0, seen)
  end)

  for _, how in ipairs({ "returns false", "throws" }) do
    it("a pre hook that " .. how .. " vetoes the write, whichever way", function()
      local post_ok = {}
      reg("t-first", {
        order = 1,
        post = function(_, ctx)
          post_ok[#post_ok + 1] = ctx.ok
        end,
      })
      reg("t-veto", {
        pre = function()
          if how == "throws" then
            error("boom", 0)
          end
          return false, "t-veto: not today"
        end,
      })
      local path = tmpdir() .. "/x.org"
      local buf = hidden(path, { "* A" })
      local before = read(path)
      api.nvim_buf_set_lines(buf, 0, -1, false, { "* Changed" })
      local saved, err = utils.save_buffer(buf)
      eq(false, saved)
      eq(how == "throws" and "t-veto: boom" or "t-veto: not today", err)
      eq(before, read(path))
      eq(true, vim.bo[buf].modified)
      -- the hooks that ran before the veto are closed
      eq({ false }, post_ok)
      local okw, werr = pcall(api.nvim_buf_call, buf, function()
        vim.cmd("silent write")
      end)
      eq(false, okw)
      ok(tostring(werr):find("t-veto", 1, true), tostring(werr))
      eq(before, read(path))
      eq(true, vim.bo[buf].modified)
      eq({ false, false }, post_ok)
      -- save_buffer_or_warn reports it
      local warned
      local w = utils.warn
      utils.warn = function(msg)
        warned = msg
      end
      eq(false, utils.save_buffer_or_warn(buf))
      utils.warn = w
      ok(warned and warned:find("t-veto", 1, true), warned)
      vim.bo[buf].modified = false
    end)
  end

  it("runs the post hooks of a :w that failed", function()
    local post_ok
    reg("t-fail", {
      post = function(_, ctx)
        post_ok = ctx.ok
      end,
    })
    local buf = hidden(tmpdir() .. "/x.org", { "* A" })
    api.nvim_buf_call(buf, function()
      ok(not pcall(vim.cmd, "silent write " .. vim.fn.tempname() .. "/no/such/dir/x.org"))
    end)
    vim.wait(1000, function()
      return post_ok ~= nil
    end)
    eq(false, post_ok)
  end)

  -- a hook that hides the "secret" line while the file is written and
  -- puts it back afterwards (as a re-decrypting crypt would)
  local function mask_hook()
    reg("t-mask", {
      pre = function(buf, ctx)
        local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        for i, l in ipairs(lines) do
          if l == "secret" then
            ctx.state.row = i - 1
            api.nvim_buf_set_lines(buf, i - 1, i, false, { "XXXX" })
          end
        end
      end,
      post = function(buf, ctx)
        if ctx.state.row then
          local modified = vim.bo[buf].modified
          api.nvim_buf_set_lines(buf, ctx.state.row, ctx.state.row + 1, false, { "secret" })
          vim.bo[buf].modified = modified and not ctx.ok
        end
      end,
    })
  end

  it(":w and save_buffer write the same bytes and restore the buffer", function()
    mask_hook()
    local dir = tmpdir()
    local lines = { "* Plain", "* Vault", "secret", "* Tail" }
    local results = {}
    for _, how in ipairs({ "write", "save_buffer" }) do
      local path = dir .. "/" .. how .. ".org"
      local buf = hidden(path, { "* Old" })
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      if how == "write" then
        api.nvim_buf_call(buf, function()
          vim.cmd("silent write")
        end)
      else
        eq(true, (utils.save_buffer(buf)))
      end
      results[how] = read(path)
      eq(lines, api.nvim_buf_get_lines(buf, 0, -1, false))
      eq(false, vim.bo[buf].modified, how)
    end
    eq(results.write, results.save_buffer)
    ok(results.write:find("XXXX", 1, true))
    ok(not results.write:find("secret", 1, true))
  end)
end)

describe("org's own writes", function()
  it("all go through utils.save_buffer", function()
    -- a `:noautocmd write`, or a `:write` run inside another write
    -- (BufWriteCmd) or an autocommand, skips the write hooks; save_buffer
    -- runs them. The exceptions:
    local allowed = {
      ["lua/org/utils.lua"] = true, -- save_buffer itself
      -- heal: a re-write of an unmodified buffer, in without_inserted
      ["lua/org/extensions/transclusion/init.lua"] = true,
      -- writes the edit-special buffer (its BufWriteCmd syncs the block)
      ["lua/org/babel/commands.lua"] = true,
      -- a plain :write from a command: BufWritePre runs the hooks
      ["lua/org/extensions/ics/init.lua"] = true,
    }
    local root = vim.fn.getcwd()
    local found = {}
    for name, kind in vim.fs.dir(root .. "/lua/org", { depth = 10 }) do
      if kind == "file" and name:match("%.lua$") and not allowed["lua/org/" .. name] then
        for n, l in ipairs(vim.fn.readfile(root .. "/lua/org/" .. name)) do
          if l:match("cmd%(?%s*[\"'][^\"']*%f[%a]write%f[%A]") or l:match("cmd%(?%s*[\"'][^\"']*%f[%a]w%f[%A]") then
            found[#found + 1] = name .. ":" .. n .. ": " .. l
          end
        end
      end
    end
    eq({}, found)
  end)
end)

-- Fake gpg: reversible "encryption" in PGP armour, so every save path can
-- be checked quickly and without a keyring.
describe("crypt.encrypt_on_save on every org save", function()
  local saved_enc
  before_each(function()
    saved_enc = crypt.encrypt_string
    crypt.encrypt_string = function(text)
      return BEGIN .. "\n" .. vim.base64.encode(text) .. "\n-----END PGP MESSAGE-----\n"
    end
  end)
  after_each(function()
    crypt.encrypt_string = saved_enc
    pcall(require("org.agenda.view").quit, true)
    config.setup({})
  end)

  local function setup(dir, extra)
    config.setup(vim.tbl_deep_extend("force", {
      org_directory = dir,
      agenda_files = { dir },
      archive_save_context_info = {},
      id = { locations_file = dir .. "/ids.json" },
      crypt = { encrypt_on_save = true, key = false, disable_auto_save = false },
    }, extra or {}))
    require("org.id")._reset()
  end

  local VAULT = { "* Vault :crypt:", "secret" }

  local function encrypted(path)
    local disk = read(path)
    ok(not disk:find("secret", 1, true), disk)
    ok(disk:find(BEGIN, 1, true), disk)
    return disk
  end

  it("utils.save_buffer and :w", function()
    local dir = tmpdir()
    setup(dir)
    for _, how in ipairs({ "save_buffer", "write" }) do
      local p = dir .. "/" .. how .. ".org"
      local buf = hidden(p, { "* Plain" })
      api.nvim_buf_set_lines(buf, 1, 1, false, VAULT)
      if how == "write" then
        api.nvim_buf_call(buf, function()
          vim.cmd("silent write")
        end)
      else
        eq(true, (utils.save_buffer(buf)))
      end
      encrypted(p)
    end
    eq(read(dir .. "/write.org"):gsub("^.-\n", ""), read(dir .. "/save_buffer.org"):gsub("^.-\n", ""))
  end)

  it("a failed encryption writes nothing", function()
    local dir = tmpdir()
    setup(dir)
    crypt.encrypt_string = function()
      return nil, "no gpg"
    end
    local p = dir .. "/a.org"
    local buf = hidden(p, { "* Plain" })
    api.nvim_buf_set_lines(buf, 1, 1, false, VAULT)
    local e = utils.error
    utils.error = function() end
    local saved, err = utils.save_buffer(buf)
    utils.error = e
    eq(false, saved)
    eq("org-crypt: encryption failed, buffer not written", err)
    eq("* Plain\n", read(p))
    vim.bo[buf].modified = false
  end)

  it("refile (destination file)", function()
    local dir = tmpdir()
    setup(dir)
    local a, b = dir .. "/a.org", dir .. "/b.org"
    utils.writefile(a, { "* Move me", "* Stay" })
    hidden(b, vim.list_extend({ "* Target" }, VAULT))
    vim.cmd("edit! " .. a)
    local refile = require("org.refile")
    refile.refile({ bufnr = api.nvim_get_current_buf(), lnum = 1 }, {
      dest = { filename = b, lnum = 1, olp = {}, label = "Target" },
    })
    local disk = encrypted(b)
    ok(disk:find("** Move me", 1, true), disk)
  end)

  it("archive (archive file)", function()
    local dir = tmpdir()
    setup(dir, { archive_location = "%s_archive::" })
    local p = dir .. "/s.org"
    utils.writefile(p, vim.list_extend(vim.deepcopy(VAULT), { "* Keep" }))
    vim.cmd("edit! " .. p)
    api.nvim_win_set_cursor(0, { 1, 0 })
    require("org.archive").archive_subtree()
    encrypted(p .. "_archive")
  end)

  it("capture (target file)", function()
    local dir = tmpdir()
    setup(dir)
    local p = dir .. "/inbox.org"
    hidden(p, vim.list_extend(vim.deepcopy(VAULT), { "* Inbox" }))
    run(require("org.capture").capture, { target = p, template = "* Captured", immediate_finish = true })
    local disk = encrypted(p)
    ok(disk:find("* Captured", 1, true), disk)
  end)

  it("agenda edits (save_after_edit) and agenda save_all", function()
    local dir = tmpdir()
    setup(dir, { agenda = { save_after_edit = true } })
    local p = dir .. "/a.org"
    local today = os.date("%Y-%m-%d")
    local lines = vim.list_extend({ "* TODO Task", "SCHEDULED: <" .. today .. ">" }, VAULT)
    utils.writefile(p, lines)
    vim.cmd("edit! " .. p)
    local buf = api.nvim_get_current_buf()
    require("org.agenda").open_agenda({ span = "day" })
    local view = require("org.agenda.view")
    local line
    for l, it in pairs(view.state.line_items) do
      if it.title == "Task" then
        line = l
      end
    end
    ok(line, "agenda item")
    api.nvim_win_set_cursor(0, { line, 0 })
    view.actions.todo_next()
    local disk = encrypted(p)
    ok(disk:find("* DONE Task", 1, true), disk)
    -- save_all
    view.quit(true)
    api.nvim_buf_set_lines(buf, 2, -1, false, VAULT)
    require("org.agenda").open_agenda({ span = "day" })
    local n = utils.notify
    utils.notify = function() end
    view.actions.save_all()
    utils.notify = n
    encrypted(p)
  end)

  it("mobile push", function()
    local dir = tmpdir()
    vim.fn.mkdir(dir .. "/stage", "p")
    setup(dir, {
      agenda_files = { dir .. "/a.org" },
      mobile = { directory = dir .. "/stage", inbox_for_pull = dir .. "/from-mobile.org", show_flagged = false },
    })
    local p = dir .. "/a.org"
    local buf = hidden(p, { "* Plain" })
    api.nvim_buf_set_lines(buf, 1, 1, false, VAULT)
    local n = utils.notify
    utils.notify = function() end
    ok(require("org.mobile").push())
    utils.notify = n
    encrypted(p)
    encrypted(dir .. "/stage/a.org")
  end)

  it("babel tangle (tangle_save_buffer)", function()
    local dir = tmpdir()
    setup(dir)
    local p = dir .. "/t.org"
    local buf = hidden(p, { "* Code", "#+begin_src sh :tangle out.sh", "echo hi", "#+end_src" })
    api.nvim_buf_set_lines(buf, -1, -1, false, VAULT)
    local n = utils.notify
    utils.notify = function() end
    require("org.babel.tangle").tangle({ bufnr = buf })
    utils.notify = n
    encrypted(p)
    eq({ "echo hi" }, utils.readfile(dir .. "/out.sh"))
  end)
end)
