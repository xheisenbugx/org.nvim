-- The faces of blocks and LaTeX (org-block, org-block-begin-line /
-- -end-line, org-quote, org-verse, org-latex-and-related) drawn by the
-- parser highlighter (org.ui.highlight.block), against Emacs Org 9.8.12
-- byte by byte (tests/helpers/faces.lua, tests/fixtures/emacs/faces/;
-- tests/fixtures/emacs/faces/block.org holds the hard cases).
local F = require("tests.helpers.faces")
local P = require("tests.emacs_parity")

-- fixture -> { [line] = why it differs }
local KNOWN = {
  ["examples-17-babel.org"] = {
    -- a json src block: Vim's json syntax conceals the quotes, and a
    -- hidden byte shows no face
    [574] = "json syntax conceal",
  },
}

--- Lines owned by another part, left out until the parts are merged:
--- inline src blocks (`src_LANG{...}`, the object part), whose body Emacs
--- draws in org-block (org-fontify-inline-src-blocks-1 fontifies it as a
--- src block).
local function other_part(line)
  return line:find("src_[^ \t\n[{]+[[{]") ~= nil
end

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

  local known = {}
  for _, fx in ipairs(F.fixtures()) do
    local k = vim.deepcopy(KNOWN[fx.name] or {})
    for _, dir in ipairs({ "examples", "tests/fixtures/emacs/fontify", "tests/fixtures/emacs/faces" }) do
      local prefix = dir:gsub("/", "-") .. "-"
      if fx.name:sub(1, #prefix) == prefix then
        local path = P.root .. "/" .. dir .. "/" .. fx.name:sub(#prefix + 1)
        for i, line in ipairs(vim.fn.readfile(path)) do
          if other_part(line) then
            k[i] = k[i] or "inline src block (object part)"
          end
        end
        break
      end
    end
    known[fx.name] = k
  end
  F.spec("block", known)
end)
