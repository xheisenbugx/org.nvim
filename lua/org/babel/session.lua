---@mod org.babel.session Persistent interpreter sessions (`:session`)
---
--- A session is one interactive interpreter (a REPL) per (language family,
--- buffer name), running in a Neovim terminal buffer named like Emacs'
--- comint buffers (`*Python*`, `*shell*`, `*name*`). The user can switch
--- to that buffer and type into the REPL; blocks and typed input share the
--- same state.
---
--- Like ob-comint (`org-babel-comint-with-output`), an evaluation is sent
--- to the REPL as input and its output is found between two indicator
--- lines:
---
---   __ORG_BABEL_BOS__ <id>
---   <what the code printed>
---   __ORG_BABEL_EOE__ <id> <status>
---
--- The code itself is written to a file in the session directory and the
--- REPL is sent one short line that runs it (a helper defined at start-up
--- for python, ruby, node and R; `.` / `source` for shells), the way
--- python.el sends code through a file. The helpers evaluate the code in
--- the REPL's global scope and write the value of the last expression to
--- `<id>.val` (like ob-python's session value wrapper) and an error message
--- to `<id>.err`. The indicators are spelt so that the echo of the input
--- line never contains them. Requests to one session are sent one at a
--- time, in order.
---
--- Lua sessions live inside Neovim as a persistent environment table, with
--- a prompt buffer as transcript.

local M = {}

M.BOS = "__ORG_BABEL_BOS__"
M.EOE = "__ORG_BABEL_EOE__"

---@type table<string, table> key "family:buffer name" -> session
M.sessions = {}

local next_id = 0

-- Python start-up file (PYTHONSTARTUP): the user's start-up file, then
-- the value formatter of ob-python and the request runner.
local PY_SETUP = [[
import os as __org_babel_os
__org_babel_startup = __org_babel_os.environ.get("ORG_BABEL_USER_STARTUP")
if __org_babel_startup and __org_babel_os.path.isfile(__org_babel_startup):
    try:
        exec(open(__org_babel_startup).read())
    except Exception:
        pass
%s

def __org_babel_run(id, __dir=__org_babel_os.environ["ORG_BABEL_SESSION_DIR"]):
    import sys, ast, traceback
    g = sys.modules["__main__"].__dict__
    base = __org_babel_os.path.join(__dir, str(id))
    with open(base + ".req") as f:
        req = f.read().split("\n")
    mode, gfile, params = req[0], req[1], [p for p in req[2:] if p]
    sys.stdout.write("__ORG_BABEL_BOS__ %%d\n" %% id)
    sys.stdout.flush()
    status = 0
    try:
        with open(base + ".src") as f:
            tree = ast.parse(f.read(), "<org-babel>", "exec")
        last = None
        if mode != "output" and tree.body and isinstance(tree.body[-1], ast.Expr):
            last = ast.Expression(tree.body.pop().value)
        exec(compile(tree, "<org-babel>", "exec"), g)
        value = eval(compile(last, "<org-babel>", "eval"), g) if last is not None else None
        if mode == "value":
            __org_babel_python_format_value(value, gfile if "graphics" in params else base + ".val", params)
        elif mode == "repl" and value is not None:
            print(repr(value))
    except BaseException as e:
        status = 1
        traceback.print_exception(type(e), e, e.__traceback__.tb_next)
        with open(base + ".err", "w") as f:
            f.write("".join(traceback.format_exception_only(type(e), e)).strip())
        if isinstance(e, SystemExit):
            raise
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        sys.stdout.write("\n__ORG_BABEL_EOE__ %%d %%d\n" %% (id, status))
        sys.stdout.flush()
]]

-- Node: a REPL sharing the global object with the code of the blocks.
local JS_SETUP = [[
const repl = require("repl");
const vm = require("vm");
const util = require("util");
const fs = require("fs");
const path = require("path");
globalThis.require = require;
const dir = process.env.ORG_BABEL_SESSION_DIR;
globalThis.__org_babel_run = async (id) => {
  const base = path.join(dir, String(id));
  const mode = fs.readFileSync(base + ".req", "utf8").split("\n")[0];
  process.stdout.write("__ORG_BABEL_BOS__ " + id + "\n");
  let status = 0;
  try {
    let v = vm.runInThisContext(fs.readFileSync(base + ".src", "utf8"), { filename: "org-babel" });
    if (v && typeof v.then === "function") v = await v;
    if (mode === "value") fs.writeFileSync(base + ".val", util.inspect(v));
    else if (mode === "repl" && v !== undefined) console.log(util.inspect(v));
  } catch (e) {
    status = 1;
    console.log(e && e.stack ? e.stack : String(e));
    fs.writeFileSync(base + ".err", String(e && e.message !== undefined ? e.message : e));
  }
  process.stdout.write("\n__ORG_BABEL_EOE__ " + id + " " + status + "\n");
};
repl.start({ prompt: "> ", useGlobal: true, ignoreUndefined: true, preview: false, useColors: false });
]]

-- irb start-up file (IRBRC): the user's ~/.irbrc, a plain line reader (no
-- multi-line editor or completion dialogs) and the request runner, which
-- evaluates in irb's own binding so local variables are shared.
local RB_SETUP = [[
begin
  user_rc = ENV["ORG_BABEL_USER_STARTUP"]
  load(user_rc) if user_rc && File.file?(user_rc)
rescue Exception
end
IRB.conf[:USE_MULTILINE] = false
IRB.conf[:USE_SINGLELINE] = false
IRB.conf[:USE_READLINE] = false
IRB.conf[:USE_COLORIZE] = false
IRB.conf[:USE_AUTOCOMPLETE] = false
IRB.conf[:PROMPT_MODE] = :DEFAULT
def __org_babel_run(id)
  b = (defined?(IRB) && IRB.CurrentContext) ? IRB.CurrentContext.workspace.binding : TOPLEVEL_BINDING
  base = File.join(ENV["ORG_BABEL_SESSION_DIR"], id.to_s)
  req = File.read(base + ".req").split("\n")
  mode, params = req[0], req[2..-1] || []
  $stdout.print "__ORG_BABEL_BOS__ #{id}\n"
  $stdout.flush
  status = 0
  begin
    value = eval(File.read(base + ".src"), b, "org-babel")
    if mode == "value"
      text = if params.include?("pp")
        require "pp"
        value.pretty_inspect
      else
        value.class == String ? value : value.inspect
      end
      File.write(base + ".val", text)
    elsif mode == "repl"
      puts value.inspect
    end
  rescue SystemExit
    raise
  rescue Exception => e
    status = 1
    puts "#{e.class}: #{e.message}"
    File.write(base + ".err", e.message)
  ensure
    $stdout.flush
    $stdout.print "\n__ORG_BABEL_EOE__ #{id} #{status}\n"
    $stdout.flush
  end
  nil
end
]]

