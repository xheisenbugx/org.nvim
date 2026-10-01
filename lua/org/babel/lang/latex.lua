---@mod org.babel.lang.latex LaTeX blocks (ob-latex)
---
--- Without :file the body is the result (`:results latex`). With :file it
--- is compiled: .png like LaTeX previews (the `process_alist` png process,
--- latex + dvipng), .svg through PDF and `pdf_svg_process`, .pdf (and any
--- image with :imagemagick) with the LaTeX export's compiler, .html with
--- htlatex, .tikz written as it is.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

local function opts()
  return ob.opts("latex") or {}
end

--- An option that is a string or a function of the header arguments.
local function call_opt(v, args, default)
  if type(v) == "function" then
    return v(args)
  end
  return v or default
end

--- `org-babel-expand-body:latex`: variable names replaced by the values,
--- :prologue and :epilogue around.
function M.expand(body, args, vars)
  local text = ob.body_text(body)
  for _, v in ipairs(vars) do
    local val = type(v.value) == "string" and v.value or lisp.prin1(v.value)
    text = text:gsub(vim.pesc(v.name), (val:gsub("%%", "%%%%")))
  end
  local prologue, epilogue = ob.unq(args.prologue), ob.unq(args.epilogue)
  return ob.trim((prologue and (prologue .. "\n") or "") .. text .. (epilogue and ("\n" .. epilogue .. "\n") or ""))
end

--- `org-babel-latex-process-alist`: the png process.
function M.png_process()
  local p = (opts().process_alist or {}).png
  if p then
    return p
  end
  local latexmk = vim.fn.executable("latexmk") == 1 and vim.fn.executable("perl") == 1
  return {
    programs = { "latex", "dvipng" },
    message = "you need to install the programs: latex and dvipng.",
    image_input_type = "dvi",
    image_output_type = "png",
    image_size_adjust = { 1.0, 1.0 },
    latex_compiler = latexmk and { "latexmk -f -pdf -latex -interaction=nonstopmode -output-directory=%o %f" } or {
      "latex -interaction nonstopmode -output-directory %o %f",
      "latex -interaction nonstopmode -output-directory %o %f",
      "latex -interaction nonstopmode -output-directory %o %f",
    },
    image_converter = { "dvipng -D %D -T tight -o %O %f" },
    transparent_image_converter = { "dvipng -D %D -T tight -bg Transparent -o %O %f" },
  }
end

--- A header value that is a Lisp list of strings (or one string).
local function strings(v)
  local r = ob.list_or_string(v)
  if r == nil then
    return nil
  elseif type(r) == "string" then
    return { r }
  end
  local out = {}
  for i, x in ipairs(r) do
    out[i] = lisp.princ(x)
  end
  return out
end

