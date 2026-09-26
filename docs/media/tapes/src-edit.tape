# Editing a source block in its own buffer
Output docs/media/src-edit.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-src-edit; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/babel.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/vim.version"
Enter
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap <leader>o' edit the block in its own buffer` Enter
Show
Type " o'"
Sleep 1.5s
Type `A .. "!"`
Escape
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap <C-c>' save and go back` Enter
Show
Ctrl+C
Type "'"
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-c> run it` Enter
Show
Ctrl+C Ctrl+C
Sleep 2s
Sleep 1.5s
