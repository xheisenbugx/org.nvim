---@mod org.babel Source block evaluation, tangling and editing
---
--- Evaluation runs asynchronously via `vim.system` (Lua blocks run inside
--- Neovim). Results are written below the block as `#+RESULTS:`.

local blocks_mod = require("org.babel.blocks")
local langs = require("org.babel.langs")
local results = require("org.babel.results")
local session_mod = require("org.babel.session")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.babel")

M.parse_blocks = blocks_mod.parse_blocks
M.parse_header_string = blocks_mod.parse_header_string

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

--- Merged header args for a block (resolving #+CALL targets).
function M.block_args(b, file, bufnr)
  if b.call then
    local lines = buf_lines(bufnr)
    local target = M.find_named_block(lines, b.target)
    if not target then
      return nil
    end
    local args = blocks_mod.header_args(target, not target.lob and file or nil)
    blocks_mod.merge(args, blocks_mod.parse_header_string(table.concat(b.header_lines, " ")))
    blocks_mod.merge(args, blocks_mod.parse_header_string(b.params))
    if b.call_args ~= "" then
      blocks_mod.merge(args, { { key = "var", value = b.call_args } })
    end
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
local function noweb_reference(bufnr, ref, depth, purpose, ctx)
  local call_name = ref:match("^(.-)%(.*%)$")
  if call_name then
    -- <<name(args)>>: the result of evaluating the named block with args
    local ok, v = pcall(M.resolve_var, bufnr, ref, {}, {}, { skip_confirm = ctx.skip_confirm })
    if not ok then
      if type(bufnr) == "number" and (purpose or "eval") == "eval" then
        error("noweb <<" .. ref .. ">>: " .. tostring(v), 0)
      end
      utils.warn("noweb <<" .. ref .. ">>: " .. tostring(v))
      return { "" }
    end
    return vim.split(results.stringify(v), "\n", { plain = true })
  end
  local function body_of(b, args)
    local nw = noweb_for(args, purpose or "eval")
    if nw then
      return M.expand_noweb(bufnr, b.body, depth + 1, nw == "strip" and "strip" or nil, args, purpose)
    end
    return b.body
  end
  -- a block named `ref` is unique
  for _, b in ipairs(ctx.all) do
    if not b.call and b.name == ref and not in_commented(ctx.file, b.start) then
      return body_of(b, blocks_mod.header_args(b, ctx.file))
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
    if not line:find("<<[^%s<>]+>>") then
      out[#out + 1] = line
    elseif mode == "strip" then
      local stripped = line:gsub("<<[^%s<>]+>>", "")
      if not stripped:match("^%s*$") then
        out[#out + 1] = stripped
      end
    else
      local built = { "" }
      local pos = 1
      while true do
        local s, e, ref = line:find("<<([^%s<>]+)>>", pos)
        if not s then
          built[#built] = built[#built] .. line:sub(pos)
          break
        end
        built[#built] = built[#built] .. line:sub(pos, s - 1)
        local prefix = use_prefix and built[#built] or ""
        for i, x in ipairs(noweb_reference(bufnr, ref, depth, purpose, ctx)) do
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

--- Apply an Emacs-style index (`2`, `-1`, `1:3`, `` = all) to a list.
--- Returns the element, or a sub-list for ranges (second value true).
local function index_list(list, spec)
  spec = vim.trim(spec or "")
  local n = #list
  local function norm(i)
    i = tonumber(i)
    if i < 0 then
      i = n + i
    end
    return i + 1
  end
  if spec == "" or spec == "*" then
    return list, true
  end
  local a, b = spec:match("^(%-?%d*):(%-?%d*)$")
  if a then
    return vim.list_slice(list, a == "" and 1 or norm(a), b == "" and n or norm(b)), true
  end
  if not tonumber(spec) then
    return list, true
  end
  return list[norm(spec)], false
end

--- Index a table value with `[rows,cols]` (0-based, ranges, negatives).
function M.index_value(value, index)
  if type(value) ~= "table" then
    return value
  end
  local idx = vim.split(index, ",", { plain = true })
  local rows, ranged = index_list(value, idx[1])
  if idx[2] == nil then
    return rows
  end
  if not ranged then
    return type(rows) == "table" and (index_list(rows, idx[2])) or rows
  end
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = type(row) == "table" and (index_list(row, idx[2])) or row
  end
  return out
end

local function is_rows(v)
  if type(v) ~= "table" or #v == 0 then
    return false
  end
  for _, r in ipairs(v) do
    if type(r) ~= "table" and r ~= "hline" then
      return false
    end
  end
  return true
end

--- Handle :colnames / :rownames for a table value (rows with "hline"
--- markers). Returns the rows passed to the code, recording the names in
--- `meta` so they can be re-attached to the result.
local function disassemble(rows, args, meta)
  local colnames = args and args.colnames
  local rownames = args and args.rownames
  local names
  if colnames == "yes" or colnames == "t" then
    local first = rows[1] ~= "hline" and rows[1] or nil
    if first then
      names = first
      rows = vim.list_slice(rows, 2)
    end
  elseif colnames ~= "no" and #rows > 2 and rows[1] ~= "hline" and rows[2] == "hline" then
    names = rows[1]
    rows = vim.list_slice(rows, 2)
  end
  -- :hlines yes keeps the horizontal lines (as "hline" rows)
  local keep_hlines = args and args.hlines == "yes"
  local out = {}
  for _, r in ipairs(rows) do
    if r ~= "hline" or keep_hlines then
      out[#out + 1] = r
    end
  end
  local rnames
  if rownames == "yes" or rownames == "t" then
    rnames = {}
    for i, r in ipairs(out) do
      if type(r) == "table" then
        rnames[i] = r[1]
        out[i] = vim.list_slice(r, 2)
      end
    end
    if names then
      names = vim.list_slice(names, 2)
    end
  end
  if meta then
    meta.colnames = meta.colnames or names
    meta.rownames = meta.rownames or rnames
  end
  return out
end

--- Re-attach column / row names to a table result.
function M.reassemble(value, args, meta)
  if not is_rows(value) then
    return value
  end
  local colnames = meta and meta.colnames
  local explicit = args.colnames and args.colnames:match("^'?%((.*)%)$")
  if explicit then
    colnames = {}
    for _, tok in ipairs(vim.split(vim.trim(explicit), "%s+", { trimempty = true })) do
      colnames[#colnames + 1] = blocks_mod.unquote(tok)
    end
  end
  if args.colnames == "no" then
    colnames = nil
  end
  local out = vim.deepcopy(value)
  local rnames = meta and meta.rownames
  if rnames and #rnames == #out then
    for i, r in ipairs(out) do
      if type(r) == "table" then
        table.insert(r, 1, rnames[i])
      end
    end
    if colnames then
      colnames = vim.list_extend({ "" }, colnames)
    end
  end
  if colnames and type(out[1]) == "table" and #out[1] == #colnames then
    table.insert(out, 1, "hline")
    table.insert(out, 1, colnames)
  end
  return out
end

--- Convert a value of the Emacs Lisp evaluator to a Lua value.
local function from_elisp(v)
  local el = require("org.table.elisp")
  if v == nil then
    return ""
  elseif v == true then
    return "t"
  end
  local n = el.tonumber(v)
  if n then
    return n
  end
  if type(v) == "table" then
    if v.n ~= nil and getmetatable(v) == nil then
      local out = {}
      for i = 1, v.n do
        out[i] = from_elisp(v[i])
      end
      return out
    elseif v.name then
      return v.name -- a symbol, e.g. hline
    end
  end
  return type(v) == "string" and v or el.to_string(v)
end

--- Split a reference `name[header](args)[index]` like org-babel-ref-resolve.
---@return { name: string, header?: string, call?: string, index?: string, contents?: boolean }
function M.parse_ref(ref)
  local r = {}
  local head, idx = ref:match("^(.-)(%b[])$")
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

--- Value of a named element that is not code (org-babel-read-element):
--- tables become rows, lists their top-level items, the rest text.
local function read_element(lines, args, meta)
  local first = lines[1] or ""
  if first:match("^%s*|") then
    local rows = results.read(lines, true)
    return langs.normalize(disassemble(rows, args, meta))
  end
  if first:match("^%s*[-+*] ") or first:match("^%s*%d+[.)] ") then
    local indent = #first:match("^(%s*)")
    local items = {}
    for _, l in ipairs(lines) do
      local ind, text = l:match("^(%s*)[-+*] (.*)$")
      if not ind then
        ind, text = l:match("^(%s*)%d+[.)] (.*)$")
      end
      if ind and #ind == indent then
        items[#items + 1] = langs.normalize(text:gsub("^%[.%] ", ""))
      end
    end
    return items
  end
  local text = results.read(lines)
  if type(text) == "string" and tonumber(vim.trim(text)) and not text:find("\n") then
    return tonumber(vim.trim(text))
  end
  return text
end

--- Body text of the headline with ID or CUSTOM_ID `id` (after its
--- planning line and property drawer), or nil.
local function headline_body(bufnr, id)
  local file, lines, hl = get_file(bufnr), nil, nil
  for _, h in ipairs(file and file.headlines or {}) do
    if h.properties and (h.properties.ID == id or h.properties.CUSTOM_ID == id) then
      hl, lines = h, buf_lines(bufnr)
      break
    end
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

local evaluate_ref

--- Resolve a :var value to a Lua value (org-babel-read, then
--- org-babel-ref-resolve). `args` (the block's header args) controls
--- :colnames / :rownames / :hlines; names found are recorded in `meta`.
--- References to src blocks and #+CALL lines evaluate them.
---@param opts? { depth?: integer, skip_confirm?: boolean }
function M.resolve_var(bufnr, raw, args, meta, opts)
  opts = opts or {}
  raw = vim.trim(raw or "")
  local q = raw:match('^"(.*)"$')
  if q then
    return (q:gsub('\\"', '"'))
  end
  if tonumber(raw) then
    return tonumber(raw)
  end
  if raw == "" then
    return ""
  end
  local c = raw:sub(1, 1)
  if c == "(" or c == "'" or c == "`" then
    local ok, v = pcall(require("org.table.elisp").eval, raw)
    if not ok then
      error("cannot evaluate " .. raw .. ": " .. tostring(v), 0)
    end
    return from_elisp(v)
  end
  local ref = M.parse_ref(raw)
  local value = M.resolve_ref(bufnr, ref, args, meta, opts)
  if ref.index then
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
            return table.concat(b.body, "\n")
          end
          return evaluate_ref(bufnr, b, ref, file, opts)
        end
      end
      return read_element(vim.list_slice(lines, k, blocks_mod.results_end(lines, k - 1)), args, meta)
    end
  end
  local body = headline_body(bufnr, name)
  if body then
    return body
  end
  if M.library[name] then
    local b = vim.deepcopy(M.library[name])
    if ref.contents then
      return table.concat(b.body, "\n")
    end
    return evaluate_ref(bufnr, b, ref, nil, opts)
  end
  error("reference '" .. name .. "' not found in this buffer", 0)
end

local function resolve_vars(bufnr, args, meta, opts)
  local out = {}
  for _, v in ipairs(args.vars or {}) do
    out[#out + 1] = { name = v.name, value = M.resolve_var(bufnr, v.value, args, meta, opts) }
  end
  return out
end

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

--- The session of a block, started when needed.
local function get_session(bufnr, lang, args, name)
  local fam = langs.family(lang)
  local cmd = {}
  if fam ~= "lua" then
    local lang_cfg = (require("org.config").opts.babel.languages or {})[lang]
    if not lang_cfg or not lang_cfg.cmd then
      error("No babel command configured for language: " .. tostring(lang), 0)
    end
    cmd = split_cmd(lang_cfg.cmd)
    if vim.fn.executable(cmd[1]) == 0 then
      error("Executable not found: " .. cmd[1], 0)
    end
  end
  return session_mod.get({ lang = lang, family = fam, name = name, cmd = cmd, cwd = block_cwd(bufnr, args) })
end

--- Code sent to a session: variables, :prologue, body and :epilogue.
local function session_code(lang, body, args, vars)
  local lines = langs.var_lines(lang, vars, args)
  if args.prologue then
    vim.list_extend(lines, vim.split(blocks_mod.unquote(args.prologue), "\\n", { plain = true }))
  end
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

local function run_in_session(bufnr, lang, body, args, vars, name, done, sync)
  local ok, sess = pcall(get_session, bufnr, lang, args, name)
  if not ok then
    return done({ error = tostring(sess), text = "" })
  end
  local timeout = require("org.config").opts.babel.timeout
  if langs.family(lang) == "lua" then
    session_mod.echo(sess, table.concat(body, "\n"))
    local res = langs.run_lua(body, args, vars, sess.env)
    if vim.trim(res.output or "") ~= "" then
      session_mod.append(sess, res.output)
    end
    local r = { text = res.output }
    if res.error then
      r.error = res.error
      r.text = (res.output ~= "" and (res.output .. "\n") or "") .. res.error
    elseif args.results_spec.collection == "value" then
      r.value = res.value
    end
    return done(r)
  end
  local exit_status = langs.shell_exit_status(lang, args)
  local mode = (args.results_spec.collection == "value" and not langs.family(lang):match("shell")) and "value"
    or "output"
  local function convert(sres)
    local r = { text = sres.output or "", error = sres.error }
    if not sres.error then
      if exit_status then
        r.value = sres.status
      elseif mode == "value" then
        r.value = sres.value
      end
    end
    return r
  end
  local code = session_code(lang, body, args, vars)
  if sync then
    return done(convert(session_mod.eval_sync(sess, code, mode, { timeout = timeout })))
  end
  session_mod.eval(sess, code, mode, function(sres)
    done(convert(sres))
  end, { timeout = timeout })
end

--- Run code and call `cb(result)` with { value?, text, error? }. With
--- `opts.sync` the result is returned instead (the call blocks).
---@param opts? { sync?: boolean }
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
    run_in_session(bufnr, lang, body, args, vars, sname, done, sync)
    return result
  end
  local cwd = block_cwd(bufnr, args)
  if fam == "lua" then
    local res = langs.run_lua(body, args, vars)
    local r = { text = res.output }
    if res.error then
      r.error = res.error
      r.text = (res.output ~= "" and (res.output .. "\n") or "") .. res.error
    elseif args.results_spec.collection == "value" then
      if res.value ~= nil then
        r.value = res.value
      end
    end
    done(r)
    return result
  end
  local lang_cfg = (require("org.config").opts.babel.languages or {})[lang]
  if not lang_cfg or not lang_cfg.cmd then
    done({ error = "No babel command configured for language: " .. tostring(lang), text = "" })
    return result
  end
  local cmd = split_cmd(lang_cfg.cmd)
  if vim.fn.executable(cmd[1]) == 0 then
    done({ error = "Executable not found: " .. cmd[1], text = "" })
    return result
  end
  local stdin
  if args.stdin and (fam == "shell" or fam == "fish") then
    -- :stdin ref feeds a value to the script (ob-shell)
    local ok, v = pcall(M.resolve_var, bufnr, args.stdin, args, {})
    if not ok then
      done({ error = ":stdin: " .. tostring(v), text = "" })
      return result
    end
    stdin = langs.table_to_text(v) .. "\n"
  end
  if fam == "sqlite" then
    body = langs.sqlite_substitute(body, vars)
    vars = {}
  end
  local code, has_marker = langs.program(lang, body, args, vars)
  if fam == "sqlite" then
    cmd[#cmd + 1] = blocks_mod.unquote(args.db) or ":memory:"
    stdin = code
  else
    local tmp = vim.fn.tempname() .. "." .. (lang_cfg.ext or langs.ext(lang))
    utils.writefile(tmp, vim.split(code, "\n", { plain = true }))
    cmd[#cmd + 1] = tmp
    if args.cmdline then
      vim.list_extend(cmd, vim.split(blocks_mod.unquote(args.cmdline), "%s+", { trimempty = true }))
    end
  end
  local function handle(obj)
    local stdout = obj.stdout or ""
    local stderr = obj.stderr or ""
    local r = {}
    if has_marker then
      local value, printed = langs.split_marker(stdout)
      r.value = value
      r.text = printed
      if value == nil then
        r.text = stdout
      end
    else
      r.text = stdout
    end
    if obj.code ~= 0 or (obj.signal and obj.signal ~= 0) then
      r.error = stderr ~= "" and stderr or ("exited with code " .. tostring(obj.code))
      r.value = nil
      r.text = vim.trim((r.text or "") .. "\n" .. stderr)
    elseif stderr ~= "" and vim.trim(r.text or "") == "" and r.value == nil then
      r.text = stderr
    end
    return r
  end
  local timeout = require("org.config").opts.babel.timeout
  local sys_opts = { cwd = cwd, text = true, stdin = stdin, timeout = timeout }
  if sync then
    local ok, obj = pcall(function()
      return vim.system(cmd, sys_opts):wait()
    end)
    done(ok and handle(obj) or { error = tostring(obj), text = "" })
    return result
  end
  local ok, err = pcall(vim.system, cmd, sys_opts, function(obj)
    vim.schedule(function()
      cb(handle(obj))
    end)
  end)
  if not ok then
    done({ error = tostring(err), text = "" })
  end
  return result
end

--- The value a result gives a :var reference: the value, else the output
--- (as a table for `:results table`, a list for `:results list`).
function M.result_value(res, args)
  local v = res.value
  if v ~= nil and v ~= vim.NIL then
    return v
  end
  local text = (res.text or ""):gsub("\n+$", "")
  local t = args.results_spec.type
  if t == "table" or t == "vector" then
    return langs.normalize(results.text_to_rows(text))
  elseif t == "list" then
    local items = {}
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      if l:match("%S") then
        items[#items + 1] = langs.normalize(l)
      end
    end
    return items
  end
  if tonumber(vim.trim(text)) and not text:find("\n") then
    return tonumber(vim.trim(text))
  end
  return text
end

--- Insert formatted results for `block` (re-parsed at `start`).
local function insert_results(bufnr, start, lines_out, args, hash)
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
  local indent = b.indent or ""
  local body = {}
  for i, l in ipairs(lines_out) do
    body[i] = l == "" and "" or indent .. l
  end
  local header = indent
    .. "#+RESULTS"
    .. (hash and ("[" .. hash .. "]") or "")
    .. ":"
    .. (b.name and (" " .. b.name) or "")
  local handling = args.results_spec.handling
  if b.results then
    local s, e = b.results.start, b.results.finish
    if handling == "append" then
      vim.api.nvim_buf_set_lines(bufnr, e, e, false, body)
    elseif handling == "prepend" then
      vim.api.nvim_buf_set_lines(bufnr, s, s, false, body)
    else
      local new = { header }
      vim.list_extend(new, body)
      vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, new)
    end
  else
    local new = { "", header }
    vim.list_extend(new, body)
    vim.api.nvim_buf_set_lines(bufnr, b.finish, b.finish, false, new)
  end
end

--- Hash identifying a block's body and parameters (for `:cache yes`).
function M.cache_hash(lang, body, args, vars)
  local keys = {}
  for k, v in pairs(args) do
    if type(v) == "string" and k ~= "cache" then
      keys[#keys + 1] = k .. "=" .. v
    end
  end
  table.sort(keys)
  local spec = {}
  for k, v in pairs(args.results_spec or {}) do
    -- like org-babel-sha1-hash, how results are inserted doesn't count
    if k ~= "handling" then
      spec[#spec + 1] = k .. "=" .. v
    end
  end
  table.sort(spec)
  local payload = table.concat({
    lang or "",
    table.concat(keys, ";"),
    table.concat(spec, ";"),
    vim.inspect(vars or {}),
    table.concat(body or {}, "\n"),
  }, "|")
  return vim.fn.sha256(payload):sub(1, 40)
end

--- Output file of a block (:file, :output-dir, :file-ext), or nil.
function M.file_param(args, name)
  local file = blocks_mod.unquote(args.file)
  local dir = blocks_mod.unquote(args["output-dir"])
  local ext = blocks_mod.unquote(args["file-ext"])
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

--- Write a result to its :file (like Emacs, unless :results link/graphics).
local function write_file_result(bufnr, res, args, path)
  local spec = args.results_spec
  if spec.format == "link" or spec.format == "graphics" or res.error then
    return
  end
  local v = res.value
  if v == nil or v == vim.NIL then
    v = res.text or ""
  end
  local out
  if type(v) == "table" then
    local sep = blocks_mod.unquote(args.sep) or "\t"
    out = {}
    for _, row in ipairs(is_rows(v) and v or { v }) do
      if row ~= "hline" then
        local cells = {}
        for j, c in ipairs(type(row) == "table" and row or { row }) do
          cells[j] = results.stringify(c)
        end
        out[#out + 1] = table.concat(cells, sep)
      end
    end
  else
    local text = results.stringify(v):gsub("\n+$", "")
    if text == "" or text == "None" or text == "nil" then
      return
    end
    out = vim.split(text, "\n", { plain = true })
  end
  local file_dir = buf_dir(bufnr)
  local cwd = args.dir and utils.expand(blocks_mod.unquote(args.dir), file_dir) or file_dir
  local full = utils.expand(path, cwd)
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  utils.writefile(full, out)
  if args["file-mode"] then
    local oct = args["file-mode"]:match("#o(%d+)") or args["file-mode"]:match("^o?(%d%d%d)$")
    if oct then
      vim.uv.fs_chmod(full, tonumber(oct, 8))
    end
  end
end

local function should_eval(args, lang, name, skip_confirm)
  local ev = args.eval
  if ev == "no" or ev == "never" then
    utils.warn("Evaluation of this code block is disabled (:eval " .. ev .. ")")
    return false
  end
  if ev == "yes" or skip_confirm then
    return true
  end
  local cfg = require("org.config").opts.babel
  if ev == "query" or cfg.confirm_evaluate ~= false then
    return utils.confirm(string.format("Evaluate this %s code block%s on your system?", lang, name and (" (" .. name .. ")") or ""))
  end
  return true
end

--- Execute the block at (bufnr, lnum). `on_done(ok)` is called when done.
--- With `sync` the evaluation blocks and results are inserted before return.
---@param opts? { bufnr?: integer, lnum?: integer, skip_confirm?: boolean, sync?: boolean, handling?: string, on_done?: fun(ok: boolean) }
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
      done(false)
      return
    end
  end
  local src = target or b
  if opts.handling then
    args.results_spec.handling = opts.handling
  end
  if not should_eval(args, src.lang, src.name, opts.skip_confirm) then
    done(false)
    return
  end
  local meta = {}
  local ok, vars = pcall(resolve_vars, bufnr, args, meta, { skip_confirm = opts.skip_confirm })
  if not ok then
    utils.error("babel: " .. tostring(vars))
    done(false)
    return
  end
  local body = src.body
  local nw = noweb_for(args, "eval")
  if nw then
    body = M.expand_noweb(bufnr, body, 0, nil, args, "eval")
  end
  local hash
  if args.cache == "yes" and not b.call then
    hash = M.cache_hash(src.lang, body, args, vars)
    if b.results and b.results.hash == hash then
      utils.notify("babel: results are up to date (:cache yes)")
      done(true)
      return
    end
  end
  local out_file = M.file_param(args, src.name)
  if out_file then
    args.file = out_file
  end
  -- track the block position across edits
  local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, b.start - 1, 0, {
    virt_text = { { "  ⏳ executing…", "Comment" } },
    virt_text_pos = "eol",
  })
  local function finish(res)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
    if res.error then
      utils.error(string.format("babel (%s): %s", src.lang, vim.trim(res.error)))
    end
    local handling = args.results_spec.handling
    if out_file then
      write_file_result(bufnr, res, args, out_file)
    end
    local out = results.format(res, args, src.lang)
    if handling == "silent" or handling == "none" or handling == "discard" then
      if handling == "silent" then
        utils.notify(table.concat(out or {}, "\n"))
      end
      done(true)
      return
    end
    if pos and pos[1] then
      insert_results(bufnr, pos[1] + 1, out or {}, args, hash)
    end
    done(res.error == nil)
  end
  local function after_run(res)
    if res.value ~= nil and not res.error then
      res.value = M.reassemble(res.value, args, meta)
    end
    if args.post and not res.error and vim.api.nvim_buf_is_valid(bufnr) then
      if opts.sync then
        return finish(M.run_post(bufnr, args.post, res, nil, { sync = true }))
      end
      return M.run_post(bufnr, args.post, res, finish)
    end
    finish(res)
  end
  if opts.sync then
    after_run(M.run(bufnr, src.lang, body, args, vars, nil, { sync = true }))
  else
    M.run(bufnr, src.lang, body, args, vars, after_run)
  end
end

--- :post name(arg=*this*): run the named block on the result; its result
--- replaces the original one. With `opts.sync` the result is returned.
function M.run_post(bufnr, post, res, cb, opts)
  opts = opts or {}
  cb = cb or function() end
  local function give(r)
    if opts.sync then
      return r
    end
    cb(r)
  end
  post = vim.trim(blocks_mod.unquote(post) or "")
  local pname, pargs = post:match("^([^%(]+)%((.*)%)$")
  pname = vim.trim(pname or post)
  local target = M.find_named_block(buf_lines(bufnr), pname)
  if not target then
    utils.error(":post: no block named " .. pname)
    return give(res)
  end
  local file = get_file(bufnr)
  local targs = blocks_mod.header_args(target, not target.lob and file or nil)
  if pargs and vim.trim(pargs) ~= "" then
    blocks_mod.merge(targs, { { key = "var", value = pargs } })
  end
  local this = res.value
  if this == nil or this == vim.NIL then
    this = vim.trim(res.text or "")
  end
  local vars = {}
  for _, v in ipairs(targs.vars) do
    local value
    if vim.trim(v.value) == "*this*" then
      value = this
    else
      local ok, resolved = pcall(M.resolve_var, bufnr, v.value, targs, {}, { skip_confirm = true })
      value = ok and resolved or v.value
    end
    vars[#vars + 1] = { name = v.name, value = value }
  end
  local function after(pres)
    if pres.error then
      utils.error(string.format("babel :post (%s): %s", pname, vim.trim(pres.error)))
      return res
    end
    return pres
  end
  if opts.sync then
    return after(M.run(bufnr, target.lang, target.body, targs, vars, nil, { sync = true }))
  end
  M.run(bufnr, target.lang, target.body, targs, vars, function(pres)
    cb(after(pres))
  end)
end

--- Evaluate a block synchronously and return its result without inserting
--- it (what a :var reference or a noweb call sees). Honours :eval, :cache,
--- :noweb, :var and :post. Raises an error when evaluation fails.
---@param src table the block (the target of a #+CALL)
---@param opts? { depth?: integer, skip_confirm?: boolean }
function M.evaluate_sync(bufnr, src, args, opts)
  opts = opts or {}
  local depth = (opts.depth or 0) + 1
  if depth > 20 then
    error("reference depth exceeded (circular :var references?)", 0)
  end
  local name = src.name or "block"
  local ev = args.eval
  if ev == "no" or ev == "never" then
    error("evaluation of '" .. name .. "' is disabled (:eval " .. ev .. ")", 0)
  end
  if not should_eval(args, src.lang, src.name, opts.skip_confirm) then
    error("evaluation of '" .. name .. "' was cancelled", 0)
  end
  local meta = {}
  local vars = resolve_vars(bufnr, args, meta, { depth = depth, skip_confirm = opts.skip_confirm })
  local body = src.body
  if noweb_for(args, "eval") then
    body = M.expand_noweb(bufnr, body, 0, nil, args, "eval")
  end
  if args.cache == "yes" and src.results and not src.lob then
    if src.results.hash == M.cache_hash(src.lang, body, args, vars) then
      local lines = buf_lines(bufnr)
      return { value = results.read(vim.list_slice(lines, src.results.start + 1, src.results.finish)) }
    end
  end
  local res = M.run(bufnr, src.lang, body, args, vars, nil, { sync = true })
  if res.error then
    error(string.format("%s (%s): %s", name, src.lang, vim.trim(res.error)), 0)
  end
  if res.value ~= nil then
    res.value = M.reassemble(res.value, args, meta)
  end
  if args.post then
    res = M.run_post(bufnr, args.post, res, nil, { sync = true })
  end
  return res
end

--- Evaluate the block (or #+CALL) `b` for the reference `ref`.
evaluate_ref = function(bufnr, b, ref, file, opts)
  local args, src
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
    blocks_mod.merge(args, blocks_mod.parse_header_string(ref.header))
  end
  if ref.call and vim.trim(ref.call) ~= "" then
    blocks_mod.merge(args, { { key = "var", value = ref.call } })
  end
  args.results_spec.handling = "none"
  if type(bufnr) ~= "number" then
    -- a list of lines (export) can't run code: use the existing results
    local lines = buf_lines(bufnr)
    if src.results then
      return results.read(vim.list_slice(lines, src.results.start + 1, src.results.finish), true)
    end
    error("block '" .. tostring(src.name) .. "' has no results", 0)
  end
  opts = opts or {}
  local res = M.evaluate_sync(bufnr, src, args, { depth = opts.depth, skip_confirm = opts.skip_confirm })
  return M.result_value(res, args)
end

--- Execute the src block at cursor (or the inline src block under it).
function M.execute_block()
  if M.inline_at_cursor() then
    return M.execute_inline()
  end
  M.execute({})
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
        local lang, hdr, body = rest:match("^src_([%w%-%+]+)(%b[])(%b{})")
        if not lang then
          hdr = ""
          lang, body = rest:match("^src_([%w%-%+]+)(%b{})")
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

--- Format a value for an inline `{{{results(...)}}}` macro.
local function inline_result(res, args, lang)
  local v = res.value
  if v == nil or v == vim.NIL then
    v = res.text or ""
  end
  local text = vim.trim(results.stringify(v))
  if text:find("\n") then
    return nil, "multi-line results cannot be inserted inline"
  end
  local fmt = args.results_spec.format
  if fmt == "raw" then
    return "{{{results(" .. text .. ")}}}"
  elseif fmt == "code" then
    return "{{{results(src_" .. lang .. "{" .. text .. "})}}}"
  elseif fmt == "html" or fmt == "latex" then
    return "{{{results(@@" .. fmt .. ":" .. text .. "@@)}}}"
  end
  return "{{{results(=" .. text .. "=)}}}"
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

--- Evaluate the inline element `ib` (from `M.inline_at`) of line `lnum`.
---@param opts? { skip_confirm?: boolean, sync?: boolean }
function M.execute_inline_at(bufnr, lnum, ib, opts)
  opts = opts or {}
  local file = get_file(bufnr)
  local lang, body, args, name
  if ib.call then
    local target = M.find_named_block(buf_lines(bufnr), ib.target)
    if not target then
      utils.error("call_" .. ib.target .. ": no block named " .. ib.target)
      return
    end
    lang, body, name = target.lang, target.body, target.name
    args = blocks_mod.header_args(target, not target.lob and file or nil)
    blocks_mod.merge(args, blocks_mod.parse_header_string(ib.inside))
    if vim.trim(ib.call_args) ~= "" then
      blocks_mod.merge(args, { { key = "var", value = ib.call_args } })
    end
    blocks_mod.merge(args, blocks_mod.parse_header_string(ib.params))
  else
    lang, body = ib.lang, { ib.body }
    args = blocks_mod.header_args({ start = lnum, lang = ib.lang, params = ib.params, header_lines = {} }, file)
  end
  if not ib.params:match(":results") and not (ib.inside or ""):match(":results") then
    args.results_spec.handling = "replace"
  end
  if not should_eval(args, lang, name, opts.skip_confirm) then
    return
  end
  local ok, vars = pcall(resolve_vars, bufnr, args, {}, { skip_confirm = opts.skip_confirm })
  if not ok then
    utils.error("babel: " .. tostring(vars))
    return
  end
  if noweb_for(args, "eval") then
    body = M.expand_noweb(bufnr, body, 0, nil, args, "eval")
  end
  local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, ib.e, { right_gravity = false })
  local function finish(res)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
    if res.error then
      utils.error(string.format("babel (%s): %s", lang, vim.trim(res.error)))
      return
    end
    local handling = args.results_spec.handling
    local text, err = inline_result(res, args, lang)
    if not text then
      utils.warn("Inline error: " .. err)
      return
    end
    if handling == "silent" or handling == "none" or handling == "discard" then
      utils.notify(text)
      return
    end
    if not pos or not pos[1] then
      return
    end
    local row, col = pos[1], pos[2]
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local before, after = line:sub(1, col), line:sub(col + 1)
    after = after:gsub("^%s*{{{results%(.-%)}}}", "", 1)
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { before .. " " .. text .. after })
  end
  if opts.sync then
    return finish(M.run(bufnr, lang, body, args, vars, nil, { sync = true }))
  end
  M.run(bufnr, lang, body, args, vars, finish)
end

local function execute_many(bufnr, starts)
  if #starts == 0 then
    utils.notify("No source blocks to evaluate")
    return
  end
  local cfg = require("org.config").opts.babel
  if cfg.confirm_evaluate ~= false then
    if not utils.confirm(string.format("Evaluate %d code blocks?", #starts)) then
      return
    end
  end
  local marks = {}
  for _, s in ipairs(starts) do
    marks[#marks + 1] = vim.api.nvim_buf_set_extmark(bufnr, ns, s - 1, 0, {})
  end
  local i = 0
  local function step()
    i = i + 1
    if i > #marks then
      utils.notify(string.format("Evaluated %d code blocks", #marks))
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, marks[i], {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, marks[i])
    M.execute({ bufnr = bufnr, lnum = pos[1] + 1, skip_confirm = true, on_done = step })
  end
  step()
end

function M.execute_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local starts = {}
  for _, b in ipairs(blocks_mod.parse_blocks(buf_lines(bufnr))) do
    starts[#starts + 1] = b.start
  end
  execute_many(bufnr, starts)
end

function M.execute_subtree()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = get_file(bufnr)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local hl = file and file:headline_at(lnum)
  local s, e = 1, vim.api.nvim_buf_line_count(bufnr)
  if hl then
    s, e = hl.line, hl.end_line
  end
  local starts = {}
  for _, b in ipairs(blocks_mod.parse_blocks(buf_lines(bufnr))) do
    if b.start >= s and b.finish <= e then
      starts[#starts + 1] = b.start
    end
  end
  execute_many(bufnr, starts)
end

--- Remove every result in the buffer.
function M.remove_all_results(bufnr)
  bufnr = resolve_buf(bufnr)
  local list = blocks_mod.parse_blocks(buf_lines(bufnr))
  local n = 0
  for i = #list, 1, -1 do
    local b = list[i]
    if b.results and b.results.start > b.finish then
      local s, e = b.results.start, b.results.finish
      local prev = vim.api.nvim_buf_get_lines(bufnr, s - 2, s - 1, false)[1]
      if prev and prev:match("^%s*$") and s - 1 > b.finish then
        s = s - 1
      end
      vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
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
  local s, e = b.results.start, b.results.finish
  local prev = vim.api.nvim_buf_get_lines(bufnr, s - 2, s - 1, false)[1]
  if prev and prev:match("^%s*$") and s - 1 > b.finish then
    s = s - 1
  end
  vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, {})
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

local function common_indent(lines)
  local min
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = #l:match("^(%s*)")
      if not min or n < min then
        min = n
      end
    end
  end
  return min or 0
end

function M.edit_special()
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call then
    return false
  end
  local raw = vim.api.nvim_buf_get_lines(bufnr, b.start, b.finish - 1, false)
  local body = blocks_mod.unescape(raw)
  -- -i (org-src-preserve-indentation) keeps the lines exactly as they are
  local preserve = (" " .. (b.switches or "") .. " "):match("%s%-i%s") ~= nil
  local n = preserve and 0 or common_indent(body)
  local dedented = {}
  for i, l in ipairs(body) do
    dedented[i] = l:sub(n + 1)
  end
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
-- Tangling
---------------------------------------------------------------------------

--- Tangle `bufnr`. Returns list of written files.
---@param opts? { bufnr?: integer, target?: string only tangle this file, silent?: boolean }
function M.tangle(opts)
  opts = opts or {}
  local bufnr = resolve_buf(opts.bufnr)
  local lines = buf_lines(bufnr)
  local file = get_file(bufnr)
  local src_path = vim.api.nvim_buf_get_name(bufnr)
  local dir = src_path ~= "" and vim.fn.fnamemodify(src_path, ":p:h") or vim.fn.getcwd()
  local base = src_path ~= "" and vim.fn.fnamemodify(src_path, ":t:r") or "tangled"
  local outputs, order = {}, {}
  for _, b in ipairs(blocks_mod.parse_blocks(lines)) do
    if not b.call and not in_commented(file, b.start) and (not opts.only_line or opts.only_line == b.start) then
      local args = blocks_mod.header_args(b, file)
      local tangle = blocks_mod.unquote(args.tangle or "no")
      if tangle ~= "no" and tangle ~= "nil" and tangle ~= "" then
        local target
        if tangle == "yes" then
          target = dir .. "/" .. base .. "." .. langs.ext(b.lang)
        else
          target = utils.expand(tangle, dir)
        end
        if not opts.target or opts.target == target then
          if not outputs[target] then
            outputs[target] = { lines = {}, args = args, lang = b.lang }
            order[#order + 1] = target
          end
          local out = outputs[target]
          local body = M.expand_body(bufnr, b, args, "tangle")
          local n = (" " .. (b.switches or "") .. " "):match("%s%-i%s") and 0 or common_indent(body)
          local ded = {}
          for i, l in ipairs(body) do
            ded[i] = l:sub(n + 1)
          end
          local comments = args.comments or "no"
          local cp = langs.comment_prefix(b.lang)
          local hl = file and file:headline_at(b.start)
          local link = string.format("[[file:%s::%d][%s]]", src_path, b.start, hl and hl:plain_title() or b.name or "block")
          if #out.lines > 0 and args.padline ~= "no" then
            out.lines[#out.lines + 1] = ""
          end
          if comments == "link" or comments == "both" or comments == "yes" then
            out.lines[#out.lines + 1] = cp .. link
          end
          if comments == "org" or comments == "both" then
            if hl then
              out.lines[#out.lines + 1] = cp .. hl:plain_title()
            end
          end
          vim.list_extend(out.lines, ded)
          if comments == "link" or comments == "both" or comments == "yes" then
            out.lines[#out.lines + 1] = cp .. link .. " ends here"
          end
          if args.shebang and not out.shebang then
            out.shebang = blocks_mod.unquote(args.shebang)
          end
          if args["tangle-mode"] then
            out.mode = args["tangle-mode"]
          end
          if args.mkdirp == "yes" or args.mkdirp == "t" then
            out.mkdirp = true
          end
        end
      end
    end
  end
  local written = {}
  for _, target in ipairs(order) do
    local out = outputs[target]
    local content = vim.deepcopy(out.lines)
    if out.shebang then
      table.insert(content, 1, out.shebang)
    end
    local pdir = vim.fn.fnamemodify(target, ":h")
    if not utils.is_dir(pdir) then
      if out.mkdirp then
        vim.fn.mkdir(pdir, "p")
      else
        utils.error("Tangle: directory does not exist (use :mkdirp yes): " .. pdir)
        goto continue
      end
    end
    utils.writefile(target, content)
    do
      local mode
      if out.mode then
        local oct = out.mode:match("#o(%d+)") or out.mode:match("^o?(%d%d%d)$")
        mode = oct and tonumber(oct, 8)
      elseif out.shebang then
        mode = tonumber("755", 8)
      end
      if mode then
        vim.uv.fs_chmod(target, mode)
      end
    end
    written[#written + 1] = target
    ::continue::
  end
  if not opts.silent then
    if #written == 0 then
      utils.notify("Tangled 0 code blocks")
    else
      utils.notify(string.format("Tangled %d file(s):\n%s", #written, table.concat(written, "\n")))
    end
  end
  return written
end

function M.tangle_command(args)
  args = vim.trim(args or "")
  return M.tangle({ target = args ~= "" and utils.expand(args, vim.fn.expand("%:p:h")) or nil })
end

--- Tangle target of the block at the cursor (nil when it isn't tangled).
local function block_tangle_target(bufnr, b)
  local src_path = vim.api.nvim_buf_get_name(bufnr)
  local dir = src_path ~= "" and vim.fn.fnamemodify(src_path, ":p:h") or vim.fn.getcwd()
  local tangle = blocks_mod.unquote(b.args.tangle or "no")
  if tangle == "no" or tangle == "nil" or tangle == "" then
    return nil
  end
  if tangle == "yes" then
    local base = src_path ~= "" and vim.fn.fnamemodify(src_path, ":t:r") or "tangled"
    return dir .. "/" .. base .. "." .. langs.ext(b.lang)
  end
  return utils.expand(tangle, dir)
end

--- C-c C-v t: tangle the file. With a count of 1 (Emacs C-u) only the block
--- at the cursor, with a count of 2 or more (C-u C-u) the target file of the
--- block at the cursor.
function M.tangle_action()
  local count = vim.v.count
  if count == 0 then
    return M.tangle()
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local b = M.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call then
    utils.warn("No source block at point")
    return
  end
  local target = block_tangle_target(bufnr, b)
  if not target then
    utils.warn("This block is not tangled (:tangle no)")
    return
  end
  if count == 1 then
    return M.tangle({ only_line = b.start })
  end
  return M.tangle({ target = target })
end

--- C-c C-v f: tangle another org file.
function M.tangle_file(path)
  if not path then
    local ok, v = pcall(vim.fn.input, { prompt = "Tangle file: ", completion = "file", cancelreturn = vim.NIL })
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

--- Body of a block with noweb references expanded and :var assignments,
--- :prologue and :epilogue added (what tangling writes).
function M.expand_body(bufnr, b, args, purpose)
  local body = b.body
  local nw = noweb_for(args, purpose or "eval")
  if nw then
    body = M.expand_noweb(bufnr, body, 0, nw == "strip" and "strip" or nil, args, purpose or "eval")
  end
  local pat = blocks_mod.coderef_pattern(b.switches)
  if (b.switches or ""):match("%-r") then
    local stripped = {}
    for i, l in ipairs(body) do
      stripped[i] = l:gsub(pat, "")
    end
    body = stripped
  end
  if args["no-expand"] then
    return body
  end
  local out = {}
  local ok, vars = pcall(resolve_vars, bufnr, args, {})
  if ok and #vars > 0 then
    vim.list_extend(out, langs.var_lines(b.lang, vars, args))
  end
  if args.prologue then
    vim.list_extend(out, vim.split(blocks_mod.unquote(args.prologue), "\\n", { plain = true }))
  end
  vim.list_extend(out, body)
  if args.epilogue then
    vim.list_extend(out, vim.split(blocks_mod.unquote(args.epilogue), "\\n", { plain = true }))
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
function M.switch_to_session()
  local sess, bufnr, src, args = cursor_session()
  if not sess then
    return
  end
  vim.fn.setreg('"', table.concat(src.body, "\n"))
  if vim.v.count > 0 then
    local ok, vars = pcall(resolve_vars, bufnr, args, {})
    if not ok then
      utils.error("babel: " .. tostring(vars))
    elseif #vars > 0 then
      if sess.kind == "lua" then
        for _, v in ipairs(vars) do
          sess.env[v.name] = v.value
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
  local ok, vars = pcall(resolve_vars, bufnr, args, {})
  if not ok then
    utils.error("babel: " .. tostring(vars))
    return
  end
  local body = src.body
  if noweb_for(args, "eval") then
    body = M.expand_noweb(bufnr, body, 0, nil, args, "eval")
  end
  local hash = M.cache_hash(src.lang, body, args, vars)
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
        local exports = args.exports or "code"
        if b.call then
          -- calls export their results unless they say otherwise
          local own = blocks_mod.parse_header_string(table.concat(b.header_lines, " ") .. " " .. b.params)
          exports = blocks_mod.merge({}, own).exports or "results"
        end
        local silent = (exports == "code" or exports == "none") and session_mod.name(args.session) ~= nil
        if exports == "results" or exports == "both" or silent then
          jobs[#jobs + 1] = { line = b.start, silent = silent, query = args.eval }
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
  local cfg = require("org.config").opts.babel
  local proceed = #jobs > 0
  if proceed and cfg.confirm_evaluate ~= false then
    proceed = utils.confirm(string.format("Evaluate %d code block%s for export?", #jobs, #jobs == 1 and "" or "s"))
  end
  if proceed then
    table.sort(jobs, function(x, y)
      if x.line ~= y.line then
        return x.line < y.line
      end
      return (x.col or 0) < (y.col or 0)
    end)
    for _, job in ipairs(jobs) do
      job.mark = vim.api.nvim_buf_set_extmark(scratch, ns, job.line - 1, (job.col or 1) - 1, {})
    end
    for _, job in ipairs(jobs) do
      local pos = vim.api.nvim_buf_get_extmark_by_id(scratch, ns, job.mark, {})
      local lnum = pos[1] + 1
      local ask = job.query == "query" or job.query == "query-export"
      local ok, err = pcall(function()
        if job.inline then
          local line = vim.api.nvim_buf_get_lines(scratch, lnum - 1, lnum, false)[1] or ""
          local ib = M.inline_at(line, pos[2] + 1)
          if ib then
            M.execute_inline_at(scratch, lnum, ib, { skip_confirm = not ask, sync = true })
          end
        else
          M.execute({
            bufnr = scratch,
            lnum = lnum,
            skip_confirm = not ask,
            sync = true,
            handling = job.silent and "none" or nil,
          })
        end
      end)
      if not ok then
        utils.error("babel (export): " .. tostring(err))
      end
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
