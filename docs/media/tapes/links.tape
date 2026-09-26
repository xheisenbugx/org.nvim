# Links: store, insert, follow and show raw
Output docs/media/links.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-links; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/notes.org" Enter
Sleep 2.5s
Show
Sleep 1s
Shift+Tab
Sleep 300ms
Shift+Tab
Sleep 800ms
Type `/checklist \[`
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>ols store a link to this heading` Enter
Show
Type " ols"
Sleep 1.2s
Type "/Configuration"
Enter
Sleep 400ms
Type "o"
Escape
Sleep 200ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oli insert a link` Enter
Show
Type " oli"
Sleep 1.2s
Enter
Sleep 800ms
Ctrl+U
Type "the checklist"
Enter
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap <CR> follow the link` Enter
Show
Enter
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap <leader>olt show the raw links` Enter
Show
Type " olt"
Sleep 1.5s
Sleep 1.5s
