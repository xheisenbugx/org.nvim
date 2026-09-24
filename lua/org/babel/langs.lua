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

local function json(v)
  return vim.json.encode(v)
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

local function table_to_text(v)
  if type(v) ~= "table" then
    return tostring(v)
  end
  local lines = {}
  for _, row in ipairs(v) do
    if type(row) == "table" then
      local cells = {}
      for i, c in ipairs(row) do
        cells[i] = tostring(c)
      end
      lines[#lines + 1] = table.concat(cells, "\t")
    else
      lines[#lines + 1] = tostring(row)
    end
  end
  return table.concat(lines, "\n")
end

--- Variable assignment lines for a language.
---@param vars { name: string, value: any }[]
function M.var_lines(lang, vars)
  local fam = M.family(lang)
  local out = {}
  for _, v in ipairs(vars) do
    local val = v.value
    if fam == "shell" then
      out[#out + 1] = v.name .. "=" .. sh_quote(table_to_text(val))
    elseif fam == "fish" then
      out[#out + 1] = "set " .. v.name .. " " .. sh_quote(table_to_text(val))
    elseif fam == "python" then
      local s = json(val):gsub("%f[%w]null%f[%W]", "None"):gsub("%f[%w]true%f[%W]", "True"):gsub("%f[%w]false%f[%W]", "False")
      out[#out + 1] = v.name .. " = " .. s
    elseif fam == "js" then
      out[#out + 1] = "const " .. v.name .. " = " .. json(val) .. ";"
    elseif fam == "ruby" then
      out[#out + 1] = v.name .. " = " .. json(val):gsub("%f[%w]null%f[%W]", "nil")
    elseif fam == "lua" then
      out[#out + 1] = "local " .. v.name .. " = " .. lua_literal(val)
    elseif fam == "perl" then
      out[#out + 1] = "my $" .. v.name .. " = " .. string.format("%q", table_to_text(val)) .. ";"
    elseif fam == "r" then
      out[#out + 1] = v.name .. " <- " .. (type(val) == "number" and tostring(val) or string.format("%q", table_to_text(val)))
    end
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

--- Build the program text for an external language.
---@param lang string
---@param body string[]
---@param args table merged header args
---@param vars table resolved variables
---@return string code, boolean has_marker
function M.program(lang, body, args, vars)
  local fam = M.family(lang)
  local value_mode = args.results_spec.collection == "value"
  local lines = M.var_lines(lang, vars)
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
function M.run_lua(body, args, vars)
  local printed = {}
  local function cap(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    printed[#printed + 1] = table.concat(parts, "\t")
  end
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
  }, { __index = _G })
  for _, v in ipairs(vars) do
    env[v.name] = v.value
  end
  local code = table.concat(body, "\n")
  if args.prologue then
    code = require("org.babel.blocks").unquote(args.prologue) .. "\n" .. code
  end
  local chunk = load("return " .. code, "org-babel", "t", env)
  if not chunk then
    local err
    chunk, err = load(code, "org-babel", "t", env)
    if not chunk then
      return { error = err, output = "" }
    end
  end
  local ok, res = pcall(chunk)
  local output = table.concat(printed, "\n")
  if not ok then
    return { error = tostring(res), output = output }
  end
  return { value = res, output = output }
end

return M
