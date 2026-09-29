-- ob-clojure (babashka, clojure-cli and nbb backends), checked against
-- Emacs Org 9.8.10 (`emacs --batch`): expansions from
-- org-babel-expand-src-block and results from org-babel-execute-buffer with
-- the same fake `bb` (babashka, clojure and nbb are not installed). The
-- fake prints [1 "a b" 3] for a value block, else the script.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local FAKE_BB = [[
if grep -q '^(prn \|(pprint ' "$1"; then cat "$1" > "$(dirname "$0")/bb.log"; echo '[1 "a b" 3]'; else cat "$1"; echo; fi]]

local BLOCKS = {
  "#+begin_src clojure :backend babashka :results output",
  '(println "hi")',
  "#+end_src",
  "",
  '#+begin_src clojure :backend babashka :var x=1 y=\'(1 "a") :ns my.ns',
  ";; comment",
  "(+ x 1)",
  "#+end_src",
  "",
  "#+begin_src clojure :backend babashka :results pp",
  "{:a 1}",
  "#+end_src",
  "",
  "#+begin_src clojurescript :backend nbb",
  "(+ 1 2)",
  "#+end_src",
}

describe("babel ob-clojure", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("expands like org-babel-expand-body:clojure", function()
    eq('(println "hi")', h.expand(BLOCKS, 1))
    eq(
      "(prn (binding [*out* (java.io.StringWriter.)](ns my.ns)\n(let [x '1\n      y '(1 \"a\")]\n\n(+ x 1))))",
      h.expand(BLOCKS, 2)
    )
    eq(
      "(require '[clojure.pprint :refer [pprint]]) (pprint (binding [*out* (java.io.StringWriter.)]{:a 1}))",
      h.expand(BLOCKS, 3)
    )
    eq("(+ 1 2)", h.expand(BLOCKS, 4))
  end)

  it("runs the backend's command on a script file", function()
    local dir = h.tmpdir()
    local bb = h.fake(dir, "bb", FAKE_BB)
    h.set_lang("clojure", { babashka_command = bb, nbb_command = bb })
    local out = h.run(BLOCKS, dir)
    eq({ "#+RESULTS:", ': (println "hi")' }, vim.list_slice(out, 5, 6))
    eq({ "#+RESULTS:", ': [1 "a b" 3]' }, vim.list_slice(out, 13, 14))
    eq({ "#+RESULTS:", ': [1 "a b" 3]' }, vim.list_slice(out, 20, 21))
    eq({ "#+RESULTS:", ': [1 "a b" 3]' }, vim.list_slice(out, 27, 28))
    -- nbb: ClojureScript printing
    eq({ "(prn (binding [cljs.core/*print-fn* (constantly nil)](+ 1 2)))" }, vim.fn.readfile(dir .. "/bb.log"))
  end)

  it("needs a backend", function()
    h.set_lang("clojure", { backend = false })
    local m = require("org.babel.lang.clojure")
    local exe = vim.fn.exepath("bb") ~= "" or vim.fn.exepath("clojure") ~= ""
    if not exe then
      eq(nil, m.backend())
      local out = h.run({ "#+begin_src clojure", "(+ 1 2)", "#+end_src" })
      eq(3, #out)
    end
    h.set_lang("clojure", { backend = "clojure-cli", cli_command = "myclj -M" })
    eq("clojure-cli", m.backend())
    eq("myclj -M", m.command("clojure-cli"))
  end)
end)
