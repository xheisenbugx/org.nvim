-- Generated from the Emacs comparison harness: every case below was run
-- through Emacs Org 9.8.10 (batch, org-todo-keywords TODO NEXT | DONE)
-- and the expected text is Emacs' result.
local config = require("org.config")

local h = {}
function h.keys(k)
  vim.api.nvim_feedkeys(vim.keycode(k), "xt", false)
end
local answers
function h.stub_input(a)
  answers = a
end

local function run(text, fn)
  local lines = vim.split(text, "\n", { plain = true })
  local cl, cc
  for i, l in ipairs(lines) do
    local p = l:find("|", 1, true)
    if p and not cl then
      cl, cc = i, p - 1
      lines[i] = l:sub(1, p - 1) .. l:sub(p + 1)
    end
  end
  local buf = org_buffer(lines, { cl or 1, cc or 0 })
  local msgs = {}
  local notify = vim.notify
  vim.notify = function(m)
    msgs[#msgs + 1] = tostring(m)
  end
  local utils, ui = require("org.utils"), require("org.ui")
  local input, getchar, menu = utils.input, utils.getchar, ui.menu
  answers = {}
  local i = 0
  utils.input = function()
    i = i + 1
    return answers[i]
  end
  utils.getchar = utils.input
  ui.menu = function(opts)
    i = i + 1
    for _, it in ipairs(opts.items) do
      if it.key == answers[i] then
        return it.value
      end
    end
  end
  local ok, err = pcall(fn)
  vim.cmd("stopinsert")
  vim.notify, utils.input, utils.getchar, ui.menu = notify, input, getchar, menu
  assert(ok, err)
  local out = buf_lines(buf)
  while #out > 0 and out[#out]:match("^%s*$") do
    table.remove(out)
  end
  return out, msgs
end

local function case(name, text, fn, expected, message)
  it(name, function()
    local out, msgs = run(text, fn)
    eq(expected, out)
    if message then
      ok(vim.tbl_contains(msgs, message), "message " .. message .. " in " .. vim.inspect(msgs))
    end
  end)
end

describe("emacs parity: L1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "toggle-cb-parent",
    "- [ ] p|arent\n  - [ ] a\n  - [ ] b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [ ] parent",
      "  - [ ] a",
      "  - [ ] b",
    },
    "Cannot toggle this checkbox: unchecked subitems"
  )
  case(
    "toggle-cb-parent-x",
    "- [X] p|arent\n  - [X] a\n  - [X] b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [X] parent",
      "  - [X] a",
      "  - [X] b",
    },
    "Cannot toggle this checkbox: all subitems checked"
  )
  case(
    "toggle-cb-child",
    "- [ ] parent\n  - [ ] a|\n  - [ ] b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [-] parent",
      "  - [X] a",
      "  - [ ] b",
    }
  )
  case(
    "cb-none-cc",
    "- it|em",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- item",
    }
  )
  case(
    "cb-none-cxcb",
    "- it|em",
    function()
      h.keys("<C-c><C-x><C-b>")
    end,
    {
      "- item",
    }
  )
  case(
    "cb-cookie-item",
    "- [ ] parent [/]\n  - [X] a|\n  - [ ] b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [ ] parent [0/2]",
      "  - [ ] a",
      "  - [ ] b",
    }
  )
  case(
    "cb-heading-cookie",
    "* H [/]\n- [ ] a|\n- [X] b\n  - [ ] b1",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "* H [1/2]",
      "- [X] a",
      "- [ ] b",
      "  - [ ] b1",
    }
  )
  case(
    "cb-heading-pct",
    "* H [%]\n- [ ] a|\n- [ ] b\n- [ ] c",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "* H [33%]",
      "- [X] a",
      "- [ ] b",
      "- [ ] c",
    }
  )
  case(
    "todo-cookie",
    "* H [/]\n** TODO a\n** DONE b\n*** TODO c\n** d|",
    function()
      h.keys("<C-c>#")
    end,
    {
      "* H [/]",
      "** TODO a",
      "** DONE b",
      "*** TODO c",
      "** d",
    }
  )
  case(
    "indent-item",
    "- a\n- b|\n- c",
    function()
      h.keys("<M-l>")
    end,
    {
      "- a",
      "  - b",
      "- c",
    }
  )
  case(
    "indent-item-num",
    "1. a\n2. b|\n3. c",
    function()
      h.keys("<M-l>")
    end,
    {
      "1. a",
      "   1. b",
      "2. c",
    }
  )
  case(
    "indent-item-cb",
    "- [ ] a\n- [ ] b|",
    function()
      h.keys("<M-l>")
    end,
    {
      "- [ ] a",
      "  - [ ] b",
    }
  )
  case(
    "indent-first",
    "- a|\n- b",
    function()
      h.keys("<M-l>")
    end,
    {
      "- a",
      "- b",
    },
    "At first item: use S-M-<left/right> to move the whole list"
  )
  case(
    "indent-with-children",
    "- a\n- b|\n  - b1\n- c",
    function()
      h.keys("<M-l>")
    end,
    {
      "- a",
      "  - b",
      "  - b1",
      "- c",
    }
  )
  case(
    "indent-subtree",
    "- a\n- b|\n  - b1\n- c",
    function()
      h.keys("<M-L>")
    end,
    {
      "- a",
      "  - b",
      "    - b1",
      "- c",
    }
  )
  case(
    "outdent-item",
    "- a\n  - b|\n  - c\n- d",
    function()
      h.keys("<M-h>")
    end,
    {
      "- a",
      "- b",
      "  - c",
      "- d",
    }
  )
  case(
    "outdent-top",
    "- a|\n- b",
    function()
      h.keys("<M-h>")
    end,
    {
      "- a",
      "- b",
    },
    "At first item: use S-M-<left/right> to move the whole list"
  )
  case(
    "move-item-down",
    "- a|\n  - a1\n- b\n- c",
    function()
      h.keys("<M-j>")
    end,
    {
      "- b",
      "- a",
      "  - a1",
      "- c",
    }
  )
  case(
    "move-item-last",
    "- a\n- b|",
    function()
      h.keys("<M-j>")
    end,
    {
      "- a",
      "- b",
    },
    "Cannot move this item further down"
  )
  case(
    "move-num",
    "1. a|\n2. b",
    function()
      h.keys("<M-j>")
    end,
    {
      "1. b",
      "2. a",
    }
  )
  case(
    "cycle-bullet",
    "- a|\n- b",
    function()
      h.keys("<S-Right>")
    end,
    {
      "+ a",
      "+ b",
    }
  )
  case(
    "cycle-bullet2",
    "+ a|\n+ b",
    function()
      h.keys("<S-Right>")
    end,
    {
      "1. a",
      "2. b",
    }
  )
  case(
    "cycle-bullet-left",
    "- a|\n- b",
    function()
      h.keys("<S-Left>")
    end,
    {
      "1) a",
      "2) b",
    }
  )
  case(
    "cycle-bullet-indented",
    "- x\n  - a|\n  - b",
    function()
      h.keys("<S-Right><S-Right>")
    end,
    {
      "- x",
      "  * a",
      "  * b",
    }
  )
  case(
    "cycle-bullet-text",
    "- a b|c",
    function()
      h.keys("<S-Right>")
    end,
    {
      "+ a bc",
    }
  )
  case(
    "cycle-bullet-desc",
    "- t :: a|\n- u :: b",
    function()
      h.keys("<S-Right><S-Right><S-Right>")
    end,
    {
      "1) t :: a",
      "2) u :: b",
    }
  )
  case(
    "cc-minus",
    "- a|\n- b",
    function()
      h.keys("<C-c>-")
    end,
    {
      "+ a",
      "+ b",
    }
  )
  case(
    "cc-minus-text",
    "some te|xt",
    function()
      h.keys("<C-c>-")
    end,
    {
      "- some text",
    }
  )
  case(
    "cc-minus-heading",
    "* Head|ing",
    function()
      h.keys("<C-c>-")
    end,
    {
      "- Heading",
    }
  )
  case(
    "cc-star-text",
    "some te|xt",
    function()
      h.keys("<C-c>*")
    end,
    {
      "* some text",
    }
  )
  case(
    "cc-star-item",
    "* H\n- [X] do|ne\n- [ ] todo",
    function()
      h.keys("<C-c>*")
    end,
    {
      "* H",
      "** DONE done",
      "- [ ] todo",
    }
  )
  case(
    "renumber-cc",
    "3. a|\n5. b\n9. c",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "1. a",
      "2. b",
      "3. c",
    }
  )
  case(
    "counter",
    "1. a|\n2. [@5] b\n3. c",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "1. a",
      "5. [@5] b",
      "6. c",
    }
  )
  case(
    "counter-first",
    "1. [@3] a|\n2. b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "3. [@3] a",
      "4. b",
    }
  )
  case(
    "mixed-bullets",
    "- a|\n+ b\n* c",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- a",
      "- b",
      "* c",
    }
  )
  case(
    "next-item",
    "- a|\n  - a1\n- b",
    function()
      h.keys("<S-Down>")
    end,
    {
      "- a",
      "  - a1",
      "- b",
    }
  )
  case(
    "cb-toggle-parent-partial",
    "- [-] p|\n  - [X] a\n  - [ ] b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [-] p",
      "  - [X] a",
      "  - [ ] b",
    },
    "Cannot toggle this checkbox: unchecked subitems"
  )
end)

