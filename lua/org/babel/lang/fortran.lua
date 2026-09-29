---@mod org.babel.lang.fortran Fortran blocks (ob-fortran)

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

--- `org-babel-fortran-transform-list`
local function transform_list(v)
  if lisp.is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = transform_list(x)
    end
    return "(/" .. table.concat(parts, ", ") .. "/)"
  end
  return lisp.prin1(v)
end

--- `org-babel-fortran-var-to-fortran`
local function var_to_fortran(name, val)
  if type(val) == "number" or lisp.is_bignum(val) then
    return string.format("integer, parameter  ::  %s = %s\n", name, lisp.prin1(val))
  elseif lisp.is_float(val) then
    return string.format("real, parameter ::  %s = %s\n", name, lisp.prin1(val))
  elseif type(val) == "string" then
    return string.format("character(len=%d), parameter ::  %s = '%s'\n", vim.fn.strchars(val), name, val)
  elseif lisp.is_list(val) and #val > 0 then
    local matrix = true
    for _, r in ipairs(val) do
      if not lisp.is_list(r) then
        matrix = false
      end
    end
    if matrix then
      return string.format(
        "real, parameter :: %s(%d,%d) = transpose( reshape( %s , (/ %d, %d /) ) )\n",
        name,
        #val,
        #val[1],
        transform_list(val),
        #val[1],
        #val
      )
    end
    return string.format("real, parameter :: %s(%d) = %s\n", name, #val, transform_list(val))
  end
  error("The type of parameter " .. name .. " is not supported by ob-fortran", 0)
end

--- A header value that may be a Lisp list: its items as strings.
local function items(v)
  local r = ob.list_or_string(v)
  if r == nil then
    return {}
  elseif type(r) == "string" then
    return { r }
  end
  local out = {}
  for i, x in ipairs(r) do
    out[i] = lisp.princ(x)
  end
  return out
end

--- `org-babel-expand-body:fortran`
function M.expand(body, args, vars)
  local text = ob.body_text(body)
  local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
  local main_p = ob.unq(args.main) ~= "no"
  local inc, def = {}, {}
  for i, x in ipairs(items(args.includes)) do
    inc[i] = "#include " .. x
  end
  for i, x in ipairs(items(args.defines)) do
    def[i] = "#define " .. x
  end
  local main
  if main_p then
    local vl = {}
    for i, v in ipairs(vars) do
      vl[i] = var_to_fortran(v.name, v.value)
    end
    -- ob-fortran puts the prologue after the body too (not the epilogue)
    local pro = prologue and (prologue .. "\n") or ""
    local inner = table.concat(vl, "\n") .. pro .. text .. pro
    if vim.regex([[\c^[ \t]*program\>]]):match_str(inner) then
      if #vars > 0 then
        error("Cannot use :vars if `program' statement is present", 0)
      end
      main = inner
    else
      main = "program main\n" .. inner .. "\nend program main\n"
    end
  else
    main = (prologue and (prologue .. "\n") or "") .. text .. (epilogue and ("\n" .. epilogue .. "\n") or "")
  end
  return table.concat({ table.concat(inc, "\n"), table.concat(def, "\n"), main, "\n" }, "\n")
end

function M.prepare(body, args, vars, ctx)
  local src = ob.temp(".F90")
  local bin = ob.temp()
  ob.write(src, M.expand(body, args, vars))
  local flags = ob.list_or_string(args.flags)
  if type(flags) == "table" then
    local f = {}
    for i, x in ipairs(flags) do
      f[i] = lisp.princ(x)
    end
    flags = table.concat(f, " ")
  end
  local cmdline = ob.unq(args.cmdline)
  return {
    steps = {
      { cmd = string.format("%s -o %s %s %s", ctx.opts.cmd or "gfortran", ob.sh(bin), flags or "", ob.sh(src)) },
      { cmd = ob.sh(bin) .. (cmdline and (" " .. cmdline) or "") },
    },
    convert = function(raw)
      local results = ob.trim(ob.remove_indentation(raw))
      return ob.result_cond(args, results, function(s)
        return ob.import(s)
      end, ob.babel_read)
    end,
  }
end

return M
