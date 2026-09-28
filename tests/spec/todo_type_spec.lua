-- #+TYP_TODO / (type ...) sequences; expectations from Emacs Org 9.8.10
-- org-todo run in batch with this-command / last-command set by hand.
local todo = require("org.todo")
local todo_keywords = require("org.todo_keywords")

local function heading(buf)
  return buf_lines(buf)[2]
end

--- Run C-c C-t `n` times without repetition: an edit between two presses
--- makes each one a fresh command.
local function fresh_presses(buf, n)
  local out = {}
  for _ = 1, n do
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
    todo.select_or_cycle(nil, nil)
    out[#out + 1] = heading(buf)
  end
  return out
end

describe("TYP_TODO type sequences", function()
  with_config({ log_done = false })

  it("jumps from any type straight to DONE, then to no keyword", function()
    local buf = org_buffer({ "#+TYP_TODO: Fred Sara Lucy | DONE", "* A" }, { 2, 0 })
    eq({ "* Fred A", "* DONE A", "* A", "* Fred A" }, fresh_presses(buf, 4))
    buf = org_buffer({ "#+TYP_TODO: Fred Sara Lucy | DONE", "* Sara A" }, { 2, 0 })
    eq({ "* DONE A", "* A" }, fresh_presses(buf, 2))
  end)

  it("walks the names when C-c C-t is repeated", function()
    local buf = org_buffer({ "#+TYP_TODO: Fred Sara Lucy | DONE", "* A" }, { 2, 0 })
    local out = {}
    for _ = 1, 6 do
      todo.select_or_cycle(nil, nil)
      out[#out + 1] = heading(buf)
    end
    eq({ "* Fred A", "* Sara A", "* Lucy A", "* DONE A", "* A", "* Fred A" }, out)
  end)

  it("moving the cursor ends a repetition", function()
    local buf = org_buffer({ "#+TYP_TODO: Fred Sara Lucy | DONE", "* A" }, { 2, 0 })
    todo.select_or_cycle(nil, nil)
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    todo.select_or_cycle(nil, nil)
    eq("* DONE A", heading(buf))
  end)

  it("stays on a DONE keyword that is not the last one", function()
    local buf = org_buffer({ "#+TYP_TODO: Fred | DONE CANCELED", "* DONE A" }, { 2, 0 })
    eq({ "* DONE A", "* DONE A" }, fresh_presses(buf, 2))
  end)

  it("S-right / S-left walk every keyword like other sequences", function()
    local buf = org_buffer({ "#+TYP_TODO: Fred Sara Lucy | DONE", "* A" }, { 2, 0 })
    local out = {}
    for _, dir in ipairs({ 1, 1, 1, 1, 1, -1, -1 }) do
      if dir > 0 then
        todo.cycle_next()
      else
        todo.cycle_prev()
      end
      out[#out + 1] = heading(buf)
    end
    eq({ "* Fred A", "* Sara A", "* Lucy A", "* DONE A", "* A", "* DONE A", "* Lucy A" }, out)
  end)

  it("orders TYP_TODO first, then TODO, then SEQ_TODO lines, like Emacs", function()
    local buf = org_buffer({ "#+TODO: TODO | DONE", "#+TYP_TODO: Fred Sara | FIN", "* A" }, { 3, 0 })
    local out = {}
    for _ = 1, 5 do
      todo.cycle_next()
      out[#out + 1] = buf_lines(buf)[3]
    end
    eq({ "* Fred A", "* Sara A", "* FIN A", "* TODO A", "* DONE A" }, out)
    buf = org_buffer({ "#+SEQ_TODO: A B | C", "#+TODO: X | Y", "* H" }, { 3, 0 })
    todo.cycle_next()
    eq("* X H", buf_lines(buf)[3])
  end)

  it("accepts { type = ... } in todo_keywords", function()
    local cfg = todo_keywords.new({ { type = "Fred Sara | DONE" }, "TODO | OK" })
    eq("type", cfg:get("Sara").seq_type)
    eq("sequence", cfg:get("OK").seq_type)
    eq("DONE", cfg:cycle("Sara", 1))
    eq("DONE", cfg:cycle("Fred", 1))
    eq("Sara", cfg:cycle("Fred", 1, nil, true))
    eq(nil, cfg:cycle("DONE", 1))
    eq("OK", cfg:cycle("TODO", 1))
  end)

  describe("in todo_keywords", function()
    with_config({ todo_keywords = { { type = "Fred Sara | DONE" }, "TODO | OK" } })

    it("C-c C-t follows the type rules", function()
      local buf = org_buffer({ "", "* Sara A" }, { 2, 0 })
      eq({ "* DONE A", "* A", "* Fred A" }, fresh_presses(buf, 3))
    end)
  end)
end)
