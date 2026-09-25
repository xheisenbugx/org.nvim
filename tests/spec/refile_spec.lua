local refile = require("org.refile")
local config = require("org.config")
local utils = require("org.utils")
vim.g.org_test = true

local function setup_files(a, b, extra)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  utils.writefile(dir .. "/a.org", a)
  utils.writefile(dir .. "/b.org", b)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = dir,
    agenda_files = { dir },
    id = { locations_file = dir .. "/ids.json" },
  }, extra or {}))
  require("org.id")._reset()
  return dir
end

local function lines_of(path)
  local b = utils.find_buffer(path)
  return b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or utils.readfile(path)
end

local function labels()
  return vim.tbl_map(function(t)
    return t.label
  end, refile.targets())
end

local function target(label)
  for _, t in ipairs(refile.targets()) do
    if t.label == label then
      return t
    end
  end
  error("no target " .. label .. " in " .. vim.inspect(labels()))
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

--- Answer utils.select with the item whose label is next in `list`.
local function choose(list, seen)
  local orig = utils.select
  utils.select = function(items, opts)
    local want = table.remove(list, 1)
    local labels_, found, idx = {}, nil, nil
    for i, it in ipairs(items) do
      local l = opts.format_item and opts.format_item(it) or it
      labels_[#labels_ + 1] = l
      if l == want and not found then
        found, idx = it, i
      end
    end
    if seen then
      seen[#seen + 1] = labels_
    end
    return found, idx
  end
  return function()
    utils.select = orig
  end
end

describe("refile targets", function()
  after_each(function()
    config.setup({})
  end)

  it("defaults to the level-1 headlines of the current buffer, labelled by their heading", function()
    local dir = setup_files({ "* A1 [1/2]", "** A2", "* [[https://x][Link]] :t:" }, { "* B1" })
    vim.cmd("edit! " .. dir .. "/a.org")
    eq({ "A1 [1/2]", "Link" }, labels())
  end)

  it("labels other files' targets with the file name and offers files only with file styles", function()
    local dir = setup_files({ "* A1", "** A2" }, { "* B1" }, {
      refile = { targets = { { files = "agenda", max_level = 2 } } },
    })
    vim.cmd("edit! " .. dir .. "/a.org")
    eq({ "A1", "A2", "B1 (b.org)" }, labels())
    config.opts.refile.use_outline_path = true
    eq({ "A1/", "A1/A2/", "B1/ (b.org)" }, labels())
    config.opts.refile.use_outline_path = "file"
    eq({ "a.org/", "a.org/A1/", "a.org/A1/A2/", "b.org/", "b.org/B1/" }, labels())
    config.opts.refile.use_outline_path = "full-file-path"
    local l = labels()
    ok(l[#l]:match("^/.*/b%.org/B1/$"), vim.inspect(l))
  end)

  it("uses #+TITLE with the title style, escapes / and drops cookies in paths", function()
    local dir = setup_files({ "#+TITLE: My T", "* A [1/2]", "** TODO [#A] deep [50%] :x:", "* B/C" }, { "* X" }, {
      refile = { targets = { { files = "current", max_level = 3 } }, use_outline_path = "title" },
    })
    vim.cmd("edit! " .. dir .. "/a.org")
    eq({ "My T/", "My T/A/", "My T/A/deep/", "My T/B\\/C/" }, labels())
  end)

  it("offers the agenda files up to `max_level` when set", function()
    local dir = setup_files({ "* A1", "** A2", "*** A3", "**** A4" }, { "* B1" }, {
      refile = { max_level = 3, use_outline_path = "file" },
    })
    vim.cmd("edit! " .. dir .. "/a.org")
    local l = labels()
    ok(vim.tbl_contains(l, "a.org/A1/A2/A3/"), vim.inspect(l))
    ok(not vim.tbl_contains(l, "a.org/A1/A2/A3/A4/"))
    ok(vim.tbl_contains(l, "b.org/"))
    ok(vim.tbl_contains(l, "b.org/B1/"))
  end)

  it("uses refile.targets specs and the verify function", function()
    local dir = setup_files({ "* A :proj:", "** A2 :proj:", "* B", "** TODO B2" }, { "* C :proj:" }, {
      refile = {
        use_outline_path = "file",
        targets = { { files = "agenda", tag = "proj", max_level = 1 }, { files = "current", todo = "TODO" } },
      },
    })
    vim.cmd("edit! " .. dir .. "/a.org")
    local l = labels()
    ok(vim.tbl_contains(l, "a.org/A/"))
    ok(vim.tbl_contains(l, "b.org/C/"))
    ok(vim.tbl_contains(l, "a.org/B/B2/"))
    ok(not vim.tbl_contains(l, "a.org/A/A2/"))
    ok(not vim.tbl_contains(l, "a.org/B/"))
    config.opts.refile.verify = function(hl)
      return hl.todo == nil
    end
    ok(not vim.tbl_contains(labels(), "a.org/B/B2/"))
  end)

  it("completes the outline path in steps", function()
    local dir = setup_files({ "* A", "** A1", "*** A11", "* B" }, { "* X" }, {
      refile = { targets = { { files = "current", max_level = 3 } }, use_outline_path = true },
    })
    vim.cmd("edit! " .. dir .. "/a.org")
    local seen = {}
    local restore = choose({ "A/", "A/A1/", "A/A1/  (here)" }, seen)
    local t = run(refile.pick_target)
    restore()
    eq("A/A1/", t.path)
    eq({ "A/", "B/" }, seen[1])
    eq({ "A/  (here)", "A/A1/" }, seen[2])
    eq({ "A/A1/  (here)", "A/A1/A11/" }, seen[3])
    restore = choose({ "B/" })
    t = run(refile.pick_target)
    restore()
    eq("B/", t.path)
  end)

  it("creates parent nodes, asking first with \"confirm\"", function()
    local dir = setup_files({ "* X" }, { "* Top" }, {
      refile = { targets = { { files = "agenda", level = 1 } }, use_outline_path = "file" },
    })
    local t = { filename = dir .. "/b.org", lnum = 1, olp = { "Top" }, label = "b.org/Top/", path = "b.org/Top/" }
    local new = refile.create_nodes(t, { "New", "Deeper" })
    eq(3, new.lnum)
    eq({ "* Top", "** New", "*** Deeper" }, lines_of(dir .. "/b.org"))
    vim.cmd("edit! " .. dir .. "/a.org")
    config.opts.refile.allow_creating_parent_nodes = "confirm"
    local oc, oi, asked = utils.confirm, utils.input_complete, 0
    utils.input_complete = function()
      return "b.org/Top/Other"
    end
    utils.confirm = function()
      asked = asked + 1
      return false
    end
    eq(nil, run(refile.pick_target))
    eq(1, asked)
    config.opts.refile.allow_creating_parent_nodes = true
    local t2 = run(refile.pick_target)
    utils.confirm, utils.input_complete = oc, oi
    eq(1, asked)
    eq("b.org/Top/Other/", t2.path)
  end)
end)

describe("refile", function()
  after_each(function()
    config.setup({})
  end)

  -- source file, refiled headline, target headline (nil = file), expected
  -- (checked against Emacs org-refile)
  local cases = {
    { "* A\n** a1\n\n* B\n** b1\nbody\n\n* C", "a1", "B", "* A\n* B\n** b1\nbody\n\n** a1\n\n* C" },
    { "* A\n** a1\n* B\n** b1", "A", nil, "* B\n** b1\n* A\n** a1" },
    { "* A\n** a1\n* B\nbody\n** b1", "a1", "B", "* A\n* B\nbody\n** a1\n** b1", true },
    { "* A\n** a1\n* B", "a1", "B", "* A\n* B\n** a1" },
    { "* A\n** a1\n\n\n* B\n** b1\n\n", "a1", "B", "* A\n* B\n** b1\n\n\n** a1\n\n" },
    { "* One\nbody\n* Two\n** Child\n* Three", "One", "Two", "* Two\n** Child\n** One\nbody\n* Three" },
    { "* One\n* Two\n** Child\n* Three", "Three", "One", "* One\n** Three\n* Two\n** Child" },
  }
  for i, c in ipairs(cases) do
    it("keeps blank lines like Emacs (case " .. i .. ")", function()
      local dir = setup_files(vim.split(c[1], "\n"), { "* X" })
      config.opts.refile.reverse_note_order = c[5] or false
      local p = dir .. "/a.org"
      vim.cmd("edit! " .. p)
      local buf = vim.api.nvim_get_current_buf()
      local src, dst
      for n, l in ipairs(buf_lines(buf)) do
        src = src or (l:match("^%*+ " .. c[2] .. "$") and n)
        dst = dst or (c[3] and l:match("^%*+ " .. c[3] .. "$") and n)
      end
      refile.refile({ bufnr = buf, lnum = src }, { dest = { filename = p, lnum = dst or nil, olp = {}, label = "x" } })
      eq(c[4], table.concat(buf_lines(buf), "\n"))
    end)
  end

  it("refiles to another file, saves it and registers moved IDs", function()
    local dir = setup_files({ "* Move me", ":PROPERTIES:", ":ID: moved-1", ":END:", "text", "* Stay" }, { "* Target", "** Existing" }, {
      refile = { targets = { { files = "agenda", level = 1 } }, use_outline_path = "file" },
    })
    vim.cmd("edit! " .. dir .. "/a.org")
    refile.refile({ lnum = 1 }, { dest = target("b.org/Target/") })
    eq({ "* Stay" }, buf_lines())
    eq({ "* Target", "** Existing", "** Move me", ":PROPERTIES:", ":ID: moved-1", ":END:", "text" }, utils.readfile(dir .. "/b.org"))
    local where = require("org.utils").read_json(dir .. "/ids.json")["moved-1"]
    eq(vim.uv.fs_realpath(dir .. "/b.org"), vim.uv.fs_realpath(where))
  end)

  it("copies a subtree, logs and honours reverse note order", function()
    local dir = setup_files({ "* Copy me", "text" }, { "* Target", "** Existing" }, {
      todo_keywords = { "TODO(t) NEXT(n) | DONE(d)" },
      log_into_drawer = "LOGBOOK",
      refile = { targets = { { files = "agenda", level = 1 } }, use_outline_path = "file", reverse_note_order = true, log = "time" },
    })
    vim.cmd("edit! " .. dir .. "/a.org")
    refile.refile_copy({ lnum = 1 }, { dest = target("b.org/Target/") })
    eq({ "* Copy me", "text" }, buf_lines())
    local b = lines_of(dir .. "/b.org")
    eq("* Target", b[1])
    eq("** Copy me", b[2])
    ok(b[3]:match("^:LOGBOOK:"), b[3])
    ok(b[4]:match("^%- Refiled on %[%d%d%d%d%-%d%d%-%d%d %a+ %d%d:%d%d%]$"), b[4])
    eq("** Existing", b[#b])
    -- goto last stored jumps to the copy
    vim.cmd("enew!")
    refile.goto_last_stored()
    eq("** Copy me", vim.api.nvim_get_current_line())
  end)

  it("refuses to refile into the subtree itself", function()
    local dir = setup_files({ "* One", "** Two" }, { "* X" })
    vim.cmd("edit! " .. dir .. "/a.org")
    local buf = vim.api.nvim_get_current_buf()
    local okk = pcall(refile.move, { bufnr = buf, lnum = 1 }, { bufnr = buf, lnum = 2 })
    eq(false, okk)
  end)

  it("refiles a region of subtrees", function()
    local dir = setup_files({ "* A", "** a1", "** a2", "*** a21", "** a3", "* B" }, { "* X" })
    local p = dir .. "/a.org"
    vim.cmd("edit! " .. p)
    local buf = vim.api.nvim_get_current_buf()
    refile.refile(nil, { range = { 2, 4 }, dest = { filename = p, lnum = 6, olp = {}, label = "B" }, count = 0 })
    eq({ "* A", "** a3", "* B", "** a1", "** a2", "*** a21" }, buf_lines(buf))
    -- a region that is not a sequence of subtrees
    refile.refile(nil, { range = { 2, 3 }, dest = { filename = p, lnum = 4, olp = {}, label = "a1" }, count = 0 })
    eq({ "* A", "** a3", "* B", "** a1", "** a2", "*** a21" }, buf_lines(buf))
  end)

  it("makes the region's first line a headline with active_region_within_subtree", function()
    local dir = setup_files({ "* A", "some text", "more", "* B" }, { "* X" }, {
      refile = { active_region_within_subtree = true },
    })
    local p = dir .. "/a.org"
    vim.cmd("edit! " .. p)
    local buf = vim.api.nvim_get_current_buf()
    refile.refile(nil, { range = { 2, 3 }, dest = { filename = p, lnum = 4, olp = {}, label = "B" }, count = 0 })
    eq({ "* A", "* B", "** some text", "more" }, buf_lines(buf))
  end)

  it("copies with a count of 3 and refiles under the clocked task with 2", function()
    local dir = setup_files({ "* Task", "* Note", "* Other" }, { "* X" })
    local p = dir .. "/a.org"
    vim.cmd("edit! " .. p)
    local buf = vim.api.nvim_get_current_buf()
    local clock = require("org.clock")
    clock.clock_in({ bufnr = buf, lnum = 1 })
    local other = vim.fn.index(buf_lines(buf), "* Other") + 1
    refile.refile({ bufnr = buf, lnum = other }, { count = 2 })
    clock.clock_cancel()
    local l = buf_lines(buf)
    eq("* Task", l[1])
    eq("** Other", l[#l - 1])
    eq("* Note", l[#l])
    refile.refile({ bufnr = buf, lnum = #l - 1 }, { count = 3, dest = { filename = p, olp = {}, label = "a.org" } })
    l = buf_lines(buf)
    eq("** Other", l[#l - 2])
    eq("* Note", l[#l - 1])
    eq("* Other", l[#l])
  end)
end)
