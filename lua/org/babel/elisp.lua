---@mod org.babel.elisp Emacs Lisp blocks and elisp: links in an external Emacs
---
--- Neovim has no Emacs Lisp. When an `emacs` executable is available
--- (`babel.emacs_lisp.command`), emacs-lisp blocks run in a separate
--- `emacs -Q --batch` process the way ob-emacs-lisp evaluates them: the
--- body is wrapped in `(let ((VAR 'VALUE) ...) ...)`, read and `eval`ed
--- with `:lexical`, and the value is printed with `prin1` (or `format
--- "%s"` / `"%S"` for scalar results) and read back as Babel data, so lists
--- become tables. That Emacs is not the editor: it starts from scratch for
--- every evaluation (no user configuration with `-Q`, no buffers, no state
--- kept between blocks). Without Emacs, side-effect-free code runs on the
--- small interpreter of table formulas (`org.table.elisp`).

local lisp = require("org.babel.lisp")

local M = {}

local function cfg()
  return require("org.config").opts.babel.emacs_lisp or {}
end

--- The command (argv) that runs Emacs in batch mode, or nil when there is
--- none (`babel.emacs_lisp.command` false or not executable).
function M.command()
  local c = cfg()
  local cmd = c.command
  if cmd == false then
    return nil
  end
  cmd = cmd or "emacs"
  local argv = type(cmd) == "table" and vim.deepcopy(cmd) or vim.split(cmd, "%s+", { trimempty = true })
  if not argv[1] or vim.fn.executable(argv[1]) == 0 then
    return nil
  end
  vim.list_extend(argv, c.args or { "-Q", "--batch" })
  return argv
end