-- R profile (R_PROFILE_USER): the user's ~/.Rprofile and the request
-- runner. The value is written like org-babel-R-write-object-command.
local R_SETUP = [[
local({
  f <- Sys.getenv("ORG_BABEL_USER_STARTUP")
  if (nzchar(f) && file.exists(f)) try(sys.source(f, envir = globalenv()), silent = TRUE)
})
.org_babel_run <- function(id, mode) {
  base <- file.path(Sys.getenv("ORG_BABEL_SESSION_DIR"), id)
  cat(sprintf("__ORG_BABEL_BOS__ %d\n", id))
  status <- 0L
  tryCatch({
    v <- source(paste0(base, ".src"), local = globalenv(), echo = FALSE, print.eval = mode != "value")$value
    if (mode == "value") {
      ok <- try(write.table(v, file = paste0(base, ".val"), sep = "\t", na = "nil",
                            row.names = FALSE, col.names = FALSE, quote = FALSE), silent = TRUE)
      if (inherits(ok, "try-error")) file.create(paste0(base, ".val"))
    }
  }, error = function(e) {
    status <<- 1L
    cat("Error:", conditionMessage(e), "\n")
    writeLines(conditionMessage(e), paste0(base, ".err"))
  })
  cat(sprintf("\n__ORG_BABEL_EOE__ %d %d\n", id, status))
  invisible(NULL)
}
]]

