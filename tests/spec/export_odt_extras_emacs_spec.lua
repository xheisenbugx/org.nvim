-- org-odt-export-as-odf(-and-open) and the org-odt-convert command.
-- Expected .odf members from Emacs Org 9.8.10 (org-odt-export-as-odf with
-- the same fake MathML converter).
local odt = require("org.export.odt")
local zip = require("org.export.zip")
local config = require("org.config")
local utils = require("org.utils")

describe("odt extras (Emacs parity)", function()
  local dir, c, saved
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.fn.resolve(dir)
    c = config.opts.export.odt
    saved = vim.deepcopy(c)
    vim.fn.writefile({
      'printf \'<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>%s</mi></math>\' "$(cat "$1")" > "$2"',
    }, dir .. "/mml.sh")
    c.latex_to_mathml_convert_command = "sh " .. dir .. "/mml.sh %I %o"
  end)
  after_each(function()
    config.opts.export.odt = saved
  end)

  it("exports a LaTeX fragment as an OpenDocument formula", function()
    local notify = utils.notify
    utils.notify = function() end
    local out = odt.export_as_odf("$a$", dir .. "/f.odf")
    utils.notify = notify
    eq(dir .. "/f.odf", out)
    eq("application/vnd.oasis.opendocument.formula", zip.read(out, "mimetype"))
    eq(
      '<?xml version="1.0" encoding="UTF-8"?>\n<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>$a$</mi></math>',
      zip.read(out, "content.xml")
    )
    eq(
      table.concat({
        '<?xml version="1.0" encoding="UTF-8"?>',
        '     <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">',
        "",
        '<manifest:file-entry manifest:media-type="application/vnd.oasis.opendocument.formula" manifest:full-path="/" manifest:version="1.2"/>',
        '<manifest:file-entry manifest:media-type="text/xml" manifest:full-path="content.xml"/>',
        "</manifest:manifest>",
        "",
      }, "\n"),
      zip.read(out, "META-INF/manifest.xml")
    )
  end)

  it("takes the fragment from the selection and asks for the file", function()
    local buf = org_buffer({ "Text \\(x+1\\) and more." }, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/doc.org")
    local vr, mode, input, notify = utils.visual_range, vim.fn.mode, utils.input, utils.notify
    utils.visual_range = function()
      return 1, 1, 1, 22, "v"
    end
    vim.fn.mode = function()
      return "v"
    end
    local prompts = {}
    utils.input = function(o)
      prompts[#prompts + 1] = { o.prompt, o.default }
      return o.default
    end
    utils.notify = function() end
    local out = odt.export_as_odf()
    utils.visual_range, vim.fn.mode, utils.input, utils.notify = vr, mode, input, notify
    eq({ { "LaTeX Fragment: ", "\\(x+1\\)" }, { "ODF filename: ", dir .. "/doc.odf" } }, prompts)
    eq(dir .. "/doc.odf", out)
    ok(zip.read(out, "content.xml"):find("<mi>\\(x+1\\)</mi>", 1, true))
  end)

  it("finds fragments like org-latex-regexps", function()
    eq("$x$", odt.find_latex_fragment("a $x$ b"))
    eq("$a + b$", odt.find_latex_fragment("so $a + b$."))
    eq("\\[y\\]", odt.find_latex_fragment("see \\[y\\] here"))
    eq("$$z$$", odt.find_latex_fragment("$$z$$"))
    eq(
      "\\begin{equation}\na\n\\end{equation}\n",
      odt.find_latex_fragment("\\begin{equation}\na\n\\end{equation}\nrest")
    )
  end)

  it("converts a file chosen at a prompt (org-odt-convert)", function()
    c.convert_process = "fake"
    c.convert_processes = { { "fake", "cp %i %o" } }
    c.convert_capabilities = { { "Text", { "odt" }, { { "txt", "txt" }, { "pdf", "pdf" } } } }
    vim.fn.writefile({ "x" }, dir .. "/a.odt")
    local input, complete, notify = utils.input, utils.input_complete, utils.notify
    utils.input = function()
      return dir .. "/a.odt"
    end
    local offered
    utils.input_complete = function(_, choices)
      offered = choices
      return "txt"
    end
    utils.notify = function() end
    local out = odt.convert_command()
    utils.input, utils.input_complete, utils.notify = input, complete, notify
    eq({ "txt", "pdf" }, offered)
    eq(dir .. "/a.txt", out)
    eq({ "x" }, vim.fn.readfile(out))
  end)
end)
