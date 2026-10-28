-- The faces of lists (org-checkbox, org-checkbox-statistics-todo / -done,
-- org-list-dt) that the parser highlighter draws, against what Emacs Org
-- 9.8.12 draws on every fixture (tests/helpers/faces.lua). Bullets have no
-- Emacs face.

local KNOWN = {}

describe("emacs faces: list", function()
  with_config({ ui = { hide_emphasis_markers = true } })
  require("tests.helpers.faces").spec("list", KNOWN)
end)
