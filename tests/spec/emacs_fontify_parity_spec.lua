-- ui.highlighter = "parser" (org.ui.emphasis) against what Emacs Org 9.8.12
-- draws: emphasis faces and hidden emphasis markers and link brackets on
-- every byte of the example files and tests/fixtures/emacs/fontify/*.org,
-- with org-hide-emphasis-markers on (tests/fixtures/emacs/fontify/
-- expected.txt, scripts/emacs-parity/fontify.el).
local P = require("tests.emacs_parity")
local hl = require("tests.helpers.highlighter")

-- Known differences: file -> { [line] = reason }.
local KNOWN = {}

describe("emacs parity: emphasis faces and hidden text", function()
  with_config({ ui = { hide_emphasis_markers = true, highlighter = "parser" } })

  for _, sec in ipairs(P.sections(P.dir .. "/fontify/expected.txt")) do
    it(sec.name, function()
      local expected = {}
      for _, l in ipairs(sec.lines) do
        local n, runs = l:match("^(%d+)\t(.*)$")
        if n then
          expected[tonumber(n)] = hl.normalize_emacs(runs)
        end
      end
      local lines = vim.fn.readfile(P.root .. "/" .. sec.name)
      local buf = org_buffer(lines, { 1, 0 })
      vim.wo.conceallevel = 2
      local got = hl.emacs_codes(buf, "parser")
      local known = KNOWN[sec.name] or {}
      local diffs = {}
      for i = 1, #lines do
        if (expected[i] or "") ~= (got[i] or "") and not known[i] then
          diffs[#diffs + 1] =
            string.format("%d: %s\n  emacs:   %s\n  org.nvim: %s", i, lines[i], expected[i] or "-", got[i] or "-")
        end
      end
      eq(
        "",
        table.concat(diffs, "\n", 1, math.min(#diffs, 30)) .. (#diffs > 30 and ("\n... " .. #diffs .. " lines") or "")
      )
    end)
  end
end)
