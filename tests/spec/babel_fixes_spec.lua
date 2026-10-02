local babel = require("org.babel")
local blocks = require("org.babel.blocks")
local config = require("org.config")

describe("babel block switches", function()
  it("keeps the header arguments after a -l format containing a colon", function()
    local b =
      blocks.parse_blocks({ '#+begin_src sh -n 10 -r -l "(ref:%s)" :results output', "echo hi", "#+end_src" })[1]
    eq('-n 10 -r -l "(ref:%s)"', b.switches)
    eq(":results output", b.params)
    eq("output", blocks.header_args(b, nil).results_spec.collection)
    eq("(ref:%s)", blocks.coderef_format(b.switches))
  end)

  it("splits switches like the org-element src-block parser", function()
    eq({ "", ":var x=1" }, { blocks.split_switches(":var x=1") })
    eq({ "-i +n", ":tangle yes" }, { blocks.split_switches("-i +n :tangle yes") })
    eq({ "", "-x :tangle yes" }, { blocks.split_switches("-x :tangle yes") })
    eq({ "-k", "" }, { blocks.split_switches("-k") })
  end)
end)

describe("babel sql engines", function()
  it("passes mssql/sqsh connection values as single shell words", function()
    local langs = require("org.babel.langs")
    for _, engine in ipairs({ "mssql", "sqsh" }) do
      local args = blocks.header_args({
        params = ":engine " .. engine .. ' :dbhost my-host :dbuser u :dbpassword "p w" :database d',
        header_lines = {},
        start = 1,
        lang = "sql",
      }, nil)
      local cmd = langs.prepare("sql", { "select 1;" }, args, {}, { cmd = {}, ext = "sql" }).steps[1].cmd
      ok(cmd:find("-S 'my-host' -U 'u' -P 'p w' -", 1, true), cmd)
      ok(not cmd:find("\"'", 1, true), cmd)
    end
  end)
end)

describe("babel noweb strip-tangle", function()
  local function tangled(lines)
    local buf = org_buffer(lines)
    local groups, order = require("org.babel.tangle").collect(buf, {})
    return groups[order[1]][1].body
  end

  it("removes the reference but keeps its line, like Emacs", function()
    eq(
      "echo a\n\necho b",
      tangled({
        "#+NAME: foo",
        "#+begin_src sh",
        "echo foo",
        "#+end_src",
        "",
        "#+begin_src sh :tangle /tmp/org-strip.sh :noweb strip-tangle",
        "echo a",
        "<<foo>>",
        "echo b",
        "#+end_src",
      })
    )
  end)

  it("expands the references of a strip-tangle block included by another", function()
    eq(
      "echo in\necho foo",
      tangled({
        "#+NAME: foo",
        "#+begin_src sh",
        "echo foo",
        "#+end_src",
        "#+NAME: inner",
        "#+begin_src sh :noweb strip-tangle",
        "echo in",
        "<<foo>>",
        "#+end_src",
        "#+begin_src sh :tangle /tmp/org-strip.sh :noweb yes",
        "<<inner>>",
        "#+end_src",
      })
    )
  end)
end)
