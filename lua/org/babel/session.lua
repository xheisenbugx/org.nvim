---@mod org.babel.session Persistent interpreter sessions (`:session`)
---
--- A session is one long-running interpreter per (language family, name).
--- Every evaluation is written to its stdin as a framed request and the
--- interpreter answers with the output of the code followed by an
--- end-of-evaluation line:
---
---   __ORG_BABEL_EOE__ <id> <status> <json value or error message>
---
--- Python, Ruby and Node run a small driver that evaluates each request in
--- one persistent global scope and reports the value of the last
--- expression (like Emacs). Shells run the code directly and report `$?`.
--- Lua sessions live inside Neovim as a persistent environment table.
---
--- Each session has a transcript buffer (a prompt buffer): lines typed at
--- its prompt are evaluated in the session, like an Emacs REPL buffer.
--- Wiping that buffer kills the session.

local M = {}

M.EOF = "__ORG_BABEL_EOF__"
M.EOE = "__ORG_BABEL_EOE__"

---@type table<string, table> key "family:name" -> session
M.sessions = {}

local next_id = 0

-- Evaluate requests in one global scope. `value` returns the value of the
-- last expression statement (None when the code ends with a statement),
-- `repl` prints its repr like the interactive interpreter.
local PY_DRIVER = [[
import sys, os, json, ast, traceback
os.dup2(1, 2)
sys.stderr = sys.stdout
_org_g = {"__name__": "__main__", "__builtins__": __builtins__}
def _org_run(code, mode):
    tree = ast.parse(code, "<org-babel>", "exec")
    last = None
    if mode != "output" and tree.body and isinstance(tree.body[-1], ast.Expr):
        last = ast.Expression(tree.body.pop().value)
    exec(compile(tree, "<org-babel>", "exec"), _org_g)
    if last is not None:
        return eval(compile(last, "<org-babel>", "eval"), _org_g)
    return None
# the text Emacs' __org_babel_python_format_value writes for a value
def _org_fmt(result, result_params, result_file):
    if 'graphics' in result_params:
        result.savefig(result_file)
        return ""
    if 'pp' in result_params:
        import pprint
        return pprint.pformat(result)
    if 'list' in result_params and isinstance(result, dict):
        return str(['{} :: {}'.format(k, v) for k, v in result.items()])
    if not set(result_params).intersection(['scalar', 'verbatim', 'raw']):
        def dict2table(res):
            if isinstance(res, dict):
                return [(k, dict2table(v)) for k, v in res.items()]
            elif isinstance(res, list) or isinstance(res, tuple):
                return [dict2table(x) for x in res]
            else:
                return res
        if 'table' in result_params:
            result = dict2table(result)
        try:
            import pandas
        except ImportError:
            pass
        else:
            if isinstance(result, pandas.DataFrame) and 'table' in result_params:
                result = [[result.index.name or ''] + list(result.columns)] + \
                    [None] + [[i] + list(row) for i, row in result.iterrows()]
            elif isinstance(result, pandas.Series) and 'table' in result_params:
                result = list(result.items())
        try:
            import numpy
        except ImportError:
            pass
        else:
            if isinstance(result, numpy.ndarray):
                if 'table' in result_params:
                    result = result.tolist()
                else:
                    result = repr(result)
    return str(result)
while True:
    header = sys.stdin.readline()
    if not header:
        break
    req = json.loads(header)
    lines = []
    while True:
        line = sys.stdin.readline()
        if not line or line.rstrip("\r\n") == "__ORG_BABEL_EOF__":
            break
        lines.append(line)
    status, payload = 0, ""
    try:
        value = _org_run("".join(lines), req["mode"])
        if req["mode"] == "value":
            payload = json.dumps(_org_fmt(value, req.get("params") or [], req.get("file") or ""))
        elif req["mode"] == "repl" and value is not None:
            print(repr(value))
    except SystemExit:
        raise
    except BaseException as e:
        traceback.print_exc()
        status = 1
        payload = json.dumps("".join(traceback.format_exception_only(type(e), e)).strip())
    sys.stdout.flush()
    sys.stdout.write("\n__ORG_BABEL_EOE__ %d %d %s\n" % (req["id"], status, payload))
    sys.stdout.flush()
]]

