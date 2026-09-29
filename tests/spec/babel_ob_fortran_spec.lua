-- ob-fortran, checked against Emacs Org 9.8.10 with gfortran: the
-- expansions (org-babel-expand-src-block) and results
-- (org-babel-execute-buffer) come from `emacs --batch`.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local BLOCKS = {
  "#+begin_src fortran",
  'print *, "hello"',
  "#+end_src",
  "",
  '#+begin_src fortran :var n=5 x=2.5 s="abc" :prologue "! pro" :epilogue "! epi"',
  "print *, n, x, s",
  "#+end_src",
  "",
  "#+begin_src fortran :var v='(1 2 3) m='((1 2) (3 4))",
  "print *, v(2), m(2,1)",
  "#+end_src",
  "",
  "#+begin_src fortran :main no",
  "program p",
  "print *, 42",
  "end program p",
  "#+end_src",
  "",
  "#+begin_src fortran :results table",
  "print *, 1, 2",
  "print *, 3, 4",
  "#+end_src",
  "",
  '#+begin_src fortran :flags -O2 :cmdline "a b"',
  "character(len=10) :: arg",
  "call get_command_argument(2, arg)",
  "write (*,'(A)') trim(arg)",
  "#+end_src",
  "",
  '#+begin_src fortran :includes \'("a.h" "b.h") :defines "X 1" :main no',
  "! nothing",
  "#+end_src",
}

describe("babel ob-fortran", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)

  it("expands like org-babel-expand-body:fortran", function()
    eq('\n\nprogram main\nprint *, "hello"\nend program main\n\n\n', h.expand(BLOCKS, 1))
    eq(
      table.concat({
        "",
        "",
        "program main",
        "integer, parameter  ::  n = 5",
        "",
        "real, parameter ::  x = 2.5",
        "",
        "character(len=3), parameter ::  s = 'abc'",
        "! pro",
        "print *, n, x, s! pro",
        "",
        "end program main",
        "",
        "",
        "",
      }, "\n"),
      h.expand(BLOCKS, 2)
    )
    eq(
      table.concat({
        "",
        "",
        "program main",
        "real, parameter :: v(3) = (/1, 2, 3/)",
        "",
        "real, parameter :: m(2,2) = transpose( reshape( (/(/1, 2/), (/3, 4/)/) , (/ 2, 2 /) ) )",
        "print *, v(2), m(2,1)",
        "end program main",
        "",
        "",
        "",
      }, "\n"),
      h.expand(BLOCKS, 3)
    )
    eq("\n\nprogram p\nprint *, 42\nend program p\n\n", h.expand(BLOCKS, 4))
    eq("#include a.h\n#include b.h\n#define X 1\n! nothing\n\n", h.expand(BLOCKS, 7))
  end)

  it("compiles with gfortran and reads the output", function()
    if vim.fn.executable("gfortran") == 0 then
      return
    end
    local out = h.run(BLOCKS)
    local function result(head)
      for i, l in ipairs(out) do
        if l == head then
          local k = i
          while out[k] ~= "#+RESULTS:" do
            k = k + 1
          end
          local res = {}
          k = k + 1
          while out[k] and out[k] ~= "" do
            res[#res + 1] = out[k]
            k = k + 1
          end
          return res
        end
      end
    end
    eq({ ": hello" }, result(BLOCKS[1]))
    eq({ ": 5   2.50000000     abc" }, result(BLOCKS[5]))
    eq({ ": 2.00000000       3.00000000" }, result(BLOCKS[9]))
    eq({ ": 42" }, result(BLOCKS[13]))
    eq({ "| 1 | 2 |", "| 3 | 4 |" }, result(BLOCKS[19]))
    eq({ ": b" }, result(BLOCKS[24]))
  end)
end)
