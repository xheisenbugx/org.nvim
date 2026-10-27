-- The faces of keywords, drawers and comments (the "meta" family of
-- tests/helpers/faces.lua) with the parser highlighter, against what Emacs
-- Org draws on each byte of the fixtures (tests/fixtures/emacs/faces/).
local F = require("tests.helpers.faces")
local P = require("tests.emacs_parity")

--- Fixture name -> { [line] = reason }: lines left out on purpose.
local KNOWN = {
  ["examples-14-footnotes.org"] = {
    -- (#+STARTUP in an org src block: Emacs's native fontification of
    -- the block, another highlighter's)
    [418] = "native fontification",
    [430] = "native fontification",
    [454] = "native fontification",
    [480] = "native fontification",
  },
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
}

--- The input lines of a fixture (its name with "-" for "/").
local function input(name)
  for _, dir in ipairs({ "examples", "tests/fixtures/emacs/fontify", "tests/fixtures/emacs/faces" }) do
    local prefix = dir:gsub("/", "-") .. "-"
    if name:sub(1, #prefix) == prefix then
      return vim.fn.readfile(P.root .. "/" .. dir .. "/" .. name:sub(#prefix + 1))
    end
  end
  return {}
end

--- Whether a line holds a face of this family that another part of the
--- parser highlighter draws: org-special-keyword on SCHEDULED:,
--- DEADLINE:, CLOSED: and CLOCK: (anywhere after a word boundary: the date
--- part) and on the COMMENT of a headline (the headline part), and
--- font-lock-comment-face on the @@ of export snippets and org-meta-line
--- on the language of inline src blocks (the object part).
--- (These lines are compared once the parts are merged.)
local function other_part(line)
  for _, w in ipairs({ "SCHEDULED:", "DEADLINE:", "CLOSED:", "CLOCK:" }) do
    if line:find("%f[%w_]" .. w) then
      return true
    end
  end
  return line:find("^%*+ .*COMMENT") ~= nil or line:find("@@", 1, true) ~= nil or line:find("%f[%w]src_%w") ~= nil
end

describe("Emacs faces: keywords, drawers and comments", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })
  local known = {}
  for _, fx in ipairs(F.fixtures()) do
    local k = vim.deepcopy(KNOWN[fx.name] or {})
    for l, line in ipairs(input(fx.name)) do
      if not k[l] and other_part(line) then
        k[l] = "another part's face"
      end
    end
    known[fx.name] = k
  end
  F.spec("meta", known)
end)
