# Agenda: TODO list, tag match and search views
Output docs/media/agenda-views.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-agenda-views; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/work.org" Enter
Sleep 2.5s
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <leader>oa t every TODO` Enter
Show
Type " oa"
Sleep 800ms
Type "t"
Sleep 2s
Type "q"
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oa m tags match: +oss` Enter
Show
Type " oa"
Sleep 800ms
Type "m"
Sleep 800ms
Type "+oss"
Enter
Sleep 2s
Type "q"
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oa s search for words` Enter
Show
Type " oa"
Sleep 800ms
Type "s"
Sleep 800ms
Type "review"
Enter
Sleep 2s
Sleep 1.5s
