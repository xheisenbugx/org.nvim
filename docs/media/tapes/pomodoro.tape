# Pomodoro: the pomodoro extension, with 9-second pomodoros and 6-second
# breaks (docs/media/demo/pomodoro.lua)
Output docs/media/pomodoro.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-pomodoro; clear; nvim -u docs/media/demo/pomodoro.lua $ORG_DEMO_DIR/work.org" Enter
Sleep 2.5s
Type "/Ship" Enter
Type ":nohlsearch" Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <leader>ozs | start a pomodoro (clocks in)` Enter
Show
Sleep 800ms
Type " ozs"
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap <leader>ozp | pause and resume` Enter
Show
Type " ozp"
Sleep 2s
Type " ozp"
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap POMODOROS | the pomodoro ends: counted, clocked out, break` Enter
Show
Sleep 7s
Hide
Ctrl+G
Type@5ms `Cap break over | start the next one` Enter
Show
Sleep 5.5s
Type " ozs"
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap <leader>ozx | stop` Enter
Show
Type " ozx"
Sleep 2.5s
