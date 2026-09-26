# Headings: insert, promote/demote, sort and narrow
Output docs/media/headings.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-headings; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/projects.org" Enter
Sleep 2.5s
Show
Sleep 1s
Shift+Tab
Sleep 300ms
Shift+Tab
Sleep 800ms
Type "/Write the"
Enter
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Do <M-CR> new heading` Enter
Show
Sleep 600ms
Type "Record a demo video"
Escape
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Do <M-l> demote` Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Do <M-h> promote` Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <leader>oit insert a TODO heading` Enter
Show
Type " oit"
Sleep 800ms
Type "Update the pricing page"
Escape
Sleep 1s
Type "/Someday"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>ohs sort the children (a: alphabetically)` Enter
Show
Type " ohs"
Sleep 1.2s
Type "a"
Sleep 1.5s
Type "gg/Website"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>ohn narrow to the subtree` Enter
Show
Type " ohn"
Sleep 1.5s
Tab
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap <C-c>' save and close` Enter
Show
Ctrl+C
Type "'"
Sleep 1.5s
Sleep 1.5s
