-- Man page back-end (ox-man). The .man files next to the fixtures were
-- written by Emacs Org 9.8.10 (org-export-as 'man; blocks-options.man with
-- org-man-tables-centered nil and org-man-table-scientific-notation
-- "%s*10^%s", basic-options.man with smart quotes and preserve-breaks).
-- See $SCRATCH/probes/11-koma-man/gen.sh; the inline expectations come from
-- the same Emacs (probes/11-koma-man/p1.el).

local export = require("org.export")
local ox = require("org.export.ox")
local man = require("org.export.man")
local config = require("org.config")
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local dir = root .. "/fixtures/export/man"

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

--- Generated target references are random in Emacs.
local function norm(s)
  return (s:gsub("org%x%x%x%x%x%x%x", "orgREF"))
end

local function manpage(lines, opts)
  return (ox.export_as("man", lines, opts or {}))
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return require("org.utils").realpath(d)
end

local function golden(name, file, ext)
  local src = dir .. "/" .. file .. ".org"
  local out = ox.export_as("man", vim.fn.readfile(src), { filename = src, ext = ext })
  eq(norm(read(dir .. "/" .. name .. ".man")), norm(out))
end

describe("man export", function()
  local saved_man
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    saved_man = vim.deepcopy(config.opts.export.man)
  end)
  after_each(function()
    config.opts.export.man = saved_man
  end)

  it("matches Emacs on basic.org (header, sections, lists, markup, links)", function()
    golden("basic", "basic")
  end)

  it("matches Emacs on blocks.org (blocks, tables, drawers)", function()
    golden("blocks", "blocks")
  end)

  it("honours export.man table options", function()
    config.opts.export.man = vim.tbl_extend("force", saved_man or {}, {
      tables_centered = false,
      table_scientific_notation = "%s*10^%s",
    })
    golden("blocks-options", "blocks")
  end)

  it("honours smart quotes and preserve-breaks", function()
    golden("basic-options", "basic", { with_smart_quotes = true, preserve_breaks = true })
  end)

  it("writes tables verbatim with export.man.tables_verbatim", function()
    config.opts.export.man = vim.tbl_extend("force", saved_man or {}, { tables_verbatim = true })
    local s = manpage({ "| a | b |", "|---+---|", "| 1 | 22 |" }, { body_only = true })
    eq(".nf\n\\fC| a |  b |\n|---+----|\n| 1 | 22 |\\fP\n.fi\n", s)
  end)

  it("writes nil for empty sections and protects backslashes like Emacs", function()
    eq('.SH "Empty"\nnil\n.SH "Two"\n.SS "Sub"\nnil\n', manpage({ "* Empty", "* Two", "** Sub" }, { body_only = true }))
    local s = manpage({
      "#+OPTIONS: title:nil date:nil",
      "#+TITLE: x",
      "#+MAN_CLASS_OPTIONS: :section-id 5",
      "Text a\\\\b c\\%d e\\",
    })
    eq('.TH " " "1" "" "" \n.PP\nText a$\\ c\\%d e$\\\n', s)
    local breaks = manpage({ "#+OPTIONS: \\n:t", "line one\\\\", "line two" }, { body_only = true })
    eq(".PP\nline one\n.br\nline two.br\n", breaks)
    eq("$\\x\\y", man.protect_backslashes("\\x\\y"))
    eq("xa$\\b\\c", man.protect_backslashes("xa\\b\\c"))
    eq("q$\\", man.protect_backslashes("q\\"))
  end)

  it("highlights source blocks with source-highlight (fake executable)", function()
    local d = tmpdir()
    local bin = d .. "/bin"
    vim.fn.mkdir(bin, "p")
    -- writes "HL <lang>" and the input to the -o file
    fake_exe(
      bin,
      "source-highlight",
      'while [ $# -gt 0 ]; do case "$1" in -s) l=$2; shift;; -i) i=$2; shift;; -o) o=$2; shift;; esac; shift; done\n'
        .. '{ echo "HL $l"; cat "$i"; } > "$o"'
    )
    local path = vim.env.PATH
    path_prepend(bin)
    config.opts.export.man = vim.tbl_extend("force", saved_man or {}, { source_highlight = true })
    local ok_, s = pcall(manpage, {
      "#+begin_src emacs-lisp",
      "(a \\b)",
      "#+end_src",
      "",
      "#+begin_src nolang",
      "x \\y",
      "#+end_src",
    }, { body_only = true })
    vim.env.PATH = path
    ok(ok_, s)
    eq("HL lisp\n(a \\b)\n.RS\n.nf\n\\fCx \\ey\n\\m[]\\fP\n.fi\n.RE\n", s)
  end)

  it("completes the new formats for :Org export", function()
    eq({ "man", "man-pdf" }, require("org.commands").complete("ma", "Org export ma"))
    eq({ "koma-letter", "koma-pdf" }, require("org.commands").complete("ko", "Org export ko"))
  end)

  describe("with a POSIX shell", function()
    posix_shell()
    it("exports with the dispatcher formats man and man-pdf (fake groff pipeline)", function()
      local d = tmpdir()
      local src = d .. "/tool.org"
      vim.fn.writefile({ "#+TITLE: tool", "#+DATE: 2026", "* NAME", "tool - x" }, src)
      vim.cmd("edit " .. vim.fn.fnameescape(src))
      local buf = vim.api.nvim_get_current_buf()
      local out = export.export("man", { bufnr = buf })
      eq(d .. "/tool.man", out)
      eq('.TH "tool" "1" "2026" "" \n.SH "NAME"\n.PP\ntool - x\n', read(out))
      -- man-pdf: pdf_process with %f/%b, log files removed
      config.opts.export.man = vim.tbl_extend("force", saved_man or {}, {
        pdf_process = { "cp %f %b.pdf", "touch %b.log %b.toc" },
      })
      local pdf = export.export("man-pdf", { bufnr = buf })
      eq(d .. "/tool.pdf", pdf)
      eq(read(d .. "/tool.man"), read(pdf))
      eq(0, vim.fn.filereadable(d .. "/tool.log"))
      eq(0, vim.fn.filereadable(d .. "/tool.toc"))
      -- remove_logfiles = false keeps them
      config.opts.export.man.remove_logfiles = false
      export.export("man-pdf", { bufnr = buf })
      eq(1, vim.fn.filereadable(d .. "/tool.log"))
      -- a failing process reports an error and returns nil
      config.opts.export.man.pdf_process = { "true" }
      os.remove(d .. "/tool.pdf")
      eq(nil, export.export("man-pdf", { bufnr = buf }))
      vim.cmd("bwipeout!")
    end)
  end)
end)
