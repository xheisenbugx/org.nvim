
# Table of Contents

1.  [How to use this file](#org27a19fc)
    1.  [Which interpreters you need](#orgafc9f12)
    2.  [Keys in this file](#orge1f6803)
2.  [Running a block](#org5570f68)
    1.  [The confirmation prompt](#org6f3b54d)
    2.  [Removing and folding results](#org3d780a4)
    3.  [Running many blocks at once](#orgcda24b4)
    4.  [Moving between blocks](#org14c171c)
3.  [Languages](#orgfe04580)
    1.  [Lua: runs inside Neovim](#orgbc77e6e)
    2.  [Shell](#org26715ee)
    3.  [Other languages (need their interpreter)](#org1709cfb)
4.  [Results](#orgc673174)
    1.  [value versus output](#orge8b307a)
    2.  [Types: table, list, verbatim, scalar](#orgfd896ea)
    3.  [Formats: raw, org, drawer, html, code](#org05944c1)
    4.  [:wrap](#orgd22997b)
    5.  [Handling: replace, append, prepend, silent, none](#org063e364)
    6.  [:cache](#org8ba8d27)
    7.  [:file results](#orga176ef6)
5.  [Variables: :var](#org0307b6a)
    1.  [Literals](#org331091e)
    2.  [Tables and lists as input](#org6030345)
    3.  [Slices and indexes](#org853d9c8)
    4.  [:colnames, :rownames and :hlines](#org5f1eceb)
    5.  [Results of other blocks](#orge3a656f)
6.  [Named blocks and #+CALL](#orgb02189e)
    1.  [Inline source blocks and calls](#org2c62ff8)
7.  [Noweb: blocks inside blocks](#orgbb990c9)
    1.  [Inserting a result: ](#org16cf1a1)
    2.  [:noweb-ref: collecting blocks](#orga2c3f62)
    3.  [When noweb applies](#org5119fb4)
8.  [Sessions](#orgd7dcd96)
    1.  [Lua sessions](#org90f946b)
    2.  [Shell sessions](#org783583e)
    3.  [:async](#org7d4c8a2)
9.  [Header arguments at every level](#org91befa8)
    1.  [A subtree with its own header arguments](#orge3d1bd6)
    2.  [Checking and inserting header arguments](#org09ddd66)
    3.  [:dir, :prologue, :epilogue, :cmdline](#org9cb87b2)
10. [Editing blocks](#orgca7fe95)
    1.  [Edit in a special buffer: <prefix>'](#org8a52622)
    2.  [Split, wrap and insert blocks: <prefix>bd](#orga11ae79)
    3.  [Show the expanded block: <prefix>bv](#orga525676)
11. [Tangling](#orgbbdda16)
    1.  [A small shell script](#orgfcf7059)
    2.  [A Lua module with link comments and noweb](#org37dc0a3)
12. [Library of Babel](#org8d32f2f)
13. [Exporting code and results](#org8f01684)
14. [Further reading](#orgc2b38a0)



<a id="org27a19fc"></a>

# How to use this file

Babel runs the code in `#+begin_src` blocks and writes what the code returns
or prints back into the file, under a `#+RESULTS:` line. Blocks can take
arguments (`:var`), call each other, include each other (noweb), share a
live interpreter (`:session`) and be written out to source files
(tangling). This file walks through all of it, from the first
`<C-c><C-c>` to tangling a small program.

-   The file starts folded. `<Tab>` on a heading opens it, `<S-Tab>` cycles
    the whole buffer.
-   Nothing breaks if you make a mess: `u` undoes, and
    `git checkout examples/17-babel.org` restores the file.
-   `<prefix>` means `<leader>o` (the default `mappings.prefix`). `g?` lists
    every key of the buffer, `<prefix>bh` only the Babel ones.
-   The Emacs keys work too: `C-c C-v e`, `C-c C-v t` &hellip; (`:h org-emacs-keys`).
-   Lines starting with **Try:** are exercises, **Expect:** says what you should
    see afterwards. Lines starting with =# = are Org comments that annotate the
    examples; they are never exported.
-   Most blocks already show a `#+RESULTS:`, produced by org.nvim itself.
    Running them again replaces the result with the same text (unless the
    block prints the time or a random number). Remove a result with
    `<prefix>bk` to watch it come back.

Start Neovim from the repo root with the bundled init file, so your own
config is not involved:

    nvim -u examples/minimal_init.lua examples/17-babel.org

Tangling writes files into `examples/17-babel-out/`, a directory next to
this file. Delete it when you are done: `rm -r examples/17-babel-out`.


<a id="orgafc9f12"></a>

## Which interpreters you need

Lua blocks run **inside Neovim**: they always work, need nothing installed,
and can use the whole `vim` API. `sh` needs a POSIX shell, which every
Unix-like system has. All the exercises use one of these two. A few
examples show other languages; they only run when the interpreter is on
your `$PATH`:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Language</th>
<th scope="col" class="org-left">Interpreter</th>
<th scope="col" class="org-left">Notes</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>lua</code></td>
<td class="org-left">none (inside Neovim)</td>
<td class="org-left"><code>print</code> goes to the output</td>
</tr>

<tr>
<td class="org-left"><code>sh</code> <code>bash</code></td>
<td class="org-left"><code>sh</code> / <code>bash</code></td>
<td class="org-left">also <code>zsh</code>, <code>fish</code></td>
</tr>

<tr>
<td class="org-left"><code>python</code></td>
<td class="org-left"><code>python3</code></td>
<td class="org-left"><code>:python</code> picks another binary</td>
</tr>

<tr>
<td class="org-left"><code>js</code></td>
<td class="org-left"><code>node</code></td>
<td class="org-left"><code>:cmd</code> picks another binary</td>
</tr>

<tr>
<td class="org-left"><code>ruby</code></td>
<td class="org-left"><code>ruby</code> (<code>irb</code> for sessions)</td>
<td class="org-left">&nbsp;</td>
</tr>

<tr>
<td class="org-left"><code>sqlite</code></td>
<td class="org-left"><code>sqlite3</code></td>
<td class="org-left"><code>:db</code> names the database</td>
</tr>

<tr>
<td class="org-left"><code>awk</code> <code>perl</code></td>
<td class="org-left"><code>awk</code> / <code>perl</code></td>
<td class="org-left">&nbsp;</td>
</tr>

<tr>
<td class="org-left"><code>C</code> <code>cpp</code></td>
<td class="org-left"><code>gcc</code> / <code>g++</code></td>
<td class="org-left">compiled, then run</td>
</tr>

<tr>
<td class="org-left"><code>emacs-lisp</code></td>
<td class="org-left"><code>emacs --batch</code></td>
<td class="org-left">runs in a separate Emacs</td>
</tr>
</tbody>
</table>

`:checkhealth org` reports which of them it found.


<a id="orge1f6803"></a>

## Keys in this file

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Emacs</th>
<th scope="col" class="org-left">What it does</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-c&gt;</code> / <code>&lt;prefix&gt;be</code></td>
<td class="org-left"><code>C-c C-v e</code></td>
<td class="org-left">run the block / #+CALL / inline src</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bb</code></td>
<td class="org-left"><code>C-c C-v b</code></td>
<td class="org-left">run every block of the buffer</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bs</code></td>
<td class="org-left"><code>C-c C-v s</code></td>
<td class="org-left">run every block of the subtree</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bk</code></td>
<td class="org-left"><code>C-c C-v k</code></td>
<td class="org-left">remove the result</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bn</code> / <code>&lt;prefix&gt;bp</code></td>
<td class="org-left"><code>C-c C-v n/p</code></td>
<td class="org-left">next / previous block</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bu</code></td>
<td class="org-left"><code>C-c C-v u</code></td>
<td class="org-left">go to the <code>#+begin_src</code> line</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bg</code> / <code>&lt;prefix&gt;br</code></td>
<td class="org-left"><code>C-c C-v g/r</code></td>
<td class="org-left">go to a named block / result</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;'</code></td>
<td class="org-left"><code>C-c '</code></td>
<td class="org-left">edit the block in its own buffer</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bv</code></td>
<td class="org-left"><code>C-c C-v v</code></td>
<td class="org-left">show the expanded body</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bI</code></td>
<td class="org-left"><code>C-c C-v I</code></td>
<td class="org-left">show the merged header arguments</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bc</code></td>
<td class="org-left"><code>C-c C-v c</code></td>
<td class="org-left">check for misspelt header args</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bj</code></td>
<td class="org-left"><code>C-c C-v j</code></td>
<td class="org-left">insert a header argument</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bd</code></td>
<td class="org-left"><code>C-c C-v d</code></td>
<td class="org-left">split / wrap / insert a block</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;ba</code></td>
<td class="org-left"><code>C-c C-v a</code></td>
<td class="org-left">show the block's hash</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bo</code></td>
<td class="org-left"><code>C-c C-v o</code></td>
<td class="org-left">open the result</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bm</code></td>
<td class="org-left"><code>C-c C-v C-M-h</code></td>
<td class="org-left">select the block body</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bt</code> / <code>&lt;prefix&gt;bf</code></td>
<td class="org-left"><code>C-c C-v t/f</code></td>
<td class="org-left">tangle this file / another file</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bi</code></td>
<td class="org-left"><code>C-c C-v i</code></td>
<td class="org-left">add blocks to the Library of Babel</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bz</code> / <code>&lt;prefix&gt;bZ</code></td>
<td class="org-left"><code>C-c C-v C-z</code> / <code>z</code></td>
<td class="org-left">show the session</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bl</code></td>
<td class="org-left"><code>C-c C-v l</code></td>
<td class="org-left">run in the session and show it</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bK</code></td>
<td class="org-left">&nbsp;</td>
<td class="org-left">kill the session</td>
</tr>

<tr>
<td class="org-left"><code>&lt;Tab&gt;</code> on <code>#+RESULTS:</code></td>
<td class="org-left">&nbsp;</td>
<td class="org-left">fold / unfold the result</td>
</tr>
</tbody>
</table>


<a id="org5570f68"></a>

# Running a block

A source block starts with `#+begin_src LANG` followed by optional header
arguments, and ends with `#+end_src`. Put the cursor **anywhere** in it (on
the `#+begin_src` line, in the body, or on `#+end_src`) and press
`<C-c><C-c>` (or `<prefix>be`). The block runs in the background; while it
runs, `⏳ executing…` is shown at the end of the `#+end_src` line.

The simplest block: a Lua expression. Its value is the result.

    1 + 2

    3

A Lua block can also `return` a value, and use the `vim` API:

    return "Neovim " .. vim.version().major .. "." .. vim.version().minor

    Neovim 0.13

**Try:** put the cursor on the `1 + 2` line above and press `<C-c><C-c>`.
Answer `y` to the question "Evaluate this lua code block on your system?".

**Expect:** the block below it now reads `#+RESULTS:` followed by `: 3`. The
=: = prefix marks a one-line fixed-width result.

**Try:** change `1 + 2` to `6 * 7` and run it again.

**Expect:** the old result is **replaced** by `: 42`; it does not pile up.


<a id="org6f3b54d"></a>

## The confirmation prompt

By default you are asked before every evaluation (Emacs
`org-confirm-babel-evaluate`). This is the option `babel.confirm_evaluate`:

    require("org").setup({
      babel = {
        -- never ask:
        confirm_evaluate = false,
        -- or: ask for everything except Lua
        -- confirm_evaluate = function(lang, body) return lang ~= "lua" end,
      },
    })

**Try:** to stop the prompts for this session only, run this command:
`:lua require("org.config").opts.babel.confirm_evaluate = false`

**Expect:** `<C-c><C-c>` on a block runs it at once, without a question.
Restart Neovim to get the prompt back.

The `:eval` header argument controls one block:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left"><code>:eval</code></th>
<th scope="col" class="org-left">Effect</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">(none) / <code>yes</code></td>
<td class="org-left">ask if <code>confirm_evaluate</code> says so, then run</td>
</tr>

<tr>
<td class="org-left"><code>query</code></td>
<td class="org-left">always ask, even when prompts are off</td>
</tr>

<tr>
<td class="org-left"><code>no</code> / <code>never</code></td>
<td class="org-left">never run (also <code>:noeval</code>)</td>
</tr>

<tr>
<td class="org-left"><code>never-export</code></td>
<td class="org-left">run by hand, but not when exporting</td>
</tr>

<tr>
<td class="org-left"><code>query-export</code></td>
<td class="org-left">ask when exporting</td>
</tr>
</tbody>
</table>

    return "you will never see me"

**Try:** press `<C-c><C-c>` in the `:eval no` block above.

**Expect:** nothing is inserted; a message says evaluation is disabled.


<a id="org3d780a4"></a>

## Removing and folding results

-   `<prefix>bk` in a block deletes its result. With a count
    (`1<prefix>bk`, Emacs `C-u C-c C-v k`) it deletes every result in the
    buffer.
-   `<Tab>` on a `#+RESULTS:` line folds the result;
    `:Org babel_hide_all_results` folds all of them.

    return { "alpha", "beta", "gamma", "delta" }

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<tbody>
<tr>
<td class="org-left">alpha</td>
<td class="org-left">beta</td>
<td class="org-left">gamma</td>
<td class="org-left">delta</td>
</tr>
</tbody>
</table>

**Try:** put the cursor in the block above and press `<prefix>bk`.

**Expect:** the `#+RESULTS:` line and the four-column table under it are
gone. Press `<C-c><C-c>` to bring them back, then `<Tab>` on the
`#+RESULTS:` line to fold and unfold them.


<a id="orgcda24b4"></a>

## Running many blocks at once

-   `<prefix>bb` runs every block (and `#+CALL:` line and inline block) of
    the buffer, from top to bottom.
-   `<prefix>bs` runs every block of the current subtree.

Each one is confirmed unless prompts are off. Blocks with `:eval no` are
skipped. Don't use `<prefix>bb` on this whole file before the "Library of
Babel" exercise: its `#+CALL:` lines stop the run with an error until the
library is loaded, and the session blocks start shells.

**Try:** on the "Running a block" heading press `<prefix>bs`.

**Expect:** every block of this section runs once (answer `y` each time);
the `:eval no` blocks are skipped and keep having no result.


<a id="org14c171c"></a>

## Moving between blocks

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Moves to</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&lt;prefix&gt;bn</code></td>
<td class="org-left">the next <code>#+begin_src</code> line</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bp</code></td>
<td class="org-left">the previous <code>#+begin_src</code> line</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bu</code></td>
<td class="org-left">the head of the block the cursor is in</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bg</code></td>
<td class="org-left">a named block (asks for the name)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;br</code></td>
<td class="org-left">a named result (asks for the name)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bm</code></td>
<td class="org-left">selects the block body in Visual mode</td>
</tr>
</tbody>
</table>

**Try:** on this line press `<prefix>bp` twice, then `<prefix>bn`.

**Expect:** the cursor jumps from `#+begin_src` line to `#+begin_src` line.
`<prefix>bg` then `square` jumps to the `square` block in "Named blocks".


<a id="orgfe04580"></a>

# Languages

The language after `#+begin_src` picks the interpreter. The plugin enables
shells, python, lua, js/ts, ruby, perl, php, R, go, rust, sqlite, sql, C,
C++, D, awk and emacs-lisp out of the box (`babel.languages`).


<a id="orgbc77e6e"></a>

## Lua: runs inside Neovim

Lua needs nothing installed. A block that is a single expression returns
its value; otherwise use `return`. `print` goes to the output (see
"Results").

    local words = vim.split("the quick brown fox", " ")
    return #words .. " words, longest: " .. vim.iter(words):fold("", function(a, w)
      return #w > #a and w or a
    end)

    4 words, longest: quick

Several return values are joined with `, =; =nil` gives `nil`:

    return "a", 2, true

    a, 2, true

    return nil

    nil

A Lua table that is a list becomes an Org list-table (one row); a list of
lists becomes a table; a table with keys becomes a two-column table sorted
by key:

    return { { "x", "x²" }, { 1, 1 }, { 2, 4 }, { 3, 9 } }

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">x</td>
<td class="org-right">x²</td>
</tr>

<tr>
<td class="org-right">1</td>
<td class="org-right">1</td>
</tr>

<tr>
<td class="org-right">2</td>
<td class="org-right">4</td>
</tr>

<tr>
<td class="org-right">3</td>
<td class="org-right">9</td>
</tr>
</tbody>
</table>

    return { lang = "lua", version = 5.1, jit = jit ~= nil }

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<tbody>
<tr>
<td class="org-left">jit</td>
<td class="org-left">true</td>
</tr>

<tr>
<td class="org-left">lang</td>
<td class="org-left">lua</td>
</tr>

<tr>
<td class="org-left">version</td>
<td class="org-left">5.1</td>
</tr>
</tbody>
</table>

**Try:** in the key/value block above add `, os = jit.os` before the closing brace and
press `<C-c><C-c>`.

**Expect:** a fourth row appears, sorted between `lang` and `version`, with
your OS name (`OSX`, `Linux` or `Windows`).

Because the code runs in the editor, a block can act on the editor. This
one counts the headings of this very file:

    local n = 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:match("^%*+ ") then n = n + 1 end
    end
    return n .. " headings in this file"

    50 headings in this file

(`os.exit()` or an endless loop would affect Neovim itself, and
`babel.timeout` cannot stop Lua code.)


<a id="org26715ee"></a>

## Shell

Shell blocks run `sh` (or `bash`, `zsh`, `fish`). By default their
**output** is the result, and it is read like data: one line stays text,
several lines become a table split at tabs, commas or runs of spaces.

    echo "hello from sh"

    hello from sh

    printf 'apples 3\nbananas 12\ncherries 7\n'

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-left">apples</td>
<td class="org-right">3</td>
</tr>

<tr>
<td class="org-left">bananas</td>
<td class="org-right">12</td>
</tr>

<tr>
<td class="org-left">cherries</td>
<td class="org-right">7</td>
</tr>
</tbody>
</table>

Add `:results output` to keep the text as it is (see "Results"):

    printf 'apples 3\nbananas 12\ncherries 7\n'

    apples 3
    bananas 12
    cherries 7

**Try:** in the block above, change `:results output` to `:results value`
and run it.

**Expect:** the result becomes `: 0`: for shells, the "value" is the exit
status. Put back `output`.

Errors: what a program writes to stderr (and a non-zero exit code) goes to
the `*Org-Babel Error Output*` buffer in a split; the result keeps only the
standard output.

    echo "this goes to the result"
    echo "this goes to the error buffer" >&2
    exit 3

**Try:** run the block above.

**Expect:** `: this goes to the result` under `#+RESULTS:`, and a split
named `*Org-Babel Error Output*` that shows the stderr line and the exit
code 3.


<a id="org1709cfb"></a>

## Other languages (need their interpreter)

These show the same idea in other languages. They only run when the
interpreter is installed; the results here were produced by org.nvim.

    return [[n, n**2] for n in range(1, 4)]

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">1</td>
<td class="org-right">1</td>
</tr>

<tr>
<td class="org-right">2</td>
<td class="org-right">4</td>
</tr>

<tr>
<td class="org-right">3</td>
<td class="org-right">9</td>
</tr>
</tbody>
</table>

    console.log(["a", "b", "c"].map((s) => s.toUpperCase()).join("-"))

    A-B-C

    [1, 2, 3].sum * 10

    60

    select 'Mon' as day, 3 as tasks union all select 'Tue', 5;

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">day</th>
<th scope="col" class="org-right">tasks</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">Mon</td>
<td class="org-right">3</td>
</tr>

<tr>
<td class="org-left">Tue</td>
<td class="org-right">5</td>
</tr>
</tbody>
</table>

    BEGIN { for (i = 1; i <= 3; i++) printf "%d%s", i * i, (i < 3 ? " " : "\n") }

    1 4 9

Emacs-lisp blocks run in a separate `emacs --batch` (not in the editor),
and fall back to the formula interpreter of tables when Emacs is missing.


<a id="orgc673174"></a>

# Results

The `:results` header argument decides four things, which can be combined
in one value (`:results output table replace`):

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Group</th>
<th scope="col" class="org-left">Values</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">collection</td>
<td class="org-left"><code>value</code> (default), <code>output</code></td>
</tr>

<tr>
<td class="org-left">type</td>
<td class="org-left"><code>table</code> (<code>vector</code>), <code>list</code>, <code>verbatim</code>, <code>scalar</code>, <code>file</code></td>
</tr>

<tr>
<td class="org-left">format</td>
<td class="org-left"><code>raw</code>, <code>org</code>, <code>drawer</code>, <code>html</code>, <code>latex</code>, <code>code</code>, <code>pp</code>, <code>link</code></td>
</tr>

<tr>
<td class="org-left">handling</td>
<td class="org-left"><code>replace</code> (default), <code>append</code>, <code>prepend</code>, <code>silent</code>, <code>none</code></td>
</tr>
</tbody>
</table>


<a id="orge8b307a"></a>

## value versus output

`value` is what the code returns, `output` what it prints.

    print("printed")
    return "returned"

    returned

    print("printed")
    return "returned"

    printed


<a id="orgfd896ea"></a>

## Types: table, list, verbatim, scalar

A list-like value becomes a table unless you ask otherwise.

    return { "red", "green", "blue" }

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<tbody>
<tr>
<td class="org-left">red</td>
<td class="org-left">green</td>
<td class="org-left">blue</td>
</tr>
</tbody>
</table>

    return { "red", "green", "blue" }

-   red
-   green
-   blue

    printf 'a b\nc d\n'

    a b
    c d

    echo "one two three"

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />
</colgroup>
<tbody>
<tr>
<td class="org-left">one two three</td>
</tr>
</tbody>
</table>

    return { 1, 2, 3 }

    (1 2 3)

Long text (`babel.min_lines_for_block_output`, 10 lines by default) goes
into an example block instead of =: = lines:

    for i = 1, 12 do print("line " .. i) end

    line 1
    line 2
    line 3
    line 4
    line 5
    line 6
    line 7
    line 8
    line 9
    line 10
    line 11
    line 12


<a id="org05944c1"></a>

## Formats: raw, org, drawer, html, code

By default text is quoted with =: =. Other formats insert it differently:

    return "This is *bold* and /italic/."

This is **bold** and *italic*.

    return "- item one\n- item two"

-   item one
-   item two

    return "| a | b |\n| 1 | 2 |"

    | a | b |
    | 1 | 2 |

    return "<b>bold</b>"

<b>bold</b>

    return "print('generated code')"

    print('generated code')

**Try:** run the `raw` block above twice.

**Expect:** the text appears **twice**: a raw result has no end marker, so it
cannot be found and replaced. That is what `drawer` is for: run the drawer
block twice and it stays single.


<a id="orgd22997b"></a>

## :wrap

`:wrap` wraps the result in any block: `:wrap` alone uses
`#+begin_results`, `:wrap src json` a JSON src block, `:wrap example` an
example block, `:wrap export html` an export block. Avoid `:wrap quote` or
`:wrap center`: like in Emacs, those blocks are not recognised as a result,
so every run adds another one instead of replacing it.

    return vim.json.encode({ answer = 42 })

    {"answer":42}

    echo "an example block"

    an example block

    return "Wrapped in a results block."

<div class="results" id="org32a6c99">
<p>
Wrapped in a results block.
</p>

</div>


<a id="org063e364"></a>

## Handling: replace, append, prepend, silent, none

-   `replace` (the default) replaces the old result.
-   `append` / `prepend` add the new result after / before the old one.
-   `silent` shows the value as a message and writes nothing.
-   `none` neither shows nor writes (useful for side effects).

    return os.date("%H:%M:%S")

    15:07:56

**Try:** press `<C-c><C-c>` three times in the block above, a few seconds
apart.

**Expect:** three more times appear under `#+RESULTS:`, each below the
previous one. Change `append` to `prepend` and the newest goes on top.

    return "shown in the message area only"

**Try:** run the `silent` block.

**Expect:** the message `"shown in the message area only"` (quoted, like
Emacs' `%S`) and no `#+RESULTS:` line.


<a id="org8ba8d27"></a>

## :cache

With `:cache yes` the result is stored with a hash of the body and header
arguments: `#+RESULTS[hash]:`. Running the block again does nothing while
the hash matches. Change the body and it runs again.

    return "computed at " .. os.date("%Y-%m-%d")

    computed at 2026-09-28

**Try:** press `<C-c><C-c>` in the block above.

**Expect:** nothing changes in the buffer: the hash still matches and the
cached value is reused. `<prefix>ba` shows the same hash as in
`#+RESULTS[...]:`. Now add a space at the end of the
`return` line and run it again: the hash changes and the date is today's.
A count forces a run: `1<prefix>be` (Emacs `C-u C-c C-c`).


<a id="orga176ef6"></a>

## :file results

With `:results file` and `:file NAME` the result is written to a file and a
link to it is inserted. `:output-dir` says where (and is created).
`<prefix>bo` opens the file.

    echo "Written by babel on a Monday"

**Try:** run the block above, then press `<prefix>bo` in it.

**Expect:** `#+RESULTS:` followed by `[[file:17-babel-out/hello.txt]]`, and
`<prefix>bo` opens that file with the text "Written by babel on a Monday".


<a id="org0307b6a"></a>

# Variables: :var

`:var name=value` defines a variable in the block. Values can be literals,
tables, lists, or the results of other blocks.


<a id="org331091e"></a>

## Literals

Numbers stay numbers, quoted text is a string. Several `:var` can be given
on one line or in separate `:var` arguments.

    return x * y

    42

    return greeting .. ", " .. name .. "!"

    Hello, Ada!

In a shell, variables are shell variables:

    i=0
    while [ "$i" -lt "$n" ]; do echo "hello $who"; i=$((i + 1)); done

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<tbody>
<tr>
<td class="org-left">hello</td>
<td class="org-left">world</td>
</tr>

<tr>
<td class="org-left">hello</td>
<td class="org-left">world</td>
</tr>

<tr>
<td class="org-left">hello</td>
<td class="org-left">world</td>
</tr>
</tbody>
</table>

**Try:** change `n=3` to `n=5` in the `#+begin_src` line above and run it.

**Expect:** five `hello world` rows.

A value that looks like an Emacs Lisp list is a list; a form like `(+ 1 2)`
is evaluated:

    return "#xs = " .. #xs .. ", total = " .. total

    #xs = 3, total = 6


<a id="org6030345"></a>

## Tables and lists as input

A `#+NAME:` makes a table (or a list) available by name. A table arrives as
a list of rows. The header row above the first hline is removed from the
data by default.

<table id="org4787c0a" border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">name</th>
<th scope="col" class="org-right">qty</th>
<th scope="col" class="org-right">price</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">apples</td>
<td class="org-right">12</td>
<td class="org-right">0.50</td>
</tr>

<tr>
<td class="org-left">bananas</td>
<td class="org-right">6</td>
<td class="org-right">0.25</td>
</tr>

<tr>
<td class="org-left">cherry</td>
<td class="org-right">100</td>
<td class="org-right">0.05</td>
</tr>
</tbody>
</table>

    local total = 0
    for _, r in ipairs(rows) do total = total + r[2] * r[3] end
    return string.format("%d rows, total %.2f", #rows, total)

    3 rows, total 12.50

A named plain list arrives as a list of strings:

-   milk
-   eggs
-   bread

    return table.concat(items, " + ")

    milk + eggs + bread

**Try:** add a line `- butter` to the `shopping` list and run the block again.

**Expect:** `: milk + eggs + bread + butter`.

In a shell, a one-column value is a string with one item per line, a table
is lines of tab-separated cells:

    echo "$items" | sort

    bread
    eggs
    milk


<a id="org853d9c8"></a>

## Slices and indexes

`name[i]` picks row `i`, `name[i,j]` one cell, `name[i:j]` a range of rows
(both ends included), `name[,j]` a column and `name[i:j,k:l]` a
rectangle. Indexes are 0-based; negative ones count from the end.

These examples use a table without a header, so row 0 is the first line:

<table id="orge7575d4" border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">11</td>
<td class="org-right">12</td>
<td class="org-right">13</td>
</tr>

<tr>
<td class="org-right">21</td>
<td class="org-right">22</td>
<td class="org-right">23</td>
</tr>

<tr>
<td class="org-right">31</td>
<td class="org-right">32</td>
<td class="org-right">33</td>
</tr>
</tbody>
</table>

    return r

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">21</td>
<td class="org-right">22</td>
<td class="org-right">23</td>
</tr>
</tbody>
</table>

    return c

    13

    return col

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">12</td>
<td class="org-right">22</td>
<td class="org-right">32</td>
</tr>
</tbody>
</table>

    return rows

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">21</td>
<td class="org-right">22</td>
<td class="org-right">23</td>
</tr>

<tr>
<td class="org-right">31</td>
<td class="org-right">32</td>
<td class="org-right">33</td>
</tr>
</tbody>
</table>

    return box

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">12</td>
<td class="org-right">13</td>
</tr>

<tr>
<td class="org-right">22</td>
<td class="org-right">23</td>
</tr>
</tbody>
</table>

    return last

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">31</td>
<td class="org-right">32</td>
<td class="org-right">33</td>
</tr>
</tbody>
</table>

**Try:** change `grid[-1]` to `grid[0:1]` and run it.

**Expect:** a two-row table: `| 11 | 12 | 13 |` and `| 21 | 22 | 23 |`.

In a table **with a header**, like `fruit`, the header row is row 0 and the
hline is row 1 (as in Emacs), so the first data row is row 2:

    return first

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-left">apples</td>
<td class="org-right">12</td>
<td class="org-right">0.5</td>
</tr>
</tbody>
</table>

    return names

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<tbody>
<tr>
<td class="org-left">apples</td>
<td class="org-left">bananas</td>
<td class="org-left">cherry</td>
</tr>
</tbody>
</table>

    return p

    0.05


<a id="org5f1eceb"></a>

## :colnames, :rownames and :hlines

-   `:colnames yes` takes the first row as column names and puts them back
    on a table result of the same width. `:colnames no` keeps the header as
    a data row.
-   `:rownames yes` does the same for the first column.
-   `:hlines yes` keeps the hlines of the input (in Lua they are the string
    `"hline"`).

    for _, r in ipairs(t) do r[3] = r[3] * 2 end
    return t

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">name</th>
<th scope="col" class="org-right">qty</th>
<th scope="col" class="org-right">price</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">apples</td>
<td class="org-right">12</td>
<td class="org-right">1</td>
</tr>

<tr>
<td class="org-left">bananas</td>
<td class="org-right">6</td>
<td class="org-right">0.5</td>
</tr>

<tr>
<td class="org-left">cherry</td>
<td class="org-right">100</td>
<td class="org-right">0.1</td>
</tr>
</tbody>
</table>

    return t

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-left">apples</td>
<td class="org-right">12</td>
<td class="org-right">0.5</td>
</tr>

<tr>
<td class="org-left">bananas</td>
<td class="org-right">6</td>
<td class="org-right">0.25</td>
</tr>

<tr>
<td class="org-left">cherry</td>
<td class="org-right">100</td>
<td class="org-right">0.05</td>
</tr>
</tbody>
</table>

    return #t .. " rows, first cell: " .. t[1][1]

    4 rows, first cell: name

    for _, r in ipairs(t) do r[1] = r[1] * 10 end
    return t

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">name</th>
<th scope="col" class="org-right">qty</th>
<th scope="col" class="org-right">price</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">apples</td>
<td class="org-right">120</td>
<td class="org-right">0.5</td>
</tr>

<tr>
<td class="org-left">bananas</td>
<td class="org-right">60</td>
<td class="org-right">0.25</td>
</tr>

<tr>
<td class="org-left">cherry</td>
<td class="org-right">1000</td>
<td class="org-right">0.05</td>
</tr>
</tbody>
</table>

<table id="org42d1764" border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">a</th>
<th scope="col" class="org-right">1</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">b</td>
<td class="org-right">2</td>
</tr>
</tbody>
<tbody>
<tr>
<td class="org-left">c</td>
<td class="org-right">3</td>
</tr>
</tbody>
</table>

    return t

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-right" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">a</th>
<th scope="col" class="org-right">1</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">b</td>
<td class="org-right">2</td>
</tr>
</tbody>
<tbody>
<tr>
<td class="org-left">c</td>
<td class="org-right">3</td>
</tr>
</tbody>
</table>


<a id="orge3a656f"></a>

## Results of other blocks

A `:var` that names a **block** runs that block and uses its result. The
block does not need a `#+RESULTS:`; arguments can be passed like a call.

    return n * n

    4

    return a + b

    29

A block can produce a table that another block consumes:

    local t = {}
    for i = 1, 4 do t[#t + 1] = { i, i * i, i * i * i } end
    return t

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-right" />

<col  class="org-right" />

<col  class="org-right" />
</colgroup>
<tbody>
<tr>
<td class="org-right">1</td>
<td class="org-right">1</td>
<td class="org-right">1</td>
</tr>

<tr>
<td class="org-right">2</td>
<td class="org-right">4</td>
<td class="org-right">8</td>
</tr>

<tr>
<td class="org-right">3</td>
<td class="org-right">9</td>
<td class="org-right">27</td>
</tr>

<tr>
<td class="org-right">4</td>
<td class="org-right">16</td>
<td class="org-right">64</td>
</tr>
</tbody>
</table>

    local s = 0
    for _, v in ipairs(cubes) do s = s + v end
    return s

    100

`name[]` gives the **body text** of a block instead of its result:

    return vim.trim(code)

    return n * n

**Try:** change the body of `square` to `return n * n * n` and run the
`a + b` block again (without running `square`).

**Expect:** `: 133` (8 + 125): the referenced block is always evaluated.


<a id="orgb02189e"></a>

# Named blocks and #+CALL

`#+NAME: x` above a block names it. `#+CALL: x(args)` runs it with other
arguments and writes the result under the `#+CALL:` line.

    return "Hello, " .. who .. punct

    Hello, world!

    Hello, Ada!

    Hello, Linus?

Hello, Grace!

**Try:** put the cursor on `#+CALL: greet(who`"Ada")= and press
`<C-c><C-c>`. Then change `"Ada"` to `"Margaret"` and run it again.

**Expect:** the line under its `#+RESULTS:` changes to
`: Hello, Margaret!`.

A `#+NAME:` above a `#+CALL:` names its result, so the call itself can be
used as a `:var` value:

    Hello, Ada!

    return s:upper()

    HELLO, ADA!

**Try:** `<prefix>br` then `ada`.

**Expect:** the cursor jumps to the `#+RESULTS: ada` line.


<a id="org2c62ff8"></a>

## Inline source blocks and calls

Inside a paragraph, a small block is written `src_` followed by the
language and the code in braces, and a call is written `call_` followed by
the block name and its arguments in parentheses. Header arguments go in
square brackets after the language. `<C-c><C-c>` on one of them inserts
the result right after it, wrapped in a `{{{results(...)}}}` macro (which
exports as the bare value).

Two times three is `return 2 * 3` and the square
of nine is . Header arguments go in
brackets: `echo "hi from sh"` .

**Try:** in the paragraph above, delete the first `{{{results(...)}}}` (the
one with the 6), put the cursor on the inline lua block before it and
press `<C-c><C-c>`.

**Expect:** the same `{{{results(...)}}}` with `6` comes back. Running it
again replaces it rather than adding a second one.

Raw: `return 6 * 7`

**Try:** press `<C-c><C-c>` on the raw block in the line above.

**Expect:** the line reads `Raw:` then the block, then a space and a bare
`42`. A table or list result cannot be inlined: changing the code to
return `{1, 2}` gives the message "Inline error: list result cannot be
used".


<a id="orgbb990c9"></a>

# Noweb: blocks inside blocks

With `:noweb yes`, a line containing `<<name>>` is replaced by the body of
the block named `name` (before running and when tangling). This is
"literate programming": write the parts where they are explained, and
assemble them elsewhere.

    local function shout(s) return s:upper() .. "!" end

    <<helper-functions>>
    return shout("noweb works")

    NOWEB WORKS!

**Try:** in the second block press `<prefix>bv`.

**Expect:** a split with the expanded body: the `local function shout` line
in place of `<<helper-functions>>`. Close it with `:q`.

The text before a reference is repeated on every inserted line (handy for
comments or indentation):

    echo one
    echo two

    <<two-lines>>
    # prefix: <<two-lines>>

    one
    two


<a id="org16cf1a1"></a>

## Inserting a result: <a id="org72e7644"></a>

With parentheses, the reference is replaced by the **result** of running the
block, not its body:

    return "square(7) = <<square(n=7)>>"

    square(7) = 49


<a id="orga2c3f62"></a>

## :noweb-ref: collecting blocks

Several blocks can share a `:noweb-ref` instead of a name; a reference then
inserts all of them, joined with a newline (`:noweb-sep` changes it).

    echo "step 1: fetch"

    echo "step 2: build"

    <<steps>>
    echo "done"

    step 1: fetch
    step 2: build
    done

**Try:** copy one of the two `:noweb-ref steps` blocks, change its text to
`"step 3: test"` and run the last block.

**Expect:** four lines of output: step 1, step 2, step 3, done.


<a id="org5119fb4"></a>

## When noweb applies

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left"><code>:noweb</code></th>
<th scope="col" class="org-left">Expanded when&hellip;</th>
<th scope="col" class="org-left">On export</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>no</code> (default)</td>
<td class="org-left">never</td>
<td class="org-left"><code>&lt;&lt;ref&gt;&gt;</code> kept</td>
</tr>

<tr>
<td class="org-left"><code>yes</code></td>
<td class="org-left">running, tangling, exporting</td>
<td class="org-left">expanded</td>
</tr>

<tr>
<td class="org-left"><code>tangle</code></td>
<td class="org-left">tangling only</td>
<td class="org-left"><code>&lt;&lt;ref&gt;&gt;</code> kept</td>
</tr>

<tr>
<td class="org-left"><code>eval</code></td>
<td class="org-left">running only</td>
<td class="org-left">kept</td>
</tr>

<tr>
<td class="org-left"><code>no-export</code></td>
<td class="org-left">running and tangling</td>
<td class="org-left"><code>&lt;&lt;ref&gt;&gt;</code> kept</td>
</tr>

<tr>
<td class="org-left"><code>strip-export</code></td>
<td class="org-left">running and tangling</td>
<td class="org-left">the reference removed</td>
</tr>

<tr>
<td class="org-left"><code>strip-tangle</code></td>
<td class="org-left">running and exporting</td>
<td class="org-left">removed on tangle</td>
</tr>

<tr>
<td class="org-left"><code>tangle-eval</code></td>
<td class="org-left">running and tangling</td>
<td class="org-left"><code>&lt;&lt;ref&gt;&gt;</code> kept</td>
</tr>
</tbody>
</table>

    echo "before"
    <<two-lines>>

**Try:** run the `:noweb tangle` block above.

**Expect:** the result is `: before`, and the `*Org-Babel Error Output*`
split shows a syntax error about `<<two-lines>>` (it is not valid shell)
and "exited with code 2". Change `tangle` to `yes` and it prints `before`,
`one` and `two`.


<a id="orgd7dcd96"></a>

# Sessions

Without a session every run starts a fresh interpreter. With
`:session [name]` blocks of the same language and name share a live
interpreter (a REPL), so variables and functions persist between blocks.


<a id="org90f946b"></a>

## Lua sessions

A Lua session keeps its globals inside Neovim (nothing to install):

    counter = (counter or 0) + 1
    return "counter is " .. counter

    counter is 1

    return "the other block sees counter = " .. counter

    the other block sees counter = 1

**Try:** run the first block three times, then the second one.

**Expect:** the first block shows `counter is 1`, then `2`, then `3` (each
Neovim starts with a fresh session). The second block then shows
`the other block sees counter = 3`: they share `counter`. Without `:session`
the second block would fail (`counter` would be nil).


<a id="org783583e"></a>

## Shell sessions

A shell session keeps the working directory, variables and functions. It
runs in a terminal buffer named `*name*` (`*shell*` for the default
session).

    cd /tmp
    greeting="set in the first block"

    pwd
    echo "$greeting"

**Try:** run the two blocks above in order.

**Expect:** the first one gets an empty `#+RESULTS:` (it prints nothing);
the second one prints `/tmp` and `set in the first block`.
Without the session it would print the directory of this file and an
empty line.

**Try:** in the second block press `<prefix>bz`.

**Expect:** a split with the `*work*` terminal buffer. Enter Insert mode,
type `echo $greeting` and `<CR>`: the REPL answers "set in the first
block". Define `x=5` there; a block with `:session work` running
`echo $x` now prints `5`.

Other session keys:

-   `<prefix>bZ` shows the session and also opens the edit buffer.
-   `<prefix>bl` sends the block to its session and shows the session.
-   `<prefix>bK` kills the session (the next run starts a fresh one).


<a id="org7d4c8a2"></a>

## :async

Every evaluation already runs in the background, so Neovim never freezes.
With `:async yes` (or just `:async`) on a session block, a placeholder id
is written into `#+RESULTS:` at once and replaced by the result when it
arrives, even if you keep editing in between (Lua sessions finish at once
and ignore it).

    sleep 3
    echo "finished after 3 seconds"

**Try:** run the block above and keep typing elsewhere in the file.

**Expect:** first a `#+RESULTS:` line with a long random id under it, then
after three seconds that id becomes `: finished after 3 seconds`.


<a id="org91befa8"></a>

# Header arguments at every level

Header arguments can be set in many places. From weakest to strongest:

1.  the defaults (`babel.default_header_args`, per language in
    `babel.languages.LANG.default_header_args`),
2.  `#+PROPERTY: header-args[:LANG] ...` at the top of the file,
3.  a `header-args[:LANG]` property of a heading (the nearest heading that
    sets one wins; `header-args+` adds to the inherited value),
4.  the `#+begin_src` line,
5.  `#+HEADER:` lines above the block (the last one wins).

This file starts with `#+PROPERTY: header-args:lua :exports both`, so every
Lua block of the file is exported with its code and its results.

**Try:** in any Lua block of this file (outside the next subtree, which
sets its own) press `<prefix>bI`.

**Expect:** a message listing the merged header arguments. Under
"Properties" a line reads `:header-args:lua` followed by `:exports both`,
and under "Header Arguments" there is `:exports both` (with `:cache no`,
`:results replace`, `:session none` and the other defaults). In a `sh`
block the `:header-args:sh` line says `nil` and `:exports` is `code`.


<a id="orge3d1bd6"></a>

## A subtree with its own header arguments

Every Lua block below this heading gets `base` and `:results verbatim`.
The heading's `header-args:lua` **replaces** the file's
`#+PROPERTY: header-args:lua :exports both` (the nearest one wins), so
`<prefix>bI` here shows `:exports code`. Writing the property as
`:header-args:lua+:` would add to the inherited value instead.

    return base + 1

    101

    return base + 1

    6

    return base + extra

    1100

**Try:** change `:var base=100` in the `:PROPERTIES:` drawer to
`:var base=200` and run the first block of this subtree.

**Expect:** `: 201`.


<a id="org09ddd66"></a>

## Checking and inserting header arguments

-   `<prefix>bj` inserts a header argument on the `#+begin_src` line, with
    completion of names and values.
-   `<prefix>bc` reports a header argument that looks like a misspelt one.

    print("typo")

**Try:** press `<prefix>bc` in the block above.

**Expect:** the error `Supplied header "resluts" is suspiciously close to
"results"`. Fix the typo and press it again: "No suspicious header
arguments found."

**Try:** in the same block press `<prefix>bj`, pick `results`, then `silent`.

**Expect:** = :results silent= is appended to the `#+begin_src` line.


<a id="org9cb87b2"></a>

## :dir, :prologue, :epilogue, :cmdline

-   `:dir PATH` runs the block in that directory (`:mkdirp yes` creates it).
-   `:prologue` / `:epilogue` add code before / after the body.
-   `:cmdline` passes arguments to the interpreter.

    pwd

    /tmp

    echo middle

    start
    middle
    end

    echo "$# arguments: $1 and $2"

    2 arguments: alpha and beta


<a id="orgca7fe95"></a>

# Editing blocks


<a id="org8a52622"></a>

## Edit in a special buffer: <prefix>'

`<prefix>'` (Emacs `C-c '`) opens the body of the block in a separate
buffer whose filetype matches the language, so you get that language's
indentation, completion and LSP. Save with `:w`, or press `<prefix>'` /
`<C-c>'` again to save and close.

    local function add(a, b)
    return a + b
    end
    return add(20, 22)

    42

**Try:** in the block above press `<prefix>'`, then `gg=G` to reindent, then
`<prefix>'`.

**Expect:** you are back in this file. The body is now indented by two
spaces (`edit_src_content_indentation`, 2 like Emacs) and the
`return a + b` line one level more than the other lines. The same key
edits example blocks, =: = fixed-width lines, LaTeX fragments and
footnote definitions.

`<prefix>bx` does the same without opening a window: it asks for Normal
mode keys, runs them in the edit buffer and writes the result back
(`gg=G` reindents the block in one go).


<a id="orga11ae79"></a>

## Split, wrap and insert blocks: <prefix>bd

`<prefix>bd` (`org-babel-demarcate-block`):

-   inside a block: split it in two at the cursor line,
-   on a Visual selection outside blocks: wrap the lines in a new block,
-   elsewhere: insert an empty block (it asks for the language).

    print("first half")
    print("second half")

**Try:** put the cursor on `print("second half")` and press `<prefix>bd`.

**Expect:** two blocks, both `#+begin_src lua :results output`, with one
`print` each.

**Try:** select the next two lines with `V` and `j`, then press `<prefix>bd`.
At the `Lang:` prompt (it proposes the language of the block above), type
`sh` and press `<CR>`.

echo "wrap me"
echo "me too"

**Expect:** the two lines are now inside `#+begin_src sh` &hellip; `#+end_src`.


<a id="orga525676"></a>

## Show the expanded block: <prefix>bv

`<prefix>bv` shows what would actually run: noweb references expanded,
`:var` assignments, `:prologue` and `:epilogue` added.

    <<two-lines>>

**Try:** press `<prefix>bv` in the block above.

**Expect:** a split with `n=3`, `set -e`, `echo one` and `echo two`.


<a id="orgbbdda16"></a>

# Tangling

Tangling writes blocks out to source files. `:tangle FILE` says where
(relative to this Org file); `:tangle yes` uses this file's name with the
language's extension (it would create `examples/17-babel.lua`, so it is
not used here); `:tangle no` (the default) skips the block.

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Tangles</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&lt;prefix&gt;bt</code></td>
<td class="org-left">every block of this file (<code>:Org tangle</code>)</td>
</tr>

<tr>
<td class="org-left"><code>1&lt;prefix&gt;bt</code></td>
<td class="org-left">only the block at the cursor (Emacs <code>C-u C-c C-v t</code>)</td>
</tr>

<tr>
<td class="org-left"><code>2&lt;prefix&gt;bt</code></td>
<td class="org-left">the blocks with the same <code>:tangle</code> file as the cursor</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;bf</code></td>
<td class="org-left">another Org file (asks for its name)</td>
</tr>
</tbody>
</table>

The blocks below write into `examples/17-babel-out/`. `:mkdirp yes`
creates the directory. Delete it afterwards with `rm -r examples/17-babel-out`.


<a id="orgfcf7059"></a>

## A small shell script

    echo "Hello from a tangled script"

    echo "Second block, same file"

**Try:** press `<prefix>bt`, then in a shell run
`sh examples/17-babel-out/hello.sh` (or `:!sh %:h/17-babel-out/hello.sh`).

**Expect:** the message says the files were tangled; the script prints both
lines. `:e examples/17-babel-out/hello.sh` shows `#!/bin/sh` on line 1, then
the two `echo` lines separated by a blank line (`:padline no` removes it).


<a id="org37dc0a3"></a>

## A Lua module with link comments and noweb

`:comments link` wraps each block in comments that link back here, so
`:Org tangle_jump` in the tangled file jumps to the Org block and
`:Org detangle` copies edits back. `:comments org` also writes the Org text
before the block as comments.

    local function double(x) return 2 * x end

    local M = {}
    <<mod-helpers>>
    function M.quadruple(x) return double(double(x)) end
    return M

**Try:** with the cursor in the block above press `1<prefix>bt` (tangle only
this block). Open `examples/17-babel-out/mymod.lua`.

**Expect:** the file starts with
`-- [[file:../17-babel.org::*A Lua module with link comments and noweb][A Lua module with link comments and noweb:2]]`
(`:2` because it is the second block of that heading), has
`local function double` where `<<mod-helpers>>` was, and ends with a
`-- A Lua module with link comments and noweb:2 ends here` line. In that
file, put the cursor inside the code and run `:Org tangle_jump`: you land
back on this block.

**Try:** now load the module from a Lua block:

    local path = vim.fn.expand("%:p:h") .. "/17-babel-out/mymod.lua"
    if vim.fn.filereadable(path) == 0 then return "tangle it first" end
    return dofile(path).quadruple(10)

**Expect:** `: 40` once tangled, `: tangle it first` before.


<a id="org8d32f2f"></a>

# Library of Babel

Named blocks of **other** files can be added to the Library of Babel with
`<prefix>bi` (`C-c C-v i`). Then `#+CALL:`, `:var` and noweb find them from
any file, for the rest of the session.

This block tangles a small library file (an Org file with two named Lua
blocks). The commas in front of `#+` lines inside an `org` block are
escapes; tangling removes them.

    #+NAME: lib-add
    #+begin_src lua :var a=1 b=2
    return a + b
    #+end_src
    
    #+NAME: lib-shout
    #+begin_src lua :var s="hi"
    return s:upper() .. "!"
    #+end_src

**Try:**

1.  In the `org` block press `1<prefix>bt` (writes
    `examples/17-babel-out/library.org`).
2.  Press `<prefix>bi` and answer `examples/17-babel-out/library.org`
    (the path is relative to the directory Neovim was started in).
3.  Put the cursor on each `#+CALL:` line and press `<C-c><C-c>`.

**Expect:** step 2 says "2 src blocks added to Library of Babel"; step 3
writes `: 42` and `: LIBRARY!` under the calls. `<prefix>bi` with an
empty answer ingests the current buffer.


<a id="org8f01684"></a>

# Exporting code and results

`:exports` says what the export shows: `code` (the default), `results`,
`both` or `none`. When exporting, blocks with `:exports results` or `both`
are evaluated first (`babel.evaluate_on_export`, asked like any
evaluation). This file sets `:exports both` for Lua (see "Header arguments
at every level").

    echo "only this line appears in the export"

    only this line appears in the export

**Try:** turn off the prompts first (export evaluates every Lua block of
this file, which has `:exports both`):
`:lua require("org.config").opts.babel.confirm_evaluate = false`. Then
export to plain text with `<prefix>e` then `t` then `A` (ASCII to a
buffer) and search for "only this line" with `/only this line`.

**Expect:** the output shows the line in a box, but not the `echo` command.
With `babel.evaluate_on_export = false` nothing is evaluated and
`:exports` is ignored (as in Emacs with `org-export-use-babel` nil): the
code and the existing `#+RESULTS:` are both exported. See
[19-export.org](19-export.md) for the exporters.


<a id="orgc2b38a0"></a>

# Further reading

-   `:h org-babel` (running, results, sessions, languages, header arguments)
-   `:h org-babel-edit-special` (`<prefix>'`)
-   `:h org-keymaps` (the Babel keys), `:h org-emacs-keys` (`C-c C-v` keys)
-   `:h org-table-calc` (Lisp forms in header arguments, `org-sbe`)
-   [15-tables.org](15-tables.md), [16-spreadsheet.org](16-spreadsheet.md) (tables that blocks read)
-   [18-dynamic-blocks.org](18-dynamic-blocks.md) (other generated content)

