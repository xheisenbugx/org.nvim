---@mod org.babel.lang.haskell Haskell blocks (ob-haskell)
---
--- `:compile yes` compiles the body with ghc and runs it. Other blocks go
--- to ghci like ob-haskell sends them to its inf-haskell session: the
--- lines of the block, then a marker, and for a value `it` is kept in
--- `__LAST_VALUE_IMPROBABLE_NAME__` and printed. Without `:session` each
--- block runs in a new ghci; with one, in that session's ghci
--- (`M.session`).

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

M.EOE = "org-babel-haskell-eoe"

--- `org-babel-haskell-var-to-haskell`
local function to_haskell(v)
  if lisp.is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = to_haskell(x)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return lisp.prin1(v)
end

local function var_lines(vars)
  local out = {}
  for i, v in ipairs(vars) do
    out[i] = string.format("let %s = %s", v.name, to_haskell(v.value))
  end
  return out
end

function M.expand(body, args, vars)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, var_lines(vars))
end

--- A header value that may be a Lisp list, joined with spaces.
local function joined(v)
  local r = ob.list_or_string(v)
  if r == nil then
    return ""
  elseif type(r) == "table" then
    local out = {}
    for i, x in ipairs(r) do
      out[i] = lisp.princ(x)
    end
    return table.concat(out, " ")
  end
  return r
end

--- `org-strip-quotes`
local strip_quotes = require("org.utils").strip_quotes

--- `org-babel-haskell-execute`: ghc, then the program.
local function compiled(body, args, ctx)
  local src, bin = ob.temp(".hs"), ob.temp()
  ob.write(src, ob.body_text(body))
  local cmdline = ob.unq(args.cmdline)
  return {
    steps = {
      {
        cmd = string.format(
          "%s -o %s %s %s %s",
          ctx.opts.compiler or "ghc",
          ob.sh(bin),
          joined(args.flags),
          ob.sh(src),
          joined(args.libs)
        ),
      },
      { cmd = ob.sh(bin) .. (cmdline and (" " .. cmdline) or "") },
    },
    convert = function(raw)
      local results = ob.trim(ob.remove_indentation(raw))
      return ob.result_cond(args, results, function(s)
        return ob.import(s)
      end, function(s)
        return ob.babel_read(s, true)
      end)
    end,
  }
end

--- The input sent to ghci.
function M.ghci_input(full, value)
  local eoe = 'putStrLn "' .. M.EOE .. '"'
  local lines = { ':set prompt-cont ""' }
  if value then
    vim.list_extend(lines, {
      "__LAST_VALUE_IMPROBABLE_NAME__=()::()",
      ob.trim(full),
      "__LAST_VALUE_IMPROBABLE_NAME__=it",
      eoe,
    })
    vim.list_extend(lines, { "__LAST_VALUE_IMPROBABLE_NAME__", eoe })
  else
    vim.list_extend(lines, { ob.trim(full), eoe })
  end
  return table.concat(lines, "\n") .. "\n"
end

