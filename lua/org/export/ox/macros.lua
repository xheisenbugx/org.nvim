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
  -- org-macro--find-keyword-value searches the buffer's own text: the
  -- keywords of a #+SETUPFILE don't count (its #+MACRO definitions do)
  local own = ctx.own_keywords or kw
  local function kwval(name, collect)
    local v = own[name]
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
  local function eval_macro(name, t, args)
    if ctx.no_eval then
      -- the live preview exports on every write: no code from the
      -- document runs without being asked for (export.preview.evaluate_babel)
      return "[macro " .. name .. " not evaluated in the preview]"
    end
    local ok = pcall(require("org.table.elisp").read, t)
    local body = ok and t:match("^%(eval(.*)%)%s*$")
    if not body then
      return nil
    end
    local max = 0
    for d in t:gmatch("%$(%d+)") do
      max = math.max(max, tonumber(d))
    end
    local bindings, parts = {}, { body }
    for i = 1, max do
      bindings[i] = { "$" .. i, args[i] }
      parts[#parts + 1] = args[i] or "\1"
    end
    local key = table.concat(parts, "\0")
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
      elseif action and action:match("^%d+$") then
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
        return eval_macro(key, t, args)
      end
      -- org-macro-expand takes (nth (1- N) args): $0 is the first argument
      return (t:gsub("%$(%d+)", function(d)
        return args[math.max(tonumber(d) or 0, 1)] or ""
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

---------------------------------------------------------------------------
-- org-macro-replace-all on the lines
---------------------------------------------------------------------------

--- Whether `lines` hold a macro ("{{{name").
function M.has_macro(lines)
  for _, l in ipairs(lines) do
    if l:find("{{{[%w_%-]") then
      return true
    end
  end
  return false
end

local VERBATIM_BLOCKS = { src = true, example = true, export = true, comment = true }

--- Replace the macros of `lines` by their value before they are parsed,
--- as org-export-as does with org-macro-replace-all: what a macro expands
--- to is parsed with the text around it, so a macro expanding to nothing
--- can leave an empty line (ending a paragraph), stop a line continuing a
--- list item or empty a description tag. Only the macros of text where
--- objects are parsed are replaced here: paragraphs (also in items,
--- drawers, footnote definitions, quote and special blocks), verse
--- blocks, headline titles and table rows, and the values of the parsed
--- keywords (`popts.parsed_keywords`: #+TITLE, #+AUTHOR, ... of the
--- back-end) and of their EXPORT_ node properties, where they are, so
--- {{{n}}} counters follow the document. Other keywords, node properties
--- and {{{results}}} are left to the parser; src, example, export and
--- comment blocks, LaTeX environments, fixed-width and comment lines have
--- no macros.
---@param lines string[]
---@param expander fun(node: table, parser: table): string|nil
---@param popts table element parser options (todo, inlinetask_min_level, alpha, term, parsed_keywords)
---@return string[] lines
---@return boolean changed whether a parsed keyword or EXPORT_ property had macros
function M.replace_all_macros(lines, expander, popts)
  local shared = require("org.export.element.shared")
  local R = element.RESTRICTIONS.paragraph
  local pp = element.new(vim.tbl_extend("force", popts, {
    macro = function(node, p)
      if node.key == "results" then
        -- replaced after Babel (org-export-as's second pass)
        return nil
      end
      return expander(node, p)
    end,
  }))
  local min_inline = popts.inlinetask_min_level or 15
  local n = #lines
  -- the line of the next headline after each line: the end of a block or
  -- a drawer is looked for before it
  local next_hl = {}
  local nh = n + 1
  for i = n, 1, -1 do
    next_hl[i] = nh
    local s = shared.headline_stars(lines[i])
    if s and s < min_inline then
      nh = i
    end
  end
  -- searches that failed, by what was looked for and section: a later
  -- one in the same section fails too
  local failed = {}
  local function find_end(i, key, pred)
    local stop = next_hl[i]
    local fk = key .. "\0" .. stop
    if failed[fk] and failed[fk] < i then
      return nil
    end
    for j = i + 1, stop - 1 do
      if pred(lines[j]) then
        return j
      end
    end
    failed[fk] = i
    return nil
  end
  local out = {}
  local run = {} -- consecutive lines of text, replaced together
  local function flush()
    if #run == 0 then
      return
    end
    local text = table.concat(run, "\n")
    if text:find("{{{", 1, true) then
      text = pp:replace_macros(text, R)
    end
    vim.list_extend(out, vim.split(text, "\n", { plain = true }))
    run = {}
  end
  local function keep(from, to)
    flush()
    for j = from, to or from do
      out[#out + 1] = lines[j]
    end
  end
  -- org-macro-replace-all forces macro recognition in the parsed
  -- keywords and their EXPORT_ node properties
  local parsed = popts.parsed_keywords or {}
  local changed = false
  local function keyword_line(l, prop)
    if not l:find("{{{", 1, true) then
      return nil
    end
    local head, key, rest
    if prop then
      head, key, rest = l:match("^([ \t]*:)(%S-)(:.*)$")
      key = key and key:upper():match("^EXPORT_(.-)%+?$")
    else
      head, key, rest = l:match("^([ \t]*#%+)(%S-)(:.*)$")
    end
    if not (key and parsed[key:upper()]) then
      return nil
    end
    changed = true
    local text = head .. l:sub(#head + 1, #l - #rest) .. ":" .. pp:replace_macros(rest:sub(2), R)
    return vim.split(text, "\n", { plain = true })
  end
  local i = 1
  local meta = false -- right after a headline or its planning line
  while i <= n do
    local l = lines[i]
    local stars = shared.headline_stars(l)
    local after_hl = meta
    meta = false
    local e
    if stars then
      flush()
      if stars < min_inline then
        -- {{{property}}} reads the entry's own properties
        local node = { props = {} }
        pp.scanning = true
        pp:headline_title(node, l, false)
        pp.scanning = false
        pp:headline_meta(node, lines, i, next_hl[i] - 1)
        pp.current_headline = node
        meta = true
      end
      local head, title = l:match("^(%*+%s+)(.*)$")
      local first = #out + 1
      run[1] = title
      flush()
      out[first] = head .. out[first]
      i = i + 1
    elseif l:match("^[ \t]*$") then
      keep(i)
      i = i + 1
    elseif after_hl and shared.is_planning_line(l) then
      keep(i)
      meta = true
      i = i + 1
    elseif after_hl and shared.property_drawer_end(lines, i, next_hl[i] - 1) then
      e = shared.property_drawer_end(lines, i, next_hl[i] - 1)
      keep(i)
      for j = i + 1, e do
        local rep = j < e and keyword_line(lines[j], true)
        if rep then
          vim.list_extend(out, rep)
        else
          out[#out + 1] = lines[j]
        end
      end
      i = e + 1
    else
      local btype = shared.block_type(l)
      local env = shared.latex_env_begin(l)
      if btype then
        local endp = "^[ \t]*#%+[Ee][Nn][Dd]_" .. vim.pesc(btype:lower()) .. "[ \t]*$"
        e = find_end(i, "block " .. btype:lower(), function(x)
          return x:lower():match(endp) ~= nil
        end)
      elseif shared.drawer_name(l) and not shared.is_end_line(l) then
        e = find_end(i, "drawer", shared.is_end_line)
      elseif env then
        local endp = "^[ \t]*\\end{" .. vim.pesc(env) .. "}[ \t]*$"
        e = find_end(i, "env " .. env, function(x)
          return x:match(endp) ~= nil
        end)
      end
      local caption = l:match("^[ \t]*#%+[Cc][Aa][Pp][Tt][Ii][Oo][Nn][%[:]")
      local kw = not caption and not btype and keyword_line(l, false)
      if kw then
        flush()
        vim.list_extend(out, kw)
        i = i + 1
      elseif caption then
        -- a caption is parsed: its macros are objects (org-element-context)
        local head, short, colon, value = l:match("^([ \t]*#%+%a+)(%b[])(:)(.*)$")
        if not head then
          head, colon, value = l:match("^([ \t]*#%+%a+)(:)(.*)$")
          short = ""
        end
        flush()
        if head then
          local function rep(s)
            return s:find("{{{", 1, true) and pp:replace_macros(s, R) or s
          end
          if short ~= "" then
            short = "[" .. rep(short:sub(2, -2)) .. "]"
          end
          vim.list_extend(out, vim.split(head .. short .. colon .. rep(value), "\n", { plain = true }))
        else
          out[#out + 1] = l
        end
        i = i + 1
      elseif e and ((btype and VERBATIM_BLOCKS[btype:lower()]) or env) then
        -- no objects inside
        keep(i, e)
        i = e + 1
      elseif
        e
        or l:match("^[ \t]*#%+")
        or shared.is_comment_line(l)
        or shared.is_fixed_width(l)
        or shared.is_clock_line(l)
        or shared.is_hr(l)
        or shared.is_end_line(l)
        or l:match("^%%%%%(")
      then
        -- a line without objects; for the other blocks and the drawers,
        -- what is between their delimiters is text or other elements
        keep(i)
        i = i + 1
      elseif shared.is_tableel_rule(l) then
        -- a table.el table: no objects
        while i <= n and (shared.is_table_line(lines[i]) or shared.is_tableel_rule(lines[i])) do
          keep(i)
          i = i + 1
        end
      elseif shared.is_table_line(l) then
        -- each row on its own
        flush()
        run[1] = l
        flush()
        i = i + 1
      else
        -- paragraph text: an item or a footnote definition starts a new
        -- run (objects don't span them)
        if shared.item_match(l, popts.alpha, popts.term) or shared.is_footnote_def(l) then
          flush()
        end
        run[#run + 1] = l
        i = i + 1
      end
    end
  end
  flush()
  return out, changed
end
