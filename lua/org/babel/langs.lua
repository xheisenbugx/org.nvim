---@mod org.babel.langs Per-language code preparation and execution

local M = {}

M.MARKER = "__ORG_BABEL_RESULT__"

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
  sql = "sqlite",
}

function M.family(lang)
  return FAMILY[lang] or FAMILY[(lang or ""):lower()] or "generic"
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
  c = "c",
  cpp = "cpp",
  ["c++"] = "cpp",
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
  if cfg and cfg.ext then
    return cfg.ext
  end
  return EXT[lang] or EXT[(lang or ""):lower()] or lang
end

--- Comment prefix used for tangle :comments.
function M.comment_prefix(lang)
  local fam = M.family(lang)
  if fam == "lua" or lang == "sql" or lang == "haskell" or fam == "sqlite" then
    return "-- "
  elseif fam == "js" or lang == "c" or lang == "cpp" or lang == "rust" or lang == "go" or lang == "java" then
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
    local n = tonumber(v)
    if n and v:match("^%s*[-+]?[%d.]") then
      return n
    end
    return v
  elseif type(v) == "table" then
    local out = {}
    for i, x in ipairs(v) do
      out[i] = M.normalize(x)
    end
    return out
  end
  return v
end

--- Replace "hline" rows of a table value (kept by `:hlines yes`) with `to`.
local function map_hlines(v, to)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for i, x in ipairs(v) do
    if x == "hline" then
      out[i] = to
    else
      out[i] = map_hlines(x, to)
    end
  end
  return out
end

local function json(v)
  return vim.json.encode(map_hlines(v, vim.NIL))
end

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function lua_literal(v)
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = lua_literal(x)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif type(v) == "number" then
    return tostring(v)
  end
  return string.format("%q", tostring(v))
end

local function cell(c)
  if type(c) == "number" and c == math.floor(c) and math.abs(c) < 1e15 then
    return string.format("%d", c)
  end
  return tostring(c)
end

local function is_table_value(v)
  return type(v) == "table" and (type(v[1]) == "table" or v[1] == "hline")
end