describe("emacs parity: S1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "promote",
    "* A\n** B|\n*** C\ntext",
    function()
      h.keys("<M-h>")
    end,
    {
      "* A",
      "* B",
      "*** C",
      "text",
    }
  )
  case(
    "promote-level1",
    "* A|\n** B",
    function()
      h.keys("<M-h>")
    end,
    {
      "* A",
      "** B",
    },
    "Cannot promote to level 0.  UNDO to recover if necessary"
  )
  case(
    "demote",
    "* A\n* B|\n** C",
    function()
      h.keys("<M-l>")
    end,
    {
      "* A",
      "** B",
      "** C",
    }
  )
  case(
    "demote-tags",
    "* A\n* B    :tag:|",
    function()
      h.keys("<M-l>")
    end,
    {
      "* A",
      "** B                                                                    :tag:",
    }
  )
  case(
    "demote-subtree",
    "* A\n* B|\n** C",
    function()
      h.keys("<M-L>")
    end,
    {
      "* A",
      "** B",
      "*** C",
    }
  )
  case(
    "promote-subtree",
    "* A\n** B|\n*** C",
    function()
      h.keys("<M-H>")
    end,
    {
      "* A",
      "* B",
      "** C",
    }
  )
  case(
    "demote-in-body",
    "* A\n* B\nbo|dy\n** C",
    function()
      h.keys("<M-l>")
    end,
    {
      "* A",
      "* B",
      "body",
      "** C",
    }
  )
  case(
    "demote-subtree-body",
    "* A\n* B\nbo|dy\n** C",
    function()
      h.keys("<M-L>")
    end,
    {
      "* A",
      "* B",
      "body",
      "** C",
    },
    "This command is active in special context like tables, headlines or items"
  )
  case(
    "move-down",
    "* A|\nbody a\n* B\nbody b\n* C",
    function()
      h.keys("<M-j>")
    end,
    {
      "* B",
      "body b",
      "* A",
      "body a",
      "* C",
    }
  )
  case(
    "move-down-blank",
    "* A|\n\n* B\nbody b\n\n* C",
    function()
      h.keys("<M-j>")
    end,
    {
      "* B",
      "body b",
      "",
      "* A",
      "",
      "* C",
    }
  )
  case(
    "move-down-last-blank",
    "* A|\na\n\n* B\nb",
    function()
      h.keys("<M-j>")
    end,
    {
      "* B",
      "b",
      "* A",
      "a",
    }
  )
  case(
    "move-down-body",
    "* A\nbod|y a\n* B",
    function()
      h.keys("<M-j>")
    end,
    {
      "* A",
      "body a",
      "* B",
    },
    "Cannot drag element forward"
  )
  case(
    "move-up-first",
    "* A|\n* B",
    function()
      h.keys("<M-k>")
    end,
    {
      "* A",
      "* B",
    },
    "Cannot move past superior level or buffer limit"
  )
  case(
    "move-down-child",
    "* P\n** A|\n** B\n* Q",
    function()
      h.keys("<M-j><M-j>")
    end,
    {
      "* P",
      "** B",
      "** A",
      "* Q",
    },
    "Cannot move past superior level or buffer limit"
  )
  case(
    "drag-para",
    "para one|\n\npara two",
    function()
      h.keys("<M-j>")
    end,
    {
      "para two",
      "",
      "para one",
    }
  )
  case(
    "msup-heading",
    "* A\n* B|",
    function()
      h.keys("<M-K>")
    end,
    {
      "* B",
      "* A",
    }
  )
  case(
    "msup-item",
    "- a\n- b|",
    function()
      h.keys("<M-K>")
    end,
    {
      "- b",
      "- a",
    }
  )
  case(
    "msdown-text",
    "one|\ntwo",
    function()
      h.keys("<M-J>")
    end,
    {
      "two",
      "one",
    }
  )
  case(
    "cstar-heading",
    "* Head|ing\ntext",
    function()
      h.keys("<C-c>*")
    end,
    {
      "Heading",
      "text",
    }
  )
  case(
    "cstar-text-under",
    "* H\nsome |text",
    function()
      h.keys("<C-c>*")
    end,
    {
      "* H",
      "** some text",
    }
  )
  case(
    "cstar-item-under",
    "* H\n- [ ] a|\n- [X] b\n- c",
    function()
      h.keys("<C-c>*")
    end,
    {
      "* H",
      "** TODO a",
      "- [X] b",
      "- c",
    }
  )
  case(
    "cminus-heading-todo",
    "* TODO Head|ing :tag:",
    function()
      h.keys("<C-c>-")
    end,
    {
      "- [ ] Heading",
    }
  )
  case(
    "comment",
    "* TODO Head|ing",
    function()
      h.keys("<C-c>;")
    end,
    {
      "* TODO COMMENT Heading",
    }
  )
  case(
    "comment-off",
    "* TODO COMMENT Head|ing",
    function()
      h.keys("<C-c>;")
    end,
    {
      "* TODO Heading",
    }
  )
  case(
    "insert-sub",
    "* A|\nbody\n** C",
    function()
      require("org.structure").insert_subheading()
      vim.cmd("stopinsert")
    end,
    {
      "* A",
      "** ",
      "body",
      "** C",
    }
  )
  case(
    "cret",
    "* Hea|ding\nbody\n** child\n* Next",
    function()
      h.keys("<C-CR>")
    end,
    {
      "* Heading",
      "body",
      "** child",
      "* ",
      "* Next",
    }
  )
  case(
    "csret",
    "* Hea|ding\nbody",
    function()
      h.keys("<C-S-CR>")
    end,
    {
      "* Heading",
      "body",
      "* TODO ",
    }
  )
  case(
    "cret-item",
    "- a|b\n  - sub\n- c",
    function()
      h.keys("<C-CR>")
    end,
    {
      "- ab",
      "  - sub",
      "- c",
      "* ",
    }
  )
  case(
    "cycle-level",
    "* A\n** B\n** |",
    function()
      h.keys("A<Tab><Esc>")
    end,
    {
      "* A",
      "** B",
      "*** ",
    }
  )
end)

