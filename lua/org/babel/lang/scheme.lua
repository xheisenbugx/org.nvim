---@mod org.babel.lang.scheme Scheme blocks (ob-scheme)
---
--- Emacs evaluates through Geiser. Here the implementation (`:scheme`
--- header, else `impl`, default guile) runs the code from a file: for
--- `:results output` what it prints, else the value of the last form,
--- written with `write`, like the value Geiser returns. There are no
--- sessions.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

M.COMMANDS = {
  guile = "guile --no-auto-compile -s",
  chez = "scheme --script",
  chicken = "csi -s",
  chibi = "chibi-scheme",
  gambit = "gsi",
  racket = "racket -f",
  mit = "mit-scheme --quiet --load",
}

--- `org-babel-expand-body:scheme`
function M.expand(body, args, vars)
  local text = ob.body_text(body)
  if #vars > 0 then
    local defs = {}
    for i, v in ipairs(vars) do
      defs[i] = string.format("(define %s '%s)", v.name, lisp.prin1(v.value))
    end
    text = table.concat(defs, "\n") .. "\n" .. text
  end
  local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
  return (prologue and (prologue .. "\n") or "") .. text .. (epilogue and ("\n" .. epilogue) or "")
end

--- A Scheme string literal.
local function scm_string(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

--- The program that evaluates the forms of `code_file` in turn and writes
--- the last value to `value_file`.
function M.value_wrapper(code_file, value_file)
  return table.concat({
    "(let ((port (open-input-file " .. scm_string(code_file) .. ")))",
    "  (let loop ((form (read port)) (last (if #f #f)))",
    "    (if (eof-object? form)",
    "        (let ((out (open-output-file " .. scm_string(value_file) .. ")))",
    "          (write last out)",
    "          (close-output-port out))",
    "        (let ((value (eval form (interaction-environment))))",
    "          (loop (read port) value)))))",
    "",
  }, "\n")
end

--- `org-babel-scheme--table-or-string`
local function table_or_string(s, null_to)
  local ok, raw = pcall(lisp.script_escape_raw, s)
  if not ok then
    return s
  end
  if raw == nil or lisp.is_elisp_list(raw) then
    local out = {}
    for i = 1, raw and raw.n or 0 do
      local el = raw[i]
      if el == nil or lisp.is_symbol(el, "null") then
        out[i] = null_to
      else
        out[i] = lisp.from_elisp(el)
      end
    end
    return out
  end
  return lisp.from_elisp(raw)
end

function M.prepare(body, args, vars, ctx)
  local o = ctx.opts
  local impl = ob.unq(args.scheme) or o.impl or "guile"
  local cmd = (o.commands or {})[impl] or M.COMMANDS[impl]
  if not cmd then
    error("No command for the Scheme implementation " .. impl .. " (babel.languages.scheme.commands)", 0)
  end
  local code = ob.write(ob.temp(".scm"), M.expand(body, args, vars))
  local output = args.results_spec.collection == "output"
  local value_file = ob.temp()
  local file = code
  if not output then
    file = ob.write(ob.temp(".scm"), M.value_wrapper(code, value_file))
  end
  local null_to = o.null_to
  if null_to == nil then
    null_to = "hline"
  end
  if null_to == false or null_to == "nil" then
    null_to = {}
  end
  return {
    steps = { { cmd = cmd .. " " .. ob.sh(file) } },
    convert = function(raw, failed)
      local result = raw
      if not output then
        result = ob.read(value_file)
        if not result then
          return nil
        end
      elseif result == "" then
        result = "Geiser Interpreter produced no output"
      end
      if failed and not output then
        return nil
      end
      return ob.result_cond(args, result, function(s)
        return table_or_string(s, null_to)
      end)
    end,
  }
end

return M
