---@mod org.babel.lang.plantuml PlantUML blocks (ob-plantuml)

local ob = require("org.babel.ob")

local M = {}

--- `org-babel-variable-assignments:plantuml`
local function var_lines(vars)
  local out = {}
  for _, v in ipairs(vars) do
    local val = type(v.value) == "string" and v.value or require("org.babel.lisp").princ(v.value)
    out[#out + 1] = string.format("!define %s %s", v.name, (val:gsub('"', "")))
  end
  return out
end

--- The expanded body (C-c C-v v, tangling): the generic expansion with
--- `!define` lines.
function M.expand(body, args, vars)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, var_lines(vars))
end

--- `org-babel-plantuml-make-body`: @startuml ... @enduml around a body
--- that has no @startXXX.
function M.make_body(body, args, vars)
  local text = ob.body_text(body)
  local full = M.expand(body, args, vars)
  if text:sub(1, 6):lower() == "@start" then
    return full
  end
  return "@startuml\n" .. full .. "\n@enduml"
end

local TYPES = {
  png = "-tpng",
  svg = "-tsvg",
  eps = "-teps",
  pdf = "-tpdf",
  tex = "-tlatex",
  tikz = "-tlatex:nopreamble",
  vdx = "-tvdx",
  xmi = "-txmi",
  scxml = "-tscxml",
  html = "-thtml",
  txt = "-ttxt",
  utxt = "-utxt",
}

function M.prepare(body, args, vars, ctx)
  local o = ctx.opts
  local do_export = ob.rp(args).file
  local out_file
  if do_export then
    out_file = ob.unq(args.file)
    if not out_file or out_file == "" then
      error("No :file provided but :results set to file.  For plain text output, set :results to verbatim", 0)
    end
  else
    out_file = ob.temp(".txt")
  end
  local cmdline = ob.unq(args.cmdline) or ""
  local in_file = ob.temp()
  local java = ob.unq(args.java) or ""
  local parts
  if (o.exec_mode or "jar") == "plantuml" then
    parts = { o.executable_path or "plantuml" }
    vim.list_extend(parts, o.args or {})
  else
    local jar = o.jar_path or ""
    if jar == "" then
      error("`babel.languages.plantuml.jar_path' is not set", 0)
    end
    -- lint: allow expand: the jar_path option
    jar = vim.fn.expand(jar)
    if vim.fn.filereadable(jar) == 0 then
      error("Could not find plantuml.jar at " .. jar, 0)
    end
    parts = { "java", java, "-jar", ob.sh(vim.fs.normalize(vim.fn.fnamemodify(jar, ":p"))) }
    vim.list_extend(parts, o.args or {})
  end
  local ext = out_file:match("%.([^./]+)$")
  if ext and TYPES[ext] then
    parts[#parts + 1] = TYPES[ext]
  end
  vim.list_extend(parts, { "-p", cmdline, "<", ob.sh(in_file), ">", ob.sh(out_file) })
  ob.write(in_file, M.make_body(body, args, vars))
  local steps = { { cmd = table.concat(parts, " ") } }
  if ext == "svg" and o.svg_text_to_path then
    steps[2] = { cmd = string.format("inkscape %s -T -l %s", out_file, out_file) }
  end
  return {
    steps = steps,
    convert = function()
      if do_export then
        return nil
      end
      return ob.read(out_file) or ""
    end,
  }
end

return M
