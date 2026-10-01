---@mod org.babel.lang.julia Julia blocks (ob-julia)
---
--- Table variables are read with CSV.jl and values written back with
--- CSV.jl and DataFrames.jl, like ob-julia. Sessions (ESS) are not
--- supported: blocks run in a new `julia` each time.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

--- `org-babel-julia-quote-csv-field`
local function quote_field(s)
  if type(s) == "string" then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return lisp.prin1(s)
end

--- `orgtbl-to-csv` of rows (hlines dropped); cells reach the :fmt function
--- as text, so all are quoted.
local function to_csv(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r ~= "hline" then
      local cells = {}
      for i, c in ipairs(lisp.is_list(r) and r or { r }) do
        cells[i] = quote_field(lisp.cell(c))
      end
      out[#out + 1] = table.concat(cells, ",")
    end
  end
  return table.concat(out, "\n")
end

--- `org-babel-julia-assign-elisp`. Emacs puts the CSV text itself in
--- `CSV.read("...")`; here it goes to a file, whose name is read.
local function assign(name, value)
  if lisp.is_list(value) then
    local rows = value
    if not lisp.is_list(value[1]) and value[1] ~= "hline" then
      rows = { value }
    end
    local text = to_csv(rows)
    local hash = require("org.utils").sha256(text):sub(1, 16)
    local file = vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/julia-" .. hash .. ".csv"
    ob.write(file, text .. "\n")
    return string.format('%s = begin\n    using CSV\n    CSV.read("%s")\nend', name, file)
  end
  return string.format("%s = %s", name, quote_field(value))
end

--- `org-babel-variable-assignments:julia`: tables get their column names back.
local function var_lines(vars, colnames)
  local out = {}
  for _, v in ipairs(vars) do
    local val = v.value
    local names = colnames and colnames[v.name]
    if names and lisp.is_list(val) then
      val = vim.list_extend({ names, "hline" }, val)
    end
    out[#out + 1] = assign(v.name, val)
  end
  return out
end

function M.expand(body, args, vars, ectx)
  local parts = {}
  if args.prologue then
    parts[#parts + 1] = ob.unq(args.prologue)
  end
  vim.list_extend(parts, var_lines(vars, ectx and ectx.colnames))
  parts[#parts + 1] = ob.body_text(body)
  if args.epilogue then
    parts[#parts + 1] = ob.unq(args.epilogue)
  end
  return table.concat(parts, "\n")
end

M.WRITE_OBJECT = [[begin
    local p_ans = %s
    local p_tmp_file = "%s"

    try
        using CSV, DataFrames

        if typeof(p_ans) <: DataFrame
           p_ans_df = p_ans
        else
            p_ans_df = DataFrame(:ans => p_ans)
        end

        CSV.write(p_tmp_file,
                  p_ans_df,
                  writeheader = %s,
                  transform = (col, val) -> something(val, missing),
                  missingstring = "nil",
                  quotestrings = false)
        p_ans
    catch e
        err_msg = "Source block evaluation failed. $e"
        CSV.write(p_tmp_file,
                  DataFrame(:ans => err_msg),
                  writeheader = false,
                  transform = (col, val) -> something(val, missing),
                  missingstring = "nil",
                  quotestrings = false)

        err_msg
    end
end]]

function M.prepare(body, args, vars, ctx)
  local rp = ob.rp(args)
  local graphics = rp.graphics and ob.graphical_output_file(args)
  local colnames = not graphics and ob.unq(args.colnames)
  local column_names_p = colnames == "yes" or (colnames and colnames ~= "no" and colnames ~= "nil")
  local full = M.expand(body, args, vars, { colnames = ctx.colnames })
  local cmd = ctx.opts.cmd or "julia"
  if args.results_spec.collection == "output" then
    return {
      steps = { { cmd = cmd, stdin = full } },
      convert = function(raw)
        return graphics and nil or raw
      end,
    }
  end
  local tmp = ob.temp()
  local subs = { "begin " .. full .. " end", tmp, column_names_p and "true" or "false" }
  local i = 0
  local code = M.WRITE_OBJECT:gsub("%%s", function()
    i = i + 1
    return subs[i]
  end)
  return {
    steps = { { cmd = cmd, stdin = code } },
    result_file = tmp,
    convert = function(raw)
      if graphics then
        return nil
      end
      local result = ob.result_cond(args, raw, function(s)
        return ob.import(s, "csv")
      end)
      if column_names_p and lisp.is_list(result) then
        result = vim.list_extend({ result[1], "hline" }, vim.list_slice(result, 2))
      end
      return result
    end,
  }
end

return M