describe("emacs parity: S2", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "paste-bol-heading",
    "* A\n** X\nx\n* B\n|* C",
    function()
      local s=require("org.structure")
      vim.api.nvim_win_set_cursor(0,{2,0})
      s.cut_subtree()
      vim.api.nvim_win_set_cursor(0,{3,0})
      s.paste_subtree()
    end,
    {
      "* A",
      "* B",
      "* X",
      "x",
      "* C",
    }
  )
  case(
    "paste-mid-heading",
    "|* A\n** X\nx\n* B\nbody\n* C",
    function()
      local s=require("org.structure")
      vim.api.nvim_win_set_cursor(0,{2,0})
      s.cut_subtree()
      vim.api.nvim_win_set_cursor(0,{2,1})
      s.paste_subtree()
    end,
    {
      "* A",
      "* B",
      "body",
      "* X",
      "x",
      "* C",
    }
  )
  case(
    "paste-in-body-level",
    "|* A\n** B\nbody\n*** C",
    function()
      local s=require("org.structure")
      vim.api.nvim_win_set_cursor(0,{1,0})
      s.copy_subtree()
      vim.api.nvim_win_set_cursor(0,{3,2})
      s.paste_subtree()
    end,
    {
      "* A",
      "** B",
      "body",
      "*** A",
      "**** B",
      "body",
      "***** C",
      "*** C",
    }
  )
  case(
    "clone-repeater",
    "* Meet|\nSCHEDULED: <2024-01-01 Mon +1w>",
    function()
      h.stub_input({"2","+1d"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "SCHEDULED: <2024-01-01 Mon>",
      "* Meet",
      "SCHEDULED: <2024-01-02 Tue>",
      "* Meet",
      "SCHEDULED: <2024-01-03 Wed>",
      "* Meet",
      "SCHEDULED: <2024-01-04 Thu +1w>",
    }
  )
  case(
    "clone-plain",
    "* Meet|\n<2024-01-01 Mon>\n:PROPERTIES:\n:ID: abc\n:END:",
    function()
      h.stub_input({"2","+1w"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "<2024-01-01 Mon>",
      ":PROPERTIES:",
      ":ID: abc",
      ":END:",
      "* Meet",
      "<2024-01-08 Mon>",
      ":PROPERTIES:",
      ":ID: abc",
      ":END:",
      "* Meet",
      "<2024-01-15 Mon>",
      ":PROPERTIES:",
      ":ID: abc",
      ":END:",
    }
  )
  case(
    "clone-inactive",
    "* Meet|\n[2024-01-01 Mon]",
    function()
      h.stub_input({"1","+1d"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "[2024-01-01 Mon]",
      "* Meet",
      "[2024-01-02 Tue]",
    }
  )
  case(
    "clone-neg",
    "* Meet|\n<2024-01-10 Wed>",
    function()
      h.stub_input({"1","-1d"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "<2024-01-10 Wed>",
      "* Meet",
      "<2024-01-09 Tue>",
    }
  )
  case(
    "sort-alpha",
    "* P|\n** b\n** C\n** a",
    function()
      h.stub_input({"a"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** a",
      "** b",
      "** C",
    }
  )
  case(
    "sort-alpha-todo",
    "* P|\n** TODO b\n** a\n** DONE c",
    function()
      h.stub_input({"a"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** a",
      "** TODO b",
      "** DONE c",
    }
  )
  case(
    "sort-num",
    "* P|\n** 10 x\n** 9 y\n** z",
    function()
      h.stub_input({"n"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** z",
      "** 9 y",
      "** 10 x",
    }
  )
  case(
    "sort-todo",
    "* P|\n** DONE a\n** b\n** TODO c\n** NEXT d",
    function()
      h.stub_input({"o"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** TODO c",
      "** NEXT d",
      "** b",
      "** DONE a",
    }
  )
  case(
    "sort-prio",
    "* P|\n** a\n** [#A] b\n** [#C] c",
    function()
      h.stub_input({"p"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** [#A] b",
      "** a",
      "** [#C] c",
    }
  )
  case(
    "sort-time",
    "* P|\n** a\n** b <2024-01-05 Fri>\n** c <2024-01-02 Tue>",
    function()
      h.stub_input({"t"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** c <2024-01-02 Tue>",
      "** b <2024-01-05 Fri>",
      "** a",
    }
  )
  case(
    "sort-time-rev",
    "* P|\n** a\n** b <2024-01-05 Fri>\n** c <2024-01-02 Tue>",
    function()
      h.stub_input({"T"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** a",
      "** b <2024-01-05 Fri>",
      "** c <2024-01-02 Tue>",
    }
  )
  case(
    "sort-alpha-rev",
    "* P|\n** b\n** a\n** c",
    function()
      h.stub_input({"A"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** c",
      "** b",
      "** a",
    }
  )
  case(
    "sort-top",
    "* b|\n* a",
    function()
      h.stub_input({"a"})
      require("org.structure").sort()
    end,
    {
      "* b",
      "* a",
    },
    "Nothing to sort"
  )
  case(
    "sort-list-alpha",
    "- b|\n- C\n- a",
    function()
      h.stub_input({"a"})
      require("org.structure").sort()
    end,
    {
      "- a",
      "- b",
      "- C",
    }
  )
  case(
    "sort-list-num",
    "1. b|\n2. a\n3. c",
    function()
      h.stub_input({"a"})
      require("org.structure").sort()
    end,
    {
      "1. a",
      "2. b",
      "3. c",
    }
  )
  case(
    "sort-list-cb",
    "- [X] a|\n- [ ] b\n- [-] c",
    function()
      h.stub_input({"x"})
      require("org.structure").sort()
    end,
    {
      "- [ ] b",
      "- [-] c",
      "- [X] a",
    }
  )
  case(
    "toggle-item-heading-tree",
    "* TODO A :t:|\n** DONE B\ntext",
    function()
      vim.cmd("normal! ggVG")
      require("org.lists").toggle_item()
    end,
    {
      "- [X] A",
      "  - [X] B",
      "    text",
    }
  )
  case(
    "toggle-heading-items",
    "- [ ] a|\n- [X] b\n- c",
    function()
      vim.cmd("normal! ggVG")
      require("org.structure").toggle_heading()
    end,
    {
      "* TODO a",
      "* DONE b",
      "* c",
    }
  )
  case(
    "toggle-heading-text",
    "* H\nfoo|\nbar",
    function()
      require("org.structure").toggle_heading()
    end,
    {
      "* H",
      "** foo",
      "bar",
    }
  )
  case(
    "toggle-item-text-region",
    "foo|\nbar",
    function()
      vim.cmd("normal! ggVG")
      require("org.lists").toggle_item()
    end,
    {
      "- foo",
      "- bar",
    }
  )
end)

describe("emacs parity: S3", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "sort-todo",
    "* P|\n** DONE a\n** b\n** TODO c\n** NEXT d",
    function()
      h.stub_input({"o"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** TODO c",
      "** NEXT d",
      "** b",
      "** DONE a",
    }
  )
  case(
    "toggle-heading-text-region",
    "* H\n|foo\nbar",
    function()
      h.keys("Vj<Space>o*")
    end,
    {
      "* H",
      "** foo",
      "** bar",
    }
  )
  case(
    "toggle-heading-mixed-region",
    "* H\n|foo\n- item\nbar",
    function()
      h.keys("Vjj<Space>o*")
    end,
    {
      "* H",
      "** foo",
      "- item",
      "** bar",
    }
  )
  case(
    "toggle-item-headings-region",
    "|* A\n** B\n* C",
    function()
      h.keys("Vjj<Space>o-")
    end,
    {
      "- A",
      "  - B",
      "- C",
    }
  )
  case(
    "toggle-item-mixed",
    "* H\n|foo\nbar\n\nbaz",
    function()
      h.keys("Vjjj<Space>o-")
    end,
    {
      "* H",
      "- foo",
      "- bar",
      "",
      "- baz",
    }
  )
  case(
    "toggle-item-single",
    "* H\n|foo\nbar",
    function()
      h.keys("<C-c>-")
    end,
    {
      "* H",
      "- foo",
      "bar",
    }
  )
  case(
    "toggle-item-heading",
    "* TODO A :t:|\ntext",
    function()
      h.keys("<C-c>-")
    end,
    {
      "- [ ] A",
      "text",
    }
  )
  case(
    "toggle-heading-item",
    "* H\n- [ ] a|\n  - b",
    function()
      h.keys("<C-c>*")
    end,
    {
      "* H",
      "** TODO a",
      "  - b",
    }
  )
  case(
    "toggle-heading-heading",
    "* TODO A|\n** B",
    function()
      h.keys("<C-c>*")
    end,
    {
      "TODO A",
      "** B",
    }
  )
end)

describe("emacs parity: K1b", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "cucc-item-add-cb",
    "- it|em\n- other",
    function()
      h.keys("4<C-c><C-c>")
    end,
    {
      "- [ ] item",
      "- other",
    }
  )
  case(
    "cucc-item-rm-cb",
    "- [X] it|em\n- other",
    function()
      h.keys("4<C-c><C-c>")
    end,
    {
      "- item",
      "- other",
    }
  )
  case(
    "cc-item-cont-line",
    "- [ ] item\n  mo|re",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [ ] item",
      "  more",
    },
    "C-c C-c can do nothing useful here"
  )
  case(
    "cc-desc-item",
    "- [ ] term :: de|sc",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [X] term :: desc",
    }
  )
  case(
    "cc-item-in-block",
    "#+begin_example\n- [ ] i|tem\n#+end_example",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "#+begin_example",
      "- [ ] item",
      "#+end_example",
    },
    "C-c C-c can do nothing useful here"
  )
  case(
    "cc-item-counter",
    "1. [@3] [ ] i|tem",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "3. [@3] [X] item",
    }
  )
  case(
    "toggle-cb-no-space",
    "- [ ]it|em",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [ ]item",
    }
  )
  case(
    "cb-stats-nested-noncb",
    "* H [/]\n- [ ] a|\n- b\n- [X] c",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "* H [2/2]",
      "- [X] a",
      "- b",
      "- [X] c",
    }
  )
  case(
    "cb-cookie-recursive",
    "* H [/]\n:PROPERTIES:\n:COOKIE_DATA: checkbox recursive\n:END:\n- [ ] a|\n  - [X] a1\n- [X] b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "* H [3/3]",
      ":PROPERTIES:",
      ":COOKIE_DATA: checkbox recursive",
      ":END:",
      "- [X] a",
      "  - [X] a1",
      "- [X] b",
    }
  )
  case(
    "cb-cookie-both",
    "* H [/]\n- [ ] a|\n** DONE x\n** TODO y",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "* H [1/1]",
      "- [X] a",
      "** DONE x",
      "** TODO y",
    }
  )
  case(
    "item-star-bullet",
    "- a\n  * b|",
    function()
      h.keys("<M-h>")
    end,
    {
      "- a",
      "- b",
    }
  )
  case(
    "indent-nested-ordered",
    "1. a\n2. b|\n3. c",
    function()
      h.keys("<M-l><M-l>")
    end,
    {
      "1. a",
      "   1. b",
      "2. c",
    },
    "Cannot indent the first item of a list"
  )
  case(
    "indent-desc",
    "- a :: x\n- b :: y|",
    function()
      h.keys("<M-l>")
    end,
    {
      "- a :: x",
      "  - b :: y",
    }
  )
  case(
    "outdent-with-children-sub",
    "- a\n  - b|\n    - c\n  - d",
    function()
      h.keys("<M-h>")
    end,
    {
      "- a",
      "  - b",
      "    - c",
      "  - d",
    },
    "Cannot outdent an item without its children"
  )
  case(
    "outdent-subtree",
    "- a\n  - b|\n    - c\n  - d",
    function()
      h.keys("<M-H>")
    end,
    {
      "- a",
      "- b",
      "  - c",
      "  - d",
    }
  )
  case(
    "mret-counter",
    "1. [@4] a|",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "4. [@4] a",
      "5. ",
    }
  )
  case(
    "mret-nested-end",
    "- a\n  - b|\n- c",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "  - b",
      "  - ",
      "- c",
    }
  )
  case(
    "mret-empty-item",
    "- a\n- |",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "- ",
      "- ",
    }
  )
  case(
    "mret-10",
    "9. a\n10. b|",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "1. a",
      "2. b",
      "3. ",
    }
  )
  case(
    "renum-width",
    "8. a|\n9. b\n   more b\n10. c",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "1. a",
      "2. b",
      "   more b",
      "3. c",
    }
  )
end)

describe("emacs parity: K2", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "mret-in-src",
    "* H\n#+begin_src python\n- foo|\n#+end_src",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "* H",
      "#+begin_src python",
      "- foo",
      "* ",
      "#+end_src",
    }
  )
  case(
    "mret-in-example",
    "* H\n#+begin_example\n1. foo|\n#+end_example",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "* H",
      "#+begin_example",
      "1. foo",
      "* ",
      "#+end_example",
    }
  )
  case(
    "mleft-in-src",
    "* H\n#+begin_src python\n  - fo|o\n#+end_src",
    function()
      h.keys("<M-h>")
    end,
    {
      "* H",
      "#+begin_src python",
      "  - foo",
      "#+end_src",
    }
  )
  case(
    "item-after-block",
    "- a\n  #+begin_src sh\n  echo\n  #+end_src\n- b|",
    function()
      h.keys("<M-k>")
    end,
    {
      "- b",
      "- a",
      "  #+begin_src sh",
      "  echo",
      "  #+end_src",
    }
  )
  case(
    "item-ends-dedent",
    "- a\ntext\n- b|",
    function()
      h.keys("<M-k>")
    end,
    {
      "- a",
      "text",
      "- b",
    },
    "Cannot move this item further up"
  )
  case(
    "item-two-blanks",
    "- a\n\n\n- b|",
    function()
      h.keys("<M-k>")
    end,
    {
      "- a",
      "",
      "",
      "- b",
    },
    "Cannot move this item further up"
  )
  case(
    "heading-in-src",
    "* A\n#+begin_src org\n* not heading\n#+end_src\n* B|",
    function()
      h.keys("<M-k>")
    end,
    {
      "* A",
      "#+begin_src org",
      "* B",
      "* not heading",
      "#+end_src",
    }
  )
end)

