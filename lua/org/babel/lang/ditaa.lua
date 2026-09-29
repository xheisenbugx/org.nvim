---@mod org.babel.lang.ditaa ditaa diagrams (ob-ditaa)

local ob = require("org.babel.ob")

local M = {}

function M.expand(body, args)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, {})
end

local function ensure_jar(file)
  if vim.fn.filereadable(vim.fn.expand(file)) == 0 then
    error("(ob-ditaa) Could not find jar file " .. file, 0)
  end
  return vim.fn.expand(file)
end

function M.prepare(body, args, _, ctx)
  local o = ctx.opts
  local out_file = ob.graphical_output_file(args)
  if not out_file then
    -- Emacs builds the command with a nil file name and fails
    error("(ob-ditaa) :results graphics is needed to write the diagram", 0)
  end
  local suffix = out_file:match("%.([^./]+)$") or ""
  local legacy_eps, legacy_pdf = args.eps, args.pdf
  if legacy_eps and legacy_pdf then
    error("(ob-ditaa) Both :eps and :pdf legacy output types specified", 0)
  end
  local legacy = legacy_eps or legacy_pdf
  local eps = legacy_eps ~= nil or suffix == "eps"
  local pdf = legacy_pdf ~= nil or suffix == "pdf"
  local svg = not legacy and suffix == "svg"
  local ditaa_options = ob.unq(args.cmdline)
  local java_options = ob.unq(args.java)
  local use_eps_jar = eps or pdf
  local exec_form
  if (o.exec_mode or "jar") == "jar" or use_eps_jar then
    local jar = use_eps_jar and (o.eps_jar_path or (vim.fn.fnamemodify(o.jar_path or "", ":h") .. "/DitaaEps.jar"))
      or (o.jar_path or "")
    exec_form = (o.java_exec or "java")
      .. (java_options and (" " .. java_options) or "")
      .. " -jar "
      .. ob.sh(ensure_jar(jar))
  else
    exec_form = o.exec or "ditaa"
  end
  local in_file = ob.temp()
  local ditaa_out = ob.sh(pdf and (in_file .. ".eps") or out_file)
  local cmd = exec_form
    .. (ditaa_options and (" " .. ditaa_options) or "")
    .. (svg and " --svg" or "")
    .. " -e utf-8 "
    .. in_file
    .. " "
    .. ditaa_out
  ob.write(in_file, ob.body_text(body))
  local steps = { { cmd = cmd } }
  if pdf then
    steps[2] = { cmd = "epstopdf " .. ditaa_out .. " -o=" .. ob.sh(out_file) }
  end
  return {
    steps = steps,
    convert = function()
      return nil
    end,
  }
end

return M
