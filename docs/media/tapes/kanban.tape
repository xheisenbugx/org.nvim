# Kanban board (kanban extension): moving cards between TODO states, the
# WIP limit, filtering and jumping to the heading
Output docs/media/kanban.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-kanban; clear; nvim -u docs/media/demo/kanban.lua $ORG_DEMO_DIR/views/board.org" Enter
Sleep 2.5s
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap :Org kanban | a column per TODO state` Enter
Show
Type ":Org kanban"
Sleep 500ms
Enter
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap j | next card` Enter
Show
Type "j"
Sleep 700ms
Type "j"
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap l | move it to NEXT: 4/3 is over the WIP limit` Enter
Show
Sleep 500ms
Type "l"
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap / | filter: a tags match or an org-ql query` Enter
Show
Type "/"
Sleep 700ms
Type "dev"
Sleep 600ms
Enter
Sleep 2.5s
Type "/"
Sleep 400ms
Ctrl+U
Enter
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap L | next column` Enter
Show
Type "L"
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap l | WAITING to DONE: CLOSED is logged` Enter
Show
Sleep 500ms
Type "l"
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap <CR> | open the heading` Enter
Show
Sleep 500ms
Enter
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