describe("emacs parity: T2", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "tmpl-empty",
    "* H\n|\nx",
    function()
      h.stub_input({"s"})
      h.keys("i<Cmd>lua require('org.structure').insert_structure_template()<CR><Esc>")
    end,
    {
      "* H",
      "#+begin_src ",
      "#+end_src",
      "x",
    }
  )
  case(
    "tmpl-text",
    "* H\nsome te|xt\nx",
    function()
      h.stub_input({"q"})
      h.keys("i<Cmd>lua require('org.structure').insert_structure_template()<CR><Esc>")
    end,
    {
      "* H",
      "some te",
      "#+begin_quote",
      "#+end_quote",
      "xt",
      "x",
    }
  )
  case(
    "tmpl-text-normal",
    "* H\nsome te|xt\nx",
    function()
      h.stub_input({"q"})
      require("org.structure").insert_structure_template()
      vim.cmd("stopinsert")
    end,
    {
      "* H",
      "some text",
      "#+begin_quote",
      "#+end_quote",
      "x",
    }
  )
  case(
    "tmpl-region",
    "* H\n|a\nb\nc",
    function()
      h.keys("Vj")
      h.stub_input({"q"})
      require("org.structure").insert_structure_template()
    end,
    {
      "* H",
      "#+begin_quote",
      "a",
      "b",
      "#+end_quote",
      "c",
    }
  )
  case(
    "tmpl-region-src",
    "* H\n|* a\nb",
    function()
      h.keys("Vj")
      h.stub_input({"s"})
      require("org.structure").insert_structure_template()
    end,
    {
      "* H",
      "#+begin_src ",
      ",* a",
      "b",
      "#+end_src",
    }
  )
  case(
    "tmpl-indented-item",
    "- item\n  |\n- b",
    function()
      h.stub_input({"e"})
      h.keys("i<Cmd>lua require('org.structure').insert_structure_template()<CR><Esc>")
    end,
    {
      "- item",
      "  #+begin_example",
      "  #+end_example",
      "- b",
    }
  )
  case(
    "tmpl-upper",
    "* H\n|\nx",
    function()
      h.stub_input({"\t", "QUOTE"})
      h.keys("i<Cmd>lua require('org.structure').insert_structure_template()<CR><Esc>")
    end,
    {
      "* H",
      "#+BEGIN_QUOTE",
      "#+END_QUOTE",
      "x",
    }
  )
  case(
    "drawer-headline",
    "* H|\nSCHEDULED: <2024-01-01 Mon>\n:PROPERTIES:\n:A: 1\n:END:\nbody",
    function()
      h.stub_input({"NOTES"})
      require("org.structure").insert_drawer()
      vim.cmd("stopinsert")
    end,
    {
      "* H",
      ":NOTES:",
      "",
      ":END:",
      "",
      "SCHEDULED: <2024-01-01 Mon>",
      ":PROPERTIES:",
      ":A: 1",
      ":END:",
      "body",
    }
  )
  case(
    "drawer-body",
    "* H\nbo|dy\nmore",
    function()
      h.stub_input({"NOTES"})
      h.keys("i<Cmd>lua require('org.structure').insert_drawer()<CR><Esc>")
    end,
    {
      "* H",
      "bo",
      ":NOTES:",
      "",
      ":END:",
      "dy",
      "more",
    }
  )
  case(
    "drawer-bol",
    "* H\n|body\nmore",
    function()
      h.stub_input({"NOTES"})
      require("org.structure").insert_drawer()
      vim.cmd("stopinsert")
    end,
    {
      "* H",
      ":NOTES:",
      "",
      ":END:",
      "body",
      "more",
    }
  )
  case(
    "drawer-region",
    "* H\n|a\nb\n\nc",
    function()
      h.keys("Vjj")
      h.stub_input({"NOTES"})
      require("org.structure").insert_drawer()
    end,
    {
      "* H",
      ":NOTES:",
      "a",
      "b",
      ":END:",
      "",
      "c",
    }
  )
  case(
    "drawer-prop",
    "* H|\nbody",
    function()
      h.keys("4<C-c><C-x>d")
    end,
    {
      "* H",
      ":PROPERTIES:",
      "",
      ":END:",
      "body",
    }
  )
  case(
    "drawer-prop-planning",
    "* H|\nSCHEDULED: <2024-01-01 Mon>\nbody",
    function()
      h.keys("4<C-c><C-x>d")
    end,
    {
      "* H",
      "SCHEDULED: <2024-01-01 Mon>",
      ":PROPERTIES:",
      "",
      ":END:",
      "body",
    }
  )
  case(
    "drawer-invalid",
    "* H\n|x",
    function()
      h.stub_input({"a b"})
      require("org.structure").insert_drawer()
    end,
    {
      "* H",
      "x",
    },
    "Invalid drawer name"
  )
  case(
    "emphasize-word",
    "some |word here",
    function()
      h.keys("ve")
      h.stub_input({"*"})
      require("org.structure").emphasize()
    end,
    {
      "some *word* here",
    }
  )
  case(
    "emphasize-nosel",
    "some |word here",
    function()
      h.stub_input({"*"})
      require("org.structure").emphasize()
      vim.cmd("stopinsert")
    end,
    {
      "some ** word here",
    }
  )
  case(
    "emphasize-replace",
    "some |/word/ here",
    function()
      h.keys("v5l")
      h.stub_input({"*"})
      require("org.structure").emphasize()
    end,
    {
      "some *word* here",
    }
  )
  case(
    "emphasize-remove",
    "some |*word* here",
    function()
      h.keys("v5l")
      h.stub_input({" "})
      require("org.structure").emphasize()
    end,
    {
      "some word here",
    }
  )
  case(
    "emphasize-glued",
    "x|yz",
    function()
      h.keys("v")
      h.stub_input({"/"})
      require("org.structure").emphasize()
    end,
    {
      "x /y/ z",
    }
  )
end)

