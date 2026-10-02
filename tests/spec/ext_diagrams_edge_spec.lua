-- The diagrams extension: argv commands, included files in the cache key,
-- cleaning unused renders, cache pruning and rendering after a save in the
-- background. The tools are fake shell scripts.
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

local function log_lines(log)
  return vim.fn.filereadable(log) == 1 and vim.fn.readfile(log) or {}
end

local function setup(ext, dir)
  ext = vim.tbl_deep_extend("force", {
    mermaid = { command = dir .. "/mmdc" },
    dot = { command = dir .. "/dot" },
    cache_dir = dir .. "/cache",
    auto_preview = false,
  }, ext or {})
  require("org").setup({ babel = { confirm_evaluate = false }, extensions = { diagrams = ext } })
end

describe("diagrams: commands", function()
  after_each(function()
    require("org").setup({})
  end)

  it("runs the tools without a shell unless the command is a shell fragment", function()
    local render = require("org.extensions.diagrams.render")
    eq({ "mmdc" }, render.argv("mmdc"))
    eq({ "/opt/my tools/dot" }, render.argv({ "/opt/my tools/dot" }))
    eq(nil, render.argv("npx -y @mermaid-js/mermaid-cli"))
    eq(nil, render.argv("dot; rm -rf x"))
    -- a bare program name stays a name found on $PATH (it used to become
    -- org_directory/mmdc, so the default command was never found)
    eq("mmdc", render.program("mmdc"))
    eq("npx -y @mermaid-js/mermaid-cli", render.command_string("npx -y @mermaid-js/mermaid-cli"))
    eq(require("org.utils").home() .. "/bin/dot", render.program("~/bin/dot"))
    local dir = tmpdir()
    fake(dir, "mmdc", "exit 0")
    h.with_path(dir, function()
      ok(render.available("mmdc"))
    end)
  end)

  it("renders from a directory with spaces and quotes in its name", function()
    skip_on_windows("the fake tool runs behind cmd.exe, which re-quotes this command line")
    local dir = tmpdir() .. "/it's a dir"
    vim.fn.mkdir(dir, "p")
    local log = dir .. "/log"
    fake(dir, "dot", 'echo "dot $*" >> "' .. log .. '"\n' .. COPY)
    setup({ dot = { command = { dir .. "/dot" } } }, dir)
    local out = run({ "#+begin_src dot :file g.png", "graph { a }", "#+end_src" }, dir)
    eq("[[file:g.png]]", out[6])
    eq({ "graph { a }" }, vim.fn.readfile(dir .. "/g.png"))
    ok(log_lines(log)[1]:match("^dot %S+%.dot %-Tpng %-o " .. vim.pesc(dir) .. "/g%.png$"), log_lines(log)[1])
  end)
end)

