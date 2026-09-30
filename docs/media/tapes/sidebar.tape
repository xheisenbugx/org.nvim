# Today sidebar (sidebar extension): the running clock against its effort,
# the next appointment, today's items, habits and the inbox, kept up to date.
# views/today.org puts appointments 25 and 80 minutes from now: record it
# before 23:30 or after midnight.
Output docs/media/sidebar.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-sidebar; clear; nvim -u docs/media/demo/sidebar.lua $ORG_DEMO_DIR/work.org" Enter
Sleep 2.5s
Type "/Ship" Enter
Type ":noh" Enter
Show
Sleep 600ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oxi | clock in` Enter
Show
Type " oxi"
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap <leader>oVs | toggle the Today sidebar` Enter
Show
Type " oVs"
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap <C-w>l j <CR> | open an entry` Enter
Show
Ctrl+W
Type "l"
Sleep 400ms
Type@100ms "jjjjjjjjjjjjjj"
Sleep 600ms
Enter
Sleep 2s
Hide
Ctrl+G
Type@5ms `Cap <leader>oc t | capture: the inbox count follows` Enter
Show
Type " oc"
Sleep 800ms
Type "t"
Sleep 800ms
Type "Call the bank"
Sleep 600ms
Escape Ctrl+C Ctrl+C
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 2.5s
