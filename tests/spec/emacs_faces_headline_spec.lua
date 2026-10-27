-- The headline faces org.nvim draws with the parser highlighter (levels,
-- TODO keywords, priorities, tags, COMMENT, ARCHIVE, inline tasks), byte
-- by byte against Emacs Org 9.8.12 (tests/helpers/faces.lua).
local F = require("tests.helpers.faces")

--- Lines left out, per fixture: line -> reason.
local KNOWN = {}

describe("Emacs faces: headline", function()
  -- (inlinetask_min_level: the fixtures are made with org-inlinetask
  -- loaded, whose minimum level is 15)
  with_config({ inlinetask_min_level = 15, ui = { highlighter = "parser", hide_emphasis_markers = true } })
  F.spec("headline", KNOWN)
end)
