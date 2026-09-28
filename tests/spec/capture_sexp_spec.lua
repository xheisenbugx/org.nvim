-- Capture template %(sexp) (org-capture-expand-embedded-elisp). Expected
-- values were produced by Emacs 31 / Org 9.8.10 in batch with
-- (org-capture-fill-template TEMPLATE "init \"q\"") and org-store-link-plist
-- (:subject "Hello \"world\"" :link "https://x.org" :description "X").
-- Forms the Lisp interpreter doesn't implement run in an external Emacs:
-- those tests are skipped without an `emacs` executable.
local capture = require("org.capture")
local config = require("org.config")
local utils = require("org.utils")

local function has_emacs()
  return require("org.babel.elisp").command() ~= nil
end

local ctx = {
  initial = 'init "q"',
  keywords = { subject = 'Hello "world"', link = "https://x.org", description = "X" },
}

local function expand(template)
  local res
  local finished = utils.run(function()
    res = capture.expand(template, vim.deepcopy(ctx))
  end)
  ok(finished, "coroutine did not finish")
  return res
end

describe("capture %(sexp)", function()
  local saved
  before_each(function()
    saved = vim.deepcopy(config.opts.babel.emacs_lisp)
  end)
  after_each(function()
    config.opts.babel.emacs_lisp = saved
  end)

  it("evaluates Emacs Lisp with the escapes expanded and quoted", function()
    config.opts.babel.emacs_lisp.command = false
    eq('A INIT "Q" B', expand('A %(upcase "%i") B'))
    eq('<Hello "world">', expand('%(concat "<" "%:subject" ">")'))
    eq("1970-01-01", expand('%(format-time-string "%Y-%m-%d" 0 t)'))
    eq("[]", expand("[%(identity nil)]"))
    eq("X", expand('%(capitalize "%:description")'))
    eq(
      "c.org c gz",
      expand('%(file-name-nondirectory "/a/b/c.org") %(file-name-base "/a/b/c.org") %(file-name-extension "x.tar.gz")')
    )
    eq("f00 b00", expand('%(replace-regexp-in-string "o" "0" "foo boo")'))
  end)

  it("inserts an error for forms that fail", function()
    config.opts.babel.emacs_lisp.command = false
    eq("%![Error: (void-function undefined-fn)]", expand("%(undefined-fn 1)"))
  end)

  it("still evaluates Lua expressions", function()
    config.opts.babel.emacs_lisp.command = false
    eq("3 X", expand("%(1 + 2) %(string.upper('x'))"))
    eq(os.date("%Y"), expand('%(os.date("%Y"))'))
  end)

  it("runs in Emacs what the interpreter does not implement", function()
    if not has_emacs() then
      return
    end
    eq("gro.x//:sptth", expand('%(string-reverse "%:link")'))
    eq("%![Error: (void-function undefined-fn)]", expand("%(undefined-fn 1)"))
  end)
end)
