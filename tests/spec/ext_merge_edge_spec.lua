-- Edge cases, performance and fuzzing of the merge extension's structural
-- merge (ext_merge_spec.lua has the basics, the driver and git).

local function merge(base, ours, theirs, opts)
  return require("org.extensions.merge.merge").merge(base, ours, theirs, opts)
end

local function props(id)
  return { ":PROPERTIES:", ":ID: " .. id, ":END:" }
end

local function entry(head, id, body)
  local l = { head }
  if id then
    vim.list_extend(l, props(id))
  end
  return vim.list_extend(l, body or {})
end

local function cat(...)
  local out = {}
  for _, l in ipairs({ ... }) do
    vim.list_extend(out, l)
  end
  return out
end

describe("merge extension: edge cases", function()
  it("keeps a level changed on one side under the same parent", function()
    local base = { "* A", "*** B", "text", "**** C" }
    local theirs = { "* A", "** B", "text", "*** C" }
    local res = merge(base, base, theirs)
    eq(0, res.conflicts)
    eq(theirs, res.lines)
    local ours = { "* A", "*** B", "text ours", "**** C" }
    res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* A", "** B", "text ours", "*** C" }, res.lines)
  end)

  it("keeps both entries of an ID used twice in different subtrees", function()
    local base = cat({ "* A" }, entry("** X", "1", { "a" }), { "* B" }, entry("** Y", "1", { "b" }))
    local theirs = vim.list_extend(vim.deepcopy(base), { "c" })
    local res = merge(base, base, theirs)
    eq(0, res.conflicts)
    eq(theirs, res.lines)
  end)

  it("keeps CRLF line ends, also on a recomposed headline", function()
    local base = { "* TODO A :x:\r", "body\r", "* B\r" }
    local ours = { "* DONE A :x:\r", "body\r", "* B\r" }
    local theirs = { "* TODO A :x:y:\r", "body\r", "* B\r" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    for _, l in ipairs(res.lines) do
      eq("\r", l:sub(-1))
    end
    ok(res.lines[1]:match("^%* DONE A%s+:x:y:\r$"))
  end)

  it("keeps a UTF-8 BOM and still reads the first headline", function()
    local bom = "\239\187\191"
    local res = merge({ bom .. "* TODO A", "x" }, { bom .. "* DONE A", "x" }, { bom .. "* TODO A", "x", "y" })
    eq(0, res.conflicts)
    eq({ bom .. "* DONE A", "x", "y" }, res.lines)
  end)

  it("matches an entry renamed and edited on one side by its similar text", function()
    local base = { "* A", "one", "two", "three", "* B" }
    local ours = { "* A2", "one", "two", "three", "ours", "* B" }
    local theirs = { "* A", "zero", "one", "two", "three", "* B" }
    local res = merge(base, ours, theirs)
    eq(0, res.conflicts)
    eq({ "* A2", "zero", "one", "two", "three", "ours", "* B" }, res.lines)
    -- off: a delete and an add, so a conflict
    eq(1, merge(base, ours, theirs, { rename_similarity = false }).conflicts)
  end)

  it("does not take an unrelated new entry for a renamed one", function()
    local base = { "* A", "alpha", "beta", "* B" }
    local ours = { "* C", "gamma", "delta", "* B" }
    local theirs = { "* A", "alpha", "beta", "more", "* B" }
    local res = merge(base, ours, theirs)
    -- A deleted by ours and changed by theirs: a conflict; C stays, new
    eq(1, res.conflicts)
    ok(vim.tbl_contains(res.lines, "* C"))
    ok(vim.tbl_contains(res.lines, "more"))
  end)

  it("matches an entry that got an ID on one side (org-roam) by its title", function()
    local res = merge({ "* A", "x" }, entry("* A", "42", { "x" }), { "* A", "x", "y" })
    eq(0, res.conflicts)
    eq({ "* A", ":PROPERTIES:", ":ID: 42", ":END:", "x", "y" }, res.lines)
  end)

  it("conflicts on an entry moved to different parents on both sides", function()
    local base = cat({ "* P", "* Q" }, entry("* X", "x"))
    local ours = cat({ "* P" }, entry("** X", "x"), { "* Q" })
    local theirs = cat({ "* P", "* Q" }, entry("** X", "x"))
    local res = merge(base, ours, theirs)
    eq(2, res.conflicts)
    eq(
      cat(
        { "* P", "<<<<<<< ours" },
        entry("** X", "x"),
        { "=======", ">>>>>>> theirs", "* Q", "<<<<<<< ours", "=======" },
        entry("** X", "x"),
        { ">>>>>>> theirs" }
      ),
      res.lines
    )
    eq(theirs, merge(base, ours, theirs, { prefer = "theirs" }).lines)
    eq(ours, merge(base, ours, theirs, { prefer = "ours" }).lines)
  end)

  it("keeps both entries when the two sides' moves make a cycle", function()
    local base = cat(entry("* X", "x"), entry("* Y", "y"))
    local ours = cat(entry("* Y", "y"), entry("** X", "x"))
    local theirs = cat(entry("* X", "x"), entry("** Y", "y"))
    local res = merge(base, ours, theirs)
    ok(res.conflicts > 0)
    ok(vim.tbl_contains(res.lines, "* Y"))
    ok(vim.tbl_contains(res.lines, "** X"))
  end)

  it("merges other log drawers item by item", function()
    local base = { "* A", ":NOTES:", "- a [2024-01-01 Mon]", ":END:", "text" }
    local ours = { "* A", ":NOTES:", "- o [2024-01-03 Wed]", "- a [2024-01-01 Mon]", ":END:", "text" }
    local theirs = { "* A", ":NOTES:", "- t [2024-01-02 Tue]", "- a [2024-01-01 Mon]", ":END:", "text" }
    eq(1, merge(base, ours, theirs).conflicts)
    local res = merge(base, ours, theirs, { set_drawers = { "notes" } })
    eq(0, res.conflicts)
    eq(
      { "* A", ":NOTES:", "- o [2024-01-03 Wed]", "- t [2024-01-02 Tue]", "- a [2024-01-01 Mon]", ":END:", "text" },
      res.lines
    )
  end)

  describe("with log_into_drawer", function()
    with_config({ log_into_drawer = "STATES" })
    it("merges that drawer item by item", function()
      local base = { "* A", ":STATES:", "- a [2024-01-01 Mon]", ":END:" }
      local ours = { "* A", ":STATES:", "- o [2024-01-03 Wed]", "- a [2024-01-01 Mon]", ":END:" }
      local theirs = { "* A", ":STATES:", "- t [2024-01-02 Tue]", "- a [2024-01-01 Mon]", ":END:" }
      eq(0, merge(base, ours, theirs).conflicts)
    end)
  end)

  it("keeps identical CLOCK lines that both sides kept", function()
    local c = "CLOCK: [2024-01-01 Mon 10:00]--[2024-01-01 Mon 11:00] =>  1:00"
    local n = "CLOCK: [2024-01-02 Tue 10:00]--[2024-01-02 Tue 11:00] =>  1:00"
    local m = "CLOCK: [2024-01-03 Wed 10:00]--[2024-01-03 Wed 11:00] =>  1:00"
    local base = { "* A", ":LOGBOOK:", c, c, ":END:" }
    local res = merge(base, { "* A", ":LOGBOOK:", n, c, c, ":END:" }, { "* A", ":LOGBOOK:", m, c, c, ":END:" })
    eq({ "* A", ":LOGBOOK:", m, n, c, c, ":END:" }, res.lines)
  end)

  it("merges files with only a preamble, and empty files", function()
    eq(
      { "#+TITLE: x", "#+AUTHOR: z" },
      merge({ "#+TITLE: x" }, { "#+TITLE: x", "#+AUTHOR: z" }, { "#+TITLE: x" }).lines
    )
    eq({ "* B" }, merge({}, {}, { "* B" }).lines)
    local res = merge({ "* A" }, {}, { "* A", "x" })
    eq(1, res.conflicts)
    ok(vim.tbl_contains(res.lines, "x"))
  end)

  it("merges 5,000 headings in well under a second", function()
    local base = {}
    for i = 1, 5000 do
      vim.list_extend(base, { "* TODO Task " .. i, "body " .. i })
    end
    local ours = vim.deepcopy(base)
    for i = 1, 2500 do
      vim.list_extend(ours, { "* Ours " .. i, "o " .. i })
    end
    -- theirs deletes every other entry and adds as many new ones
    local theirs = {}
    for i = 1, 5000, 2 do
      vim.list_extend(theirs, { "* TODO Task " .. i, "body " .. i })
    end
    for i = 1, 2500 do
      vim.list_extend(theirs, { "* Theirs " .. i, "t " .. i })
    end
    local t0 = vim.uv.hrtime()
    local res = merge(base, ours, theirs)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    eq(0, res.conflicts)
    eq(15000, #res.lines)
    ok(ms < 1000, string.format("took %.0f ms", ms))
  end)
end)

describe("merge extension: fuzz", function()
  -- a random outline: entries with unique titles and body lines, some
  -- with IDs
  local seq = 0
  local function uid(p)
    seq = seq + 1
    return p .. seq
  end
  local function new_node(depth)
    local n = {
      title = uid("E"),
      id = math.random() < 0.5 and uid("id") or nil,
      todo = math.random() < 0.5 and "TODO" or nil,
      tags = {},
      props = {},
      body = {},
      children = {},
    }
    for _ = 1, math.random(0, 3) do
      n.body[#n.body + 1] = uid("line ")
    end
    if depth < 3 then
      for _ = 1, math.random(0, 3 - depth) do
        n.children[#n.children + 1] = new_node(depth + 1)
      end
    end
    return n
  end
  local function tree()
    local root = { children = {} }
    for _ = 1, math.random(1, 5) do
      root.children[#root.children + 1] = new_node(1)
    end
    return root
  end
  local function render(root)
    local out = {}
    local function r(n, level)
      local h = string.rep("*", level) .. " " .. (n.todo and (n.todo .. " ") or "") .. n.title
      if #n.tags > 0 then
        h = h .. " :" .. table.concat(n.tags, ":") .. ":"
      end
      out[#out + 1] = h
      if n.id or #n.props > 0 then
        out[#out + 1] = ":PROPERTIES:"
        if n.id then
          out[#out + 1] = ":ID: " .. n.id
        end
        for _, p in ipairs(n.props) do
          out[#out + 1] = ":" .. p[1] .. ": " .. p[2]
        end
        out[#out + 1] = ":END:"
      end
      vim.list_extend(out, n.body)
      for _, c in ipairs(n.children) do
        r(c, level + 1)
      end
    end
    for _, c in ipairs(root.children) do
      r(c, 1)
    end
    return out
  end
  -- every entry with its parent, in document order
  local function nodes(root)
    local out = {}
    local function walk(n)
      for _, c in ipairs(n.children) do
        out[#out + 1] = { node = c, parent = n }
        walk(c)
      end
    end
    walk(root)
    return out
  end
  local function find(root, title)
    for _, x in ipairs(nodes(root)) do
      if x.node.title == title then
        return x.node, x.parent
      end
    end
  end
  local KINDS = { "body", "todo", "tag", "prop", "child", "delete", "rename" }
  -- random edits `{ kind, title, data }`; the titles of the entries they
  -- change (the parent too for an added or deleted child, the subtree of a
  -- deleted one) go into `touched`, and entries in `avoid` are left alone
  local function random_ops(root, count, touched, avoid)
    local ops = {}
    local all = nodes(root)
    for _ = 1, count do
      local x = all[math.random(#all)]
      local kind = KINDS[math.random(#KINDS)]
      local t = x.node.title
      local set = { [t] = true }
      if kind == "child" or kind == "delete" then
        set[x.parent.title or ""] = true
      end
      if kind == "delete" then
        local function mark(n)
          set[n.title] = true
          for _, c in ipairs(n.children) do
            mark(c)
          end
        end
        mark(x.node)
      end
      local clash = false
      for k in pairs(set) do
        clash = clash or (avoid and avoid[k]) or false
      end
      if not clash and not touched[t] then
        for k in pairs(set) do
          touched[k] = true
        end
        ops[#ops + 1] = { kind = kind, title = t, data = uid("x") }
      end
    end
    return ops
  end
  local function apply(root, ops)
    for _, op in ipairs(ops) do
      local n, parent = find(root, op.title)
      if n then
        if op.kind == "body" then
          n.body[#n.body + 1] = "added " .. op.data
        elseif op.kind == "todo" then
          n.todo = n.todo == "TODO" and "DONE" or "TODO"
        elseif op.kind == "tag" then
          n.tags[#n.tags + 1] = "t" .. op.data
        elseif op.kind == "prop" then
          n.props[#n.props + 1] = { "P" .. op.data, "v" }
        elseif op.kind == "child" then
          local child = { title = "N" .. op.data, tags = {}, props = {}, body = { "b" .. op.data }, children = {} }
          table.insert(n.children, child)
        elseif op.kind == "delete" then
          for i, c in ipairs(parent.children) do
            if c == n then
              table.remove(parent.children, i)
              break
            end
          end
        elseif op.kind == "rename" then
          n.title = "R" .. op.data
        end
      end
    end
  end
  local function dump(name, lines)
    return name .. ":\n" .. table.concat(lines, "\n") .. "\n"
  end

  it("merges random edits to disjoint entries cleanly into both edits applied", function()
    math.randomseed(20260930)
    for iter = 1, 300 do
      local base = tree()
      local touched_o = {}
      local ops_o = random_ops(base, math.random(1, 3), touched_o)
      local ops_t = random_ops(base, math.random(1, 3), {}, touched_o)
      local ours, theirs, both = vim.deepcopy(base), vim.deepcopy(base), vim.deepcopy(base)
      apply(ours, ops_o)
      apply(theirs, ops_t)
      apply(both, ops_o)
      apply(both, ops_t)
      local b, o, t = render(base), render(ours), render(theirs)
      local res = merge(b, o, t)
      local want = render(both)
      if res.conflicts ~= 0 or not vim.deep_equal(want, res.lines) then
        error(
          string.format("iteration %d (%d conflicts)\n", iter, res.conflicts)
            .. dump("base", b)
            .. dump("ours", o)
            .. dump("theirs", t)
            .. dump("want", want)
            .. dump("got", res.lines)
        )
      end
    end
  end)

  it("never loses a line either side added, whatever the edits", function()
    math.randomseed(4242)
    for iter = 1, 300 do
      local base = tree()
      local ours, theirs = vim.deepcopy(base), vim.deepcopy(base)
      apply(ours, random_ops(base, math.random(1, 4), {}))
      apply(theirs, random_ops(base, math.random(1, 4), {}))
      local b, o, t = render(base), render(ours), render(theirs)
      local res = merge(b, o, t)
      local text = table.concat(res.lines, "\n")
      local in_base, base_titles = {}, {}
      local function bare(title)
        return (title:gsub("^TODO ", ""):gsub("^DONE ", ""):gsub("%s+:[%w:]+:$", ""))
      end
      for _, l in ipairs(b) do
        in_base[l] = true
        local title = l:match("^%*+ (.*)$")
        if title then
          base_titles[bare(title)] = true
        end
      end
      for _, side in ipairs({ o, t }) do
        for _, l in ipairs(side) do
          if not in_base[l] then
            -- a headline may be recomposed: a new title and new tags must
            -- stay (an old title may be renamed by the other side)
            local title = l:match("^%*+ (.*)$")
            local needles = { l }
            if title then
              needles = {}
              if not base_titles[bare(title)] then
                needles[1] = bare(title)
              end
              for tag in title:gmatch(":(t%w+)") do
                needles[#needles + 1] = tag
              end
            end
            for _, needle in ipairs(needles) do
              if not text:find(needle, 1, true) then
                error(
                  string.format("iteration %d: lost %q\n", iter, needle)
                    .. dump("base", b)
                    .. dump("ours", o)
                    .. dump("theirs", t)
                    .. dump("got", res.lines)
                )
              end
            end
          end
        end
      end
    end
  end)
end)

describe("merge extension: driver options", function()
  local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))
  local driver = root .. "/lua/org/extensions/merge/driver.lua"
  local function files(dir)
    vim.fn.writefile({ "* TODO A" }, dir .. "/base.org")
    vim.fn.writefile({ "* DONE A" }, dir .. "/ours.org")
    vim.fn.writefile({ "* WAIT A" }, dir .. "/theirs.org")
  end
  local function run(dir, args)
    local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", driver }
    vim.list_extend(cmd, args)
    vim.list_extend(cmd, { "--todo=TODO WAIT | DONE", dir .. "/base.org", dir .. "/ours.org", dir .. "/theirs.org" })
    return vim.system(cmd, { cwd = dir, text = true }):wait().code
  end

  it("labels the markers with git's %X and %Y, ignoring unexpanded ones", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    files(dir)
    eq(1, run(dir, { "--no-git-config", "--ours-label=HEAD", "--theirs-label=feature/x" }))
    local lines = vim.fn.readfile(dir .. "/ours.org")
    eq("<<<<<<< HEAD", lines[1])
    eq(">>>>>>> feature/x", lines[#lines])
    files(dir)
    eq(1, run(dir, { "--no-git-config", "--ours-label=%X", "--theirs-label=%Y" }))
    lines = vim.fn.readfile(dir .. "/ours.org")
    eq("<<<<<<< ours", lines[1])
    eq(">>>>>>> theirs", lines[#lines])
    vim.fn.delete(dir, "rf")
  end)

  it("reads merge.org.* from the repository's git config at merge time", function()
    if vim.fn.executable("git") == 0 then
      return
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.system({ "git", "init", "-q" }, { cwd = dir }):wait()
    vim.system({ "git", "config", "merge.org.prefer", "theirs" }, { cwd = dir }):wait()
    files(dir)
    eq(0, run(dir, { "--name=org" }))
    eq({ "* WAIT A" }, vim.fn.readfile(dir .. "/ours.org"))
    -- the command line wins over the git config
    files(dir)
    eq(0, run(dir, { "--name=org", "--prefer=ours" }))
    eq({ "* DONE A" }, vim.fn.readfile(dir .. "/ours.org"))
    -- another driver name reads other keys
    files(dir)
    eq(1, run(dir, { "--name=other" }))
    vim.fn.delete(dir, "rf")
  end)

  it("installs from :Org merge_install ARG, which completes", function()
    if vim.fn.executable("git") == 0 then
      return
    end
    require("org.config").opts.extensions.merge = {}
    require("org.extensions").setup()
    local notify = vim.notify
    vim.notify = function() end
    local ok1, err = pcall(function()
      eq({ "info" }, require("org.commands").complete("i", "Org merge_install i"))
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      vim.system({ "git", "init", "-q" }, { cwd = dir }):wait()
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, dir .. "/notes.org")
      vim.api.nvim_set_current_buf(buf)
      require("org.extensions.merge").install_command("info")
      eq({ "*.org merge=org" }, vim.fn.readfile(dir .. "/.git/info/attributes"))
      local cmd = { "git", "config", "--get", "merge.org.renameSimilarity" }
      local res = vim.system(cmd, { cwd = dir, text = true }):wait()
      eq("0.6", vim.trim(res.stdout))
      vim.api.nvim_buf_delete(buf, { force = true })
      vim.fn.delete(dir, "rf")
    end)
    vim.notify = notify
    require("org.config").opts.extensions.merge = nil
    require("org.extensions").setup()
    ok(ok1, err)
  end)
end)
