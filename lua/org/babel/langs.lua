---@mod org.babel.langs Per-language code preparation and result conversion
---
--- Each language follows its Emacs `ob-LANG.el`: how variables are
--- assigned (`org-babel-variable-assignments:LANG`), how the program is
--- wrapped to get a value (`org-babel-execute:LANG`) and how the printed
--- value becomes Lisp data (`org-babel-LANG-table-or-string`), so results
--- are the same as in Emacs.

local lisp = require("org.babel.lisp")

local M = {}

local FAMILY = {
  sh = "shell",
  shell = "shell",
  bash = "shell",
  zsh = "shell",
  ksh = "shell",
  dash = "shell",
  fish = "fish",
  python = "python",
  python3 = "python",
  py = "python",
  js = "js",
  javascript = "js",
  node = "js",
  typescript = "js",
  ts = "js",
  ruby = "ruby",
  rb = "ruby",
  lua = "lua",
  perl = "perl",
  r = "r",
  R = "r",
  sqlite = "sqlite",
  sql = "sql",
  C = "c",
  ["C++"] = "c",
  cpp = "c",
  D = "c",
}

function M.family(lang)
  return FAMILY[lang] or FAMILY[(lang or ""):lower()] or "generic"
end

--- C variant of a language (ob-C): "c", "cpp" or "d".
function M.c_variant(lang)
  if lang == "C" then
    return "c"
  elseif lang == "D" then
    return "d"
  end
  return "cpp"
end

local EXT = {
  sh = "sh",
  shell = "sh",
  bash = "sh",
  zsh = "zsh",
  fish = "fish",
  python = "py",
  python3 = "py",
  js = "js",
  javascript = "js",
  typescript = "ts",
  ts = "ts",
  ruby = "rb",
  lua = "lua",
  perl = "pl",
  C = "c",
  c = "c",
  cpp = "cpp",
  ["C++"] = "cpp",
  ["c++"] = "cpp",
  D = "d",
  rust = "rs",
  go = "go",
  java = "java",
  ["emacs-lisp"] = "el",
  elisp = "el",
  haskell = "hs",
  sql = "sql",
  sqlite = "sql",
  yaml = "yaml",
  json = "json",
  toml = "toml",
  conf = "conf",
  html = "html",
  css = "css",
  vim = "vim",
  makefile = "mk",
  R = "R",
  r = "R",
  awk = "awk",
  php = "php",
  kotlin = "kt",
  swift = "swift",
  scala = "scala",
  nix = "nix",
  clojure = "clj",
  elixir = "ex",
  latex = "tex",
  org = "org",
  markdown = "md",
}

function M.ext(lang)
  local cfg = (require("org.config").opts.babel.languages or {})[lang]
  if type(cfg) == "table" and cfg.ext then
    return cfg.ext
  end
  return EXT[lang] or EXT[(lang or ""):lower()] or lang
end

--- Comment prefix used for tangle :comments (the language's comment-start).
function M.comment_prefix(lang)
  local fam = M.family(lang)
  if fam == "lua" or lang == "sql" or lang == "haskell" or fam == "sqlite" then
    return "-- "
  elseif fam == "js" or fam == "c" or lang == "rust" or lang == "go" or lang == "java" or lang == "c" then
    return "// "
  elseif lang == "emacs-lisp" or lang == "elisp" or lang == "clojure" then
    return ";; "
  elseif lang == "vim" then
    return '" '
  end
  return "# "
end

---------------------------------------------------------------------------
-- Variable values
---------------------------------------------------------------------------

--- Normalize a value: numeric strings become numbers (also inside tables).
function M.normalize(v)
  if type(v) == "string" then
    local n = lisp.string_to_number(v)
    if n then
      return n
    end
    return v
  elseif lisp.is_list(v) then
    local out = {}
    for i, x in ipairs(v) do
      out[i] = M.normalize(x)
    end
    return out
  end
  return v
end

local function is_list(v)
  return lisp.is_list(v)
end

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\"'\"'") .. "'"
end

--- `(if (stringp v) v (format "%S" v))`
local function echo(v)
  if type(v) == "string" then
    return v
  end
  return lisp.prin1(v)
end

local function is_table_value(v)
  return is_list(v) and (is_list(v[1]) or v[1] == "hline")
end