local JS_DRIVER = [[
const vm = require("vm");
const util = require("util");
globalThis.require = require;
process.stderr.write = process.stdout.write.bind(process.stdout);
const rl = require("readline").createInterface({ input: process.stdin, terminal: false });
const queue = [];
let req = null, buf = [], busy = false, closed = false;
const encode = (v) => {
  try { const s = JSON.stringify(v === undefined ? null : v); return s === undefined ? "null" : s; }
  catch (e) { return JSON.stringify(util.inspect(v)); }
};
async function pump() {
  if (busy) return;
  busy = true;
  while (queue.length) {
    const [r, code] = queue.shift();
    let status = 0, payload = "";
    try {
      let v = vm.runInThisContext(code, { filename: "org-babel" });
      if (v && typeof v.then === "function") v = await v;
      if (r.mode === "value") payload = JSON.stringify(util.inspect(v));
      else if (r.mode === "repl" && v !== undefined) console.log(util.inspect(v));
    } catch (e) {
      status = 1;
      console.log(e && e.stack ? e.stack : String(e));
      payload = JSON.stringify(String(e && e.message !== undefined ? e.message : e));
    }
    process.stdout.write("\n__ORG_BABEL_EOE__ " + r.id + " " + status + " " + payload + "\n");
  }
  busy = false;
  if (closed) process.exit(0);
}
rl.on("line", (line) => {
  if (!req) { req = JSON.parse(line); buf = []; return; }
  if (line === "__ORG_BABEL_EOF__") { queue.push([req, buf.join("\n")]); req = null; pump(); return; }
  buf.push(line);
});
rl.on("close", () => { closed = true; if (!busy) process.exit(0); });
]]

local RB_DRIVER = [[
require "json"
$stdout.sync = true
$stderr.reopen($stdout)
while (header = $stdin.gets)
  req = JSON.parse(header)
  code = +""
  while (line = $stdin.gets) && line.chomp != "__ORG_BABEL_EOF__"
    code << line
  end
  status, payload = 0, ""
  begin
    value = eval(code, TOPLEVEL_BINDING, "org-babel")
    if req["mode"] == "value"
      text = if (req["params"] || []).include?("pp")
        require "pp"
        value.pretty_inspect
      else
        value.class == String ? value : value.inspect
      end
      payload = JSON.generate(text)
    elsif req["mode"] == "repl"
      puts value.inspect
    end
  rescue SystemExit
    raise
  rescue Exception => e
    status = 1
    puts "#{e.class}: #{e.message}"
    payload = JSON.generate(e.message)
  end
  print "\n__ORG_BABEL_EOE__ #{req["id"]} #{status} #{payload}\n"
end
]]

local DRIVERS = {
  python = { "-u", "-c", PY_DRIVER },
  js = { "-e", JS_DRIVER },
  ruby = { "-e", RB_DRIVER },
}

--- Languages whose `family` can run in a session.
local KIND = { shell = "shell", fish = "shell", python = "driver", js = "driver", ruby = "driver", lua = "lua" }

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

local function key(fam, name)
  return fam .. ":" .. name
end

---------------------------------------------------------------------------
-- Transcript buffer
---------------------------------------------------------------------------

--- Append lines to the session transcript, above its prompt line.
function M.append(sess, lines)
  local buf = sess.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
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

