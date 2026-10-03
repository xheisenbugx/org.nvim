---@mod org.export.ox.macros Macro expansion ({{{name(args)}}})
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local element = require("org.export.element")
local M = require("org.export.ox")

local trim = M.trim
local cfg = M.cfg

---------------------------------------------------------------------------
-- Macros
---------------------------------------------------------------------------

--- Build the macro expander (org-macro-initialize-templates). Returns a
--- function(macro_node, parser) -> expansion string or nil (undefined).
function M.macro_expander(ctx)
  if cfg().replace_macros == false then
    -- org-export-replace-macros = nil: macros stay (and export as nothing);
    -- with Babel, {{{results(...)}}} is still replaced, and like
    -- org-macro-replace-all with only that template, any other macro
    -- aborts the export.
    local babel = (require("org.config").opts.babel or {}).evaluate_on_export
    return function(node)
      if babel then
        if node.key == "results" then
          return (node.args or {})[1] or ""
        end
        error("Undefined Org macro: " .. node.key .. "; aborting", 0)
      end
      return nil
    end
  end
  local kw = ctx.keywords
  local function kwval(name, collect)
    local v = kw[name]
    if not v then
      return nil
    end
    if collect then
      return trim(table.concat(v, " "))
    end
    return v[1]
  end
  local date = kwval("DATE") or ""
  local templates = {}
  -- global macros from config (org-export-global-macros): strings or Lua functions
  for name, v in pairs(cfg().global_macros or {}) do
    templates[name:lower()] = v
  end
  templates.author = kwval("AUTHOR", true) or ""
  templates.email = kwval("EMAIL") or ""
  templates.title = kwval("TITLE", true) or ""
  templates.date = function(fmt)
    if fmt and M.nw(fmt) then
      local d = element.new({}):parse_timestamp(trim(date), 1)
      if d and trim(date) == d.raw_value then
        return M.format_timestamp(d, fmt)
      end
    end
    return date
  end
  for _, def in ipairs(kw.MACRO or {}) do
    local name, body = def:match("^(%S+)[ \t]*(.*)$")
    if name then
      templates[name:lower()] = body
    end
  end
  local counters = {}
  local file = ctx.filename
  -- (eval FORM) templates (org-macro--set-templates): FORM runs with $1..$N
  -- bound to the arguments (strings, nil when missing), N being the
  -- highest $N of the template, on the Lisp interpreter of table formulas
  -- or in a separate Emacs for what it does not implement. The value is
  -- inserted with `format "%s"`; one that can't be evaluated (Emacs stops
  -- the export) is left unexpanded, with a warning.
  local evaluated = {}
  local function eval_macro(t, args)
    local ok = pcall(require("org.table.elisp").read, t)
    local body = ok and t:match("^%(eval(.*)%)%s*$")
    if not body then
      return nil
    end
    local max = 0
    for d in t:gmatch("%$(%d+)") do
      max = math.max(max, tonumber(d))
    end
    local bindings, key = {}, { body }
    for i = 1, max do
      bindings[i] = { "$" .. i, args[i] }
      key[#key + 1] = args[i] or "\1"
    end
    key = table.concat(key, "\0")
    if evaluated[key] == nil then
      local v, err = require("org.babel.elisp").eval(body, {
        bindings = bindings,
        cwd = file and vim.fn.fnamemodify(file, ":p:h") or nil,
        requires = { "org", "ox" },
      })
      if err then
        require("org.utils").warn("Macro " .. t .. ": " .. err)
        evaluated[key] = false
      else
        evaluated[key] = require("org.table.elisp").to_string(v)
      end
    end
    return evaluated[key] or nil
  end
  local builtin = {
    keyword = function(args)
      return kwval((args[1] or ""):upper(), true) or ""
    end,
    n = function(args)
      local name = trim(args[1] or "")
      local action = args[2] and trim(args[2]) or nil
      if not M.nw(action) then
        counters[name] = (counters[name] or 0) + 1
      elseif action == "-" then
        counters[name] = counters[name] or 1
      elseif action:match("^%d+$") then
        counters[name] = tonumber(action)
      else
        counters[name] = 1
      end
      return tostring(counters[name])
    end,
    property = function(args, parser)
      local name = (args[1] or ""):upper()
      if ctx.property_lookup then
        return ctx.property_lookup(name, args[2], parser) or ""
      end
      return ""
    end,
    time = function(args)
      return M.format_time(args[1] or "")
    end,
    results = function(args)
      -- replaced only after Babel ran (org-export-as): without it the
      -- macro stays and exports as nothing (org-export-use-babel nil)
      if ctx.babel == false then
        return nil
      end
      return args[1] or ""
    end,
  }
  if file and vim.fn.filereadable(file) == 1 then
    builtin["input-file"] = function()
      return vim.fn.fnamemodify(file, ":t")
    end
    builtin["modification-time"] = function(args)
      local t = vim.fn.getftime(file)
      if M.nw(args[2]) then
        -- the date of the file's last commit (org-macro--vc-modified-time; Git only)
        local ok, obj = pcall(function()
          local dir = vim.fn.fnamemodify(file, ":p:h")
          return vim.system({ "git", "log", "-1", "--format=%ct", "--", file }, { cwd = dir, text = true }):wait()
        end)
        local vc = ok and obj.code == 0 and tonumber(vim.trim(obj.stdout or ""))
        t = vc or t
      end
      return M.format_time(args[1] or "", t)
    end
  end
  return function(node, parser)
    local key = node.key
    local args = node.args or {}
    local t = templates[key]
    if t ~= nil then
      if type(t) == "function" then
        local ok, v = pcall(t, unpack(args))
        return ok and tostring(v or "") or ""
      end
      if t:match("^%(eval%f[^%w]") then
        return eval_macro(t, args)
      end
      -- org-macro-expand takes (nth (1- N) args): $0 is the first argument
      return (t:gsub("%$(%d+)", function(d)
        return args[math.max(tonumber(d), 1)] or ""
      end))
    end
    local b = builtin[key]
    if b then
      return b(args, parser)
    end
    -- org-macro-replace-all: an unknown macro stops the export
    error("Undefined Org macro: " .. key .. "; aborting", 0)
  end
end
