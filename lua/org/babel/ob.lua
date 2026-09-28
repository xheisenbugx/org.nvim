---@mod org.babel.ob Languages ported from their own ob-LANG.el
---
--- Each module in `org.babel.lang` follows one Emacs `ob-LANG.el`: how the
--- body is expanded (`org-babel-expand-body:LANG`, also what C-c C-v v
--- shows and what is tangled) and how `org-babel-execute:LANG` runs it and
--- turns the output into a result. A handler is
---
---   { expand = fun(body, args, vars, lang): string,
---     prepare = fun(body, args, vars, ctx): spec }
---
--- where `spec` is `{ steps = {...}, result_file?, convert? = fun(raw,
--- failed) }` like `org.babel.langs.prepare` (steps are run by
--- `org.babel.run_steps`; a step with `fn` runs Lua), or `{ value = v }`
--- for a result that needs no program. Errors raised by `prepare` or
--- `convert` abort the evaluation without a result, like an Emacs `error`.
--- The options of a language are its `babel.languages` entry.

local lisp = require("org.babel.lisp")

local M = {}

--- Language name -> module in org.babel.lang.
M.HANDLERS = {
  plantuml = "plantuml",
  ditaa = "ditaa",
  gnuplot = "gnuplot",
  latex = "latex",
  lilypond = "lilypond",
  java = "java",
  csharp = "csharp",
  haskell = "haskell",
  clojure = "clojure",
  clojurescript = "clojure",
  lisp = "lisp",
  scheme = "scheme",
  fortran = "fortran",
  processing = "processing",
  screen = "screen",
  julia = "julia",
  groovy = "groovy",
  ocaml = "ocaml",
  maxima = "maxima",
}

--- The options of `lang` (its `babel.languages` entry), or nil when the
--- language is not enabled.
function M.opts(lang)
  local cfg = (require("org.config").opts.babel.languages or {})[lang]
  return type(cfg) == "table" and cfg or nil
end

--- The handler of `lang`, or nil (not ported, or removed from
--- `babel.languages`).
function M.get(lang)
  local name = M.HANDLERS[lang]
  if not name or not M.opts(lang) then
    return nil
  end
  return require("org.babel.lang." .. name)
end

---------------------------------------------------------------------------
-- Helpers shared by the handlers
---------------------------------------------------------------------------

--- A header argument's text (quotes removed), or nil.
function M.unq(v)
  if v == nil then
    return nil
  end
  if type(v) ~= "string" then
    return lisp.princ(v)
  end
  return require("org.babel.blocks").unquote(v)
end

--- A new temporary file name (org-babel-temp-file) ending with `ext`.
function M.temp(ext)
  return vim.fn.tempname() .. (ext or "")
end

--- Write `text` to `path` as it is.
function M.write(path, text)
  local fh = assert(io.open(path, "wb"))
  fh:write(text)
  fh:close()
  return path
end

