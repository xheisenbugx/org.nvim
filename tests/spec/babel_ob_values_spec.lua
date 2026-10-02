-- Value conversion options of ob-python, ob-ruby and ob-lua
-- (*-hline-to, *-None-to, *-nil-to, lua multiple-values-separator and
-- command), checked against Emacs Org 9.8.10: the expected lines come from
-- `emacs --batch` (org-babel-execute-buffer) with the same options.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local function has(exe)
  return vim.fn.executable(exe) == 1
end

local TABLE = {
  "#+name: t",
  "| a | b |",
  "|---+---|",
  "| 1 | 2 |",
  "|---+---|",
  "| 3 | 4 |",
  "",
}

describe("babel value conversion options", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("python hline_to and None_to", function()
    if not has("python3") then
      return
    end
    h.set_lang("python", { hline_to = '"H"', None_to = "N" })
    local out = h.run(vim.list_extend(vim.deepcopy(TABLE), {
      "#+begin_src python :var x=t :hlines yes",
      "return [str(r) for r in x]",
      "#+end_src",
      "",
      "#+begin_src python",
      "return [1, None, 3]",
      "#+end_src",
    }))
    eq("| ['a', 'b'] | H | [1, 2] | H | [3, 4] |", out[13])
    eq("| 1 | N | 3 |", out[20])
  end)

  it("ruby hline_to and nil_to", function()
    if not has("ruby") then
      return
    end
    h.set_lang("ruby", { hline_to = '"R"', nil_to = "Z" })
    local out = h.run(vim.list_extend(vim.deepcopy(TABLE), {
      "#+begin_src ruby :var x=t :hlines yes",
      "x.map { |r| r.inspect }",
      "#+end_src",
      "",
      "#+begin_src ruby",
      "[1, nil, 3]",
      "#+end_src",
    }))
    eq('| ["a", "b"] | "R" | [1, 2] | "R" | [3, 4] |', out[13])
    eq("| 1 | Z | 3 |", out[20])
  end)

  local LUA_BLOCKS = {
    "#+begin_src lua :results output table",
    'print("[1, None, 3]")',
    "#+end_src",
    "",
    "#+begin_src lua",
    'return 1, "b", 3',
    "#+end_src",
    "",
    "#+begin_src lua",
    "return nil",
    "#+end_src",
    "",
    '#+begin_src lua :var t=(quote ("a" hline "c"))',
    "return tostring(t[2])",
    "#+end_src",
    "",
    "#+begin_src lua :return 5",
    "local z = 1",
    "#+end_src",
    "",
    "#+begin_src lua :results output",
    'print("hi")',
    'io.write("x")',
    "#+end_src",
  }
  -- Emacs 9.8.10 with org-babel-lua-None-to 'L and
  -- org-babel-lua-multiple-values-separator " | "
  local LUA_EXPECTED = {
    "#+begin_src lua :results output table",
    'print("[1, None, 3]")',
    "#+end_src",
    "",
    "#+RESULTS:",
    "| 1 | L | 3 |",
    "",
    "#+begin_src lua",
    'return 1, "b", 3',
    "#+end_src",
    "",
    "#+RESULTS:",
    ": 1 | b | 3",
    "",
    "#+begin_src lua",
    "return nil",
    "#+end_src",
    "",
    "#+RESULTS:",
    ": nil",
    "",
    '#+begin_src lua :var t=(quote ("a" hline "c"))',
    "return tostring(t[2])",
    "#+end_src",
    "",
    "#+RESULTS:",
    ": nil",
    "",
    "#+begin_src lua :return 5",
    "local z = 1",
    "#+end_src",
    "",
    "#+RESULTS:",
    ": 5",
    "",
    "#+begin_src lua :results output",
    'print("hi")',
    'io.write("x")',
    "#+end_src",
    "",
    "#+RESULTS:",
    ": hi",
    ": x",
  }

  it("lua in Neovim: hline_to (None, so nil), None_to, multiple_values_separator", function()
    h.set_lang("lua", { None_to = "L", multiple_values_separator = " | " })
    local out = h.run(LUA_BLOCKS)
    -- in Neovim `:return` is not supported: everything else as in Emacs
    local expected = vim.deepcopy(LUA_EXPECTED)
    eq(vim.list_slice(expected, 1, 27), vim.list_slice(out, 1, 27))
  end)

  it("lua with an external interpreter (cmd) like ob-lua", function()
    if not has("lua") then
      return
    end
    h.set_lang("lua", { cmd = "lua", None_to = "L", multiple_values_separator = " | " })
    eq(LUA_EXPECTED, h.run(LUA_BLOCKS))
  end)

  it("expands lua variables like org-babel-lua-var-to-lua", function()
    -- Emacs 9.8.10 (org-babel-expand-src-block)
    eq(
      table.concat({ "a=1", 'b="x\\"y"', 'c={1, "two", 3.5}', "d={a=1, b=2}", "e=7", "return a" }, "\n"),
      h.expand({
        [[#+begin_src lua :var a=1 b="x\"y" c='(1 "two" 3.5) d='(("a" 1) ("b" 2)) e='(7)]],
        "return a",
        "#+end_src",
      })
    )
  end)

  it("python sessions start session_cmd as it is (org-babel-python-command-session)", function()
    skip_on_windows("REPL sessions run in a terminal, which gets no input in headless Neovim on Windows")
    if not has("python3") then
      return
    end
    local dir = h.tmpdir()
    local log = dir .. "/log"
    local exe = h.fake(dir, "mypython", 'echo "$*" > ' .. log .. '\nexec python3 "$@"')
    h.set_lang("python", { session_cmd = exe .. " -i -q -u" })
    local out = h.run({ "#+begin_src python :session s1 :results value", "1 + 2", "#+end_src" }, dir)
    eq("#+RESULTS:", out[5])
    eq(": 3", out[6])
    eq({ "-i -q -u" }, vim.fn.readfile(log))
    require("org.babel.session").kill_all()
  end)
end)
