-- ui.highlighter = "parser" (org.ui.highlight.object) against every face
-- Emacs Org 9.8.12 draws, for the object family: links, footnotes,
-- targets, macros, inline src blocks, citations and hidden text
-- (tests/helpers/faces.lua, tests/fixtures/emacs/faces/expected/).

-- Known differences: fixture -> { [line] = reason }.
local KNOWN = {
  ["examples-13-links.org"] = {
    -- man: is an org.nvim link type; Emacs knows it only with ol-man
    -- loaded, which org doesn't do by default
    [456] = "man: links",
  },
  ["examples-17-babel.org"] = {
    -- a json src block: Vim's json syntax conceals the quotes
    -- (g:vim_json_conceal), Emacs shows them
    [574] = "the json syntax",
  },
  ["tests-fixtures-emacs-faces-object.org"] = {
    -- after a macro with no "}}}" before an empty line, org-fontify-macros
    -- returns nil and font-lock stops looking for macros in the region it
    -- fontifies (the whole buffer here, a jit-lock chunk when editing):
    -- org.nvim goes on to the macros after it
    [81] = "macros after an unclosed one",
  },
}

describe("emacs parity: object faces", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })
  require("tests.helpers.faces").spec("object", KNOWN)
end)
