---@mod org.babel.lang.ocaml OCaml blocks (ob-ocaml)
---
--- Emacs sends the block to a tuareg toplevel; here a new `ocaml`
--- toplevel reads it on its input, followed by the end marker, and its
--- transcript is read like ob-ocaml reads the comint buffer: the answer to
--- the last phrase, `NAME : TYPE = VALUE`, is parsed by type.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

M.EOE_INDICATOR = '"org-babel-ocaml-eoe";;'
M.EOE_OUTPUT = "org-babel-ocaml-eoe"

--- `org-babel-ocaml-elisp-to-ocaml`
local function to_ocaml(v)
  if lisp.is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = to_ocaml(x)
    end
    return "[|" .. table.concat(parts, "; ") .. "|]"
  end
  return lisp.prin1(v)
end

local function var_lines(vars)
  local out = {}
  for i, v in ipairs(vars) do
    out[i] = string.format("let %s = %s;;", v.name, to_ocaml(v.value))
  end
  return out
end

function M.expand(body, args, vars)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, var_lines(vars))
end

--- `org-babel-ocaml-parse-output`
local function parse_output(value, typ)
  if typ == "string" then
    return ob.babel_read(value)
  elseif typ == "int" or typ == "float" then
    return tonumber(value:match("^%s*([-+]?[%d.eE+-]+)")) or 0
  elseif typ:find("list", 1, true) then
    return ob.table_or_string((value:gsub(";", ",")))
  elseif typ:find("array", 1, true) then
    return ob.table_or_string((value:gsub("; ", ","):gsub("|%]", "]"):gsub("%[|", "[")))
  end
  return value
end

--- The answer to the phrase before the end marker in a toplevel
--- transcript (the comint output split at the `# ` prompts).
function M.clean(transcript)
  local pieces = vim.split("\n" .. transcript, "\n#%s+")
  for i = #pieces, 1, -1 do
    if pieces[i]:find(M.EOE_OUTPUT, 1, true) then
      return vim.trim(pieces[i - 1] or "")
    end
  end
  return ""
end

function M.prepare(body, args, vars, ctx)
  local full = M.expand(body, args, vars)
  local input = ob.chomp(full) .. ";;\n" .. M.EOE_INDICATOR .. "\n"
  return {
    steps = { { cmd = ctx.opts.cmd or "ocaml", stdin = input } },
    convert = function(transcript)
      local raw = M.clean(transcript)
      -- "\(\(.*\n\)*\)[^:\n]+ : \([^=\n]+\) =[[:space:]]+\(\(.\|\n\)+\)$"
      local output, typ, value
      local lines = vim.split(raw, "\n", { plain = true })
      -- the leading lines are matched greedily: the last `x : t = v` line
      for i = #lines, 1, -1 do
        local t, v = lines[i]:match("^[^:\n]+ : ([^=\n]+) =%s+(.*)$")
        if t then
          output = table.concat(vim.list_slice(lines, 1, i - 1), "\n") .. (i > 1 and "\n" or "")
          typ = t
          value = table.concat(vim.list_extend({ v }, vim.list_slice(lines, i + 1)), "\n")
          break
        end
      end
      local rp = ob.rp(args)
      return ob.result_cond(args, raw, function()
        if value and typ then
          return parse_output(value, typ)
        end
        return raw
      end, function()
        if rp.verbatim then
          return raw
        elseif rp.output then
          return output
        end
        return raw
      end)
    end,
  }
end

return M
