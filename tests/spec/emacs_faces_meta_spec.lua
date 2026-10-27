-- The faces of keywords, drawers and comments (the "meta" family of
-- tests/helpers/faces.lua) with the parser highlighter, against what Emacs
-- Org draws on each byte of the fixtures (tests/fixtures/emacs/faces/).
local F = require("tests.helpers.faces")

--- Fixture name -> { [line] = reason }: lines left out on purpose.
local KNOWN = {
  ["tests-fixtures-emacs-faces-meta.org"] = {
    -- After a #+begin_ line with no end line and no headline below,
    -- Emacs draws no keyword or comment to the end of what it fontifies
    -- (org-fontify-meta-lines-and-blocks-1 returns nil there, which ends
    -- font-lock's calls to it; how far that goes depends on jit-lock's
    -- chunks): an accident not worth copying, the lines are drawn as
    -- anywhere else.
    [107] = "Emacs stops at an unterminated block",
    [108] = "Emacs stops at an unterminated block",
  },
  ["tests-fixtures-emacs-faces-object.org"] = {
    -- An inline src block in a comment or a keyword line: Emacs's inline
    -- src fontification (org-fontify-inline-src-blocks-1) takes the
    -- comment and meta-line faces off its braces and body; org.nvim
    -- keeps the line's face there, as on the rest of the line.
    [99] = "inline src block in a comment",
    [100] = "inline src block in a keyword",
  },
}

describe("Emacs faces: keywords, drawers and comments", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })
  F.spec("meta", KNOWN)
end)
