-- The parser highlighter (org.ui.highlight.object) against every face
-- Emacs Org 9.8.12 draws, for the object family: links, footnotes,
-- targets, macros, inline src blocks, citations and hidden text
-- (tests/helpers/faces.lua, tests/fixtures/emacs/faces/expected/).

-- Known differences: fixture -> { [line] = reason }.
local KNOWN = {
  ["tests-fixtures-emacs-faces-objects.org"] = {
    -- a macro with no "}}}" before the next headline, and a footnote
    -- reference with no closing bracket before it: Emacs's font-lock
    -- paints them over the headline and on (org-fontify-macros stops only
    -- at an empty line, scan-sexps not even there); org.nvim ends them
    -- before the line of stars, so that a row is drawn from a window that
    -- reads back no further than the headline above it (`:h
    -- org-differences`)
    [35] = "a macro and a footnote reference over a headline",
    [36] = "a macro and a footnote reference over a headline",
    [37] = "a macro and a footnote reference over a headline",
  },
  ["tests-fixtures-emacs-faces-object.org"] = {
    -- after a macro with no "}}}" before an empty line, org-fontify-macros
    -- returns nil and font-lock stops looking for macros in the region it
    -- fontifies (the whole buffer here, a jit-lock chunk when editing):
    -- org.nvim goes on to the macros after it
    [81] = "macros after an unclosed one",
    -- a footnote reference org-footnote-next-reference-or-definition
    -- turns down (in a bracket link, in a LaTeX macro's argument, at the
    -- start of a line, with no closing bracket) goes on to its definition
    -- branch, which finds the definition above it (up to a headline or
    -- two blank lines) and draws org-footnote from that definition's
    -- label to the end of the reference: over whole paragraphs, lists
    -- and tables. An Emacs bug not worth copying: org.nvim draws the
    -- label of the definition only
    [127] = "org-footnote from a definition to a reference it turned down",
  },
}

describe("emacs parity: object faces", function()
  with_config({ ui = { hide_emphasis_markers = true } })
  require("tests.helpers.faces").spec("object", KNOWN)
end)
