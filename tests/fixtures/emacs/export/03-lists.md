
# Table of Contents

1.  [How to use this file](#org32b315a)
    1.  [Keys in this file](#org2872d7b)
2.  [Unordered lists](#org3030266)
    1.  [Groceries](#orgafc9f12)
    2.  [Where a list ends](#org28d6e92)
3.  [Ordered lists](#orgc5d4884)
    1.  [Wrong numbers](#org9627784)
    2.  [Counter](#org2fc59bc)
    3.  [Two styles](#org7ce5a9a)
4.  [Description lists](#org6f3b54d)
    1.  [Editors](#orgd82a681)
5.  [Inserting items](#orgc4eb537)
    1.  [Weekend](#org1183b91)
    2.  [Spaced items](#org1a9b2bc)
6.  [Bullet styles](#org9a91767)
    1.  [Cycle me](#org3d780a4)
7.  [Moving between items](#orgcda24b4)
    1.  [People](#orgd1986c9)
8.  [Indenting and outdenting](#org2ee9fa0)
    1.  [Indent rules](#orgd2d6e17)
    2.  [Outdent rules](#org4f04a7e)
9.  [Moving items](#org8457a29)
    1.  [Numbered to reorder](#org97668aa)
    2.  [Boxes to reorder](#orgcc47755)
10. [Converting items, text and headlines](#orge5cb850)
    1.  [Text to items](#orgbc77e6e)
    2.  [Items to headlines](#orgd54f3f3)
11. [Checkboxes](#orgde2857d)
    1.  [Packing](#org99967f4)
    2.  [Toggle everything from the headline](#org1fec826)
    3.  [Ordered checklists](#org8242909)
12. [Statistics cookies](#orgfe04580)
    1.  [Party <code>[/]</code> <code>[%]</code>](#org99af24e)
    2.  [Counting the whole tree <code>[/]</code>](#org9b58fed)
    3.  [Cookies without checkboxes](#org1709cfb)
        1.  [Nothing to count <code>[%]</code>](#orgb0f1a4e)
13. [Radio lists](#orgd5b1c41)
    1.  [Coffee size](#orgd39765f)
    2.  [Normal list](#org6d2fcfd)
14. [Sorting lists](#orge8b307a)
    1.  [Fruit list](#org14f7a8f)
    2.  [Chores list](#orgffc7ee1)
    3.  [Meetings list](#org25f39bf)
15. [Checkboxes that block a TODO](#org5befec0)
    1.  [Ship the release](#orgd279195)
16. [List settings](#orga5fd821)
17. [Further reading](#orgef0656a)



<a id="org32b315a"></a>

# How to use this file

Plain lists are the lists you write in the body of an entry: bullets,
numbers, descriptions and checkboxes. Org understands their structure, so
it can renumber them, move items with their sub-items, and count the
checked boxes for you. This file goes from simple lists to checkbox
statistics.

Start Neovim from the root of the repository with the bundled config:

    nvim -u examples/minimal_init.lua examples/03-lists.org

-   The file opens folded. `<Tab>` on a heading opens it, `<S-Tab>` cycles
    the whole buffer.
-   `<prefix>` means `<leader>o` (`<Space>o` with the bundled config). `g?`
    lists every key of the buffer.
-   `u` undoes; `git checkout examples/03-lists.org` restores the file.
-   **Try:** lines are exercises, **Expect:** lines say what you should see.
-   Lines starting with =# = are comments: notes for you. A comment line in
    column 0 ends a list, so comments are placed above or below lists, never
    between their items.
-   The bundled config draws checkboxes as icons: `[ ]` as an empty box,
    `[-]` as `◐` and `[X]` as `✓`. The text in the file does not change.
-   "On an item" means the cursor is on the first line of the item, usually
    on its text (not in column 0).


<a id="org2872d7b"></a>

## Keys in this file

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">What it does</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&lt;M-CR&gt;</code></td>
<td class="org-left">new item (Normal mode: after this one)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;M-S-CR&gt;</code></td>
<td class="org-left">new item with a checkbox</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;is</code></td>
<td class="org-left">new sub-item (indented)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;Tab&gt;</code> (Insert mode)</td>
<td class="org-left">on an empty item: cycle its indentation</td>
</tr>

<tr>
<td class="org-left"><code>&lt;Tab&gt;</code></td>
<td class="org-left">on an item with sub-items: fold / unfold</td>
</tr>

<tr>
<td class="org-left"><code>&lt;S-Right&gt;</code> <code>&lt;S-Left&gt;</code></td>
<td class="org-left">cycle the bullet style of the list</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;hb</code> / <code>&lt;C-c&gt;-</code></td>
<td class="org-left">cycle the bullet style</td>
</tr>

<tr>
<td class="org-left"><code>&lt;S-Down&gt;</code> <code>&lt;S-Up&gt;</code></td>
<td class="org-left">next / previous item of the same level</td>
</tr>

<tr>
<td class="org-left"><code>&gt;&gt;</code> <code>&lt;&lt;</code> / <code>&lt;M-l&gt;</code> <code>&lt;M-h&gt;</code></td>
<td class="org-left">indent / outdent the item</td>
</tr>

<tr>
<td class="org-left"><code>&gt;s</code> <code>&lt;s</code> / <code>&lt;M-L&gt;</code> <code>&lt;M-H&gt;</code></td>
<td class="org-left">indent / outdent the item and its children</td>
</tr>

<tr>
<td class="org-left"><code>&lt;M-k&gt;</code> <code>&lt;M-j&gt;</code></td>
<td class="org-left">move the item (with sub-items) up / down</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-Space&gt;</code></td>
<td class="org-left">toggle a checkbox</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-c&gt;</code></td>
<td class="org-left">toggle a checkbox, or repair the list</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-x&gt;&lt;C-b&gt;</code></td>
<td class="org-left">toggle checkbox (Emacs key)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;#</code> / <code>&lt;C-c&gt;#</code></td>
<td class="org-left">update statistics cookies</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;-</code></td>
<td class="org-left">toggle between item and text / headline</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;*</code></td>
<td class="org-left">turn the item into a headline</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-*&gt;</code></td>
<td class="org-left">turn the whole list into a subtree</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;hs</code></td>
<td class="org-left">sort the list</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-x&gt;&lt;C-r&gt;</code></td>
<td class="org-left">toggle a radio button</td>
</tr>
</tbody>
</table>


<a id="org3030266"></a>

# Unordered lists

An item starts with a bullet followed by a space: `-`, `+`, or `*` (a star
only when the item is indented, because a star in column 0 starts a
headline). Lines that belong to an item are indented past its bullet.
Items indented under another item form a sub-list.

A list ends:

-   at a line that is indented at or left of the first bullet (and is not a
    new item),
-   at a headline,
-   or after **two** blank lines in a row.

**Try:** open "Groceries" below. Put the cursor on "Fruit" and press `<Tab>`,
then `<Tab>` again.

**Expect:** the first `<Tab>` folds "Fruit": its sub-items "apples" and
"pears" and its second line are hidden, the line ends with `...`. The
second `<Tab>` shows them again. (`cycle_include_plain_lists = true`, the
default, makes items with sub-items or several lines foldable.)


<a id="orgafc9f12"></a>

## Groceries

-   Fruit
    (only the ripe ones)
    -   apples
    -   pears
-   Vegetables
    -   carrots
    -   leeks
        -   the thin ones
-   Bread

This line is not indented, so it is not part of the list.


<a id="org28d6e92"></a>

## Where a list ends

-   first item
-   second item

This paragraph comes after two blank lines: the list above has ended.

    - this looks like an item
    - but it is example text


<a id="orgc5d4884"></a>

# Ordered lists

Ordered bullets are a number followed by `.` or `)`: `1.`, `1)`. You never
renumber by hand: every list command renumbers the list when it changes it.
If the numbers are wrong (you typed them, or pasted lines), `<C-c><C-c>` on
the first line of an item repairs the whole list.

A counter `[@N]` right after the bullet makes the list continue from N.

**Try:** put the cursor on "Wake up" (in "Wrong numbers") and press
`<C-c><C-c>`.

**Expect:** the numbers become 1, 2, 3, 4:

    1. Wake up
    2. Make coffee
    3. Drink coffee
    4. Work

**Try:** in "Counter", press `<C-c><C-c>` on "Chapter five".

**Expect:** the numbers stay 5, 6, 7: the list starts at the counter.
Change `[@5]` to `[@10]` and press `<C-c><C-c>` again: 10, 11, 12.


<a id="org9627784"></a>

## Wrong numbers

1.  Wake up
2.  Make coffee
3.  Drink coffee
4.  Work


<a id="org2fc59bc"></a>

## Counter

5.  Chapter five
6.  Chapter six
7.  Chapter seven


<a id="org7ce5a9a"></a>

## Two styles

1.  A closing parenthesis
2.  works the same way
    1.  and a sub-list can use its own style
    2.  independently


<a id="org6f3b54d"></a>

# Description lists

A description item has a term, then `::` surrounded by spaces, then the
description. It is an unordered item (`-` or `+`), and it is exported as a
definition list (`<dl>` in HTML).

**Try:** on "Neovim" press `$` (end of line) then `<M-CR>`, type `Emacs`,
press `<Esc>`.

**Expect:** a new description item right after "Neovim", with the separator
already there and the cursor on the term:

    - Emacs ::


<a id="orgd82a681"></a>

## Editors

-   **Org:** a plain-text outliner and organizer
-   **Neovim:** a hyperextensible Vim-based text editor
-   **Plain text:** lasts forever
    and a description can go on over
    several lines.


<a id="orgc4eb537"></a>

# Inserting items

`<M-CR>` (Meta-Return) on an item inserts a new item of the same kind
(bullet, description term) and leaves you in Insert mode. Where:

-   Normal mode, anywhere on the item's first line (even column 0): after
    the item **and its sub-items**.
-   Insert mode: at the cursor. At or before the item text (e.g. `i` in
    column 0) the new item goes above; in the middle of the text, the rest of
    the text moves to the new item.

`<M-S-CR>` does the same but adds an empty checkbox `[ ]`. `<prefix>is`
inserts a sub-item (indented one level). A new item never copies the
checkbox of the current one with `<M-CR>`.

In Insert mode, right after `<M-CR>`, `<Tab>` on the new empty item cycles
its indentation: under the previous item, then back out level by level.

When the items of a list are separated by blank lines, new items get a
blank line too (`blank_before_new_entry = { plain_list_item = "auto" }`).

**Try:** on "Saturday" press `$` and `<M-CR>`, type `Sunday`, `<Esc>`.

**Expect:** `- Sunday` after "Saturday" (and after its sub-item "morning
run"), before "Next week".

**Try:** on "Saturday" press `$` and `<M-S-CR>`, type `Pack`, `<Esc>`.

**Expect:** `- [ ] Pack` after the "Saturday" item.

**Try:** on "Saturday" press `$` and `<prefix>is`, type `evening`, `<Esc>`.

**Expect:** an indented sub-item =  - evening= right below "Saturday".

**Try:** on "Next week" press `A`, then `<M-CR>`, then `<Tab>`, type
`Monday` and `<Esc>`.

**Expect:** =  - Monday= indented under "Next week".

**Try:** on "Split this item" put the cursor on `i` of "item", press `i` and
`<M-CR>`, then `<Esc>`.

**Expect:** two items: `- Split this` and `- item`.


<a id="org1183b91"></a>

## Weekend

-   Saturday
    -   morning run
-   Next week
-   Split this item


<a id="org1a9b2bc"></a>

## Spaced items

-   first

-   second

**Try:** on "second" press `$` and `<M-CR>`, type `third`.

**Expect:** a blank line, then `- third`.


<a id="org9a91767"></a>

# Bullet styles

`<S-Right>` / `<S-Left>` on an item cycle the bullet of **the whole list**
(the item and its siblings) through `-`, `+`, `*`, `1.`, `1)`. The star is
skipped for a list in column 0. Sub-lists keep their own bullets.
`<prefix>hb` and `<C-c>-` cycle forward too.

**Try:** on "alpha" (in "Cycle me") press `<S-Right>` four times.

**Expect:** the bullets of alpha, beta and gamma become `+`, then `1.` `2.`
`3.`, then `1)` `2)` `3)`, then `-` again. The sub-item "beta one" keeps its
`-` bullet (and moves right when the numbers make the bullet wider).


<a id="org3d780a4"></a>

## Cycle me

-   alpha
-   beta
    -   beta one
-   gamma


<a id="orgcda24b4"></a>

# Moving between items

`<S-Down>` / `<S-Up>` jump to the next / previous item **of the same level**,
skipping sub-items.

**Try:** on "Ann" press `<S-Down>` twice.

**Expect:** the cursor goes to "Bob" (skipping "Ann's notes"), then to "Cid".


<a id="orgd1986c9"></a>

## People

-   Ann
    -   Ann's notes
-   Bob
-   Cid


<a id="org2ee9fa0"></a>

# Indenting and outdenting

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Moves</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&gt;&gt;</code> / <code>&lt;&lt;</code>, <code>&lt;M-l&gt;</code> / <code>&lt;M-h&gt;</code></td>
<td class="org-left">the item alone</td>
</tr>

<tr>
<td class="org-left"><code>&gt;s</code> / <code>&lt;s</code>, <code>&lt;M-L&gt;</code> / <code>&lt;M-H&gt;</code></td>
<td class="org-left">the item and its sub-items (subtree)</td>
</tr>
</tbody>
</table>

Org's list rules apply:

-   The first item of a list cannot be indented alone; `<M-L>` / `<M-H>` on
    it move the whole list.
-   An item with sub-items cannot be outdented alone: use `<s` or `<M-H>`.
-   After each change the list is repaired: numbering, bullets, the
    indentation of sub-lists and parent checkboxes.
-   In Visual mode, `<M-l>` / `<M-h>` indent / outdent every selected item.

**Try:** on "Task B" press `>s`.

**Expect:** "Task B" and its sub-item "B detail" move right together; "Task
B" is now a sub-item of "Task A":

    - Task A
      - Task B
        - B detail
    - Task C

**Try:** press `u`, then `>>` on "Task B".

**Expect:** only "Task B" moves; "B detail" stays where it was and becomes
its sibling:

    - Task A
      - Task B
      - B detail

**Try:** press `u`, then `>>` on "Task A".

**Expect:** nothing changes and a message says "At first item: use
S-M-<left/right> to move the whole list".

**Try:** on "Nested parent" (in "Outdent rules") press `<<`.

**Expect:** the message "Cannot outdent an item without its children".
Press `<s` instead: "Nested parent" and "Nested child" both move left.


<a id="orgd2d6e17"></a>

## Indent rules

-   Task A
-   Task B
    -   B detail
-   Task C


<a id="org4f04a7e"></a>

## Outdent rules

-   Top
    -   Nested parent
        -   Nested child


<a id="org8457a29"></a>

# Moving items

`<M-k>` / `<M-j>` (also `<M-Up>` / `<M-Down>`) move an item up / down past
its sibling. Sub-items, extra lines and checkboxes travel with it, and
ordered lists are renumbered.

**Try:** on "Third" press `<M-k>` twice.

**Expect:**

    1. Third
    2. First
    3. Second

The numbers stay in order; only the texts moved.

**Try:** on "Unpacked" press `<M-j>`.

**Expect:** "Unpacked" moves below "Packed" together with its sub-item:

    - [X] Packed
    - [ ] Unpacked
      - [ ] socks


<a id="org97668aa"></a>

## Numbered to reorder

1.  First
2.  Second
3.  Third


<a id="orgcc47755"></a>

## Boxes to reorder

-   [ ] Unpacked
    -   [ ] socks
-   [X] Packed


<a id="orge5cb850"></a>

# Converting items, text and headlines

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">On</th>
<th scope="col" class="org-left">Result</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>&lt;prefix&gt;-</code></td>
<td class="org-left">a text line</td>
<td class="org-left">an item</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;-</code></td>
<td class="org-left">an item</td>
<td class="org-left">a text line (the checkbox stays)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;-</code></td>
<td class="org-left">a headline</td>
<td class="org-left">an item (a TODO keyword becomes a box)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;prefix&gt;*</code></td>
<td class="org-left">an item</td>
<td class="org-left">a headline (<code>[ ]</code> / <code>[X]</code> → TODO / DONE)</td>
</tr>

<tr>
<td class="org-left"><code>&lt;C-c&gt;&lt;C-*&gt;</code></td>
<td class="org-left">an item</td>
<td class="org-left">the whole list becomes a subtree</td>
</tr>
</tbody>
</table>

In Visual mode `<prefix>-` converts every selected line; with a count the
selection becomes a single item.

**Try:** select the three lines "eggs", "flour" and "sugar" (in "Text to
items") with `V` and `2j`, then press `<prefix>-`.

**Expect:**

    - eggs
    - flour
    - sugar

**Try:** in "Items to headlines", on "[ ] Book the venue" press `<C-c><C-*>`.

**Expect:** the list is gone; its items are now child headlines of "Items to
headlines", with checkboxes turned into keywords and sub-items into deeper
headlines:

    *** TODO Book the venue
    *** DONE Send the invitations
    **** DONE Family
    **** DONE Friends


<a id="orgbc77e6e"></a>

## Text to items

eggs
flour
sugar


<a id="orgd54f3f3"></a>

## Items to headlines

-   [ ] Book the venue
-   [X] Send the invitations
    -   [X] Family
    -   [X] Friends


<a id="orgde2857d"></a>

# Checkboxes

An item becomes a task when it starts with a checkbox: `[ ]` (open),
`[X]` (done) or `[-]` (partly done, set automatically).

-   `<C-Space>` (or `<C-c><C-c>`, or Emacs `<C-c><C-x><C-b>`) on the first
    line of an item toggles its box.
-   A parent box follows its children: when some children are done it shows
    `[-]`, when all are done `[X]`. Toggling the parent itself is refused
    ("Cannot toggle this checkbox").
-   With a count: `4<C-c><C-c>` adds (or removes) a checkbox on the item;
    `16<C-c><C-c>` sets `[-]`.
-   In Visual mode, `<C-Space>` toggles every selected item (following the
    state of the first one).
-   On a **headline**, `<C-Space>` toggles every item of its text.

**Try:** in "Packing", toggle "Passport" and "Tickets" with `<C-Space>`.

**Expect:** "Documents" first becomes `[-]` (after Passport), then `[X]`
(after Tickets). "Documents" was never toggled by you.

**Try:** on "Documents" press `<C-c><C-c>`.

**Expect:** nothing changes, and the message "Cannot toggle this checkbox:
all subitems checked" appears. (`<C-Space>` silently leaves it alone.)

**Try:** on "Toothbrush" (no box yet) press `4<C-c><C-c>`.

**Expect:** `- [ ] Toothbrush`. Press `4<C-c><C-c>` again to remove it.

**Try:** select "Shirts", "Socks" and "Shoes" with `V2j` and press
`<C-Space>`.

**Expect:** all three become `[X]`.


<a id="org99967f4"></a>

## Packing

-   [ ] Documents
    -   [ ] Passport
    -   [ ] Tickets
-   Toothbrush
-   [ ] Shirts
-   [ ] Socks
-   [ ] Shoes


<a id="org1fec826"></a>

## Toggle everything from the headline

-   [ ] one
-   [ ] two
-   [ ] three

**Try:** on the headline "Toggle everything from the headline" press
`<C-Space>`.

**Expect:** one, two and three are all checked. Press it again to uncheck
them.


<a id="org8242909"></a>

## Ordered checklists

With the property `ORDERED: t`, the boxes must be checked in order: an
unchecked box blocks the ones after it.

**Try:** press `<C-c><C-c>` on "Step two" (before "Step one").

**Expect:** "Step two" stays unchecked and the message "Cannot toggle this
checkbox: unchecked subitems" appears (the same words as Emacs). Check
"Step one" first; then "Step two" can be checked.

-   [ ] Step one
-   [ ] Step two
-   [ ] Step three


<a id="orgfe04580"></a>

# Statistics cookies

A cookie `[/]` or `[%]` at the end of an item or a headline shows how many
of its checkboxes are done: `[2/5]` or `[40%]`. Type the empty cookie
yourself; Org fills it in and updates it after every toggle. You can put
both on the same line.

-   On an **item**, the cookie counts its direct sub-items.
-   On a **headline**, it counts the top-level items of its text (sub-items are
    counted through their parents), or, when there are no checkboxes, its
    child TODO entries (see [04-todo.org](04-todo.md)).
-   `<prefix>#` (Emacs `<C-c>#`) updates the cookies of the current entry;
    `4<prefix>#` updates every cookie of the buffer.

**Try:** go to "Party <code>[/]</code> <code>[%]</code>" below and press `<prefix>#` on its headline.

**Expect:** the headline shows `[1/3] [33%]` (one of its three top-level
items, "Music", is checked). "Food" shows `[1/2]`.

**Try:** check "Snacks".

**Expect:** "Food" becomes `[X]` with `[2/2]`, and the headline becomes
`[2/3] [66%]`.


<a id="org99af24e"></a>

## Party <code>[/]</code> <code>[%]</code>

-   [-] Food <code>[/]</code>
    -   [X] Cake
    -   [ ] Snacks
-   [X] Music
-   [ ] Invitations


<a id="org9b58fed"></a>

## Counting the whole tree <code>[/]</code>

`COOKIE_DATA` changes what a headline cookie counts: `checkbox` or `todo`
forces one kind, and `recursive` counts every box in the tree, sub-items
included.

**Try:** press `<prefix>#` on this headline.

**Expect:** `[2/7]`: all seven boxes are counted, parents and sub-items
alike (Food, Cake, Snacks, Decoration, Balloons, Lights, Music), and two of
them (Cake and Music) are checked. Without `recursive` the cookie would
count only the three top-level items: `[1/3]`.

-   [-] Food
    -   [X] Cake
    -   [ ] Snacks
-   [ ] Decoration
    -   [ ] Balloons
    -   [ ] Lights
-   [X] Music


<a id="org1709cfb"></a>

## Cookies without checkboxes

When a headline has a cookie but no checkboxes in its text and no child
entries, `<prefix>#` sets it to `[0/0]` or `[100%]`.


<a id="orgb0f1a4e"></a>

### Nothing to count <code>[%]</code>

**Try:** press `<prefix>#` on "Nothing to count".

**Expect:** `[100%]`.


<a id="orgd5b1c41"></a>

# Radio lists

A radio list allows only one checked item: checking one unchecks the
others. Mark the list with `#+attr_org: :radio t` on the line above it;
then `<C-c><C-c>` and `<C-Space>` work like radio buttons.
`<C-c><C-x><C-r>` (`:Org toggle_radio_button`) toggles a radio button in
any list, and `:Org checkbox_radio_mode` makes `<C-c><C-c>` behave that
way in every list of the buffer.

**Try:** in "Coffee size", press `<C-c><C-c>` on "Large".

**Expect:** "Large" is checked and "Medium" is unchecked.

**Try:** in "Normal list", put the cursor on "red" and press
`<C-c><C-x><C-r>`.

**Expect:** "red" is checked and "green" unchecked, although this list has no
`:radio` attribute.


<a id="orgd39765f"></a>

## Coffee size

-   [ ] Small
-   [X] Medium
-   [ ] Large


<a id="org6d2fcfd"></a>

## Normal list

-   [ ] red
-   [X] green
-   [ ] blue


<a id="orge8b307a"></a>

# Sorting lists

`<prefix>hs` (Emacs `<C-c>^`) on an item sorts that item and its siblings.
The menu has fewer keys than for headlines:

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Key</th>
<th scope="col" class="org-left">Sorts by</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>a</code></td>
<td class="org-left">the item text, alphabetically</td>
</tr>

<tr>
<td class="org-left"><code>n</code></td>
<td class="org-left">the number at the start of the text</td>
</tr>

<tr>
<td class="org-left"><code>t</code></td>
<td class="org-left">the first timestamp of the item (or a timer <code>0:05:00 ::</code> term)</td>
</tr>

<tr>
<td class="org-left"><code>x</code></td>
<td class="org-left">checkbox: unchecked <code>[ ]</code> first, then <code>[-]</code>, then <code>[X]</code></td>
</tr>

<tr>
<td class="org-left"><code>f</code></td>
<td class="org-left">a Lua function</td>
</tr>
</tbody>
</table>

Uppercase keys reverse the order; a count makes `a` case-sensitive.
Sub-items travel with their item, and ordered lists are renumbered.

**Try:** on "cherry" press `<prefix>hs` then `a`.

**Expect:** apple, banana (with its sub-item), cherry, numbered 1, 2, 3.

**Try:** on any item of "Chores list" press `<prefix>hs` then `x`.

**Expect:** the open items first, each group in its original order:

    - [ ] vacuum
    - [ ] windows
    - [X] dishes
    - [X] laundry

Press `<prefix>hs` then `X` (reverse) to get the checked ones first.

**Try:** on "Retro" press `<prefix>hs` then `t`.

**Expect:** Kickoff (Oct 1), Review (Oct 14), Retro (Nov 2).


<a id="org14f7a8f"></a>

## Fruit list

1.  cherry
2.  banana
    -   a sub-item stays with banana
3.  apple


<a id="orgffc7ee1"></a>

## Chores list

-   [ ] vacuum
-   [X] dishes
-   [ ] windows
-   [X] laundry


<a id="org25f39bf"></a>

## Meetings list

-   Retro <span class="timestamp-wrapper"><span class="timestamp">&lt;2026-11-02 Mon&gt;</span></span>
-   Meeting: Kickoff <span class="timestamp-wrapper"><span class="timestamp">&lt;2026-10-01 Thu&gt;</span></span>
-   Review <span class="timestamp-wrapper"><span class="timestamp">&lt;2026-10-14 Wed&gt;</span></span>


<a id="org5befec0"></a>

# Checkboxes that block a TODO

With `enforce_todo_checkbox_dependencies = true`, an entry cannot be marked
DONE while it has unchecked boxes. It is off by default; for this session:

    :lua require("org.config").opts.enforce_todo_checkbox_dependencies = true

**Try:** turn it on, then on "Ship the release" press `cit` (next TODO
state).

**Expect:** the entry stays TODO and a message says it is blocked. Check both
boxes and press `cit` again: it becomes DONE.


<a id="orgd279195"></a>

## TODO Ship the release

-   [ ] Tests pass
-   [ ] Changelog written


<a id="orga5fd821"></a>

# List settings

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Option (default)</th>
<th scope="col" class="org-left">Effect</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>blank_before_new_entry.plain_list_item</code> (auto)</td>
<td class="org-left">blank lines between items</td>
</tr>

<tr>
<td class="org-left"><code>cycle_include_plain_lists</code> (<code>true</code>)</td>
<td class="org-left"><code>&lt;Tab&gt;</code> folds items</td>
</tr>

<tr>
<td class="org-left"><code>meta_return_split_line</code> (<code>true</code>)</td>
<td class="org-left"><code>&lt;M-CR&gt;</code> splits the text</td>
</tr>

<tr>
<td class="org-left"><code>enforce_todo_checkbox_dependencies</code> (<code>false</code>)</td>
<td class="org-left">open boxes block DONE</td>
</tr>

<tr>
<td class="org-left"><code>ui.checkboxes</code> (<code>false</code>)</td>
<td class="org-left">icons for the boxes</td>
</tr>
</tbody>
</table>

Not available (Emacs options without an org.nvim equivalent): alphabetical
bullets (`a.`, `org-list-allow-alphabetical`), changing the bullet
automatically when demoting (`org-list-demote-modify-bullet`) and a custom
indentation of sub-lists (`org-list-indent-offset`).

Timer lists (items whose term is a running time, `0:05:12 ::`) are covered
in [20-timers-reminders.org](20-timers-reminders.md).


<a id="orgef0656a"></a>

# Further reading

-   **`:h org-lists`:** lists, checkboxes and cookies
-   **`:h org-radio-list`:** radio buttons
-   **`:h org-meta-return`:** `<M-CR>` in lists
-   **`:h org-promote-demote`:** indentation rules for items
-   **`:h org-sort`:** sorting lists
-   **`:h org-todo-statistics`:** cookies that count TODO entries

