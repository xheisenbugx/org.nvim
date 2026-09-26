# Relative timers and timed list items
Output docs/media/timers.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-timers; clear; DEMO_SNACKS=1 nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/meeting.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/Standup"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-x>0 start a relative timer` Enter
Show
Ctrl+C Ctrl+X
Type "0"
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-x>- a list item with the time` Enter
Show
Type "o"
Escape
Ctrl+C Ctrl+X
Type "-"
Sleep 600ms
Type "Ana presents the roadmap"
Escape
Sleep 3s
Ctrl+C Ctrl+X
Type "-"
Sleep 600ms
Type "Questions about the release date"
Escape
Sleep 2s
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-x>, pause the timer` Enter
Show
Ctrl+C Ctrl+X
Type ","
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-x>_ stop it` Enter
Show
Ctrl+C Ctrl+X
Type "_"
Sleep 2s
Sleep 1.5s
