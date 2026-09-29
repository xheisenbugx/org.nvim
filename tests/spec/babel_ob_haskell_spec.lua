-- ob-haskell, checked against Emacs Org 9.8.10 (`emacs --batch`):
-- expansions (org-babel-expand-src-block), `:compile yes` results with the
-- same fake ghc (GHC is not installed) and org-babel-haskell-export-to-lhs.
-- Emacs interprets blocks in an inf-haskell session (haskell-mode, not
-- available in batch); ghci is replaced by a fake that answers like it.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local FAKE_GHC = [[
echo "ghc $*" >> "$(dirname "$0")/ghc.log"
bin=$2
printf '#!/bin/sh\necho "  [1, 2]"\necho "  args: $*"\n' > "$bin"
chmod +x "$bin"]]

describe("babel ob-haskell", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("expands variables as let bindings", function()
    -- Emacs 9.8.10
    eq(
      'let x = 1\nlet l = [1, 2]\nlet s = "a"\nx + 1',
      h.expand({ '#+begin_src haskell :var x=1 l=\'(1 2) s="a"', "x + 1", "#+end_src" })
    )
  end)

  it("compiles with ghc for :compile yes", function()
    local dir = h.tmpdir()
    h.set_lang("haskell", { compiler = h.fake(dir, "ghc", FAKE_GHC) })
    local out = h.run({
      '#+begin_src haskell :compile yes :flags -O2 :cmdline "a b"',
      "main = print [1, 2]",
      "#+end_src",
      "",
      "#+begin_src haskell :compile yes :results table",
      "main = print [1, 2]",
      "#+end_src",
    }, dir)
    -- Emacs 9.8.10
    eq({
      '#+begin_src haskell :compile yes :flags -O2 :cmdline "a b"',
      "main = print [1, 2]",
      "#+end_src",
      "",
      "#+RESULTS:",
      "| [1,   | 2] |   |",
      "| args: | a  | b |",
      "",
      "#+begin_src haskell :compile yes :results table",
      "main = print [1, 2]",
      "#+end_src",
      "",
      "#+RESULTS:",
      "| [1,   | 2] |",
      "| args: |    |",
    }, out)
    local log = vim.fn.readfile(dir .. "/ghc.log")
    ok(log[1]:match("^ghc %-o %S+ %-O2 %S+%.hs$"))
  end)

  it("sends the block to ghci and reads the value between markers", function()
    local dir = h.tmpdir()
    -- a ghci answering like the real one: the value of each expression
    local ghci = h.fake(
      dir,
      "ghci",
      table.concat({
        "cat > " .. dir .. "/input",
        'echo "ghci> ghci> ghci> ghci> org-babel-haskell-eoe"',
        'echo "ghci> [1,2,3]"',
        'echo "ghci> org-babel-haskell-eoe"',
        'echo "ghci> "',
      }, "\n")
    )
    h.set_lang("haskell", { cmd = ghci })
    local out = h.run({ "#+begin_src haskell :var n=3", "[1..n]", "#+end_src" }, dir)
    eq({ "#+RESULTS:", "| 1 | 2 | 3 |" }, vim.list_slice(out, 5, 6))
    eq({
      ':set prompt-cont ""',
      "__LAST_VALUE_IMPROBABLE_NAME__=()::()",
      "let n = 3",
      "[1..n]",
      "__LAST_VALUE_IMPROBABLE_NAME__=it",
      'putStrLn "org-babel-haskell-eoe"',
      "__LAST_VALUE_IMPROBABLE_NAME__",
      'putStrLn "org-babel-haskell-eoe"',
    }, vim.fn.readfile(dir .. "/input"))
    local hs = require("org.babel.lang.haskell")
    eq("hi\nthere", hs.parse('ghci> hi\n"there"\nghci> org-babel-haskell-eoe\nghci> ', false))
  end)

  it("exports to .lhs (org-babel-haskell-export-to-lhs)", function()
    local dir = h.tmpdir()
    local buf = org_buffer({
      "#+title: Hs",
      "",
      "Some text.",
      "",
      "#+begin_src haskell :var x=1",
      "x + 1",
      "#+end_src",
      "",
      "  #+begin_src haskell",
      "    main = print 1",
      "      where y = 2",
      "  #+end_src",
    }, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/hs.org")
    local lhs = require("org.babel.lang.haskell").export_to_lhs()
    eq(dir .. "/hs.lhs", lhs)
    local l = vim.fn.readfile(lhs)
    -- Emacs 9.8.10: %include polycode.fmt as the third line, the blocks as
    -- code environments at the first column
    eq("%include polycode.fmt", l[3])
    local text = table.concat(l, "\n")
    ok(text:find("\\begin{code}\nx + 1\n\\end{code}", 1, true))
    ok(text:find("\\begin{code}\nmain = print 1\n  where y = 2\n\\end{code}", 1, true))
  end)
end)
