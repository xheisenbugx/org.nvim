---@mod org.babel.lang.processing Processing sketches (ob-processing)
---
--- Evaluating a block gives HTML that runs the sketch with processing.js;
--- `:Org babel_processing_view_sketch` runs it with processing-java.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

--- `org-babel-processing-define-type`
local function define_type(data)
  local t = "int"
  local function find(row)
    for _, e in ipairs(row) do
      if lisp.is_list(e) then
        if find(e) == "String" then
          return "String"
        end
      elseif type(e) == "string" then
        return "String"
      elseif lisp.is_float(e) then
        t = "float"
      end
    end
    return t
  end
  return find(data)
end

--- `org-babel-processing-var-to-processing`
local function var_to_processing(name, val)
  if type(val) == "number" then
    return string.format("int %s=%s;", name, lisp.prin1(val))
  elseif lisp.is_float(val) then
    return string.format("float %s=%s;", name, lisp.prin1(val))
  elseif type(val) == "string" then
    return string.format('String %s="%s";', name, val)
  elseif lisp.is_list(val) then
    local t = define_type(val)
    local fmt = t == "String" and '"%s"' or "%s"
    local function row(r)
      local cells = {}
      for i, e in ipairs(r) do
        cells[i] = string.format(fmt, lisp.princ(e))
      end
      return table.concat(cells, ", ")
    end
    if not lisp.is_list(val[1]) then
      return string.format("%s[] %s={%s};", t, name, row(val))
    end
    local rows = {}
    for i, r in ipairs(val) do
      rows[i] = "{" .. row(r) .. "}"
    end
    return string.format("%s[][] %s={%s};", t, name, table.concat(rows, ","))
  end
  return ""
end

local function var_lines(vars)
  local out = {}
  for i, v in ipairs(vars) do
    out[i] = var_to_processing(v.name, v.value)
  end
  return out
end

function M.expand(body, args, vars)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, var_lines(vars))
end

function M.prepare(body, args, vars, ctx)
  local code = M.expand(body, args, vars)
  local id = "ob-" .. require("org.babel.sha1").hex(code)
  return {
    value = '<script src="'
      .. (ctx.opts.js_filename or "processing.js")
      .. '"></script>\n <script type="text/processing" data-processing-target="'
      .. id
      .. '">\n'
      .. code
      .. '\n</script> <canvas id="'
      .. id
      .. '"></canvas>',
  }
end

--- `org-babel-processing-view-sketch`: run the sketch of the block at the
--- cursor with processing-java (`cmd`), in the background.
function M.view_sketch()
  local babel = require("org.babel")
  local bufnr = vim.api.nvim_get_current_buf()
  local b = babel.at_block(bufnr, vim.api.nvim_win_get_cursor(0)[1])
  if not b or b.call or b.lang ~= "processing" then
    require("org.utils").notify("Not inside a Processing source block.")
    return
  end
  local code = table.concat(babel.expand_body(bufnr, b, b.args, "eval"), "\n")
  -- a sketch name must be a Java class name (no hyphen) and match its dir
  local name = "processing" .. string.format("%d", vim.uv.hrtime()):sub(-10)
  local dir = vim.fn.fnamemodify(vim.fn.tempname(), ":h") .. "/" .. name
  vim.fn.mkdir(dir, "p")
  local sketch = ob.write(dir .. "/" .. name .. ".pde", code)
  local o = ob.opts("processing") or {}
  local cmd = string.format(
    "%s --force --sketch=%s --output=%s --run",
    o.cmd or "processing-java",
    ob.sh(dir),
    ob.sh(dir .. "/output")
  )
  vim.system({ "sh", "-c", cmd }, { text = true }, function(res)
    if res.code ~= 0 then
      vim.schedule(function()
        babel.error_notify(res.code, (res.stdout or "") .. (res.stderr or ""))
      end)
    end
  end)
  return sketch
end

return M
