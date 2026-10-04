-- Dot-repeat (.) of org editing keys: a repeatable action registers itself
-- with Vim's redo, so "." runs it again at the cursor, with the same count
-- or a new one.
local function keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end

describe("dot-repeat", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" } })

  it("repeats a heading demotion on the next heading", function()
    local buf = org_buffer({ "* A", "** B", "** C" }, { 2, 0 })
    keys(">>")
    keys("j.")
    eq({ "* A", "*** B", "*** C" }, buf_lines(buf))
  end)

  it("repeats a TODO cycle and keeps the undo steps apart", function()
    local buf = org_buffer({ "* A", "* B", "* C" }, { 1, 0 })
    keys("cit")
    keys("j.")
    keys("j.")
    eq({ "* TODO A", "* TODO B", "* TODO C" }, buf_lines(buf))
    keys("u")
    eq({ "* TODO A", "* TODO B", "* C" }, buf_lines(buf))
  end)

  it("repeats with the original count, or the count given to .", function()
    local buf = org_buffer({ "* A", "* B", "* C", "* D" }, { 1, 0 })
    keys("2>>")
    keys("j.")
    keys("j3.")
    eq({ "*** A", "*** B", "**** C", "* D" }, buf_lines(buf))
  end)

  it("repeats a checkbox toggle", function()
    local buf = org_buffer({ "* H", "- [ ] a", "- [ ] b" }, { 2, 0 })
    keys("<C-Space>")
    keys("j.")
    eq({ "* H", "- [X] a", "- [X] b" }, buf_lines(buf))
  end)

  it("repeats moving a subtree down", function()
    local buf = org_buffer({ "* A", "* B", "* C" }, { 1, 0 })
    keys("<M-j>")
    keys(".")
    eq({ "* B", "* C", "* A" }, buf_lines(buf))
  end)

  it("works on folded subtrees and keeps the cursor where it was", function()
    local buf = org_buffer({ "* A", "text a", "* B", "text b" }, { 1, 2 })
    vim.cmd("normal! zMgg")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    keys(">>")
    eq({ 1, 2 }, { vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_win_get_cursor(0)[2] - 1 })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    keys(".")
    eq({ "** A", "text a", "** B", "text b" }, buf_lines(buf))
    eq(1, vim.fn.foldclosed(1))
  end)

  it("leaves . to Vim when the key fell back to its default", function()
    local buf = org_buffer({ "text", "more" }, { 1, 0 })
    vim.bo[buf].shiftwidth = 2
    keys(">>")
    keys("j.")
    eq({ "  text", "  more" }, buf_lines(buf))
  end)

  it("does not register actions that are not repeatable", function()
    local buf = org_buffer({ "* A", "** B", "* C" }, { 2, 0 })
    keys(">>")
    -- cycling visibility is not an edit: . still repeats the demotion
    keys("<Tab>")
    keys("j.")
    eq({ "* A", "*** B", "** C" }, buf_lines(buf))
  end)
end)
