---@mod org.babel.lang.lisp Common Lisp blocks (ob-lisp)
---
--- Emacs evaluates through SLIME or SLY (`org-babel-lisp-eval-fn`,
--- `swank:eval-and-grab-output`); here a Lisp program (`cmd`, default
--- `sbcl --script`) reads the wrapped body as one form, evaluates it with
--- the standard output captured and writes the output and the printed
--- values (`~{~S~^~%~}`), which are then read like ob-lisp.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

--- `org-babel-expand-body:lisp`
function M.expand(body, args, vars)
  local text
  if #vars == 0 then
    text = ob.trim(ob.body_text(body))
  else
    local binds = {}
    for i, v in ipairs(vars) do
      binds[i] = string.format("(%s (cl:quote %s))", v.name, lisp.prin1(v.value))
    end
    local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
    text = "(cl:let ("
      .. table.concat(binds, "\n      ")
      .. ")\n"
      .. (prologue and (prologue .. "\n") or "")
      .. ob.body_text(body)
      .. (epilogue and ("\n" .. epilogue .. "\n") or "")
      .. ")"
  end
  local rp = ob.rp(args)
  if rp.code or rp.pp then
    return "(cl:pprint " .. text .. ")"
  end
  return text
end

--- A Common Lisp string literal.
local function cl_string(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

--- The program that evaluates `code` like swank:eval-and-grab-output.
function M.wrapper(code, package, out_file, value_file)
  local read = "(cl:read-from-string " .. cl_string(code) .. ")"
  if package then
    read = string.format("(cl:let ((cl:*package* (cl:find-package %s))) %s)", cl_string(package:upper()), read)
  end
  return table.concat({
    "(cl:let* ((org-babel-out (cl:make-string-output-stream))",
    "          (org-babel-values (cl:let ((cl:*standard-output* org-babel-out))",
    "                              (cl:multiple-value-list (cl:eval " .. read .. ")))))",
    "  (cl:with-open-file (f " .. cl_string(out_file) .. " :direction :output :if-exists :supersede)",
    "    (cl:write-string (cl:get-output-stream-string org-babel-out) f))",
    "  (cl:with-open-file (f " .. cl_string(value_file) .. " :direction :output :if-exists :supersede)",
    '    (cl:format f "~{~S~^~%~}" org-babel-values)))',
    "",
  }, "\n")
end

--- `org-strip-quotes`
local function strip_quotes(s)
  return s:match('^"(.*)"$') or s
end

--- The text of the first Lisp form of `s` (what `read` reads).
local function first_form(s)
  local c = s:sub(1, 1)
  if c == "(" or c == '"' then
    local depth, in_str, i = 0, false, 1
    while i <= #s do
      local ch = s:sub(i, i)
      if in_str then
        if ch == "\\" then
          i = i + 1
        elseif ch == '"' then
          in_str = false
          if depth == 0 then
            return s:sub(1, i)
          end
        end
      elseif ch == '"' then
        in_str = true
      elseif ch == "(" then
        depth = depth + 1
      elseif ch == ")" then
        depth = depth - 1
        if depth == 0 then
          return s:sub(1, i)
        end
      end
      i = i + 1
    end
    return s
  end
  return s:match("^[^%s()\"]+") or s
end

--- Emacs `read` of the printed values (vectors #(...) read as lists).
local function read_value(s)
  s = s:gsub("#%(", "(")
  local t = first_form(vim.trim(s))
  local ok, v
  if t:sub(1, 1) == "(" then
    ok, v = pcall(lisp.read, "'" .. t)
  else
    ok, v = pcall(lisp.read, t, true)
  end
  if ok then
    return v
  end
  return s
end

function M.prepare(body, args, vars, ctx)
  -- :dir as written, else default-directory (with a final slash)
  local dir = ob.unq(args.dir)
  if not dir then
    dir = ctx.cwd:sub(-1) == "/" and ctx.cwd or (ctx.cwd .. "/")
  end
  local dir_fmt = ctx.opts.dir_fmt or "(cl:let ((cl:*default-pathname-defaults* #P%S\n)) %%s\n)"
  local wrapped = dir_fmt:gsub("%%%%", "\0"):gsub("%%S", function()
    return lisp.prin1(dir)
  end):gsub("%z", "%%")
  wrapped = wrapped:gsub("%%s", function()
    return M.expand(body, args, vars)
  end)
  local out_file, value_file = ob.temp(), ob.temp()
  local script = ob.write(ob.temp(".lisp"), M.wrapper(wrapped, ob.unq(args.package), out_file, value_file))
  local output = ob.rp(args).output
  return {
    steps = { { cmd = (ctx.opts.cmd or "sbcl --script") .. " " .. ob.sh(script) } },
    convert = function()
      local result = ob.read(output and out_file or value_file) or ""
      return ob.result_cond(args, result, read_value, strip_quotes)
    end,
  }
end

return M