describe("emacs parity: O1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "sort-time-first",
    "* P|\n** a\nSCHEDULED: <2024-01-10 Wed>\n<2024-01-01 Mon>\n** b\n<2024-01-05 Fri>",
    function()
      h.stub_input({"t"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** b",
      "<2024-01-05 Fri>",
      "** a",
      "SCHEDULED: <2024-01-10 Wed>",
      "<2024-01-01 Mon>",
    }
  )
  case(
    "sort-time-inactive",
    "* P|\n** a\n[2024-01-01 Mon]\n** b\n<2024-01-05 Fri>",
    function()
      h.stub_input({"t"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** a",
      "[2024-01-01 Mon]",
      "** b",
      "<2024-01-05 Fri>",
    }
  )
  case(
    "sort-sched-missing",
    "* P|\n** a\n** b\nSCHEDULED: <2024-01-05 Fri>",
    function()
      h.stub_input({"s"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** b",
      "SCHEDULED: <2024-01-05 Fri>",
      "** a",
    }
  )
  case(
    "sort-sched-missing-rev",
    "* P|\n** a\n** b\nSCHEDULED: <2024-01-05 Fri>\n** c\nSCHEDULED: <2024-01-01 Mon>",
    function()
      h.stub_input({"S"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** a",
      "** b",
      "SCHEDULED: <2024-01-05 Fri>",
      "** c",
      "SCHEDULED: <2024-01-01 Mon>",
    }
  )
  case(
    "sort-prop",
    "* P|\n** a\n:PROPERTIES:\n:N: 10\n:END:\n** b\n:PROPERTIES:\n:N: 9\n:END:\n** c",
    function()
      h.stub_input({"r","N"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** c",
      "** a",
      ":PROPERTIES:",
      ":N: 10",
      ":END:",
      "** b",
      ":PROPERTIES:",
      ":N: 9",
      ":END:",
    }
  )
  case(
    "sort-alpha-link",
    "* P|\n** [[x][Zed]]\n** b\n** COMMENT a",
    function()
      h.stub_input({"a"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** COMMENT a",
      "** b",
      "** [[x][Zed]]",
    }
  )
  case(
    "sort-prio-default",
    "* P|\n** [#C] c\n** none\n** [#A] a",
    function()
      h.stub_input({"p"})
      require("org.structure").sort()
    end,
    {
      "* P",
      "** [#A] a",
      "** none",
      "** [#C] c",
    }
  )
  case(
    "sort-list-num",
    "- 10 x|\n- 9 y\n- z",
    function()
      h.stub_input({"n"})
      require("org.structure").sort()
    end,
    {
      "- z",
      "- 9 y",
      "- 10 x",
    }
  )
  case(
    "sort-list-time",
    "- b <2024-01-05 Fri>|\n- a\n- c <2024-01-01 Mon>",
    function()
      h.stub_input({"t"})
      require("org.structure").sort()
    end,
    {
      "- c <2024-01-01 Mon>",
      "- b <2024-01-05 Fri>",
      "- a",
    }
  )
  case(
    "sort-region",
    "* x\n* c|\n* b\n* a",
    function()
      h.keys("Vjj")
      h.stub_input({"a"})
      require("org.structure").sort()
    end,
    {
      "* x",
      "* a",
      "* b",
      "* c",
    }
  )
end)

describe("emacs parity: P1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "demote-full",
    "* TODO [#A] COMMENT Title :t:|",
    function()
      h.keys("<M-l>")
    end,
    {
      "** TODO [#A] COMMENT Title                                                :t:",
    }
  )
  case(
    "demote-spaces",
    "*   Title   with  spaces|",
    function()
      h.keys("<M-l>")
    end,
    {
      "**   Title   with  spaces",
    }
  )
  case(
    "demote-shorttags",
    "* Title      :t:|",
    function()
      h.keys("<M-l>")
    end,
    {
      "** Title                                                                  :t:",
    }
  )
  case(
    "demote-longtitle",
    "* A very long title that is longer than the tags column position of seventy seven chars :t:|",
    function()
      h.keys("<M-l>")
    end,
    {
      "** A very long title that is longer than the tags column position of seventy seven chars :t:",
    }
  )
  case(
    "demote-cookie",
    "* Title [1/2]|",
    function()
      h.keys("<M-l>")
    end,
    {
      "** Title [1/2]",
    }
  )
  case(
    "demote-wide",
    "* Tïtlé ünïcode :t:|",
    function()
      h.keys("<M-l>")
    end,
    {
      "** Tïtlé ünïcode                                                          :t:",
    }
  )
  case(
    "demote-subtree-drawer",
    "* A|\n:PROPERTIES:\n:X: 1\n:END:\n** B",
    function()
      h.keys("<M-L>")
    end,
    {
      "** A",
      ":PROPERTIES:",
      ":X: 1",
      ":END:",
      "*** B",
    }
  )
end)

describe("emacs parity: R1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "region-indent-items",
    "- a\n|- b\n- c",
    function()
      h.keys("Vj<M-l>")
    end,
    {
      "- a",
      "  - b",
      "  - c",
    }
  )
  case(
    "region-demote-heads",
    "* a\n|* b\n* c",
    function()
      h.keys("Vj<M-l>")
    end,
    {
      "* a",
      "** b",
      "** c",
    }
  )
  case(
    "region-move-lines",
    "|one\ntwo\nthree",
    function()
      h.keys("Vj<M-j>")
    end,
    {
      "three",
      "one",
      "two",
    }
  )
  case(
    "cb-partial-toggle",
    "- [-] a|",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [X] a",
    }
  )
  case(
    "cc-region-cb",
    "- [ ] a|\n- [X] b\n- [ ] c",
    function()
      h.keys("ggVG<C-c><C-x><C-b>")
    end,
    {
      "- [X] a",
      "- [X] b",
      "- [X] c",
    }
  )
end)

describe("emacs parity: C1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "cyc1",
    "* A\n** B\n** |",
    function()
      h.keys("A<Tab><Esc>")
    end,
    {
      "* A",
      "** B",
      "*** ",
    }
  )
  case(
    "cyc2",
    "* A\n** B\n** |",
    function()
      h.keys("A<Tab><Tab><Esc>")
    end,
    {
      "* A",
      "** B",
      "* ",
    }
  )
  case(
    "cyc3",
    "* A\n** B\n** |",
    function()
      h.keys("A<Tab><Tab><Tab><Esc>")
    end,
    {
      "* A",
      "** B",
      "** ",
    }
  )
  case(
    "cyc4",
    "* A\n** B\n** |",
    function()
      h.keys("A<Tab><Tab><Tab><Tab><Esc>")
    end,
    {
      "* A",
      "** B",
      "*** ",
    }
  )
  case(
    "cyc-deep",
    "* A\n** B\n*** C\n*** |",
    function()
      h.keys("A<Tab><Tab><Tab><Tab><Esc>")
    end,
    {
      "* A",
      "** B",
      "*** C",
      "*** ",
    }
  )
  case(
    "icyc1",
    "- a\n- |",
    function()
      h.keys("A<Tab><Esc>")
    end,
    {
      "- a",
      "  - ",
    }
  )
  case(
    "icyc2",
    "- a\n- |",
    function()
      h.keys("A<Tab><Tab><Esc>")
    end,
    {
      "- a",
      "- ",
    }
  )
  case(
    "icyc3",
    "- a\n  - b\n  - |",
    function()
      h.keys("A<Tab><Tab><Tab><Esc>")
    end,
    {
      "- a",
      "  - b",
      "  - ",
    }
  )
end)

describe("emacs parity: F1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "fn-new",
    "* H\nSome text|\n* Other\nbody",
    function()
      vim.api.nvim_win_set_cursor(0,{2,8})
      require("org.footnotes").new_footnote({no_insert=true})
    end,
    {
      "* H",
      "Some text[fn:1]",
      "* Other",
      "body",
      "",
      "* Footnotes",
      "",
      "[fn:1] ",
    }
  )
  case(
    "fn-new-existing",
    "* H\nSome text|\n* Other\nbody\n* Footnotes\n[fn:1] one",
    function()
      vim.api.nvim_win_set_cursor(0,{2,8})
      require("org.footnotes").new_footnote({no_insert=true})
    end,
    {
      "* H",
      "Some text[fn:2]",
      "* Other",
      "body",
      "* Footnotes",
      "",
      "[fn:2] ",
      "[fn:1] one",
    }
  )
  case(
    "fn-new-nosection",
    "* H\nSome text|\n* Other\nbody",
    function()
      require("org.config").opts.footnote_section=false
      vim.api.nvim_win_set_cursor(0,{2,8})
      require("org.footnotes").new_footnote({no_insert=true})
      require("org.config").opts.footnote_section="Footnotes"
    end,
    {
      "* H",
      "Some text[fn:1]",
      "",
      "[fn:1] ",
      "* Other",
      "body",
    }
  )
  case(
    "fn-new-noheadings",
    "Some text|\nmore",
    function()
      vim.api.nvim_win_set_cursor(0,{1,8})
      require("org.footnotes").new_footnote({no_insert=true})
    end,
    {
      "Some text[fn:1]",
      "more",
      "",
      "* Footnotes",
      "",
      "[fn:1] ",
    }
  )
  case(
    "fn-sort",
    "* H\nA[fn:b] B[fn:a]|\n* Footnotes\n[fn:a] aaa\n\n[fn:b] bbb",
    function()
      require("org.footnotes").sort()
    end,
    {
      "* H",
      "A[fn:b] B[fn:a]",
      "",
      "* Footnotes",
      "",
      "[fn:b] bbb",
      "",
      "[fn:a] aaa",
    }
  )
  case(
    "fn-renumber",
    "* H\nA[fn:3] B[fn:1]|\n* Footnotes\n[fn:1] one\n\n[fn:3] three",
    function()
      require("org.footnotes").renumber()
    end,
    {
      "* H",
      "A[fn:1] B[fn:2]",
      "* Footnotes",
      "[fn:2] one",
      "",
      "[fn:1] three",
    }
  )
  case(
    "fn-normalize",
    "* H\nA[fn:x] B[fn::inline]|\n* Footnotes\n[fn:x] xx",
    function()
      require("org.footnotes").normalize()
    end,
    {
      "* H",
      "A[fn:1] B[fn:2]",
      "",
      "* Footnotes",
      "",
      "[fn:1] xx",
      "",
      "[fn:2] inline",
    }
  )
  case(
    "fn-delete",
    "* H\nA[fn:1|] B\n* Footnotes\n[fn:1] one",
    function()
      vim.api.nvim_win_set_cursor(0,{2,4})
      require("org.footnotes").delete()
    end,
    {
      "* H",
      "A B",
      "* Footnotes",
    }
  )
  case(
    "fn-goto-def",
    "* H\nA[fn:|1] B\n* Footnotes\n[fn:1] one",
    function()
      vim.api.nvim_win_set_cursor(0,{2,4})
      require("org.footnotes").footnote_action()
    end,
    {
      "* H",
      "A[fn:1] B",
      "* Footnotes",
      "[fn:1] one",
    }
  )
end)

describe("emacs parity: B1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "star-outdent",
    "- a\n  * b|",
    function()
      h.keys("<M-h>")
    end,
    {
      "- a",
      "- b",
    }
  )
  case(
    "star-outdent-sub",
    "- a\n  * b|\n  * c",
    function()
      h.keys("<M-H>")
    end,
    {
      "- a",
      "- b",
      "  * c",
    }
  )
  case(
    "outdent-top-nonfirst",
    "- a\n- b|",
    function()
      h.keys("<M-h>")
    end,
    {
      "- a",
      "- b",
    },
    "Cannot outdent top-level items"
  )
  case(
    "outdent-sub-top-nonfirst",
    "- a\n- b|",
    function()
      h.keys("<M-H>")
    end,
    {
      "- a",
      "- b",
    },
    "Cannot outdent top-level items"
  )
  case(
    "outdent-children",
    "- a\n  - b|\n    - c\n  - d",
    function()
      h.keys("<M-h>")
    end,
    {
      "- a",
      "  - b",
      "    - c",
      "  - d",
    },
    "Cannot outdent an item without its children"
  )
  case(
    "indent-children-noSub",
    "- a\n- b|\n  - c\n- d",
    function()
      h.keys("<M-l>")
    end,
    {
      "- a",
      "  - b",
      "  - c",
      "- d",
    }
  )
  case(
    "cb-parent",
    "- [ ] p|arent\n  - [ ] a\n  - [ ] b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [ ] parent",
      "  - [ ] a",
      "  - [ ] b",
    },
    "Cannot toggle this checkbox: unchecked subitems"
  )
  case(
    "cb-parent-nocb-children",
    "- [ ] p|arent\n  - a\n  - b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [X] parent",
      "  - a",
      "  - b",
    }
  )
  case(
    "cb-parent-mixed",
    "- [ ] p|arent\n  - [X] a\n  - b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [X] parent",
      "  - [X] a",
      "  - b",
    }
  )
  case(
    "cb-parent-cxcb",
    "- [ ] p|arent\n  - [ ] a",
    function()
      h.keys("<C-c><C-x><C-b>")
    end,
    {
      "- [ ] parent",
      "  - [ ] a",
    }
  )
  case(
    "cb-renumber",
    "1. [@3] [ ] i|tem",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "3. [@3] [X] item",
    }
  )
  case(
    "cb-renumber2",
    "3. [ ] a|\n5. [ ] b",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "1. [X] a",
      "2. [ ] b",
    }
  )
  case(
    "cucc-add",
    "- it|em\n- other",
    function()
      h.keys("4<C-c><C-c>")
    end,
    {
      "- [ ] item",
      "- other",
    }
  )
  case(
    "cucc-rm",
    "- [X] it|em\n- other",
    function()
      h.keys("4<C-c><C-c>")
    end,
    {
      "- item",
      "- other",
    }
  )
  case(
    "cc-cont",
    "- [ ] item\n  mo|re",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- [ ] item",
      "  more",
    },
    "C-c C-c can do nothing useful here"
  )
  case(
    "cc-inblock",
    "#+begin_example\n- [ ] i|tem\n#+end_example",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "#+begin_example",
      "- [ ] item",
      "#+end_example",
    },
    "C-c C-c can do nothing useful here"
  )
  case(
    "mret-inblock",
    "* H\n#+begin_src python\n- foo|\n#+end_src",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "* H",
      "#+begin_src python",
      "- foo",
      "* ",
      "#+end_src",
    }
  )
  case(
    "mleft-inblock",
    "* H\n#+begin_src python\n  - fo|o\n#+end_src",
    function()
      h.keys("<M-h>")
    end,
    {
      "* H",
      "#+begin_src python",
      "  - foo",
      "#+end_src",
    }
  )
  case(
    "mret-cb",
    "- [X] ab|",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- [X] ab",
      "- ",
    }
  )
  case(
    "msret-cb",
    "- [X] ab|",
    function()
      h.keys("A<M-S-CR><Esc>")
    end,
    {
      "- [X] ab",
      "- [ ] ",
    }
  )
  case(
    "msret-nocb",
    "- ab|",
    function()
      h.keys("A<M-S-CR><Esc>")
    end,
    {
      "- ab",
      "- [ ] ",
    }
  )
  case(
    "mret-blank",
    "- a\n\n- b|",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "",
      "- b",
      "",
      "- ",
    }
  )
  case(
    "mret-blank-first",
    "- a|\n\n- b",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "",
      "- ",
      "",
      "- b",
    }
  )
  case(
    "mret-noblank",
    "- a|\n- b",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "- ",
      "- b",
    }
  )
  case(
    "mret-single-then-blank",
    "- a|\n\ntext",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "- ",
      "",
      "text",
    }
  )
  case(
    "mret-multi-para",
    "- a\n\n  para|\n- b",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "",
      "  para",
      "- ",
      "- b",
    }
  )
  case(
    "mret-split-item",
    "- ab|cd",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "- ab",
      "- cd",
    }
  )
  case(
    "mret-item-bol",
    "|- item one",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "- ",
      "- item one",
    }
  )
  case(
    "mret-desc",
    "- t :: a|",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- t :: a",
      "-  :: ",
    }
  )
  case(
    "mret-split-head",
    "* Hea|ding",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* Hea",
      "* ding",
    }
  )
  case(
    "mret-head-end",
    "* Heading|\nbody\n** child",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "* Heading",
      "* ",
      "body",
      "** child",
    }
  )
  case(
    "mret-text-bol",
    "* H\n|some text",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* H",
      "* some text",
    }
  )
  case(
    "mret-text-mid",
    "* H\nsome| text",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* H",
      "some",
      "*  text",
    }
  )
  case(
    "mret-text-nohead",
    "some| text",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "some",
      "*  text",
    }
  )
  case(
    "mret-empty-nohead",
    "|",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* ",
    }
  )
  case(
    "mret-body-end",
    "* H\nbody|\n** c",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "* H",
      "body",
      "* ",
      "** c",
    }
  )
  case(
    "cumret",
    "* H|ead\nbody\n** c\n* B",
    function()
      h.keys("4<M-CR><Esc>")
    end,
    {
      "* Head",
      "body",
      "** c",
      "* ",
      "* B",
    }
  )
  case(
    "cucumret",
    "* A\n** H|ead\nbody\n*** c\n** d\n* B",
    function()
      h.keys("16<M-CR><Esc>")
    end,
    {
      "* A",
      "** Head",
      "body",
      "*** c",
      "** d",
      "** ",
      "* B",
    }
  )
  case(
    "cret-nohead",
    "- a|b\n  - sub\n- c",
    function()
      h.keys("<C-CR>")
    end,
    {
      "- ab",
      "  - sub",
      "- c",
      "* ",
    }
  )
  case(
    "cret-nohead-text",
    "para|graph\nmore\n\nother",
    function()
      h.keys("<C-CR>")
    end,
    {
      "paragraph",
      "more",
      "",
      "other",
      "* ",
    }
  )
