# Tables: insert, move and delete rows and columns
Output docs/media/table-edit.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-table-edit; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/budget.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/Coffee"
Enter
Sleep 600ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oTr insert a row` Enter
Show
Type " oTr"
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <Tab> next field` Enter
Show
Type "iMouse"
Tab
Type "2"
Tab
Type "25"
Escape
Sleep 1s
Hide
Ctrl+G
Type@5ms `Do <M-j> move the row down` Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Do <M-j> move the row down` Enter
Show
Sleep 1.2s
Type "/Qty"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oTi insert a column` Enter
Show
Type " oTi"
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <Tab> next field` Enter
Show
Type "iStore"
Escape
Sleep 1s
Hide
Ctrl+G
Type@5ms `Do <M-l> move the column right` Enter
Show
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Do <M-l> move the column right` Enter
Show
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap <leader>oTI delete the column` Enter
Show
Type " oTI"
Sleep 1.5s
Type "/Stickers"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oTR delete the row` Enter
Show
Type " oTR"
Sleep 1.5s
Sleep 1.5s
