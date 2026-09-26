# Tables: sort, hlines, field formulas and transposing
Output docs/media/table-tools.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-table-tools; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/budget.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/120"
Enter
Sleep 600ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oTs sort the rows (n: by number)` Enter
Show
Type " oTs"
Sleep 1.2s
Type "n"
Sleep 1.5s
Type "G"
Sleep 300ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oT- insert a hline` Enter
Show
Type " oT-"
Sleep 1s
Type "G"
Type "o|Total"
Escape
Sleep 300ms
Ctrl+C Ctrl+C
Sleep 800ms
Type "0f|;l"
Sleep 300ms
Hide
Ctrl+G
Type@5ms `Cap :=vsum(@2..@-1) a formula typed in the field` Enter
Show
Type "a:=vsum(@2..@-1)"
Escape
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-c> evaluate it` Enter
Show
Ctrl+C Ctrl+C
Sleep 2s
Hide
Ctrl+G
Type@5ms `Cap <leader>oTt transpose the table` Enter
Show
Type " oTt"
Sleep 2.5s
Sleep 1.5s