end)

describe("emacs parity: B2", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "indent-sub-first",
    "- a|\n- b",
    function()
      h.keys("<M-L>")
    end,
    {
      " - a",
      " - b",
    }
  )
  case(
    "outdent-sub-first-ind",
    " - a|\n - b",
    function()
      h.keys("<M-H>")
    end,
    {
      "- a",
      "- b",
    }
  )
  case(
    "outdent-sub-first-star",
    " * a|\n * b",
    function()
      h.keys("<M-H>")
    end,
    {
      "- a",
      "- b",
    }
  )
  case(
    "outdent-sub-first0",
    "- a|\n- b",
    function()
      h.keys("<M-H>")
    end,
    {
      "- a",
      "- b",
    },
    "Cannot outdent beyond margin"
  )
  case(
    "indent-sub-first-nested",
    "- a|\n  - x\n- b",
    function()
      h.keys("<M-L>")
    end,
    {
      " - a",
      "   - x",
      " - b",
    }
  )
  case(
    "indent-first-under-head",
    "* H\n- a|\n- b",
    function()
      h.keys("<M-L>")
    end,
    {
      "* H",
      " - a",
      " - b",
    }
  )
end)

describe("emacs parity: B3", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "mret-children",
    "- a|\n  - sub\n- c",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "- ",
      "  - sub",
      "- c",
    }
  )
  case(
    "mret-children-cont",
    "- a|\n  more\n- c",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "- ",
      "  more",
      "- c",
    }
  )
  case(
    "mret-cont-end",
    "- a\n  more|\n- c",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "- a",
      "  more",
      "- ",
      "- c",
    }
  )
  case(
    "mret-mid-children",
    "- a|b\n  - sub\n- c",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "- a",
      "- b",
      "  - sub",
      "- c",
    }
  )
  case(
    "mret-after-bullet",
    "- |ab",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "- ",
      "- ab",
    }
  )
  case(
    "mret-trailing-space",
    "- ab |",
    function()
      h.keys("A <M-CR><Esc>")
    end,
    {
      "- ab",
      "- ",
    }
  )
  case(
    "mret-head-tags",
    "* Hea|ding    :tag:",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* Hea                                                                   :tag:",
      "* ding",
    }
  )
  case(
    "mret-head-stars",
    "*| Heading",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* Heading",
      "* ",
    }
  )
  case(
    "mret-head-todo",
    "* TO|DO Heading",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* TODO Heading",
      "* ",
    }
  )
  case(
    "mret-head-blank-auto",
    "* A\n\n* B|\nbody\n\n* C",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "* A",
      "",
      "* B",
      "",
      "* ",
      "body",
      "",
      "* C",
    }
  )
  case(
    "mret-head-bol",
    "* A\n|* B",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* A",
      "* ",
      "* B",
    }
  )
  case(
    "mret-head-bol-blank",
    "* A\n\n|* B",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* A",
      "",
      "* ",
      "",
      "* B",
    }
  )
  case(
    "msret-next",
    "** NEXT Hea|d",
    function()
      h.keys("i<M-S-CR><Esc>")
    end,
    {
      "** NEXT Hea",
      "** NEXT d",
    }
  )
  case(
    "msret-done",
    "** DONE Hea|d",
    function()
      h.keys("i<M-S-CR><Esc>")
    end,
    {
      "** DONE Hea",
      "** TODO d",
    }
  )
  case(
    "csret-next",
    "** NEXT Hea|d",
    function()
      h.keys("<C-S-CR><Esc>")
    end,
    {
      "** NEXT Head",
      "** NEXT ",
    }
  )
  case(
    "cmret-item",
    "- a|",
    function()
      h.keys("4<M-CR><Esc>")
    end,
    {
      "- a",
      "* ",
    }
  )
  case(
    "cret-blank-auto",
    "* A\n\n* B|\nbody",
    function()
      h.keys("<C-CR><Esc>")
    end,
    {
      "* A",
      "",
      "* B",
      "body",
      "",
      "* ",
    }
  )
  case(
    "cret-blank-auto-last",
    "* A\n\n* B|\nbody",
    function()
      h.keys("<C-CR><Esc>")
    end,
    {
      "* A",
      "",
      "* B",
      "body",
      "",
      "* ",
    }
  )
  case(
    "cret-noblank",
    "* A\n* B|\nbody\n* C",
    function()
      h.keys("<C-CR><Esc>")
    end,
    {
      "* A",
      "* B",
      "body",
      "* ",
      "* C",
    }
  )
end)

describe("emacs parity: B4", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "cret-pre",
    "te|xt\n* A",
    function()
      h.keys("<C-CR><Esc>")
    end,
    {
      "text",
      "* ",
      "",
      "* A",
    }
  )
  case(
    "cret-pre-blank",
    "te|xt\n\n* A",
    function()
      h.keys("<C-CR><Esc>")
    end,
    {
      "text",
      "",
      "* ",
      "",
      "",
      "* A",
    }
  )
  case(
    "mret-pre-bol",
    "|text\n\n* A",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "",
      "* text",
      "",
      "* A",
    }
  )
  case(
    "mret-pre-end",
    "text|\n\n* A",
    function()
      h.keys("A<M-CR><Esc>")
    end,
    {
      "text",
      "",
      "* ",
      "",
      "* A",
    }
  )
  case(
    "cret-first-line",
    "* A|\nx\n* B",
    function()
      h.keys("<C-CR><Esc>")
    end,
    {
      "* A",
      "x",
      "* ",
      "* B",
    }
  )
  case(
    "cret-first-line-blank",
    "* A|\nx\n\n* B",
    function()
      h.keys("<C-CR><Esc>")
    end,
    {
      "* A",
      "x",
      "",
      "* ",
      "",
      "* B",
    }
  )
  case(
    "cret-trailing-blanks-noauto",
    "* A\n* B|\nx\n\n\n* C",
    function()
      h.keys("<C-CR><Esc>")
    end,
    {
      "* A",
      "* B",
      "x",
      "* ",
      "* C",
    }
  )
  case(
    "mret-text-blankabove",
    "* A\nx\n\n|text",
    function()
      h.keys("i<M-CR><Esc>")
    end,
    {
      "* A",
      "x",
      "* text",
    }
  )
  case(
    "cucumret-top",
    "* H|ead\n** c\n* B",
    function()
      h.keys("16<M-CR><Esc>")
    end,
    {
      "* Head",
      "** c",
      "* ",
      "* B",
    }
  )
end)

