---
area: babel
recipe: scripts/verify/recipes/babel.lua
keys: org.context_action, org.babel_execute, org.edit_special, edit_src.save_exit, edit_src.abort
modules: lua/org/babel, lua/org/babel/evaluate.lua, lua/org/babel/results.lua, lua/org/babel/edit.lua
specs: tests/spec/babel_spec.lua, tests/spec/babel_emacs_spec.lua, tests/spec/babel_parity_spec.lua, tests/spec/org_src_emacs_spec.lua
doc: org-babel, org-babel-edit-special, org-babel-languages, org-babel-async
emacs: ob-core.el, ob-eval.el, ob-lua.el, org-src.el
---

# Babel (source blocks)

Run the code of a `#+begin_src` block and get its result written under
it as `#+RESULTS:`, and edit the code in a buffer of its own language
(org-babel-execute-src-block, org-edit-special).

## How to get to it

Put the cursor in a src block. `{{org.context_action}}` (`C-c C-c`, also
`{{org.babel_execute}}`) runs it; `{{org.edit_special}}` (`C-c '`) opens
the edit buffer. Before running, org asks "Evaluate this LANG code block
on your system?" unless `babel.confirm_evaluate` is false.

## Driving it

| Step | Expected |
| --- | --- |
| `{{org.context_action}}` in a block | the prompt on the last lines: `Evaluate this lua code block on your system?` / `(Y)es, [N]o:` |
| `y` | a blank line, `#+RESULTS:` and `: 42` under `#+end_src` |
| `n` | "Evaluation of this lua code block is aborted." and a Press ENTER prompt; no result |
| `{{org.context_action}}` again after editing the code | the old result replaced, not a second `#+RESULTS:` |
| `{{org.edit_special}}` | a floating window titled `src-lua`, filetype `lua`, the winbar "Edit, then exit with ‘<C-c>'’ or abort with ‘<C-c><C-k>’" |
| `{{edit_src.save_exit}}` | the window gone; the block holds the edited code, indented by 2 |
| `{{edit_src.abort}}` | the window gone; the block as it was |

## Gotchas

- Use `lua` blocks in a recipe: the default `lua` entry
  (`babel.languages.lua.cmd = "nvim"`) runs the code inside Neovim, so it
  needs no other program on any OS. `python`, `sh` and the rest need
  their interpreter on PATH.
- The prompt's default is No (`[N]o`): `<CR>` there doesn't run the
  block. Turn it off with `setup = { babel = { confirm_evaluate = false } }`
  in scenarios that aren't about the prompt.
- Answering `n` leaves "Evaluation ... is aborted." under the prompt text,
  which makes a Press ENTER prompt (seen in a real terminal too). The
  child doesn't answer the driver until it's dismissed, so send `n<CR>`
  and check the message with `vim.fn.execute("messages")`. Answering `y`
  doesn't leave one.
- Write-back indents the code by `edit_src_content_indentation` (2,
  org-src-content-indentation): `return 2 + 2` comes back as
  `  return 2 + 2`. `cc` on a body line in the Org buffer indents it the
  same way (the indent expression), so expect the two spaces on disk.
- Running a block changes the buffer only: `:write` before checking the
  file with `expect.file`.
- `{{org.context_action}}` is a two-key Ctrl sequence; the driver sends
  it at once. After `{{edit_src.abort}}` the cursor comes back to the same
  place in the code, not the start of the block.
- The edit buffer of a `lua` block runs Neovim's lua ftplugin, which
  starts tree-sitter: without the bundled parsers (lib/nvim/parser) the
  child stops on an error prompt. The driver adds them even when the
  parent's runtimepath doesn't have them (`make test` runs with only the
  plugin and $VIMRUNTIME).
- Exporting a file with `:exports results` (or `both`) blocks runs them
  too and asks the same question (see the export feature file).
