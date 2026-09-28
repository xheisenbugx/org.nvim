-- Ports of ob-LANG.el checked against Emacs Org 9.8.10. Expected results
-- come from `emacs --batch` running org-babel-execute-buffer on the same
-- input. Programs that are not installed (plantuml, ditaa, gnuplot, java,
-- ghc, ...) are replaced by small shell scripts that record their
-- arguments; Emacs was probed with the same scripts.
local babel = require("org.babel")
local config = require("org.config")

local function tmpdir()
  local dir = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  return dir
end

--- An executable shell script `name` in `dir` with `body`.
local function fake(dir, name, body)
  local path = dir .. "/" .. name
  vim.fn.writefile(vim.split("#!/bin/sh\n" .. body, "\n", { plain = true }), path)
  vim.uv.fs_chmod(path, tonumber("755", 8))
  return path
end

--- Execute the whole buffer (org-babel-execute-buffer) and return its lines.
local function run(lines, dir, name)
  dir = dir or tmpdir()
  local buf = org_buffer(lines, { 1, 0 })
  vim.api.nvim_buf_set_name(buf, dir .. "/" .. (name or "t.org"))
  babel.execute_buffer({ bufnr = buf, skip_confirm = true, sync = true })
  vim.bo[buf].modified = false
  return buf_lines(buf), dir, buf
end

--- The expanded body of the first block (C-c C-v v).
local function expand(lines)
  local buf = org_buffer(lines, { 1, 0 })
  local b = require("org.babel.blocks").parse_blocks(buf_lines(buf))[1]
  local args = require("org.babel.blocks").header_args(b, babel.get_file(buf))
  return table.concat(babel.expand_body(buf, b, args), "\n")
end

local saved
local function set_lang(lang, opts)
  saved = saved or {}
  if saved[lang] == nil then
    saved[lang] = vim.deepcopy(config.opts.babel.languages[lang]) or false
  end
  config.opts.babel.languages[lang] =
    vim.tbl_deep_extend("force", vim.deepcopy(config.opts.babel.languages[lang] or {}), opts)
end

local function restore()
  for lang, v in pairs(saved or {}) do
    config.opts.babel.languages[lang] = v or nil
  end
  saved = nil
end

describe("babel ob-plantuml", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(restore)

  it("runs the executable with -tTYPE -p and links the :file", function()
    local dir = tmpdir()
    local exe = fake(dir, "fakeplantuml", 'echo "ARGS: $*"\ncat')
    set_lang("plantuml", { exec_mode = "plantuml", executable_path = exe })
    -- Emacs 9.8.10: [[file:out.png]], out.png holding the command's output
    local out = run({
      '#+begin_src plantuml :file out.png :var who="Bob"',
      "Alice -> who",
      "#+end_src",
      "",
      "#+begin_src plantuml :results verbatim",
      "@startsalt",
      "{ a }",
      "@endsalt",
      "#+end_src",
      "",
      "#+begin_src plantuml :results verbatim :cmdline -v",
      "A -> B",
      "#+end_src",
    }, dir)
    eq({
      '#+begin_src plantuml :file out.png :var who="Bob"',
      "Alice -> who",
      "#+end_src",
      "",
      "#+RESULTS:",
      "[[file:out.png]]",
      "",
      "#+begin_src plantuml :results verbatim",
      "@startsalt",
      "{ a }",
      "@endsalt",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": ARGS: -headless -ttxt -p",
      ": @startsalt",
      ": { a }",
      ": @endsalt",
      "",
      "#+begin_src plantuml :results verbatim :cmdline -v",
      "A -> B",
      "#+end_src",
      "",
      "#+RESULTS:",
      ": ARGS: -headless -ttxt -p -v",
      ": @startuml",
      ": A -> B",
      ": @enduml",
    }, out)
    eq({ "ARGS: -headless -tpng -p", "@startuml", "!define who Bob", "Alice -> who", "@enduml" }, vim.fn.readfile(dir .. "/out.png"))
  end)

  it("needs the jar in jar mode (the default)", function()
    set_lang("plantuml", { exec_mode = "jar", jar_path = "" })
    local out = run({ "#+begin_src plantuml :file x.png", "A -> B", "#+end_src" })
    eq({ "#+begin_src plantuml :file x.png", "A -> B", "#+end_src" }, out)
  end)

  it("runs java -jar with :java options and converts svg text with inkscape", function()
    local dir = tmpdir()
    local log = dir .. "/log"
    fake(dir, "java", 'echo "java $*" >> ' .. log .. "\ncat")
    fake(dir, "inkscape", 'echo "inkscape $*" >> ' .. log)
    vim.fn.writefile({}, dir .. "/plantuml.jar")
    local path = vim.env.PATH
    vim.env.PATH = dir .. ":" .. path
    set_lang("plantuml", { exec_mode = "jar", jar_path = dir .. "/plantuml.jar", svg_text_to_path = true })
    run({ "#+begin_src plantuml :file d.svg :java -Xmx1g", "A -> B", "#+end_src" }, dir)
    vim.env.PATH = path
    local l = vim.fn.readfile(log)
    eq("java -Xmx1g -jar " .. dir .. "/plantuml.jar -headless -tsvg -p", l[1])
    eq("inkscape d.svg -T -l d.svg", l[2])
  end)
end)
