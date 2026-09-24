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
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function resolve_buf(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function get_file(bufnr)
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
    local args = blocks_mod.header_args(target, file)
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
end

---------------------------------------------------------------------------
-- Noweb
---------------------------------------------------------------------------

--- Expand <<ref>> references in body lines.
function M.expand_noweb(bufnr, body, depth, mode)
  depth = depth or 0
  if depth > 20 then
    error("noweb: reference depth exceeded")
  end
  local lines = buf_lines(bufnr)
  local all = blocks_mod.parse_blocks(lines)
  local file = get_file(bufnr)
  local out = {}
  for _, line in ipairs(body) do
    local prefix, ref, suffix = line:match("^(.-)<<([^%s<>]+)>>(.*)$")
    if not ref then
      out[#out + 1] = line
    elseif mode == "strip" then
      local stripped = line:gsub("<<[^%s<>]+>>", "")
      if not stripped:match("^%s*$") then
        out[#out + 1] = stripped
      end
    else
      local expansion = {}
      local call_name = ref:match("^(.-)%(.*%)$")
      if call_name then
        local target = M.find_named_block(lines, call_name)
        if target and target.results then
          local text = results.read(vim.list_slice(lines, target.results.start + 1, target.results.finish))
          expansion = vim.split(type(text) == "table" and vim.inspect(text) or text, "\n", { plain = true })
        end
      else
        local found = false
        for _, b in ipairs(all) do
          if not b.call then
            local args = blocks_mod.header_args(b, file)
            if b.name == ref or blocks_mod.unquote(args["noweb-ref"]) == ref then
              if found then
                expansion[#expansion + 1] = ""
              end
              vim.list_extend(expansion, M.expand_noweb(bufnr, b.body, depth + 1, mode))
              found = true
              if expansion[#expansion] == "" then
                table.remove(expansion)
              end
            end
          end
        end
        if not found then
          expansion = { "" }
        end
      end
      if #expansion == 0 then
        expansion = { "" }
      end
      for i, e in ipairs(expansion) do
        local l = prefix .. e
        if i == #expansion then
          l = l .. suffix
        end
        out[#out + 1] = l
      end
    end
  end
  return out
end

local function noweb_for(args, purpose)
  local v = args.noweb or "no"
  if purpose == "eval" then
    return (v == "yes" or v == "eval" or v == "no-export" or v == "strip-export" or v == "tangle-eval") and "expand"
      or nil
  elseif purpose == "tangle" then
    if v == "strip-tangle" then
      return "strip"
    end
    return (v == "yes" or v == "tangle" or v == "no-export" or v == "strip-export") and "expand" or nil
  end
end

---------------------------------------------------------------------------
-- Variables
---------------------------------------------------------------------------

--- Resolve a :var value to a Lua value.
function M.resolve_var(bufnr, raw)
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
  local rows = require("org.table").get_named_table(bufnr, name)
  if rows then
    value = langs.normalize(rows)
  else
    local b = M.find_named_block(lines, name)
    if b then
      if b.results then
        value = results.read(vim.list_slice(lines, b.results.start + 1, b.results.finish))
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
  if index and type(value) == "table" then
    local idx = vim.split(index:sub(2, -2), ",", { plain = true })
    local r = tonumber(vim.trim(idx[1] or ""))
    local c = tonumber(vim.trim(idx[2] or ""))
    if r then
      value = value[r + 1]
      if c and type(value) == "table" then
        value = value[c + 1]
      end
    end
  end
  return value
end

local function resolve_vars(bufnr, args)
  local out = {}
  for _, v in ipairs(args.vars or {}) do
    out[#out + 1] = { name = v.name, value = M.resolve_var(bufnr, v.value) }
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
local function insert_results(bufnr, start, lines_out, args)
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
  local header = indent .. "#+RESULTS:" .. (b.name and (" " .. b.name) or "")
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
  local ok, vars = pcall(resolve_vars, bufnr, args)
  if not ok then
    utils.error("babel: " .. tostring(vars))
    done(false)
    return
  end
  local body = src.body
  local nw = noweb_for(args, "eval")
  if nw then
    body = M.expand_noweb(bufnr, body, 0, nw)
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
    local out = results.format(res, args, src.lang)
    if handling == "silent" or handling == "none" or handling == "discard" then
      if handling == "silent" then
        utils.notify(table.concat(out or {}, "\n"))
      end
      done(true)
      return
    end
    if pos and pos[1] then
      insert_results(bufnr, pos[1] + 1, out or {}, args)
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

--- Remove the results of the block at cursor.
function M.remove_result()
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
    if not b.call then
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
          local body = b.body
          local nw = noweb_for(args, "tangle")
          if nw then
            body = M.expand_noweb(bufnr, body, 0, nw == "strip" and "strip" or nil)
          end
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

return M
