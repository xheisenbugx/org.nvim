describe("emphasis syntax", function()
  with_config({ ui = { hide_emphasis_markers = true } })

  local function groups(l, c)
    return table.concat(
      vim.tbl_map(function(id)
        return vim.fn.synIDattr(id, "name"):lower()
      end, vim.fn.synstack(l, c)),
      " "
    )
  end

  -- Emacs `org-do-emphasis-faces`: "Do not match headline stars."
  it("doesn't treat headline stars as bold markers", function()
    org_buffer({ "*** WAITING Level three", "**** TODO Level four", "*** KPI Warnings" }, { 1, 0 })
    for l = 1, 3 do
      local stars = #buf_lines()[l]:match("^%*+")
      for c = 1, stars + 2 do
        ok(not groups(l, c):find("orgbold"), l .. ":" .. c .. " " .. groups(l, c))
        eq(0, vim.fn.synconcealed(l, c)[1])
      end
    end
  end)

  it("still highlights bold in a headline and at the start of a line", function()
    org_buffer({ "*** *bold* title", "*bold* text" }, { 1, 0 })
    ok(groups(1, 6):find("orgbold"), groups(1, 6))
    eq(1, vim.fn.synconcealed(1, 5)[1])
    ok(groups(2, 2):find("orgbold"), groups(2, 2))
    eq(1, vim.fn.synconcealed(2, 1)[1])
  end)
end)