describe("emacs parity: B5", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "ns-item",
    "- a|b\n\n- c",
    function()
      h.keys("<M-CR><Esc>")
    end,
    {
      "- ab",
      "",
      "- ",
      "",
      "- c",
    }
  )
  case(
    "ns-item-children",
    "- a|b\n  - sub\n\n- c",
    function()
      h.keys("<M-CR><Esc>")
    end,
    {
      "- ab",
      "  - sub",
      "",
      "- ",
      "",
      "- c",
    }
  )
  case(
    "ns-item-last-blank",
    "- a\n- b|b\n\ntext",
    function()
      h.keys("<M-CR><Esc>")
    end,
    {
      "- a",
      "- bb",
      "- ",
      "",
      "text",
    }
  )
  case(
    "ns-head",
    "* A|b\nbody\n** c",
    function()
      h.keys("<M-CR><Esc>")
    end,
    {
      "* Ab",
      "* ",
      "body",
      "** c",
    }
  )
  case(
    "ns-text",
    "* A\nsome| text\nmore",
    function()
      h.keys("<M-CR><Esc>")
    end,
    {
      "* A",
      "some text",
      "* ",
      "more",
    }
  )
  case(
    "ns-item-single-blank-inside",
    "- a\n\n  p|q",
    function()
      h.keys("<M-CR><Esc>")
    end,
    {
      "- a",
      "",
      "  pq",
      "",
      "- ",
    }
  )
  case(
    "ns-item-cont",
    "- a\n  mo|re\n- c",
    function()
      h.keys("<M-CR><Esc>")
    end,
    {
      "- a",
      "  more",
      "- ",
      "- c",
    }
  )
end)

describe("emacs parity: E1", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "repair-ind",
    "- a|\n    - b\n    - c\n-   d",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- a",
      "  - b",
      "  - c",
      "- d",
    }
  )
  case(
    "repair-bul-mixed",
    "- a|\n+ b\n  * x\n  + y",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "- a",
      "- b",
      "  * x",
      "  * y",
    }
  )
  case(
    "repair-parent-box",
    "- [ ] a|\n  - [X] b\n  - [X] c",
    function()
      require("org.lists").repair()
    end,
    {
      "- [X] a",
      "  - [X] b",
      "  - [X] c",
    }
  )
  case(
    "make-subtree",
    "* H\n- a\n  more\n  - b\n- [X] c|\n- [ ] e\n- d :: desc\ntext",
    function()
      require("org.lists").make_subtree()
    end,
    {
      "* H",
      "** a",
      "more",
      "*** b",
      "** DONE c",
      "** TODO e",
      "**  d desc",
      "text",
    }
  )
  case(
    "make-subtree-top",
    "- a|\n  - b\n\n- c",
    function()
      require("org.lists").make_subtree()
    end,
    {
      "* a",
      "** b",
      "* c",
    }
  )
  case(
    "make-subtree-blank",
    "* H\n\n* I\n- a|\n- b",
    function()
      require("org.lists").make_subtree()
    end,
    {
      "* H",
      "",
      "* I",
      "** a",
      "** b",
    }
  )
  case(
    "toggle-heading-list",
    "* H\n- [ ] a|\n  - b\n- [X] c",
    function()
      h.keys("<C-c>*")
    end,
    {
      "* H",
      "** TODO a",
      "  - b",
      "- [X] c",
    }
  )
  case(
    "ordered-block",
    "* H\n:PROPERTIES:\n:ORDERED: t\n:END:\n- [ ] a\n- [ ] b|",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "* H",
      ":PROPERTIES:",
      ":ORDERED: t",
      ":END:",
      "- [ ] a",
      "- [ ] b",
    },
    "Cannot toggle this checkbox: unchecked subitems"
  )
  case(
    "ordered-ok",
    "* H\n:PROPERTIES:\n:ORDERED: t\n:END:\n- [X] a\n- [ ] b|",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "* H",
      ":PROPERTIES:",
      ":ORDERED: t",
      ":END:",
      "- [X] a",
      "- [X] b",
    }
  )
  case(
    "radio",
    "#+attr_org: :radio t\n- [ ] a\n- [X] b\n- [ ] c|",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "#+attr_org: :radio t",
      "- [ ] a",
      "- [ ] b",
      "- [X] c",
    }
  )
  case(
    "radio-off",
    "#+attr_org: :radio t\n- [ ] a\n- [X] b|\n- [ ] c",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "#+attr_org: :radio t",
      "- [ ] a",
      "- [ ] b",
      "- [ ] c",
    }
  )
  case(
    "radio-nobox",
    "#+attr_org: :radio t\n- a\n- b|",
    function()
      h.keys("<C-c><C-c>")
    end,
    {
      "#+attr_org: :radio t",
      "- [ ] a",
      "- [X] b",
    }
  )
  case(
    "radio-cxcr",
    "- [ ] a\n- [X] b\n- [ ] c|",
    function()
      require("org.lists").toggle_radio_button()
    end,
    {
      "- [ ] a",
      "- [ ] b",
      "- [X] c",
    }
  )
  case(
    "cxcb-heading",
    "* H|\n- [ ] a\n- [X] b\n- c",
    function()
      h.keys("<C-c><C-x><C-b>")
    end,
    {
      "* H",
      "- [X] a",
      "- [X] b",
      "- c",
    }
  )
  case(
    "cxcb-heading-x",
    "* H|\n- [X] a\n- [ ] b",
    function()
      h.keys("<C-c><C-x><C-b>")
    end,
    {
      "* H",
      "- [ ] a",
      "- [ ] b",
    }
  )
  case(
    "cucxcb-add",
    "- a|\n- b",
    function()
      h.keys("4<C-c><C-x><C-b>")
    end,
    {
      "- [ ] a",
      "- b",
    }
  )
  case(
    "cucucc",
    "- [X] a|",
    function()
      h.keys("16<C-c><C-c>")
    end,
    {
      "- [-] a",
    }
  )
  case(
    "cc-parent-partial-cucu",
    "- [-] p|\n  - [X] a\n  - [ ] b",
    function()
      h.keys("16<C-c><C-c>")
    end,
    {
      "- [-] p",
      "  - [X] a",
      "  - [ ] b",
    }
  )
  case(
    "toggle-item-headings",
    "* TODO A :t:|\nSCHEDULED: <2024-01-01 Mon>\ntext\n** DONE B\nbody\n* C",
    function()
      vim.cmd("normal! ggVG")
      require("org.lists").toggle_item()
    end,
    {
      "- [X] A",
      "  text",
      "  - [X] B",
      "    body",
      "- C",
    }
  )
  case(
    "toggle-item-items",
    "- [ ] a|\n  - b\n1. c",
    function()
      vim.cmd("normal! ggVG")
      require("org.lists").toggle_item()
    end,
    {
      "[ ] a",
      "  b",
      "c",
    }
  )
  case(
    "toggle-item-arg",
    "foo|\n  bar\nbaz",
    function()
      h.keys("ggVG4<C-c>-")
    end,
    {
      "- foo",
      "    bar",
      "  baz",
    }
  )
end)

describe("emacs parity: E2", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "cucucxcb-nobox",
    "- a\n- b|",
    function()
      h.keys("16<C-c><C-x><C-b>")
    end,
    {
      "- a",
      "- b",
    }
  )
  case(
    "cucucxcb-box",
    "- [X] a|",
    function()
      h.keys("16<C-c><C-x><C-b>")
    end,
    {
      "- [-] a",
    }
  )
  case(
    "cucxcb-rm",
    "- [X] a|\n- b",
    function()
      h.keys("4<C-c><C-x><C-b>")
    end,
    {
      "- a",
      "- b",
    }
  )
  case(
    "region-nobox",
    "- a|\n- b",
    function()
      h.keys("ggVG<C-c><C-x><C-b>")
    end,
    {
      "- a",
      "- b",
    }
  )
  case(
    "region-nobox-cu",
    "- a|\n- b",
    function()
      h.keys("ggVG4<C-c><C-x><C-b>")
    end,
    {
      "- [ ] a",
      "- [ ] b",
    }
  )
  case(
    "fn-local-sort",
    "* A\nx[fn:b] y[fn:a]|\n\n* B\nz\n[fn:a] A\n\n[fn:b] B",
    function()
      require("org.config").opts.footnote_section=false
      require("org.footnotes").sort()
      require("org.config").opts.footnote_section="Footnotes"
    end,
    {
      "* A",
      "x[fn:b] y[fn:a]",
      "",
      "[fn:b] B",
      "",
      "[fn:a] A",
      "",
      "* B",
      "z",
    }
  )
  case(
    "fn-section-blank",
    "* H\nText|\n* Footnotes\n\n[fn:1] one",
    function()
      require("org.footnotes").new_footnote({no_insert=true})
    end,
    {
      "* H",
      "Text[fn:2]",
      "* Footnotes",
      "[fn:2] ",
      "",
      "[fn:1] one",
    }
  )
  case(
    "fn-unique",
    "* H\nText[fn:1] [fn:3]|\n* Footnotes\n[fn:1] a\n[fn:3] c",
    function()
      vim.api.nvim_win_set_cursor(0,{2,16})
      require("org.footnotes").new_footnote({no_insert=true})
    end,
    {
      "* H",
      "Text[fn:1] [fn:3][fn:2]",
      "* Footnotes",
      "",
      "[fn:2] ",
      "[fn:1] a",
      "[fn:3] c",
    }
  )
  case(
    "fn-inline",
    "* H\nText|",
    function()
      require("org.config").opts.footnote_define_inline=true
      vim.api.nvim_win_set_cursor(0,{2,3})
      require("org.footnotes").new_footnote({no_insert=true})
      require("org.config").opts.footnote_define_inline=false
    end,
    {
      "* H",
      "Text[fn:1:]",
    }
  )
  case(
    "fn-anon",
    "* H\nText|",
    function()
      require("org.config").opts.footnote_auto_label="anonymous"
      vim.api.nvim_win_set_cursor(0,{2,3})
      require("org.footnotes").new_footnote({no_insert=true})
      require("org.config").opts.footnote_auto_label=true
    end,
    {
      "* H",
      "Text[fn::]",
    }
  )
  case(
    "fn-adjust",
    "* H\nA[fn:2] B|\n* Footnotes\n[fn:2] two",
    function()
      require("org.config").opts.footnote_auto_adjust=true
      vim.api.nvim_win_set_cursor(0,{2,8})
      require("org.footnotes").new_footnote({no_insert=true})
      require("org.config").opts.footnote_auto_adjust=false
    end,
    {
      "* H",
      "A[fn:1] B[fn:2]",
      "",
      "* Footnotes",
      "",
      "[fn:1] two",
      "",
      "[fn:2] ",
    }
  )
  case(
    "fn-startup-local",
    "#+STARTUP: fnlocal\n* H\nText|\n* B",
    function()
      vim.api.nvim_win_set_cursor(0,{3,3})
      require("org.footnotes").new_footnote({no_insert=true})
    end,
    {
      "#+STARTUP: fnlocal",
      "* H",
      "Text[fn:1]",
      "",
      "[fn:1] ",
      "* B",
    }
  )
