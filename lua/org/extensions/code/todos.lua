---@mod org.extensions.code.todos TODO comments of a repository in the agenda
---
--- The `code_todos` agenda block type lists comments like `TODO: text`,
--- `FIXME(bob): text` or `TODO(org:ID): text` found with `git grep`
--- (else `rg`, else a limited walk of the tree). `<CR>` on one opens the
--- code line; comments naming a heading's ID are grouped under it.
---
--- The agenda block never waits for the scan: it runs in the background
--- (the first time the block says "scanning") and the agenda is redrawn
--- when it is done. Results are kept per repository and scanned again in
--- the background when the block is drawn later.

local git = require("org.extensions.code.git")

local M = {}

local function opts()
  return require("org.extensions").opts("code") or require("org.extensions.code").defaults
end

--- The options a scan uses, copied so a scan running in the background
--- (in libuv callbacks) reads plain values.
local function snapshot()
  local o = opts()
  return {
    keywords = vim.deepcopy(o.todo_keywords or { "TODO", "FIXME" }),
    require_comment = o.todo_require_comment,
    link_pattern = o.todo_link_pattern or "^org:%s*(.-)%s*$",
    exclude = vim.deepcopy(o.todo_exclude or {}),
    scanner = o.todo_scanner or "auto",
    max_files = o.todo_max_files or 2000,
    max_items = o.todo_max_items or 500,
  }
end