--- Text form of a value for shells (`org-babel-sh-var-to-string`): table
--- rows on lines with cells joined by `sep` (a tab), list items on lines.
local function table_to_text(v, sep)
  if type(v) ~= "table" then
    return cell(v)
  end
  local lines = {}
  if is_table_value(v) then
    for _, row in ipairs(v) do
      if type(row) == "table" then
        local cells = {}
        for i, c in ipairs(row) do
          cells[i] = cell(c)
        end
        lines[#lines + 1] = table.concat(cells, sep or "\t")
      else
        lines[#lines + 1] = tostring(row)
      end
    end
  else
    for _, x in ipairs(v) do
      lines[#lines + 1] = type(x) == "table" and table_to_text(x, sep) or cell(x)
    end
  end
  return table.concat(lines, "\n")
end
M.table_to_text = table_to_text

--- Bash: a table becomes an associative array keyed by its first column,
--- a list an indexed array (ob-shell).
local function bash_assignment(name, val, sep)
  if is_table_value(val) then
    local out = { "unset " .. name, "declare -A " .. name }
    for _, row in ipairs(val) do
      if type(row) == "table" then
        out[#out + 1] = string.format(
          "%s[%s]=%s",
          name,
          sh_quote(cell(row[1])),
          sh_quote(table_to_text(vim.list_slice(row, 2), sep))
        )
      end
    end
    return out
  elseif type(val) == "table" then
    local items = {}
    for i, x in ipairs(val) do
      items[i] = sh_quote(table_to_text(x, sep))
    end
    return { "unset " .. name, "declare -a " .. name .. "=( " .. table.concat(items, " ") .. " )" }
  end
  return { name .. "=" .. sh_quote(cell(val)) }
end

local function perl_literal(v)
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = perl_literal(x)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  elseif type(v) == "number" then
    return cell(v)
  elseif v == vim.NIL then
    return "undef"
  end
  return "'" .. tostring(v):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

local function r_literal(v)
  if type(v) == "number" then
    return cell(v)
  elseif v == vim.NIL then
    return "NA"
  end
  return string.format("%q", tostring(v))
end

--- R: a table becomes a data.frame (one vector per column), a list a vector.
local function r_value(v)
  if is_table_value(v) then
    local rows = {}
    for _, row in ipairs(v) do
      if type(row) == "table" then
        rows[#rows + 1] = row
      end
    end
    local cols = {}
    for j = 1, #(rows[1] or {}) do
      local vals = {}
      for i, row in ipairs(rows) do
        vals[i] = r_literal(row[j] == nil and vim.NIL or row[j])
      end
      cols[j] = "V" .. j .. " = c(" .. table.concat(vals, ", ") .. ")"
    end
    return "data.frame(" .. table.concat(cols, ", ") .. ", stringsAsFactors = FALSE)"
  elseif type(v) == "table" then
    local vals = {}
    for i, x in ipairs(v) do
      vals[i] = r_literal(x)
    end
    return "c(" .. table.concat(vals, ", ") .. ")"
  end
  return r_literal(v)
end

--- Variable assignment lines for a language.
---@param vars { name: string, value: any }[]
---@param args? table header args (:separator)
function M.var_lines(lang, vars, args)
  local fam = M.family(lang)
  local sep = args and args.separator and require("org.babel.blocks").unquote(args.separator)
  local out = {}
  for _, v in ipairs(vars) do
    local val = v.value
    if fam == "shell" then
      if lang == "bash" then
        vim.list_extend(out, bash_assignment(v.name, val, sep))
      else
        out[#out + 1] = v.name .. "=" .. sh_quote(table_to_text(val, sep))
      end
    elseif fam == "fish" then
      out[#out + 1] = "set " .. v.name .. " " .. sh_quote(table_to_text(val, sep))
    elseif fam == "python" then
      local s = json(val):gsub("%f[%w]null%f[%W]", "None"):gsub("%f[%w]true%f[%W]", "True"):gsub("%f[%w]false%f[%W]", "False")
      out[#out + 1] = v.name .. " = " .. s
    elseif fam == "js" then
      out[#out + 1] = "var " .. v.name .. " = " .. json(val) .. ";"
    elseif fam == "ruby" then
      out[#out + 1] = v.name .. " = " .. json(val):gsub("%f[%w]null%f[%W]", "nil")
    elseif fam == "lua" then
      out[#out + 1] = "local " .. v.name .. " = " .. lua_literal(val)
    elseif fam == "perl" then
      out[#out + 1] = "my $" .. v.name .. " = " .. perl_literal(map_hlines(val, vim.NIL)) .. ";"
    elseif fam == "r" then
      out[#out + 1] = v.name .. " <- " .. r_value(val)
    end
  end
  return out
end

--- sqlite: `$name` in the body is replaced by the value; a table is written
--- to a CSV file whose path replaces it (ob-sqlite).
function M.sqlite_substitute(body, vars)
  local out = {}
  for i, line in ipairs(body) do
    for _, v in ipairs(vars) do
      local val = v.value
      if type(val) == "table" then
        local tmp = vim.fn.tempname() .. ".csv"
        local rows = {}
        for _, row in ipairs(is_table_value(val) and val or { val }) do
          if type(row) == "table" then
            local cells = {}
            for j, c in ipairs(row) do
              local s = cell(c)
              cells[j] = s:find('[,"\n]') and ('"' .. s:gsub('"', '""') .. '"') or s
            end
            rows[#rows + 1] = table.concat(cells, ",")
          end
        end
        vim.fn.writefile(rows, tmp)
        val = tmp
      end
      line = line:gsub("%$" .. vim.pesc(v.name) .. "%f[^%w_]", (cell(val):gsub("%%", "%%%%")))
    end
    out[i] = line
  end
  return out
end

---------------------------------------------------------------------------
-- Program construction
---------------------------------------------------------------------------

local function indent_lines(lines, prefix)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l == "" and "" or prefix .. l
  end
  return out
end

--- Is the value of this shell block its exit status? Shell blocks
--- default to `:results output`; only an explicit `:results value` asks for
--- the exit status (`org-babel-shell-results-defaults-to-output`).
function M.shell_exit_status(lang, args)
  local fam = M.family(lang)
  return (fam == "shell" or fam == "fish") and args.results_spec.collection == "value" and not args.default_collection
end

--- Build the program text for an external language.
---@param lang string
---@param body string[]
---@param args table merged header args
---@param vars table resolved variables
---@return string code, boolean has_marker
function M.program(lang, body, args, vars)
  local fam = M.family(lang)
  local value_mode = args.results_spec.collection == "value"
  local lines = M.var_lines(lang, vars, args)
  if args.prologue then
    vim.list_extend(lines, vim.split(require("org.babel.blocks").unquote(args.prologue), "\\n", { plain = true }))
  end
  local marker = false
  if value_mode and fam == "python" then
    lines[#lines + 1] = "def __org_babel_main():"
    local b = indent_lines(body, "    ")
    if #b == 0 then
      b = { "    pass" }
    end
    vim.list_extend(lines, b)
    vim.list_extend(lines, {
      "__org_babel_r = __org_babel_main()",
      "import json as __org_babel_json",
      "try:",
      "    print('\\n" .. M.MARKER .. "' + __org_babel_json.dumps(__org_babel_r))",
      "except Exception:",
      "    print('\\n" .. M.MARKER .. "' + __org_babel_json.dumps(repr(__org_babel_r)))",
    })
    marker = true
  elseif value_mode and fam == "js" then
    lines[#lines + 1] = "const __org_babel_r = (function() {"
    vim.list_extend(lines, body)
    vim.list_extend(lines, {
      "})();",
      "console.log('\\n" .. M.MARKER .. "' + JSON.stringify(__org_babel_r === undefined ? null : __org_babel_r));",
    })
    marker = true
  elseif value_mode and fam == "ruby" then
    lines[#lines + 1] = "require 'json'"
    lines[#lines + 1] = "__org_babel_r = (lambda do"
    vim.list_extend(lines, body)
    vim.list_extend(lines, { "end).call", "puts \"\\n" .. M.MARKER .. "\" + JSON.generate(__org_babel_r)" })
    marker = true
  else
    vim.list_extend(lines, body)
  end
  if args.epilogue then
    vim.list_extend(lines, vim.split(require("org.babel.blocks").unquote(args.epilogue), "\\n", { plain = true }))
  end
  if M.shell_exit_status(lang, args) then
    -- an explicit `:results value` of a shell block is its exit status
    local status = fam == "fish" and "$status" or '"$?"'
    lines[#lines + 1] = string.format("printf '\\n%s%%s\\n' %s", M.MARKER, status)
    marker = true
  end
  return table.concat(lines, "\n") .. "\n", marker
end

--- Split stdout at the value marker. Returns (value|nil, printed_output).
function M.split_marker(stdout)
  local s = stdout:find(M.MARKER, 1, true)
  if not s then
    return nil, stdout
  end
  local printed = stdout:sub(1, s - 1):gsub("\n$", "")
  local payload = stdout:sub(s + #M.MARKER):gsub("%s+$", "")
  local ok, v = pcall(vim.json.decode, payload, { luanil = { object = true, array = true } })
  if not ok then
    return payload, printed
  end
  if v == nil then
    v = "None"
  end
  return v, printed
end

---------------------------------------------------------------------------
-- Lua (in-process)
---------------------------------------------------------------------------

--- Run Lua code inside Neovim. Returns { value = any, output = string, error = string|nil }.
--- `session_env` (a `:session`) keeps globals and variables between runs.
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
      session_env[v.name] = v.value
    else
      rawset(env, v.name, v.value)
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
  local ok, res = pcall(chunk)
  if ok and epilogue then
    local echunk, eerr = load(epilogue, "org-babel-epilogue", "t", env)
    if not echunk then
      ok, res = false, eerr
    else
      local eok, eres = pcall(echunk)
      if not eok then
        ok, res = false, eres
      end
    end
  end
  local output = table.concat(printed, "\n")
  if not ok then
    return { error = tostring(res), output = output }
  end
  return { value = res, output = output }
end

return M
