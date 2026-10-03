---@mod org.babel.params Header argument helpers and the :cache hash
---
--- Part of org.babel: it adds its functions to that module, which it
--- requires back. Load it through `require("org.babel")`.

local blocks_mod = require("org.babel.blocks")
local langs = require("org.babel.langs")
local lisp = require("org.babel.lisp")
local utils = require("org.utils")

local M = require("org.babel")
local P = require("org.babel.internal")

---------------------------------------------------------------------------
-- Header argument helpers
---------------------------------------------------------------------------

--- Output file of a block (org-babel-generate-file-param: `:file`, or
--- NAME.`:file-ext`, below `:output-dir`), or nil.
---@param base? string directory relative paths start from (the Org file's)
function M.file_param(args, name, base)
  local file = blocks_mod.unquote(args.file)
  local dir = blocks_mod.unquote(args["output-dir"])
  local ext = blocks_mod.unquote(args["file-ext"])
  if dir and dir ~= "" then
    pcall(vim.fn.mkdir, utils.expand(dir, base or vim.fn.getcwd()), "p")
  end
  if (not file or file == "") and name and ext and ext ~= "" then
    file = name .. "." .. ext
  end
  if not file or file == "" then
    return nil
  end
  if dir and dir ~= "" and not file:match("^[/~]") then
    file = dir:gsub("/$", "") .. "/" .. file
  end
  return file
end

--- Symbolic file mode `u+x,go-w` applied to `base` (file-modes-symbolic-to-number).
local function symbolic_mode(spec, base)
  local mode = base
  local SH = { u = 6, g = 3, o = 0 }
  for clause in spec:gmatch("[^,]+") do
    local who, ops = clause:match("^([ugoa]*)(.*)$")
    if who == "" or who:find("a") then
      who = "ugo"
    end
    for op, perms in ops:gmatch("([+=-])([rwxXstugo]*)") do
      local bits = 0
      for p in perms:gmatch(".") do
        if p == "r" then
          bits = bit.bor(bits, 4)
        elseif p == "w" then
          bits = bit.bor(bits, 2)
        elseif p == "x" then
          bits = bit.bor(bits, 1)
        elseif p == "X" and bit.band(mode, tonumber("111", 8)) ~= 0 then
          bits = bit.bor(bits, 1)
        elseif SH[p] then
          bits = bit.bor(bits, bit.band(bit.rshift(mode, SH[p]), 7))
        end
      end
      for w in who:gmatch(".") do
        local sh = SH[w]
        local m = bit.lshift(bits, sh)
        if op == "+" then
          mode = bit.bor(mode, m)
        elseif op == "-" then
          mode = bit.band(mode, bit.bnot(m))
        else
          mode = bit.bor(bit.band(mode, bit.bnot(bit.lshift(7, sh))), m)
        end
      end
    end
  end
  return mode
end

--- File mode of a `:tangle-mode` / `:file-mode` value like
--- org-babel-interpret-file-mode: `(identity #o755)`, `o755`, `#o755`,
--- `rwxr-xr-x` or `u+x` (on top of `babel.tangle_default_file_mode`,
--- 644). Returns nil and a message for
--- other values (a decimal number like `755` is refused, as in Emacs).
function M.file_mode(value)
  local v = vim.trim(blocks_mod.unquote(value or "") or "")
  local default = tonumber(tostring(require("org.config").opts.babel.tangle_default_file_mode or "644"), 8)
    or tonumber("644", 8)
  local oct = v:match("^#o([0-7]+)$") or v:match("^%(identity%s+#o([0-7]+)%)$") or v:match("^o0?([0-7][0-7][0-7])$")
  if oct then
    return tonumber(oct, 8)
  end
  local n = tonumber(v)
  if n then
    return nil,
      string.format(
        "%s is not a valid file mode octal.  Did you give the decimal value %s by mistake?",
        string.format("%o", n),
        v
      )
  end
  if v:match("^[r-][w-][xs-][r-][w-][xs-][r-][w-][x-]$") then
    local function part(s)
      return (s:gsub("-", ""))
    end
    return symbolic_mode("u=" .. part(v:sub(1, 3)) .. ",g=" .. part(v:sub(4, 6)) .. ",o=" .. part(v:sub(7, 9)), 0)
  end
  if v:match("^[ugoa]*[+=-]") then
    return symbolic_mode(v, default)
  end
  if v:match("^%(") then
    local ok, r = pcall(lisp.read, v)
    if ok and type(r) == "number" then
      return r
    end
  end
  return nil, string.format("File mode %q not recognized as a valid format", v)
end

--- Write a result to its :file like org-babel-format-result: a table with
--- cells separated by `:sep` (a tab), anything else as text.
local function write_file_result(path, result, args)
  local text
  if lisp.is_list(result) then
    local sep = blocks_mod.unquote(args.sep) or "\t"
    local rows = {}
    for _, row in ipairs(result) do
      if row ~= "hline" then
        if lisp.is_list(row) then
          local cells = {}
          for j, c in ipairs(row) do
            cells[j] = type(c) == "string" and c or lisp.prin1(c)
          end
          rows[#rows + 1] = table.concat(cells, sep)
        else
          rows[#rows + 1] = type(row) == "string" and row or lisp.prin1(row)
        end
      end
    end
    text = table.concat(rows, "\n")
  else
    text = type(result) == "string" and result or lisp.prin1(result)
  end
  -- like Emacs, the directory must exist (:mkdirp is about :dir)
  if not utils.is_dir(vim.fn.fnamemodify(path, ":h")) then
    return false, "Opening output file: No such file or directory, " .. path
  end
  vim.fn.writefile(vim.split(text, "\n", { plain = true }), path, "b")
  if args["file-mode"] then
    local mode, err = M.file_mode(args["file-mode"])
    if mode then
      vim.uv.fs_chmod(path, mode)
    else
      utils.error(err)
    end
  end
end

--- Remove coderef labels `(ref:name)` from a body (org-babel--expand-body).
local function strip_coderefs(body, switches)
  local pat = blocks_mod.coderef_pattern(switches)
  local out = {}
  for i, l in ipairs(body) do
    out[i] = (l:gsub(pat, ""))
  end
  return out
end
M.strip_coderefs = strip_coderefs

--- `org-confirm-babel-evaluate`: true to ask (a function gets the
--- language and the body, like Emacs).
local function confirm_setting(lang, body)
  local ce = require("org.config").opts.babel.confirm_evaluate
  if type(ce) == "function" then
    local ok, v = pcall(ce, lang, table.concat(body or {}, "\n"))
    return not ok or (v ~= false and v ~= nil)
  end
  return ce ~= false
end

--- org-babel-check-confirm-evaluate: "no" (`:eval no|never`, or
--- `no-export|never-export` while exporting), "query" (ask) or "yes".
---@param opts? { export?: boolean, skip_confirm?: boolean }
function M.check_evaluate(args, lang, body, opts)
  opts = opts or {}
  local ev = args.eval or (args.noeval and "no")
  if ev == "no" or ev == "never" or (opts.export and (ev == "no-export" or ev == "never-export")) then
    return "no"
  end
  if ev == "query" or (opts.export and ev == "query-export") then
    return "query"
  end
  if not opts.skip_confirm and confirm_setting(lang, body) then
    return "query"
  end
  return "yes"
end

local function name_string(name)
  return name and (" (" .. name .. ") ") or " "
end

---------------------------------------------------------------------------
-- :cache hashes (org-babel-sha1-hash)
---------------------------------------------------------------------------

local HASH_SKIP = {
  vars = true,
  results_spec = true,
  results_extra = true,
  results_order = true,
  default_collection = true,
}
local HANDLING = { replace = true, silent = true, none = true, discard = true, append = true, prepend = true }

--- `(name . value)` printed like Emacs.
local function cons_str(name, value)
  if lisp.is_list(value) then
    if #value == 0 then
      return "(" .. name .. ")"
    end
    return "(" .. name .. " " .. lisp.prin1(value):sub(2)
  end
  return "(" .. name .. " . " .. lisp.prin1(value) .. ")"
end

--- The hash `:cache yes` stores in `#+RESULTS[hash]:`, computed like
--- org-babel-sha1-hash (the sorted parameters and the expanded body), so
--- hashes written by Emacs and by Neovim agree.
function M.cache_hash(lang, body, args, vars, meta)
  local entries = {}
  local function add(key, s)
    if s then
      entries[#entries + 1] = { key = key, s = s, i = #entries }
    end
  end
  for k, v in pairs(args) do
    if type(v) == "string" and not HASH_SKIP[k] and k ~= "exports" then
      local ok, val = pcall(lisp.read, v)
      if not ok then
        val = v
      end
      if v ~= "" and not (lisp.is_list(val) and #val == 0) then
        add(":" .. k, lisp.prin1(val))
      end
    end
  end
  local words = {}
  for cat, w in pairs(args.results_spec or {}) do
    if not HANDLING[w] and not (cat == "collection" and args.default_collection) then
      words[#words + 1] = w
    end
  end
  for _, w in ipairs(args.results_extra or {}) do
    if not HANDLING[w] then
      words[#words + 1] = w
    end
  end
  table.sort(words)
  add(":results", lisp.prin1(table.concat(words, " ")))
  if #words > 0 then
    add(":result-params", lisp.prin1(words))
  end
  add(":result-type", (args.results_spec or {}).collection == "output" and "output" or "value")
  local ex = vim.split(args.exports or "code", "%s+", { trimempty = true })
  table.sort(ex)
  add(":exports", lisp.prin1(table.concat(ex, " ")))
  for _, v in ipairs(vars or {}) do
    add(":var", cons_str(v.name, v.value))
  end
  for _, key in ipairs({ "colnames", "rownames" }) do
    local names = meta and meta[key]
    if names and #names > 0 then
      local parts = {}
      for i, pair in ipairs(names) do
        parts[i] = cons_str(pair[1], pair[2])
      end
      add(key == "colnames" and ":colname-names" or ":rowname-names", "(" .. table.concat(parts, " ") .. ")")
    end
  end
  table.sort(entries, function(a, b)
    if a.key ~= b.key then
      return a.key < b.key
    end
    return a.i < b.i
  end)
  local parts = {}
  for i, e in ipairs(entries) do
    parts[i] = e.s
  end
  local colnames
  if meta and meta.colnames then
    colnames = {}
    for _, pair in ipairs(meta.colnames) do
      colnames[pair[1]] = pair[2]
    end
  end
  local expanded = langs.expand(lang, body or {}, args, vars or {}, colnames)
  return require("org.babel.sha1").hex(table.concat(parts, ":") .. "-" .. expanded)
end

-- shared with the other parts of org.babel
P.write_file_result = write_file_result
P.name_string = name_string
