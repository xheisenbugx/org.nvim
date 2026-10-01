---@mod org.extensions.literate Literate Neovim configuration
---
--- Enable with `setup({ extensions = { literate = { files = {
--- "~/.config/nvim/init.org" } } } })` (see `:h org-extensions-literate`).
--- Saving a literate org file tangles it and runs the Lua blocks whose
--- text changed since the last tangle, so an option or a keymap changes at
--- once; errors show as diagnostics on the block's line in the org file.
---
--- Trust: saving runs Lua and writes the tangled files, so only files you
--- chose do it: the ones in `files`, and with `detect` org files that
--- tangle their Lua blocks and live under a directory of `allow` (asked
--- once per file with `confirm`). Opening a file never runs or evaluates
--- anything.

local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.literate")
local augroup = vim.api.nvim_create_augroup("org.literate", { clear = true })

M.defaults = {
  --- Org files (paths or globs) that are always literate (trusted).
  files = { vim.fn.stdpath("config") .. "/init.org" },
  --- Also treat as literate the org files whose Lua blocks tangle by
  --- default (`#+PROPERTY: header-args:lua :tangle FILE`), when they are
  --- under a directory of `allow`.
  detect = true,
  --- Directories (paths or globs) where `detect` looks. An org file
  --- elsewhere is never tangled or run on save unless it is in `files`.
  allow = { vim.fn.stdpath("config") },
  --- Ask before the first save that would tangle and run a detected file;
  --- the answer is kept in stdpath("data")/org/literate-trust.json.
  confirm = true,
  --- Tangle literate files when they are written.
  tangle_on_save = true,
  --- After tangling, run the Lua blocks whose text changed since the last
  --- tangle (in file order).
  reload = true,
  --- Show errors of blocks as diagnostics in the org buffer.
  diagnostics = true,
  --- Also put the errors in the quickfix list.
  quickfix = false,
  --- Report what was tangled and reloaded.
  notify = true,
  --- The init.lua `literate_bootstrap` writes without an argument: next to
  --- the org file.
  bootstrap_file = nil,
}

M.actions = {
  literate_reload = {
    "org.extensions.literate",
    "reload",
    desc = "Literate config: run the Lua block at point (or every tangled Lua block)",
  },
  literate_run_block = {
    "org.extensions.literate",
    "run_block",
    desc = "Literate config: run the Lua block at point in this Neovim and show its value",
  },
  literate_health = {
    "org.extensions.literate",
    "health_check",
    desc = "Literate config: check that every Lua block compiles",
  },
  literate_bootstrap = {
    "org.extensions.literate",
    "bootstrap",
    desc = "Literate config: write an init.lua that tangles the org file when it is newer",
  },
  literate_goto_org = {
    "org.extensions.literate",
    "goto_org",
    desc = "Literate config: jump from a tangled Lua line to its org block",
    global = true,
  },
}

M.commands = {
  literate_bootstrap = {
    "org.extensions.literate",
    "bootstrap",
    desc = "Write an init.lua stub that tangles an org file: :Org literate_bootstrap [init.lua path]",
    -- a path: the files and directories that start with the argument
    complete = function(arglead)
      local items = vim.fn.getcompletion(arglead, "file")
      if arglead == "" then
        table.insert(items, 1, vim.fn.fnamemodify(vim.fn.stdpath("config") .. "/init.lua", ":~"))
      end
      return items
    end,
  },
}

local function opts()
  return require("org.extensions").opts("literate") or M.defaults
end

---------------------------------------------------------------------------
-- Which files
---------------------------------------------------------------------------

local function buf_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

local function real(p)
  return utils.realpath(p) or p
end

--- Does glob or path `pat` (normalized) name `path` (whose real path is `rp`)?
local function names(pat, path, rp)
  if pat == path or real(pat) == rp then
    return true
  end
  if pat:find("[%*%?%[{]") then
    for _, f in ipairs(vim.fn.glob(pat, false, true)) do
      if real(vim.fs.normalize(f)) == rp then
        return true
      end
    end
  end
  return false
end