--- How each family's REPL is started and sent a request.
local REPL = {}

local function basename(cmd)
  return vim.fn.fnamemodify(cmd[1], ":t")
end

--- A program next to `cmd[1]` (the same installation), else on $PATH.
local function sibling(cmd, prog)
  local exe = vim.fn.exepath(cmd[1])
  if exe ~= "" then
    local p = vim.fn.fnamemodify(exe, ":h") .. "/" .. prog
    if vim.fn.executable(p) == 1 then
      return p
    end
  end
  return prog
end

REPL.shell = {
  default = "shell",
  argv = function(cmd)
    local sh = basename(cmd)
    local argv = vim.deepcopy(cmd)
    -- no start-up files: a predictable prompt and environment
    if sh == "bash" then
      vim.list_extend(argv, { "--noprofile", "--norc" })
    elseif sh == "zsh" then
      argv[#argv + 1] = "-f"
    elseif sh == "fish" then
      argv[#argv + 1] = "--no-config"
    end
    argv[#argv + 1] = "-i"
    return argv, { HISTFILE = "", BASH_SILENCE_DEPRECATION_WARNING = "1" }
  end,
  line = function(sess, id, src)
    local status = sess.family == "fish" and "$status" or '"$?"'
    local run = sess.family == "fish" and "source" or "."
    return string.format(
      [[printf '%%s\n' "%s""%s %d"; %s '%s'; printf '\n%%s %%s\n' "%s""%s %d" %s]],
      M.BOS:sub(1, 8),
      M.BOS:sub(9),
      id,
      run,
      src,
      M.EOE:sub(1, 8),
      M.EOE:sub(9),
      id,
      status
    )
  end,
}

REPL.python = {
  default = "Python",
  argv = function(cmd, dir, opts)
    local setup = dir .. "/setup.py"
    vim.fn.writefile(
      vim.split(PY_SETUP:format(require("org.babel.langs").PY_FORMAT_VALUE), "\n", { plain = true }),
      setup
    )
    local argv = vim.deepcopy(cmd)
    if not (opts and opts.explicit) then
      -- `session_cmd` (org-babel-python-command-session) is used as it is
      vim.list_extend(argv, { "-i", "-q" })
    end
    return argv,
      {
        PYTHONSTARTUP = setup,
        ORG_BABEL_USER_STARTUP = vim.env.PYTHONSTARTUP or "",
        PYTHON_BASIC_REPL = "1",
        PYTHON_COLORS = "0",
      }
  end,
  line = function(_, id)
    return string.format("__org_babel_run(%d)", id)
  end,
}

REPL.js = {
  default = "Javascript REPL",
  argv = function(cmd, dir)
    local setup = dir .. "/setup.js"
    vim.fn.writefile(vim.split(JS_SETUP, "\n", { plain = true }), setup)
    local argv = vim.deepcopy(cmd)
    argv[#argv + 1] = setup
    return argv, { NODE_DISABLE_COLORS = "1" }
  end,
  line = function(_, id)
    return string.format("await __org_babel_run(%d)", id)
  end,
}

REPL.ruby = {
  default = "ruby",
  argv = function(cmd, dir, opts)
    local setup = dir .. "/irbrc.rb"
    vim.fn.writefile(vim.split(RB_SETUP, "\n", { plain = true }), setup)
    local argv = vim.deepcopy(cmd)
    -- `ruby` (the configured interpreter) runs irb, like inf-ruby; a
    -- `:ruby` header argument is the REPL command itself
    if not opts.explicit and basename(cmd) == "ruby" then
      argv = { sibling(cmd, "irb") }
    end
    local user_rc = vim.env.IRBRC or vim.fn.expand("~/.irbrc")
    return argv, { IRBRC = setup, ORG_BABEL_USER_STARTUP = user_rc }
  end,
  line = function(_, id)
    return string.format("__org_babel_run(%d)", id)
  end,
}

REPL.r = {
  default = "R",
  argv = function(cmd, dir)
    local setup = dir .. "/Rprofile.R"
    vim.fn.writefile(vim.split(R_SETUP, "\n", { plain = true }), setup)
    local argv = vim.deepcopy(cmd)
    -- `Rscript` (the configured interpreter) runs the R console
    if basename(cmd) == "Rscript" then
      argv = { sibling(cmd, "R") }
    end
    vim.list_extend(argv, { "--no-save", "--no-restore", "--quiet" })
    local user_rc = vim.env.R_PROFILE_USER or vim.fn.expand("~/.Rprofile")
    return argv, { R_PROFILE_USER = setup, ORG_BABEL_USER_STARTUP = user_rc }
  end,
  line = function(_, id, _, mode)
    return string.format('.org_babel_run(%dL, "%s")', id, mode)
  end,
}

--- Languages whose `family` can run in a session.
local KIND = { shell = "shell", fish = "shell", python = "repl", js = "repl", ruby = "repl", r = "repl", lua = "lua" }

local function repl_of(fam)
  return REPL[fam == "fish" and "shell" or fam]
end

--- Can `lang` (of family `fam`) run in a session?
function M.supported(lang, fam)
  if fam == "js" and (lang == "ts" or lang == "typescript") then
    return false
  end
  return KIND[fam] ~= nil
end

--- Session name of a `:session` header value, or nil for no session.
function M.name(value)
  if value == nil then
    return nil
  end
  value = vim.trim(require("org.babel.blocks").unquote(value) or "")
  if value == "none" or value == "no" or value == "nil" then
    return nil
  end
  return value == "" and "default" or value
end

--- Buffer name of session `name` of family `fam`, like Emacs: the default
--- session is `*Python*`, `*shell*`, `*ruby*`, `*R*`, ...; another name
--- gets earmuffs (`py` -> `*py*`) unless it has them.
function M.buffer_name(fam, name)
  if name == "default" then
    local r = repl_of(fam)
    return "*" .. (r and r.default or fam) .. "*"
  end
  if name:match("^%*.+%*$") then
    return name
  end
  return "*" .. name .. "*"
end

local function key(fam, name)
  return fam .. ":" .. M.buffer_name(fam, name)
end

--- A buffer name not used by another session's live buffer.
local function unique_name(name)
  local taken = {}
  for _, s in pairs(M.sessions) do
    if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
      taken[vim.fn.fnamemodify(vim.api.nvim_buf_get_name(s.buf), ":t")] = true
    end
  end
  local out, n = name, 1
  while taken[out] do
    n = n + 1
    out = string.format("%s<%d>", name, n)
  end
  return out
end

--- Remove the buffer of an earlier (exited) session with this name.
local function drop_stale(name)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":t") == name then
      local live = false
      for _, s in pairs(M.sessions) do
        live = live or (s.buf == b and s.alive)
      end
      if not live then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end
end

---------------------------------------------------------------------------
-- Lua transcript buffer
---------------------------------------------------------------------------

--- Append lines to a Lua session's transcript, above its prompt line.
function M.append(sess, lines)
  local buf = sess.buf
  if sess.kind ~= "lua" or not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if type(lines) == "string" then
    lines = vim.split(lines, "\n", { plain = true })
  end
  if #lines == 0 then
    return
  end
  local n = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, n - 1, n - 1, false, lines)
  vim.bo[buf].modified = false
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
  end
end

--- Show `code` in a Lua session's transcript as input at its prompt.
function M.echo(sess, code)
  local out = {}
  for i, l in ipairs(vim.split(code, "\n", { plain = true })) do
    out[i] = (i == 1 and sess.prompt or string.rep(" ", #sess.prompt - 4) .. "... ") .. l
  end
  M.append(sess, out)
end

local function lua_buffer(sess)
  local name = M.buffer_name("lua", sess.name)
  drop_stale(name)
  local buf = vim.api.nvim_create_buf(true, true)
  pcall(vim.api.nvim_buf_set_name, buf, unique_name(name))
  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.fn.prompt_setprompt(buf, sess.prompt)
  vim.fn.prompt_setcallback(buf, function(text)
    if vim.trim(text) == "" then
      return
    end
    M.eval(sess, text, "repl", function() end, { echo = true, typed = true })
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      sess.buf = nil
      M.kill(sess)
    end,
  })
  sess.buf = buf
end

---------------------------------------------------------------------------
-- REPL processes
---------------------------------------------------------------------------

--- Terminal output as plain text: no escape sequences or carriage returns.
local function plain(s)
  s = s:gsub("\27%[[0-9;:?<=>]*[ -/]*[@-~]", "")
  s = s:gsub("\27%][^\7\27]*\7", ""):gsub("\27%][^\7\27]*\27\\", "")
  s = s:gsub("\27[%(%)][%w]", ""):gsub("\27[=>78cDEHM]", "")
  return (s:gsub("\r+\n", "\n"):gsub("\r", ""))
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

local function stop_timer(req)
  if req.timer then
    req.timer:stop()
    req.timer:close()
    req.timer = nil
  end
end

local send_next

--- The current request finished: collect its output, value and error.
local function finish(sess, req, output, status)
  sess.current = nil
  local base = sess.dir .. "/" .. req.id
  local res = { output = output, status = status }
  if sess.kind == "shell" then
    res.value = status
  else
    local err = read_file(base .. ".err")
    if status ~= 0 then
      res.error = (err and err ~= "") and err or "evaluation failed"
    elseif req.mode == "value" then
      res.value = read_file(base .. ".val") or ""
    end
  end
  for _, ext in ipairs({ ".src", ".req", ".val", ".err" }) do
    os.remove(base .. ext)
  end
  stop_timer(req)
  if not req.abandoned then
    req.cb(res)
  end
  send_next(sess)
end

local function on_output(sess, data)
  local req = sess.current
  if not req then
    return
  end
  -- without escape sequences: a terminal (ConPTY on Windows) may wrap the
  -- markers' lines in cursor and erase sequences. A sequence split between
  -- chunks is removed once its end arrives.
  sess.acc = plain(sess.acc .. table.concat(data, "\n"))
  if not req.bos then
    local s, e = sess.acc:find(M.BOS .. " " .. req.id .. "\r*\n")
    if not s then
      return
    end
    req.bos = true
    sess.acc = sess.acc:sub(e + 1)
    sess.scan = 1
  end
  local s, e, status = sess.acc:find(M.EOE .. " " .. req.id .. " (%-?%d+)\r*\n", sess.scan)
  if not s then
    -- the indicator may straddle the next chunk
    sess.scan = math.max(1, #sess.acc - #M.EOE - 32)
    return
  end
  local output = plain(sess.acc:sub(1, s - 1)):gsub("\n$", "")
  sess.acc = ""
  finish(sess, req, output, tonumber(status))
end

--- Send the next queued request to the REPL.
function send_next(sess)
  if sess.current or not sess.alive then
    return
  end
  local req = table.remove(sess.queue, 1)
  if not req then
    return
  end
  if req.abandoned then
    return send_next(sess)
  end
  local base = sess.dir .. "/" .. req.id
  local r = repl_of(sess.family)
  local src = base .. ".src"
  vim.fn.writefile(vim.split(req.code, "\n", { plain = true }), src)
  local params = req.params or {}
  vim.fn.writefile(vim.list_extend({ req.mode, req.file or "" }, params), base .. ".req")
  sess.current = req
  sess.acc = ""
  sess.scan = 1
  -- C-u first discards what was typed at the prompt and not yet sent
  -- (readline's unix-line-discard: a Windows console would insert it, and
  -- takes \r for Enter)
  local win = vim.fn.has("win32") == 1
  local line = r.line(sess, req.id, src, req.mode)
  local ok, err = pcall(vim.fn.chansend, sess.job, win and (line .. "\r") or ("\21" .. line .. "\n"))
  if not ok or err == 0 then
    sess.current = nil
    stop_timer(req)
    req.cb({ error = "cannot send to session '" .. sess.name .. "': " .. tostring(err), output = "" })
    send_next(sess)
  end
end

local function on_exit(sess, code)
  if M.sessions[sess.key] == sess then
    M.sessions[sess.key] = nil
  end
  sess.alive = false
  local pending = sess.queue
  if sess.current then
    table.insert(pending, 1, sess.current)
  end
  local leftover = vim.trim(plain(sess.acc or ""))
  sess.current, sess.queue, sess.acc = nil, {}, ""
  for _, req in ipairs(pending) do
    stop_timer(req)
    if not req.abandoned then
      req.cb({
        error = string.format("session '%s' exited with code %s", sess.name, tostring(code)),
        output = req.bos and leftover or "",
      })
    end
  end
end

local leave_autocmd = false

--- Start the REPL of `sess` in a new terminal buffer.
local function start_repl(sess, opts)
  local r = repl_of(sess.family)
  sess.dir = vim.fn.tempname()
  vim.fn.mkdir(sess.dir, "p")
  local argv, env = r.argv(opts.cmd, sess.dir, opts)
  if vim.fn.executable(argv[1]) == 0 then
    error("Executable not found: " .. argv[1], 0)
  end
  env.ORG_BABEL_SESSION_DIR = sess.dir
  local name = M.buffer_name(sess.family, sess.name)
  drop_stale(name)
  local buf = vim.api.nvim_create_buf(true, false)
  local job
  local jopts = {
    cwd = opts.cwd,
    env = env,
    on_stdout = function(_, data)
      on_output(sess, data)
    end,
    on_exit = function(_, code)
      on_exit(sess, code)
    end,
  }
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    jopts.term = true
    job = vim.fn.jobstart(argv, jopts)
  end)
  if not ok or not job or job <= 0 then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    error("cannot start session: " .. (ok and ("cannot run " .. argv[1]) or tostring(err)), 0)
  end
  pcall(vim.api.nvim_buf_set_name, buf, unique_name(name))
  vim.bo[buf].bufhidden = "hide"
  sess.buf, sess.job = buf, job
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      sess.buf = nil
      M.kill(sess)
    end,
  })
end

--- Start a session.
---@param opts { lang: string, family: string, name: string, cmd: string[], cwd?: string, explicit?: boolean }
local function start(opts)
  local sess = {
    key = key(opts.family, opts.name),
    lang = opts.lang,
    family = opts.family,
    name = opts.name,
    kind = KIND[opts.family],
    prompt = opts.lang .. "> ",
    queue = {},
    acc = "",
    alive = true,
    cwd = opts.cwd,
  }
  if sess.kind == "lua" then
    lua_buffer(sess)
    sess.env = setmetatable({}, { __index = _G })
    M.sessions[sess.key] = sess
    return sess
  end
  start_repl(sess, opts)
  M.sessions[sess.key] = sess
  if not leave_autocmd then
    leave_autocmd = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        M.kill_all()
      end,
    })
  end
  return sess
