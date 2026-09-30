-- The diagrams extension: mermaid / dot / plantuml blocks rendered to
-- files, cached by content hash, previewed and rendered on save. The tools
-- are fake shell scripts that log their arguments and copy the input to
-- the output file.
local config = require("org.config")
local ob = require("org.babel.ob")
local h = require("tests.helpers.babel_ob")
local tmpdir, fake, run = h.tmpdir, h.fake, h.run

local COPY = [[
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -i) in="$2"; shift ;;
    -*) ;;
    *) [ -z "$in" ] && in="$1" ;;
  esac
  shift
done
cat "$in" > "$out"]]

-- fake mmdc and dot in `dir`, logging to dir/log
local function tools(dir)
  local log = dir .. "/log"
  fake(dir, "mmdc", 'echo "mmdc $*" >> ' .. log .. "\n" .. COPY)
  fake(dir, "dot", 'echo "dot $*" >> ' .. log .. "\n" .. COPY)
  return log
end

local function log_lines(log)
  return vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
end

local function setup(ext, dir)
  local o = { babel = { confirm_evaluate = false } }
  if ext ~= nil then
    if type(ext) == "table" then
      ext = vim.tbl_deep_extend("force", {
        mermaid = { command = dir .. "/mmdc" },
        dot = { command = dir .. "/dot" },
        cache_dir = dir .. "/cache",
        auto_preview = false,
      }, ext)
    end
    o.extensions = { diagrams = ext }
  end
  require("org").setup(o)
end

