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
    [112] = "Emacs stops at an unterminated block",
    [113] = "Emacs stops at an unterminated block",
  },
}

describe("Emacs faces: keywords, drawers and comments", function()
  with_config({ ui = { hide_emphasis_markers = true } })
  F.spec("meta", KNOWN)
end)
