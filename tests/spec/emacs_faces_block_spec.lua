-- The faces of blocks and LaTeX (org-block, org-block-begin-line /
-- -end-line, org-quote, org-verse, org-latex-and-related) drawn by the
-- parser highlighter (org.ui.highlight.block), against Emacs Org 9.8.12
-- byte by byte (tests/helpers/faces.lua, tests/fixtures/emacs/faces/;
-- tests/fixtures/emacs/faces/block.org holds the hard cases).
local F = require("tests.helpers.faces")

-- fixture -> { [line] = why it differs }
local KNOWN = {
  ["examples-17-babel.org"] = {
    -- a json src block: Vim's json syntax conceals the quotes, and a
    -- hidden byte shows no face
    [574] = "json syntax conceal",
  },
  ["tests-fixtures-emacs-faces-object.org"] = {
    -- "src_sh{z}" in the body of a sh src block: Emacs's inline src
    -- fontification runs there too and takes org-block off the braces;
    -- org.nvim sees no inline src block in a src block
    [103] = "inline src block in a src block's body",
  },
  ["tests-fixtures-emacs-faces-orgsrc.org"] = {
    -- (the same in the body of an org src block, drawn as Org)
    [33] = "inline src block in a src block's body",
  },
}

describe("emacs faces: block", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })

  -- OrgQuoteBlock stands for org-quote and org-verse, which Emacs draws
  -- only with org-fontify-quote-and-verse-blocks (nil by default, as in
  -- the fixtures); org.nvim always draws it, under the Org text of quote
  -- and verse blocks (:h org-highlights). Its marks are checked in
  -- ui_highlight_block_spec.lua.
  local saved
  before_each(function()
    saved = F.FACE_OF.orgquoteblock
    F.FACE_OF.orgquoteblock = nil
  end)
  after_each(function()
    F.FACE_OF.orgquoteblock = saved
  end)

  F.spec("block", KNOWN)
end)
