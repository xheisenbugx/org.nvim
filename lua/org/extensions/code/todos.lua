---@mod org.extensions.code.todos TODO comments of a repository in the agenda
---
--- The `code_todos` agenda block type lists comments like `TODO: text`,
--- `FIXME(bob): text` or `TODO(org:ID): text` found with `git grep`
--- (else `rg`, else a limited walk of the tree). `<CR>` on one opens the
--- code line; comments naming a heading's ID are grouped under it.

local git = require("org.extensions.code.git")

local M = {}

local function opts()
  return require("org.extensions").opts("code") or require("org.extensions.code").defaults
end

local function keywords()
  return opts().todo_keywords or { "TODO", "FIXME" }
end

--- Parse a line for a TODO comment: `{ keyword, arg, id, text, col }` or nil.
---@param line string
---@return table|nil
function M.parse(line)
  local o = opts()
  local best
  for _, kw in ipairs(keywords()) do
    local init = 1
    while true do
      local s, e = line:find("%f[%w_]" .. vim.pesc(kw) .. "%f[^%w_]", init)
      if not s then
        break
      end
      local after = line:sub(e + 1, e + 1)
      local before = line:sub(1, s - 1)
      local commented = not o.todo_require_comment
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
  local id = arg and arg:match(o.todo_link_pattern or "^org:%s*(.-)%s*$") or nil
  return {
    keyword = best.keyword,
    arg = arg,
    id = id ~= "" and id or nil,
    text = vim.trim(text),
    col = best.col,
  }
end

local function excluded(rel)
  for _, pat in ipairs(opts().todo_exclude or {}) do
    if rel:match(pat) then
      return true
    end
  end
  return false
end

local function run(cmd, cwd)
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, cwd = cwd }):wait(10000)
  end)
  if not ok or not res then
    return nil
  end
  -- grep tools exit 1 when nothing matches
  if res.code ~= 0 and res.code ~= 1 then
    return nil
  end
  return res.stdout or ""
end

local function grep_lines(out)
  local list = {}
  for l in out:gmatch("[^\n]+") do
    local path, lnum, text = l:match("^(.-):(%d+):(.*)$")
    if path then
      list[#list + 1] = { rel = path, lnum = tonumber(lnum), line = text }
    end
  end
  return list
end

local function scanner(root)
  local want = opts().todo_scanner or "auto"
  local is_git = vim.uv.fs_stat(root .. "/.git") ~= nil
  if (want == "auto" or want == "git") and is_git and vim.fn.executable("git") == 1 then
    return "git"
  elseif (want == "auto" or want == "rg") and vim.fn.executable("rg") == 1 then
    return "rg"
  end
  return "lua"
end

-- the regexp of the keywords for git grep / rg (ERE)
local function alternation()
  local parts = {}
  for _, kw in ipairs(keywords()) do
    parts[#parts + 1] = kw:gsub("[%^%$%(%)%.%[%]%*%+%?{}|\\]", "\\%0")
  end
  return table.concat(parts, "|")
end

local function walk(root)
  local list = {}
  local max_files = opts().todo_max_files or 2000
  local seen = 0
  local skip = { [".git"] = true, node_modules = true, [".venv"] = true, target = true, build = true, dist = true }
  local function visit(dir, rel)
    for name, typ in vim.fs.dir(dir) do
      if seen >= max_files then
        return
      end
      local r = rel == "" and name or (rel .. "/" .. name)
      if typ == "directory" then
        if not skip[name] and not name:match("^%.") then
          visit(dir .. "/" .. name, r)
        end
      elseif typ == "file" and not excluded(r) then
        seen = seen + 1
        local path = dir .. "/" .. name
        local st = vim.uv.fs_stat(path)
        if st and st.size < 1024 * 1024 then
          local ok, lines = pcall(vim.fn.readfile, path)
          if ok and not table.concat(lines, "\n", 1, math.min(#lines, 20)):find("\0", 1, true) then
            for i, l in ipairs(lines) do
              for _, kw in ipairs(keywords()) do
                if l:find(kw, 1, true) then
                  list[#list + 1] = { rel = r, lnum = i, line = l }
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
  return list
end

--- The TODO comments under `root`, in file order: `{ file, rel, lnum,
--- line, keyword, arg, id, text }`.
---@param root string
---@return table[]
function M.scan(root)
  root = vim.fs.normalize(root)
  local how = scanner(root)
  local raw
  if how == "git" then
    local out = run({ "git", "grep", "-n", "-I", "--untracked", "-w", "-E", alternation() }, root)
    raw = out and grep_lines(out)
  elseif how == "rg" then
    local out = run({ "rg", "-n", "--no-heading", "--color", "never", "-w", "-e", alternation(), "." }, root)
    raw = out and grep_lines(out)
    for _, r in ipairs(raw or {}) do
      r.rel = r.rel:gsub("^%./", "")
    end
  end
  raw = raw or walk(root)
  local out = {}
  local max = opts().todo_max_items or 500
  for _, r in ipairs(raw) do
    if not excluded(r.rel) then
      local p = M.parse(r.line)
      if p then
        p.rel = r.rel
        p.file = root .. "/" .. r.rel
        p.lnum = r.lnum
        p.line = r.line
        out[#out + 1] = p
        if #out >= max then
          break
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.rel ~= b.rel then
      return a.rel < b.rel
    end
    return a.lnum < b.lnum
  end)
  return out
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
  }
end

--- The heading a `TODO(org:ID)` names, or nil.
local function heading_for(id, root)
  -- the repository's project file first: it need not be an agenda file
  local pf = require("org.extensions.code.project").file(root)
  local pfile = pf and vim.uv.fs_stat(pf) and require("org.files").get(pf)
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

--- Agenda items for the TODOs of `root`: comments naming a heading's ID
--- come first, each group after an item for its heading, then the others.
---@param root string
---@return table[] items, integer count of TODO comments
function M.items(root)
  local list = M.scan(root)
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
  return out, #list
end

--- The `code_todos` agenda block type: `{ type = "code_todos", root = dir }`
--- (default root: the current buffer's repository).
function M.source(block)
  if not require("org.extensions").enabled("code") then
    return { error = "The code extension is not enabled (:h org-extensions-code)" }
  end
  local root = block.root and vim.fs.normalize(block.root)
    or require("org.extensions.code.project").current_root()
  if not root then
    return { error = "code_todos: not in a git repository (set the block's root)" }
  end
  local items, count = M.items(root)
  local title = block.title or ("Code TODOs in " .. (git.repo_name(root) or root))
  return {
    items = items,
    kind = "todo",
    sorted = true,
    header = { { { title, "OrgAgendaHeader" }, { string.format("  (%d)", count), "OrgAgendaFilter" } } },
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