end

--- The running session for (family, name), started when needed.
--- `opts.explicit`: `cmd` comes from a header argument (`:ruby`).
---@param opts { lang: string, family: string, name: string, cmd?: string[], cwd?: string, explicit?: boolean }
function M.get(opts)
  local sess = M.sessions[key(opts.family, opts.name)]
  if sess and sess.alive then
    return sess
  end
  return start(opts)
end

--- Look up a running session without starting it.
function M.find(family, name)
  return M.sessions[key(family, name)]
end

--- Evaluate `code` in `sess`; `cb(res)` gets { output, value?, status?, error? }.
--- `mode` is "value", "output" or "repl" (output plus the value of a last
--- expression, as typed at the prompt).
--- `opts.params` are the result params (python formats the value like
--- Emacs), `opts.file` the graphics file.
---@param opts? { timeout?: integer, echo?: boolean, params?: string[], file?: string }
function M.eval(sess, code, mode, cb, opts)
  opts = opts or {}
  if sess.kind == "lua" then
    if opts.echo ~= false and not opts.typed then
      M.echo(sess, code)
    end
    local langs = require("org.babel.langs")
    local res = langs.run_lua(vim.split(code, "\n", { plain = true }), {}, {}, sess.env)
    local r = { output = res.output or "", error = res.error, value = res.value }
    if res.error then
      r.output = (r.output ~= "" and (r.output .. "\n") or "") .. res.error
    elseif mode == "repl" and res.value ~= nil then
      r.output = (r.output ~= "" and (r.output .. "\n") or "") .. vim.inspect(res.value)
    end
    if opts.echo ~= false and vim.trim(r.output) ~= "" then
      M.append(sess, (r.output:gsub("\n+$", "")))
    end
    vim.schedule(function()
      cb(r)
    end)
    return
  end
  if not sess.alive then
    vim.schedule(function()
      cb({ error = "session '" .. sess.name .. "' is not running", output = "" })
    end)
    return
  end
  next_id = next_id + 1
  local req = { id = next_id, code = code, mode = mode, cb = cb, params = opts.params, file = opts.file }
  local timeout = opts.timeout
  if timeout and timeout > 0 then
    req.timer = vim.uv.new_timer()
    req.timer:start(
      timeout,
      0,
      vim.schedule_wrap(function()
        if not req.abandoned and req.timer then
          req.abandoned = true
          stop_timer(req)
          cb({ error = string.format("session '%s' timed out after %d ms", sess.name, timeout), output = "" })
        end
      end)
    )
  end
  sess.queue[#sess.queue + 1] = req
  send_next(sess)
end

--- Synchronous `eval`: waits for the result (for :var references, noweb
--- calls and export).
function M.eval_sync(sess, code, mode, opts)
  opts = opts or {}
  local res
  M.eval(sess, code, mode, function(r)
    res = r
  end, opts)
  local limit = (opts.timeout and opts.timeout > 0) and (opts.timeout + 1000) or 24 * 3600 * 1000
  vim.wait(limit, function()
    return res ~= nil
  end, 5)
  return res or { error = "session '" .. sess.name .. "' did not answer", output = "" }
end

--- Stop a session (a session object, or "family:name") and remove its
--- buffer, like killing an Emacs session buffer.
function M.kill(sess)
  if type(sess) == "string" then
    local fam, name = sess:match("^([^:]+):(.*)$")
    sess = M.sessions[sess] or (fam and M.find(fam, name))
  end
  if not sess then
    return false
  end
  if M.sessions[sess.key] == sess then
    M.sessions[sess.key] = nil
  end
  local was_alive = sess.alive
  sess.alive = false
  if sess.job and was_alive then
    pcall(vim.fn.jobstop, sess.job)
  end
  if sess.buf and vim.api.nvim_buf_is_valid(sess.buf) then
    local buf = sess.buf
    sess.buf = nil
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  if sess.dir then
    vim.fn.delete(sess.dir, "rf")
  end
  return true
end

function M.kill_all()
  for _, sess in pairs(M.sessions) do
    M.kill(sess)
  end
end

--- Show the buffer of `sess` (its REPL terminal, or the Lua transcript)
--- in a split and return its window.
function M.show(sess)
  if not sess.buf or not vim.api.nvim_buf_is_valid(sess.buf) then
    if sess.kind ~= "lua" then
      return nil
    end
    lua_buffer(sess)
  end
  local wins = vim.fn.win_findbuf(sess.buf)
  if #wins > 0 then
    vim.api.nvim_set_current_win(wins[1])
  else
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, sess.buf)
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { vim.api.nvim_buf_line_count(sess.buf), 0 })
  return vim.api.nvim_get_current_win()
end

return M
