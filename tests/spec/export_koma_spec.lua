-- KOMA-Script letter back-end (ox-koma-letter). The .tex files next to the
-- fixtures were written by Emacs Org 9.8.10 (org-export-as 'koma-letter,
-- with user-full-name "Jane Doe" and user-mail-address "jane@example.com";
-- config.tex and headings-noopening.tex with the org-koma-letter-*
-- settings mirrored in the tests below). See
-- $SCRATCH/probes/11-koma-man/gen.sh.

local export = require("org.export")
local ox = require("org.export.ox")
local config = require("org.config")
local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local dir = root .. "/fixtures/export/koma"

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function koma(lines, opts)
  return (ox.export_as("koma-letter", lines, opts or {}))
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
  return require("org.utils").realpath(d)
end

local function golden(name, file)
  local src = dir .. "/" .. file .. ".org"
  local out = ox.export_as("koma-letter", vim.fn.readfile(src), { filename = src })
  eq(read(dir .. "/" .. name .. ".tex"), out)
end

describe("koma-letter export", function()
  posix_shell()
  local saved_koma, saved_author, saved_email
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    saved_koma = vim.deepcopy(config.opts.export.koma_letter)
    saved_author, saved_email = config.opts.export.author, config.opts.export.email
    config.opts.export.author = "Jane Doe"
    config.opts.export.email = "jane@example.com"
  end)
  after_each(function()
    config.opts.export.koma_letter = saved_koma
    config.opts.export.author, config.opts.export.email = saved_author, saved_email
  end)

  for _, name in ipairs({ "letter", "headings", "prefer", "plain" }) do
    it("matches Emacs on " .. name .. ".org", function()
      golden(name, name)
    end)
  end

  it("honours the export.koma_letter options like the org-koma-letter-* variables", function()
    config.opts.export.koma_letter = vim.tbl_extend("force", saved_koma or {}, {
      class_option_file = "DIN",
      from_address = "Addr 1\nAddr 2",
      phone_number = "123",
      url = "https://x.y",
      from_logo = "\\includegraphics{l}",
      place = "Paris",
      location = "Loc",
      opening = "Hello,",
      closing = "Bye,",
      signature = "Sig",
      subject_format = { "left", "titled" },
      use_backaddress = true,
      use_foldmarks = { "B", "H" },
      use_phone = true,
      use_url = true,
      use_from_logo = true,
      use_email = true,
      use_place = false,
      prefer_subject = true,
      author = "Config Author",
      email = function()
        return "cfg@example.com"
      end,
    })
    golden("config", "config")
  end)

  it("uses no headline as opening/closing without headline_is_opening_maybe", function()
    config.opts.export.koma_letter = vim.tbl_extend("force", saved_koma or {}, {
      headline_is_opening_maybe = false,
      default_class = "article",
      author = false,
      email = false,
    })
    golden("headings-noopening", "headings")
  end)

  it("prefers special headings with export.koma_letter.prefer_special_headings", function()
    -- same as special-headings:t in prefer.org
    local lines = { "#+OPTIONS: timestamp:nil", "#+TO_ADDRESS: Keyword", "* To :to:", "Heading" }
    has(koma(lines), "\\begin{letter}{%\nKeyword}")
    config.opts.export.koma_letter = vim.tbl_extend("force", saved_koma or {}, { prefer_special_headings = true })
    has(koma(lines), "\\begin{letter}{%\nHeading}")
  end)

  it("sets every property of an OPTIONS item (email:t)", function()
    local s = koma({ "#+OPTIONS: email:t timestamp:nil", "Body." })
    -- in-buffer setting: after the LCO file
    has(s, "\\LoadLetterOption{NF}\n\\KOMAoption{fromemail}{true}\n")
  end)

  it("keeps the last headline of a special tag and the after-letter order", function()
    local s = koma({
      "#+OPTIONS: timestamp:nil after-letter-order:(x after_letter)",
      "* A :ps:",
      "one",
      "* B :ps:",
      "two",
      "* C :after_letter:",
      "tail",
    })
    has(s, "\\ps{two}")
    hasnt(s, "\\ps{one}")
    has(s, "\\end{letter}\n\ntail\n\\end{document}")
  end)

  it("exports only the letter body with body_only", function()
    local s = koma({ "#+OPTIONS: timestamp:nil", "* PS :ps:", "p", "* Open", "Body *b*." }, { body_only = true })
    eq("Body \\textbf{b}.\n", s)
  end)

  it("has the Emacs dispatcher entries (C-c C-e k and C-c C-e M)", function()
    local ui = require("org.ui")
    local menu, exp = ui.menu, export.export
    local calls = {}
    local path = { "k", "L" }
    ui.menu = function(o)
      local key = table.remove(path, 1)
      for _, i in ipairs(o.items) do
        if i.key == key then
          if i.items then
            return ui.menu({ items = i.items })
          end
          return i.value
        end
      end
    end
    export.export = function(f, o)
      calls[#calls + 1] = { f, o.to_buffer or false, o.open or false }
    end
    org_buffer({ "Body." }, { 1, 0 })
    local ok_, err = pcall(function()
      export.prompt()
      for _, p in ipairs({ { "k", "l" }, { "k", "p" }, { "k", "o" }, { "M", "m" }, { "M", "p" }, { "M", "o" } }) do
        path = p
        export.prompt()
      end
    end)
    ui.menu, export.export = menu, exp
    vim.cmd("bwipeout!")
    ok(ok_, err)
    eq({
      { "koma-letter", true, false },
      { "koma-letter", false, false },
      { "koma-pdf", false, false },
      { "koma-pdf", false, true },
      { "man", false, false },
      { "man-pdf", false, false },
      { "man-pdf", false, true },
    }, calls)
  end)

  it("exports with the dispatcher formats koma-letter and koma-pdf", function()
    local d = tmpdir()
    local src = d .. "/letter.org"
    vim.fn.writefile({ "#+OPTIONS: timestamp:nil", "#+OPENING: Hi", "Body." }, src)
    vim.cmd("edit " .. vim.fn.fnameescape(src))
    local buf = vim.api.nvim_get_current_buf()
    local out = export.export("koma-letter", { bufnr = buf })
    eq(d .. "/letter.tex", out)
    has(read(out), "\\documentclass[11pt]{scrlttr2}")
    has(read(out), "\\opening{Hi}\n\nBody.\n\\closing{}")
    eq(out, export.export("koma", { bufnr = buf }))
    -- buffer
    eq("buffer", export.export("koma-letter", { bufnr = buf, to_buffer = true }))
    local scratch = vim.api.nvim_get_current_buf()
    eq("tex", vim.bo[scratch].filetype)
    ok(vim.api.nvim_buf_get_name(scratch):find("Org KOMA%-LETTER Export"))
    vim.cmd("close")
    -- pdf: org-latex-compile with a fake pdf_process (no LaTeX needed)
    local latex_saved = vim.deepcopy(config.opts.export.latex)
    config.opts.export.latex = vim.tbl_extend("force", latex_saved or {}, {
      pdf_process = { "cp %f %b.pdf" },
    })
    local ok_, pdf = pcall(export.export, "koma-pdf", { bufnr = buf, async = false })
    config.opts.export.latex = latex_saved
    ok(ok_, pdf)
    eq(d .. "/letter.pdf", pdf)
    eq(read(d .. "/letter.tex"), read(pdf))
    vim.cmd("bwipeout!")
  end)
end)
