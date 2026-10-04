---@mod org.babel.exec Running code: commands, sessions, error output
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

local buf_dir = M.buf_dir

---------------------------------------------------------------------------
-- Execution
---------------------------------------------------------------------------

local function split_cmd(cmd)
  if type(cmd) == "table" then
    return vim.deepcopy(cmd)
  end
  return vim.split(vim.trim(cmd), "%s+")
end

--- Working directory of a block (`:dir`, created unless `:mkdirp` is
--- missing, "no" or "nil"). Like Emacs, a `:dir` that does not exist is
--- an error: the code must not run in another directory.
local function block_cwd(bufnr, args)
  local file_dir = buf_dir(bufnr)
  if not args.dir then
    return utils.is_dir(file_dir) and file_dir or vim.fn.getcwd()
  end
  local cwd = utils.expand(blocks_mod.unquote(args.dir), file_dir)
  local mkdirp = args.mkdirp
  if mkdirp ~= nil and mkdirp ~= "no" and mkdirp ~= "nil" and not utils.is_dir(cwd) then
    vim.fn.mkdir(cwd, "p")
  end
  if not utils.is_dir(cwd) then
    error("Setting current directory: No such file or directory, " .. cwd, 0)
  end
  return cwd
end
M.block_cwd = block_cwd

local warned_session = {}

--- Session name of a block, or nil (warns once for languages without
--- session support, which then run without one).
local function block_session(lang, args)
  local name = session_mod.name(args.session)
  local handler = require("org.babel.ob").get(lang)
  if handler then
    -- ob-LANG ports read :session themselves (ob-screen)
    return nil
  end
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
  elseif fam == "shell" and lang_cfg == nil then
    -- a shell of `babel.shell_names` runs as itself (org-babel-shell-initialize)
    return { lang }
  end
  return nil
end

