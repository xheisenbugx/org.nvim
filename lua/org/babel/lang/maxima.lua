---@mod org.babel.lang.maxima Maxima blocks (ob-maxima)

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

local GRAPHICS = {
  plot = "(set_plot_option ('[gnuplot_term, %s]), set_plot_option ('[gnuplot_out_file, %s]))$",
  draw = "(load(draw), set_draw_defaults(terminal='%s,file_name=%s))$",
}

--- `org-babel-maxima-elisp-to-maxima`
local function to_maxima(v)
  if lisp.is_list(v) then
    local parts = {}
    for i, x in ipairs(v) do
      parts[i] = to_maxima(x)
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return lisp.princ(v)
end

--- The graphics file of a block, or nil (errors are ignored like Emacs).
local function graphic_file(args)
  local ok, f = pcall(ob.graphical_output_file, args)
  return ok and f or nil
end

--- The expanded body (C-c C-v v): ob-maxima has no
--- org-babel-expand-body:maxima, so the generic one without variables.
function M.expand(body, args)
  return ob.expand_generic(type(body) == "table" and body or { body }, args, {})
end

--- `org-babel-maxima-expand`: what is run.
function M.maxima_expand(body, args, vars)
  local parts = {}
  if args.prologue then
    parts[#parts + 1] = ob.unq(args.prologue)
  end
  local gfile = graphic_file(args)
  if gfile then
    local pkg = ob.unq(args["graphics-pkg"]) or "plot"
    local term = gfile:match("%.([^./]+)$") or ""
    local file = pkg == "plot" and gfile or gfile:gsub("%.[^./]*$", "")
    local i = 0
    local subs = { term, lisp.prin1(file) }
    parts[#parts + 1] = (GRAPHICS[pkg] or GRAPHICS.plot):gsub("%%s", function()
      i = i + 1
      return subs[i]
    end)
  end
  local vl = {}
  for i, v in ipairs(vars) do
    vl[i] = string.format("%s: %s$", v.name, to_maxima(v.value))
  end
  parts[#parts + 1] = table.concat(vl, "\n")
  parts[#parts + 1] = ob.body_text(body)
  if args.epilogue then
    parts[#parts + 1] = ob.unq(args.epilogue)
  end
  parts[#parts + 1] = gfile and "gnuplot_close ()$" or ""
  return table.concat(parts, "\n")
end

-- org-babel-maxima--output-filter-regexps (Vim regexps)
local FILTERS = {
  [[(linenum:0,$]],
  [[batch]],
  [[^rat: replaced .*$]],
  [[^;;; Loading #P]],
  [[^read and interpret]],
  [[\v^\(\%i-?[0-9]+\) $]],
  [[\v^Loading .+maxima-init\.mac]],
}

local function keep(line)
  if line == "" then
    return false
  end
  for _, re in ipairs(FILTERS) do
    if vim.fn.match(line, "\\c" .. re) >= 0 then
      return false
    end
  end
  return true
end

function M.prepare(body, args, vars, ctx)
  local cmdline = ob.unq(args.cmdline) or ""
  local batch = ob.unq(args.batch) or "batchload"
  if cmdline == "" or batch == "batchload" then
    cmdline = cmdline .. " --very-quiet"
  end
  local in_file = ob.temp(".max")
  ob.write(in_file, M.maxima_expand(body, args, vars))
  local cmd = string.format(
    "%s -r %s %s",
    ctx.opts.cmd or "maxima",
    ob.sh(string.format("(linenum:0, %s(%s))$", batch, lisp.prin1(in_file))),
    cmdline
  )
  return {
    steps = { { cmd = cmd } },
    convert = function(raw)
      local kept = {}
      for _, l in ipairs(vim.split(raw, "[\r\n]")) do
        if keep(l) then
          kept[#kept + 1] = l
        end
      end
      local result = table.concat(kept, "\n")
      if graphic_file(args) then
        return nil
      end
      return ob.result_cond(args, result, function(s)
        return ob.import(s)
      end)
    end,
  }
end

return M
