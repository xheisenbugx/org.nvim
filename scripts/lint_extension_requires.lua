-- The org modules each extension depends on, against a baseline that only
-- shrinks. Run it with
--
--   nvim --headless --clean -l scripts/lint_extension_requires.lua
--
-- (`make lint` does). An extension reads and changes Org data through
-- org.api (`:h org-api`), whose functions and fields stay within a major
-- version; every other `org.*` module is internal and can change in any
-- release, so an extension that requires one breaks with it and isn't
-- something a third party could have written.
--
-- A dependency is any string in an extension's code (comments left out)
-- that names an org module, a file under lua/: a `require("org.files")`,
-- `pcall(require, "org.files")`, a require through an alias
-- (`local req = require` ... `req("org.files")`), a module name kept in a
-- local, `org.lazy`'s `on_load("org.agenda.render", ...)`, the module of an
-- action. Allowed for extension `<name>` (lua/org/extensions/<name>.lua or
-- lua/org/extensions/<name>/):
--
--   org.api and org.api.*           the public API
--   org.extensions                  the extension registry
--   org.extensions.views_util       the shared code of the built-in views
--   org.extensions.<name>(.*)       its own modules
--
-- Every other one is a pair `<name> <module>` that must be in
-- scripts/extension_requires.txt, the dependencies extensions had when the
-- check came in (views_util's own count too: shared code is no way around
-- it). The check fails on a pair missing from the list (a new internal
-- dependency: use org.api, or extend it) and on a listed pair no longer
-- found (delete its line: the list only shrinks). lua/org/extensions/init.lua
-- is the registry itself, part of the core: not checked.

local M = {}

M.BASELINE = "scripts/extension_requires.txt"

