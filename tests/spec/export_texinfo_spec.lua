-- Texinfo back-end (ox-texinfo). The .texi files next to the fixtures were
-- written by Emacs Org 9.8.10 (org-texinfo-export-to-texinfo, with
-- org-export-use-babel nil, org-inlinetask loaded and the kbd macro of the
-- Org manual as a global macro).

local export = require("org.export")
local ox = require("org.export.ox")
local texinfo = require("org.export.texinfo")
local config = require("org.config")
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local dir = root .. "/fixtures/export/texinfo"

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function texi(lines, ext)
  return (ox.export_as("texinfo", lines, { ext = ext or {} }))
end

local function has(s, sub)
  ok(s:find(sub, 1, true), "missing: " .. sub .. "\n---\n" .. s)
end
local function hasnt(s, sub)
  ok(not s:find(sub, 1, true), "unexpected: " .. sub .. "\n---\n" .. s)
end

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end

describe("texinfo export", function()
  posix_shell()
  local saved_texinfo
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    saved_texinfo = vim.deepcopy(config.opts.export.texinfo)
    config.opts.export.global_macros = {
      kbd = function(key)
        return texinfo.kbd_macro(key)
      end,
    }
  end)
  after_each(function()
    config.opts.export.texinfo = saved_texinfo
    config.opts.export.global_macros = {}
  end)

  for _, name in ipairs({ "basic", "features", "lists", "structure" }) do
    it("matches Emacs on " .. name .. ".org", function()
      local file = dir .. "/" .. name .. ".org"
      local opts = { filename = file, ext = { output_file = name .. ".texi" } }
      local out = ox.export_as("texinfo", vim.fn.readfile(file), opts)
      eq(read(dir .. "/" .. name .. ".texi"), out .. "\n")
    end)
  end

  it("quotes keys like org-texinfo-kbd-macro", function()
    eq("@kbd{C-c @key{SPC}}", texinfo.kbd_macro("C-c SPC", true))
    eq("@kbd{M-@key{RET} x}", texinfo.kbd_macro("M-RET x", true))
    eq("@@texinfo:@kbd{@@C-x @@texinfo:@key{@@TAB@@texinfo:}@@@@texinfo:}@@", texinfo.kbd_macro("C-x TAB"))
    local s = texi({ "#+OPTIONS: toc:nil", "Type {{{kbd(C-c SPC)}}}." })
    has(s, "Type @kbd{C-c @key{SPC}}.")
  end)

  it("sanitizes node names and keeps them unique", function()
    eq("[a) b c d", texinfo.sanitize_node("(a) b,  c: d."))
    local s = texi({ "* Top", "* A", "* A" })
    has(s, "@node Top (1)\n@chapter Top")
    has(s, "@node A\n@chapter A")
    has(s, "@node A (1)\n@chapter A")
    has(s, "* A: A (1). ")
  end)

  it("uses TEXINFO_CLASS sectioning from export.texinfo.classes", function()
    config.opts.export.texinfo = vim.tbl_extend("force", saved_texinfo or {}, {
      classes = {
        {
          "info",
          "@documentencoding AUTO\n@documentlanguage AUTO",
          { "@chapter %s", "@unnumbered %s", "@chapheading %s", "@appendix %s" },
        },
        {
          "parts",
          "@documentencoding AUTO\n@set PARTS",
          { "@part %s", "@part %s", "@part %s", "@part %s" },
          { "@chapter %s", "@unnumbered %s", "@chapheading %s", "@appendix %s" },
        },
      },
    })
    local s = texi({ "#+TEXINFO_CLASS: parts", "#+LANGUAGE: fr", "* P", "** C", "*** Low" })
    has(s, "@documentencoding UTF-8\n@set PARTS\n")
    has(s, "@node P\n@part P")
    has(s, "@node C\n@chapter C")
    has(s, "@enumerate\n@item\n@anchor{Low}Low\n\n@end enumerate")
    ok(not pcall(texi, { "#+TEXINFO_CLASS: nope", "* A" }))
  end)

  it("honours the header keywords", function()
    local s = texi({
      "#+TITLE: T",
      '#+TEXINFO_FILENAME: "manual.info"',
      "#+TEXINFO_HEADER: @set A",
      "#+TEXINFO_POST_HEADER: @set B",
      "#+TEXINFO_DIR_TITLE: Short",
      "#+SUBAUTHOR: Other",
      "#+AUTHOR: Me",
    }, { output_file = "ignored.texi" })
    has(s, "@setfilename manual.info\n@settitle T\n")
    has(s, "@set A\n@c %**end of header\n\n@set B\n")
    has(s, "@dircategory Misc\n@direntry\n* Short: (manual).      T.\n@end direntry")
    has(s, "@author Me\n@author Other\n")
    -- without an output file (to_string), Emacs writes no @setfilename
    local s2 = texi({ "#+TITLE: T" })
    hasnt(s2, "@setfilename")
    has(s2, "* (nil).                T.")
  end)

  it("exports Info links like ol-info", function()
    local s = texi({ "See [[info:emacs#Init File][init]] and [[info:elisp]]." })
    has(s, "See @ref{Init File,init,,emacs,} and @ref{Top,,,elisp,}.")
    local h = export.to_string("html", { lines = { "See [[info:emacs::Init File][init]]." }, body_only = true })
    has(h, '<a href="https://www.gnu.org/software/emacs/manual/html_mono/emacs.html#Init-File">init</a>')
    local h2 = export.to_string("html", { lines = { "[[info:foo#1 x]]" }, body_only = true })
    has(h2, '<a href="foo.html#g_t1-x">foo#1 x</a>')
  end)

  it("drops math unless supported (with_latex detect)", function()
    texinfo._supports_math = false
    local s = texi({ "#+OPTIONS: toc:nil", "Math $a+b$ here." })
    has(s, "Math here.")
    texinfo._supports_math = true
    has(texi({ "#+OPTIONS: toc:nil", "Math $a+b$ here." }), "Math @math{a+b} here.")
    texinfo._supports_math = nil
    has(texi({ "#+OPTIONS: toc:nil tex:t", "Math $a+b$ here." }), "Math @math{a+b} here.")
  end)

  it("exports a file with the dispatcher formats texinfo and info", function()
    local d = require("org.utils").realpath(tmpdir())
    local src = d .. "/manual.org"
    vim.fn.writefile({ "#+TITLE: Manual", "* Chapter", "Text." }, src)
    vim.cmd("edit " .. vim.fn.fnameescape(src))
    local buf = vim.api.nvim_get_current_buf()
    local out = export.export("texinfo", { bufnr = buf })
    eq(d .. "/manual.texi", out)
    local text = read(out)
    has(text, "@setfilename manual.info\n")
    has(text, "@direntry\n* (manual).             Manual.\n")
    has(text, "@node Chapter\n@chapter Chapter\n\nText.\n")
    -- info: the .texi is processed by export.texinfo.info_process
    config.opts.export.texinfo = vim.tbl_extend("force", saved_texinfo or {}, {
      info_process = { "cp %f %b.info", "touch %b.cp" },
    })
    local info = export.export("info", { bufnr = buf })
    eq(d .. "/manual.info", info)
    eq(read(d .. "/manual.texi"), read(info))
    eq(0, vim.fn.filereadable(d .. "/manual.cp"))
    config.opts.export.texinfo.info_process = { "true" }
    os.remove(d .. "/manual.info")
    eq(nil, export.export("info", { bufnr = buf }))
    vim.cmd("bwipeout!")
  end)

  it("compiles a .texi whose directory name contains % (format-spec in one pass)", function()
    local d = vim.uv.fs_realpath(tmpdir()) .. "/100%fun"
    vim.fn.mkdir(d, "p")
    local texi = d .. "/m.texi"
    vim.fn.writefile({ "\\input texinfo" }, texi)
    local saved = config.opts.export.texinfo
    config.opts.export.texinfo = vim.tbl_extend("force", saved or {}, { info_process = { "cp %F %O" } })
    local info, err = require("org.export.texinfo").compile(texi)
    config.opts.export.texinfo = saved
    eq(nil, err)
    eq(d .. "/m.info", info)
    eq(read(texi), read(info))
  end)

  it("publishes with the texinfo publishing function", function()
    local d = require("org.utils").realpath(tmpdir())
    vim.fn.mkdir(d .. "/src", "p")
    vim.fn.writefile({ "#+TITLE: P", "* A" }, d .. "/src/p.org")
    local out = require("org.export.publish").functions.texinfo({}, d .. "/src/p.org", d .. "/pub")
    eq(d .. "/pub/p.texi", out)
    has(read(out), "@setfilename " .. d .. "/pub/p.info\n")
  end)
end)