--- Is `path` one of the configured `files`?
local function configured(path)
  local rp = real(path)
  for _, pat in ipairs(opts().files or {}) do
    if names(vim.fs.normalize(pat), path, rp) then
      return true
    end
  end
  return false
end

--- Is `path` under one of the `allow` directories?
local function allowed(path)
  local rp = real(path)
  for _, pat in ipairs(opts().allow or {}) do
    local e = vim.fs.normalize(pat)
    local dirs = e:find("[%*%?%[{]") and vim.fn.glob(e, false, true) or { e }
    for _, d in ipairs(dirs) do
      local rd = real(vim.fs.normalize(d)):gsub("/+$", "")
      if rp:sub(1, #rd + 1) == rd .. "/" or path:sub(1, #d + 1) == d .. "/" then
        return true
      end
    end
  end
  return false
end

--- Does the buffer set `:tangle` for Lua blocks in a PROPERTY line?
local function tangles_lua(bufnr)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find("^%s*#%+") then
      local args = l:match("^%s*#%+[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Yy]:%s+header%-args:lua%s+(.*)$")
      local t = args and args:match(":tangle%s+(%S+)")
      if t and t ~= "no" then
        return true
      end
    end
  end
  return false
end

--- How `bufnr` is literate: "configured" (in `files`), "detected" (tangles
--- its Lua blocks, under `allow`), or nil.
---@param bufnr? integer
---@return "configured"|"detected"|nil
function M.kind(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= "org" then
    return nil
  end
  local path = buf_path(bufnr)
  if path and configured(path) then
    return "configured"
  end
  if opts().detect ~= false and path and allowed(path) and tangles_lua(bufnr) then
    return "detected"
  end
  return nil
end

--- Is `bufnr` a literate org buffer?
---@param bufnr? integer
---@return boolean
function M.is_literate(bufnr)
  return M.kind(bufnr) ~= nil
end

---------------------------------------------------------------------------
-- Trust
---------------------------------------------------------------------------

--- File keeping the answers of `confirm`: real path -> true/false.
function M.trust_file()
  return vim.fn.stdpath("data") .. "/org/literate-trust.json"
end

local trust_db

local function trust_table()
  if not trust_db then
    trust_db = {}
    local ok, lines = pcall(vim.fn.readfile, M.trust_file())
    if ok and #lines > 0 then
      local dok, t = pcall(vim.json.decode, table.concat(lines, "\n"))
      if dok and type(t) == "table" then
        trust_db = t
      end
    end
  end
  return trust_db
end

local function remember_trust(rp, yes)
  local t = trust_table()
  t[rp] = yes
  vim.fn.mkdir(vim.fs.dirname(M.trust_file()), "p")
  pcall(vim.fn.writefile, { vim.json.encode(t) }, M.trust_file())
end

--- May saving `bufnr` tangle and run its Lua? Configured files may; a
--- detected one when you said so (asked the first time with `confirm`).
---@param bufnr integer
---@return boolean
function M.trusted(bufnr)
  local kind = M.kind(bufnr)
  if kind == "configured" then
    return true
  elseif kind ~= "detected" then
    return false
  end
  if opts().confirm == false then
    return true
  end
  local rp = real(buf_path(bufnr))
  local known = trust_table()[rp]
  if known ~= nil then
    return known
  end
  local yes = utils.confirm(
    string.format(
      "org literate: tangle %s and run its changed Lua blocks on every save? (remembered)",
      vim.fn.fnamemodify(rp, ":~")
    )
  ) and true or false
  remember_trust(rp, yes)
  if not yes then
    utils.notify("Not tangled or run on save; add it to `files` or edit " .. vim.fn.fnamemodify(M.trust_file(), ":~"))
  end
  return yes
end

---------------------------------------------------------------------------
-- Blocks
---------------------------------------------------------------------------

--- The Lua blocks of `bufnr` that tangle, in file order: `{ block, body,
--- target }` (the body as tangled: noweb expanded, dedented).
---@param bufnr integer
---@return table[]
function M.lua_blocks(bufnr)
  local ok, groups, order = pcall(require("org.babel.tangle").collect, bufnr, { lang_re = "^lua$" })
  if not ok then
    return {}
  end
  local out = {}
  for _, target in ipairs(order) do
    for _, spec in ipairs(groups[target]) do
      out[#out + 1] = { block = spec.block, body = spec.body, target = target }
    end
  end
  table.sort(out, function(a, b)
    return a.block.start < b.block.start
  end)
  return out
end

--- Every `lua` src block of `bufnr` (tangled or not), `{ block, body }`.
local function all_lua_blocks(bufnr)
  local out = {}
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, b in ipairs(require("org.babel.blocks").parse_blocks(lines)) do
    if not b.call and b.lang == "lua" then
      out[#out + 1] = { block = b, body = table.concat(b.body, "\n") }
    end
  end
  return out
end

-- The text that identifies a Lua block: its #+begin_src line and body as
-- written (no noweb or variable expansion, so nothing is evaluated).
local function raw_key(lines, b)
  return (lines[b.start] or "") .. "\n" .. table.concat(b.body, "\n")
end

--- What the blocks of each buffer were at the last tangle (or when the
--- file was opened): `raw` holds the raw keys of every Lua block, `tangled`
--- the tangled bodies (known after the first tangle).
---@type table<integer, { raw: table<string, boolean>, tangled?: table<string, boolean> }>
M.baseline = {}

-- Taken when a literate file is opened: the raw blocks only. Collecting
-- the tangled bodies would expand noweb and :var references, which can
-- evaluate blocks.
local function remember(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local raw = {}
  for _, b in ipairs(require("org.babel.blocks").parse_blocks(lines)) do
    if not b.call then
      raw[raw_key(lines, b)] = true
    end
  end
  M.baseline[bufnr] = { raw = raw }
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

--- Run one block's Lua. Returns ok, value or the error `{ lnum, message }`
--- with `lnum` the org line of the error.
---@param bufnr integer
---@param spec { block: table, body: string }
---@return boolean ok, any value_or_error
function M.run_spec(bufnr, spec)
  local b = spec.block
  local name = "org:" .. vim.fn.fnamemodify(buf_path(bufnr) or "buffer", ":t") .. ":" .. b.start
  -- `line`: the line in the block's chunk (from the stack when the error
  -- was raised in a function it called)
  local function where(msg, line)
    msg = tostring(msg)
    line = line or tonumber(msg:match(vim.pesc(name) .. ":(%d+):"))
    local lnum = line and (b.start + line) or b.start
    lnum = math.max(b.start, math.min(lnum, b.finish))
    -- the position prefix of the message ("file:12: ")
    local clean =
      msg:gsub("^" .. vim.pesc(name) .. ":%d+:%s*", ""):gsub("^%[string .-%]:%d+:%s*", ""):gsub("^[^%s:]+:%d+:%s*", "")
    return { lnum = lnum, message = clean }
  end
  local chunk, err = loadstring(spec.body, "=" .. name)
  if not chunk then
    return false, where(err)
  end
  local res = {
    xpcall(chunk, function(e)
      for level = 2, 60 do
        local info = debug.getinfo(level, "Sl")
        if not info then
          break
        end
        if info.source == "=" .. name then
          return { e, info.currentline }
        end
      end
      return { e }
    end),
  }
  if not res[1] then
    return false, where(res[2][1], res[2][2])
  end
  return true, res[2]
end

--- Show `errors` (`{ lnum, message }`) as diagnostics and in the quickfix
--- list; none clears them.
---@param bufnr integer
---@param errors table[]
function M.report(bufnr, errors)
  local o = opts()
  if o.diagnostics ~= false then
    local diags = {}
    for _, e in ipairs(errors) do
      diags[#diags + 1] = {
        lnum = e.lnum - 1,
        col = 0,
        severity = vim.diagnostic.severity.ERROR,
        message = e.message,
        source = "literate",
      }
    end
    vim.diagnostic.set(ns, bufnr, diags)
  end
  if o.quickfix and #errors > 0 then
    local items = {}
    for _, e in ipairs(errors) do
      items[#items + 1] = { bufnr = bufnr, lnum = e.lnum, text = e.message, type = "E" }
    end
    vim.fn.setqflist({}, " ", { title = "org literate", items = items })
  end
end

--- Run `specs` in order; returns the number run and the errors.
local function run_all(bufnr, specs)
  local errors, ran = {}, 0
  for _, s in ipairs(specs) do
    local okr, res = M.run_spec(bufnr, s)
    ran = ran + 1
    if not okr then
      errors[#errors + 1] = res
      s.failed = true
    end
  end
  return ran, errors
end

local function summary(ran, errors)
  local s = string.format("reloaded %d changed Lua block%s", ran, ran == 1 and "" or "s")
  if #errors > 0 then
    s = s .. string.format(", %d error%s (line %d)", #errors, #errors == 1 and "" or "s", errors[1].lnum)
  end
  return s
end

--- Tangle `bufnr` and run its changed Lua blocks (the BufWritePost handler).
---@param bufnr integer
---@return { tangled: string[], ran: integer, errors: table[] }
function M.on_save(bufnr)
  local o = opts()
  local written = require("org.babel.tangle").tangle({ bufnr = bufnr, silent = true })
  local result = { tangled = written, ran = 0, errors = {} }
  if o.reload ~= false then
    local base = M.baseline[bufnr] or { raw = {} }
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- blocks whose text is new, and the names among them (a block that
    -- includes one with <<name>> changes too)
    local new_raw, new_names = {}, {}
    local raw = {}
    for _, b in ipairs(require("org.babel.blocks").parse_blocks(lines)) do
      if not b.call then
        local key = raw_key(lines, b)
        raw[key] = true
        if not base.raw[key] then
          new_raw[b.start] = true
          if b.name and b.name ~= "" then
            new_names[#new_names + 1] = b.name
          end
        end
      end
    end
    local function includes_new(spec)
      for _, name in ipairs(new_names) do
        for _, l in ipairs(spec.block.body) do
          if l:find("<<" .. name, 1, true) then
            return true
          end
        end
      end
      return false
    end
    local changed = {}
    local specs = M.lua_blocks(bufnr)
    for _, s in ipairs(specs) do
      local is_new = new_raw[s.block.start]
        or (base.tangled and not base.tangled[s.body])
        or (not base.tangled and includes_new(s))
      if is_new then
        changed[#changed + 1] = s
      end
    end
    result.ran, result.errors = run_all(bufnr, changed)
    M.report(bufnr, result.errors)
    -- failed blocks stay "changed" and run again on the next save
    local tangled = {}
    for _, s in ipairs(specs) do
      if not s.failed then
        tangled[s.body] = true
      end
    end
    for _, s in ipairs(changed) do
      if s.failed then
        tangled[s.body] = nil
        raw[raw_key(lines, s.block)] = nil
      end
    end
    M.baseline[bufnr] = { raw = raw, tangled = tangled }
  else
    remember(bufnr)
  end
  if o.notify ~= false then
    local names = vim.tbl_map(function(p)
      return vim.fn.fnamemodify(p, ":t")
    end, written)
    local msg = "Tangled " .. (#names > 0 and table.concat(names, ", ") or "nothing")
    if o.reload ~= false then
      msg = msg .. "; " .. summary(result.ran, result.errors)
    end
    -- after the write message, instead of a hit-enter prompt below it
    vim.schedule(function()
      utils.notify(msg, #result.errors > 0 and vim.log.levels.WARN or nil)
    end)
  end
  return result
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function lua_block_at(bufnr, lnum)
  for _, s in ipairs(all_lua_blocks(bufnr)) do
    if lnum >= s.block.start and lnum <= s.block.finish then
      -- the tangled body when the block tangles (noweb expanded)
      for _, t in ipairs(M.lua_blocks(bufnr)) do
        if t.block.start == s.block.start then
          return t
        end
      end
      return s
    end
  end
  return nil
end

--- `literate_reload`: run the Lua block at point, or every tangled Lua
--- block of the file.
function M.reload()
  if not utils.ensure_org() then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local at = lua_block_at(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  local specs = at and { at } or M.lua_blocks(bufnr)
  if #specs == 0 then
    utils.warn("No Lua blocks to run")
    return
  end
  local ran, errors = run_all(bufnr, specs)
  M.report(bufnr, errors)
  local msg = string.format("Ran %d Lua block%s", ran, ran == 1 and "" or "s")
  if #errors > 0 then
    msg = msg .. string.format(": %d error%s", #errors, #errors == 1 and "" or "s")
  end
  utils.notify(msg, #errors > 0 and vim.log.levels.WARN or nil)
  return ran, errors
end

--- `literate_run_block`: run the Lua block at point now and show its value.
function M.run_block()
  if not utils.ensure_org() then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local s = lua_block_at(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not s then
    utils.warn("Not in a Lua src block")
    return
  end
  local okr, res = M.run_spec(bufnr, s)
  if okr then
    M.report(bufnr, {})
    utils.notify(res == nil and "Lua block ran" or ("=> " .. vim.inspect(res)))
  else
    M.report(bufnr, { res })
    utils.warn(string.format("Line %d: %s", res.lnum, res.message))
  end
  return okr, res
end

--- `literate_health`: compile every Lua block (without running it) and show
--- the syntax errors as diagnostics.
---@return table[] errors
function M.health_check()
  if not utils.ensure_org() then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local tangled = {}
  for _, t in ipairs(M.lua_blocks(bufnr)) do
    tangled[t.block.start] = t
  end
  local errors, count = {}, 0
  for _, s in ipairs(all_lua_blocks(bufnr)) do
    local spec = tangled[s.block.start] or s
    count = count + 1
    local name = "org:" .. s.block.start
    local _, err = loadstring(spec.body, "=" .. name)
    if err then
      local line = tostring(err):match(vim.pesc(name) .. ":(%d+):")
      local lnum = line and (s.block.start + tonumber(line)) or s.block.start
      errors[#errors + 1] = {
        lnum = math.min(lnum, s.block.finish),
        message = tostring(err):gsub("^" .. vim.pesc(name) .. ":%d+:%s*", ""),
      }
    end
  end
  M.report(bufnr, errors)
  if #errors == 0 then
    utils.notify(string.format("%d Lua block%s compile", count, count == 1 and "" or "s"))
  else
    utils.warn(string.format("%d of %d Lua blocks do not compile", #errors, count))
  end
  return errors
end

---------------------------------------------------------------------------
-- Bootstrap
---------------------------------------------------------------------------

-- The init.lua `literate_bootstrap` writes. `__ORG__`, `__OUT__` (quoted
-- paths) and `__ORG_SHOWN__`, `__OUT_SHOWN__` are replaced. It runs before
-- any plugin, so it holds its own small tangler.
local STUB = [==[
-- Generated by org.nvim (:Org literate_bootstrap). Your configuration lives
-- in __ORG_SHOWN__; saving it in Neovim tangles it to __OUT_SHOWN__.
-- On startup this tangles the org file again when it is newer than the
-- tangled file (edited elsewhere, or pulled), then loads the tangled file.
local org = __ORG__
local out = __OUT__
local uv = vim.uv or vim.loop

-- A small tangler (org.nvim is not loaded yet): the lua blocks whose
-- :tangle (from the block, else the nearest heading's header-args:lua /
-- header-args property, else #+PROPERTY) is this file, with <<name>>
-- references expanded when :noweb is yes, tangle, no-export or
-- strip-export. Saving the org file in Neovim uses the full tangle.
local function tangle()
  local dir = vim.fn.fnamemodify(org, ":h")
  local file = { generic = "", lua = "" }
  local stack, drawer, name, cur = {}, nil, nil, nil
  local blocks, named = {}, {}
  local function prop(t, k, v)
    k = k:lower()
    if k == "header-args" or k == "header-args+" then
      t.generic = (k:sub(-1) == "+" and t.generic .. " " or "") .. v
    elseif k == "header-args:lua" or k == "header-args:lua+" then
      t.lua = (k:sub(-1) == "+" and t.lua .. " " or "") .. v
    end
  end
  local function nearest(kind)
    for i = #stack, 1, -1 do
      if stack[i][kind] ~= "" then
        return stack[i][kind]
      end
    end
    return file[kind]
  end
  local function lookup(args, lang, key)
    local pat = ":" .. key .. "%s+([^%s]+)"
    local v = args:match(pat)
    if not v and lang == "lua" then
      v = nearest("lua"):match(pat)
    end
    return v or nearest("generic"):match(pat)
  end
  for line in io.lines(org) do
    if cur then
      if line:match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") then
        blocks[#blocks + 1] = cur
        if cur.name then
          named[cur.name] = cur
        end
        cur = nil
      else
        cur.body[#cur.body + 1] = (line:gsub("^(%s*),([*#])", "%1%2"))
      end
    else
      local stars = line:match("^(%*+)%s")
      local pk, pv = line:match("^%s*#%+[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Yy]:%s+(%S+)%s*(.-)%s*$")
      local dk, dv = line:match("^%s*:(%S-):%s+(.-)%s*$")
      if stars then
        while #stack > 0 and stack[#stack].level >= #stars do
          table.remove(stack)
        end
        stack[#stack + 1] = { level = #stars, generic = "", lua = "" }
        drawer, name = nil, nil
      elseif line:match("^%s*:[Pp][Rr][Oo][Pp][Ee][Rr][Tt][Ii][Ee][Ss]:%s*$") and #stack > 0 then
        drawer = stack[#stack]
      elseif drawer and line:match("^%s*:[Ee][Nn][Dd]:%s*$") then
        drawer = nil
      elseif drawer and dk then
        prop(drawer, dk, dv)
      elseif pk then
        prop(file, pk, pv)
      elseif line:match("^%s*#%+[Nn][Aa][Mm][Ee]:") then
        name = line:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$")
      else
        local lang, args = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]%s+(%S+)(.*)$")
        if lang then
          cur = {
            lang = lang,
            name = name,
            tangle = lookup(args, lang, "tangle"),
            noweb = lookup(args, lang, "noweb"),
            body = {},
          }
          name = nil
        end
        if not line:match("^%s*#%+") then
          name = nil
        end
      end
    end
  end
  local function target(t)
    t = t and t:gsub('^"(.*)"$', "%1")
    if not t or t == "no" or t == "nil" then
      return nil
    elseif t == "yes" then
      return vim.fn.fnamemodify(org, ":r") .. ".lua"
    end
    -- copied into the bootstrap init.lua, so no org.utils: / or a drive
    local abs = t:match("^/") or t:match("^%a:[/\\]")
    return vim.fn.fnamemodify(abs and t or (dir .. "/" .. vim.fn.expand(t)), ":p")
  end
  local want = vim.fn.fnamemodify(out, ":p")
  local NOWEB = { yes = true, tangle = true, ["no-export"] = true, ["strip-export"] = true }
  local function expand(b, depth)
    if depth > 10 or not NOWEB[b.noweb or ""] then
      return b.body
    end
    local res = {}
    for _, l in ipairs(b.body) do
      local pre, ref, post = l:match("^(.-)<<([^%s<>()]+)>>(.*)$")
      local inc = ref and named[ref]
      if inc then
        local sub = expand(inc, depth + 1)
        for i, s in ipairs(sub) do
          res[#res + 1] = pre .. s .. (i == #sub and post or "")
        end
      else
        res[#res + 1] = l
      end
    end
    return res
  end
  local lines = {}
  for _, b in ipairs(blocks) do
    if b.lang == "lua" and target(b.tangle) == want then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      vim.list_extend(lines, expand(b, 0))
    end
  end
  vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
  vim.fn.writefile(lines, out)
end

local function newer(a, b)
  return a.mtime.sec > b.mtime.sec or (a.mtime.sec == b.mtime.sec and a.mtime.nsec > b.mtime.nsec)
end

local so, st = uv.fs_stat(org), uv.fs_stat(out)
if so and (not st or newer(so, st)) then
  local ok, err = pcall(tangle)
  if not ok then
    vim.notify("Tangling " .. org .. " failed: " .. tostring(err), vim.log.levels.WARN)
  end
end
if uv.fs_stat(out) then
  dofile(out)
end
]==]

--- The file the Lua blocks of `bufnr` tangle to (the first one), or nil.
local function lua_target(bufnr)
  local specs = M.lua_blocks(bufnr)
  return specs[1] and specs[1].target or nil
end

--- `literate_bootstrap`: write an init.lua that tangles the current org file
--- on startup when it is newer than its tangled file, then loads it.
---@param path? string the init.lua to write (default: next to the org file)
---@return string|nil path written
function M.bootstrap(path)
  if not utils.ensure_org() then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local org = buf_path(bufnr)
  if not org then
    utils.warn("Save the org file first")
    return
  end
  local out = lua_target(bufnr)
  if not out then
    utils.warn("No Lua block of this file tangles (add #+PROPERTY: header-args:lua :tangle lua/config.lua)")
    return
  end
  path = path and vim.trim(path) ~= "" and vim.trim(path) or opts().bootstrap_file
  path = path and vim.fs.normalize(path) or (vim.fs.dirname(org) .. "/init.lua")
  if vim.fs.normalize(out) == path then
    utils.warn("The Lua blocks tangle to " .. path .. " itself: tangle them to another file (lua/config.lua)")
    return
  end
  if vim.uv.fs_stat(path) and not utils.confirm(path .. " exists. Overwrite it?") then
    return
  end
  local subst = {
    __ORG__ = string.format("%q", org),
    __OUT__ = string.format("%q", out),
    __ORG_SHOWN__ = vim.fn.fnamemodify(org, ":~"),
    __OUT_SHOWN__ = vim.fn.fnamemodify(out, ":~"),
  }
  local text = STUB:gsub("__[%u_]+__", function(k)
    return subst[k]
  end)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  utils.notify("Wrote " .. vim.fn.fnamemodify(path, ":~"))
  return path
end

---------------------------------------------------------------------------
-- Back from the tangled file
---------------------------------------------------------------------------

--- Is the org file `p` literate and trusted, without asking? (Reading
--- which blocks tangle where expands header arguments, which may evaluate
--- Lisp: only for files you chose.)
local function trusted_path(p)
  if configured(p) then
    return true
  end
  local o = opts()
  if o.detect == false or not allowed(p) then
    return false
  end
  if o.confirm ~= false and trust_table()[real(p)] ~= true then
    return false
  end
  local ok, lines = pcall(vim.fn.readfile, p, "", 200)
  return ok and table.concat(lines, "\n"):find("header%-args:lua") ~= nil
end

--- Org files that may have tangled `path`, among the trusted literate
--- ones: the configured files, the loaded org buffers and the org files
--- next to it and up to two levels up.
local function candidates(path)
  local list, seen = {}, {}
  local function add(p)
    p = vim.fs.normalize(p)
    if not seen[real(p)] and vim.uv.fs_stat(p) then
      seen[real(p)] = true
      if trusted_path(p) then
        list[#list + 1] = p
      end
    end
  end
  for _, pat in ipairs(opts().files or {}) do
    for _, f in ipairs(vim.fn.glob(vim.fs.normalize(pat), false, true)) do
      add(f)
    end
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "org" and buf_path(b) then
      add(buf_path(b))
    end
  end
  local dir = vim.fs.dirname(path)
  for _, d in ipairs({ dir, vim.fs.dirname(dir), vim.fs.dirname(vim.fs.dirname(dir)) }) do
    for _, f in ipairs(vim.fn.glob(d .. "/*.org", false, true)) do
      add(f)
    end
  end
  return list
end

--- `literate_goto_org`: from a line of a tangled Lua file to the org
--- block it came from (by the link comments of `:comments link`, else by
--- matching the line's text in the blocks that tangle to this file).
function M.goto_org()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = buf_path(bufnr)
  if not path then
    utils.warn("Not a file")
    return
  end
  local tangle = require("org.babel.tangle")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  for _, p in ipairs(tangle.comment_pairs(lines)) do
    if p.start < lnum and lnum < p.finish then
      return tangle.jump_to_org()
    end
  end
  local want = vim.trim(lines[lnum] or "")
  -- the occurrence of the text among equal lines above, to pick the same one
  local nth = 0
  for i = 1, lnum do
    if vim.trim(lines[i]) == want then
      nth = nth + 1
    end
  end
  local rp = real(path)
  local best
  for _, org in ipairs(candidates(path)) do
    local obuf = utils.find_buffer(org) or utils.load_buffer(org)
    local matches = {}
    for _, s in ipairs(M.lua_blocks(obuf)) do
      if real(s.target) == rp then
        for i, l in ipairs(s.block.body_raw or {}) do
          if vim.trim(l) == want then
            matches[#matches + 1] = { buf = obuf, lnum = s.block.start + i }
          end
        end
      end
    end
    if #matches == 0 and want ~= "" then
      -- a line a noweb reference brought in: the block it comes from
      for _, s in ipairs(all_lua_blocks(obuf)) do
        for i, l in ipairs(s.block.body_raw or s.block.body or {}) do
          if vim.trim(l) == want then
            matches[#matches + 1] = { buf = obuf, lnum = s.block.start + i }
          end
        end
      end
    end
    best = matches[nth] or matches[1]
    if best then
      break
    end
  end
  if not best then
    utils.warn("No org block tangles this line")
    return
  end
  vim.cmd("normal! m'")
  local wins = vim.fn.win_findbuf(best.buf)
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[1])
  else
    vim.api.nvim_win_set_buf(0, best.buf)
  end
  vim.api.nvim_win_set_cursor(0, { best.lnum, 0 })
  pcall(require("org.fold").reveal_cursor, "link-search")
  return best
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function M.setup(o)
  vim.api.nvim_clear_autocmds({ group = augroup })
  M.baseline = {}
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "FileType" }, {
    group = augroup,
    callback = function(ev)
      if not M.baseline[ev.buf] and vim.bo[ev.buf].filetype == "org" then
        -- only text is read here; a failure just leaves no baseline
        pcall(function()
          if M.is_literate(ev.buf) then
            remember(ev.buf)
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(ev)
      M.baseline[ev.buf] = nil
    end,
  })
  if o.tangle_on_save ~= false then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = augroup,
      callback = function(ev)
        if vim.bo[ev.buf].filetype ~= "org" then
          return
        end
        local ok, err = pcall(function()
          if not M.trusted(ev.buf) then
            return
          end
          if not M.baseline[ev.buf] then
            remember(ev.buf)
          end
          M.on_save(ev.buf)
        end)
        if not ok then
          utils.warn("literate: " .. tostring(err))
        end
      end,
    })
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and M.is_literate(b) then
      remember(b)
    end
  end
end

function M.teardown()
  vim.api.nvim_clear_autocmds({ group = augroup })
  trust_db = nil
  -- every buffer: literate_run_block reports in any org buffer
  vim.diagnostic.reset(ns)
  M.baseline = {}
end

function M.health(h, o)
  local found = 0
  for _, pat in ipairs(o.files or {}) do
    for _, f in ipairs(vim.fn.glob(vim.fs.normalize(pat), false, true)) do
      found = found + 1
      h.ok("literate file: " .. vim.fn.fnamemodify(f, ":~"))
    end
  end
  if found == 0 then
    h.info("none of `files` exists")
  end
  if o.detect ~= false then
    local dirs = vim.tbl_map(function(d)
      return vim.fn.fnamemodify(vim.fs.normalize(d), ":~")
    end, o.allow or {})
    if #dirs == 0 then
      h.info("`allow` is empty: only `files` are literate")
    else
      local ask = o.confirm ~= false and " (asked once per file)" or ""
      h.info("org files with header-args:lua :tangle under " .. table.concat(dirs, ", ") .. " are literate" .. ask)
    end
  end
  if o.tangle_on_save == false then
    h.info("tangle_on_save is off: tangle with :Org tangle")
  end
end

--- The diagnostic namespace (for tests and statuslines).
M.ns = ns

return M
