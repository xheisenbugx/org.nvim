-- The faces of dates and planning (org-date, org-special-keyword,
-- org-sexp-date) org.nvim's parser highlighter draws, against those Emacs
-- Org 9.8.12 draws on every fixture (tests/helpers/faces.lua).
local F = require("tests.helpers.faces")

local KNOWN = {
  ["tests-fixtures-emacs-faces-date.org"] = {
    -- A date right after "[" (a link's description "[<2026-...>]"): the
    -- matcher of org-activate-dates then returns nil, which ends the
    -- search for dates up to the end of the region font-lock is drawing
    -- (here the rest of the file, the fixture fontifies it at once; a
    -- jit-lock chunk in a window). An Emacs bug not worth copying:
    -- org.nvim leaves out only that date.
    [95] = "dates after a date that follows [",
  },
}

describe("emacs faces: date", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })
  F.spec("date", KNOWN)
end)
