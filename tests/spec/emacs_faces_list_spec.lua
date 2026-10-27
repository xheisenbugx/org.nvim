-- The faces of lists (org-checkbox, org-checkbox-statistics-todo / -done,
-- org-list-dt) that the parser highlighter draws, against what Emacs Org
-- 9.8.12 draws on every fixture (tests/helpers/faces.lua). Bullets have no
-- Emacs face.

local KNOWN = {
  ["tests-fixtures-emacs-faces-list.org"] = {
    -- the body of an org src block: Emacs fontifies it natively with Org's
    -- own font-lock; org.nvim gives src blocks of "org" no language syntax
    -- (org.syntax), and this part draws nothing in src blocks
    [55] = "native fontification of an org src block",
  },
}

describe("emacs faces: list", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })
  require("tests.helpers.faces").spec("list", KNOWN)
end)
