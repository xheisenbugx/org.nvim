---@mod org.babel.vars :var values: references, tables, disassembling
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local lisp = require("org.babel.lisp")
local utils = require("org.utils")

local M = require("org.babel")
-- P.evaluate_ref comes from org.babel.evaluate, which loads after this file
local P = require("org.babel.internal")

local buf_lines = M.buf_lines
local get_file = M.get_file
local in_commented = M.in_commented

---------------------------------------------------------------------------
-- Variables
---------------------------------------------------------------------------

--- Index a value like org-babel-ref-index-list: `2`, `-1`, `1:3`, `` or
--- `*` (everything), one portion per dimension separated by commas; a
--- one-element result is unwrapped. Indices are 0-based and count every
--- row, the header and hlines included.
function M.index_value(value, index)
  index = index or ""
  if index == "" or not lisp.is_list(value) then
    return value
  end
  local portion, remainder = index:match("^([^,]*),?(.*)$")
  portion = vim.trim(portion)
  local n = #value
  local function wrap(i)
    return i < 0 and n + i or i
  end
  local picked = {}
  local a, b = portion:match("^(%-?%d*):(%-?%d*)$")
  if portion == "" or portion == "*" or a then
    local from = (a and a ~= "") and wrap(tonumber(a)) or 0
    local to = (b and b ~= "") and wrap(tonumber(b)) or (n - 1)
    for k = from, to do
      picked[#picked + 1] = value[k + 1] == nil and {} or value[k + 1]
    end
  else
    local k = wrap(tonumber(portion) or 0)
    picked[1] = value[k + 1] == nil and {} or value[k + 1]
  end
  local mapped = {}
  for i, sub in ipairs(picked) do
    mapped[i] = lisp.is_list(sub) and M.index_value(sub, remainder) or sub
  end
  if #mapped == 1 then
    return mapped[1]
  end
  return mapped
end

--- `org-babel-get-colnames`: (table without names, names).
local function get_colnames(t)
  local i = 1
  while t[i] == "hline" do
    i = i + 1
  end
  if t[i + 1] == "hline" then
    return vim.list_slice(t, i + 2), t[i]
  end
  return vim.list_slice(t, i + 1), t[i]
end

--- Take :colnames / :rownames / :hlines into account for the table values
--- of `vars` (org-babel-disassemble-tables). The names found are recorded
--- in `meta.colnames` / `meta.rownames` as { name, names } pairs.
function M.disassemble(vars, args, meta)
  meta = meta or {}
  meta.colnames = meta.colnames or {}
  meta.rownames = meta.rownames or {}
  local colnames, rownames, hlines = args.colnames, args.rownames, args.hlines
  for _, var in ipairs(vars) do
    local t = var.value
    if lisp.is_list(t) and #t > 0 then
      local take
      if colnames ~= "no" then
        if colnames == nil or colnames == "nil" then
          take = #t > 1 and t[1] ~= "hline" and t[2] == "hline" and not vim.tbl_contains(vim.list_slice(t, 3), "hline")
        else
          take = true
        end
      end
      if take then
        local rest, names = get_colnames(t)
        meta.colnames[#meta.colnames + 1] = { var.name, names }
        t = rest
      end
      if rownames and rownames ~= "no" then
        local rows, names = {}, {}
        for _, r in ipairs(t) do
          if r ~= "hline" then
            if lisp.is_list(r) then
              names[#names + 1] = r[1] == nil and {} or r[1]
              rows[#rows + 1] = vim.list_slice(r, 2)
            else
              names[#names + 1] = {}
              rows[#rows + 1] = r
            end
          end
        end
        meta.rownames[#meta.rownames + 1] = { var.name, names }
        t = rows
      end
      if hlines and hlines ~= "yes" then
        local rows = {}
        for _, r in ipairs(t) do
          if r ~= "hline" then
            rows[#rows + 1] = r
          end
        end
        t = rows
      end
      var.value = t
    end
  end
  return vars, meta
end

--- `org-babel-pick-name`: the names a result gets back.
local function pick_name(names, selector)
  if selector == nil then
    return nil
  end
  local s = vim.trim(selector)
  if s:match("^'?%(") or s == "nil" then
    local ok, v = pcall(lisp.read, s)
    if ok and lisp.is_list(v) then
      local out = {}
      for i, x in ipairs(v) do
        out[i] = lisp.princ(x)
      end
      return #out > 0 and out or nil
    end
    return nil
  end
  if not names or #names == 0 then
    return nil
  end
  local n = tonumber(s)
  if n then
    local e = names[n]
    return e and e[2] or nil
  end
  return names[#names][2]
end

--- Re-attach column / row names to a table result
--- (org-babel-reassemble-table with org-babel-pick-name).
function M.reassemble(value, args, meta)
  if not lisp.is_list(value) then
    return value
  end
  meta = meta or {}
  local colnames = pick_name(meta.colnames, args.colnames)
  local rownames = pick_name(meta.rownames, args.rownames)
  local out = value
  if rownames and #value == #rownames then
    out = {}
    local k = 0
    for i, r in ipairs(value) do
      if lisp.is_list(r) then
        k = k + 1
        local row = { rownames[k] ~= nil and rownames[k] or "" }
        vim.list_extend(row, r)
        out[i] = row
      else
        out[i] = r
      end
    end
  end
  if colnames and lisp.is_list(out[1]) and #out[1] == #colnames then
    local t = { colnames, "hline" }
    vim.list_extend(t, out)
    out = t
  end
  return out
end

--- Split a reference `name[header](args)[index]` like org-babel-ref-resolve.
---@return { name: string, header?: string, call?: string, index?: string, contents?: boolean }
function M.parse_ref(ref)
  local r = {}
  local head, idx = ref:match("^(.-)(%[[^%[]*%])$")
  if head and head ~= "" then
    local _, opens = head:gsub("%(", "")
    local _, closes = head:gsub("%)", "")
    if opens == closes then
      local inner = idx:sub(2, -2)
      if inner == "" then
        r.contents = true
      else
        r.index = inner
      end
      ref = head
    end
  end
  local name, hdr, call = ref:match("^(.-)(%b[])%((.*)%)$")
  if not name or name == "" then
    hdr = nil
    name, call = ref:match("^(.-)%((.*)%)$")
  end
  if name and name ~= "" then
    r.call = call
    r.header = hdr and hdr:sub(2, -2) or nil
    ref = name
  end
  r.name = vim.trim(ref)
  return r
end

--- Directory a buffer's code runs in by default (the file's directory).
local function buf_dir(bufnr)
  if type(bufnr) ~= "number" then
    return vim.fn.getcwd()
  end
  local dir = vim.b[bufnr].org_babel_dir
  if dir then
    return dir
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
end
M.buf_dir = buf_dir

local dedent = blocks_mod.dedent

--- Value of the element at line `k` (org-babel-read-element): a table
--- (rows of read cells and "hline"), the top-level items of a list, the
--- text of a fixed-width area (a number when it is one), the contents of
--- a block, or the text of a paragraph (a lone file link gives the file's
--- contents).
local function read_element(lines, k, bufnr)
  local last, kind = blocks_mod.element_end(lines, k)
  local el = vim.list_slice(lines, k, last)
  if kind == "table" then
    local rows = {}
    for _, l in ipairs(el) do
      if l:match("^%s*|%-") then
        rows[#rows + 1] = "hline"
      elseif l:match("^%s*|") then
        local cells = {}
        for j, c in ipairs(require("org.table").split_cells(l)) do
          cells[j] = lisp.read(c, true)
        end
        rows[#rows + 1] = cells
      end
    end
    return rows
  elseif kind == "list" then
    local indent = #el[1]:match("^(%s*)")
    local items = {}
    for _, l in ipairs(el) do
      local ind, text = l:match("^(%s*)[-+*] (.*)$")
      if not ind then
        ind, text = l:match("^(%s*)%d+[.)] (.*)$")
      end
      if ind and #ind == indent then
        items[#items + 1] = lisp.read((text:gsub("^%[.%] ", "")), true)
      end
    end
    return items
  elseif kind == "fixed-width" then
    local out = {}
    for i, l in ipairs(el) do
      out[i] = l:match("^%s*: (.*)$") or ""
    end
    local v = vim.trim(table.concat(out, "\n"))
    return lisp.string_to_number(v) or v
  elseif kind == "src" or kind == "example" or kind == "export" then
    local body = blocks_mod.unescape(vim.list_slice(el, 2, #el - 1))
    local preserve = kind ~= "export"
      and (el[1]:match("%s%-i%f[%s%z]") or require("org.config").opts.src_preserve_indentation)
    return table.concat(preserve and body or dedent(body), "\n") .. (#body > 0 and "\n" or "")
  elseif kind == "special" or kind == "quote" or kind == "center" or kind == "verse" then
    return table.concat(dedent(vim.list_slice(el, 2, #el - 1)), "\n") .. (#el > 2 and "\n" or "")
  elseif kind == "drawer" then
    return table.concat(vim.list_slice(el, 2, #el - 1), "\n") .. (#el > 2 and "\n" or "")
  elseif kind == "paragraph" then
    local text = table.concat(el, "\n")
    local link = vim.trim(text):match("^%[%[([^%]]+)%]%]$") or vim.trim(text):match("^%[%[([^%]]+)%]%[[^%]]*%]%]$")
    if link then
      local path = link:match("^file:(.*)$") or (not link:match("^%a[%w+.-]*:") and link:match("^[/~.]") and link)
      if path then
        path = path:gsub("::.*$", "")
        local full = utils.expand(path, buf_dir(bufnr))
        local content = utils.readfile(full)
        if content then
          return table.concat(content, "\n") .. "\n"
        end
      end
      return link
    end
    return text .. "\n"
  end
  return nil
end
M.read_element = read_element

--- Body text of the headline with ID or CUSTOM_ID `id` (after its
--- planning line and property drawer), or nil. With `local_only` other
--- files are not searched.
local function headline_body(bufnr, id, local_only)
  local file, lines, hl = get_file(bufnr), nil, nil
  for _, h in ipairs(file and file.headlines or {}) do
    if h.properties and (h.properties.ID == id or h.properties.CUSTOM_ID == id) then
      hl, lines = h, buf_lines(bufnr)
      break
    end
  end
  if not hl and local_only then
    return nil
  end
  if not hl then
    local ok, found = pcall(require("org.id").find, id)
    if not ok or not found then
      return nil
    end
    hl = found.headline
    lines = found.bufnr and buf_lines(found.bufnr) or utils.readfile(found.filename)
    if not hl or not lines then
      return nil
    end
  end
  local k = hl.line + 1
  local last = hl.end_line or #lines
  if lines[k] and lines[k]:match("^%s*[A-Z]+:%s*[<%[]") then
    k = k + 1
  end
  if lines[k] and lines[k]:match("^%s*:PROPERTIES:%s*$") then
    while k <= last and not lines[k]:match("^%s*:END:%s*$") do
      k = k + 1
    end
    k = k + 1
  end
  return table.concat(vim.list_slice(lines, k, last), "\n")
end

M.headline_body = headline_body

--- Resolve a :var value to a Babel value like org-babel-ref-parse: a
--- number, a "string", a Lisp form (evaluated), or a reference
--- (org-babel-ref-resolve). References to src blocks and #+CALL lines
--- evaluate them. The value is not yet disassembled (:colnames ...).
---@param opts? { depth?: integer, skip_confirm?: boolean }
function M.resolve_var(bufnr, raw, args, meta, opts)
  opts = opts or {}
  raw = vim.trim(raw or "")
  if raw == "" then
    return {}
  end
  if raw == "*this*" then
    local has, this = M.current_this()
    if has then
      return this
    end
  end
  local ok, out = pcall(lisp.read, raw)
  if not ok and raw:match("^[(`']") and require("org.babel.elisp").command() then
    -- a form the interpreter does not implement: evaluate it in Emacs
    local v, err = require("org.babel.elisp").eval(raw, { requires = { "org" } })
    ok, out = err == nil, err or lisp.from_elisp(v)
  end
  if not ok then
    error("cannot evaluate " .. raw .. ": " .. tostring(out), 0)
  end
  if out ~= raw then
    return out
  end
  local q = raw:match('^"(.*)"$')
  if q then
    return (q:gsub('\\"', '"'))
  end
  local ref = M.parse_ref(raw)
  local value = M.resolve_ref(bufnr, ref, args, meta, opts)
  if ref.index and lisp.is_list(value) then
    value = M.index_value(value, ref.index)
  end
  return value
end

--- Value of the element named by `ref` (see `M.parse_ref`).
function M.resolve_ref(bufnr, ref, args, meta, opts)
  local name = ref.name
  -- file.org:name refers to another file
  local fpart, rest = name:match("^(.+):([^:]+)$")
  if fpart and type(bufnr) == "number" then
    local path = utils.expand(fpart, buf_dir(bufnr))
    if utils.exists(path) then
      bufnr = utils.load_buffer(path)
      name = rest
    end
  end
  local lines = buf_lines(bufnr)
  local file = get_file(bufnr)
  local all = blocks_mod.parse_blocks(lines)
  for i, l in ipairs(lines) do
    local nm = l:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$")
    if nm == name and not in_commented(file, i) then
      local k = i + 1
      while lines[k] and lines[k]:match("^%s*#%+[%w_]+:") and not lines[k]:match("^%s*#%+[Cc][Aa][Ll][Ll]:") do
        k = k + 1
      end
      for _, b in ipairs(all) do
        if b.start == k then
          if ref.contents then
            return table.concat(b.body, "\n") .. "\n"
          end
          return P.evaluate_ref(bufnr, b, ref, file, opts)
        end
      end
      local v = read_element(lines, k, bufnr)
      if v == nil then
        error("Reference not found", 0)
      end
      return v
    end
  end
  local body = headline_body(bufnr, name)
  if body then
    return body
  end
  if M.library[name] then
    local b = vim.deepcopy(M.library[name])
    if ref.contents then
      return table.concat(b.body, "\n") .. "\n"
    end
    return P.evaluate_ref(bufnr, b, ref, nil, opts)
  end
  error("Reference `" .. name .. "' not found in this buffer", 0)
end

--- Resolve the `:var` values of `args` and disassemble their tables
--- (org-babel-process-params); names found go to `meta`.
local function resolve_vars(bufnr, args, meta, opts)
  local out = {}
  for _, v in ipairs(args.vars or {}) do
    out[#out + 1] = { name = v.name, value = M.resolve_var(bufnr, v.value, args, meta, opts) }
  end
  M.disassemble(out, args, meta)
  return out
end
M.resolve_vars = resolve_vars
