---@mod org.babel.evaluate Evaluating src blocks and inserting their results
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local jobs = require("org.babel.jobs")
local langs = require("org.babel.langs")
local lisp = require("org.babel.lisp")
local results = require("org.babel.results")
local session_mod = require("org.babel.session")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

local buf_lines = M.buf_lines
local buffer_blocks = M._buffer_blocks
local resolve_buf = P.resolve_buf
local ns = vim.api.nvim_create_namespace("org.babel")
local noweb_for = P.noweb_for
local buf_dir = M.buf_dir
local read_element = M.read_element
local resolve_vars = M.resolve_vars
local block_cwd = M.block_cwd
local write_file_result = P.write_file_result
local strip_coderefs = M.strip_coderefs
local name_string = P.name_string

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
---@param opts? { sync?: boolean, skip_confirm?: boolean, export?: boolean, depth?: integer, current_hash?: string, read_cached?: (fun(): any), force?: boolean, on_start?: fun(), job?: org.babel.Job }
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
    finish(nil, { error = tostring(vars), skipped = true, abort = true })
    return ret_result, ret_info
  end
  if noweb_for(args, "eval") then
    local nok, expanded = pcall(M.expand_noweb, bufnr, body, 0, nil, args, "eval")
    if not nok then
      utils.error("babel: " .. tostring(expanded))
      finish(nil, { error = tostring(expanded), skipped = true, abort = true })
      return ret_result, ret_info
    end
    body = expanded
  end
  local out_file = M.file_param(args, name, buf_dir(bufnr))
  if out_file then
    args.file = out_file
  end
  local hash
  if args.cache == "yes" and not opts.force then
    hash = M.cache_hash(lang, body, args, vars, meta)
    if opts.current_hash and opts.current_hash == hash and opts.read_cached then
      local result = opts.read_cached()
      -- (format "%S" result), with the newlines escaped as by
      -- print-escape-newlines: a second line would be a hit-enter prompt
      local shown = lisp.prin1(result):gsub("\n", "\\n")
      utils.notify("Cached: " .. shown)
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
  local cok, cwd = pcall(block_cwd, bufnr, args)
  if not cok then
    utils.error("babel: " .. tostring(cwd))
    finish(nil, { error = tostring(cwd), skipped = true, abort = true })
    return ret_result, ret_info
  end
  local graphics_file
  if rp.graphics and langs.family(lang) == "python" then
    if not args.file then
      local msg = args["file-ext"] and ":file-ext given but no :file generated; did you forget to name a block?"
        or "No :file header argument given; cannot create graphical result"
      utils.error(msg)
      finish(nil, { error = msg, skipped = true, abort = true })
      return ret_result, ret_info
    end
    graphics_file = utils.expand(blocks_mod.unquote(args.file), cwd)
  end
  local colnames = {}
  for _, pair in ipairs(meta.colnames or {}) do
    colnames[pair[1]] = pair[2]
  end
  local function after(r)
    if r.abort then
      return finish(nil, { skipped = true, abort = true, error = r.error })
    end
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
        local wok, werr = write_file_result(utils.expand(file, cwd), result, args)
        if wok == false then
          utils.error(werr)
          return finish(nil, { skipped = true, abort = true, error = werr })
        end
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
    after(
      M.run(bufnr, lang, body, args, vars, nil, { sync = true, colnames = colnames, graphics_file = graphics_file })
    )
  else
    if opts.on_start then
      -- may set opts.job (org.babel.jobs): the run can then be cancelled
      opts.on_start()
    end
    M.run(bufnr, lang, body, args, vars, after, { colnames = colnames, graphics_file = graphics_file, job = opts.job })
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
  local lines, list = buffer_blocks(bufnr)
  local b
  for _, x in ipairs(list) do
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

-- A point alone can slide onto a different block when its source is
-- deleted. Track the complete source and check it before inserting an
-- asynchronous result; edits outside the source may still move it.
local function track_source(bufnr, row, col, end_row, end_col, opts)
  local text = vim.api.nvim_buf_get_text(bufnr, row, col, end_row, end_col, {})
  local mark = vim.api.nvim_buf_set_extmark(
    bufnr,
    ns,
    row,
    col,
    vim.tbl_extend("force", opts or {}, {
      end_row = end_row,
      end_col = end_col,
      right_gravity = true,
      end_right_gravity = false,
      invalidate = true,
    })
  )
  return { mark = mark, text = text }
end

