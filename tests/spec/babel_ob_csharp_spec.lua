-- ob-csharp, checked against Emacs Org 9.8.10 with .NET 10: expansions from
-- org-babel-expand-src-block and results from org-babel-execute-buffer in
-- `emacs --batch`. Without dotnet only the expansion and the project file
-- are checked, and a fake dotnet shows the commands.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local BLOCKS = {
  '#+begin_src csharp :var n=3 s="x"',
  "Console.WriteLine(n);",
  "Console.WriteLine(s);",
  "#+end_src",
  "",
  '#+begin_src csharp :usings \'("System.Text") :class Foo :prologue "// pro" :epilogue "// epi"',
  'Console.WriteLine("  a b");',
  'Console.WriteLine("  c d");',
  "#+end_src",
  "",
  "#+begin_src csharp :main no :class no",
  'Console.WriteLine("top level");',
  "#+end_src",
  "",
  '#+begin_src csharp :results output :cmdline "one two"',
  'Console.WriteLine(args.Length + " " + args[0]);',
  "#+end_src",
}

describe("babel ob-csharp", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("expands like org-babel-expand-body:csharp", function()
    -- Emacs 9.8.10
    eq(
      table.concat({
        "namespace org.babel.autogen;",
        "",
        "class Program",
        "{",
        "static void Main(string[] args)",
        "{",
        "var n = 3;",
        'var s = "x";',
        "Console.WriteLine(n);",
        "Console.WriteLine(s);",
        "}",
        "}",
      }, "\n"),
      h.expand(BLOCKS, 1)
    )
    eq(
      table.concat({
        "// pro",
        "namespace org.babel.autogen;",
        "",
        "using System.Text;",
        "",
        "class Foo",
        "{",
        "static void Main(string[] args)",
        "{",
        "",
        'Console.WriteLine("  a b");',
        'Console.WriteLine("  c d");',
        "}",
        "}",
        "// epi",
      }, "\n"),
      h.expand(BLOCKS, 2)
    )
    eq('namespace org.babel.autogen;\n\nConsole.WriteLine("top level");', h.expand(BLOCKS, 3))
  end)

  it("writes the project file like org-babel-csharp--generate-project-file", function()
    h.set_lang("csharp", { additional_project_flags = "<LangVersion>latest</LangVersion>" })
    local m = require("org.babel.lang.csharp")
    eq(
      table.concat({
        '<Project Sdk="Microsoft.NET.Sdk">',
        "",
        "  ",
        "",
        "  <PropertyGroup>",
        "    <OutputType>Exe</OutputType>",
        "",
        "    <TargetFramework>net8.0</TargetFramework>",
        "    <ImplicitUsings>enable</ImplicitUsings>",
        "    <Nullable>enable</Nullable>",
        "    <LangVersion>latest</LangVersion>",
        "  </PropertyGroup>",
        "</Project>",
      }, "\n"),
      m.project_file(nil, "net8.0", "/tmp")
    )
  end)

  it("restores, builds and runs the project", function()
    if vim.fn.executable("dotnet") == 0 then
      return
    end
    local out = h.run(BLOCKS)
    -- Emacs 9.8.10 (the top-level statements after a file-scoped
    -- namespace don't compile: an empty result)
    eq({ "#+RESULTS:", "| 3 |", "| x |" }, vim.list_slice(out, 6, 8))
    eq({ "#+RESULTS:", "| a | b |", "| c | d |" }, vim.list_slice(out, 15, 17))
    eq({ "#+RESULTS:", "" }, vim.list_slice(out, 23, 24))
    eq({ "#+RESULTS:", ": 1 one two" }, vim.list_slice(out, 29, 30))
  end)

  it("uses the configured command functions", function()
    local dir = h.tmpdir()
    local log = dir .. "/log"
    local dotnet =
      h.fake(dir, "dotnet", 'echo "dotnet $*" >> ' .. log .. '\n[ "$1" = --list-sdks ] && echo "9.0.100 [/x]"')
    h.set_lang("csharp", {
      compiler = dotnet,
      generate_restore_command = function(p)
        return "echo restore " .. vim.fn.fnamemodify(p, ":e") .. " >> " .. log
      end,
      generate_compile_command = function(p, bin)
        return "echo build " .. vim.fn.fnamemodify(bin, ":t") .. " >> " .. log
      end,
    })
    h.run({ "#+begin_src csharp", "1;", "#+end_src" }, dir)
    local l = vim.fn.readfile(log)
    eq({ "restore csproj", "build bin" }, vim.list_slice(l, #l - 1))
    eq("net9.0", require("org.babel.lang.csharp").default_framework())
  end)

  it("runs the program with DOTNET_ROOT of an SDK outside the default location", function()
    local dir = h.tmpdir()
    local dotnet = h.fake(dir, "dotnet", '[ "$1" = --list-sdks ] && echo "10.0.400 [/home/u/.dotnet/sdk]"')
    h.set_lang("csharp", {
      compiler = dotnet,
      generate_restore_command = function()
        return "true"
      end,
      -- the "app host": prints where it would look for .NET
      generate_compile_command = function(p, bin)
        local app = bin .. "/" .. vim.fn.fnamemodify(p, ":t:r")
        return string.format(
          "mkdir -p %s && printf '#!/bin/sh\\necho \"$DOTNET_ROOT\"\\n' > %s && chmod +x %s",
          bin,
          app,
          app
        )
      end,
    })
    local saved = vim.env.DOTNET_ROOT
    vim.env.DOTNET_ROOT = nil
    local out = h.run({ "#+begin_src csharp", "1;", "#+end_src" }, dir)
    eq({ "#+RESULTS:", ": /home/u/.dotnet" }, vim.list_slice(out, 5, 6))
    -- one set by the user is kept
    vim.env.DOTNET_ROOT = "/opt/dotnet"
    out = h.run({ "#+begin_src csharp", "1;", "#+end_src" }, dir)
    vim.env.DOTNET_ROOT = saved
    eq({ "#+RESULTS:", ": /opt/dotnet" }, vim.list_slice(out, 5, 6))
  end)
end)
