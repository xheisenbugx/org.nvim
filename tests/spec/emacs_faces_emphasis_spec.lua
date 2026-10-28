-- The faces of emphasis, verbatim and code (org-do-emphasis-faces,
-- org-activate-code) and the hidden emphasis markers drawn by the parser
-- highlighter (org.ui.emphasis), against Emacs Org 9.8.12 byte by byte
-- (tests/helpers/faces.lua, tests/fixtures/emacs/faces/). The bodies of
-- html export blocks count too: Emacs fontifies them with html-mode, which
-- draws <b> and <em> bold and italic, and so does Vim's html syntax there
-- (htmlBold, htmlItalic: faces.lua `native_faces_of`).
local F = require("tests.helpers.faces")

-- fixture -> { [line] = why it differs }
local KNOWN = {
  ["tests-fixtures-emacs-faces-inlinesrc.org"] = {
    -- an inline src block in <b>...</b> of an html export block: Emacs
    -- takes bold off its braces and body (org-fontify-inline-src-blocks);
    -- Vim's html syntax draws htmlBold there, and a mark can't take an
    -- attribute of the syntax off
    [47] = "Vim's html syntax under an inline src block",
  },
}

describe("emacs faces: emphasis", function()
  with_config({ ui = { hide_emphasis_markers = true } })
  F.spec("emphasis", KNOWN)
end)
