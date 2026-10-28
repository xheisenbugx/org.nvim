-- Babel: running src blocks and editing them (feature map:
-- .claude/skills/verify-org/features/babel.md). Lua blocks run inside
-- Neovim, so no other program is needed.
local block = {
  "* Sums",
  "#+begin_src lua",
  "return 6 * 7",
  "#+end_src",
}

return {
  {
    name = "C-c C-c runs a block and writes its result",
    files = { ["code.org"] = block },
    open = "code.org",
    setup = { babel = { confirm_evaluate = false } },
    steps = {
      { at = "return 6 * 7" },
      { key = "{{org.context_action}}", expect = { screen = { "#+RESULTS:", ": 42" } } },
      { key = "ccreturn 6 * 8<Esc>" },
      { key = "{{org.context_action}}", expect = { screen = ": 48", no_screen = ": 42" } },
      { cmd = "write" },
      {
        expect = {
          file = {
            "code.org",
            lines = { "* Sums", "#+begin_src lua", "  return 6 * 8", "#+end_src", "", "#+RESULTS:", ": 48" },
          },
        },
      },
    },
  },
  {
    name = "the confirmation prompt: y runs the block, n doesn't",
    files = { ["code.org"] = block },
    open = "code.org",
    steps = {
      { at = "return 6 * 7" },
      { key = "{{org.context_action}}", expect = { screen = "Evaluate this lua code block on your system?" } },
      {
        key = "n<CR>",
        expect = {
          no_screen = "#+RESULTS:",
          lua = [[return vim.fn.execute("messages"):find("Evaluation of this lua code block is aborted.", 1, true) ~= nil]],
        },
      },
      { key = "{{org.context_action}}", expect = { screen = "Evaluate this lua code block on your system?" } },
      { key = "y", expect = { screen = { "#+RESULTS:", ": 42" } } },
    },
  },
  {
    name = "C-c ' edits a block in its own buffer and writes it back",
    files = { ["code.org"] = block },
    open = "code.org",
    steps = {
      { at = "return 6 * 7" },
      { key = "{{org.edit_special}}", expect = { filetype = "lua", screen = "Edit, then exit" } },
      { key = "ccreturn 2 + 2<Esc>" },
      { key = "{{edit_src.save_exit}}", expect = { filetype = "org", line = "^  return 2 %+ 2$" } },
      { cmd = "write" },
      { expect = { file = { "code.org", lines = { "* Sums", "#+begin_src lua", "  return 2 + 2", "#+end_src" } } } },
    },
  },
  {
    name = "C-c C-k in the edit buffer drops the edit",
    files = { ["code.org"] = block },
    open = "code.org",
    steps = {
      { at = "return 6 * 7" },
      { key = "{{org.edit_special}}", expect = { filetype = "lua" } },
      { key = "ccreturn 0<Esc>" },
      { key = "{{edit_src.abort}}", expect = { filetype = "org", line = "^return 6 %* 7$", no_screen = "return 0" } },
    },
  },
}
