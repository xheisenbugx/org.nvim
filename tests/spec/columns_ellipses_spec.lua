-- org-columns-ellipses. Expected values from Emacs Org 9.8.10
-- (org-columns-add-ellipses).

local columns = require("org.columns")

describe("columns: columns_ellipses", function()
  it('ends truncated fields with ".." by default', function()
    eq("Hea..", columns.add_ellipses("Headline", 5))
    eq(".", columns.add_ellipses("Headline", 1))
    eq("Head", columns.add_ellipses("Head", 4))
  end)
end)

describe("columns: columns_ellipses custom", function()
  with_config({ columns_ellipses = "…" })
  it("uses the option", function()
    eq("Head…", columns.add_ellipses("Headline", 5))
  end)
end)