--- Contents of `path`, or nil.
function M.read(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local s = fh:read("*a")
  fh:close()
  return s
end

--- `shell-quote-argument`.
function M.sh(s)
  return vim.fn.shellescape(s)
end

--- `org-trim`.
function M.trim(s)
  return (s:gsub("^[ \t\n\r]+", ""):gsub("[ \t\n\r]+$", ""))
end

--- `org-babel-chomp`: drop trailing newlines and spaces.
function M.chomp(s)
  return (s:gsub("[ \t\n\r]+$", ""))
end

--- `org-remove-indentation`.
function M.remove_indentation(s)
  local min
  for _, l in ipairs(vim.split(s, "\n", { plain = true })) do
    if l:match("%S") then
      local n = #l:match("^(%s*)")
      if not min or n < min then
        min = n
      end
    end
  end
  if not min or min == 0 then
    return s
  end
  local out = {}
  for i, l in ipairs(vim.split(s, "\n", { plain = true })) do
    out[i] = l:sub(min + 1)
  end
  return table.concat(out, "\n")
end

--- Result parameters of `args` as a set.
function M.rp(args)
  return require("org.babel.results").result_params(args)
end

--- `org-babel-result-cond`: keep `raw` as a string, or convert it with `fn`.
function M.result_cond(args, raw, fn)
  if require("org.babel.langs").scalar_result(args) then
    return raw
  end
  return fn(raw)
end

--- `org-babel-script-escape` whose top-level elements pass through
--- `map(el)` (a raw elisp value; return a Babel value to replace it).
function M.table_or_string(s, map)
  local ok, raw = pcall(lisp.script_escape_raw, s)
  if not ok then
    return s
  end
  if not lisp.is_elisp_list(raw) then
    return lisp.from_elisp(raw)
  end
  local out = {}
  for i = 1, raw.n do
    local el = raw[i]
    local mapped = map and map(el)
    if mapped ~= nil then
      out[i] = mapped
    else
      out[i] = lisp.from_elisp(el)
    end
  end
  return out
end

--- An option naming a Lisp symbol (`org-babel-*-null-to`): "hline" is
--- the table rule, other names stay strings.
function M.symbol_value(v)
  if v == nil or v == false then
    return {}
  end
  return v
end

--- `org-babel-import-elisp-from-file` on `text`.
function M.import(text, separator)
  return lisp.import_table(text, separator)
end

--- `org-babel-graphical-output-file`: the :file of a `graphics` result,
--- nil for other results, an error without :file.
function M.graphical_output_file(args)
  local file = M.unq(args.file)
  if file and file ~= "" then
    return M.rp(args).graphics and file or nil
  end
  if args["file-ext"] then
    error(":file-ext given but no :file generated; did you forget to name a block?", 0)
  end
  error("No :file header argument given; cannot create graphical result", 0)
end

--- The words of a header value: a Lisp list `'(a b)`, or a string split
--- on spaces.
function M.words(v)
  return require("org.babel.langs").words(v)
end

--- A header value read as Lisp when it is a list (`'("a" "b")`),
--- otherwise its text; nil when missing.
function M.list_or_string(v)
  if v == nil then
    return nil
  end
  if type(v) == "table" then
    return v
  end
  local s = M.unq(v)
  if s:match("^%s*'?%(") then
    local ok, r = pcall(lisp.read, s)
    if ok then
      return r
    end
  end
  return s
end

--- `org-babel-expand-body:generic` with the language's assignments.
function M.expand_generic(body, args, var_lines)
  return require("org.babel.langs").expand_generic(body, args, var_lines)
end

--- `default-directory` of a block of the current buffer (its :dir, else
--- the file's directory).
function M.default_directory(args)
  return require("org.babel").block_cwd(vim.api.nvim_get_current_buf(), args)
end

--- The body as one string.
function M.body_text(body)
  return type(body) == "table" and table.concat(body, "\n") or body
end

---------------------------------------------------------------------------
-- Running
---------------------------------------------------------------------------

--- Run a handler: `done({ result, error?, abort? })`.
---@param ctx { bufnr: integer, cwd: string, sync?: boolean }
function M.run(handler, lang, body, args, vars, ctx, done)
  local babel = require("org.babel")
  local utils = require("org.utils")
  ctx.lang = lang
  ctx.opts = M.opts(lang) or {}
  local ok, spec = pcall(handler.prepare, body, args, vars, ctx)
  if not ok then
    utils.error(tostring(spec))
    return done({ error = tostring(spec), abort = true })
  end
  if spec.steps == nil or #spec.steps == 0 then
    return done({ result = spec.value })
  end
  babel.run_steps(spec, ctx.cwd, ctx.sync, function(stdout, failed)
    if stdout == nil then
      return done({ error = true })
    end
    local raw = stdout
    if spec.result_file then
      raw = M.read(spec.result_file) or ""
    end
    local result = raw
    if spec.convert then
      local cok, res = pcall(spec.convert, raw, failed)
      if not cok then
        utils.error(tostring(res))
        return done({ error = tostring(res), abort = true })
      end
      result = res
    end
    done({ result = result, error = failed or nil })
  end)
end

return M
