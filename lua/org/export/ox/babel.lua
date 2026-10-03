---@mod org.export.ox.babel Babel during export (ob-exp): evaluating blocks, {{{results}}}
---
--- Part of org.export.ox, which loads it: the functions are fields of
--- that module.

local M = require("org.export.ox")

local trim = M.trim
local escape_code = M.escape_code

---------------------------------------------------------------------------
-- Babel (ob-exp)
---------------------------------------------------------------------------

local DEFAULT_EXP_CODE_TEMPLATE = "#+begin_src %lang%switches%header-args\n%body\n#+end_src"
local DEFAULT_EXP_INLINE_TEMPLATE = "src_%lang[%switches%header-args]{%body}"

--- org-fill-template: replace each `%key` of `fields`, longest key first.
function M.fill_template(template, fields)
  local keys = vim.tbl_keys(fields)
  table.sort(keys, function(a, b)
    if #a ~= #b then
      return #a > #b
    end
    return a < b
  end)
  for _, k in ipairs(keys) do
    local v = fields[k] or ""
    template = template:gsub("%%" .. vim.pesc(k), function()
      return v
    end)
  end
  return template
end

--- A header value as Emacs prints it with %S: strings quoted, numbers bare.
local function lisp_repr(v)
  if type(v) == "number" or (type(v) == "string" and v:match("^%-?%d+%.?%d*$")) then
    return tostring(v)
  end
  v = tostring(v)
  if v:match('^".*"$') then
    return v
  end
  return '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--- Fields of org-babel-exp-code: %lang %body %switches %header-args %name
--- and %<header argument> for each header argument of the block.
local function exp_code_fields(lang, body, switches, params, name, args)
  local fields = {}
  for k, v in pairs(args or {}) do
    if type(k) == "string" and (type(v) == "string" or type(v) == "number") then
      fields[k] = lisp_repr(v)
    end
  end
  local var = args and args.vars and args.vars[1]
  if var then
    fields.var = string.format("(%s . %s)", var.name, lisp_repr(var.value or ""))
  end
  if args and args.results_order then
    -- the words as org-babel-merge-params orders them (no implied "value")
    fields.results = lisp_repr(table.concat(args.results_order, " "))
  end
  fields.lang = lang or ""
  fields.body = body
  fields.switches = (switches and vim.trim(switches) ~= "") and (" " .. vim.trim(switches)) or ""
  -- a missing field of org-fill-template's alist is filled with ""
  fields.flags = args and args.flags and (" " .. args.flags) or ""
  fields["header-args"] = (params and vim.trim(params) ~= "") and (" " .. vim.trim(params)) or ""
  fields.name = name or ""
  return fields
end
M.exp_code_fields = exp_code_fields

