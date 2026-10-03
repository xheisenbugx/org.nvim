-- Leaving Visual mode must not run the keys typed ahead. A command that
-- works on the selection leaves Visual mode and then prompts; the key for
-- the prompt is often already waiting (typed fast, a macro, a mapping),
-- and it must reach the prompt, not run as a Visual-mode command. Each
-- case sends the whole key sequence in one nvim_input, so every key after
-- the mapping is typeahead when the command runs.
local Screen = require("tests.screen")

local function run(lines, cursor, keys)
  local s = Screen.new({ width = 60, height = 12 })
  s:org(lines, { cursor = cursor })
  s:input(keys)
  local out = {
    lines = s:request("nvim_buf_get_lines", 0, 0, -1, false),
    mode = s:request("nvim_get_mode").mode,
    s = s,
  }
  return out
end

describe("leaving Visual mode keeps the typed-ahead keys", function()
  it("emphasize gets the marker typed with the mapping", function()
    local r = run({ "Plain text here" }, { 1, 0 }, "viw<Space>oE*")
    r.s:close()
    eq({ "*Plain* text here" }, r.lines)
    eq("n", r.mode)
  end)

  it("a macro that emphasizes words replays", function()
    local s = Screen.new({ width = 60, height = 12 })
    s:org({ "one two three four" }, { cursor = { 1, 0 } })
    s:input("qaviw<Space>oE*wq")
    s:input("2@a")
    local lines = s:request("nvim_buf_get_lines", 0, 0, -1, false)
    local mode = s:request("nvim_get_mode").mode
    s:close()
    eq({ "*one* *two* *three* four" }, lines)
    eq("n", mode)
  end)

  it("insert_structure_template gets the block key typed with the mapping", function()
    local r = run({ "one", "two" }, { 1, 0 }, "Vj<Space>oibq")
    r.s:close()
    eq({ "#+begin_quote", "one", "two", "#+end_quote" }, r.lines)
    eq("n", r.mode)
  end)

  it("change tag in region gets the menu key and the tag typed ahead", function()
    local r = run({ "* One", "* Two" }, { 1, 0 }, "Vj<C-c><C-q>awork<CR>")
    r.s:close()
    ok(r.lines[1]:match("^%* One%s+:work:$"), r.lines[1])
    ok(r.lines[2]:match("^%* Two%s+:work:$"), r.lines[2])
    eq("n", r.mode)
  end)

  it("utils.exit_visual sets the '< and '> marks and leaves the rest typed ahead", function()
    local s = Screen.new({ width = 60, height = 12 })
    s:org({ "abc def", "ghi jkl" }, { cursor = { 1, 1 } })
    s:lua([[vim.keymap.set("x", "Q", function()
      require("org.utils").exit_visual()
      _G.after = { mode = vim.fn.mode(), s = vim.fn.getpos("'<"), e = vim.fn.getpos("'>") }
    end)]])
    s:input("vjlQx")
    local after = s:lua("return _G.after")
    local lines = s:request("nvim_buf_get_lines", 0, 0, -1, false)
    s:close()
    eq("n", after.mode)
    eq({ 1, 2 }, { after.s[2], after.s[3] })
    eq({ 2, 3 }, { after.e[2], after.e[3] })
    -- x ran in Normal mode after the mapping: one character deleted
    eq({ "abc def", "gh jkl" }, lines)
  end)
end)