describe("diagrams: plantuml includes", function()
  after_each(function()
    require("org").setup({})
  end)

  it("renders again when an !include'd file changed", function()
    local dir = tmpdir()
    local log = dir .. "/log"
    fake(dir, "plantuml", 'echo "plantuml $*" >> ' .. log .. "\ncat")
    setup({}, dir)
    vim.fn.writefile({ "skinparam monochrome true" }, dir .. "/style.puml")
    h.with_path(dir, function()
      local src = { "#+begin_src plantuml :file seq.png", "!include style.puml", "A -> B", "#+end_src" }
      run(src, dir)
      run(src, dir)
      eq(1, #log_lines(log))
      vim.fn.writefile({ "skinparam monochrome false" }, dir .. "/style.puml")
      run(src, dir)
      eq(2, #log_lines(log))
    end)
    local render = require("org.extensions.diagrams.render")
    eq("", render.include_digest("A -> B", dir))
    ok(render.include_digest("!include <C4/C4_Container>\n!includeurl https://x/y.puml", dir):find("<C4") == nil)
  end)
end)

describe("diagrams: cleaning", function()
  local real_notify
  before_each(function()
    real_notify = vim.notify
    vim.notify = function() end
  end)
  after_each(function()
    vim.notify = real_notify
    require("org").setup({})
  end)

  it("lists and deletes generated diagrams no org file of the directory links to", function()
    local dir = tmpdir()
    setup({}, dir)
    vim.fn.mkdir(dir .. "/diagrams", "p")
    for _, n in ipairs({ "dot-0123abcd.png", "mermaid-89abcdef.svg", "plantuml-00000000.png", "mine.png" }) do
      vim.fn.writefile({ "x" }, dir .. "/diagrams/" .. n)
    end
    vim.fn.writefile({ "[[file:diagrams/plantuml-00000000.png]]" }, dir .. "/other.org")
    local buf = org_buffer({ "#+RESULTS:", "[[file:diagrams/dot-0123abcd.png]]" }, { 1, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/notes.org")
    local ext = require("org.extensions.diagrams")
    local unused = ext.unreferenced(buf)
    eq({ dir .. "/diagrams/mermaid-89abcdef.svg" }, unused)
    eq(1, ext.clean(true))
    eq(1, vim.fn.filereadable(dir .. "/diagrams/mermaid-89abcdef.svg"))
    local select = vim.ui.select
    vim.ui.select = function(_, _, cb)
      cb("Yes")
    end
    local n
    require("org.utils").run(function()
      n = ext.clean()
    end)
    vim.wait(1000, function()
      return n ~= nil
    end)
    vim.ui.select = select
    eq(1, n)
    eq(0, vim.fn.filereadable(dir .. "/diagrams/mermaid-89abcdef.svg"))
    eq(1, vim.fn.filereadable(dir .. "/diagrams/dot-0123abcd.png"))
    eq(1, vim.fn.filereadable(dir .. "/diagrams/plantuml-00000000.png"))
    eq(1, vim.fn.filereadable(dir .. "/diagrams/mine.png"))
    eq({ "dry" }, require("org.commands").complete("", "Org diagrams_clean "))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("prunes the cache by age, then by size", function()
    local dir = tmpdir()
    setup({}, dir)
    vim.fn.mkdir(dir .. "/cache", "p")
    local now = os.time()
    local function entry(name, kb, days)
      vim.fn.writefile({ string.rep("x", kb * 1024 - 1) }, dir .. "/cache/" .. name, "b")
      vim.uv.fs_utime(dir .. "/cache/" .. name, now - days * 86400, now - days * 86400)
    end
    local function h(c)
      return string.rep(c, 64) .. ".png"
    end
    entry(h("0"), 1, 100)
    entry(h("a"), 600, 1)
    entry(h("b"), 600, 2)
    entry(h("c"), 600, 3)
    -- not cache entries: never deleted, whatever their age and size
    entry("notes.txt", 1, 100)
    entry("big.png", 2048, 1)
    local ext = require("org.extensions.diagrams")
    eq(1, ext.prune_cache(90, false))
    eq(0, vim.fn.filereadable(dir .. "/cache/" .. h("0")))
    eq(1, ext.prune_cache(false, 1.5))
    eq({ 1, 1, 0 }, {
      vim.fn.filereadable(dir .. "/cache/" .. h("a")),
      vim.fn.filereadable(dir .. "/cache/" .. h("b")),
      vim.fn.filereadable(dir .. "/cache/" .. h("c")),
    })
    ext.clear_cache()
    eq({ "big.png", "notes.txt" }, vim.fn.readdir(dir .. "/cache"))
  end)
end)

describe("diagrams: render_on_save", function()
  after_each(function()
    require("org").setup({})
  end)

  it("renders in the background and leaves the buffer to you if you edit meanwhile", function()
    local dir = tmpdir()
    local log = dir .. "/log"
    fake(dir, "dot", "sleep 1\n" .. 'echo "dot $*" >> ' .. log .. "\n" .. COPY)
    setup({ render_on_save = true }, dir)
    local buf = org_buffer({ "#+begin_src dot :file a.png", "graph { a }", "#+end_src", "* Tail" }, { 1, 0 })
    local path = dir .. "/slow.org"
    vim.api.nvim_buf_set_name(buf, path)
    local t0 = vim.uv.hrtime()
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("silent write")
    end)
    local ms = (vim.uv.hrtime() - t0) / 1e6
    ok(ms < 800, string.format("the write blocked for %.0f ms", ms))
    -- an edit while dot runs
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "typed meanwhile" })
    vim.wait(5000, function()
      return vim.fn.index(buf_lines(buf), "[[file:a.png]]") >= 0
    end, 20)
    ok(vim.fn.index(buf_lines(buf), "[[file:a.png]]") >= 0, table.concat(buf_lines(buf), "\n"))
    vim.wait(100)
    eq(true, vim.bo[buf].modified)
    eq(-1, vim.fn.index(vim.fn.readfile(path), "typed meanwhile"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