--- Process source blocks, #+CALL lines and inline code for export
--- (org-babel-exp-process-buffer): honour :exports, expand noweb
--- references and drop the code or results as needed.
function M.babel_process(lines, ctx)
  local bcfg = require("org.config").opts.babel or {}
  local code_template = bcfg.exp_code_template or DEFAULT_EXP_CODE_TEMPLATE
  local call_template = bcfg.exp_call_line_template or ""
  local blocks_mod = require("org.babel.blocks")
  local file = require("org.parser").parse(lines, ctx.filename)
  local all_blocks = blocks_mod.parse_blocks(lines)
  local drop = {}
  local replace = {}
  local function in_archived_or_commented(lnum)
    local hl = file:headline_at(lnum)
    while hl do
      if hl:is_archived() then
        return true
      end
      hl = hl.parent
    end
    return false
  end
  for _, b in ipairs(all_blocks) do
    if not in_archived_or_commented(b.start) then
      if b.call then
        local own = blocks_mod.parse_header_string(table.concat(b.header_lines or {}, " ") .. " " .. (b.params or ""))
        local merged = blocks_mod.merge({ vars = {}, results_spec = {} }, own)
        local exports = merged.exports or "results"
        -- org-babel-exp-call-line-template, filled with the call
        local rep = M.fill_template(call_template, {
          line = (lines[b.start]:match("^[ \t]*#%+[Cc][Aa][Ll][Ll]:[ \t]*(.-)[ \t]*$") or ""),
        })
        if rep ~= "" then
          -- the call (and its affiliated #+NAME) is replaced by the text
          local first = b.name_line or b.start
          replace[first] = { finish = b.finish, lines = vim.split(rep, "\n", { plain = true }) }
        else
          -- the call line itself is removed with the blank lines after it
          local last = b.finish
          while lines[last + 1] and lines[last + 1]:match("^[ \t]*$") do
            last = last + 1
          end
          if b.name_line then
            drop[b.name_line] = true
          end
          for k = b.start, last do
            drop[k] = true
          end
        end
        if (exports == "code" or exports == "none") and b.results then
          for k = b.results.start, b.results.finish do
            drop[k] = true
          end
        end
      else
        local args = blocks_mod.header_args(b, file)
        local exports = args.exports or "code"
        local keep_code = exports == "code" or exports == "both"
        local keep_results = exports == "results" or exports == "both"
        if not keep_results and b.results then
          for k = b.results.start, b.results.finish do
            drop[k] = true
          end
        end
        if not keep_code then
          local last = b.finish
          while lines[last + 1] and lines[last + 1]:match("^[ \t]*$") do
            last = last + 1
          end
          -- the block starts at its affiliated keywords (#+NAME, #+HEADER)
          local first = b.start
          local affiliated = { name = true, header = true, headers = true, caption = true, plot = true }
          while lines[first - 1] do
            local key = lines[first - 1]:match("^[ \t]*#%+([%w_]+)[%[:]")
            key = key and key:lower()
            if not key or not (affiliated[key] or key:match("^attr_")) then
              break
            end
            first = first - 1
          end
          for k = first, last do
            drop[k] = true
          end
        else
          -- rewrite the block with org-babel-exp-code-template
          local body = b.body
          local nw = args.noweb or "no"
          if nw == "strip-export" then
            local out = {}
            for i, l in ipairs(body) do
              out[i] = l:gsub("<<[^\n]->>", "")
            end
            body = out
          elseif nw == "yes" or nw == "strip-tangle" then
            local ok, expanded = pcall(require("org.babel").expand_noweb, lines, body, 0, nil, args, "export")
            if ok and expanded then
              body = expanded
            end
          end
          local new
          if code_template == DEFAULT_EXP_CODE_TEMPLATE then
            local head = b.indent
              .. "#+begin_src "
              .. (b.lang or "")
              .. (b.switches and b.switches ~= "" and (" " .. vim.trim(b.switches)) or "")
              .. (b.params and b.params ~= "" and (" " .. vim.trim(b.params)) or "")
            new = { head }
            for _, l in ipairs(escape_code(body)) do
              new[#new + 1] = (l ~= "" and b.indent or "") .. l
            end
            new[#new + 1] = b.indent .. "#+end_src"
          else
            -- org-babel-exp-code-template, indented like the block
            local fields =
              exp_code_fields(b.lang, table.concat(escape_code(body), "\n"), b.switches, b.params, b.name, args)
            new = {}
            for _, l in ipairs(vim.split(M.fill_template(code_template, fields), "\n", { plain = true })) do
              new[#new + 1] = (l ~= "" and b.indent or "") .. l
            end
          end
          replace[b.start] = { finish = b.finish, lines = new }
        end
      end
    end
  end
  local out = {}
  local i = 1
  while i <= #lines do
    local r = replace[i]
    if r and not drop[i] then
      vim.list_extend(out, r.lines)
      i = r.finish + 1
    else
      if not drop[i] then
        out[#out + 1] = lines[i]
      end
      i = i + 1
    end
  end
  -- inline src blocks and inline calls
  local literal = blocks_mod.inline_literal_lines(out)
  for k, l in ipairs(out) do
    if not literal[k] and not l:match("^[ \t]*#%+") and not l:match("^[ \t]*: ") then
      out[k] = M.babel_inline(l)
    end
  end
  return out
end

--- Handle inline src blocks and calls of one line.
function M.babel_inline(l)
  if not (l:find("src_", 1, true) or l:find("call_", 1, true)) then
    return l
  end
  -- only real objects: not text in verbatim, code, link paths... (org-element-context)
  local real = {}
  for _, ib in ipairs(require("org.babel").inline_all(l)) do
    real[ib.s] = true
  end
  local result = {}
  local pos = 1
  local n = #l
  while pos <= n do
    local s1 = l:find("src_", pos, true)
    local s2 = l:find("call_", pos, true)
    local s = (s1 and s2) and math.min(s1, s2) or s1 or s2
    if not s then
      break
    end
    local prev = s > 1 and l:sub(s - 1, s - 1) or ""
    local handled = false
    if real[s] and not prev:match("%w") then
      if l:sub(s, s + 3) == "src_" then
        local lang = l:match("^src_([^ \t%[{]+)", s)
        if lang then
          local k = s + 4 + #lang
          local params = ""
          if l:sub(k, k) == "[" then
            params = l:match("^%b[]", k)
            if params then
              k = k + #params
              params = params:sub(2, -2)
            end
          end
          local body = params and l:match("^%b{}", k)
          if body then
            local e = k + #body
            local args = require("org.babel.blocks").parse_header_string(params)
            local merged = require("org.babel.blocks").merge({ vars = {}, results_spec = {} }, args)
            local exports = merged.exports or "results"
            -- existing result: " {{{results(...)}}}"
            local res = l:match("^[ \t]*{{{results%(.-%)}}}", e)
            local code = "src_" .. lang .. "[" .. params .. "]" .. body
            local itemplate = (require("org.config").opts.babel or {}).exp_inline_code_template
            if itemplate and itemplate ~= DEFAULT_EXP_INLINE_TEMPLATE then
              -- org-babel-exp-inline-code-template
              local iargs = require("org.babel.blocks").header_args(
                { lang = lang, params = params, header_lines = {}, lob = true, start = 1 },
                nil,
                lang,
                { inline = true }
              )
              code = M.fill_template(itemplate, exp_code_fields(lang, body:sub(2, -2), "", params, nil, iargs))
            end
            local rep
            if exports == "results" then
              rep = res and trim(res) or ""
            elseif exports == "code" then
              rep = code
            elseif exports == "both" then
              rep = code .. (res and (" " .. trim(res)) or "")
            else
              rep = ""
            end
            local stop = res and (e + #res) or e
            if rep == "" then
              local ws = l:match("^[ \t]*", stop)
              stop = stop + #ws
            end
            result[#result + 1] = l:sub(pos, s - 1) .. rep
            pos = stop
            handled = true
          end
        end
      else
        local call = l:match("^(call_[^ \t%(%[]+%b[]%b()%b[])", s)
          or l:match("^(call_[^ \t%(%[]+%b()%b[])", s)
          or l:match("^(call_[^ \t%(%[]+%b[]%b())", s)
          or l:match("^(call_[^ \t%(%[]+%b())", s)
        if call then
          local e = s + #call
          local res = l:match("^[ \t]*{{{results%(.-%)}}}", e)
          local hdr = call:match("%b()(%b[])$")
          local exports = "results"
          if hdr then
            local merged = require("org.babel.blocks").merge(
              { vars = {}, results_spec = {} },
              require("org.babel.blocks").parse_header_string(hdr:sub(2, -2))
            )
            exports = merged.exports or "results"
          end
          local rep = ""
          if res and (exports == "results" or exports == "both") then
            rep = trim(res)
          end
          -- org-babel-exp-call-line-template: text before the results
          local ctemplate = (require("org.config").opts.babel or {}).exp_call_line_template or ""
          if ctemplate ~= "" then
            local text = M.fill_template(ctemplate, { line = call })
            rep = rep ~= "" and (text .. " " .. rep) or text
          end
          local stop = res and (e + #res) or e
          if rep == "" then
            local ws = l:match("^[ \t]*", stop)
            stop = stop + #ws
          end
          result[#result + 1] = l:sub(pos, s - 1) .. rep
          pos = stop
          handled = true
        end
      end
    end
    if not handled then
      result[#result + 1] = l:sub(pos, s)
      pos = s + 1
    end
  end
  result[#result + 1] = l:sub(pos)
  return table.concat(result)
end