--- The tracked source's position, or nil and whether evaluation should
--- stop: a deleted buffer ends the run, while a changed source only
--- discards this result (with a warning) so later blocks still run.
local function take_source(bufnr, source)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil, true
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, source.mark, { details = true })
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, source.mark)
  local detail = pos[3]
  if not detail or detail.invalid then
    utils.warn("Source changed during evaluation; result discarded")
    return nil, false
  end
  local text = vim.api.nvim_buf_get_text(bufnr, pos[1], pos[2], detail.end_row, detail.end_col, {})
  if not vim.deep_equal(text, source.text) then
    utils.warn("Source changed during evaluation; result discarded")
    return nil, false
  end
  return pos
end

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

--- Whether an interactive run writes a placeholder result at once
--- (org-babel-comint-use-async): `:async` (not "no") on a session block
--- like Emacs, or any block with `babel.async` unless it says `:async no`.
--- Never outside interactive runs, and not for Lua run inside Neovim,
--- which finishes at once.
local function use_async(args, lang, opts)
  if opts.sync or opts.export then
    return false
  end
  local async = args.async
  if async ~= nil and vim.trim(async) == "no" then
    return false
  end
  local rp = results.result_params(args)
  if args.results_spec.handling ~= "replace" or rp.silent or rp.none then
    return false
  end
  local fam = langs.family(lang)
  local in_session = session_mod.name(args.session) ~= nil and session_mod.supported(lang, fam)
  if fam == "lua" and (in_session or not langs.lua_external()) then
    return false
  end
  if async ~= nil and in_session then
    return true
  end
  return require("org.config").opts.babel.async == true
end

--- Run `fn` (a change of `bufnr`) as part of the previous undo step when
--- nothing changed the buffer since `tick`: the placeholder and the result
--- that replaces it are one step for `u`.
local function joined(bufnr, tick, fn)
  if not tick or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
    return fn()
  end
  vim.api.nvim_buf_call(bufnr, function()
    -- E790 after an undo: then it is a step of its own
    pcall(vim.cmd, "undojoin")
    fn()
  end)
end

--- A random placeholder id, like org-id-uuid.
local function async_uuid()
  local h = utils.sha256(tostring(vim.uv.hrtime()) .. tostring(math.random()))
  local variant = ("89ab"):sub(tonumber(h:sub(17, 17), 16) % 4 + 1, tonumber(h:sub(17, 17), 16) % 4 + 1)
  return table.concat({ h:sub(1, 8), h:sub(9, 12), "4" .. h:sub(14, 16), variant .. h:sub(18, 20), h:sub(21, 32) }, "-")
end

--- The start line of the block whose result contains `uuid`
--- (org-babel-comint-async--find-src), or nil when it was removed.
local function find_async_block(bufnr, uuid)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local lines, list = buffer_blocks(bufnr)
  for _, x in ipairs(list) do
    if x.results then
      for i = x.results.start, x.results.finish or x.results.start do
        if lines[i] and lines[i]:find(uuid, 1, true) then
          return x.start
        end
      end
    end
  end
end

