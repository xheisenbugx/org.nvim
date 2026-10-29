-- org.babel.check: the C-c C-v commands that find, open, split and edit
-- src blocks (org-babel-goto-named-src-block, org-babel-goto-named-result,
-- org-babel-open-src-block-result, org-babel-demarcate-block,
-- org-babel-insert-header-arg), their prompts and what they say when
-- there is nothing to act on.

local babel = require("org.babel")
local utils = require("org.utils")

local NAMED = {
  "* H",
  "#+NAME: foo",
  "#+begin_src sh",
  "echo foo",
  "#+end_src",
  "",
  "#+RESULTS: foo",
  ": foo",
  "",
  "#+NAME: bar",
  "#+begin_src sh",
  "echo bar",
  "#+end_src",
  "",
  "#+RESULTS: bar",
  ": bar",
}

--- Run `fn` with utils.select / utils.input answering from `answers` (in
--- order) and vim.notify collected; returns the messages and the prompts.
local function prompted(answers, fn)
  local select, input, notify = utils.select, utils.input, vim.notify
  local msgs, prompts, i = {}, {}, 0
  local function answer(opts)
    i = i + 1
    prompts[#prompts + 1] = type(opts) == "table" and opts.prompt or opts
    return answers[i]
  end
  utils.select = function(items, opts)
    prompts[#prompts + 1] = { prompt = opts.prompt, items = items }
    i = i + 1
    return answers[i]
  end
  utils.input = answer
  vim.notify = function(m)
    msgs[#msgs + 1] = tostring(m)
  end
  local okk, err = pcall(fn)
  utils.select, utils.input, vim.notify = select, input, notify
  assert(okk, err)
  return msgs, prompts
end

local function lnum()
  return vim.api.nvim_win_get_cursor(0)[1]
end

describe("babel: going to named blocks and results", function()
  it("offers the named blocks and goes to the one chosen", function()
    org_buffer(NAMED, { 1, 0 })
    local _, prompts = prompted({ "bar" }, function()
      babel.goto_named_block()
    end)
    eq({ { prompt = "Src block", items = { "foo", "bar" } } }, prompts)
    eq(10, lnum())
  end)

  it("says when there are no named blocks", function()
    org_buffer({ "* H", "#+begin_src sh", "echo", "#+end_src" }, { 1, 0 })
    local msgs, prompts = prompted({}, function()
      babel.goto_named_block()
    end)
    eq({}, prompts)
    eq({ "No named src blocks" }, msgs)
    eq(1, lnum())
  end)

  it("stays when no block has the name, or the prompt is cancelled", function()
    org_buffer(NAMED, { 1, 0 })
    local msgs = prompted({}, function()
      babel.goto_named_block("baz")
      babel.goto_named_block()
    end)
    eq({ "No src block named baz" }, msgs)
    eq(1, lnum())
  end)

  it("offers the named results and goes to the one chosen", function()
    org_buffer(NAMED, { 1, 0 })
    local _, prompts = prompted({ "bar" }, function()
      babel.goto_named_result()
    end)
    eq({ { prompt = "Result", items = { "foo", "bar" } } }, prompts)
    eq(15, lnum())
  end)

  it("says when there are no named results, or none with the name", function()
    org_buffer({ "* H", "#+begin_src sh", "echo", "#+end_src", "", "#+RESULTS:", ": x" }, { 1, 0 })
    local msgs = prompted({}, function()
      babel.goto_named_result()
      babel.goto_named_result("foo")
    end)
    eq({ "No named results", "No result named foo" }, msgs)
    eq(1, lnum())
  end)

  it("goes to the block's head only inside a block", function()
    org_buffer(NAMED, { 1, 0 })
    local msgs = prompted({}, babel.goto_block_head)
    eq({ "Not in a src block" }, msgs)
    eq(1, lnum())
    vim.api.nvim_win_set_cursor(0, { 12, 0 })
    babel.goto_block_head()
    eq(11, lnum())
  end)
end)

describe("babel: opening a block's result", function()
  after_each(function()
    vim.cmd("silent! only")
  end)

  it("says when the block has no results", function()
    org_buffer({ "#+begin_src sh", "echo", "#+end_src" }, { 2, 0 })
    local msgs = prompted({}, babel.open_result)
    eq({ "No results for this block" }, msgs)
    eq(1, #vim.api.nvim_list_wins())
  end)

  it("shows a scalar result as text", function()
    local buf = org_buffer({ "#+begin_src sh", "echo", "#+end_src", "", "#+RESULTS:", ": one", ": two" }, { 2, 0 })
    babel.open_result()
    local shown = vim.api.nvim_get_current_buf()
    ok(shown ~= buf)
    eq({ "one", "two" }, buf_lines(shown))
    eq("", vim.bo[shown].filetype)
  end)

  it("shows a table result as Org", function()
    local buf = org_buffer(
      { "#+begin_src sh", "echo", "#+end_src", "", "#+RESULTS:", "| a | 1 |", "| b | 2 |" },
      { 2, 0 }
    )
    babel.open_result()
    local shown = vim.api.nvim_get_current_buf()
    ok(shown ~= buf)
    eq({ "| a | 1 |", "| b | 2 |" }, buf_lines(shown))
    eq("org", vim.bo[shown].filetype)
  end)
end)

describe("babel: inserting header arguments", function()
  local SRC = { "#+begin_src sh   ", "echo", "#+end_src" }

  it("asks for the argument and offers its values", function()
    local buf = org_buffer(SRC, { 2, 0 })
    local _, prompts = prompted({ "results", "output" }, function()
      babel.insert_header_arg()
    end)
    eq("Header argument", prompts[1].prompt)
    ok(vim.tbl_contains(prompts[1].items, "results"))
    eq({ prompt = ":results", items = babel.HEADER_ARGS.results }, prompts[2])
    eq("#+begin_src sh :results output", buf_lines(buf)[1])
  end)

  it("reads a free value, and writes the argument alone for an empty one", function()
    local buf = org_buffer(SRC, { 2, 0 })
    local _, prompts = prompted({ " /tmp " }, function()
      babel.insert_header_arg("dir")
    end)
    eq({ ":dir " }, prompts)
    eq("#+begin_src sh :dir /tmp", buf_lines(buf)[1])
    prompted({ "" }, function()
      babel.insert_header_arg("prologue")
    end)
    eq("#+begin_src sh :dir /tmp :prologue", buf_lines(buf)[1])
  end)

  it("changes nothing when a prompt is cancelled", function()
    local buf = org_buffer(SRC, { 2, 0 })
    prompted({}, function()
      babel.insert_header_arg()
      babel.insert_header_arg("results")
      babel.insert_header_arg("dir")
    end)
    eq(SRC, buf_lines(buf))
  end)

  it("needs a src block", function()
    local buf = org_buffer({ "* H", "text" }, { 2, 0 })
    local msgs = prompted({}, function()
      babel.insert_header_arg("results", "output")
    end)
    eq({ "No source block at point" }, msgs)
    eq({ "* H", "text" }, buf_lines(buf))
  end)
end)

-- Checked against Emacs 31.1 with Org 9.8.10, org-babel-demarcate-block
-- with org-edit-src-content-indentation 0 (Emacs re-indents the bodies of
-- the blocks it writes).
describe("babel: demarcating blocks", function()
  with_config({ edit_src_content_indentation = 0 })

  it("splits a block in three around the selected lines", function()
    local buf = org_buffer({ "#+begin_src sh :results output", "echo 1", "echo 2", "echo 3", "#+end_src" }, { 3, 0 })
    vim.cmd("normal! V")
    babel.demarcate_block()
    eq({
      "#+begin_src sh :results output",
      "echo 1",
      "#+end_src",
      "",
      "#+begin_src sh :results output",
      "echo 2",
      "#+end_src",
      "",
      "#+begin_src sh :results output",
      "echo 3",
      "#+end_src",
    }, buf_lines(buf))
    eq("n", vim.fn.mode())
  end)

  it("wraps the selected lines in a block of the language given", function()
    local buf = org_buffer({ "* H", "x = 1", "y = 2" }, { 2, 0 })
    local _, prompts = prompted({ "python " }, function()
      vim.cmd("normal! Vj")
      babel.demarcate_block()
    end)
    eq({ "Lang: " }, prompts)
    eq({ "* H", "#+begin_src python", "x = 1", "y = 2", "#+end_src" }, buf_lines(buf))
    eq({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("changes nothing when the language prompt is cancelled", function()
    local buf = org_buffer({ "* H", "x = 1" }, { 2, 0 })
    prompted({}, babel.demarcate_block)
    eq({ "* H", "x = 1" }, buf_lines(buf))
  end)
end)

-- Emacs 31.1 with Org 9.8.10 and its default org-edit-src-content-indentation
-- (2): org-babel-demarcate-block re-indents every block it writes
-- (org-indent-block; Emacs's language major mode does the code, org.nvim
-- keeps its layout) and leaves the cursor on the last block.
describe("babel: demarcating blocks, re-indented", function()
  local SPLIT = {
    "#+begin_src sh",
    "  echo a",
    "#+end_src",
    "",
    "#+begin_src sh",
    "  echo b",
    "#+end_src",
  }

  it("re-indents both blocks and goes to the second", function()
    local buf = org_buffer({ "#+begin_src sh", "echo a", "echo b", "#+end_src" }, { 3, 0 })
    babel.demarcate_block()
    eq(SPLIT, buf_lines(buf))
    eq({ 5, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("keeps the code's own layout", function()
    local buf = org_buffer({ "#+begin_src python", "if x:", "    y", "    z", "w", "#+end_src" }, { 3, 0 })
    babel.demarcate_block()
    eq({
      "#+begin_src python",
      "  if x:",
      "#+end_src",
      "",
      "#+begin_src python",
      "      y",
      "      z",
      "  w",
      "#+end_src",
    }, buf_lines(buf))
  end)

  it("splits a line at the cursor", function()
    local buf = org_buffer({ "#+begin_src sh", "echo a", "echo b", "#+end_src" }, { 3, 3 })
    babel.demarcate_block()
    eq(
      { "#+begin_src sh", "  echo a", "  ech", "#+end_src", "", "#+begin_src sh", "  o b", "#+end_src" },
      buf_lines(buf)
    )
    eq({ 6, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("moves a block under a headline to the headline's indentation", function()
    local buf = org_buffer({ "* H", "  #+begin_src sh", "    echo a", "    echo b", "  #+end_src" }, { 4, 4 })
    babel.demarcate_block()
    eq({ "* H", unpack(SPLIT) }, buf_lines(buf))
  end)

  it("keeps the name on the first block and the blank lines after the last", function()
    local buf = org_buffer(
      { "#+NAME: x", "#+BEGIN_SRC sh :var a=1", "echo a", "echo b", "#+END_SRC", "", "", "after" },
      { 4, 0 }
    )
    babel.demarcate_block()
    eq({
      "#+NAME: x",
      "#+BEGIN_SRC sh :var a=1",
      "  echo a",
      "#+END_SRC",
      "",
      "#+BEGIN_SRC sh :var a=1",
      "  echo b",
      "#+END_SRC",
      "",
      "",
      "after",
    }, buf_lines(buf))
  end)

  it("adds an empty block from the #+end_src line", function()
    local buf = org_buffer({ "#+begin_src sh", "echo a", "#+end_src" }, { 3, 0 })
    babel.demarcate_block()
    eq({ "#+begin_src sh", "  echo a", "#+end_src", "", "#+begin_src sh", "#+end_src" }, buf_lines(buf))
  end)

  it("doesn't split from the #+begin_src line or the lines above it", function()
    for _, lnum in ipairs({ 1, 2 }) do
      local lines = { "#+NAME: x", "#+begin_src sh", "echo a", "#+end_src" }
      local buf = org_buffer(lines, { lnum, 0 })
      local msgs, prompts = prompted({}, babel.demarcate_block)
      eq({ "Select within the source block body to split it" }, msgs)
      eq({}, prompts)
      eq(lines, buf_lines(buf))
    end
  end)

  it("writes a block of the previous block's language in the blank lines after it", function()
    local buf = org_buffer({ "#+begin_src sh", "echo", "#+end_src", "", "", "text" }, { 4, 0 })
    local _, prompts = prompted({}, babel.demarcate_block)
    eq({}, prompts)
    eq("#+begin_src sh", buf_lines(buf)[4])
  end)

  it("asks for the language elsewhere, on the block's results too", function()
    for _, case in ipairs({
      { { "#+begin_src sh", "echo", "#+end_src", "text", "" }, 5 },
      { { "#+begin_src sh", "echo", "#+end_src", "", "#+RESULTS:", ": x" }, 5 },
    }) do
      org_buffer(case[1], { case[2], 0 })
      local _, prompts = prompted({}, babel.demarcate_block)
      eq({ "Lang: " }, prompts)
    end
  end)
end)