--- What ghci printed before the last marker (output) or between the two
--- markers (value), prompts removed.
function M.parse(out, value)
  -- prompts ("ghci> ", "Prelude> ", "λ> ") at line starts
  local lines = {}
  for _, l in ipairs(vim.split(out, "\n", { plain = true })) do
    local n
    repeat
      l, n = l:gsub("^[%w%.%*|]*[>λ]+ ", "")
    until n == 0
    lines[#lines + 1] = vim.trim(l)
  end
  local marks = {}
  for i, l in ipairs(lines) do
    if l == M.EOE then
      marks[#marks + 1] = i
    end
  end
  if value then
    if #marks < 2 then
      return nil
    end
    local pieces = {}
    for i = marks[#marks - 1] + 1, marks[#marks] - 1 do
      if lines[i] ~= "" then
        pieces[#pieces + 1] = strip_quotes(lines[i])
      end
    end
    return table.concat(pieces, "\n")
  end
  local pieces = {}
  for i = 1, (marks[#marks] or (#lines + 1)) - 1 do
    if lines[i] ~= "" then
      pieces[#pieces + 1] = strip_quotes(lines[i])
    end
  end
  return table.concat(pieces, "\n")
end

function M.prepare(body, args, vars, ctx)
  if ob.unq(args.compile) == "yes" then
    return compiled(body, args, ctx)
  end
  local value = args.results_spec.collection == "value"
  local full = M.expand(body, args, vars)
  return {
    steps = { { cmd = ctx.opts.cmd or "ghci -v0 -ignore-dot-ghci", stdin = M.ghci_input(full, value) } },
    convert = function(out)
      local result = M.parse(out, value)
      return ob.result_cond(args, result, function(s)
        if s == nil then
          return nil
        end
        local ok, v = pcall(lisp.script_escape, s)
        return ok and v or s
      end)
    end,
  }
end

---------------------------------------------------------------------------
-- Sessions (org-babel-haskell-initiate-session)
---------------------------------------------------------------------------

local VALUE = "__LAST_VALUE_IMPROBABLE_NAME__"

--- A Haskell string literal.
local function hs_string(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function ident(l)
  return l:match("^([%l_][%w_']*)")
end

--- `name :: type`
local function is_signature(l)
  return l:match("^[%l_][%w_']*%s*::") ~= nil
end

--- An equation: a `=` that is not part of `==`, `/=`, `<=`, `>=`, `=>`.
local function is_equation(l)
  local i = 1
  while true do
    local s = l:find("=", i, true)
    if not s then
      return false
    end
    local before, after = l:sub(s - 1, s - 1), l:sub(s + 1, s + 1)
    if not before:match("[=<>/!:|&+%-*$.]") and not after:match("[=>]") then
      return true
    end
    i = s + (after == "=" and 2 or 1)
  end
end

--- The lines of `code` as ghci input: a line that starts at the first
--- column begins a new input, unless it is another equation (or the
--- signature) of the definition before; indented lines continue it.
--- Inputs of several lines are put between `:{` and `:}`. Code that
--- already uses `:{` is sent as it is.
function M.ghci_lines(code)
  local lines = vim.split(code, "\n", { plain = true })
  for _, l in ipairs(lines) do
    if l:match("^%s*:[{}]%s*$") then
      return lines
    end
  end
  local chunks, cur = {}, nil
  for _, l in ipairs(lines) do
    if l:match("^%s*$") then
      if cur then
        cur.lines[#cur.lines + 1] = l
      end
    elseif cur and l:match("^%s") then
      cur.lines[#cur.lines + 1] = l
    else
      local name = ident(l)
      local def = name ~= nil and name ~= "let" and (is_signature(l) or is_equation(l))
      if cur and cur.def and def and cur.name == name then
        cur.lines[#cur.lines + 1] = l
      else
        cur = { name = name, def = def, lines = { l } }
        chunks[#chunks + 1] = cur
      end
    end
  end
  local out = {}
  for _, c in ipairs(chunks) do
    while #c.lines > 1 and c.lines[#c.lines]:match("^%s*$") do
      c.lines[#c.lines] = nil
    end
    if #c.lines > 1 then
      out[#out + 1] = ":{"
      vim.list_extend(out, c.lines)
      out[#out + 1] = ":}"
    else
      out[#out + 1] = c.lines[1]
    end
  end
  return out
end

--- `:session`: one ghci per session (`*ob-haskell*` by default, like
--- ob-haskell). The block is run with `:script`: the request file prints
--- the markers with `putStrLn`, so the line typed at the prompt never
--- contains them. For a value, `it` is kept in `__LAST_VALUE_IMPROBABLE_NAME__`
--- and written with `show`, which is what ghci prints.
M.session = {
  family = "haskell",
  repl = {
    default = "ob-haskell",
    argv = function(cmd)
      return vim.deepcopy(cmd), {}
    end,
    line = function(_, _, src)
      return ":script " .. src
    end,
    src = function(sess, req)
      local session = require("org.babel.session")
      local out = { string.format('putStrLn "%s %d"', session.BOS, req.id) }
      if req.mode == "value" then
        out[#out + 1] = VALUE .. "=()::()"
      end
      vim.list_extend(out, M.ghci_lines(req.code))
      if req.mode == "value" then
        out[#out + 1] = VALUE .. "=it"
        out[#out + 1] = string.format("writeFile %s (show %s)", hs_string(sess.dir .. "/" .. req.id .. ".val"), VALUE)
      end
      out[#out + 1] = string.format('putStrLn "%s %d 0"', session.EOE, req.id)
      return table.concat(out, "\n")
    end,
  },
  command = function(_, o)
    return o.cmd or "ghci -v0 -ignore-dot-ghci"
  end,
  prepare = function(body, args, vars)
    local value = args.results_spec.collection == "value"
    return {
      code = ob.trim(M.expand(body, args, vars)),
      mode = value and "value" or "output",
      convert = function(res)
        local text
        if value then
          text = res.value and strip_quotes(vim.trim(res.value)) or nil
        else
          text = M.parse(res.output or "", false)
        end
        return ob.result_cond(args, text, function(s)
          if s == nil then
            return nil
          end
          local ok, v = pcall(lisp.script_escape, s)
          return ok and v or s
        end)
      end,
    }
  end,
  var_code = function(vars)
    return table.concat(var_lines(vars), "\n")
  end,
}

---------------------------------------------------------------------------
-- org-babel-haskell-export-to-lhs
---------------------------------------------------------------------------

--- Visit `file` (find-file): in this window, else in a split when the
--- current buffer can't be hidden.
local function open_file(file)
  if not pcall(vim.api.nvim_command, "hide edit " .. vim.fn.fnameescape(file)) then
    vim.cmd("split " .. vim.fn.fnameescape(file))
  end
end

--- Export the buffer to BASE.lhs with its Haskell blocks as \begin{code}
--- environments (and with a count, run lhs2tex on it to make BASE.tex);
--- the file is then opened. Babel header arguments and noweb are ignored.
function M.export_to_lhs(arg)
  arg = arg or (vim.v.count > 0 and vim.v.count or nil)
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    require("org.utils").error("The buffer has no file")
    return false
  end
  local base = vim.fn.fnamemodify(name, ":p:r")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local preserve = require("org.config").opts.src_preserve_indentation
  local out, i = {}, 1
  while i <= #lines do
    local l = lines[i]
    local indent, switches = l:match("^([ \t]*)#%+[bB][eE][gG][iI][nN]_[sS][rR][cC][ \t][hH][aA][sS][kK][eE][lL]+(.*)$")
    local close
    if indent then
      for j = i + 1, #lines do
        if lines[j]:match("^[ \t]*#%+[eE][nN][dD]_[sS][rR][cC]") then
          close = j
          break
        end
      end
    end
    if indent and close then
      local code = table.concat(vim.list_slice(lines, i + 1, close - 1), "\n")
      if not (preserve or switches:find("-i", 1, true)) then
        code = ob.remove_indentation(code)
      end
      local text = "#+begin_export latex\n\\begin{code}\n" .. code .. "\n\\end{code}\n#+end_export\n"
      for _, t in ipairs(vim.split(text, "\n", { plain = true })) do
        out[#out + 1] = (t ~= "" and indent or "") .. t
      end
      i = close + 1
    else
      out[#out + 1] = l
      i = i + 1
    end
  end
  local tex = require("org.export").to_string("latex", { lines = out, filename = name })
  local tl = vim.split(tex, "\n", { plain = true })
  table.insert(tl, math.min(3, #tl + 1), "%include polycode.fmt")
  tex = table.concat(tl, "\n")
  -- indented \begin{code} ... \end{code}: start them at the first column
  local s, e = tex:find("\n[ \t]+\\begin{code}")
  if s then
    local last = select(2, tex:find(".*\\end{code}"))
    if last and last > e then
      tex = tex:sub(1, s) .. ob.remove_indentation(tex:sub(s + 1, last)) .. tex:sub(last + 1)
    end
  end
  local lhs = base .. ".lhs"
  ob.write(lhs, tex)
  if not arg then
    open_file(lhs)
    return lhs
  end
  local texfile = base .. ".tex"
  local cmd = string.format("%s %s > %s", (ob.opts("haskell") or {}).lhs2tex or "lhs2tex", ob.sh(lhs), ob.sh(texfile))
  require("org.utils").notify("running " .. cmd)
  vim.system(ob.shell_argv(cmd)):wait()
  open_file(texfile)
  return texfile
end

return M