--- `:packages '(("opt" "name") ...)` as export packages.
local function packages(v)
  local r = ob.list_or_string(v)
  local out = {}
  if type(r) == "table" then
    for _, p in ipairs(r) do
      if lisp.is_list(p) then
        out[#out + 1] = { lisp.princ(p[1] or ""), lisp.princ(p[2] or "") }
      else
        out[#out + 1] = lisp.princ(p)
      end
    end
  end
  return out
end

local function export_cfg()
  return (require("org.config").opts.export or {}).latex or {}
end

--- `org-latex--remove-packages` for the export's compiler.
local function remove_packages(pkgs)
  local compiler = (export_cfg().compiler or "pdflatex"):lower()
  local out = {}
  for _, p in ipairs(pkgs) do
    local keep = true
    if type(p) == "table" and p[4] then
      keep = false
      for _, c in ipairs(p[4]) do
        if c:lower() == compiler then
          keep = true
        end
      end
    end
    if keep then
      out[#out + 1] = p
    end
  end
  return out
end

--- org-format-latex-header
local function format_latex_header()
  local lp = (require("org.config").opts.ui or {}).latex_preview or {}
  return lp.header or require("org.ui.images").DEFAULT_HEADER
end

--- `org-latex-make-preamble` of the snippet header (what LaTeX previews
--- use), with extra packages.
local function snippet_preamble(bufnr, template, extra_packages)
  local ok, res = pcall(function()
    local ox = require("org.export.ox")
    local latex = require("org.export.latex")
    local name = vim.api.nvim_buf_get_name(bufnr)
    local dir = name ~= "" and vim.fn.fnamemodify(name, ":p:h") or vim.fn.getcwd()
    local keywords =
      ox.collect_keywords(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), dir, nil, nil, name ~= "" and name or nil)
    local info = ox.environment({
      keywords = keywords,
      backend = latex.backend,
      parse_secondary = function(s)
        return s
      end,
    })
    info.latex_packages = vim.list_extend(vim.deepcopy(extra_packages), info.latex_packages or {})
    return latex.make_preamble(info, template, true)
  end)
  if ok and type(res) == "string" then
    return res
  end
  return (template:gsub("%[N?O?%-?DEFAULT%-PACKAGES%]", ""):gsub("%[N?O?%-?PACKAGES%]", ""))
end

local function hl(group, key)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  return ok and h[key] or nil
end

--- `org-latex-color-format`: "r,g,b" of a color.
local function color(c)
  local n = type(c) == "number" and c or nil
  if type(c) == "string" then
    n = c:match("^#%x%x%x%x%x%x$") and tonumber(c:sub(2), 16) or vim.api.nvim_get_color_by_name(c)
  end
  if not n or n == -1 then
    return nil
  end
  local function f(x)
    return (string.format("%.3f", x / 255):gsub("0+$", ""):gsub("%.$", ""))
  end
  return string.format("%s,%s,%s", f(math.floor(n / 65536) % 256), f(math.floor(n / 256) % 256), f(n % 256))
end

--- A shell command of a process with its %-sequences replaced
--- (`org-compile-file` / format-spec).
local function substitute(cmd, spec)
  return (cmd:gsub("%%(%a)", function(c)
    return spec[c] or ("%" .. c)
  end))
end

--- `org-compile-file`: run `process` (a list of commands) on `source`;
--- the output is SOURCE-BASE.EXT next to it. Errors when not produced.
function M.compile_file(source, process, ext, err_msg, cwd, extra)
  local base = vim.fn.fnamemodify(source, ":t:r")
  local out_dir = vim.fn.fnamemodify(source, ":h") .. "/"
  local output = out_dir .. base .. "." .. ext
  local before = vim.fn.getftime(output)
  local spec = vim.tbl_extend("force", extra or {}, {
    b = ob.sh(base),
    f = ob.sh(source),
    F = ob.sh(vim.fn.resolve(source)),
    o = ob.sh(out_dir),
    O = ob.sh(output),
  })
  local log = {}
  for _, c in ipairs(process) do
    local res = vim.system({ "sh", "-c", substitute(c, spec) }, { cwd = cwd, text = true }):wait()
    log[#log + 1] = (res.stdout or "") .. (res.stderr or "")
  end
  if vim.fn.filereadable(output) == 0 or vim.fn.getftime(output) < before then
    local b = vim.fn.bufnr("*Org Babel LaTeX Output*")
    if b == -1 then
      b = vim.api.nvim_create_buf(false, true)
      pcall(vim.api.nvim_buf_set_name, b, "*Org Babel LaTeX Output*")
    end
    vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(table.concat(log, "\n"), "\n", { plain = true }))
    error(string.format("File %s wasn't produced%s", output, err_msg and (".  " .. err_msg) or ""), 0)
  end
  return output
end

--- `org-create-formula-image` for a block (process png).
local function formula_image(body, out_file, headers, pkgs, in_buffer, bufnr, cwd)
  local p = M.png_process()
  for _, prog in ipairs(p.programs or {}) do
    if vim.fn.executable(prog) == 0 then
      error(string.format("Can't find `%s' (%s)", prog, p.message or ""), 0)
    end
  end
  local template = format_latex_header() .. "\n" .. table.concat(headers, "\n")
  local header = p.latex_header or snippet_preamble(bufnr, template, pkgs)
  local lp = (require("org.config").opts.ui or {}).latex_preview or {}
  local adjust = p.image_size_adjust or { 1.0, 1.0 }
  local scale = (in_buffer and adjust[1] or adjust[2]) * ((in_buffer and lp.scale) or 1.0)
  local dpi = scale * 140.0
  local fg, bg
  if in_buffer then
    fg = (lp.foreground or "default") == "default" and color(hl("Normal", "fg")) or color(lp.foreground)
    local b = lp.background or "default"
    if b ~= "Transparent" then
      bg = b == "default" and color(hl("Normal", "bg")) or color(b)
    end
  end
  fg = fg or "0,0,0"
  local converter = (not bg and p.transparent_image_converter) or p.image_converter
  local text = body:sub(-1) == "\n" and (body:sub(1, -2) .. "%") or (body .. "%")
  local texbase = vim.fn.tempname() .. "orgtex"
  local texfile = texbase .. ".tex"
  ob.write(
    texfile,
    header
      .. "\n\\begin{document}\n"
      .. "\\definecolor{fg}{rgb}{"
      .. fg
      .. "}%\n"
      .. (bg and ("\\definecolor{bg}{rgb}{" .. bg .. "}%\n\n\\pagecolor{bg}%\n") or "")
      .. "\n{\\color{fg}\n"
      .. text
      .. "\n}\n"
      .. "\n\\end{document}\n"
  )
  local err = "Please adjust `png' part of `babel.languages.latex.process_alist'."
  local input = M.compile_file(texfile, p.latex_compiler, p.image_input_type or "dvi", err, cwd)
  local dpi_s = dpi == math.floor(dpi) and string.format("%.1f", dpi) or tostring(dpi)
  local image = M.compile_file(input, converter, p.image_output_type or "png", err, cwd, {
    D = ob.sh(dpi_s),
    S = ob.sh(tostring(dpi / 140.0)),
  })
  vim.uv.fs_copyfile(image, out_file)
  for _, e in ipairs({ ".dvi", ".xdv", ".pdf", ".tex", ".aux", ".log", ".svg", ".png", ".jpg", ".jpeg", ".out" }) do
    os.remove(texbase .. e)
  end
end

--- `org-babel-latex-tex-to-pdf` (org-latex-compile).
local function tex_to_pdf(texfile)
  local pdf, err = require("org.export.latex").compile(texfile)
  if not pdf then
    error(err or ("PDF file " .. texfile:gsub("%.tex$", ".pdf") .. " wasn't produced"), 0)
  end
  return pdf
end

--- The document of the pdf / imagemagick case.
local function pdf_document(body, headers, pkgs, fit, border, height, width)
  local latex = require("org.export.latex")
  local data = require("org.export.latex_data")
  local def = {}
  for _, p in ipairs(remove_packages(export_cfg().default_packages or data.default_packages)) do
    if not (type(p) == "table" and p[2] == "hyperref") then
      def[#def + 1] = p
    end
  end
  local all = vim.list_extend(vim.deepcopy(pkgs), export_cfg().packages or {})
  local header = latex.splice_header(format_latex_header(), def, remove_packages(all), false, nil)
  local inputenc = "\\usepackage[" .. (export_cfg().inputenc or "utf8") .. "]{inputenc}"
  header = header:gsub("\\usepackage%[AUTO%]{inputenc}", inputenc)
  return header
    .. (fit and "\n\\usepackage[active, tightpage]{preview}\n" or "")
    .. (border and string.format("\\setlength{\\PreviewBorder}{%s}", border) or "")
    .. (height and ("\n" .. string.format("\\pdfpageheight %s", height)) or "")
    .. (width and ("\n" .. string.format("\\pdfpagewidth %s", width)) or "")
    .. (#headers > 0 and ("\n" .. table.concat(headers, "\n") .. "\n") or "")
    .. (
      fit and ("\n\\begin{document}\n\\begin{preview}\n" .. body .. "\n\\end{preview}\n\\end{document}\n")
      or ("\n\\begin{document}\n" .. body .. "\n\\end{document}\n")
    )
end

--- Compile `body` to `out_file` (absolute), like org-babel-execute:latex.
function M.make_file(body, args, out_file, bufnr, cwd)
  local o = opts()
  local ext = out_file:match("%.([^./]+)$") or ""
  local tex_file = vim.fn.tempname() .. "latex.tex"
  local border = ob.unq(args.border)
  local imagemagick = args.imagemagick ~= nil and ob.unq(args.imagemagick) ~= "nil"
  local fit = (args.fit ~= nil and ob.unq(args.fit) ~= "nil") or border ~= nil
  local height = fit and ob.unq(args.pdfheight) or nil
  local width = fit and ob.unq(args.pdfwidth) or nil
  local headers = strings(args.headers) or {}
  local in_buffer = ob.unq(args.buffer) ~= "no"
  local pkgs = packages(args.packages)
  if out_file:match("%.png$") and not imagemagick then
    formula_image(body, out_file, headers, pkgs, in_buffer, bufnr, cwd)
  elseif ext == "svg" then
    ob.write(
      tex_file,
      call_opt(o.preamble, args, "\\documentclass[preview]{standalone}\n")
        .. table.concat(headers, "\n")
        .. call_opt(o.begin_env, args, "\\begin{document}")
        .. body
        .. call_opt(o.end_env, args, "\\end{document}")
    )
    local pdf = tex_to_pdf(tex_file)
    local img = M.compile_file(pdf, { o.pdf_svg_process }, ext, "org babel latex failed", cwd)
    vim.uv.fs_rename(img, out_file)
  elseif out_file:match("%.tikz$") then
    os.remove(out_file)
    ob.write(out_file, body)
  elseif ext == "html" and vim.fn.executable(o.htlatex or "htlatex") == 1 then
    local pk = {}
    for i, p in ipairs(o.htlatex_packages or {}) do
      pk[i] = "\\usepackage" .. p
    end
    ob.write(
      tex_file,
      "\\documentclass[preview]{standalone}\n\\def\\pgfsysdriver{pgfsys-tex4ht.def}\n"
        .. table.concat(pk, "\n")
        .. (#headers > 0 and ("\n" .. table.concat(headers, "\n") .. "\n") or "")
        .. "\\begin{document}"
        .. body
        .. "\\end{document}"
    )
    os.remove(out_file)
    local dir = vim.fn.fnamemodify(tex_file, ":h")
    vim.system({ "sh", "-c", (o.htlatex or "htlatex") .. " " .. tex_file }, { cwd = dir }):wait()
    local base = tex_file:gsub("%.tex$", "")
    if vim.fn.filereadable(base .. "-1.svg") == 1 then
      if not out_file:match("%.svg$") then
        error("SVG file produced but HTML file requested", 0)
      end
      vim.uv.fs_rename(base .. "-1.svg", out_file)
    elseif vim.fn.filereadable(base .. ".html") == 1 then
      if not out_file:match("%.html$") then
        error("HTML file produced but SVG file requested", 0)
      end
      vim.uv.fs_copyfile(base .. ".html", out_file)
      os.remove(base .. ".html")
    end
  elseif ext == "pdf" or imagemagick then
    ob.write(tex_file, pdf_document(body, headers, pkgs, fit, border, height, width))
    os.remove(out_file)
    local pdf = tex_to_pdf(tex_file)
    if ext == "pdf" then
      vim.uv.fs_copyfile(pdf, out_file)
      os.remove(pdf)
    else
      local cmd = "convert "
        .. (ob.unq(args.iminoptions) or "")
        .. " "
        .. pdf
        .. " "
        .. (ob.unq(args.imoutoptions) or "")
        .. " "
        .. (ob.unq(args.file) or out_file)
      vim.system({ "sh", "-c", cmd }, { cwd = cwd }):wait()
      os.remove(pdf)
    end
  else
    error(
      "Can not create " .. ext .. " files, please specify a .png or .pdf file or try the :imagemagick header argument",
      0
    )
  end
end

function M.prepare(body, args, vars, ctx)
  local text = M.expand(body, args, vars)
  local file = ob.unq(args.file)
  if not file or file == "" then
    return { value = text }
  end
  local out = require("org.utils").is_absolute(file) and file or (ctx.cwd .. "/" .. file)
  -- compiled at once (Emacs waits too); an error aborts without a result
  M.make_file(text, args, out, ctx.bufnr, ctx.cwd)
  return { value = nil }
end

return M