--- Show `code` in the transcript as input at the session prompt.
function M.echo(sess, code)
  local out = {}
  for i, l in ipairs(vim.split(code, "\n", { plain = true })) do
    out[i] = (i == 1 and sess.prompt or string.rep(" ", #sess.prompt - 4) .. "... ") .. l
  end
  M.append(sess, out)
end

local function create_buffer(sess)
  local name = string.format("org-babel-session://%s/%s", sess.lang, sess.name)
  -- the transcript of an earlier (exited) session of the same name
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.bo[buf].buftype = "prompt"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.fn.prompt_setprompt(buf, sess.prompt)
  vim.fn.prompt_setcallback(buf, function(text)
    if vim.trim(text) == "" then
      return
    end
    M.eval(sess, text, "repl", function(res)
      local out = vim.trim(res.output or "")
      if out ~= "" then
        M.append(sess, out)
      end
      if res.error and out == "" then
        M.append(sess, res.error)
      end
    end, { echo = false })
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
-- Processes
---------------------------------------------------------------------------

local function finish(sess, id, output, status, payload)
  local req = sess.pending[id]
  sess.pending[id] = nil
  if sess.err ~= "" then
    output = output .. ((output ~= "" and not output:match("\n$")) and "\n" or "") .. sess.err
    sess.err = ""
  end
  if req and req.echo ~= false or not req then
    local shown = output:gsub("\n+$", "")
    if shown ~= "" then
      M.append(sess, shown)
    end
  end
  if not req or req.abandoned then
    return
  end
  if req.timer then
    req.timer:stop()
    req.timer:close()
  end
  local res = { output = output, status = status }
  if sess.kind == "shell" then
    res.value = status
  elseif status ~= 0 then
    local ok, msg = pcall(vim.json.decode, payload)
    res.error = ok and type(msg) == "string" and msg or (payload ~= "" and payload or "evaluation failed")
  elseif req.mode == "value" then
    local ok, v = pcall(vim.json.decode, payload, { luanil = { object = true, array = true } })
    if not ok or type(v) ~= "string" then
      v = payload
    end
    res.value = v
  end
  req.cb(res)
end

local function on_stdout(sess, data)
  sess.acc = sess.acc .. data
  while true do
    local s, e, id, status, payload = sess.acc:find("\n" .. M.EOE .. " (%d+) (%-?%d+) ?([^\n]*)\n")
    if not s then
      return
    end
    local output = sess.acc:sub(1, s - 1)
    sess.acc = sess.acc:sub(e + 1)
    finish(sess, tonumber(id), output, tonumber(status), payload)
  end
end

local function on_exit(sess, code)
  if M.sessions[sess.key] == sess then
    M.sessions[sess.key] = nil
  end
  sess.alive = false
  local leftover = vim.trim(sess.acc .. sess.err)
  sess.acc, sess.err = "", ""
  if leftover ~= "" then
    M.append(sess, leftover)
  end
  M.append(sess, string.format("[session exited with code %s]", tostring(code)))
  for id, req in pairs(sess.pending) do
    sess.pending[id] = nil
    if not req.abandoned then
      if req.timer then
        req.timer:stop()
        req.timer:close()
      end
      req.cb({ error = "session '" .. sess.name .. "' exited", output = leftover })
    end
  end
end

local leave_autocmd = false

--- Start a session.
---@param opts { lang: string, family: string, name: string, cmd: string[], cwd?: string }
local function start(opts)
  local sess = {
    key = key(opts.family, opts.name),
    lang = opts.lang,
    family = opts.family,
    name = opts.name,
    kind = KIND[opts.family],
    prompt = opts.lang .. "> ",
    pending = {},
    acc = "",
    err = "",
    alive = true,
    cwd = opts.cwd,
  }
  create_buffer(sess)
  if sess.kind == "lua" then
    sess.env = setmetatable({}, { __index = _G })
    M.sessions[sess.key] = sess
    return sess
  end
  local cmd = vim.deepcopy(opts.cmd)
  vim.list_extend(cmd, DRIVERS[opts.family] or {})
  local ok, proc = pcall(vim.system, cmd, {
    cwd = opts.cwd,
    text = true,
    stdin = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          on_stdout(sess, data)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        vim.schedule(function()
          sess.err = sess.err .. data
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      on_exit(sess, obj.code)
    end)
  end)
  if not ok then
    error("cannot start session: " .. tostring(proc))
  end
  sess.proc = proc
  if sess.kind == "shell" and opts.family ~= "fish" then
    proc:write("exec 2>&1\n")
  end
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
---@param opts { lang: string, family: string, name: string, cmd?: string[], cwd?: string }
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
--- `mode` is "value", "output" or "repl".
--- `opts.params` are the result params (python formats the value like
--- Emacs), `opts.file` the graphics file.
---@param opts? { timeout?: integer, echo?: boolean, params?: string[], file?: string }
function M.eval(sess, code, mode, cb, opts)
  opts = opts or {}
  if opts.echo ~= false then
    M.echo(sess, code)
  end
  if sess.kind == "lua" then
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
  local id = next_id
  local req = { id = id, mode = mode, cb = cb, echo = opts.echo }
  sess.pending[id] = req
  local frame
  if sess.kind == "shell" then
    local status = sess.family == "fish" and "$status" or '"$?"'
    frame = code .. "\n" .. string.format("printf '\\n%s %d %%s \\n' %s\n", M.EOE, id, status)
  else
    frame = vim.json.encode({ id = id, mode = mode, params = opts.params or {}, file = opts.file or "" })
      .. "\n"
      .. code
      .. "\n"
      .. M.EOF
      .. "\n"
  end
  local timeout = opts.timeout
  if timeout and timeout > 0 then
    req.timer = vim.uv.new_timer()
    req.timer:start(
      timeout,
      0,
      vim.schedule_wrap(function()
        if sess.pending[id] and not req.abandoned then
          req.abandoned = true
          req.timer:close()
          req.timer = nil
          cb({ error = string.format("session '%s' timed out after %d ms", sess.name, timeout), output = "" })
        end
      end)
    )
  end
  local ok, err = pcall(sess.proc.write, sess.proc, frame)
  if not ok then
    sess.pending[id] = nil
    vim.schedule(function()
      cb({ error = tostring(err), output = "" })
    end)
  end
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

--- Stop a session (a session object, or a key "family:name").
function M.kill(sess)
  if type(sess) == "string" then
    sess = M.sessions[sess]
  end
  if not sess then
    return false
  end
  if M.sessions[sess.key] == sess then
    M.sessions[sess.key] = nil
  end
  sess.alive = false
  if sess.proc then
    pcall(sess.proc.kill, sess.proc, 15)
  end
  return true
end

function M.kill_all()
  for _, sess in pairs(M.sessions) do
    M.kill(sess)
  end
end

--- Show the transcript of `sess` in a split and return its window.
function M.show(sess)
  if not sess.buf or not vim.api.nvim_buf_is_valid(sess.buf) then
    create_buffer(sess)
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
