-- org-html-with-latex: LaTeX as pictures (dvipng, dvisvgm, imagemagick,
-- ... through org-preview-latex-process-alist) and as the output of
-- org-latex-to-html-convert-command (tex:html); ODT MathML cache
-- (org-latex-mathml-directory). Expected HTML from Emacs Org 9.8.10 with
-- the same fake processes (the picture names use another hash).
local export = require("org.export")
local config = require("org.config")

local DOC = {
  "Inline $x^2$ and \\(y < 1\\) here.",
  "",
  "#+name: eqa",
  "\\begin{equation}",
  "a = b",
  "\\end{equation}",
  "",
  "\\begin{align*}",
  "c",
  "\\end{align*}",
}

describe("html LaTeX (Emacs parity)", function()
  posix_shell()
  local dir, ui, saved_processes, saved_cmd
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "x" }, dir .. "/img.png")
    ui = config.opts.ui.latex_preview
    saved_processes = ui.processes
    ui.processes = {
      fakeimg = {
        programs = { "sh" },
        image_input_type = "tex",
        image_output_type = "png",
        latex_compiler = {},
        image_converter = { "cp " .. vim.fn.shellescape(dir .. "/img.png") .. " %O" },
      },
    }
    saved_cmd = config.opts.export.html.latex_to_html_convert_command
  end)
  after_each(function()
    ui.processes = saved_processes
    config.opts.export.html.latex_to_html_convert_command = saved_cmd
    config.opts.babel.evaluate_on_export = true
  end)

  local function html(opts_line)
    local lines = vim.list_extend({ opts_line }, DOC)
    local out = export.to_string("html", { lines = lines, filename = dir .. "/doc.org", body_only = true })
    local n = 0
    out = out:gsub("ltximg/doc_%x+%.png", function()
      n = n + 1
      return "ltximg/doc_HASH" .. n .. ".png"
    end)
    return (out:gsub('id="org%x+"', 'id="orgID"'))
  end

  it("renders fragments and environments as pictures (tex:PROCESS)", function()
    local out = html("#+OPTIONS: tex:fakeimg")
    eq(
      table.concat({
        "<p>",
        'Inline <img src="ltximg/doc_HASH1.png" alt="$x^2$" /> and <img src="ltximg/doc_HASH2.png" alt="\\(y &amp;lt; 1\\)" /> here.',
        "</p>",
        "",
        "",
        '<div id="orgID" class="equation-container">',
        '<span class="equation">',
        '<img src="ltximg/doc_HASH3.png" alt="\\begin{equation*}',
        "a = b",
        "\\end{equation*}",
        '" />',
        "</span>",
        '<span class="equation-label">',
        "1",
        "</span>",
        "</div>",
        "",
        "",
        '<div class="equation-container">',
        '<span class="equation">',
        '<img src="ltximg/doc_HASH4.png" alt="\\begin{align*}',
        "c",
        "\\end{align*}",
        '" />',
        "</span>",
        "</div>",
        "",
      }, "\n"),
      out
    )
    eq(4, #vim.fn.glob(dir .. "/ltximg/doc_*.png", false, true))
  end)

  it("runs org-latex-to-html-convert-command for tex:html", function()
    skip_on_windows("the fake tool runs behind cmd.exe, which re-quotes this command line")
    config.opts.export.html.latex_to_html_convert_command = "echo '<m>'%i'</m>'"
    local out = html("#+OPTIONS: tex:html")
    ok(out:find("<p>\nInline <m>$x^2$</m>\n and <m>\\(y < 1\\)</m>\n here.\n</p>", 1, true), out)
    -- environments stay verbatim
    ok(out:find('<span class="equation">\n\\begin{equation}\na = b\n\\end{equation}\n\n</span>', 1, true), out)
  end)

  it("caches MathML in org-latex-mathml-directory (ODT)", function()
    local odt = require("org.export.odt")
    local c = config.opts.export.odt
    local saved = { c.latex_to_mathml_convert_command, c.latex_mathml_directory }
    local script = dir .. "/mml.sh"
    vim.fn.writefile({
      'printf \'<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>%s</mi></math>\' "$(cat "$1")" > "$2"',
    }, script)
    c.latex_to_mathml_convert_command = "cat %I > %o"
    c.latex_mathml_directory = "ltxmathml/"
    -- the cache file name hashes (FRAGMENT COMMAND) like Emacs:
    -- (sha1 (prin1-to-string (list "$x^2 \"q\" \\\\a$" "cat %I > %o")))
    local file = odt.mathml_cache_file('$x^2 "q" \\\\a$', { input_file = dir .. "/doc.org" })
    eq(dir .. "/ltxmathml/doc-formula-058282f5d7bfa57eac487203acdff9ce85ece1dc.mathml", file)
    c.latex_to_mathml_convert_command = "sh " .. script .. " %I %o"
    local info = { input_file = dir .. "/doc.org" }
    local m1 = odt.latex_to_mathml_cached("a", info)
    eq('<?xml version="1.0" encoding="UTF-8"?>\n<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>a</mi></math>', m1)
    local cached = odt.mathml_cache_file("a", info)
    eq(m1, table.concat(vim.fn.readfile(cached), "\n"))
    -- a second conversion reads the cache
    c.latex_to_mathml_convert_command = nil
    local same = odt.mathml_cache_file("a", info)
    ok(same ~= cached) -- the command is part of the key
    c.latex_to_mathml_convert_command = "sh " .. script .. " %I %o"
    vim.fn.writefile({ "cached" }, cached)
    eq("cached\n", odt.latex_to_mathml_cached("a", info))
    c.latex_to_mathml_convert_command, c.latex_mathml_directory = saved[1], saved[2]
  end)
end)
