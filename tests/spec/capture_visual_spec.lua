-- Capture from Visual mode with real keys: the global capture keys work on
-- a selection (Emacs org-capture uses the active region for %i) instead of
-- falling through to Normal-mode keys that change the selected text.
local Screen = require("tests.screen")

describe("capture from Visual mode", function()
  local target

  local function start()
    target = vim.fn.tempname() .. ".org"
    vim.fn.writefile({ "* Inbox" }, target)
    return Screen.new({
      width = 80,
      height = 20,
      setup = {
        capture = {
          templates = {
            t = { description = "Quote", target = target, template = "* Q\n%i", immediate_finish = false },
          },
        },
      },
    })
  end

  -- select the second line with V, press `keys`, choose the template
  local function capture_line(screen, keys, file)
    if file then
      screen:lua("local f, l = ...; vim.fn.writefile(l, f); vim.cmd.edit(f)", file, { "one", "two words", "three" })
    else
      screen:org({ "* Notes", "two words", "three" })
    end
    screen:lua("vim.api.nvim_win_set_cursor(0, { 2, 0 })")
    screen:input("V" .. keys)
    screen:input("t")
    return screen:lua([[
      local source = vim.fn.bufnr("#")
      return {
        capture = vim.api.nvim_buf_get_lines(0, 0, -1, false),
        line = vim.api.nvim_buf_get_lines(source, 1, 2, false)[1],
        modified = vim.bo[source].modified,
        mode = vim.api.nvim_get_mode().mode,
      }]])
  end

  for _, keys in ipairs({ "<Space>oc", "<C-c>c" }) do
    it(keys .. " captures the selected line as %i and leaves it alone", function()
      local screen = start()
      local st = capture_line(screen, keys)
      screen:close()
      eq({ "* Q", "two words" }, st.capture)
      eq("two words", st.line)
      eq(false, st.modified)
      eq("n", st.mode)
    end)
  end

  it("works in a buffer that is not org", function()
    local screen = start()
    local st = capture_line(screen, "<Space>oc", vim.fn.tempname() .. ".txt")
    screen:close()
    eq({ "* Q", "two words" }, st.capture)
    eq("two words", st.line)
    eq(false, st.modified)
  end)
end)