--- Text form of a value for shells (`org-babel-sh-var-to-string`): table
--- rows on lines with cells joined by `sep` (a tab), list items on lines.
local function table_to_text(v, sep, hline)
  if not is_list(v) then
    return echo(v)
  end
  local lines = {}
  if is_table_value(v) then
    for _, row in ipairs(v) do
      if is_list(row) then
        local cells = {}
        for i, c in ipairs(row) do
          cells[i] = echo(c)
        end
        lines[#lines + 1] = table.concat(cells, sep or "\t")
      elseif row == "hline" then
        if hline then
          lines[#lines + 1] = hline
        end
      else
        lines[#lines + 1] = echo(row)
      end
    end
  else
    for _, x in ipairs(v) do
      lines[#lines + 1] = echo(x)
    end
  end
  return table.concat(lines, "\n")
end
M.table_to_text = table_to_text

--- Bash: a table becomes an associative array keyed by its first column,
--- a list an indexed array (ob-shell).
local function bash_assignment(name, val, sep, hline)
  if is_table_value(val) then
    local out = { "unset " .. name, "declare -A " .. name }
    for _, row in ipairs(val) do
      if is_list(row) then
        out[#out + 1] = string.format(
          "%s[%s]=%s",
          name,
          sh_quote(echo(row[1])),
          sh_quote(table_to_text(vim.list_slice(row, 2), sep, hline))
        )
      end
    end
    return out
  elseif is_list(val) then
    local items = {}
    for i, x in ipairs(val) do
      items[i] = sh_quote(table_to_text(x, sep, hline))
    end
    return { "unset " .. name, "declare -a " .. name .. "=( " .. table.concat(items, " ") .. " )" }
  end
  return { name .. "=" .. sh_quote(echo(val)) }
end

--- `org-babel-python-var-to-python`
local function python_value(v)
  if is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = python_value(x)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  elseif v == "hline" then
    return "None"
  elseif type(v) == "string" and v:find("[\n\r]") then
    return '""' .. lisp.prin1(v) .. '""'
  end
  return lisp.prin1(v)
end
M.python_value = python_value

--- `org-babel-js-var-to-js`
local function js_value(v)
  if is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = js_value(x)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return (lisp.prin1(v):gsub("\n", "\\n"))
end

--- `org-babel-ruby-var-to-ruby`
local function ruby_value(v)
  if is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = ruby_value(x)
    end
    return "[" .. table.concat(parts, ", \n") .. "]"
  elseif v == "hline" then
    return "nil"
  end
  return lisp.prin1(v)
end

--- Lua value of a Babel value (in-process Lua blocks).
local function lua_value(v)
  if lisp.is_float(v) or lisp.is_bignum(v) then
    return lisp.tonumber(v)
  elseif is_list(v) then
    local out = {}
    for i, x in ipairs(v) do
      out[i] = lua_value(x)
    end
    return out
  end
  return v
end
M.lua_value = lua_value

local function lua_literal(v)
  if is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = lua_literal(x)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif type(v) == "number" or lisp.is_float(v) then
    return lisp.prin1(v)
  end
  return string.format("%q", tostring(v))
end

local function perl_literal(v)
  if is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = perl_literal(x)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  elseif type(v) == "number" or lisp.is_float(v) then
    return lisp.prin1(v)
  elseif v == "hline" then
    return "undef"
  end
  return "'" .. tostring(v):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

local function r_literal(v)
  if type(v) == "number" or lisp.is_float(v) then
    return lisp.prin1(v)
  elseif v == "hline" or v == nil then
    return "NA"
  end
  return string.format("%q", tostring(v))
end

--- R: a table becomes a data.frame (one vector per column), a list a vector.
local function r_value(v)
  if is_table_value(v) then
    local rows = {}
    for _, row in ipairs(v) do
      if is_list(row) then
        rows[#rows + 1] = row
      end
    end
    local cols = {}
    for j = 1, #(rows[1] or {}) do
      local vals = {}
      for i, row in ipairs(rows) do
        vals[i] = r_literal(row[j])
      end
      cols[j] = "V" .. j .. " = c(" .. table.concat(vals, ", ") .. ")"
    end
    return "data.frame(" .. table.concat(cols, ", ") .. ", stringsAsFactors = FALSE)"
  elseif is_list(v) then
    local vals = {}
    for i, x in ipairs(v) do
      vals[i] = r_literal(x)
    end
    return "c(" .. table.concat(vals, ", ") .. ")"
  end
  return r_literal(v)
end

---------------------------------------------------------------------------
-- C, C++ and D (ob-C)
---------------------------------------------------------------------------

local function c_base_type(v)
  if type(v) == "number" then
    return "integerp"
  elseif lisp.is_float(v) then
    return "floatp"
  elseif is_list(v) then
    local t
    for _, x in ipairs(v) do
      local bt = c_base_type(x)
      if bt == "stringp" then
        t = "stringp"
      elseif bt == "floatp" then
        if not t or t == "integerp" then
          t = "floatp"
        end
      elseif bt == "integerp" then
        t = t or "integerp"
      end
    end
    return t
  end
  return "stringp"
end

local function c_format(fmt, v)
  if fmt == "%d" then
    return lisp.prin1(v)
  elseif fmt == "%s" then
    return lisp.princ(v)
  end
  return '"' .. lisp.princ(v) .. '"'
end

--- `org-babel-C-var-to-C`
local function c_var(variant, name, val)
  local base = c_base_type(val)
  local ctype, fmt
  if base == "integerp" then
    ctype, fmt = "int", "%d"
  elseif base == "floatp" then
    ctype, fmt = "double", "%s"
  else
    ctype, fmt = variant == "d" and "string" or "const char*", '"%s"'
  end
  local suffix, data
  if is_list(val) and is_list(val[1]) then
    if variant == "d" then
      suffix = string.format("[%d][%d]", #val[1], #val)
    else
      suffix = string.format("[%d][%d]", #val, #val[1])
    end
    local rows = {}
    for i, row in ipairs(val) do
      local cells = {}
      for j, w in ipairs(is_list(row) and row or {}) do
        cells[j] = c_format(fmt, w)
      end
      rows[i] = (variant == "d" and " [" or " {") .. table.concat(cells, ",") .. (variant == "d" and "]" or "}")
    end
    data = (variant == "d" and "[\n" or "{\n") .. table.concat(rows, ",\n") .. (variant == "d" and "\n]" or "\n}")
  elseif is_list(val) then
    suffix = string.format("[%d]", #val)
    local cells = {}
    for j, w in ipairs(val) do
      cells[j] = c_format(fmt, w)
    end
    data = (variant == "d" and "[" or "{") .. table.concat(cells, ",") .. (variant == "d" and "]" or "}")
  else
    suffix, data = "", c_format(fmt, val)
  end
  if variant == "d" then
    return string.format("%s%s %s = %s;", ctype, suffix, name, data)
  end
  return string.format("%s %s%s = %s;", ctype, name, suffix, data)
end

local function c_table_sizes(name, val)
  if not is_list(val) then
    return nil
  end
  if is_list(val[1]) then
    return string.format("const int %s_rows = %d;\nconst int %s_cols = %d;", name, #val, name, #val[1])
  end
  return string.format("const int %s_cols = %d;", name, #val)
end

local C_UTILITY = [[

#ifndef _STRING_H
#include <string.h>
#endif
int get_column_num (int nbcols, const char** header, const char* column)
{
  int c;
  for (c=0; c<nbcols; c++)
    if (strcmp(header[c],column)==0)
      return c;
  return -1;
}
]]

local D_UTILITY = [[int get_column_num (string[] header, string column)
{
  foreach (c, h; header)
    if (h==column)
      return to!int(c);
  return -1;
}
]]

--- Words of a header value that may be a Lisp list (`'(a b)`) or a string.
local function words(v)
  if v == nil then
    return {}
  end
  local ok, r = pcall(lisp.read, v)
  if ok and is_list(r) then
    local out = {}
    for i, x in ipairs(r) do
      out[i] = lisp.princ(x)
    end
    return out
  end
  return vim.split(require("org.babel.blocks").unquote(v) or "", "%s+", { trimempty = true })
end
M.words = words

--- `org-babel-C-expand-C` / `-C++` / `-D`: the full program.
function M.c_expand(lang, body, args, vars, colnames)
  local variant = M.c_variant(lang)
  local blocks = require("org.babel.blocks")
  local main_p = blocks.unquote(args.main) ~= "no"
  local code = table.concat(body, "\n")
  local pro, epi = args.prologue and blocks.unquote(args.prologue), args.epilogue and blocks.unquote(args.epilogue)
  code = (pro and (pro .. "\n") or "") .. code .. (epi and ("\n" .. epi .. "\n") or "")
  local parts = {}
  if variant == "d" then
    parts[#parts + 1] = "module mmm;"
    local imports = words(args.imports)
    vim.list_extend(imports, { "std.stdio", "std.conv" })
    local imp = {}
    for i, x in ipairs(imports) do
      imp[i] = "import " .. x .. ";"
    end
    parts[#parts + 1] = table.concat(imp, "\n")
  else
    local inc = {}
    for i, x in ipairs(words(args.includes)) do
      inc[i] = x:match("^<") and ("#include " .. x) or ('#include "' .. x .. '"')
    end
    parts[#parts + 1] = table.concat(inc, "\n")
    local defs = {}
    local dw = words(args.defines)
    local k = 1
    while k <= #dw do
      defs[#defs + 1] = "#define " .. dw[k] .. (dw[k + 1] and (" " .. dw[k + 1]) or "")
      k = k + 2
    end
    parts[#parts + 1] = table.concat(defs, "\n")
    local ns = {}
    for i, x in ipairs(words(args.namespaces)) do
      ns[i] = "using namespace " .. x .. ";"
    end
    parts[#parts + 1] = table.concat(ns, "\n")
  end
  local vl, sizes = {}, {}
  for _, v in ipairs(vars) do
    vl[#vl + 1] = c_var(variant, v.name, v.value)
    local s = c_table_sizes(v.name, v.value)
    sizes[#sizes + 1] = s or ""
  end
  parts[#parts + 1] = table.concat(vl, "\n")
  parts[#parts + 1] = table.concat(sizes, "\n")
  local heads = {}
  if colnames and next(colnames) then
    parts[#parts + 1] = variant == "d" and D_UTILITY or C_UTILITY
    for _, v in ipairs(vars) do
      local names = colnames[v.name]
      if names then
        local base = c_base_type(v.value)
        local typename = base == "integerp" and "int"
          or base == "floatp" and "double"
          or (variant == "d" and "string" or "const char*")
        local quoted = {}
        for i, h in ipairs(names) do
          quoted[i] = '"' .. lisp.princ(h) .. '"'
        end
        local header_list = table.concat(quoted, ",")
        local decl, accessor
        if variant == "d" then
          decl = string.format("string[%d] %s_header = [%s];", #names, v.name, header_list)
          accessor = string.format(
            "%s %s_h (size_t row, string col) { return %s[row][get_column_num(%s_header,col)]; }",
            typename,
            v.name,
            v.name,
            v.name
          )
        else
          decl = string.format("const char* %s_header[%d] = {%s};", v.name, #names, header_list)
          accessor = string.format(
            "%s %s_h (int row, const char* col) { return %s[row][get_column_num(%d,%s_header,col)]; }",
            typename,
            v.name,
            v.name,
            #names,
            v.name
          )
        end
        heads[#heads + 1] = decl .. "\n" .. accessor
      end
    end
  else
    parts[#parts + 1] = ""
  end
  parts[#parts + 1] = table.concat(heads, "\n")
  if main_p and not code:match("^[ \t]*[intvod]+[ \t\n\r]*main[ \t]*%(.*%)") and not code:find(
    "\n[ \t]*[intvod]+[ \t\n\r]*main[ \t]*%(.*%)"
  ) then
    code = "int main() {\n" .. code .. "\nreturn 0;\n}\n"
  end
  parts[#parts + 1] = code
  return table.concat(parts, "\n") .. "\n"
end

---------------------------------------------------------------------------
-- Variable assignments
---------------------------------------------------------------------------

--- Variable assignment lines for a language
--- (org-babel-variable-assignments:LANG).
---@param vars { name: string, value: any }[]
---@param args? table header args (:separator, :hlines)
function M.var_lines(lang, vars, args)
  local fam = M.family(lang)
  local blocks = require("org.babel.blocks")
  local sep = args and args.separator and blocks.unquote(args.separator)
  local hline = args and args.hlines == "yes" and (args["hline-string"] or "hline") or nil
  local out = {}
  for _, v in ipairs(vars) do
    local val = v.value
    if fam == "shell" then
      if lang == "bash" then
        vim.list_extend(out, bash_assignment(v.name, val, sep, hline))
      else
        out[#out + 1] = v.name .. "=" .. sh_quote(table_to_text(val, sep, hline))
      end
    elseif fam == "fish" then
      out[#out + 1] = "set " .. v.name .. " " .. sh_quote(table_to_text(val, sep, hline))
    elseif fam == "python" then
      out[#out + 1] = v.name .. "=" .. python_value(val)
    elseif fam == "js" then
      out[#out + 1] = "var " .. v.name .. "=" .. js_value(val) .. ";"
    elseif fam == "ruby" then
      out[#out + 1] = v.name .. "=" .. ruby_value(val)
    elseif fam == "lua" then
      out[#out + 1] = "local " .. v.name .. " = " .. lua_literal(val)
    elseif fam == "perl" then
      out[#out + 1] = "my $" .. v.name .. " = " .. perl_literal(val) .. ";"
    elseif fam == "r" then
      out[#out + 1] = v.name .. " <- " .. r_value(val)
    elseif fam == "c" then
      out[#out + 1] = c_var(M.c_variant(lang), v.name, val)
    end
  end
  return out
end

--- `org-babel-sql-expand-vars`: `$name` in the body is replaced by the
--- value; a table is written to a CSV file whose path replaces it.
function M.sql_substitute(body, vars, sqlite)
  local text = table.concat(body, "\n")
  for _, v in ipairs(vars) do
    local val = v.value
    local rep
    if is_list(val) then
      local tmp = vim.fn.tempname()
      local rows = {}
      for _, row in ipairs(is_table_value(val) and val or { val }) do
        if is_list(row) then
          local cells = {}
          for j, c in ipairs(row) do
            local s = sqlite and lisp.cell(c) or echo(c)
            cells[j] = s:find('[,"\n]') and ('"' .. s:gsub('"', '""') .. '"') or s
          end
          rows[#rows + 1] = table.concat(cells, ",")
        end
      end
      vim.fn.writefile(rows, tmp)
      rep = tmp
    else
      rep = echo(val)
    end
    text = text:gsub("%$" .. vim.pesc(v.name), (rep:gsub("%%", "%%%%")))
  end
  return vim.split(text, "\n", { plain = true })
end

---------------------------------------------------------------------------
-- Program construction
---------------------------------------------------------------------------

--- Is the value of this shell block its exit status? Shell blocks
--- default to `:results output`; only an explicit `:results value` asks for
--- the exit status (`org-babel-shell-results-defaults-to-output`).
function M.shell_exit_status(lang, args)
  local fam = M.family(lang)
  return (fam == "shell" or fam == "fish") and args.results_spec.collection == "value" and not args.default_collection
end

local function unq(v)
  return require("org.babel.blocks").unquote(v)
end

--- `org-babel-expand-body:generic`: prologue, variables, body, epilogue.
function M.expand_generic(body, args, var_lines)
  local parts = {}
  if args.prologue then
    parts[#parts + 1] = unq(args.prologue)
  end
  vim.list_extend(parts, var_lines or {})
  parts[#parts + 1] = table.concat(body, "\n")
  if args.epilogue then
    parts[#parts + 1] = unq(args.epilogue)
  end
  return table.concat(parts, "\n")
end

--- The expanded body (org-babel-expand-src-block): what `C-c C-v v`
--- shows, what `:cache` hashes and what is tangled.
function M.expand(lang, body, args, vars, colnames)
  local fam = M.family(lang)
  if fam == "c" then
    return M.c_expand(lang, body, args, vars, colnames)
  elseif fam == "sqlite" or fam == "sql" then
    local parts = {}
    parts[#parts + 1] = args.prologue and unq(args.prologue) or ""
    parts[#parts + 1] = table.concat(M.sql_substitute(body, vars, fam == "sqlite"), "\n")
    parts[#parts + 1] = args.epilogue and unq(args.epilogue) or ""
    return table.concat(parts, "\n")
  end
  return M.expand_generic(body, args, M.var_lines(lang, vars, args))
end

--- Python's body shifted right by 4 columns, except the lines that
--- continue a multi-line string (org-babel-python--shift-right).
local function python_shift(code)
  local out = {}
  local in_str
  for _, l in ipairs(vim.split(code, "\n", { plain = true })) do
    if in_str or l:match("^%s*$") then
      out[#out + 1] = l
    else
      out[#out + 1] = "    " .. l
    end
    -- track triple-quoted strings opened or closed on this line
    local pos = 1
    while true do
      local s, _, q = l:find("([\"'][\"'][\"'])", pos)
      if not s then
        break
      end
      if not in_str then
        in_str = q
      elseif in_str == q then
        in_str = nil
      end
      pos = s + 3
    end
  end
  return table.concat(out, "\n")
end

M.PY_FORMAT_VALUE = [[
def __org_babel_python_format_value(result, result_file, result_params):
    with open(result_file, 'w') as __org_babel_python_tmpfile:
        if 'graphics' in result_params:
            result.savefig(result_file)
        elif 'pp' in result_params:
            import pprint
            __org_babel_python_tmpfile.write(pprint.pformat(result))
        elif 'list' in result_params and isinstance(result, dict):
            __org_babel_python_tmpfile.write(str(['{} :: {}'.format(k, v) for k, v in result.items()]))
        else:
            if not set(result_params).intersection(\
['scalar', 'verbatim', 'raw']):
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
            __org_babel_python_tmpfile.write(str(result))]]

local PY_GRAPHICS = "import matplotlib.pyplot\nmatplotlib.pyplot.gcf().clear()\n%s\nmatplotlib.pyplot.savefig('%s')"

--- The result params as a Python list literal.
local function py_params(args)
  local rp = require("org.babel.results").result_params(args)
  local words_ = vim.tbl_keys(rp)
  table.sort(words_)
  local parts = {}
  for i, w in ipairs(words_) do
    parts[i] = lisp.prin1(w)
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

local JS_WRAPPER = "require('process').stdout.write(require('util').inspect(function(){%s\n}()));"

local RUBY_WRAPPER = [[

results = (lambda do
%s
end).call
File.open('%s', 'w'){ |f| f.write((results.class == String) ? results : results.inspect) }
]]

local RUBY_PP_WRAPPER = [[

require 'pp'
results = (lambda do
%s
end).call
File.open('%s', 'w') do |f|
  $stdout = f
  pp results
end
]]

local function fmt(template, ...)
  local args_ = { ... }
  local i = 0
  return (template:gsub("%%s", function()
    i = i + 1
    return args_[i]
  end))
end

--- Build how to run a block with an external program. Returns a spec:
--- `{ steps = { { cmd = argv|string, stdin?, script? } }, result_file? }`.
--- A string `cmd` runs through `sh -c`.
---@param ctx { cmd: string[], ext: string, graphics_file?: string }
function M.prepare(lang, body, args, vars, ctx)
  local fam = M.family(lang)
  local rp = require("org.babel.results").result_params(args)
  local value = args.results_spec.collection == "value"
  local blocks = require("org.babel.blocks")
  local spec = { steps = {} }
  local function script(code, ext)
    local tmp = vim.fn.tempname() .. "." .. (ext or ctx.ext)
    vim.fn.writefile(vim.split(code, "\n", { plain = true }), tmp)
    return tmp
  end
  local cmdline = args.cmdline and vim.split(unq(args.cmdline), "%s+", { trimempty = true }) or {}
  if fam == "python" then
    local full = M.expand_generic(body, args, M.var_lines(lang, vars, args))
    if value and args["return"] then
      full = full .. "\nreturn " .. args["return"]
    end
    local preamble = args.preamble and (unq(args.preamble) .. "\n") or ""
    local code
    if value then
      spec.result_file = ctx.graphics_file or vim.fn.tempname()
      code = preamble
        .. M.PY_FORMAT_VALUE
        .. "\ndef main():\n"
        .. python_shift(full)
        .. "\n\n__org_babel_python_format_value(main(), '"
        .. spec.result_file
        .. "', "
        .. py_params(args)
        .. ")"
    elseif ctx.graphics_file then
      code = preamble .. fmt(PY_GRAPHICS, full, ctx.graphics_file)
    else
      code = preamble .. full
    end
    local cmd = vim.deepcopy(ctx.cmd)
    cmd[#cmd + 1] = script(code)
    vim.list_extend(cmd, cmdline)
    spec.steps[1] = { cmd = cmd }
  elseif fam == "js" then
    local full = M.expand_generic(body, args, M.var_lines(lang, vars, args))
    local code = value and fmt(JS_WRAPPER, full) or full
    local cmd = vim.deepcopy(ctx.cmd)
    cmd[#cmd + 1] = script(code)
    vim.list_extend(cmd, cmdline)
    spec.steps[1] = { cmd = cmd }
  elseif fam == "ruby" then
    local full = M.expand_generic(body, args, M.var_lines(lang, vars, args))
    local code = full
    if value then
      spec.result_file = vim.fn.tempname()
      code = fmt(rp.pp and RUBY_PP_WRAPPER or RUBY_WRAPPER, full, spec.result_file)
    end
    local cmd = vim.deepcopy(ctx.cmd)
    cmd[#cmd + 1] = script(code)
    vim.list_extend(cmd, cmdline)
    spec.steps[1] = { cmd = cmd }
  elseif fam == "shell" or fam == "fish" then
    local full = M.expand_generic(body, args, M.var_lines(lang, vars, args))
    if M.shell_exit_status(lang, args) then
      full = full .. (fam == "fish" and "\necho $status" or "\necho $?")
    end
    local shebang = args.shebang and unq(args.shebang)
    if shebang and shebang ~= "" then
      local padline = args.padline ~= "no"
      local file = script(shebang .. "\n" .. (padline and "\n" or "") .. full)
      vim.uv.fs_chmod(file, tonumber("755", 8))
      local cmd = { file }
      vim.list_extend(cmd, cmdline)
      spec.steps[1] = { cmd = cmd }
    else
      local cmd = vim.deepcopy(ctx.cmd)
      cmd[#cmd + 1] = script(vim.trim(full))
      vim.list_extend(cmd, cmdline)
      spec.steps[1] = { cmd = cmd }
    end
    spec.exit_status = M.shell_exit_status(lang, args)
  elseif fam == "sqlite" then
    local flags = {}
    local others = {}
    for _, o in ipairs({ "header", "echo", "bail", "column", "csv", "html", "line", "list" }) do
      if args[o] ~= nil then
        others[#others + 1] = "-" .. o
      end
    end
    local headers = args.colnames == "yes"
    local fmt_given = args.csv ~= nil
      or args.column ~= nil
      or args.line ~= nil
      or args.list ~= nil
      or args.html ~= nil
      or args.separator ~= nil
    flags[#flags + 1] = table.concat(ctx.cmd, " ")
    flags[#flags + 1] = headers and "-header" or "-noheader"
    flags[#flags + 1] = args.separator and ("-separator " .. args.separator) or ""
    flags[#flags + 1] = args.nullvalue and ("-nullvalue " .. args.nullvalue) or ""
    flags[#flags + 1] = table.concat(others, " ")
    flags[#flags + 1] = fmt_given and "" or "-csv"
    flags[#flags + 1] = args.readonly == "yes" and "-readonly" or ""
    flags[#flags + 1] = args.db and unq(args.db) or ""
    spec.steps[1] = { cmd = table.concat(flags, " ") .. " ", stdin = M.expand(lang, body, args, vars) .. "\n" }
    spec.sqlite = { headers = headers, csv = not fmt_given }
  elseif fam == "sql" then
    local engine = args.engine and unq(args.engine)
    if not engine or engine == "sqlite" or engine == "sqlite3" then
      -- not an Emacs engine: run the sqlite3 client (plugin extension)
      local sub = vim.deepcopy(args)
      local s = M.prepare("sqlite", body, sub, vars, vim.tbl_extend("force", ctx, { cmd = { "sqlite3" } }))
      return s
    end
    local in_file = vim.fn.tempname()
    local out_file = args["out-file"] and unq(args["out-file"]) or vim.fn.tempname()
    local colnames_p = args.colnames ~= "no"
    local function q(s)
      return vim.fn.shellescape(s)
    end
    local host, port, user = args.dbhost and unq(args.dbhost), args.dbport, args.dbuser and unq(args.dbuser)
    local password, database = args.dbpassword and unq(args.dbpassword), args.database and unq(args.database)
    local cmdl = args.cmdline and unq(args.cmdline) or ""
    local prefix = ""
    local command
    if engine == "mysql" or engine == "mariadb" then
      local db = {}
      if host then
        db[#db + 1] = "-h" .. q(host)
      end
      if port then
        db[#db + 1] = "-P" .. port
      end
      if user then
        db[#db + 1] = "-u" .. q(user)
      end
      if password then
        db[#db + 1] = "-p" .. q(password)
      end
      if database then
        db[#db + 1] = "-D" .. q(database)
      end
      command = string.format(
        "mysql %s %s %s < %s > %s",
        table.concat(db, " "),
        colnames_p and "" or "-N",
        cmdl,
        q(in_file),
        q(out_file)
      )
    elseif engine == "postgresql" or engine == "postgres" then
      local db = {}
      if host then
        db[#db + 1] = "-h" .. q(host)
      end
      if port then
        db[#db + 1] = "-p" .. port
      end
      if user then
        db[#db + 1] = "-U" .. q(user)
      end
      if database then
        db[#db + 1] = "-d" .. q(database)
      end
      command = string.format(
        '%s%s --set="ON_ERROR_STOP=1" %s -A -P footer=off -F "\t"  %s -f %s -o %s %s',
        password and ("PGPASSWORD=" .. q(password) .. " ") or "",
        "psql",
        colnames_p and "" or "-t",
        table.concat(db, " "),
        q(in_file),
        q(out_file),
        cmdl
      )
    elseif engine == "monetdb" then
      command = string.format("mclient -f tab %s < %s > %s", cmdl, q(in_file), q(out_file))
    elseif engine == "dbi" then
      command = string.format(
        "dbish --batch %s < %s | sed '%s' > %s",
        cmdl,
        q(in_file),
        "/^+/d;s/^|//;s/(NULL)/ /g;$d",
        q(out_file)
      )
      prefix = "/format partbox\n"
    elseif engine == "vertica" then
      local db = {}
      if host then
        db[#db + 1] = "-h " .. q(host)
      end
      if port then
        db[#db + 1] = "-p " .. port
      end
      if user then
        db[#db + 1] = "-U " .. q(user)
      end
      if password then
        db[#db + 1] = "-w " .. q(password)
      end
      if database then
        db[#db + 1] = "-d " .. q(database)
      end
      command = string.format("vsql %s -f %s -o %s %s", table.concat(db, " "), q(in_file), q(out_file), cmdl)
      prefix = "\\a\n"
    elseif engine == "mssql" or engine == "sqsh" then
      local db = {}
      local flag = engine == "mssql" and { "-S", "-U", "-P", "-d" } or { "-S", "-U", "-P", "-D" }
      for i, v in ipairs({ host, user, password, database }) do
        if v then
          db[#db + 1] = string.format('%s "%s"', flag[i], q(v))
        end
      end
      if engine == "mssql" then
        command = string.format(
          'sqlcmd %s -s "\t" %s -i %s -o %s',
          cmdl,
          table.concat(db, " "),
          q(in_file),
          q(out_file)
        )
      else
        command = string.format("sqsh %s %s -i %s -o %s -m csv", cmdl, table.concat(db, " "), q(in_file), q(out_file))
      end
      prefix = "SET NOCOUNT ON\n\n"
    else
      error("No support for the " .. engine .. " SQL engine", 0)
    end
    local sql = prefix .. M.expand(lang, body, args, vars) .. (engine == "sqsh" and "\ngo" or "")
    vim.fn.writefile(vim.split(sql, "\n", { plain = true }), in_file)
    spec.steps[1] = { cmd = command }
    spec.sql = { engine = engine, out_file = out_file, colnames = colnames_p }
  elseif fam == "c" then
    local variant = M.c_variant(lang)
    local src = vim.fn.tempname() .. (variant == "c" and ".c" or variant == "d" and ".d" or ".cpp")
    vim.fn.writefile(vim.split(M.c_expand(lang, body, args, vars, ctx.colnames), "\n", { plain = true }), src)
    local flags = table.concat(words(args.flags), " ")
    local libs = table.concat(words(args.libs), " ")
    local cmd = table.concat(ctx.cmd, " ")
    local extra = args.cmdline and (" " .. unq(args.cmdline)) or ""
    if variant == "d" then
      spec.steps[1] = { cmd = string.format("%s %s %s %s", cmd, flags, vim.fn.shellescape(src), extra) }
    else
      local bin = vim.fn.tempname()
      spec.steps[1] = {
        cmd = string.format("%s -o %s %s %s %s", cmd, vim.fn.shellescape(bin), flags, vim.fn.shellescape(src), libs),
      }
      spec.steps[2] = { cmd = vim.fn.shellescape(bin) .. extra }
    end
    spec.c = true
  else
    local code = M.expand_generic(body, args, M.var_lines(lang, vars, args))
    local cmd = vim.deepcopy(ctx.cmd)
    cmd[#cmd + 1] = script(code)
    vim.list_extend(cmd, cmdline)
    spec.steps[1] = { cmd = cmd }
  end
  return spec
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------

--- `org-babel-result-cond`: should the raw text be kept as a string?
function M.scalar_result(args)
  local rp = require("org.babel.results").result_params(args)
  return rp.scalar
    or rp.verbatim
    or rp.html
    or rp.code
    or rp.pp
    or rp.file
    or ((rp.output or rp.raw or rp.org) and not rp.table)
    or false
end

--- Map the elements of a raw elisp list (top level only).
local function map_top(raw, fn)
  if not lisp.is_elisp_list(raw) then
    return lisp.from_elisp(raw)
  end
  local out = {}
  for i = 1, raw.n do
    local el = raw[i]
    local mapped = fn(el)
    out[i] = mapped ~= nil and mapped or lisp.from_elisp(el)
  end
  return out
end

--- `org-babel-python-table-or-string`
function M.python_table_or_string(s)
  if s:sub(1, 1) == "{" then
    return s
  end
  local ok, raw = pcall(lisp.script_escape_raw, s)
  if not ok then
    return s
  end
  return map_top(raw, function(el)
    if lisp.is_symbol(el, "None") then
      return "hline"
    end
  end)
end

--- `org-babel-ruby-table-or-string`
function M.ruby_table_or_string(s)
  local ok, raw = pcall(lisp.script_escape_raw, s)
  if not ok then
    return s
  end
  return map_top(raw, function(el)
    if el == nil then
      return "hline"
    end
  end)
end

--- `org-babel-js-read`
function M.js_read(s)
  if s:sub(1, 1) == "[" and s:sub(-1) == "]" then
    local conv = s:gsub("'", '"'):gsub(",%s", " "):gsub("%]", ")"):gsub("%[", "(")
    local ok, v = pcall(lisp.read, "'" .. conv)
    if ok then
      return v
    end
    return s
  end
  local ok, v = pcall(lisp.read, s)
  return ok and v or s
end

--- Remove the common indentation of `s` (org-remove-indentation).
local function remove_indentation(s)
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

--- Turn what a program printed into the block's result, like its
--- `org-babel-execute:LANG` (before :colnames are put back).
---@param raw string stdout, or the value file's contents
---@param spec table the spec from `M.prepare`
function M.convert(lang, raw, args, spec)
  local fam = M.family(lang)
  local scalar = M.scalar_result(args)
  if fam == "python" then
    return scalar and raw or M.python_table_or_string(raw)
  elseif fam == "ruby" then
    return scalar and raw or M.ruby_table_or_string(raw)
  elseif fam == "js" then
    return scalar and raw or M.js_read(raw)
  elseif fam == "shell" or fam == "fish" then
    if raw == nil or raw == "" then
      return nil
    end
    if spec and spec.exit_status then
      local lines = vim.split(raw, "\n", { plain = true, trimempty = true })
      raw = lines[#lines] or ""
    end
    return scalar and raw or lisp.import_table(raw)
  elseif fam == "sqlite" then
    if scalar then
      return raw
    end
    if raw == "" then
      return ""
    end
    local rows = lisp.text_to_rows(raw, spec.sqlite.csv and "csv" or nil)
    if spec.sqlite.headers then
      table.insert(rows, 2, "hline")
    end
    if #rows == 1 and #rows[1] == 1 then
      return lisp.read(rows[1][1], true)
    end
    for i, r in ipairs(rows) do
      if r ~= "hline" then
        for j, c in ipairs(r) do
          r[j] = lisp.read(c, true)
        end
        rows[i] = r
      end
    end
    return rows
  elseif fam == "sql" then
    local lines = vim.fn.filereadable(spec.sql.out_file) == 1 and vim.fn.readfile(spec.sql.out_file) or {}
    local text = table.concat(lines, "\n")
    if scalar then
      return text .. (#lines > 0 and "\n" or "")
    end
    local engine = spec.sql.engine
    local delim = ""
    if vim.tbl_contains({ "dbi", "mysql", "postgresql", "postgres", "saphana", "sqsh", "vertica" }, engine) then
      if spec.sql.colnames and #lines > 0 then
        table.insert(lines, 2, "-")
        delim = "-"
      end
    else
      for _, l in ipairs(lines) do
        local d = l:match("^(%-+)[^-]")
        if d then
          delim = d
          break
        end
      end
      while #lines > 0 and lines[#lines] == "" do
        lines[#lines] = nil
      end
    end
    local sep = (engine == "saphana" or engine == "sqsh") and "csv" or "tab"
    local rows = lisp.text_to_rows(table.concat(lines, "\n"), sep)
    for i, r in ipairs(rows) do
      if r[1] == delim then
        rows[i] = "hline"
      end
    end
    return rows
  elseif fam == "c" then
    if raw == nil then
      return nil
    end
    raw = remove_indentation(raw)
    return scalar and raw or lisp.import_table(raw)
  end
  return raw
end

---------------------------------------------------------------------------
-- Lua (in-process)
---------------------------------------------------------------------------

--- A Lua value as a Babel value: arrays become lists, other tables
--- key/value rows (sorted by key), booleans and nil their names.
function M.from_lua(v)
  if type(v) == "table" then
    if vim.islist(v) then
      local out = {}
      for i, x in ipairs(v) do
        out[i] = M.from_lua(x)
      end
      return out
    end
    local rows = {}
    for k, x in pairs(v) do
      rows[#rows + 1] = { tostring(k), M.from_lua(x) }
    end
    table.sort(rows, function(a, b)
      return a[1] < b[1]
    end)
    return rows
  elseif v == nil or v == vim.NIL then
    return "nil"
  elseif type(v) == "boolean" then
    return tostring(v)
  elseif type(v) == "number" then
    if v ~= math.floor(v) or math.abs(v) >= 2 ^ 53 then
      return lisp.float(v)
    end
    return v
  end
  return tostring(v)
end

--- Run Lua code inside Neovim. Returns { value = any, output = string, error = string|nil }.
--- `session_env` (a `:session`) keeps globals and variables between runs.
--- Several returned values are joined with ", " like ob-lua.
function M.run_lua(body, args, vars, session_env)
  local printed = {}
  local function cap(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    printed[#printed + 1] = table.concat(parts, "\t")
  end
  local base = session_env or _G
  local env = setmetatable({
    print = cap,
    io = setmetatable({
      write = function(...)
        for i = 1, select("#", ...) do
          local s = tostring((select(i, ...)))
          if #printed == 0 then
            printed[1] = s
          else
            printed[#printed] = printed[#printed] .. s
          end
          local parts = vim.split(printed[#printed], "\n", { plain = true })
          printed[#printed] = parts[1]
          for k = 2, #parts do
            printed[#printed + 1] = parts[k]
          end
        end
      end,
    }, { __index = io }),
  }, { __index = base, __newindex = session_env })
  for _, v in ipairs(vars) do
    if session_env then
      session_env[v.name] = lua_value(v.value)
    else
      rawset(env, v.name, lua_value(v.value))
    end
  end
  local blocks = require("org.babel.blocks")
  local code = table.concat(body, "\n")
  if args.prologue then
    code = blocks.unquote(args.prologue):gsub("\\n", "\n") .. "\n" .. code
  end
  local epilogue = args.epilogue and blocks.unquote(args.epilogue):gsub("\\n", "\n")
  local chunk = not epilogue and load("return " .. code, "org-babel", "t", env)
  if not chunk then
    local err
    chunk, err = load(code, "org-babel", "t", env)
    if not chunk then
      return { error = err, output = "" }
    end
  end
  local packed = vim.F.pack_len(pcall(chunk))
  local ok = packed[1]
  local res, n = {}, packed.n - 1
  for i = 1, n do
    res[i] = packed[i + 1]
  end
  if ok and epilogue then
    local echunk, eerr = load(epilogue, "org-babel-epilogue", "t", env)
    if not echunk then
      ok, res = false, { eerr }
    else
      local eok, eres = pcall(echunk)
      if not eok then
        ok, res = false, { eres }
      end
    end
  end
  local output = table.concat(printed, "\n")
  if not ok then
    return { error = tostring(res[1]), output = output }
  end
  if n > 1 then
    local parts = {}
    for i = 1, n do
      local v = res[i]
      parts[i] = type(v) == "table" and vim.inspect(v) or tostring(v)
    end
    return { value = table.concat(parts, ", "), output = output }
  end
  if n == 0 then
    return { value = "", output = output }
  end
  return { value = res[1] == nil and vim.NIL or res[1], output = output }
end

return M