--- A Lisp string literal.
local function lisp_string(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end
M.lisp_string = lisp_string

local function unq(v)
  return require("org.babel.blocks").unquote(v)
end

--- org-babel-expand-body:emacs-lisp: the variables bound around the body.
---@param body string[]|string
---@param vars { name: string, value: any }[]
function M.expand_body(body, args, vars)
  body = type(body) == "table" and table.concat(body, "\n") or body
  if not vars or #vars == 0 then
    return body .. "\n"
  end
  local bindings = {}
  for i, v in ipairs(vars) do
    bindings[i] = "(" .. v.name .. " '" .. lisp.prin1(v.value) .. ")"
  end
  return string.format(
    "(let (%s)\n%s%s%s\n)",
    table.concat(bindings, "\n      "),
    args.prologue and (unq(args.prologue) .. "\n      ") or "",
    body,
    args.epilogue and ("\n      " .. unq(args.epilogue) .. "\n") or ""
  )
end

--- The form ob-emacs-lisp evaluates: `(progn BODY)`, `(with-output-to-string
--- BODY)` for `:results output`, wrapped in `pp-to-string` for code/pp.
function M.form(body, args, vars)
  local rp = require("org.babel.results").result_params(args)
  local expanded = M.expand_body(body, args, vars)
  local form = string.format(
    args.results_spec.collection == "output" and "(with-output-to-string %s\n)" or "(progn %s\n)",
    expanded
  )
  if rp.code or rp.pp then
    form = "(pp-to-string " .. form .. ")"
  end
  return form
end

--- org-babel-emacs-lisp-lexical: `yes`/`t` is t, a Lisp list (an alist of
--- lexical bindings) is used as it is, anything else is nil.
local function lexical(args)
  local v = args.lexical and vim.trim(unq(args.lexical)) or "no"
  if v == "yes" or v == "t" then
    return "t"
  elseif v:match("^'?%(") then
    return "'" .. v:gsub("^'", "")
  end
  return "nil"
end

--- Emacs Lisp that evaluates `form` and writes the printed result to
--- `result_file` (errors are printed to stderr, exit status 1).
function M.program(form, args, result_file)
  local scalar = require("org.babel.langs").scalar_result(args)
  local rp = require("org.babel.results").result_params(args)
  local printer = "(prin1-to-string result)"
  if scalar then
    printer = (rp.scalar or rp.verbatim) and '(format "%S" result)' or '(format "%s" result)'
  end
  return table.concat({
    ";;; -*- lexical-binding: t; coding: utf-8 -*-",
    "(setq inhibit-message t print-level nil print-length nil)",
    "(condition-case err",
    "    (let ((result (eval (read " .. lisp_string(form) .. ") " .. lexical(args) .. ")))",
    "      (let ((coding-system-for-write 'utf-8))",
    "        (with-temp-file " .. lisp_string(result_file),
    "          (insert " .. printer .. "))))",
    "  (error (princ (error-message-string err) #'external-debugging-output)",
    "         (kill-emacs 1)))",
  }, "\n")
end

--- The steps for `org.babel` to run a block in Emacs.
function M.prepare(cmd, body, args, vars)
  local result_file = vim.fn.tempname()
  local script = vim.fn.tempname() .. ".el"
  local program = M.program(M.form(body, args, vars), args, result_file)
  vim.fn.writefile(vim.split(program, "\n", { plain = true }), script)
  local argv = vim.deepcopy(cmd)
  vim.list_extend(argv, { "-l", script })
  return { steps = { { cmd = argv } }, result_file = result_file, script = script }
end

--- Read what Emacs printed back as a Babel value: text for scalar results,
--- else Lisp data (a string when it does not read, e.g. `#<buffer x>`).
function M.read_result(text, args)
  if require("org.babel.langs").scalar_result(args) then
    return text
  end
  local el = require("org.table.elisp")
  local ok, v = pcall(el.read, text)
  if not ok then
    return text
  end
  return lisp.from_elisp(v)
end

--- The result of a finished run (nil when Emacs failed).
function M.convert(spec, args)
  local result
  if vim.fn.filereadable(spec.result_file) == 1 then
    local fh = io.open(spec.result_file, "rb")
    if fh then
      result = M.read_result(fh:read("*a"), args)
      fh:close()
    end
    os.remove(spec.result_file)
  end
  if spec.script then
    os.remove(spec.script)
  end
  return result
end

--- Evaluate a block without Emacs, on the interpreter of Lisp table
--- formulas. Returns { result } or { error }.
function M.run_internal(body, args, vars)
  local el = require("org.table.elisp")
  local ok, v = pcall(el.eval, M.form(body, args, vars))
  if not ok then
    return {
      error = "emacs-lisp: "
        .. tostring(v)
        .. " (no Emacs found: only the Lisp subset of table formulas is available, see babel.emacs_lisp)",
    }
  end
  if require("org.babel.langs").scalar_result(args) then
    local rp = require("org.babel.results").result_params(args)
    if type(v) == "string" and not (rp.scalar or rp.verbatim) then
      return { result = v }
    end
    return { result = (rp.scalar or rp.verbatim) and lisp.prin1(lisp.from_elisp(v)) or el.to_string(v) }
  end
  return { result = lisp.from_elisp(v) }
end

---------------------------------------------------------------------------
-- elisp: links (org-link--open-elisp)
---------------------------------------------------------------------------

--- Evaluate the sexp of an `elisp:` link in a separate Emacs (or on the
--- small interpreter without one) and return the printed value.
---@return string|nil value, string|nil err
function M.eval_link(sexp, cwd)
  local cmd = M.command()
  if not cmd then
    local el = require("org.table.elisp")
    local ok, v = pcall(el.eval, sexp)
    if not ok then
      return nil, tostring(v)
    end
    return lisp.prin1(lisp.from_elisp(v))
  end
  local result_file = vim.fn.tempname()
  local script = vim.fn.tempname() .. ".el"
  local program = table.concat({
    ";;; -*- lexical-binding: t; coding: utf-8 -*-",
    "(setq inhibit-message t)",
    "(condition-case err",
    "    (let ((result (eval (read " .. lisp_string(sexp) .. ") t)))",
    "      (let ((coding-system-for-write 'utf-8))",
    "        (with-temp-file " .. lisp_string(result_file) .. " (insert (prin1-to-string result)))))",
    "  (error (princ (error-message-string err) #'external-debugging-output)",
    "         (kill-emacs 1)))",
  }, "\n")
  vim.fn.writefile(vim.split(program, "\n", { plain = true }), script)
  local argv = vim.deepcopy(cmd)
  vim.list_extend(argv, { "-l", script })
  local ok, obj = pcall(function()
    return vim.system(argv, { cwd = cwd, text = true, timeout = require("org.config").opts.babel.timeout }):wait()
  end)
  os.remove(script)
  local value
  if vim.fn.filereadable(result_file) == 1 then
    value = table.concat(vim.fn.readfile(result_file, "b"), "\n")
    os.remove(result_file)
  end
  if not ok then
    return nil, tostring(obj)
  elseif obj.code ~= 0 or not value then
    return nil, vim.trim(obj.stderr or "") ~= "" and vim.trim(obj.stderr) or ("emacs exited with " .. obj.code)
  end
  return value
end

return M
