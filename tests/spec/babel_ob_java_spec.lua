-- ob-java, checked against Emacs Org 9.8.10 (`emacs --batch`):
-- expansions from org-babel-expand-src-block, results and the written
-- source files from org-babel-execute-buffer with the same fake `javac`
-- and `java` scripts (Java is not installed). The fake java prints its
-- arguments and writes [1,null,"x"] to the value file of the class.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local FAKE_JAVA = [[
echo "java $*"
dir=$2
for a in "$@"; do case $a in -*|"$dir") ;; *) cls=$a; break;; esac; done
src="$dir$(echo "$cls" | tr . /).java"
out=$(sed -n 's/.*new FileWriter("\([^"]*\)").*/\1/p' "$src")
if [ -n "$out" ]; then printf '[1,null,"x"]' > "$out"; fi]]

describe("babel ob-java", function()
  before_each(function()
    config.opts.babel.confirm_evaluate = false
  end)
  after_each(h.restore)

  it("wraps the body in a class and main method (org-babel-expand-body:java)", function()
    eq(
      '\npublic class Main {\n    public static void main(String[] args) {\n\tSystem.out.println("hi");\n    }\n}',
      h.expand({ "#+begin_src java", 'System.out.println("hi");', "#+end_src" })
    )
    eq(
      table.concat({
        "import java.util.Date;",
        "import java.io.File;",
        "",
        "public class Main {",
        "    static Integer a = 1;",
        "    static Double b = 2.500000;",
        '    static String s = "str";',
        "    static List<Integer> l = Arrays.asList(1, 2);",
        '    static List<List<String>> t = Arrays.asList(Arrays.asList("1", "a"), Arrays.asList("2", "b"));',
        "    public static void main(String[] args) {",
        "\tSystem.out.println(a);",
        "\t    if (true) {",
        "\tSystem.out.println(s);",
        "\t    }",
        "    }",
        "}",
      }, "\n"),
      h.expand({
        [[#+begin_src java :var a=1 b=2.5 s="str" l='(1 2) t='((1 "a") (2 "b")) :imports "java.util.Date java.io.File"]],
        "    System.out.println(a);",
        "        if (true) {",
        "    System.out.println(s);",
        "        }",
        "#+end_src",
      })
    )
    eq(
      'package com.x;\n\npublic class Hello {\n    public static void main(String[] args) {\n\tSystem.out.println("pkg");\n    }\n}',
      h.expand({ "#+begin_src java :classname com.x.Hello", 'System.out.println("pkg");', "#+end_src" })
    )
    local full = {
      "package org.me;",
      "import java.util.List;",
      "public class Foo {",
      "    public static void main(String[] args) {",
      '        System.out.println("x");',
      "    }",
      "}",
    }
    local block = vim.list_extend({ "#+begin_src java" }, vim.list_extend(vim.deepcopy(full), { "#+end_src" }))
    eq(table.concat(full, "\n"), h.expand(block))
    eq(
      "\npublic class Main {\n    static int twice(int x) {\n\treturn 2 * x;\n    }\n}",
      h.expand({ "#+begin_src java", "static int twice(int x) {", "    return 2 * x;", "}", "#+end_src" })
    )
    eq(
      "\npublic class Main {\n    public static void main(String[] args) {\n\t// pro\n\tint x = 1;\n\t// epi\n    }\n}",
      h.expand({ '#+begin_src java :prologue "// pro" :epilogue "// epi"', "int x = 1;", "#+end_src" })
    )
  end)

  it("writes hlines of table variables as hline_to", function()
    h.set_lang("java", { hline_to = "NULL" })
    -- Emacs 9.8.10 with org-babel-java-hline-to "NULL" (an hline makes the
    -- table a String table)
    local text = h.expand({
      "#+name: t",
      "| 1 | 2 |",
      "| 3 | 4 |",
      "|---+---|",
      "| 5 | 6 |",
      "",
      "#+begin_src java :var t=t :hlines yes",
      "int x = 1;",
      "#+end_src",
    })
    eq(
      '    static List<List<String>> t = Arrays.asList(Arrays.asList("1", "2"), Arrays.asList("3", "4"), NULL, '
        .. 'Arrays.asList("5", "6"));',
      vim.split(text, "\n")[3]
    )
  end)

  it("compiles and runs with javac and java; value results through a file", function()
    local dir = h.tmpdir()
    local log = dir .. "/log"
    local javac = h.fake(dir, "fakejavac", 'echo "javac $*" >> ' .. log)
    local java = h.fake(dir, "fakejava", FAKE_JAVA)
    h.set_lang("java", { cmd = java, compiler = javac })
    local out = h.run({
      '#+begin_src java :results output :cmdline -Dx=1 :cmdargs "a b" :cmpflag -g',
      'System.out.println("hi");',
      "#+end_src",
      "",
      "#+begin_src java :results value",
      "return 1;",
      "#+end_src",
      "",
      "#+begin_src java :classname com.x.Hello",
      'System.out.println("pkg");',
      "#+end_src",
    }, dir)
    eq({
      '#+begin_src java :results output :cmdline -Dx=1 :cmdargs "a b" :cmpflag -g',
      'System.out.println("hi");',
      "#+end_src",
      "",
      "#+RESULTS:",
      ": java -cp " .. dir .. "/ -Dx=1 Main a b",
      "",
      "#+begin_src java :results value",
      "return 1;",
      "#+end_src",
      "",
      "#+RESULTS:",
      "| 1 | hline | x |",
      "",
      "#+begin_src java :classname com.x.Hello",
      'System.out.println("pkg");',
      "#+end_src",
      "",
      "#+RESULTS:",
      ": java -cp " .. dir .. "/ com.x.Hello",
    }, out)
    eq({
      "javac -g " .. dir .. "/Main.java",
      "javac " .. dir .. "/Main.java",
      "javac " .. dir .. "/com/x/Hello.java",
    }, vim.fn.readfile(log))
    eq({
      "package com.x;",
      "",
      "public class Hello {",
      "    public static void main(String[] args) {",
      '\tSystem.out.println("pkg");',
      "    }",
      "}",
    }, vim.fn.readfile(dir .. "/com/x/Hello.java"))
    local main = vim.fn.readfile(dir .. "/Main.java")
    eq({
      "import java.io.IOException;",
      "import java.io.FileWriter;",
      "import java.io.BufferedWriter;",
      "import java.util.List;",
      "",
      "public class Main {",
      "",
      "    public static String __toString(Object val) {",
    }, vim.list_slice(main, 1, 8))
    ok(main[41]:match('^        BufferedWriter output = new BufferedWriter%(new FileWriter%(".+"%)%);$'))
    eq({
      "        output.write(__toString(_main(args)));",
      "        output.close();",
      "    }    public static Object _main(String[] args) {",
      "\treturn 1;",
      "    }",
      "}",
    }, vim.list_slice(main, 42))
  end)
end)
