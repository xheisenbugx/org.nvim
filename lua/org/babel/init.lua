---@mod org.babel Source block evaluation, tangling and editing
---
--- Evaluation runs asynchronously via `vim.system` (Lua blocks run inside
--- Neovim). Results are written below the block as `#+RESULTS:`.

local blocks_mod = require("org.babel.blocks")
local langs = require("org.babel.langs")
local results = require("org.babel.results")
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
    -- <<name(args)>>: the results of the named block
    local target = M.find_named_block(ctx.lines, call_name)
    if target and target.results then
      local text = results.read(vim.list_slice(ctx.lines, target.results.start + 1, target.results.finish))
      return vim.split(type(text) == "table" and vim.inspect(text) or text, "\n", { plain = true })
    end
    return { "" }
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
  local out = {}
  for _, r in ipairs(rows) do
    if r ~= "hline" then
      out[#out + 1] = r
    end
  end
  local rnames
  if rownames == "yes" or rownames == "t" then
    rnames = {}
    for i, r in ipairs(out) do
      rnames[i] = r[1]
      out[i] = vim.list_slice(r, 2)
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

--- Resolve a :var value to a Lua value. `args` (the block's header args)
--- controls :colnames / :rownames; names found are recorded in `meta`.
function M.resolve_var(bufnr, raw, args, meta)
  raw = vim.trim(raw or "")
  local q = raw:match('^"(.*)"$')
  if q then
    return (q:gsub('\\"', '"'))
  end
  if tonumber(raw) then
    return tonumber(raw)
  end
  local name, index = raw:match("^([^%[]+)(%b[])$")
  name = name or raw
  local lines = buf_lines(bufnr)
  local value
  local tbl = require("org.table").find_named_table(bufnr, name)
  if tbl then
    local rows = {}
    for _, r in ipairs(tbl.rows) do
      rows[#rows + 1] = r.hline and "hline" or vim.deepcopy(r.cells)
    end
    value = langs.normalize(disassemble(rows, args, meta))
  else
    local b = M.find_named_block(lines, name)
    if b then
      if b.results then
        value = results.read(vim.list_slice(lines, b.results.start + 1, b.results.finish), true)
        if is_rows(value) then
          value = disassemble(value, args, meta)
        end
        value = langs.normalize(value)
      elseif langs.family(b.lang) == "lua" then
        local res = langs.run_lua(b.body, { results_spec = { collection = "value" } }, {})
        value = res.value ~= nil and res.value or res.output
      else
        error("block '" .. name .. "' has no results (evaluate it first)")
      end
    else
      -- named list / example / paragraph
      for i, l in ipairs(lines) do
        local nm = l:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$")
        if nm == name then
          local e = blocks_mod.results_end(lines, i)
          value = results.read(vim.list_slice(lines, i + 1, e))
          break
        end
      end
    end
  end
  if value == nil then
    return raw
  end
  if index then
    value = M.index_value(value, index:sub(2, -2))
  end
  return value
end

local function resolve_vars(bufnr, args, meta)
  local out = {}
  for _, v in ipairs(args.vars or {}) do
    out[#out + 1] = { name = v.name, value = M.resolve_var(bufnr, v.value, args, meta) }
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

--- Run code and call `cb(result)` with { value?, text, error? }.
function M.run(bufnr, lang, body, args, vars, cb)
  local fam = langs.family(lang)
  local file_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
  local cwd = args.dir and utils.expand(blocks_mod.unquote(args.dir), file_dir) or file_dir
  if not utils.is_dir(cwd) then
    cwd = vim.fn.getcwd()
  end
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
    vim.schedule(function()
      cb(r)
    end)
    return
  end
  local lang_cfg = (require("org.config").opts.babel.languages or {})[lang]
  if not lang_cfg or not lang_cfg.cmd then
    cb({ error = "No babel command configured for language: " .. tostring(lang), text = "" })
    return
  end
  local cmd = split_cmd(lang_cfg.cmd)
  if vim.fn.executable(cmd[1]) == 0 then
    cb({ error = "Executable not found: " .. cmd[1], text = "" })
    return
  end
  local code, has_marker = langs.program(lang, body, args, vars)
  local stdin
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
  local timeout = require("org.config").opts.babel.timeout
  local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = true, stdin = stdin, timeout = timeout }, function(obj)
    vim.schedule(function()
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
      cb(r)
    end)
  end)
  if not ok then
    cb({ error = tostring(err), text = "" })
  end
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
    spec[#spec + 1] = k .. "=" .. v
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
  local file_dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":p:h")
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

--- Execute the block at (bufnr, lnum). `cb(ok)` is called when done.
---@param opts? { bufnr?: integer, lnum?: integer, skip_confirm?: boolean, on_done?: fun(ok: boolean) }
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
  if not should_eval(args, src.lang, src.name, opts.skip_confirm) then
    done(false)
    return
  end
  local meta = {}
  local ok, vars = pcall(resolve_vars, bufnr, args, meta)
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
  M.run(bufnr, src.lang, body, args, vars, function(res)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
    if res.error then
      utils.error(string.format("babel (%s): %s", src.lang, vim.trim(res.error)))
    end
    local handling = args.results_spec.handling
    if res.value ~= nil and not res.error then
      res.value = M.reassemble(res.value, args, meta)
    end
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
  end)
end

--- Execute the src block at cursor.
function M.execute_block()
  M.execute({})
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
  local n = common_indent(body)
  local dedented = {}
  for i, l in ipairs(body) do
    dedented[i] = l:sub(n + 1)
  end
  if #dedented == 0 then
    dedented = { "" }
  end
  local content_indent = require("org.config").opts.edit_src_content_indentation or 0
  local prefix = (b.indent or "") .. string.rep(" ", content_indent)
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
          local n = common_indent(body)
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
    vim.list_extend(out, langs.var_lines(b.lang, vars))
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

--- Header arguments known to Org Babel (for completion and checking).
M.HEADER_ARGS = {
  cache = { "yes", "no" },
  cmdline = {},
  colnames = { "nil", "no", "yes" },
  comments = { "no", "link", "yes", "org", "both", "noweb" },
  dir = {},
  epilogue = {},
  eval = { "yes", "no", "query", "never", "never-export", "no-export", "query-export" },
  exports = { "code", "results", "both", "none" },
  file = {},
  ["file-desc"] = {},
  ["file-ext"] = {},
  ["file-mode"] = {},
  hlines = { "no", "yes" },
  mkdirp = { "yes", "no" },
  ["no-expand"] = {},
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
  session = { "none" },
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
