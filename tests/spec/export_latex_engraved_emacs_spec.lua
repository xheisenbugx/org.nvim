-- LaTeX source blocks with org-latex-src-block-backend engraved
-- (engrave-faces). The .tex files in tests/fixtures/export/engraved were
-- written by Emacs Org 9.8.10 with engrave-faces 0.3.1 from GNU ELPA
-- (org-export-as 'latex, org-export-use-babel nil); options.tex with
-- org-latex-caption-above '(src-block table) and org-latex-engraved-options
-- '(("mathescape" . "true") ("frame" . "lines")). The Lua and C blocks were
-- chosen where tree-sitter and Emacs' lua-mode/c-mode give the same faces.

local ox = require("org.export.ox")
local config = require("org.config")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local dir = root .. "/fixtures/export/engraved"

local function has_parsers()
  local lib = vim.fn.fnamemodify(vim.env.VIMRUNTIME, ":h:h:h") .. "/lib/nvim"
  if vim.fn.isdirectory(lib .. "/parser") == 1 and not vim.o.rtp:find(lib, 1, true) then
    vim.opt.rtp:append(lib)
  end
  return pcall(vim.treesitter.language.add, "lua") and pcall(vim.treesitter.language.add, "c")
end

local function read(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function latex(lines)
  return (ox.export_as("latex", lines, {}))
end

describe("latex engraved source blocks", function()
  local lat = config.opts.export.latex
  local saved
  before_each(function()
    config.opts.babel.evaluate_on_export = false
    saved = vim.deepcopy(lat)
    lat.src_block_backend = "engraved"
  end)
  after_each(function()
    for k in pairs(lat) do
      lat[k] = nil
    end
    for k, v in pairs(saved) do
      lat[k] = v
    end
    config.opts.babel.evaluate_on_export = true
  end)

  it("matches Emacs: Code/Verbatim, \\EF faces, floats, themes, inline \\Verb, preamble", function()
    if not has_parsers() then
      return
    end
    local out = latex(vim.fn.readfile(dir .. "/blocks.org"))
    eq(read(dir .. "/blocks.tex"), out)
  end)

  it("matches Emacs with engraved options, mathescape and captions above", function()
    if not has_parsers() then
      return
    end
    lat.caption_above = { "src-block", "table" }
    lat.engraved_options = { { "mathescape", "true" }, { "frame", "lines" } }
    local out = latex(vim.fn.readfile(dir .. "/options.org"))
    eq(read(dir .. "/options.tex"), out)
  end)

  it("engraves as plain text without a parser, and leaves the preamble out without code", function()
    local out = latex({ "#+begin_src nosuchlang", "a_b & c", "#+end_src" })
    local want = "\\begin{Code}\n\\begin{Verbatim}\n\\color{EFD}a\\_b \\& c\n\\end{Verbatim}\n\\end{Code}"
    ok(out:find(want, 1, true), out)
    ok(out:find("% Setup for code blocks [1/2]", 1, true), out)
    out = latex({ "Just text." })
    ok(not out:find("Setup for code blocks", 1, true), out)
  end)

  it("colours the preamble from a colour scheme with theme t", function()
    lat.engraved_theme = true
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    local out = latex({ "#+begin_src nosuchlang", "x", "#+end_src" })
    local fg = normal.fg and string.format("%06x", normal.fg) or "000000"
    ok(out:find("\\definecolor{EFD}{HTML}{" .. fg .. "}", 1, true), out)
    ok(out:find("% font-lock-keyword-face", 1, true), out)
  end)

  it("takes a named theme from that colour scheme and restores the current one", function()
    local E = require("org.export.engrave")
    if not vim.tbl_contains(vim.fn.getcompletion("", "color"), "habamax") then
      return
    end
    local before = vim.g.colors_name
    local preset = E.get_theme("habamax")
    eq(before, vim.g.colors_name)
    eq("default", preset[1][1])
    ok(preset[1][4].fg and preset[1][4].fg ~= "#000000", vim.inspect(preset[1]))
    local out = latex({
      "#+attr_latex: :engraved-theme habamax",
      "#+begin_src nosuchlang",
      "x",
      "#+end_src",
    })
    ok(out:find("\\newcommand{\\engravedthemehabamax}{%\n\\renewcommand\\efstrut", 1, true), out)
    ok(out:find("{\\engravedthemehabamax\\begin{Code}", 1, true), out)
  end)

  it("rejects an unknown theme like engrave-faces-get-theme", function()
    local E = require("org.export.engrave")
    local okp, err = pcall(E.get_theme, "no-such-theme-anywhere")
    ok(not okp)
    ok(tostring(err):find("no%-such%-theme%-anywhere"), err)
  end)
end)

describe("engrave-faces LaTeX helpers", function()
  local E = require("org.export.engrave")

  it("protects LaTeX specials like engrave-faces-latex--protect-content", function()
    -- (engrave-faces-latex--protect-content "\\ { } $ % & _ # ^ ~") in Emacs
    eq("\\char92{} \\{ \\} \\$ \\% \\& \\_ \\# \\char94{} \\char126{}", E.protect("\\ { } $ % & _ # ^ ~"))
  end)

  it("spells out faces outside the preset through :inherit, like engrave-faces-latex-face-apply", function()
    if not has_parsers() then
      return
    end
    -- Emacs: (engrave-faces-latex-face-mapper 'font-lock-function-call-face "x")
    -- = "\\textcolor[HTML]{0000ff}{x}" (inherits font-lock-function-name-face)
    eq("\\color{EFD}\\textcolor[HTML]{0000ff}{foo}(x)", E.engrave("foo(x)", "lua", E.DEFAULT))
  end)

  it("writes preamble lines like engrave-faces-latex-gen-preamble-line", function()
    -- Emacs: (engrave-faces-latex-gen-preamble-line 'f '(:slug "x" :foreground "#112233"
    --          :background "#445566" :weight bold :slant italic))
    eq(
      "\\definecolor{EFx}{HTML}{112233}\n\\definecolor{Efx}{HTML}{445566}\n"
        .. "\\newcommand{\\EFx}[1]{\\colorbox{Efx}{\\efstrut{}\\textcolor{EFx}{\\textbf{\\textit{#1}}}}} % f",
      E.preamble_line("f", "x", { fg = "#112233", bg = "#445566", weight = "bold", slant = "italic" })
    )
  end)
end)