--- The string literals of Lua source `src`, comments left out:
--- `{ value, line }` in order. Escapes are kept as written (a module name
--- has none).
---@param src string
---@return { [1]: string, [2]: integer }[]
function M.strings(src)
  local out = {}
  local i, n, line = 1, #src, 1
  local function newlines(s)
    local _, k = s:gsub("\n", "\n")
    return k
  end
  while i <= n do
    local j = src:find("[\n%-\"'%[]", i)
    if not j then
      break
    end
    local c = src:sub(j, j)
    if c == "\n" then
      line = line + 1
      i = j + 1
    elseif c == "-" then
      if src:sub(j, j + 1) == "--" then
        local lvl = src:match("^%[(=*)%[", j + 2)
        if lvl then
          local close = "]" .. lvl .. "]"
          local e = src:find(close, j + 4 + #lvl, true) or n
          line = line + newlines(src:sub(j, e))
          i = e + #close
        else
          i = src:find("\n", j, true) or n + 1
        end
      else
        i = j + 1
      end
    elseif c == "[" then
      local lvl = src:match("^%[(=*)%[", j)
      if lvl then
        local s = j + 2 + #lvl
        local close = "]" .. lvl .. "]"
        local e = src:find(close, s, true) or n + 1
        local body = src:sub(s, e - 1)
        out[#out + 1] = { body, line }
        line = line + newlines(body)
        i = e + #close
      else
        i = j + 1
      end
    else
      -- a quoted string: up to the same quote not escaped, or the line end
      local k = j + 1
      local parts = {}
      while k <= n do
        local d = src:sub(k, k)
        if d == "\\" then
          parts[#parts + 1] = src:sub(k, k + 1)
          if src:sub(k + 1, k + 1) == "\n" then
            line = line + 1
          end
          k = k + 2
        elseif d == c or d == "\n" then
          break
        else
          parts[#parts + 1] = d
          k = k + 1
        end
      end
      out[#out + 1] = { table.concat(parts), line }
      i = k + 1
    end
  end
  return out
end

--- Is `name` an org module: a file lua/<name>.lua or lua/<name>/init.lua
--- under `root`?
local function is_module(root, name, cache)
  local v = cache[name]
  if v == nil then
    local path = root .. "/lua/" .. name:gsub("%.", "/")
    v = vim.uv.fs_stat(path .. ".lua") ~= nil or vim.uv.fs_stat(path .. "/init.lua") ~= nil
    cache[name] = v
  end
  return v
end

--- The extension a file under lua/org/extensions/ belongs to (`rel` is the
--- path from there), or nil for the registry (init.lua).
---@param rel string
---@return string|nil
function M.extension_of(rel)
  if rel == "init.lua" then
    return nil
  end
  return rel:match("^([^/]+)/") or rel:match("^(.+)%.lua$")
end

--- May extension `ext` depend on module `mod`?
---@param ext string
---@param mod string
---@return boolean
function M.allowed(ext, mod)
  if mod == "org.api" or vim.startswith(mod, "org.api.") then
    return true
  end
  if mod == "org.extensions" or mod == "org.extensions.views_util" then
    return true
  end
  local own = "org.extensions." .. ext
  return mod == own or vim.startswith(mod, own .. ".")
end

--- The dependencies of the extensions under `root` (the repository) that
--- aren't allowed: `{ [ "<ext> <module>" ] = "file:line" }` (the first
--- place each is found).
---@param root string
---@return table<string, string>
function M.scan(root)
  local base = root .. "/lua/org/extensions"
  local files = {}
  for name, t in vim.fs.dir(base, { depth = math.huge }) do
    if t == "file" and name:match("%.lua$") then
      files[#files + 1] = name
    end
  end
  table.sort(files)
  local found, cache = {}, {}
  for _, rel in ipairs(files) do
    local ext = M.extension_of(rel)
    if ext then
      local f = assert(io.open(base .. "/" .. rel, "rb"))
      local src = f:read("*a")
      f:close()
      for _, s in ipairs(M.strings(src)) do
        local mod = s[1]
        if mod:match("^org%.[%w_]+[%w_%.]*$") and not M.allowed(ext, mod) and is_module(root, mod, cache) then
          local key = ext .. " " .. mod
          found[key] = found[key] or ("lua/org/extensions/" .. rel .. ":" .. s[2])
        end
      end
    end
  end
  return found
end

--- The pairs of a baseline text (`<ext> <module>` lines; `#` comments and
--- blank lines left out).
---@param text string
---@return table<string, true>
function M.parse_baseline(text)
  local out = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    l = vim.trim(l)
    if l ~= "" and not l:match("^#") then
      local ext, mod = l:match("^(%S+)%s+(%S+)$")
      out[ext and (ext .. " " .. mod) or l] = true
    end
  end
  return out
end

--- The problems of `found` (from `scan`) against `baseline` (from
--- `parse_baseline`): new dependencies and listed ones no longer found.
---@param found table<string, string>
---@param baseline table<string, true>
---@return string[]
function M.check(found, baseline)
  local out = {}
  local keys = vim.tbl_keys(found)
  table.sort(keys)
  for _, key in ipairs(keys) do
    if not baseline[key] then
      local ext, mod = key:match("^(%S+) (%S+)$")
      out[#out + 1] = string.format(
        "%s: extension %s depends on the internal module %s: read and change Org data through org.api"
          .. " (:h org-api), extending the API when it lacks something, instead of a new internal dependency",
        found[key],
        ext,
        mod
      )
    end
  end
  local listed = vim.tbl_keys(baseline)
  table.sort(listed)
  for _, key in ipairs(listed) do
    if not found[key] then
      out[#out + 1] =
        string.format("%s: %q is no longer a dependency: delete its line (the list only shrinks)", M.BASELINE, key)
    end
  end
  return out
end

if arg and arg[0] and arg[0]:match("lint_extension_requires%.lua$") then
  local root = vim.fs.normalize(vim.fn.fnamemodify(arg[0], ":p:h:h"))
  local found = M.scan(root)
  if arg[1] == "--print" then
    -- the pairs as the baseline lists them (for a new baseline)
    local keys = vim.tbl_keys(found)
    table.sort(keys)
    io.stdout:write(table.concat(keys, "\n"), "\n")
    os.exit(0)
  end
  local f = io.open(root .. "/" .. M.BASELINE, "rb")
  local baseline = M.parse_baseline(f and f:read("*a") or "")
  if f then
    f:close()
  end
  local problems = M.check(found, baseline)
  for _, p in ipairs(problems) do
    io.stdout:write(p, "\n")
  end
  if #problems > 0 then
    io.stdout:write(#problems, " extension dependency problem(s)\n")
    os.exit(1)
  end
  os.exit(0)
end

return M
