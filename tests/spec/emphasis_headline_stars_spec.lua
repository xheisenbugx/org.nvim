-- Headline stars and emphasis (#118): the stars never open bold markup.
local hl = require("tests.helpers.highlighter")

describe("emphasis and headline stars", function()
  with_config({ ui = { hide_emphasis_markers = true } })

  -- Emacs `org-do-emphasis-faces`: "Do not match headline stars."
  it("doesn't treat headline stars as bold markers", function()
    org_buffer({ "*** WAITING Level three", "**** TODO Level four", "*** KPI Warnings" }, { 1, 0 })
    vim.wo.conceallevel = 2
    for l = 1, 3 do
      local stars = #buf_lines()[l]:match("^%*+")
      for c = 1, stars + 2 do
        ok(not hl.has(l, c, "orgbold"), l .. ":" .. c .. " " .. hl.groups(l, c))
        ok(not hl.has(l, c, "conceal"), l .. ":" .. c .. " " .. hl.groups(l, c))
      end
    end
  end)

  it("still highlights bold in a headline and at the start of a line", function()
    org_buffer({ "*** *bold* title", "*bold* text" }, { 1, 0 })
    vim.wo.conceallevel = 2
    ok(hl.has(1, 6, "orgbold"), hl.groups(1, 6))
    ok(hl.has(1, 5, "conceal"), hl.groups(1, 5))
    ok(hl.has(2, 2, "orgbold"), hl.groups(2, 2))
    ok(hl.has(2, 1, "conceal"), hl.groups(2, 1))
  end)
end)