end)

describe("emacs parity: CL", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "clone-rep",
    "* Meet|\nSCHEDULED: <2024-01-01 Mon +1w>",
    function()
      h.stub_input({"2","+1d"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "SCHEDULED: <2024-01-01 Mon>",
      "* Meet",
      "SCHEDULED: <2024-01-02 Tue>",
      "* Meet",
      "SCHEDULED: <2024-01-03 Wed>",
      "* Meet",
      "SCHEDULED: <2024-01-04 Thu +1w>",
    }
  )
  case(
    "clone-neg",
    "* Meet|\n<2024-01-10 Wed>",
    function()
      h.stub_input({"1","-1d"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "<2024-01-10 Wed>",
      "* Meet",
      "<2024-01-09 Tue>",
    }
  )
  case(
    "clone-norep-noshift",
    "* Meet|\nSCHEDULED: <2024-01-01 Mon +1w>",
    function()
      h.stub_input({"1",""})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "SCHEDULED: <2024-01-01 Mon +1w>",
      "* Meet",
      "SCHEDULED: <2024-01-01 Mon +1w>",
    }
  )
  case(
    "clone-w",
    "* Meet|\n<2024-01-01 Mon>--<2024-01-02 Tue>\n[2024-01-03 Wed]",
    function()
      h.stub_input({"1","+1w"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "<2024-01-01 Mon>--<2024-01-02 Tue>",
      "[2024-01-03 Wed]",
      "* Meet",
      "<2024-01-08 Mon>--<2024-01-09 Tue>",
      "[2024-01-10 Wed]",
    }
  )
  case(
    "clone-h",
    "* Meet|\n<2024-01-01 Mon 10:00>",
    function()
      h.stub_input({"1","+2h"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "<2024-01-01 Mon 10:00>",
      "* Meet",
      "<2024-01-01 Mon 12:00>",
    }
  )
  case(
    "clone-zero",
    "* Meet|\nSCHEDULED: <2024-01-01 Mon +1w>",
    function()
      h.stub_input({"0","+1d"})
      require("org.structure").clone_subtree()
    end,
    {
      "* Meet",
      "SCHEDULED: <2024-01-01 Mon>",
      "* Meet",
      "SCHEDULED: <2024-01-02 Tue +1w>",
    }
  )
  case(
    "clone-body",
    "* A\n** Meet|\nx\n** B",
    function()
      h.stub_input({"1",""})
      require("org.structure").clone_subtree()
    end,
    {
      "* A",
      "** Meet",
      "x",
      "** Meet",
      "x",
      "** B",
    }
  )
end)

describe("emacs parity: EL", function()
  with_config({ todo_keywords = { "TODO NEXT | DONE" }, startup_folded = "showeverything" })
  case(
    "drag-para-down",
    "* H\npara| one\n\npara two",
    function()
      h.keys("<M-j>")
    end,
    {
      "* H",
      "para two",
      "",
      "para one",
    }
  )
  case(
    "drag-para-up",
    "* H\npara one\n\npara| two",
    function()
      h.keys("<M-k>")
    end,
    {
      "* H",
      "para two",
      "",
      "para one",
    }
  )
  case(
    "drag-block",
    "* H\ntext|\n#+begin_src sh\necho\n#+end_src\nmore",
    function()
      h.keys("<M-j>")
    end,
    {
      "* H",
      "#+begin_src sh",
      "echo",
      "#+end_src",
      "text",
      "more",
    }
  )
  case(
    "drag-last",
    "* H\na\n\nb|\n* G",
    function()
      h.keys("<M-j>")
    end,
    {
      "* H",
      "a",
      "",
      "b",
      "* G",
    },
    "Cannot drag element forward"
  )
  case(
    "drag-first",
    "* H\na|\n\nb",
    function()
      h.keys("<M-k>")
    end,
    {
      "* H",
      "a",
      "",
      "b",
    },
    "Cannot drag element backward"
  )
  case(
    "drag-table",
    "* H\npara|\n| a |\n| b |",
    function()
      h.keys("<M-j>")
    end,
    {
      "* H",
      "| a |",
      "| b |",
      "para",
    }
  )
  case(
    "drag-in-item",
    "- a\n  p1|\n\n  p2\n- b",
    function()
      h.keys("<M-j>")
    end,
    {
      "- p2",
      "",
      "  a",
      "  p1",
      "- b",
    }
  )
  case(
    "fwd-elem",
    "* H\np|1\n\np2\n#+begin_quote\nq\n#+end_quote",
    function()
      require("org.element").forward()
    end,
    {
      "* H",
      "p1",
      "",
      "p2",
      "#+begin_quote",
      "q",
      "#+end_quote",
    }
  )
  case(
    "fwd-elem2",
    "* H\np1\n\n|p2\n#+begin_quote\nq\n#+end_quote\nafter",
    function()
      require("org.element").forward()
    end,
    {
      "* H",
      "p1",
      "",
      "p2",
      "#+begin_quote",
      "q",
      "#+end_quote",
      "after",
    }
  )
  case(
    "fwd-elem-heading",
    "* H|\nx\n** C\n* I",
    function()
      require("org.element").forward()
    end,
    {
      "* H",
      "x",
      "** C",
      "* I",
    }
  )
  case(
    "bwd-elem",
    "* H\np1\n\np2\np|2b",
    function()
      require("org.element").backward()
    end,
    {
      "* H",
      "p1",
      "",
      "p2",
      "p2b",
    }
  )
  case(
    "bwd-elem2",
    "* H\np1\n\n|p2",
    function()
      require("org.element").backward()
    end,
    {
      "* H",
      "p1",
      "",
      "p2",
    }
  )
  case(
    "bwd-elem-first",
    "* H\n|p1",
    function()
      require("org.element").backward()
    end,
    {
      "* H",
      "p1",
    }
  )
  case(
    "up-elem",
    "* H\n- a\n  - b|",
    function()
      require("org.element").up()
    end,
    {
      "* H",
      "- a",
      "  - b",
    }
  )
  case(
    "up-elem-quote",
    "* H\n#+begin_quote\nq|\n#+end_quote",
    function()
      require("org.element").up()
    end,
    {
      "* H",
      "#+begin_quote",
      "q",
      "#+end_quote",
    }
  )
  case(
    "up-elem-para",
    "* H\n** C\np|ara",
    function()
      require("org.element").up()
    end,
    {
      "* H",
      "** C",
      "para",
    }
  )
  case(
    "down-elem",
    "* H\n#+begin_quote|\nq\n#+end_quote",
    function()
      require("org.element").down()
    end,
    {
      "* H",
      "#+begin_quote",
      "q",
      "#+end_quote",
    }
  )
  case(
    "down-elem-list",
    "* H\n|- a\n- b",
    function()
      require("org.element").down()
    end,
    {
      "* H",
      "- a",
      "- b",
    }
  )
  case(
    "transpose",
    "* H\np1\n\np|2\n\np3",
    function()
      require("org.element").transpose()
    end,
    {
      "* H",
      "p2",
      "",
      "p1",
      "",
      "p3",
    }
  )
  case(
    "fixed-add",
    "* H\nsome |text",
    function()
      require("org.element").toggle_fixed_width()
    end,
    {
      "* H",
      ": some text",
    }
  )
  case(
    "fixed-rm",
    "* H\n: some |text",
    function()
      require("org.element").toggle_fixed_width()
    end,
    {
      "* H",
      "some text",
    }
  )
  case(
    "fixed-blank",
    "* H\np\n\n|",
    function()
      require("org.element").toggle_fixed_width()
    end,
    {
      "* H",
      "p",
      "",
      ": ",
    }
  )
  case(
    "fixed-region",
    "* H\n|a\n  b\n: c",
    function()
      h.keys("VG")
      require("org.element").toggle_fixed_width()
    end,
    {
      "* H",
      ": a",
      ":   b",
      ": c",
    }
  )
  case(
    "fixed-region-rm",
    "* H\n|: a\n: b",
    function()
      h.keys("VG")
      require("org.element").toggle_fixed_width()
    end,
    {
      "* H",
      "a",
      "b",
    }
  )
  case(
    "next-block",
    "* H|\np\n#+begin_example\nx\n#+end_example\n#+begin_quote\ny\n#+end_quote",
    function()
      require("org.element").next_block(1)
    end,
    {
      "* H",
      "p",
      "#+begin_example",
      "x",
      "#+end_example",
      "#+begin_quote",
      "y",
      "#+end_quote",
    }
  )
  case(
    "next-block2",
    "* H|\np\n#+begin_example\nx\n#+end_example\n#+begin_quote\ny\n#+end_quote",
    function()
      h.keys("2<C-c><M-f>")
    end,
    {
      "* H",
      "p",
      "#+begin_example",
      "x",
      "#+end_example",
      "#+begin_quote",
      "y",
      "#+end_quote",
    }
  )
  case(
    "prev-block",
    "* H\n#+begin_example\nx\n#+end_example\np|",
    function()
      require("org.element").previous_block()
    end,
    {
      "* H",
      "#+begin_example",
      "x",
      "#+end_example",
      "p",
    }
  )
end)