--- Execute the block at (bufnr, lnum). `on_done(ok)` is called when done.
--- With `sync` the evaluation blocks and results are inserted before return.
---@param opts? { bufnr?: integer, lnum?: integer, skip_confirm?: boolean, sync?: boolean, handling?: string, on_done?: (fun(ok: boolean, abort?: boolean)), export?: boolean, force?: boolean, params?: string }
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
  local last = vim.api.nvim_buf_get_lines(bufnr, b.finish - 1, b.finish, false)[1]
  local source = track_source(bufnr, b.start - 1, 0, b.finish - 1, #last)
  -- uuid: the placeholder result; tick: the changedtick right after it
  -- was written; job: the running evaluation (org.babel.jobs)
  local uuid, tick, lost, job, pargs
  local function finish(result, info)
    if job and job.cancelled then
      -- cancelled: on_cancel already showed it and called `done`
      return
    end
    jobs.finish(job)
    local pos, abort
    if lost then
      done(false, not vim.api.nvim_buf_is_valid(bufnr))
      return
    elseif uuid then
      -- :async: the result replaces its placeholder wherever the block is
      -- now, even when the source was edited meanwhile (like Emacs)
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, source.mark)
      local start = find_async_block(bufnr, uuid)
      if not start then
        utils.warn("Async result placeholder " .. uuid .. " not found; result discarded")
        done(false, not vim.api.nvim_buf_is_valid(bufnr))
        return
      end
      pos = { start - 1, 0 }
    else
      pos, abort = take_source(bufnr, source)
    end
    if not pos then
      done(false, abort)
      return
    end
    if info.skipped then
      done(false, info.abort)
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
      -- :results silent echoes the value (message "%S")
      utils.notify(lisp.prin1(result))
    elseif not rp.none and pos and pos[1] then
      local ctx = { base_dir = buf_dir(bufnr), cwd = info.cwd }
      joined(bufnr, tick, function()
        insert_results(bufnr, pos[1] + 1, result, iargs, rp.replace and info.hash or nil, src.lang, ctx)
      end)
    end
    M.fire("OrgBabelAfterExecute", { bufnr = bufnr, lang = src.lang, name = src.name, result = result })
    done(info.error == nil)
  end
  --- The job was cancelled (`:Org babel_cancel`, or its buffer is unloading).
  local function on_cancel(_, copts)
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, source.mark)
    local loaded = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
    if uuid and loaded and not copts.unloading then
      -- the placeholder says so; elsewhere the previous result stays
      local start = find_async_block(bufnr, uuid)
      if start then
        joined(bufnr, tick, function()
          insert_results(bufnr, start, M.CANCELLED, pargs, nil, src.lang, { base_dir = buf_dir(bufnr) })
        end)
      end
    end
    done(false, true)
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
  local placeholder = use_async(args, src.lang, opts)
  eopts.on_start = function()
    -- only asynchronous runs get here, right before the code starts
    local row = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, source.mark, {})[1]
    if row then
      job = jobs.start(bufnr, row, { lang = src.lang, name = src.name })
      job.on_cancel = on_cancel
      eopts.job = job
    end
    if not placeholder then
      return
    end
    -- org-babel-comint-async: write a placeholder result right away
    local start = take_source(bufnr, source)
    if not start then
      lost = true
      jobs.finish(job)
      job, eopts.job = nil, nil
      return
    end
    uuid = async_uuid()
    source = track_source(bufnr, start[1], 0, start[1], 0)
    pargs = vim.deepcopy(args)
    pargs.results_spec.type = nil
    pargs.file, pargs.wrap = nil, nil
    insert_results(bufnr, start[1] + 1, uuid, pargs, nil, src.lang, { base_dir = buf_dir(bufnr) })
    tick = vim.api.nvim_buf_get_changedtick(bufnr)
  end
  if opts.sync then
    local result, info = M.evaluate(bufnr, src, args, eopts)
    finish(result, info)
  else
    M.evaluate(bufnr, src, args, eopts, finish)
  end
end

--- The result that replaces the placeholder of a cancelled evaluation.
M.CANCELLED = "[ Babel evaluation cancelled ]"

--- Cancel the evaluation of the block (or #+CALL / inline element) at the
--- cursor: its process is killed, or its session interrupted. Elsewhere,
--- the only running evaluation, or one picked from the list. With a count,
--- every running evaluation.
function M.cancel_block()
  if vim.v.count > 0 then
    local n = jobs.cancel_all({ quiet = true })
    utils.notify(string.format("Cancelled %d evaluation%s", n, n == 1 and "" or "s"))
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local job = jobs.at(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not job then
    local all = jobs.list()
    if #all == 0 then
      utils.notify("No source block evaluation is running")
      return
    elseif #all == 1 then
      job = all[1]
    else
      job = utils.select(all, { prompt = "Cancel evaluation", format_item = jobs.describe })
      if not job then
        return
      end
    end
  end
  jobs.cancel(job)
end

--- Evaluate a block synchronously and return its result without inserting
--- it (what a :var reference or a noweb call sees), like
--- org-babel-execute-src-block with `:results none`.
---@param src table the block (the target of a #+CALL)
---@param opts? { depth?: integer, skip_confirm?: boolean, block?: table }
function M.evaluate_sync(bufnr, src, args, opts)
  opts = opts or {}
  local holder = opts.block or src
  local result, info = M.evaluate(bufnr, src, args, {
    sync = true,
    skip_confirm = opts.skip_confirm,
    depth = opts.depth,
    current_hash = holder.results and holder.results.hash,
    read_cached = function()
      return holder.results and type(bufnr) == "number" and read_block_result(bufnr, holder)
    end,
  })
  if info and info.abort then
    -- errors (a missing reference ...) stop the evaluation that needed it
    error(info.error or "evaluation failed", 0)
  end
  return result
end

--- Evaluate the block (or #+CALL) `b` for the reference `ref`.
local function evaluate_ref(bufnr, b, ref, file, opts)
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

-- shared with the other parts of org.babel
P.track_source = track_source
P.take_source = take_source
P.evaluate_ref = evaluate_ref