--- The session of a block, started when needed.
local function get_session(bufnr, lang, args, name)
  local fam = langs.family(lang)
  local cmd = {}
  local explicit = fam == "ruby" and args.ruby ~= nil
  -- org-babel-python-command-session: the REPL command, used as it is
  local py_session = fam == "python" and not args.python and langs.lang_opt(lang, "session_cmd")
  if fam ~= "lua" then
    if py_session then
      cmd, explicit = split_cmd(py_session), true
    else
      cmd = lang_cmd(lang, args)
    end
    if not cmd then
      error("No babel command configured for language: " .. tostring(lang), 0)
    end
    if vim.fn.executable(cmd[1]) == 0 then
      error("Executable not found: " .. cmd[1], 0)
    end
  end
  return session_mod.get({
    lang = lang,
    family = fam,
    name = name,
    cmd = cmd,
    cwd = block_cwd(bufnr, args),
    explicit = explicit,
  })
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
  utils.warn(
    code and string.format("Babel evaluation exited with code %s", tostring(code))
      or "Babel evaluation exited abnormally"
  )
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
  if langs.family(lang) == "python" and args.results_spec.collection == "value" and args["return"] then
    -- in a session :return is an expression line (ob-python)
    lines[#lines + 1] = args["return"]
  end
  return table.concat(lines, "\n")
end

--- The result of an in-process Lua evaluation.
local function lua_result(res, args)
  local rp = results.result_params(args)
  if args.results_spec.collection == "output" then
    local out = res.output or ""
    if not langs.scalar_result(args) then
      -- `:results output table`: read like org-babel-lua-table-or-string
      return langs.lua_table_or_string(vim.trim(out))
    end
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

local function run_in_session(bufnr, lang, body, args, vars, name, done, sync, graphics_file, job)
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
      if fam == "r" and not langs.scalar_result(args) then
        -- the value was written as a tab-separated table (ob-R)
        return { result = lisp.import_table(raw, "tab"), error = sres.error }
      end
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
  local req = session_mod.eval(sess, code, mode, function(sres)
    done(convert(sres))
  end, eopts)
  if req then
    jobs.set_kill(job, function()
      session_mod.cancel(sess, req)
    end)
  end
end

--- Run the steps of a spec (see `langs.prepare`) one after the other and
--- call `cb(stdout)` with the output of the last. Failures are shown in
--- the error buffer; like `org-babel-eval`, the output is still used.
--- `job` (org.babel.jobs) gets a way to kill the running step; once it is
--- cancelled nothing more runs and `cb` is not called.
local function run_steps(spec, cwd, sync, cb, job)
  local timeout = require("org.config").opts.babel.timeout
  local outs = {}
  local failed = false
  local i = 0
  local function sys_opts(step)
    local env = vim.tbl_extend("force", { PWD = cwd }, step.env or {})
    return { cwd = cwd, text = true, stdin = step.stdin, timeout = timeout, env = env }
  end
  local function handle(obj, step)
    local stderr = obj.stderr or ""
    local code = obj.code
    if obj.signal and obj.signal ~= 0 and code == 0 then
      code = 128 + obj.signal
    end
    if step and step.after then
      -- a look at the step's output (ob-csharp checks the build log)
      step.after(obj)
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
  -- a `fn` step runs Lua (moving a file, a conversion done in Neovim): its
  -- return value is the step's output, an error its failure
  local function run_fn(step)
    local ok, out = pcall(step.fn)
    return { code = ok and 0 or 1, stdout = ok and (out or "") or "", stderr = not ok and tostring(out) or "" }
  end
  if sync then
    for _, step in ipairs(spec.steps) do
      local ok, obj = pcall(function()
        if step.fn then
          return run_fn(step)
        end
        return vim.system(argv(step), sys_opts(step)):wait()
      end)
      if not ok then
        M.error_notify(nil, tostring(obj))
        return cb(nil, true)
      end
      handle(obj, step)
    end
    return cb(outs[#outs] or "", failed)
  end
  local function nxt()
    if job and job.cancelled then
      return
    end
    i = i + 1
    local step = spec.steps[i]
    if not step then
      return cb(outs[#outs] or "", failed)
    end
    if step.fn then
      handle(run_fn(step), step)
      return nxt()
    end
    local ok, proc = pcall(vim.system, argv(step), sys_opts(step), function(obj)
      vim.schedule(function()
        if job and job.cancelled then
          -- killed on purpose: no error buffer, no result
          return
        end
        handle(obj, step)
        nxt()
      end)
    end)
    if ok then
      jobs.set_kill(job, function()
        jobs.kill_process(proc)
      end)
    else
      M.error_notify(nil, tostring(proc))
      cb(nil, true)
    end
  end
  nxt()
end
M.run_steps = run_steps

--- Run code and call `cb(r)` with `r = { result, error? }`: `result` is
--- the Babel value `org-babel-execute:LANG` returns. With `opts.sync` the
--- call blocks and returns `r`.
--- `opts.job` (org.babel.jobs, asynchronous runs only) can cancel it.
---@param opts? { sync?: boolean, colnames?: table, graphics_file?: string, job?: org.babel.Job }
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
    run_in_session(bufnr, lang, body, args, vars, sname, done, sync, opts.graphics_file, opts.job)
    return result
  end
  local cwd = block_cwd(bufnr, args)
  if fam == "lua" and not langs.lua_external() then
    local res = langs.run_lua(body, args, vars)
    if res.error then
      M.error_notify(nil, res.error)
      done({
        error = res.error,
        result = args.results_spec.collection == "output" and res.output ~= "" and (res.output .. "\n") or nil,
      })
    else
      done({ result = lua_result(res, args) })
    end
    return result
  end
  if lang == "emacs-lisp" or lang == "elisp" then
    -- in a separate `emacs --batch`, else on the table formula interpreter
    local elisp = require("org.babel.elisp")
    local ecmd = elisp.command()
    if not ecmd then
      local res = elisp.run_internal(body, args, vars)
      if res.error then
        -- a Lisp error: like Emacs, no result is inserted
        M.error_notify(nil, res.error)
        res.abort = true
      end
      done(res)
      return result
    end
    local spec = elisp.prepare(ecmd, body, args, vars)
    run_steps(spec, cwd, sync, function(stdout, failed)
      local value = stdout and elisp.convert(spec, args)
      if stdout == nil or (failed and value == nil) then
        return done({ error = true, abort = true })
      end
      done({ result = value, error = failed or nil })
    end, opts.job)
    return result
  end
  local ob = require("org.babel.ob")
  local handler = ob.get(lang)
  if handler then
    -- a language with its own port of ob-LANG.el (org.babel.lang.*)
    local octx = { bufnr = bufnr, cwd = cwd, sync = sync, colnames = opts.colnames, job = opts.job }
    ob.run(handler, lang, body, args, vars, octx, done)
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
    if spec.result_file and opts.graphics_file and vim.fn.filereadable(spec.result_file) == 0 then
      -- Emacs reads the value back from the graphics file: an error when missing
      local msg = "Opening input file: No such file or directory, " .. spec.result_file
      utils.error(msg)
      return done({ error = msg, abort = true })
    end
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
  run_steps(spec, cwd, sync, finish, opts.job)
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

-- shared with the other parts of org.babel
P.get_session = get_session
