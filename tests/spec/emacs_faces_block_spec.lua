-- The faces of blocks and LaTeX (org-block, org-block-begin-line /
-- -end-line, org-quote, org-verse, org-latex-and-related) drawn by the
-- parser highlighter (org.ui.highlight.block), against Emacs Org 9.8.12
-- byte by byte (tests/helpers/faces.lua, tests/fixtures/emacs/faces/;
-- tests/fixtures/emacs/faces/block.org and quote.org hold the hard cases).
local F = require("tests.helpers.faces")

-- fixture -> { [line] = why it differs }
local KNOWN = {
  ["examples-17-babel.org"] = {
    -- a json src block: Vim's json syntax conceals the quotes, and a
    -- hidden byte shows no face
    [574] = "json syntax conceal",
  },
}

describe("emacs faces: block", function()
  -- (org-fontify-quote-and-verse-blocks nil, as in Emacs and the default)
  with_config({ ui = { hide_emphasis_markers = true } })

  F.spec("block", KNOWN)
end)

-- org-quote and org-verse: the inputs with a quote or verse block recorded
-- with org-fontify-quote-and-verse-blocks set (expected-quote/)
describe("emacs faces: block, fontify_quote_and_verse_blocks", function()
  with_config({
    ui = { hide_emphasis_markers = true, fontify_quote_and_verse_blocks = true },
  })

  F.spec("block", KNOWN, "expected-quote")
end)
