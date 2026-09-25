---@mod org.babel Source block evaluation, tangling and editing
---
--- Evaluation runs asynchronously via `vim.system` (Lua blocks run inside
--- Neovim). Results are written below the block as `#+RESULTS:`.

local blocks_mod = require("org.babel.blocks")
local langs = require("org.babel.langs")
local lisp = require("org.babel.lisp")
local results = require("org.babel.results")
local session_mod = require("org.babel.session")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.babel")

M.parse_blocks = blocks_mod.parse_blocks
M.parse_header_string = blocks_mod.parse_header_string
M.dedent = blocks_mod.dedent

local function buf_lines(bufnr)
  if type(bufnr) == "table" then
    return bufnr -- a list of lines (export)
  end
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function resolve_buf(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function get_file(bufnr)
  if type(bufnr) == "table" then
    return require("org.parser").parse(bufnr)
  end
  local ok, f = pcall(function()
    return require("org.files").get_buffer(bufnr)
  end)
  return ok and f or nil
end
M.buf_lines = buf_lines
M.get_file = get_file

--- Block containing `lnum` (begin line .. end line, the #+NAME/#+HEADER
--- lines above it, or its #+RESULTS), or a #+CALL line. Returns nil otherwise.
function M.at_block(bufnr, lnum)
  bufnr = resolve_buf(bufnr)
  local lines = buf_lines(bufnr)
  local line = lines[lnum] or ""
  -- quick reject: must be inside something that looks like a block
  local list = blocks_mod.parse_blocks(lines)
  for _, b in ipairs(list) do
    local top = b.start
    local k = b.start - 1
    while k >= 1 and lines[k]:match("^%s*#%+[%a_]+:") and not lines[k]:match("^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]") do
      top = k
      k = k - 1
    end
    if lnum >= top and lnum <= b.finish then
      b.file = get_file(bufnr)
      b.args = M.block_args(b, b.file, bufnr)
      return b
    end
    if b.results and lnum >= b.results.start and lnum <= b.results.finish and not b.call then
      b.file = get_file(bufnr)
      b.args = M.block_args(b, b.file, bufnr)
      return b
    end
  end
  local _ = line
  return nil
end

--- Header args of a call (#+CALL line or inline `call_`) of `target`,
--- merged like org-babel-lob-get-info: the target's header args, then
--- `babel.default_lob_header_args`, the properties at the call, the inside
--- header `[...]`, the arguments (positional ones fill the target's
--- variables in order) and the end header.
---@param call { start: integer, inside?: string, call_args?: string, params?: string }
function M.call_header_args(target, call, file)
  local cfg = require("org.config").opts.babel or {}
  local state = { pos = 0 }
  local args = blocks_mod.header_args(target, not target.lob and file or nil, nil, { no_finish = true, state = state })
  blocks_mod.merge(args, blocks_mod.dict_pairs(cfg.default_lob_header_args or { exports = "results" }), state)
  if file then
    local lang = target.lang
    blocks_mod.merge(args, M.parse_header_string(blocks_mod.inherited_property(file, call.start, "HEADER-ARGS")), state)
    if lang and lang ~= "" then
      local p = blocks_mod.inherited_property(file, call.start, "HEADER-ARGS:" .. lang)
      blocks_mod.merge(args, M.parse_header_string(p), state)
    end
  end
  blocks_mod.merge(args, M.parse_header_string(call.inside or ""), state)
  blocks_mod.merge(args, blocks_mod.call_args(call.call_args or ""), state)
  blocks_mod.merge(args, M.parse_header_string(call.params or ""), state)
  return blocks_mod.finish(args)
end

--- Merged header args for a block (resolving #+CALL targets).
function M.block_args(b, file, bufnr)
  if b.call then
    local lines = buf_lines(bufnr)
    local target = M.find_named_block(lines, b.target)
    if not target then
      return nil
    end
    local args = M.call_header_args(target, {
      start = b.start,
      inside = table.concat(b.header_lines, " "),
      call_args = b.call_args,
      params = b.params,
    }, file)
    return args, target
  end
  return blocks_mod.header_args(b, file)
end

function M.find_named_block(lines, name)
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if not b.call and b.name == name then
      return b
    end
  end
  if M.library[name] then
    return vim.deepcopy(M.library[name])
  end
end

---------------------------------------------------------------------------
-- Noweb
---------------------------------------------------------------------------

--- Is `lnum` inside a COMMENT headline (or one of its descendants)?
local function in_commented(file, lnum)
  local hl = file and file:headline_at(lnum)
  while hl do
    if hl.commented then
      return true
    end
    hl = hl.parent
  end
  return false
end
M.in_commented = in_commented

local function noweb_for(args, purpose)
  local v = args.noweb or "no"
  if purpose == "eval" then
    local expand = {
      yes = true,
      eval = true,
      ["no-export"] = true,
      ["strip-export"] = true,
      ["tangle-eval"] = true,
      ["strip-tangle"] = true,
    }
    return expand[v] and "expand" or nil
  elseif purpose == "tangle" then
    if v == "strip-tangle" then
      return "strip"
    end
    return (v == "yes" or v == "tangle" or v == "no-export" or v == "strip-export" or v == "tangle-eval") and "expand"
      or nil
  elseif purpose == "export" then
    if v == "strip-export" then
      return "strip"
    end
    return (v == "yes" or v == "strip-tangle") and "expand" or nil
  end
end

--- Library of Babel: named blocks ingested from other files (`lob_ingest`).
M.library = {}

--- Expansion (list of lines) of the noweb reference `ref`.
local function noweb_reference(bufnr, ref, depth, purpose, ctx, parent_args)
  if ref:find("%(.*%)") then
    -- <<name(args)>>: the result of evaluating the named block with args
    local ok, v = pcall(M.resolve_var, bufnr, ref, {}, {}, { skip_confirm = ctx.skip_confirm })
    if not ok then
      if type(bufnr) == "number" and (purpose or "eval") == "eval" then
        error("noweb <<" .. ref .. ">>: " .. tostring(v), 0)
      end
      utils.warn("noweb <<" .. ref .. ">>: " .. tostring(v))
      return { "" }
    end
    if type(v) ~= "string" then
      v = lisp.prin1(v)
    end
    return vim.split(v, "\n", { plain = true })
  end
  -- :comments noweb wraps each expansion in link comments (ob-tangle)
  local comment = parent_args and parent_args.comments == "noweb" and purpose == "tangle"
  local function body_of(b, args, named)
    local nw = noweb_for(args, purpose or "eval")
    local body = b.body
    if nw then
      body = M.expand_noweb(bufnr, b.body, depth + 1, nw == "strip" and "strip" or nil, args, purpose)
    end
    -- like Emacs, a link comment points at the referenced block the first
    -- time it is looked up, then (from its reference cache) at the block
    -- being tangled
    local seen = M._noweb_seen
    local first = named and (not seen or not seen[ref])
    if named and seen then
      seen[ref] = true
    end
    if comment then
      local link_block = first and b or (M._noweb_parent or b)
      local beg_c, end_c = require("org.babel.tangle").comment_links(bufnr, b, ctx.file, nil, true, link_block)
      local cs, ce = require("org.babel.tangle").comment_delims(b.lang)
      local out = { cs .. beg_c .. ce }
      vim.list_extend(out, body)
      -- ob-tangle wraps the body as "BEG\nBODY\nEND\n": an empty line follows
      vim.list_extend(out, { cs .. end_c .. ce, "" })
      body = out
    end
    return body
  end
  -- the text of a headline with this CUSTOM_ID or ID
  local hbody = type(bufnr) == "number" and M.headline_body and M.headline_body(bufnr, ref, true)
  if hbody then
    return vim.split(hbody, "\n", { plain = true })
  end
  -- a block named `ref` is unique
  for _, b in ipairs(ctx.all) do
    if not b.call and b.name == ref and not in_commented(ctx.file, b.start) then
      return body_of(b, blocks_mod.header_args(b, ctx.file), true)
    end
  end
  local lob = M.library[ref]
  if lob then
    return vim.deepcopy(lob.body)
  end
  -- all blocks with a matching :noweb-ref, joined by their :noweb-sep
  local text
  for _, b in ipairs(ctx.all) do
    if not b.call and not in_commented(ctx.file, b.start) then
      local args = blocks_mod.header_args(b, ctx.file)
      if blocks_mod.unquote(args["noweb-ref"]) == ref then
        local chunk = table.concat(body_of(b, args), "\n")
        if text then
          local sep = args["noweb-sep"] and blocks_mod.unquote(args["noweb-sep"]):gsub("\\n", "\n") or "\n"
          text = text .. sep .. chunk
        else
          text = chunk
        end
      end
    end
  end
  if not text then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

--- Find the next noweb reference `<<ref>>` of `line` at or after `pos`,
--- like `org-babel-noweb-wrap`: the reference starts and ends with a
--- non-blank character and may contain spaces (`<<add(a=3, b=4)>>`).
---@return integer|nil s, integer e, string ref
local function find_noweb(line, pos)
  local cfg = require("org.config").opts.babel or {}
  local open, close = cfg.noweb_wrap_start or "<<", cfg.noweb_wrap_end or ">>"
  local init = pos
  while true do
    local s = line:find(open, init, true)
    if not s then
      return nil
    end
    local first = s + #open
    local c1 = line:sub(first, first)
    if c1 ~= "" and not c1:match("[ \t]") then
      -- the shortest reference ending with a non-blank character
      local from = first + 1
      while true do
        local e = line:find(close, from, true)
        if not e then
          break
        end
        if not line:sub(e - 1, e - 1):match("[ \t]") then
          return s, e + #close - 1, line:sub(first, e - 1)
        end
        from = e + 1
      end
    end
    init = s + 1
  end
end
M.find_noweb = find_noweb

--- Expand <<ref>> references in body lines. `mode` "strip" removes them.
--- `args` are the header args of the expanded block (:noweb-prefix).
function M.expand_noweb(bufnr, body, depth, mode, args, purpose)
  depth = depth or 0
  if depth > 20 then
    error("noweb: reference depth exceeded")
  end
  local lines = buf_lines(bufnr)
  local ctx = { lines = lines, all = blocks_mod.parse_blocks(lines), file = get_file(bufnr) }
  local prefix_opt = args and args["noweb-prefix"]
  local use_prefix = not (prefix_opt == "no" or prefix_opt == "nil")
  local out = {}
  for _, line in ipairs(body) do
    if not find_noweb(line, 1) then
      out[#out + 1] = line
    elseif mode == "strip" then
      local parts, pos = {}, 1
      while true do
        local s, e = find_noweb(line, pos)
        if not s then
          parts[#parts + 1] = line:sub(pos)
          break
        end
        parts[#parts + 1] = line:sub(pos, s - 1)
        pos = e + 1
      end
      local stripped = table.concat(parts)
      if not stripped:match("^%s*$") then
        out[#out + 1] = stripped
      end
    else
      local built = { "" }
      local pos = 1
      while true do
        local s, e, ref = find_noweb(line, pos)
        if not s then
          built[#built] = built[#built] .. line:sub(pos)
          break
        end
        -- like Emacs, the prefix is the text between the previous
        -- reference (or the line start) and this one
        local prefix = use_prefix and line:sub(pos, s - 1) or ""
        built[#built] = built[#built] .. line:sub(pos, s - 1)
        for i, x in ipairs(noweb_reference(bufnr, ref, depth, purpose, ctx, args)) do
          if i == 1 then
            built[#built] = built[#built] .. x
          else
            built[#built + 1] = prefix .. x
          end
        end
        pos = e + 1
      end
      vim.list_extend(out, built)
    end
  end
  return out
end

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
    local preserve = kind ~= "export" and (el[1]:match("%s%-i%f[%s%z]") or require("org.config").opts.src_preserve_indentation)
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

local evaluate_ref

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
          return evaluate_ref(bufnr, b, ref, file, opts)
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
    return evaluate_ref(bufnr, b, ref, nil, opts)
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

---------------------------------------------------------------------------
-- Execution
---------------------------------------------------------------------------

local function split_cmd(cmd)
  if type(cmd) == "table" then
    return vim.deepcopy(cmd)
  end
  return vim.split(vim.trim(cmd), "%s+")
end

--- Working directory of a block (`:dir`, created with `:mkdirp yes`).
local function block_cwd(bufnr, args)
  local file_dir = buf_dir(bufnr)
  local cwd = args.dir and utils.expand(blocks_mod.unquote(args.dir), file_dir) or file_dir
  if args.dir and (args.mkdirp == "yes" or args.mkdirp == "t") and not utils.is_dir(cwd) then
    vim.fn.mkdir(cwd, "p")
  end
  if not utils.is_dir(cwd) then
    cwd = vim.fn.getcwd()
  end
  return cwd
end
M.block_cwd = block_cwd

local warned_session = {}

--- Session name of a block, or nil (warns once for languages without
--- session support, which then run without one).
local function block_session(lang, args)
  local name = session_mod.name(args.session)
  if name and not session_mod.supported(lang, langs.family(lang)) then
    if not warned_session[lang] then
      warned_session[lang] = true
      utils.warn(string.format("babel: %s has no session support; ignoring :session", lang))
    end
    return nil
  end
  return name
end

--- Command (argv) that runs `lang`: `babel.languages[lang].cmd`, or the
--- `:python` / `:ruby` / `:cmd` header argument like Emacs.
local function lang_cmd(lang, args)
  local fam = langs.family(lang)
  if fam == "python" and args.python then
    return split_cmd(blocks_mod.unquote(args.python))
  elseif fam == "ruby" and args.ruby then
    return split_cmd(blocks_mod.unquote(args.ruby))
  elseif fam == "js" and args.cmd then
    return split_cmd(blocks_mod.unquote(args.cmd))
  end
  local lang_cfg = (require("org.config").opts.babel.languages or {})[lang]
  if type(lang_cfg) == "table" and lang_cfg.cmd then
    return split_cmd(lang_cfg.cmd)
  end
  if fam == "sql" then
    return {}
  end
  return nil
end

--- The session of a block, started when needed.
local function get_session(bufnr, lang, args, name)
  local fam = langs.family(lang)
  local cmd = {}
  if fam ~= "lua" then
    cmd = lang_cmd(lang, args)
    if not cmd then
      error("No babel command configured for language: " .. tostring(lang), 0)
    end
    if vim.fn.executable(cmd[1]) == 0 then
      error("Executable not found: " .. cmd[1], 0)
    end
  end
  return session_mod.get({ lang = lang, family = fam, name = name, cmd = cmd, cwd = block_cwd(bufnr, args) })
end

---------------------------------------------------------------------------
-- Error output (org-babel-eval-error-notify)
---------------------------------------------------------------------------

M.ERROR_BUFFER = "*Org-Babel Error Output*"

local function error_buffer(create)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match("%*Org%-Babel Error Output%*$") then
      return b
    end
  end
  if not create then
    return nil
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "hide"
  pcall(vim.api.nvim_buf_set_name, b, M.ERROR_BUFFER)
  return b
end

--- Empty the error buffer (org-babel-eval-wipe-error-buffer).
function M.wipe_error_buffer()
  local b = error_buffer(false)
  if b then
    vim.api.nvim_buf_set_lines(b, 0, -1, false, {})
  end
end

--- Show `stderr` of a failed evaluation in the `*Org-Babel Error Output*`
--- buffer (like Emacs, the result keeps only the standard output).
function M.error_notify(code, stderr)
  local b = error_buffer(true)
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    lines = {}
  end
  local text = (stderr or ""):gsub("\n$", "")
  if text ~= "" then
    vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  end
  local tail = code and string.format("[ Babel evaluation exited with code %s ]", tostring(code))
    or "[ Babel evaluation exited abnormally ]"
  lines[#lines + 1] = tail
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if #vim.fn.win_findbuf(b) == 0 then
    local win = vim.api.nvim_get_current_win()
    pcall(function()
      vim.cmd("botright split")
      vim.api.nvim_win_set_buf(0, b)
      vim.api.nvim_win_set_height(0, math.min(10, math.max(3, #lines)))
      vim.api.nvim_set_current_win(win)
    end)
  end
  utils.warn(code and string.format("Babel evaluation exited with code %s", tostring(code)) or "Babel evaluation exited abnormally")
end

---------------------------------------------------------------------------
-- Running code
---------------------------------------------------------------------------

--- Code sent to a session: :prologue, variables, body and :epilogue.
local function session_code(lang, body, args, vars)
  local lines = {}
  if args.prologue then
    vim.list_extend(lines, vim.split(blocks_mod.unquote(args.prologue), "\\n", { plain = true }))
  end
  vim.list_extend(lines, langs.var_lines(lang, vars, args))
  if langs.family(lang) == "js" then
    -- top-level let/const would fail when the block is evaluated again
    for _, l in ipairs(body) do
      lines[#lines + 1] = (l:gsub("^let%s", "var "):gsub("^const%s", "var "))
    end
  else
    vim.list_extend(lines, body)
  end
  if args.epilogue then
    vim.list_extend(lines, vim.split(blocks_mod.unquote(args.epilogue), "\\n", { plain = true }))
  end
  return table.concat(lines, "\n")
end

--- The result of an in-process Lua evaluation.
local function lua_result(res, args)
  local rp = results.result_params(args)
  if args.results_spec.collection == "output" then
    local out = res.output or ""
    return out ~= "" and (out .. "\n") or out
  end
  if res.value == nil then
    return nil
  end
  local v = langs.from_lua(res.value)
  if langs.scalar_result(args) and not rp.file then
    return lisp.princ(v)
  end
  return v
end

local function run_in_session(bufnr, lang, body, args, vars, name, done, sync, graphics_file)
  local ok, sess = pcall(get_session, bufnr, lang, args, name)
  if not ok then
    utils.error("babel: " .. tostring(sess))
    return done({ error = tostring(sess) })
  end
  local timeout = require("org.config").opts.babel.timeout
  if langs.family(lang) == "lua" then
    session_mod.echo(sess, table.concat(body, "\n"))
    local res = langs.run_lua(body, args, vars, sess.env)
    if vim.trim(res.output or "") ~= "" then
      session_mod.append(sess, res.output)
    end
    if res.error then
      M.error_notify(nil, res.error)
      return done({ error = res.error, result = args.results_spec.collection == "output" and res.output or nil })
    end
    return done({ result = lua_result(res, args) })
  end
  local fam = langs.family(lang)
  local is_shell = fam == "shell" or fam == "fish"
  local exit_status = langs.shell_exit_status(lang, args)
  local mode = (args.results_spec.collection == "value" and not is_shell) and "value" or "output"
  local rp = vim.tbl_keys(results.result_params(args))
  local function convert(sres)
    if sres.error and not is_shell then
      M.error_notify(nil, sres.error)
      if mode == "value" then
        return { error = sres.error }
      end
    end
    local raw
    if exit_status then
      raw = tostring(sres.status or "")
    elseif mode == "value" then
      raw = type(sres.value) == "string" and sres.value or ""
    else
      raw = sres.output or ""
    end
    return { result = langs.convert(lang, raw, args, {}), error = sres.error }
  end
  local code = session_code(lang, body, args, vars)
  local eopts = { timeout = timeout, params = rp, file = graphics_file }
  if sync then
    return done(convert(session_mod.eval_sync(sess, code, mode, eopts)))
  end
  session_mod.eval(sess, code, mode, function(sres)
    done(convert(sres))
  end, eopts)
end

--- Run the steps of a spec (see `langs.prepare`) one after the other and
--- call `cb(stdout)` with the output of the last. Failures are shown in
--- the error buffer; like `org-babel-eval`, the output is still used.
local function run_steps(spec, cwd, sync, cb)
  local timeout = require("org.config").opts.babel.timeout
  local outs = {}
  local failed = false
  local i = 0
  local function sys_opts(step)
    return { cwd = cwd, text = true, stdin = step.stdin, timeout = timeout, env = { PWD = cwd } }
  end
  local function handle(obj)
    local stderr = obj.stderr or ""
    local code = obj.code
    if obj.signal and obj.signal ~= 0 and code == 0 then
      code = 128 + obj.signal
    end
    if code ~= 0 or stderr ~= "" then
      failed = true
      M.error_notify(code, stderr)
    end
    outs[#outs + 1] = obj.stdout or ""
  end
  local function argv(step)
    if type(step.cmd) == "string" then
      return { vim.o.shell ~= "" and vim.fn.exepath("sh") ~= "" and "sh" or vim.o.shell, "-c", step.cmd }
    end
    return step.cmd
  end
  if sync then
    for _, step in ipairs(spec.steps) do
      local ok, obj = pcall(function()
        return vim.system(argv(step), sys_opts(step)):wait()
      end)
      if not ok then
        M.error_notify(nil, tostring(obj))
        return cb(nil, true)
      end
      handle(obj)
    end
    return cb(outs[#outs] or "", failed)
  end
  local function nxt()
    i = i + 1
    local step = spec.steps[i]
    if not step then
      return cb(outs[#outs] or "", failed)
    end
    local ok, err = pcall(vim.system, argv(step), sys_opts(step), function(obj)
      vim.schedule(function()
        handle(obj)
        nxt()
      end)
    end)
    if not ok then
      M.error_notify(nil, tostring(err))
      cb(nil, true)
    end
  end
  nxt()
end

--- Run code and call `cb(r)` with `r = { result, error? }`: `result` is
--- the Babel value `org-babel-execute:LANG` returns. With `opts.sync` the
--- call blocks and returns `r`.
---@param opts? { sync?: boolean, colnames?: table, graphics_file?: string }
function M.run(bufnr, lang, body, args, vars, cb, opts)
  opts = opts or {}
  local sync = opts.sync
  local result
  local function done(r)
    if sync then
      result = r
    elseif cb then
      vim.schedule(function()
        cb(r)
      end)
    end
    return r
  end
  local fam = langs.family(lang)
  local sname = block_session(lang, args)
  if sname then
    run_in_session(bufnr, lang, body, args, vars, sname, done, sync, opts.graphics_file)
    return result
  end
  local cwd = block_cwd(bufnr, args)
  if fam == "lua" then
    local res = langs.run_lua(body, args, vars)
    if res.error then
      M.error_notify(nil, res.error)
      done({ error = res.error, result = args.results_spec.collection == "output" and res.output ~= "" and (res.output .. "\n") or nil })
    else
      done({ result = lua_result(res, args) })
    end
    return result
  end
  if lang == "emacs-lisp" or lang == "elisp" then
    local msg = "emacs-lisp blocks cannot be evaluated in Neovim (there is no Emacs Lisp interpreter)"
    utils.error(msg)
    done({ error = msg })
    return result
  end
  local cmd = lang_cmd(lang, args)
  if not cmd and fam == "c" then
    cmd = { M.c_compiler(lang) }
  end
  if not cmd then
    local msg = "No org-babel-execute function for " .. tostring(lang) .. "! (add it to babel.languages)"
    utils.error(msg)
    done({ error = msg })
    return result
  end
  if cmd[1] and vim.fn.executable(cmd[1]) == 0 then
    local msg = "Executable not found: " .. cmd[1]
    M.error_notify(127, msg)
    done({ error = msg })
    return result
  end
  local stdin
  if args.stdin and (fam == "shell" or fam == "fish") then
    -- :stdin ref feeds a value to the script (ob-shell)
    local ok, v = pcall(M.resolve_var, bufnr, args.stdin, args, {})
    if not ok then
      utils.error(":stdin: " .. tostring(v))
      done({ error = tostring(v) })
      return result
    end
    stdin = langs.table_to_text(v) .. "\n"
  end
  local lang_cfg = (require("org.config").opts.babel.languages or {})[lang]
  local ok, spec = pcall(langs.prepare, lang, body, args, vars, {
    cmd = cmd,
    ext = type(lang_cfg) == "table" and lang_cfg.ext or langs.ext(lang),
    graphics_file = opts.graphics_file,
    colnames = opts.colnames,
  })
  if not ok then
    utils.error("babel: " .. tostring(spec))
    done({ error = tostring(spec) })
    return result
  end
  if stdin and spec.steps[1] and not spec.steps[1].stdin then
    spec.steps[1].stdin = stdin
  end
  local function finish(stdout, failed)
    if stdout == nil then
      return done({ error = true })
    end
    local raw = stdout
    if spec.result_file then
      raw = ""
      if not opts.graphics_file and vim.fn.filereadable(spec.result_file) == 1 then
        local fh = io.open(spec.result_file, "rb")
        if fh then
          raw = fh:read("*a")
          fh:close()
        end
      end
    end
    local cok, res = pcall(langs.convert, lang, raw, args, spec)
    if not cok then
      res = raw
    end
    done({ result = res, error = failed or nil })
  end
  run_steps(spec, cwd, sync, finish)
  return result
end

--- Default compiler of a C-family language (org-babel-C-compiler ...).
function M.c_compiler(lang)
  if lang == "C" then
    return "gcc"
  elseif lang == "D" then
    return "rdmd"
  end
  return "g++"
end

---------------------------------------------------------------------------
-- Header argument helpers
---------------------------------------------------------------------------

--- Output file of a block (org-babel-generate-file-param: `:file`, or
--- NAME.`:file-ext`, below `:output-dir`), or nil.
function M.file_param(args, name)
  local file = blocks_mod.unquote(args.file)
  local dir = blocks_mod.unquote(args["output-dir"])
  local ext = blocks_mod.unquote(args["file-ext"])
  if dir and dir ~= "" then
    pcall(vim.fn.mkdir, dir, "p")
  end
  if (not file or file == "") and name and ext and ext ~= "" then
    file = name .. "." .. ext
  end
  if not file or file == "" then
    return nil
  end
  if dir and dir ~= "" and not file:match("^[/~]") then
    file = dir:gsub("/$", "") .. "/" .. file
  end
  return file
end

--- Symbolic file mode `u+x,go-w` applied to `base` (file-modes-symbolic-to-number).
local function symbolic_mode(spec, base)
  local mode = base
  local SH = { u = 6, g = 3, o = 0 }
  for clause in spec:gmatch("[^,]+") do
    local who, ops = clause:match("^([ugoa]*)(.*)$")
    if who == "" or who:find("a") then
      who = "ugo"
    end
    for op, perms in ops:gmatch("([+=-])([rwxXstugo]*)") do
      local bits = 0
      for p in perms:gmatch(".") do
        if p == "r" then
          bits = bit.bor(bits, 4)
        elseif p == "w" then
          bits = bit.bor(bits, 2)
        elseif p == "x" then
          bits = bit.bor(bits, 1)
        elseif p == "X" and bit.band(mode, tonumber("111", 8)) ~= 0 then
          bits = bit.bor(bits, 1)
        elseif SH[p] then
          bits = bit.bor(bits, bit.band(bit.rshift(mode, SH[p]), 7))
        end
      end
      for w in who:gmatch(".") do
        local sh = SH[w]
        local m = bit.lshift(bits, sh)
        if op == "+" then
          mode = bit.bor(mode, m)
        elseif op == "-" then
          mode = bit.band(mode, bit.bnot(m))
        else
          mode = bit.bor(bit.band(mode, bit.bnot(bit.lshift(7, sh))), m)
        end
      end
    end
  end
  return mode
end

--- File mode of a `:tangle-mode` / `:file-mode` value like
--- org-babel-interpret-file-mode: `(identity #o755)`, `o755`, `#o755`,
--- `rwxr-xr-x` or `u+x` (on top of 0644). Returns nil and a message for
--- other values (a decimal number like `755` is refused, as in Emacs).
function M.file_mode(value)
  local v = vim.trim(blocks_mod.unquote(value or "") or "")
  local default = tonumber("644", 8)
  local oct = v:match("^#o([0-7]+)$") or v:match("^%(identity%s+#o([0-7]+)%)$") or v:match("^o0?([0-7][0-7][0-7])$")
  if oct then
    return tonumber(oct, 8)
  end
  local n = tonumber(v)
  if n then
    return nil, string.format("%s is not a valid file mode octal.  Did you give the decimal value %s by mistake?", string.format("%o", n), v)
  end
  if v:match("^[r-][w-][xs-][r-][w-][xs-][r-][w-][x-]$") then
    local function part(s)
      return (s:gsub("-", ""))
    end
    return symbolic_mode("u=" .. part(v:sub(1, 3)) .. ",g=" .. part(v:sub(4, 6)) .. ",o=" .. part(v:sub(7, 9)), 0)
  end
  if v:match("^[ugoa]*[+=-]") then
    return symbolic_mode(v, default)
  end
  if v:match("^%(") then
    local ok, r = pcall(lisp.read, v)
    if ok and type(r) == "number" then
      return r
    end
  end
  return nil, string.format("File mode %q not recognized as a valid format", v)
end

--- Write a result to its :file like org-babel-format-result: a table with
--- cells separated by `:sep` (a tab), anything else as text.
local function write_file_result(path, result, args)
  local text
  if lisp.is_list(result) then
    local sep = blocks_mod.unquote(args.sep) or "\t"
    local rows = {}
    for _, row in ipairs(result) do
      if row ~= "hline" then
        if lisp.is_list(row) then
          local cells = {}
          for j, c in ipairs(row) do
            cells[j] = type(c) == "string" and c or lisp.prin1(c)
          end
          rows[#rows + 1] = table.concat(cells, sep)
        else
          rows[#rows + 1] = type(row) == "string" and row or lisp.prin1(row)
        end
      end
    end
    text = table.concat(rows, "\n")
  else
    text = type(result) == "string" and result or lisp.prin1(result)
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path, "b")
  if args["file-mode"] then
    local mode, err = M.file_mode(args["file-mode"])
    if mode then
      vim.uv.fs_chmod(path, mode)
    else
      utils.error(err)
    end
  end
end

--- Remove coderef labels `(ref:name)` from a body (org-babel--expand-body).
local function strip_coderefs(body, switches)
  local pat = blocks_mod.coderef_pattern(switches)
  local out = {}
  for i, l in ipairs(body) do
    out[i] = (l:gsub(pat, ""))
  end
  return out
end
M.strip_coderefs = strip_coderefs

--- `org-confirm-babel-evaluate`: true to ask (a function gets the
--- language and the body, like Emacs).
local function confirm_setting(lang, body)
  local ce = require("org.config").opts.babel.confirm_evaluate
  if type(ce) == "function" then
    local ok, v = pcall(ce, lang, table.concat(body or {}, "\n"))
    return not ok or (v ~= false and v ~= nil)
  end
  return ce ~= false
end

--- org-babel-check-confirm-evaluate: "no" (`:eval no|never`, or
--- `no-export|never-export` while exporting), "query" (ask) or "yes".
---@param opts? { export?: boolean, skip_confirm?: boolean }
function M.check_evaluate(args, lang, body, opts)
  opts = opts or {}
  local ev = args.eval or (args.noeval and "no")
  if ev == "no" or ev == "never" or (opts.export and (ev == "no-export" or ev == "never-export")) then
    return "no"
  end
  if ev == "query" or (opts.export and ev == "query-export") then
    return "query"
  end
  if not opts.skip_confirm and confirm_setting(lang, body) then
    return "query"
  end
  return "yes"
end

local function name_string(name)
  return name and (" (" .. name .. ") ") or " "
end

---------------------------------------------------------------------------
-- :cache hashes (org-babel-sha1-hash)
---------------------------------------------------------------------------

local HASH_SKIP = { vars = true, results_spec = true, results_extra = true, default_collection = true }
local HANDLING = { replace = true, silent = true, none = true, discard = true, append = true, prepend = true }

--- `(name . value)` printed like Emacs.
local function cons_str(name, value)
  if lisp.is_list(value) then
    if #value == 0 then
      return "(" .. name .. ")"
    end
    return "(" .. name .. " " .. lisp.prin1(value):sub(2)
  end
  return "(" .. name .. " . " .. lisp.prin1(value) .. ")"
end

--- The hash `:cache yes` stores in `#+RESULTS[hash]:`, computed like
--- org-babel-sha1-hash (the sorted parameters and the expanded body), so
--- hashes written by Emacs and by Neovim agree.
function M.cache_hash(lang, body, args, vars, meta)
  local entries = {}
  local function add(key, s)
    if s then
      entries[#entries + 1] = { key = key, s = s, i = #entries }
    end
  end
  for k, v in pairs(args) do
    if type(v) == "string" and not HASH_SKIP[k] and k ~= "exports" then
      local ok, val = pcall(lisp.read, v)
      if not ok then
        val = v
      end
      if v ~= "" and not (lisp.is_list(val) and #val == 0) then
        add(":" .. k, lisp.prin1(val))
      end
    end
  end
  local words = {}
  for cat, w in pairs(args.results_spec or {}) do
    if not HANDLING[w] and not (cat == "collection" and args.default_collection) then
      words[#words + 1] = w
    end
  end
  for _, w in ipairs(args.results_extra or {}) do
    if not HANDLING[w] then
      words[#words + 1] = w
    end
  end
  table.sort(words)
  add(":results", lisp.prin1(table.concat(words, " ")))
  if #words > 0 then
    add(":result-params", lisp.prin1(words))
  end
  add(":result-type", (args.results_spec or {}).collection == "output" and "output" or "value")
  local ex = vim.split(args.exports or "code", "%s+", { trimempty = true })
  table.sort(ex)
  add(":exports", lisp.prin1(table.concat(ex, " ")))
  for _, v in ipairs(vars or {}) do
    add(":var", cons_str(v.name, v.value))
  end
  for _, key in ipairs({ "colnames", "rownames" }) do
    local names = meta and meta[key]
    if names and #names > 0 then
      local parts = {}
      for i, pair in ipairs(names) do
        parts[i] = cons_str(pair[1], pair[2])
      end
      add(key == "colnames" and ":colname-names" or ":rowname-names", "(" .. table.concat(parts, " ") .. ")")
    end
  end
  table.sort(entries, function(a, b)
    if a.key ~= b.key then
      return a.key < b.key
    end
    return a.i < b.i
  end)
  local parts = {}
  for i, e in ipairs(entries) do
    parts[i] = e.s
  end
  local colnames
  if meta and meta.colnames then
    colnames = {}
    for _, pair in ipairs(meta.colnames) do
      colnames[pair[1]] = pair[2]
    end
  end
  local expanded = langs.expand(lang, body or {}, args, vars or {}, colnames)
  return require("org.babel.sha1").hex(table.concat(parts, ":") .. "-" .. expanded)
end

---------------------------------------------------------------------------
-- Evaluation
---------------------------------------------------------------------------

--- Languages whose result gets :colnames / :rownames back
--- (org-babel-reassemble-table).
local NO_REASSEMBLE = { js = true, sqlite = true }

local this_stack = {}

--- Fire a `User` autocmd (Emacs hooks).
function M.fire(pattern, data)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, modeline = false, data = data })
end

--- Evaluate `src` (a block, or the target of a call) with merged `args`,
--- like org-babel-execute-src-block without inserting the result:
--- checks `:eval`, resolves variables, honours `:cache` (with
--- `opts.current_hash` / `opts.read_cached`), asks for confirmation,
--- runs the code, then applies :colnames, `:file` and `:post`.
--- `cb(result, info)`; with `opts.sync` returns them instead.
---@param opts? { sync?: boolean, skip_confirm?: boolean, export?: boolean, depth?: integer, current_hash?: string, read_cached?: fun(): any, force?: boolean }
function M.evaluate(bufnr, src, args, opts, cb)
  opts = opts or {}
  local sync = opts.sync
  local ret_result, ret_info
  local function finish(result, info)
    info = info or {}
    if sync then
      ret_result, ret_info = result, info
    elseif cb then
      cb(result, info)
    end
  end
  local lang, name = src.lang, src.name
  local depth = (opts.depth or 0) + 1
  if depth > 20 then
    error("reference depth exceeded (circular :var references?)", 0)
  end
  local body = src.body
  if M.check_evaluate(args, lang, body, { export = opts.export, skip_confirm = true }) == "no" then
    utils.notify(string.format("Evaluation of this %s code block%sis disabled.", lang, name_string(name)))
    finish(nil, { skipped = true })
    return ret_result, ret_info
  end
  local meta = {}
  local ok, vars = pcall(resolve_vars, bufnr, args, meta, { depth = depth, skip_confirm = opts.skip_confirm })
  if not ok then
    utils.error("babel: " .. tostring(vars))
    finish(nil, { error = tostring(vars), skipped = true })
    return ret_result, ret_info
  end
  if noweb_for(args, "eval") then
    local nok, expanded = pcall(M.expand_noweb, bufnr, body, 0, nil, args, "eval")
    if not nok then
      utils.error("babel: " .. tostring(expanded))
      finish(nil, { error = tostring(expanded), skipped = true })
      return ret_result, ret_info
    end
    body = expanded
  end
  local out_file = M.file_param(args, name)
  if out_file then
    args.file = out_file
  end
  local hash
  if args.cache == "yes" and not opts.force then
    hash = M.cache_hash(lang, body, args, vars, meta)
    if opts.current_hash and opts.current_hash == hash and opts.read_cached then
      local result = opts.read_cached()
      utils.notify("Cached: " .. (type(result) == "string" and result or lisp.prin1(result)))
      finish(result, { cached = true, hash = hash })
      return ret_result, ret_info
    end
  end
  local check = M.check_evaluate(args, lang, body, { export = opts.export, skip_confirm = opts.skip_confirm })
  if check == "query" then
    local question = string.format("Evaluate this %s code block%son your system? ", lang, name_string(name))
    if not utils.confirm(question) then
      utils.notify(string.format("Evaluation of this %s code block%sis aborted.", lang, name_string(name)))
      finish(nil, { skipped = true, aborted = true })
      return ret_result, ret_info
    end
  end
  if not src.inline then
    body = strip_coderefs(body, src.switches)
  end
  local rp = results.result_params(args)
  local cwd = block_cwd(bufnr, args)
  local graphics_file
  if rp.graphics and langs.family(lang) == "python" then
    if not args.file then
      local msg = args["file-ext"] and ":file-ext given but no :file generated; did you forget to name a block?"
        or "No :file header argument given; cannot create graphical result"
      utils.error(msg)
      finish(nil, { error = msg, skipped = true })
      return ret_result, ret_info
    end
    graphics_file = utils.expand(blocks_mod.unquote(args.file), cwd)
  end
  local colnames = {}
  for _, pair in ipairs(meta.colnames or {}) do
    colnames[pair[1]] = pair[2]
  end
  local function after(r)
    local result = r.result
    if rp.discard then
      result = nil
    end
    if
      args.results_spec.collection == "value"
      and (rp.vector or rp.table)
      and result ~= nil
      and not lisp.is_list(result)
    then
      result = { { result } }
    end
    if not NO_REASSEMBLE[langs.family(lang)] then
      result = M.reassemble(result, args, meta)
    end
    local info = { hash = hash, meta = meta, error = r.error, cwd = cwd }
    local file = rp.file and args.file and blocks_mod.unquote(args.file)
    if file then
      if not results.is_null(result) and not (rp.link or rp.graphics) then
        write_file_result(utils.expand(file, cwd), result, args)
      end
      result = file
    end
    if args.post and args.post ~= "" then
      local this = result
      if file then
        this = results.result_to_file(file, results.file_desc(args, file), { base_dir = buf_dir(bufnr), cwd = cwd })
      end
      table.insert(this_stack, { value = this })
      local pok, presult = pcall(M.resolve_var, bufnr, blocks_mod.unquote(args.post), {}, {}, {
        skip_confirm = opts.skip_confirm,
        depth = depth,
      })
      table.remove(this_stack)
      if pok then
        result = presult
        if file then
          info.drop_file = true
        end
      else
        utils.error(":post: " .. tostring(presult))
      end
    end
    if sync then
      finish(result, info)
    else
      finish(result, info)
    end
  end
  if sync then
    after(M.run(bufnr, lang, body, args, vars, nil, { sync = true, colnames = colnames, graphics_file = graphics_file }))
  else
    M.run(bufnr, lang, body, args, vars, after, { colnames = colnames, graphics_file = graphics_file })
  end
  return ret_result, ret_info
end

--- The value of `*this*` while a `:post` reference is resolved.
function M.current_this()
  local top = this_stack[#this_stack]
  if top then
    return true, top.value
  end
  return false
end

---------------------------------------------------------------------------
-- Inserting results
---------------------------------------------------------------------------

--- Insert `result` for the block (or #+CALL) starting at `start`, like
--- org-babel-insert-result: below its `#+RESULTS:` keyword (created
--- after the block when missing), replacing, appending to or prepending
--- to the previous result.
local function insert_results(bufnr, start, result, args, hash, lang, ctx)
  local lines = buf_lines(bufnr)
  local b
  for _, x in ipairs(blocks_mod.parse_blocks(lines)) do
    if x.start == start then
      b = x
    end
  end
  if not b then
    return
  end
  local out, example = results.format(result, args, lang, ctx)
  local indent = b.indent or ""
  local handling = args.results_spec.handling
  local body = {}
  local no_indent = lisp.is_list(result) and handling == "append"
  for i, l in ipairs(out) do
    body[i] = (l == "" or no_indent) and l or (indent .. l)
  end
  local bcfg = require("org.config").opts.babel
  local keyword = bcfg.results_keyword or "RESULTS"
  local hash_text = hash
  if hash and bcfg.hash_show_time then
    hash_text = os.date("(%Y-%m-%d %H:%M:%S) ") .. hash
  end
  local header = indent
    .. "#+"
    .. keyword
    .. (hash_text and ("[" .. hash_text .. "]") or "")
    .. ":"
    .. (b.name and (" " .. b.name) or "")
  local after_row
  if b.results then
    local s, e = b.results.start, b.results.finish
    if hash and b.results.hash ~= hash then
      vim.api.nvim_buf_set_lines(bufnr, s - 1, s, false, { header })
    end
    if handling == "append" then
      vim.api.nvim_buf_set_lines(bufnr, e, e, false, body)
      after_row = e + #body
    elseif handling == "prepend" then
      vim.api.nvim_buf_set_lines(bufnr, s, s, false, body)
      after_row = s + #body
    else
      vim.api.nvim_buf_set_lines(bufnr, s, e, false, body)
      after_row = s + #body
    end
  else
    local new = { "", header }
    vim.list_extend(new, body)
    local nxt = lines[b.finish + 1]
    if nxt and not nxt:match("^%s*$") then
      new[#new + 1] = ""
    end
    vim.api.nvim_buf_set_lines(bufnr, b.finish, b.finish, false, new)
    after_row = b.finish + 2 + #body
  end
  if example then
    -- like Emacs, #+end_example takes the place of an empty line after it
    local l = vim.api.nvim_buf_get_lines(bufnr, after_row, after_row + 1, false)[1]
    if l == "" then
      vim.api.nvim_buf_set_lines(bufnr, after_row, after_row + 1, false, {})
    end
  end
end
M.insert_results = insert_results

--- Read the existing result of a block (org-babel-read-result).
local function read_block_result(bufnr, b)
  local lines = buf_lines(bufnr)
  local k = b.results.start + 1
  if not lines[k] or lines[k]:match("^%s*$") then
    return nil
  end
  local v = read_element(lines, k, bufnr)
  if v == nil then
    return nil
  end
  return v
end

--- Execute the block at (bufnr, lnum). `on_done(ok)` is called when done.
--- With `sync` the evaluation blocks and results are inserted before return.
---@param opts? { bufnr?: integer, lnum?: integer, skip_confirm?: boolean, sync?: boolean, handling?: string, on_done?: fun(ok: boolean), export?: boolean, force?: boolean, params?: string }
function M.execute(opts)
  opts = opts or {}
  local bufnr = resolve_buf(opts.bufnr)
  local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]
  local done = opts.on_done or function() end
  local b = M.at_block(bufnr, lnum)
  if not b then
    utils.warn("No source block at point")
    done(false)
    return false
  end
  local args, target = b.args, nil
  if b.call then
    args, target = M.block_args(b, b.file, bufnr)
    if not target then
      utils.error("#+CALL: no block named " .. tostring(b.target))
      done(false, true)
      return
    end
  end
  local src = target or b
  if opts.params then
    blocks_mod.merge(args, M.parse_header_string(opts.params))
  end
  if opts.handling then
    args.results_spec.handling = opts.handling
  end
  -- track the block position across edits
  local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, b.start - 1, 0, {
    virt_text = { { "  ⏳ executing…", "Comment" } },
    virt_text_pos = "eol",
  })
  local function finish(result, info)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
    if info.skipped then
      done(false)
      return
    end
    if info.cached then
      done(true)
      return
    end
    local iargs = args
    if info.drop_file then
      iargs = vim.deepcopy(args)
      iargs.results_spec.type = nil
    end
    local rp = results.result_params(iargs)
    if rp.silent then
      utils.notify(type(result) == "string" and result or lisp.prin1(result))
    elseif not rp.none and pos and pos[1] then
      local ctx = { base_dir = buf_dir(bufnr), cwd = info.cwd }
      insert_results(bufnr, pos[1] + 1, result, iargs, rp.replace and info.hash or nil, src.lang, ctx)
    end
    M.fire("OrgBabelAfterExecute", { bufnr = bufnr, lang = src.lang, name = src.name, result = result })
    done(info.error == nil)
  end
  local eopts = {
    sync = opts.sync,
    skip_confirm = opts.skip_confirm,
    export = opts.export,
    force = opts.force,
    current_hash = b.results and b.results.hash,
    read_cached = function()
      return b.results and read_block_result(bufnr, b)
    end,
  }
  if opts.sync then
    local result, info = M.evaluate(bufnr, src, args, eopts)
    finish(result, info)
  else
    M.evaluate(bufnr, src, args, eopts, finish)
  end
end

--- Evaluate a block synchronously and return its result without inserting
--- it (what a :var reference or a noweb call sees), like
--- org-babel-execute-src-block with `:results none`.
---@param src table the block (the target of a #+CALL)
---@param opts? { depth?: integer, skip_confirm?: boolean, block?: table }
function M.evaluate_sync(bufnr, src, args, opts)
  opts = opts or {}
  local holder = opts.block or src
  local result = M.evaluate(bufnr, src, args, {
    sync = true,
    skip_confirm = opts.skip_confirm,
    depth = opts.depth,
    current_hash = holder.results and holder.results.hash,
    read_cached = function()
      return holder.results and type(bufnr) == "number" and read_block_result(bufnr, holder)
    end,
  })
  return result
end

--- Evaluate the block (or #+CALL) `b` for the reference `ref`.
evaluate_ref = function(bufnr, b, ref, file, opts)
  local args, src
  local state = { pos = 0 }
  if b.call then
    args, src = M.block_args(b, file, bufnr)
    if not src then
      error("#+CALL: no block named " .. tostring(b.target), 0)
    end
  else
    src = b
    args = blocks_mod.header_args(b, file)
  end
  if ref.header and ref.header ~= "" then
    blocks_mod.merge(args, blocks_mod.parse_header_string(ref.header), state)
  end
  if ref.call and vim.trim(ref.call) ~= "" then
    blocks_mod.merge(args, blocks_mod.call_args(ref.call), state)
  end
  args.results_spec.handling = "none"
  if type(bufnr) ~= "number" then
    -- a list of lines (export) can't run code: use the existing results
    local lines = buf_lines(bufnr)
    if b.results then
      local v = read_element(lines, b.results.start + 1, nil)
      if v ~= nil then
        return v
      end
    end
    error("block '" .. tostring(src.name) .. "' has no results", 0)
  end
  opts = opts or {}
  return M.evaluate_sync(bufnr, src, args, { depth = opts.depth, skip_confirm = opts.skip_confirm, block = b })
end

--- Execute the src block at cursor (or the inline src block under it).
function M.execute_block()
  M.wipe_error_buffer()
  if M.inline_at_cursor() then
    return M.execute_inline()
  end
  local force = vim.v.count > 0
  M.execute({ force = force })
end

---------------------------------------------------------------------------
-- Inline src blocks: src_lang[:args]{body} {{{results(=value=)}}}
---------------------------------------------------------------------------

--- Inline src block or inline call of `line` covering column `col`
--- (1-based), or nil. Calls are `call_name[inside](args)[end]`.
---@return { lang?: string, params: string, body?: string, call?: boolean, target?: string, inside?: string, call_args?: string, s: integer, e: integer }|nil
function M.inline_at(line, col)
  for _, ib in ipairs(M.inline_all(line)) do
    if col >= ib.s and col <= ib.e then
      return ib
    end
  end
end

--- Every inline src block and inline call of `line`, left to right.
function M.inline_all(line)
  local list = {}
  local init = 1
  while true do
    local s, _, kind = line:find("(%l+)_", init)
    if not s then
      return list
    end
    local found
    if (kind == "src" or kind == "call") and (s == 1 or not line:sub(s - 1, s - 1):match("[%w_]")) then
      local rest = line:sub(s)
      if kind == "src" then
        local lang, hdr, body = rest:match("^src_([^%s%[{]+)(%b[])(%b{})")
        if not lang then
          hdr = ""
          lang, body = rest:match("^src_([^%s%[{]+)(%b{})")
        end
        if lang then
          local params = hdr ~= "" and hdr:sub(2, -2) or ""
          found = { lang = lang, params = params, body = body:sub(2, -2), len = 4 + #lang + #hdr + #body }
        end
      else
        local name = rest:match("^call_([^%s%[%(]+)")
        if name then
          local after = rest:sub(6 + #name)
          local inside = after:match("^%b[]") or ""
          after = after:sub(#inside + 1)
          local cargs = after:match("^%b()")
          if cargs then
            after = after:sub(#cargs + 1)
            local ending = after:match("^%b[]") or ""
            found = {
              call = true,
              target = name,
              inside = inside:sub(2, -2),
              call_args = cargs:sub(2, -2),
              params = ending:sub(2, -2),
              len = 5 + #name + #inside + #cargs + #ending,
            }
          end
        end
      end
    end
    if found then
      found.s, found.e, found.len = s, s + found.len - 1, nil
      list[#list + 1] = found
      init = found.e + 1
    else
      init = s + 1
    end
  end
end

function M.inline_at_cursor()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  return M.inline_at(vim.api.nvim_get_current_line(), col)
end

--- Evaluate the inline src block or inline call at the cursor and insert or
--- replace its `{{{results(...)}}}` right after it (C-c C-c on it).
function M.execute_inline(opts)
  local ib = M.inline_at_cursor()
  if not ib then
    return false
  end
  return M.execute_inline_at(vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1], ib, opts)
end

--- Source block and header args of an inline element of line `lnum`.
function M.inline_info(bufnr, lnum, ib, file)
  if ib.call then
    local target = M.find_named_block(buf_lines(bufnr), ib.target)
    if not target then
      return nil
    end
    local args = M.call_header_args(target, {
      start = lnum,
      inside = ib.inside,
      call_args = ib.call_args,
      params = ib.params,
    }, file)
    return target, args
  end
  local src = { start = lnum, lang = ib.lang, params = ib.params, header_lines = {}, inline = true }
  src.body = { (ib.body:gsub("\n[ \t]*", " ")) }
  return src, blocks_mod.header_args(src, file, nil, { inline = true })
end

--- Evaluate the inline element `ib` (from `M.inline_at`) of line `lnum`.
---@param opts? { skip_confirm?: boolean, sync?: boolean, export?: boolean, on_done?: fun(ok: boolean) }
function M.execute_inline_at(bufnr, lnum, ib, opts)
  opts = opts or {}
  local done = opts.on_done or function() end
  local file = get_file(bufnr)
  local src, args = M.inline_info(bufnr, lnum, ib, file)
  if not src then
    utils.error("call_" .. ib.target .. ": no block named " .. ib.target)
    done(false, true)
    return
  end
  local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, ib.e, { right_gravity = false })
  local function finish(result, info)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
    if info.skipped then
      done(false)
      return
    end
    local iargs = args
    if info.drop_file then
      iargs = vim.deepcopy(args)
      iargs.results_spec.type = nil
    end
    local rp = results.result_params(iargs)
    if rp.none then
      done(true)
      return
    end
    if rp.silent then
      utils.notify(type(result) == "string" and result or lisp.prin1(result))
      done(true)
      return
    end
    local text, err = results.format_inline(result, iargs, src.lang, { base_dir = buf_dir(bufnr), cwd = info.cwd })
    if not text then
      -- a user-error in Emacs: it also stops org-babel-execute-buffer
      utils.error(err)
      done(false, true)
      return
    end
    if pos and pos[1] then
      -- set_text keeps the extmarks of later inline elements of the line
      local row, col = pos[1], pos[2]
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
      local after = line:sub(col + 1)
      local ws = after:match("^(%s*)")
      if after:sub(#ws + 1):match("^{{{results%(") then
        -- replace the existing macro (it ends at the first ")}}}")
        local e = after:find(")}}}", #ws + 1, true)
        local stop = e and (col + e + 3) or #line
        vim.api.nvim_buf_set_text(bufnr, row, col + #ws, row, stop, { text })
      else
        local before = line:sub(1, col)
        local trimmed = before:gsub("[ \t]+$", "")
        vim.api.nvim_buf_set_text(bufnr, row, #trimmed, row, #trimmed, { " " .. text })
      end
    end
    M.fire("OrgBabelAfterExecute", { bufnr = bufnr, lang = src.lang, name = src.name, result = result, inline = true })
    done(info.error == nil)
  end
  local eopts = { sync = opts.sync, skip_confirm = opts.skip_confirm, export = opts.export }
  if opts.sync then
    local result, info = M.evaluate(bufnr, src, args, eopts)
    finish(result, info)
    return
  end
  M.evaluate(bufnr, src, args, eopts, finish)
end

--- Everything that can be executed in lines `s`..`e` of the buffer:
--- src blocks, #+CALL lines, inline src blocks and inline calls, in order
--- (org-babel-map-executables).
local function executables(bufnr, s, e)
  local lines = buf_lines(bufnr)
  local jobs = {}
  local covered = {}
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if b.start >= s and b.finish <= e then
      jobs[#jobs + 1] = { line = b.start, col = 0 }
    end
    for l = b.start, b.finish do
      covered[l] = true
    end
    if b.results then
      for l = b.results.start, b.results.finish do
        covered[l] = true
      end
    end
  end
  local in_block = false
  for i = s, math.min(e, #lines) do
    local l = lines[i]
    if l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") then
      in_block = true
    elseif l:match("^%s*#%+[Ee][Nn][Dd]_") then
      in_block = false
    elseif not in_block and not covered[i] and not l:match("^%s*#%+") and not l:match("^%s*: ") then
      for _, ib in ipairs(M.inline_all(l)) do
        jobs[#jobs + 1] = { line = i, col = ib.s, inline = true }
      end
    end
  end
  table.sort(jobs, function(x, y)
    if x.line ~= y.line then
      return x.line < y.line
    end
    return x.col < y.col
  end)
  return jobs
end

--- Execute every executable of lines `s`..`e` in order, each one asked
--- about like Emacs (org-babel-execute-buffer).
---@param opts? { skip_confirm?: boolean, sync?: boolean, on_done?: fun(n: integer) }
local function execute_many(bufnr, s, e, opts)
  opts = opts or {}
  M.wipe_error_buffer()
  local jobs = executables(bufnr, s, e)
  if #jobs == 0 then
    utils.notify("No source blocks to evaluate")
    if opts.on_done then
      opts.on_done(0)
    end
    return
  end
  for _, job in ipairs(jobs) do
    job.mark = vim.api.nvim_buf_set_extmark(bufnr, ns, job.line - 1, math.max(job.col - 1, 0), {})
  end
  local i = 0
  local step
  local function stop()
    for k = i + 1, #jobs do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, jobs[k].mark)
    end
    if opts.on_done then
      opts.on_done(i)
    end
  end
  -- a job that fails like an Emacs user-error stops the rest
  local function after(_, abort)
    if abort then
      return stop()
    end
    if opts.sync then
      return
    end
    vim.schedule(step)
  end
  step = function()
    i = i + 1
    local job = jobs[i]
    if not job then
      if opts.on_done then
        opts.on_done(#jobs)
      end
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, job.mark, {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, job.mark)
    local lnum = pos[1] + 1
    local aborted = false
    local function sync_done(okv, abort)
      aborted = abort or false
      after(okv, abort)
    end
    if job.inline then
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      local ib = M.inline_at(line, pos[2] + 1)
      if not ib then
        return step()
      end
      if opts.sync then
        M.execute_inline_at(bufnr, lnum, ib, { skip_confirm = opts.skip_confirm, sync = true, on_done = sync_done })
        if not aborted then
          return step()
        end
        return
      end
      M.execute_inline_at(bufnr, lnum, ib, { skip_confirm = opts.skip_confirm, on_done = after })
    else
      if opts.sync then
        M.execute({ bufnr = bufnr, lnum = lnum, skip_confirm = opts.skip_confirm, sync = true, on_done = sync_done })
        if not aborted then
          return step()
        end
        return
      end
      M.execute({ bufnr = bufnr, lnum = lnum, skip_confirm = opts.skip_confirm, on_done = after })
    end
  end
  step()
end

--- C-c C-v b: execute every src block, #+CALL line and inline element of
--- the buffer (org-babel-execute-buffer).
---@param opts? { bufnr?: integer, skip_confirm?: boolean, sync?: boolean, on_done?: fun(n: integer) }
function M.execute_buffer(opts)
  opts = opts or {}
  local bufnr = resolve_buf(opts.bufnr)
  execute_many(bufnr, 1, vim.api.nvim_buf_line_count(bufnr), opts)
end

--- C-c C-v s: the same for the subtree at the cursor.
---@param opts? { bufnr?: integer, lnum?: integer, skip_confirm?: boolean, sync?: boolean, on_done?: fun(n: integer) }
function M.execute_subtree(opts)
  opts = opts or {}
  local bufnr = resolve_buf(opts.bufnr)
  local file = get_file(bufnr)
  local lnum = opts.lnum or vim.api.nvim_win_get_cursor(0)[1]
  local hl = file and file:headline_at(lnum)
  local s, e = 1, vim.api.nvim_buf_line_count(bufnr)
  if hl then
    s, e = hl.line, hl.end_line
  end
  execute_many(bufnr, s, e, opts)
end

--- Delete the result of block `b` (org-babel-remove-result): the
--- `#+RESULTS:` keyword, its result and the blank lines before it.
local function remove_block_result(bufnr, b)
  local s, e = b.results.start, b.results.finish
  local lines = buf_lines(bufnr)
  while s - 1 > b.finish and lines[s - 1] and lines[s - 1]:match("^%s*$") do
    s = s - 1
  end
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
end

--- Remove every result in the buffer.
function M.remove_all_results(bufnr)
  bufnr = resolve_buf(bufnr)
  local list = blocks_mod.parse_blocks(buf_lines(bufnr))
  local n = 0
  for i = #list, 1, -1 do
    local b = list[i]
    if b.results and b.results.start > b.finish then
      remove_block_result(bufnr, b)
      n = n + 1
    end
  end
  utils.notify(string.format("Removed %d result%s", n, n == 1 and "" or "s"))
  return n
end

--- Remove the results of the block at cursor. With a count (Emacs C-u),
--- remove every result in the buffer.
function M.remove_result()
  if vim.v.count > 0 then
    return M.remove_all_results()
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or not b.results then
    utils.notify("No results to remove")
    return
  end
  remove_block_result(bufnr, b)
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

local BEGIN = "^%s*#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc]"

function M.next_block()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = buf_lines(0)
  for i = lnum + 1, #lines do
    if lines[i]:match(BEGIN) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  utils.notify("No next code block")
end

function M.prev_block()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = buf_lines(0)
  for i = lnum - 1, 1, -1 do
    if lines[i]:match(BEGIN) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  utils.notify("No previous code block")
end

---------------------------------------------------------------------------
-- Edit special
---------------------------------------------------------------------------

--- C-c ': edit the src block at the cursor in a buffer with the
--- language's filetype (org-edit-src-code). The common indentation is
--- removed and put back (plus `edit_src_content_indentation`) unless the
--- block has `-i` or `src_preserve_indentation` is set. With
--- `opts.session` (C-u C-c ') a block with a :session shows its session
--- instead.
---@param opts? { session?: boolean }
function M.edit_special(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call then
    return false
  end
  if opts.session and session_mod.name(b.args.session) then
    return M.switch_to_session({ no_register = true })
  end
  local raw = vim.api.nvim_buf_get_lines(bufnr, b.start, b.finish - 1, false)
  local body = blocks_mod.unescape(raw)
  local preserve = blocks_mod.preserve_indentation(b.switches)
  local dedented = preserve and body or blocks_mod.dedent(body)
  if #dedented == 0 then
    dedented = { "" }
  end
  local content_indent = require("org.config").opts.edit_src_content_indentation or 0
  local prefix = preserve and "" or ((b.indent or "") .. string.rep(" ", content_indent))
  local ft = vim.filetype.match({ filename = "x." .. langs.ext(b.lang) }) or b.lang
  require("org.special").open({
    source_buf = bufnr,
    start_line = b.start + 1,
    end_line = b.finish - 1,
    lines = dedented,
    filetype = ft,
    name = "src-" .. (b.lang ~= "" and b.lang or "block"),
    kind = "src",
    switches = b.switches,
    to_source = function(lines)
      local out = {}
      for i, l in ipairs(blocks_mod.escape(lines)) do
        out[i] = l == "" and "" or prefix .. l
      end
      return out
    end,
  })
end

---------------------------------------------------------------------------
-- Tangling (see org.babel.tangle)
---------------------------------------------------------------------------

--- Tangle `bufnr` (org-babel-tangle). Returns the list of written files.
---@param opts? { bufnr?: integer, target?: string only tangle this file, only_line?: integer, tangle_file?: string, silent?: boolean }
function M.tangle(opts)
  return require("org.babel.tangle").tangle(opts)
end

--- Begin / end link comments of block `b` used around noweb expansions
--- with `:comments noweb`.
function M.tangle_comment_links(bufnr, b, file)
  return require("org.babel.tangle").comment_links(bufnr, b, file, nil, true)
end

function M.tangle_command(args)
  args = vim.trim(args or "")
  return M.tangle({ target = args ~= "" and utils.expand(args, vim.fn.expand("%:p:h")) or nil })
end

--- C-c C-v t: tangle the file. With a count of 1 (Emacs C-u) only the block
--- at the cursor, with a count of 2 or more (C-u C-u) the blocks with the
--- same `:tangle` value as the block at the cursor.
function M.tangle_action()
  local count = vim.v.count
  if count == 0 then
    return M.tangle()
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call then
    utils.warn("Point is not in a source code block")
    return
  end
  if count == 1 then
    return M.tangle({ only_line = b.start })
  end
  return M.tangle({ tangle_file = blocks_mod.unquote(b.args.tangle or "no") })
end

--- C-c C-v f: tangle another org file (org-babel-tangle-file).
function M.tangle_file(path)
  if not path then
    local ok, v = pcall(vim.fn.input, { prompt = "File to tangle: ", completion = "file", cancelreturn = vim.NIL })
    if not ok or v == vim.NIL or vim.trim(v) == "" then
      return
    end
    path = vim.trim(v)
  end
  path = utils.expand(path, vim.fn.getcwd())
  if not utils.exists(path) then
    utils.warn("No such file: " .. path)
    return
  end
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  return M.tangle({ bufnr = bufnr })
end

--- Propagate edits of a tangled file back to the Org file (org-babel-detangle).
function M.detangle(path)
  return require("org.babel.tangle").detangle(path)
end

--- Jump from a tangled file to its Org block (org-babel-tangle-jump-to-org).
function M.jump_to_org()
  return require("org.babel.tangle").jump_to_org()
end

--- Remove tangle comments from the current buffer (org-babel-tangle-clean).
function M.tangle_clean()
  return require("org.babel.tangle").clean(0)
end

--- Tangle the Lua blocks of an Org file and run them (a Lua counterpart
--- of org-babel-load-file).
function M.load_file(path)
  return require("org.babel.tangle").load_file(path)
end

--- :Org detangle [file]
function M.detangle_command(args)
  args = vim.trim(args or "")
  return M.detangle(args ~= "" and args or nil)
end

--- :Org babel_load_file [file] (default: the current file)
function M.load_file_command(args)
  args = vim.trim(args or "")
  local path = args ~= "" and args or vim.api.nvim_buf_get_name(0)
  local ok, err = pcall(M.load_file, path)
  if not ok then
    utils.error(tostring(err))
  end
end

---------------------------------------------------------------------------
-- Hiding results (org-babel-hide-result-toggle / org-babel-result-hide-all)
---------------------------------------------------------------------------

--- Fold every `#+RESULTS` keyword with its result (org-babel-result-hide-all).
--- TAB on a `#+RESULTS` line toggles one result.
function M.hide_all_results()
  local lines = buf_lines(0)
  local n = 0
  for i, l in ipairs(lines) do
    if blocks_mod.match_results(l) and blocks_mod.results_end(lines, i) > i then
      if vim.fn.foldlevel(i) > 0 and vim.fn.foldclosed(i) == -1 then
        pcall(vim.cmd, i .. "foldclose")
        n = n + 1
      end
    end
  end
  return n
end

--- C-c C-c on a src block or #+CALL (org-babel-execute-safely-maybe):
--- nothing with `babel.no_eval_on_ctrl_c_ctrl_c`.
function M.ctrl_c_ctrl_c()
  if require("org.config").opts.babel.no_eval_on_ctrl_c_ctrl_c then
    return true
  end
  return M.execute_block()
end

---------------------------------------------------------------------------
-- org-sbe (ob-table)
---------------------------------------------------------------------------

--- The result of the src block `name` called with `vars` (a list of
--- { name, value } where value is the text of the argument), as a
--- trimmed string: what `(org-sbe name (var value)...)` gives a table
--- formula. `header` holds header arguments.
function M.sbe(name, vars, header, bufnr)
  bufnr = resolve_buf(bufnr)
  local parts = {}
  for i, v in ipairs(vars or {}) do
    parts[i] = v[1] .. "=" .. v[2]
  end
  local ref = name .. "[" .. (header or "") .. "](" .. table.concat(parts, ", ") .. ")"
  local value = M.resolve_var(bufnr, ref, {}, {}, {})
  if type(value) ~= "string" then
    value = lisp.prin1(value)
  end
  return vim.trim(value)
end

--- `org-sbe` for the Emacs Lisp formula interpreter (org.table.elisp):
--- `x` is the unevaluated form. Like the Emacs macro, a value preceded by
--- the symbol `$` is passed as a string ("$$2" in a formula).
function M.sbe_form(x)
  local el = require("org.table.elisp")
  local function text(v)
    if type(v) == "table" and v.name then
      return v.name
    end
    return type(v) == "string" and v or el.to_string(v)
  end
  local name = text(x[2])
  local k = 3
  local header = ""
  if type(x[k]) == "string" then
    header = x[k]
    k = k + 1
  end
  local vars = {}
  for i = k, x.n do
    local spec = x[i]
    if type(spec) == "table" and spec.n then
      local values, quote = {}, false
      for j = 2, spec.n do
        local v = spec[j]
        if type(v) == "table" and v.name == "$" then
          quote = true
        else
          if quote then
            values[#values + 1] = lisp.prin1(type(v) == "string" and v or text(v))
          elseif el.is_float(v) or type(v) == "number" then
            values[#values + 1] = el.to_string(v)
          else
            values[#values + 1] = text(v)
          end
          quote = false
        end
      end
      local value = values[1] or ""
      if #values > 1 then
        value = "'(" .. table.concat(values, " ") .. ")"
      end
      vars[#vars + 1] = { text(spec[1]), value }
    end
  end
  if name == "" then
    return ""
  end
  return M.sbe(name, vars, header)
end

---------------------------------------------------------------------------
-- Library of Babel
---------------------------------------------------------------------------

--- Add the named src blocks of `path` (default: prompt) to the Library of
--- Babel, so `#+CALL:`, `:var` and noweb references can use them from any
--- buffer (org-babel-lob-ingest).
function M.lob_ingest(path)
  local lines
  if path then
    lines = utils.readfile(utils.expand(path, vim.fn.getcwd()))
    if not lines then
      utils.warn("Cannot read " .. path)
      return 0
    end
  else
    local ok, v = pcall(vim.fn.input, {
      prompt = "Ingest file (empty = current buffer): ",
      completion = "file",
      cancelreturn = vim.NIL,
    })
    if not ok or v == vim.NIL then
      return 0
    end
    v = vim.trim(v)
    if v == "" then
      lines = buf_lines(0)
    else
      lines = utils.readfile(utils.expand(v, vim.fn.expand("%:p:h")))
      if not lines then
        utils.warn("Cannot read " .. v)
        return 0
      end
    end
  end
  local n = 0
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if not b.call and b.name then
      M.library[b.name] = {
        name = b.name,
        lang = b.lang,
        body = b.body,
        params = b.params,
        header_lines = b.header_lines,
        switches = b.switches,
        start = 0,
        lob = true,
      }
      n = n + 1
    end
  end
  utils.notify(string.format("%d src block%s added to Library of Babel", n, n == 1 and "" or "s"))
  return n
end

---------------------------------------------------------------------------
-- Inspection and navigation (C-c C-v ...)
---------------------------------------------------------------------------

--- Body of a block with noweb references expanded and :prologue,
--- variables and :epilogue added (org-babel-expand-src-block; with
--- `purpose` "tangle" what tangling writes, `-r` coderefs removed).
function M.expand_body(bufnr, b, args, purpose)
  local body = b.body
  local nw = noweb_for(args, purpose or "eval")
  if nw then
    body = M.expand_noweb(bufnr, body, 0, nw == "strip" and "strip" or nil, args, purpose or "eval")
  end
  local out
  if args["no-expand"] then
    out = body
  else
    local meta = {}
    local ok, vars = pcall(resolve_vars, bufnr, args, meta)
    if not ok then
      vars = {}
    end
    local colnames = {}
    for _, pair in ipairs(meta.colnames or {}) do
      colnames[pair[1]] = pair[2]
    end
    out = vim.split(langs.expand(b.lang, body, args, vars, colnames), "\n", { plain = true })
  end
  if purpose == "tangle" and (b.switches or ""):match("%-r") then
    local pat = blocks_mod.coderef_pattern(b.switches)
    local stripped = {}
    for i, l in ipairs(out) do
      stripped[i] = l:gsub(pat, "")
    end
    out = stripped
  end
  return out
end

local function block_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b then
    utils.warn("No source block at point")
    return nil
  end
  if b.call then
    local args, target = M.block_args(b, b.file, bufnr)
    if not target then
      utils.warn("#+CALL: no block named " .. tostring(b.target))
      return nil
    end
    return bufnr, target, args, b
  end
  return bufnr, b, b.args, b
end

local function show_scratch(lines, ft, name)
  vim.cmd("botright split")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modified = false
  if ft and ft ~= "" then
    vim.bo[buf].filetype = ft
  end
  pcall(vim.api.nvim_buf_set_name, buf, name .. " #" .. buf)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  return buf
end

--- C-c C-v v: show the expanded body of the block (org-babel-expand-src-block).
function M.expand_block()
  local bufnr, src, args = block_at_cursor()
  if not bufnr then
    return
  end
  local ft = vim.filetype.match({ filename = "x." .. langs.ext(src.lang) }) or src.lang
  return show_scratch(M.expand_body(bufnr, src, args, "eval"), ft, "org-babel-expanded")
end

--- C-c C-v I: show the block's language, name and merged header arguments.
function M.view_info()
  local _, src, args = block_at_cursor()
  if not src then
    return
  end
  local out = { "Lang: " .. (src.lang ~= "" and src.lang or "none") }
  if src.name then
    out[#out + 1] = "Name: " .. src.name
  end
  out[#out + 1] = "Header arguments:"
  local keys = {}
  for k, v in pairs(args) do
    if type(v) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local spec = {}
  for _, cat in ipairs({ "collection", "type", "format", "handling" }) do
    if args.results_spec[cat] then
      spec[#spec + 1] = args.results_spec[cat]
    end
  end
  out[#out + 1] = "  :results " .. table.concat(spec, " ")
  for _, v in ipairs(args.vars) do
    out[#out + 1] = "  :var " .. v.name .. "=" .. v.value
  end
  for _, k in ipairs(keys) do
    out[#out + 1] = "  :" .. k .. " " .. args[k]
  end
  utils.notify(table.concat(out, "\n"))
  return out
end

---------------------------------------------------------------------------
-- Sessions (C-c C-v z, C-z, l)
---------------------------------------------------------------------------

--- Session of the block at the cursor (started when needed), or nil.
local function cursor_session()
  local bufnr, src, args = block_at_cursor()
  if not bufnr then
    return nil
  end
  local name = session_mod.name(args.session)
  if not name then
    utils.warn("This block is not using a session (:session)")
    return nil
  end
  if not session_mod.supported(src.lang, langs.family(src.lang)) then
    utils.warn("No session support for " .. tostring(src.lang))
    return nil
  end
  local ok, sess = pcall(get_session, bufnr, src.lang, args, name)
  if not ok then
    utils.error("babel: " .. tostring(sess))
    return nil
  end
  return sess, bufnr, src, args
end

--- C-c C-v C-z: show the session of the block at the cursor
--- (org-babel-switch-to-session). The block body is copied to the unnamed
--- register. With a count, the block's :var values are first assigned in
--- the session (org-babel-prep-session).
---@param opts? { no_register?: boolean }
function M.switch_to_session(opts)
  opts = opts or {}
  local sess, bufnr, src, args = cursor_session()
  if not sess then
    return
  end
  if not opts.no_register then
    vim.fn.setreg('"', table.concat(src.body, "\n"))
  end
  if vim.v.count > 0 then
    local ok, vars = pcall(resolve_vars, bufnr, args, {})
    if not ok then
      utils.error("babel: " .. tostring(vars))
    elseif #vars > 0 then
      if sess.kind == "lua" then
        for _, v in ipairs(vars) do
          sess.env[v.name] = langs.lua_value(v.value)
        end
      else
        session_mod.eval(sess, table.concat(langs.var_lines(src.lang, vars, args), "\n"), "output", function() end)
      end
    end
  end
  return session_mod.show(sess)
end

--- C-c C-v z: show the session and edit the block in its edit buffer
--- (org-babel-switch-to-session-with-code).
function M.switch_to_session_with_code()
  local org_win = vim.api.nvim_get_current_win()
  if not M.switch_to_session() then
    return
  end
  vim.api.nvim_set_current_win(org_win)
  return M.edit_special()
end

--- C-c C-v l: send the body of the block (noweb expanded) to its session
--- and show the session (org-babel-load-in-session).
function M.load_in_session()
  local sess, bufnr, src, args = cursor_session()
  if not sess then
    return
  end
  local body = src.body
  if noweb_for(args, "eval") then
    body = M.expand_noweb(bufnr, body, 0, nil, args, "eval")
  end
  session_mod.eval(sess, table.concat(body, "\n"), "output", function(res)
    if res.error then
      utils.error("babel: " .. vim.trim(res.error))
    end
  end, { timeout = require("org.config").opts.babel.timeout })
  return session_mod.show(sess)
end

--- Stop the session of the block at the cursor (in Emacs: kill its buffer).
--- `name` ("lang:name" or a session object) stops that session instead.
function M.kill_session(name)
  if name then
    return session_mod.kill(name)
  end
  local bufnr, src, args = block_at_cursor()
  if not bufnr then
    return false
  end
  local sname = session_mod.name(args.session)
  local sess = sname and session_mod.find(langs.family(src.lang), sname)
  if not sess then
    utils.notify("No running session for this block")
    return false
  end
  session_mod.kill(sess)
  utils.notify("Killed session " .. sname)
  return true
end

---------------------------------------------------------------------------
-- More C-c C-v commands
---------------------------------------------------------------------------

--- C-c C-v a: show the hash of the block (org-babel-sha1-hash), the one
--- `:cache yes` stores in `#+RESULTS[hash]:`.
function M.sha1_hash()
  local bufnr, src, args = block_at_cursor()
  if not bufnr then
    return
  end
  local meta = {}
  local ok, vars = pcall(resolve_vars, bufnr, args, meta)
  if not ok then
    utils.error("babel: " .. tostring(vars))
    return
  end
  local body = src.body
  if noweb_for(args, "eval") then
    body = M.expand_noweb(bufnr, body, 0, nil, args, "eval")
  end
  local out_file = M.file_param(args, src.name)
  if out_file then
    args.file = out_file
  end
  local hash = M.cache_hash(src.lang, body, args, vars, meta)
  utils.notify(hash)
  return hash
end

--- C-c C-v h: list the Babel key bindings (org-babel-describe-bindings).
function M.describe_bindings()
  local maps = require("org.config").opts.mappings
  local acts = require("org.actions").list
  local rows = {}
  for name, a in pairs(acts) do
    if name:match("^babel_") then
      local keys = {}
      for _, section in ipairs({ maps.org or {}, maps.emacs or {} }) do
        vim.list_extend(keys, require("org.config").lhs_list(section[name]))
      end
      if #keys > 0 then
        rows[#rows + 1] = { table.concat(keys, " "), a.desc }
      end
    end
  end
  table.sort(rows, function(x, y)
    return x[2] < y[2]
  end)
  local width = 0
  for _, r in ipairs(rows) do
    width = math.max(width, vim.fn.strdisplaywidth(r[1]))
  end
  local out = { "Babel key bindings", "" }
  for _, r in ipairs(rows) do
    out[#out + 1] = r[1] .. string.rep(" ", width - vim.fn.strdisplaywidth(r[1]) + 2) .. r[2]
  end
  return show_scratch(out, "", "org-babel-bindings")
end

--- C-c C-v C-M-h: select the body of the block (org-babel-mark-block).
function M.mark_block()
  local b = M.at_block(0, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call then
    utils.warn("No source block at point")
    return
  end
  if b.finish - 1 < b.start + 1 then
    utils.notify("The block is empty")
    return
  end
  vim.api.nvim_win_set_cursor(0, { b.start + 1, 0 })
  vim.cmd("normal! V")
  vim.api.nvim_win_set_cursor(0, { b.finish - 1, 0 })
end

--- C-c C-v x: run a key sequence (Normal-mode keys) in the edit buffer of
--- the block and write the result back (org-babel-do-key-sequence-in-edit-buffer).
---@param keys? string e.g. "gg=G"
function M.do_key_sequence_in_edit_buffer(keys)
  if not keys then
    keys = utils.input({ prompt = "Keys to run in the edit buffer: " })
    if not keys or keys == "" then
      return
    end
  end
  local org_win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(org_win)
  local before = vim.api.nvim_get_current_buf()
  if M.edit_special() == false or vim.api.nvim_get_current_buf() == before then
    utils.warn("No source block at point")
    return
  end
  local ebuf = vim.api.nvim_get_current_buf()
  vim.cmd("normal " .. vim.keycode(keys))
  if vim.api.nvim_buf_is_valid(ebuf) then
    if vim.bo[ebuf].modified then
      vim.api.nvim_buf_call(ebuf, function()
        vim.cmd("silent write")
      end)
    end
    pcall(vim.api.nvim_buf_delete, ebuf, { force = true })
  end
  if vim.api.nvim_win_is_valid(org_win) then
    vim.api.nvim_set_current_win(org_win)
    pcall(vim.api.nvim_win_set_cursor, org_win, cursor)
  end
end

---------------------------------------------------------------------------
-- Evaluation during export (org-export-use-babel)
---------------------------------------------------------------------------

--- Evaluate the code of `bufnr` for export and return the resulting lines;
--- the buffer itself is not changed. Like Emacs: blocks and #+CALL lines
--- with `:exports results|both` are evaluated and their results replaced,
--- `:exports code|none` blocks only run when they use a session (to keep it
--- in step), inline src blocks and calls get their `{{{results}}}`, and
--- `:eval never-export|no-export` (or never/no) blocks are left alone.
---@param lines? string[] the lines to evaluate (default: the buffer's)
---@return string[]
function M.export_evaluate(bufnr, lines)
  bufnr = resolve_buf(bufnr)
  lines = lines or buf_lines(bufnr)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  vim.b[scratch].org_babel_dir = buf_dir(bufnr)
  local file = get_file(scratch)
  local jobs = {}
  local blocked = { never = true, no = true, ["never-export"] = true, ["no-export"] = true }
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if not in_commented(file, b.start) then
      local args = M.block_args(b, file, scratch)
      if args and not blocked[args.eval or ""] then
        -- #+CALL lines get :exports results from babel.default_lob_header_args
        local exports = args.exports or "code"
        local silent = (exports == "code" or exports == "none") and session_mod.name(args.session) ~= nil
        if exports == "results" or exports == "both" or silent then
          jobs[#jobs + 1] = { line = b.start, silent = silent }
        end
      end
    end
  end
  -- inline src blocks and calls in the text (not inside blocks)
  local in_block = false
  for i, l in ipairs(lines) do
    if l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") then
      in_block = true
    elseif l:match("^%s*#%+[Ee][Nn][Dd]_") then
      in_block = false
    elseif not in_block and not l:match("^%s*#%+") and not l:match("^%s*:") and not in_commented(file, i) then
      for _, ib in ipairs(M.inline_all(l)) do
        jobs[#jobs + 1] = { line = i, inline = ib, col = ib.s }
      end
    end
  end
  table.sort(jobs, function(x, y)
    if x.line ~= y.line then
      return x.line < y.line
    end
    return (x.col or 0) < (y.col or 0)
  end)
  for _, job in ipairs(jobs) do
    job.mark = vim.api.nvim_buf_set_extmark(scratch, ns, job.line - 1, (job.col or 1) - 1, {})
  end
  -- like Emacs, each block is confirmed on its own (org-confirm-babel-evaluate,
  -- :eval query / query-export)
  for _, job in ipairs(jobs) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(scratch, ns, job.mark, {})
    local lnum = pos[1] + 1
    local ok, err = pcall(function()
      if job.inline then
        local line = vim.api.nvim_buf_get_lines(scratch, lnum - 1, lnum, false)[1] or ""
        local ib = M.inline_at(line, pos[2] + 1)
        if ib then
          M.execute_inline_at(scratch, lnum, ib, { sync = true, export = true })
        end
      else
        M.execute({
          bufnr = scratch,
          lnum = lnum,
          sync = true,
          export = true,
          handling = job.silent and "none" or nil,
        })
      end
    end)
    if not ok then
      utils.error("babel (export): " .. tostring(err))
    end
  end
  local out = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
  pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  return out
end

--- Header arguments known to Org Babel (for completion and checking).
M.HEADER_ARGS = {
  cache = { "yes", "no" },
  cmdline = {},
  colnames = { "nil", "no", "yes" },
  comments = { "no", "link", "yes", "org", "both", "noweb" },
  dir = {},
  epilogue = {},
  eval = { "yes", "no", "query", "never", "never-export", "no-export", "query-export", "strip-export" },
  exports = { "code", "results", "both", "none" },
  file = {},
  ["file-desc"] = {},
  ["file-ext"] = {},
  ["file-mode"] = {},
  hlines = { "no", "yes" },
  mkdirp = { "yes", "no" },
  ["no-expand"] = {},
  noeval = {},
  noweb = { "yes", "no", "tangle", "no-export", "strip-export", "strip-tangle", "eval", "tangle-eval" },
  ["noweb-prefix"] = { "yes", "no" },
  ["noweb-ref"] = {},
  ["noweb-sep"] = {},
  ["output-dir"] = {},
  padline = { "yes", "no" },
  post = {},
  prologue = {},
  results = {
    "value",
    "output",
    "table",
    "vector",
    "list",
    "scalar",
    "verbatim",
    "file",
    "raw",
    "org",
    "html",
    "latex",
    "code",
    "pp",
    "drawer",
    "link",
    "graphics",
    "replace",
    "silent",
    "none",
    "append",
    "prepend",
  },
  rownames = { "no", "yes" },
  sep = {},
  separator = {},
  session = { "none" },
  stdin = {},
  shebang = {},
  tangle = { "yes", "no" },
  ["tangle-mode"] = {},
  var = {},
  wrap = {},
  db = {},
}

--- C-c C-v c: warn about unknown header arguments (org-babel-check-src-block).
function M.check_block()
  local _, src = block_at_cursor()
  if not src then
    return
  end
  local bad = {}
  local lines = vim.list_extend(vim.deepcopy(src.header_lines or {}), { src.params or "" })
  for _, l in ipairs(lines) do
    for _, p in ipairs(blocks_mod.parse_header_string(l)) do
      if not M.HEADER_ARGS[p.key] then
        bad[#bad + 1] = ":" .. p.key
      end
    end
  end
  if #bad > 0 then
    utils.warn("Unknown header argument(s): " .. table.concat(bad, " "))
  else
    utils.notify("No problems found")
  end
  return bad
end

--- C-c C-v j: insert a header argument on the #+begin_src line.
---@param key? string
---@param value? string
function M.insert_header_arg(key, value)
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call then
    utils.warn("No source block at point")
    return
  end
  if not key then
    local names = vim.tbl_keys(M.HEADER_ARGS)
    table.sort(names)
    key = utils.select(names, { prompt = "Header argument" })
    if not key then
      return
    end
  end
  if not value then
    local choices = M.HEADER_ARGS[key] or {}
    if #choices > 0 then
      value = utils.select(choices, { prompt = ":" .. key })
    else
      value = utils.input({ prompt = ":" .. key .. " " })
    end
    if value == nil then
      return
    end
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, b.start - 1, b.start, false)[1]
  local text = ":" .. key .. (vim.trim(value) ~= "" and (" " .. vim.trim(value)) or "")
  vim.api.nvim_buf_set_lines(bufnr, b.start - 1, b.start, false, { (line:gsub("%s+$", "")) .. " " .. text })
end

--- Names of the src blocks in `lines`.
local function block_names(lines)
  local names = {}
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if b.name and not b.call then
      names[#names + 1] = b.name
    end
  end
  return names
end

--- C-c C-v g: go to a named src block (org-babel-goto-named-src-block).
function M.goto_named_block(name)
  local lines = buf_lines(0)
  if not name then
    local names = block_names(lines)
    if #names == 0 then
      utils.notify("No named src blocks")
      return
    end
    name = utils.select(names, { prompt = "Src block" })
    if not name then
      return
    end
  end
  local b = M.find_named_block(lines, name)
  if not b or b.lob then
    utils.warn("No src block named " .. name)
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { b.name_line or b.start, 0 })
  pcall(vim.cmd, "normal! zv")
end

--- C-c C-v r: go to a named result (org-babel-goto-named-result).
function M.goto_named_result(name)
  local lines = buf_lines(0)
  if not name then
    local names = {}
    for _, l in ipairs(lines) do
      local nm = blocks_mod.match_results(l)
      if nm and nm ~= "" then
        names[#names + 1] = nm
      end
    end
    if #names == 0 then
      utils.notify("No named results")
      return
    end
    name = utils.select(names, { prompt = "Result" })
    if not name then
      return
    end
  end
  for i, l in ipairs(lines) do
    if blocks_mod.match_results(l) == name then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      pcall(vim.cmd, "normal! zv")
      return
    end
  end
  utils.warn("No result named " .. name)
end

--- C-c C-v u: go to the #+begin_src line of the block at the cursor.
function M.goto_block_head()
  local b = M.at_block(0, vim.api.nvim_win_get_cursor(0)[1])
  if not b then
    utils.warn("Not in a src block")
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { b.start, 0 })
end

--- C-c C-v o: open the result of the block: a file link is followed,
--- anything else is shown in a scratch buffer.
function M.open_result()
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or not b.results then
    utils.notify("No results for this block")
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, b.results.start, b.results.finish, false)
  local first = vim.trim(lines[1] or "")
  local links = require("org.links").parse_links(first)
  if #lines == 1 and links[1] and links[1].start_col == 1 then
    return require("org.links").open(links[1].target, { bufnr = bufnr })
  end
  local text = results.read(lines)
  if type(text) == "table" then
    return show_scratch(lines, "org", "org-babel-results")
  end
  return show_scratch(vim.split(text, "\n", { plain = true }), "", "org-babel-results")
end

--- C-c C-v d: split the block at the cursor into two blocks, wrap the
--- visual selection in a new block, or insert an empty block
--- (org-babel-demarcate-block).
function M.demarcate_block()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode = vim.fn.mode()
  local visual = mode == "v" or mode == "V" or mode == "\22"
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local b = M.at_block(bufnr, lnum)
  local function header_of(block)
    local l = vim.api.nvim_buf_get_lines(bufnr, block.start - 1, block.start, false)[1]
    return l, vim.api.nvim_buf_get_lines(bufnr, block.finish - 1, block.finish, false)[1]
  end
  if b and not b.call and lnum > b.start and lnum <= b.finish then
    local begin_line, end_line = header_of(b)
    local s, e = lnum, lnum - 1
    if visual then
      local srow, _, erow = utils.visual_range()
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
      s, e = math.max(srow, b.start + 1), math.min(erow, b.finish - 1)
    end
    local body = vim.api.nvim_buf_get_lines(bufnr, b.start, b.finish - 1, false)
    local rel_s, rel_e = s - b.start, e - b.start
    local new = { begin_line }
    vim.list_extend(new, vim.list_slice(body, 1, rel_s - 1))
    vim.list_extend(new, { end_line, "", begin_line })
    vim.list_extend(new, vim.list_slice(body, rel_s, rel_e))
    if visual then
      vim.list_extend(new, { end_line, "", begin_line })
      vim.list_extend(new, vim.list_slice(body, rel_e + 1))
    else
      vim.list_extend(new, vim.list_slice(body, rel_s))
    end
    new[#new + 1] = end_line
    vim.api.nvim_buf_set_lines(bufnr, b.start - 1, b.finish, false, new)
    vim.api.nvim_win_set_cursor(0, { s + 3, 0 })
    return
  end
  -- outside a block: wrap the selection (or insert an empty block)
  local lang = b and not b.call and b.lang or nil
  if not lang then
    local prev
    for _, x in ipairs(blocks_mod.parse_blocks(buf_lines(bufnr))) do
      if not x.call and x.finish < lnum then
        prev = x
      end
    end
    lang = utils.input({ prompt = "Lang: ", default = prev and prev.lang or "" })
    if lang == nil then
      return
    end
    lang = vim.trim(lang)
  end
  local indent = (vim.api.nvim_get_current_line():match("^(%s*)")) or ""
  if visual then
    local srow, _, erow = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    local sel = vim.api.nvim_buf_get_lines(bufnr, srow - 1, erow, false)
    local new = { indent .. "#+begin_src " .. lang }
    vim.list_extend(new, blocks_mod.escape(sel))
    new[#new + 1] = indent .. "#+end_src"
    vim.api.nvim_buf_set_lines(bufnr, srow - 1, erow, false, new)
    vim.api.nvim_win_set_cursor(0, { srow, 0 })
    return
  end
  local cur = vim.api.nvim_get_current_line()
  local at = cur:match("^%s*$") and lnum - 1 or lnum
  vim.api.nvim_buf_set_lines(bufnr, at, at, false, { indent .. "#+begin_src " .. lang, indent, indent .. "#+end_src" })
  vim.api.nvim_win_set_cursor(0, { at + 2, #indent })
end

return M
