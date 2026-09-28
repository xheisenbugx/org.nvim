-- org-footnote-fill-after-inline-note-extraction. Expected buffers from
-- Emacs 9.8.10 (org-footnote-normalize, fill-column 70).
local fn = require("org.footnotes")
local config = require("org.config")
vim.g.org_test = true

local INPUT = {
  "* Heading",
  "This is a fairly long paragraph line that has an inline footnote[fn:: The inline note text that is rather long too.] and continues after it",
  "with a second line of text.  Two spaces here.",
  "",
  "Second paragraph stays   as is.",
}

describe("footnote_fill_after_inline_note_extraction", function()
  after_each(function()
    config.setup({})
  end)

  it("leaves the paragraph alone by default", function()
    config.setup({})
    local buf = org_buffer(vim.deepcopy(INPUT))
    fn.normalize(buf)
    eq({
      "* Heading",
      "This is a fairly long paragraph line that has an inline footnote[fn:1] and continues after it",
      "with a second line of text.  Two spaces here.",
      "",
      "Second paragraph stays   as is.",
      "",
      "* Footnotes",
      "",
      "[fn:1] The inline note text that is rather long too.",
    }, buf_lines(buf))
  end)

  it("refills the paragraph the note came from", function()
    config.setup({ footnote_fill_after_inline_note_extraction = true })
    local buf = org_buffer(vim.deepcopy(INPUT))
    vim.bo[buf].textwidth = 0
    fn.normalize(buf)
    eq({
      "* Heading",
      "This is a fairly long paragraph line that has an inline footnote[fn:1]",
      "and continues after it with a second line of text.  Two spaces here.",
      "",
      "Second paragraph stays   as is.",
      "",
      "* Footnotes",
      "",
      "[fn:1] The inline note text that is rather long too.",
    }, buf_lines(buf))
  end)
end)