--- Parse a line for a TODO comment: `{ keyword, arg, id, text, col }` or nil.
---@param line string
---@param o? table options (a `snapshot()`; default: the current ones)
---@return table|nil
function M.parse(line, o)
  o = o or snapshot()
  local best
  for _, kw in ipairs(o.keywords) do
    local init = 1
    while true do
      local s, e = line:find("%f[%w_]" .. vim.pesc(kw) .. "%f[^%w_]", init)
      if not s then
        break
      end
      local after = line:sub(e + 1, e + 1)
      local before = line:sub(1, s - 1)
      local commented = not o.require_comment
        or before:match("^%s*$")
        or before:find("--", 1, true)
        or before:find("//", 1, true)
        or before:find("/*", 1, true)
        or before:find("#", 1, true)
        or before:find(";", 1, true)
        or before:find("<!--", 1, true)
        or before:match("^%s*%*")
        or before:match("^%s*%%")
      if commented and (after == "" or after == "(" or after == ":" or after:match("%s")) then
        if not best or s < best.col then
          best = { keyword = kw, col = s, stop = e }
        end
        break
      end
      init = e + 1
    end
  end
  if not best then
    return nil
  end
  local rest = line:sub(best.stop + 1)
  local arg = rest:match("^(%b())")
  if arg then
    rest = rest:sub(#arg + 1)
    arg = arg:sub(2, -2)
  end
  local text = rest:gsub("^%s*:?%s*", ""):gsub("%s*%*/%s*$", ""):gsub("%s*%-%->%s*$", "")
  local id = arg and arg:match(o.link_pattern) or nil
  return {
    keyword = best.keyword,
    arg = arg,
    id = id ~= "" and id or nil,
    text = vim.trim(text),
    col = best.col,
  }
end

local function excluded(rel, o)
  for _, pat in ipairs(o.exclude) do
    if rel:match(pat) then
      return true
    end
  end
  return false
end

--- Which tool scans `root`: "git", "rg" or "lua".
local function scanner(root, o)
  local want = o.scanner
  local is_git = vim.uv.fs_stat(root .. "/.git") ~= nil
  if (want == "auto" or want == "git") and is_git and vim.fn.executable("git") == 1 then
    return "git"
  elseif (want == "auto" or want == "rg") and vim.fn.executable("rg") == 1 then
    return "rg"
  end
  return "lua"
end

-- the regexp of the keywords for git grep / rg (ERE)
local function alternation(o)
  local parts = {}
  for _, kw in ipairs(o.keywords) do
    parts[#parts + 1] = kw:gsub("[%^%$%(%)%.%[%]%*%+%?{}|\\]", "\\%0")
  end
  return table.concat(parts, "|")
end

-- The command of a scanner. Paths come NUL-terminated (`-z`, `--null`):
-- git would quote paths with non-ASCII bytes, and a path may hold ":".
local function command(how, o)
  if how == "git" then
    return { "git", "grep", "-z", "-n", "-I", "--untracked", "-w", "-E", "-e", alternation(o) }
  end
  return { "rg", "--null", "-n", "--no-heading", "--color", "never", "-w", "-e", alternation(o) }
end

--- A collector of grep output lines (`path\0lnum\0text` from git,
--- `path\0lnum:text` from rg): `add(chunk)` returns true once `max`
--- TODOs are found.
local function collector(root, o)
  local c = { list = {}, truncated = false, pending = "" }
  local function line(l)
    local path, rest = l:match("^([^%z]*)%z(.*)$")
    if not path then
      return
    end
    local lnum, text = rest:match("^(%d+)%z(.*)$")
    if not lnum then
      lnum, text = rest:match("^(%d+):(.*)$")
    end
    if not lnum then
      return
    end
    path = path:gsub("^%./", "")
    if excluded(path, o) then
      return
    end
    local p = M.parse(text, o)
    if p then
      p.rel = path
      p.file = root .. "/" .. path
      p.lnum = tonumber(lnum)
      p.line = text
      c.list[#c.list + 1] = p
    end
  end
  function c.add(chunk)
    if c.truncated or not chunk then
      return c.truncated
    end
    local data = c.pending .. chunk
    local from = 1
    while true do
      local nl = data:find("\n", from, true)
      if not nl then
        break
      end
      line(data:sub(from, nl - 1))
      from = nl + 1
      if #c.list >= o.max_items then
        c.truncated = true
        break
      end
    end
    c.pending = data:sub(from)
    return c.truncated
  end
  function c.finish()
    if not c.truncated and c.pending ~= "" then
      line(c.pending)
      c.pending = ""
    end
    return c.list, c.truncated
  end
  return c
end

-- Walk the tree with Lua, yielding every 50 files when run in a coroutine.
local function walk(root, o)
  local c = { list = {}, truncated = false }
  local seen = 0
  local skip = { [".git"] = true, node_modules = true, [".venv"] = true, target = true, build = true, dist = true }
  local yielding = coroutine.running() ~= nil
  local function visit(dir, rel)
    for name, typ in vim.fs.dir(dir) do
      if seen >= o.max_files or c.truncated then
        return
      end
      local r = rel == "" and name or (rel .. "/" .. name)
      if typ == "directory" then
        if not skip[name] and not name:match("^%.") then
          visit(dir .. "/" .. name, r)
        end
      elseif typ == "file" and not excluded(r, o) then
        seen = seen + 1
        if yielding and seen % 50 == 0 then
          coroutine.yield()
        end
        local path = dir .. "/" .. name
        local st = vim.uv.fs_stat(path)
        if st and st.size < 1024 * 1024 then
          local ok, lines = pcall(vim.fn.readfile, path)
          if ok and not table.concat(lines, "\n", 1, math.min(#lines, 20)):find("\0", 1, true) then
            for i, l in ipairs(lines) do
              for _, kw in ipairs(o.keywords) do
                if l:find(kw, 1, true) then
                  local p = M.parse(l, o)
                  if p then
                    p.rel, p.file, p.lnum, p.line = r, path, i, l
                    c.list[#c.list + 1] = p
                    if #c.list >= o.max_items then
                      c.truncated = true
                      return
                    end
                  end
                  break
                end
              end
            end
          end
        end
      end
    end
  end
  visit(root, "")
  return c.list, c.truncated
end

local function sort(list)
  table.sort(list, function(a, b)
    if a.rel ~= b.rel then
      return a.rel < b.rel
    end
    return a.lnum < b.lnum
  end)
  return list
end

--- The TODO comments under `root`, in file order: `{ file, rel, lnum,
--- line, keyword, arg, id, text }`. Waits for the scan (at most 10 s);
--- the agenda block uses `scan_async`. The second value is true when
--- `todo_max_items` cut the list short.
---@param root string
---@return table[], boolean truncated
function M.scan(root)
  local out
  M.scan_async(root, function(list, truncated)
    out = { list, truncated }
  end)
  vim.wait(10000, function()
    return out ~= nil
  end, 5)
  if not out then
    return {}, false
  end
  return out[1], out[2]
end

--- Scan `root` in the background and call `cb(list, truncated)` on the
--- main loop. The grep process is stopped once `todo_max_items` TODOs are
--- found; the Lua walker yields to the editor every 50 files.
---@param root string
---@param cb fun(list: table[], truncated: boolean)
function M.scan_async(root, cb)
  root = vim.fs.normalize(root)
  local o = snapshot()
  local function lua_walk()
    local co = coroutine.create(function()
      return walk(root, o)
    end)
    local function step()
      local ok, list, truncated = coroutine.resume(co)
      if not ok then
        cb({}, false)
      elseif coroutine.status(co) == "dead" then
        cb(sort(list or {}), truncated or false)
      else
        vim.schedule(step)
      end
    end
    step()
  end
  local how = scanner(root, o)
  if how == "lua" then
    vim.schedule(lua_walk)
    return
  end
  local c = collector(root, o)
  local proc
  local ok = pcall(function()
    proc = vim.system(command(how, o), {
      cwd = root,
      timeout = 60000,
      stdout = function(_, data)
        if c.add(data) and proc then
          pcall(proc.kill, proc, "sigterm")
        end
      end,
    }, function(res)
      vim.schedule(function()
        if c.truncated or res.code == 0 or res.code == 1 then
          local list, truncated = c.finish()
          cb(sort(list), truncated)
        else
          lua_walk()
        end
      end)
    end)
  end)
  if not ok then
    vim.schedule(lua_walk)
  end
end

--- Results of the background scans per repository root: `{ list,
--- truncated, time, running }`.
---@type table<string, table>
M.cache = {}

--- Scans younger than this (ms) are not started again when the block is
--- drawn (the redraw after a scan must not start another one).
M.fresh_ms = 1000

local function signature(list)
  local parts = {}
  for i, t in ipairs(list) do
    parts[i] = t.rel .. ":" .. t.lnum .. ":" .. t.line
  end
  return table.concat(parts, "\n")
end

-- Redraw the agenda when it shows a code_todos block.
local function redraw_agenda()
  local ok, view = pcall(require, "org.agenda.view")
  local S = ok and view.state
  if not (S and S.view and S.buf and vim.api.nvim_buf_is_valid(S.buf)) then
    return
  end
  for _, b in ipairs(S.view.blocks or {}) do
    if b.type == "code_todos" then
      pcall(view.redo)
      return
    end
  end
end

--- The cached TODOs of `root`, starting a background scan when there are
--- none or they are older than `fresh_ms`. nil while the first scan runs.
---@param root string
---@return table|nil entry
function M.cached(root)
  local c = M.cache[root]
  local now = vim.uv.now()
  if c and (c.running or (c.time and now - c.time < M.fresh_ms)) then
    return c.list and c or nil
  end
  c = c or {}
  M.cache[root] = c
  c.running = true
  local gen = (c.gen or 0) + 1
  c.gen = gen
  M.scan_async(root, function(list, truncated)
    if M.cache[root] ~= c or c.gen ~= gen then
      return
    end
    local changed = not c.list or signature(list) ~= c.sig or truncated ~= c.truncated
    c.list, c.truncated, c.sig = list, truncated, signature(list)
    c.time, c.running = vim.uv.now(), false
    if changed then
      redraw_agenda()
    end
  end)
  return c.list and c or nil
end

local order = 0

-- `prefix`: put before the category of a TODO grouped under its heading
local function code_item(t, prefix)
  order = order + 1
  local category = vim.fs.basename(t.rel):gsub("%.[^.]+$", "")
  return {
    type = "code_todo",
    filename = t.file,
    lnum = t.lnum,
    raw = t.line,
    todo = t.keyword,
    title = (t.text ~= "" and t.text or t.keyword) .. "  (" .. t.rel .. ":" .. t.lnum .. ")",
    category = (prefix or "") .. category,
    tags = {},
    done = false,
    level = 0,
    order = order,
    prio = 0,
    urgency = 0,
    code_todo = t,
    -- agenda commands that edit org entries say this instead
    not_org = "A TODO comment in code: <CR> opens it; agenda commands on org entries don't apply",
  }
end

--- The heading a `TODO(org:ID)` names, or nil.
local function heading_for(id, root)
  -- the repository's project file first: it need not be an agenda file
  local ok_pf, pf = pcall(require("org.extensions.code.project").file, root)
  local pfile = ok_pf and pf and vim.uv.fs_stat(pf) and require("org.files").get(pf)
  local hl = pfile and pfile:find_by_id(id)
  if hl then
    return hl
  end
  local ok, loc = pcall(require("org.id").find, id)
  if not ok or not loc or not loc.filename then
    return nil
  end
  local f = require("org.files").get(loc.filename)
  return f and f:find_by_id(id) or nil
end

--- Agenda items for TODOs `list` of `root`: comments naming a heading's
--- ID come first, each group after an item for its heading, then the
--- others.
---@param list table[]
---@param root string
---@return table[]
local function to_items(list, root)
  local groups, group_order, rest = {}, {}, {}
  for _, t in ipairs(list) do
    local hl = t.id and heading_for(t.id, root)
    if hl then
      local key = hl.file.filename .. ":" .. hl.line
      if not groups[key] then
        groups[key] = { hl = hl, todos = {} }
        group_order[#group_order + 1] = key
      end
      table.insert(groups[key].todos, t)
    else
      rest[#rest + 1] = t
    end
  end
  local items_mod = require("org.agenda.items")
  local out = {}
  for _, key in ipairs(group_order) do
    local g = groups[key]
    out[#out + 1] = items_mod.new_item(g.hl, { type = "code_todo_heading" })
    for _, t in ipairs(g.todos) do
      out[#out + 1] = code_item(t, (opts().todo_group_prefix or "↳ "))
    end
  end
  for _, t in ipairs(rest) do
    out[#out + 1] = code_item(t)
  end
  return out
end

--- Agenda items for the TODOs of `root` (scanned now, waiting for it).
---@param root string
---@return table[] items
---@return integer count of TODO comments
---@return boolean truncated
function M.items(root)
  local list, truncated = M.scan(root)
  return to_items(list, root), #list, truncated
end

--- The `code_todos` agenda block type: `{ type = "code_todos", root = dir }`
--- (default root: the current buffer's repository).
function M.source(block)
  if not require("org.extensions").enabled("code") then
    return { error = "The code extension is not enabled (:h org-extensions-code)" }
  end
  local root = block.root and vim.fs.normalize(require("org.utils").expand(block.root))
    or require("org.extensions.code.project").current_root()
  if not root then
    return { error = "code_todos: not in a git repository (set the block's root)" }
  end
  local title = block.title or ("Code TODOs in " .. (git.repo_name(root) or root))
  local entry = M.cached(root)
  if not entry then
    return {
      items = {},
      kind = "todo",
      sorted = true,
      header = { { { title, "OrgAgendaHeader" }, { "  (scanning...)", "OrgAgendaFilter" } } },
    }
  end
  local count = #entry.list .. (entry.truncated and "+" or "")
  return {
    items = to_items(entry.list, root),
    kind = "todo",
    sorted = true,
    header = { { { title, "OrgAgendaHeader" }, { "  (" .. count .. ")", "OrgAgendaFilter" } } },
  }
end

--- `code_todos`: the TODO comments of the current repository in an agenda.
function M.open()
  local root = require("org.extensions.code.project").current_root()
  if not root then
    require("org.utils").warn("Not in a git repository")
    return
  end
  require("org.extensions.code").remember_root(root)
  require("org.agenda").open({ type = "code_todos", root = root })
end

return M
