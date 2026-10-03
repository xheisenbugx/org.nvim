---@mod org.babel.commands Tangling, Library of Babel, sessions and other C-c C-v commands
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local langs = require("org.babel.langs")
local lisp = require("org.babel.lisp")
local session_mod = require("org.babel.session")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

local buf_lines = M.buf_lines
local get_file = M.get_file
local resolve_buf = P.resolve_buf
local noweb_for = P.noweb_for
local buf_dir = M.buf_dir
local resolve_vars = M.resolve_vars
local get_session = P.get_session

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
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, "<cmd>close<cr>", { buffer = buf, nowait = true })
  end
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
  local bufnr, src, args, b = block_at_cursor()
  if not src then
    return
  end
  -- like org-babel-view-src-block-info
  local out = {}
  if src.name then
    out[#out + 1] = "Name: " .. src.name
  end
  out[#out + 1] = "Language: " .. (src.lang ~= "" and src.lang or "none")
  out[#out + 1] = "Properties:"
  local file = get_file(bufnr)
  local ha = file and blocks_mod.inherited_property(file, b.start, "HEADER-ARGS") or nil
  local hl = file and blocks_mod.inherited_property(file, b.start, "HEADER-ARGS:" .. src.lang) or nil
  out[#out + 1] = "\t:header-args \t" .. (ha or "nil")
  out[#out + 1] = "\t:header-args:" .. src.lang .. " \t" .. (hl or "nil")
  if src.switches and vim.trim(src.switches) ~= "" then
    out[#out + 1] = "Switches: " .. vim.trim(src.switches)
  end
  out[#out + 1] = "Header Arguments:"
  local entries = {}
  for k, v in pairs(args) do
    if type(v) == "string" and v ~= "" then
      entries[#entries + 1] = { ":" .. k, v }
    end
  end
  local spec = {}
  for _, cat in ipairs({ "collection", "type", "format", "handling" }) do
    if args.results_spec[cat] and not (cat == "collection" and args.default_collection) then
      spec[#spec + 1] = args.results_spec[cat]
    end
  end
  vim.list_extend(spec, args.results_extra or {})
  entries[#entries + 1] = { ":results", table.concat(spec, " ") }
  for _, v in ipairs(args.vars) do
    entries[#entries + 1] = { ":var", v.name .. "=" .. v.value }
  end
  table.sort(entries, function(x, y)
    if x[1] ~= y[1] then
      return x[1] < y[1]
    end
    return x[2] < y[2]
  end)
  for _, e in ipairs(entries) do
    out[#out + 1] = "\t" .. e[1] .. (#e[1] > 7 and "" or "\t") .. "\t" .. e[2]
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
  local out_file = M.file_param(args, src.name, buf_dir(bufnr))
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

-- shared with the other parts of org.babel
P.block_at_cursor = block_at_cursor
P.show_scratch = show_scratch