describe("diagrams extension", function()
  after_each(function()
    require("org").setup({})
  end)

  it("is inert when off: no mermaid/dot handlers, plantuml untouched", function()
    setup(nil)
    eq(nil, ob.HANDLERS.mermaid)
    eq(nil, ob.HANDLERS.dot)
    eq("plantuml", ob.HANDLERS.plantuml)
    eq(nil, config.opts.babel.languages.mermaid)
    eq(nil, ob.get("mermaid"))
    eq(nil, ob.get("dot"))
    eq(0, #vim.api.nvim_get_autocmds({ group = nil, event = "User", pattern = "OrgBabelAfterExecute" }))
    eq(nil, config.opts.mappings.org.diagrams_render)
    eq(nil, require("org.actions").list.diagrams_render)
  end)

  it("ob.get returns a handler table registered in HANDLERS", function()
    setup(nil)
    local handler = { prepare = function() end }
    ob.HANDLERS.fake_lang = handler
    config.opts.babel.languages.fake_lang = {}
    eq(handler, ob.get("fake_lang"))
    ob.HANDLERS.fake_lang = nil
    config.opts.babel.languages.fake_lang = nil
  end)

  it("registers handlers, languages and actions, and teardown restores them", function()
    local dir = tmpdir()
    setup({}, dir)
    ok(type(ob.HANDLERS.mermaid) == "table")
    ok(type(ob.HANDLERS.dot) == "table")
    ok(type(ob.HANDLERS.plantuml) == "table")
    eq({ results = "file", exports = "results" }, config.opts.babel.languages.mermaid.default_header_args)
    ok(require("org.actions").list.diagrams_render_buffer ~= nil)
    setup(nil)
    eq(nil, ob.HANDLERS.mermaid)
    eq("plantuml", ob.HANDLERS.plantuml)
    eq(nil, config.opts.babel.languages.dot)
  end)

  it("only handles the listed languages", function()
    local dir = tmpdir()
    setup({ languages = { "dot" } }, dir)
    eq(nil, ob.HANDLERS.mermaid)
    eq("plantuml", ob.HANDLERS.plantuml)
    ok(type(ob.HANDLERS.dot) == "table")
  end)

  it("renders mermaid with mmdc and header options, linking the :file", function()
    local dir = tmpdir()
    local log = tools(dir)
    setup({}, dir)
    local out = run({
      "#+begin_src mermaid :file flow.svg :theme dark :width 800 :background-color transparent",
      "graph TD; A-->B",
      "#+end_src",
    }, dir)
    eq({
      "#+begin_src mermaid :file flow.svg :theme dark :width 800 :background-color transparent",
      "graph TD; A-->B",
      "#+end_src",
      "",
      "#+RESULTS:",
      "[[file:flow.svg]]",
    }, out)
    eq({ "graph TD; A-->B" }, vim.fn.readfile(dir .. "/flow.svg"))
    local l = log_lines(log)
    eq(1, #l)
    ok(l[1]:match("^mmdc %-i %S+%.mmd %-o " .. vim.pesc(dir) .. "/flow%.svg %-t dark %-b transparent %-w 800$"))
  end)

  it("uses the mermaid options and extra args", function()
    local dir = tmpdir()
    local log = tools(dir)
    setup({ mermaid = { theme = "forest", args = { "--quiet" } } }, dir)
    run({ "#+begin_src mermaid :file m.png", "graph LR; X-->Y", "#+end_src" }, dir)
    ok(log_lines(log)[1]:match(" %-t forest %-%-quiet$"))
  end)

  it("renders dot with -TEXT, :cmdline, :cmd and $var expansion", function()
    local dir = tmpdir()
    local log = tools(dir)
    setup({}, dir)
    local out = run({
      '#+begin_src dot :file g.png :var color="red"',
      "digraph { a [color=$color]; a -> b }",
      "#+end_src",
      "",
      "#+begin_src dot :file g2.svg :cmdline -Kneato -Tsvg",
      "graph { x -- y }",
      "#+end_src",
    }, dir)
    eq("[[file:g.png]]", out[6])
    eq("[[file:g2.svg]]", out[13])
    eq({ "digraph { a [color=red]; a -> b }" }, vim.fn.readfile(dir .. "/g.png"))
    local l = log_lines(log)
    ok(l[1]:match("^dot %S+%.dot %-Tpng %-o " .. vim.pesc(dir) .. "/g%.png$"))
    ok(l[2]:match("^dot %S+%.dot %-Kneato %-Tsvg %-o "))
    fake(dir, "mydot", 'echo "mydot $*" >> ' .. log .. "\n" .. COPY)
    run({ "#+begin_src dot :file g3.png :cmd " .. dir .. "/mydot", "graph { z }", "#+end_src" }, dir)
    ok(log_lines(log)[3]:match("^mydot "))
  end)

  it("names the output file when there is no :file", function()
    local dir = tmpdir()
    tools(dir)
    setup({}, dir)
    local out = run({ "#+begin_src dot", "graph { p -- q }", "#+end_src" }, dir)
    local file = out[6]:match("^%[%[file:(diagrams/dot%-%x%x%x%x%x%x%x%x%.png)%]%]$")
    ok(file)
    eq({ "graph { p -- q }" }, vim.fn.readfile(dir .. "/" .. file))
    -- :file-ext picks the format; output_dir can be changed
    setup({ output_dir = "img" }, dir)
    out = run({ "#+begin_src mermaid :file-ext svg", "graph TD; Q", "#+end_src" }, dir)
    ok(out[6]:match("^%[%[file:img/mermaid%-%x+%.svg%]%]$"))
  end)

  it("errors without :file when auto_file is off", function()
    local dir = tmpdir()
    local log = tools(dir)
    setup({ auto_file = false }, dir)
    local out = run({ "#+begin_src dot", "graph { p }", "#+end_src" }, dir)
    eq(3, #out)
    eq({}, log_lines(log))
  end)

  it("reports a missing tool and inserts nothing", function()
    local dir = tmpdir()
    setup({ mermaid = { command = dir .. "/no-such-mmdc" } }, dir)
    local out = run({ "#+begin_src mermaid :file x.png", "graph TD; A", "#+end_src" }, dir)
    eq(3, #out)
  end)

  it("caches by content hash, re-renders changes, rerender and clear_cache", function()
    local dir = tmpdir()
    local log = tools(dir)
    setup({}, dir)
    local src = { "#+begin_src dot :file c.png", "graph { a }", "#+end_src" }
    run(src, dir)
    eq(1, #log_lines(log))
    vim.fn.delete(dir .. "/c.png")
    local out = run(src, dir)
    eq("[[file:c.png]]", out[6])
    -- copied from the cache, not rendered again
    eq(1, #log_lines(log))
    eq({ "graph { a }" }, vim.fn.readfile(dir .. "/c.png"))
    ok(require("org.extensions.diagrams.render").last.hit)
    -- another body renders again
    run({ "#+begin_src dot :file c.png", "graph { b }", "#+end_src" }, dir)
    eq(2, #log_lines(log))
    eq({ "graph { b }" }, vim.fn.readfile(dir .. "/c.png"))
    -- another format is another cache entry
    run({ "#+begin_src dot :file c.svg", "graph { b }", "#+end_src" }, dir)
    eq(3, #log_lines(log))
    -- rerender ignores the cache once
    local buf = org_buffer(src, { 2, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/r.org")
    require("org.extensions.diagrams").rerender({ sync = true })
    eq(4, #log_lines(log))
    ok(not require("org.extensions.diagrams.render").last.hit)
    -- not on a diagram block: not applicable
    local other = org_buffer({ "* Heading", "text" }, { 2, 0 })
    eq(false, require("org.extensions.diagrams").render())
    vim.api.nvim_buf_delete(other, { force = true })
    ok(#vim.fn.glob(dir .. "/cache/*", true, true) >= 3)
    require("org.extensions.diagrams").clear_cache()
    eq(0, #vim.fn.glob(dir .. "/cache/*", true, true))
  end)

  it("does not cache when cache = false", function()
    local dir = tmpdir()
    local log = tools(dir)
    setup({ cache = false }, dir)
    local src = { "#+begin_src dot :file n.png", "graph { a }", "#+end_src" }
    run(src, dir)
    run(src, dir)
    eq(2, #log_lines(log))
    eq(0, #vim.fn.glob(dir .. "/cache/*", true, true))
  end)

  it("wraps plantuml: the plantuml command without a jar, the cache, generated names", function()
    local dir = tmpdir()
    local log = dir .. "/log"
    fake(dir, "plantuml", 'echo "plantuml $*" >> ' .. log .. "\ncat")
    setup({}, dir)
    h.with_path(dir, function()
      local src = { "#+begin_src plantuml :file seq.png", "A -> B", "#+end_src" }
      local out = run(src, dir)
      eq("[[file:seq.png]]", out[6])
      eq({ "@startuml", "A -> B", "@enduml" }, vim.fn.readfile(dir .. "/seq.png"))
      eq(1, #log_lines(log))
      ok(log_lines(log)[1]:match("^plantuml %-headless %-tpng %-p"))
      run(src, dir)
      eq(1, #log_lines(log))
      out = run({ "#+begin_src plantuml", "C -> D", "#+end_src" }, dir)
      ok(out[6]:match("^%[%[file:diagrams/plantuml%-%x+%.png%]%]$"))
      -- text results are left to the core port
      out = run({ "#+begin_src plantuml :results verbatim", "E -> F", "#+end_src" }, dir)
      eq(": @startuml", out[6])
    end)
  end)

  it("previews the result link after execution", function()
    local dir = tmpdir()
    tools(dir)
    setup({ auto_preview = true }, dir)
    local images = require("org.ui.images")
    local backend, show = images.backend, images.show_links
    local calls = {}
    images.backend = function()
      return "stub"
    end
    images.show_links = function(buf, first, last)
      calls[#calls + 1] = { buf, first, last }
      return 1
    end
    local okr, err = pcall(function()
      local _, _, buf = run({ "* Diagram", "#+begin_src dot :file p.png", "graph { a }", "#+end_src" }, dir)
      eq(1, #calls)
      eq({ buf, 7, 7 }, calls[1])
      -- other languages are not previewed
      calls = {}
      run({ "#+begin_src dot :file p.txt", "graph { a }", "#+end_src" }, dir)
      eq(0, #calls)
    end)
    images.backend, images.show_links = backend, show
    if not okr then
      error(err, 0)
    end
  end)

  it("does not preview when auto_preview is off", function()
    local dir = tmpdir()
    tools(dir)
    setup({ auto_preview = false }, dir)
    local images = require("org.ui.images")
    local show = images.show_links
    local n = 0
    images.show_links = function()
      n = n + 1
    end
    run({ "#+begin_src dot :file q.png", "graph { a }", "#+end_src" }, dir)
    images.show_links = show
    eq(0, n)
  end)

  it("renders every diagram block on save with render_on_save, skipping :eval no", function()
    local dir = tmpdir()
    local log = tools(dir)
    setup({ render_on_save = true }, dir)
    local buf = org_buffer({
      "* A",
      "#+begin_src dot :file a.png",
      "graph { a }",
      "#+end_src",
      "* B",
      "#+begin_src mermaid :file b.png",
      "graph TD; B",
      "#+end_src",
      "#+begin_src dot :file c.png :eval no",
      "graph { c }",
      "#+end_src",
      "#+begin_src sh",
      "echo not run",
      "#+end_src",
    }, { 1, 0 })
    local path = dir .. "/save.org"
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    local lines = vim.fn.readfile(path)
    eq("[[file:a.png]]", lines[7])
    eq("[[file:b.png]]", lines[15])
    eq(-1, vim.fn.index(lines, "[[file:c.png]]"))
    eq(-1, vim.fn.index(lines, ": not run"))
    eq(2, #log_lines(log))
    -- saving again uses the cache
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    eq(2, #log_lines(log))
    eq(lines, vim.fn.readfile(path))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("does not render on save by default", function()
    local dir = tmpdir()
    local log = tools(dir)
    setup({}, dir)
    local buf = org_buffer({ "#+begin_src dot :file a.png", "graph { a }", "#+end_src" }, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/nosave.org")
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    eq({}, log_lines(log))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("reports the tools in :checkhealth", function()
    local dir = tmpdir()
    tools(dir)
    setup({ mermaid = { command = dir .. "/none" } }, dir)
    local msgs = {}
    local hh = {}
    for _, k in ipairs({ "start", "ok", "warn", "info", "error" }) do
      hh[k] = function(m)
        msgs[#msgs + 1] = k .. ": " .. m
      end
    end
    require("org.extensions").check(hh)
    local text = table.concat(msgs, "\n")
    ok(text:match("warn: diagrams: mermaid needs " .. vim.pesc(dir) .. "/none"))
    ok(text:match("ok: diagrams: dot renders with " .. vim.pesc(dir) .. "/dot"))
    ok(text:match("diagrams: cache in"))
  end)
end)
