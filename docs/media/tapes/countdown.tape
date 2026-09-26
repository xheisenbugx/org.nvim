# A countdown timer that notifies when time is up
Output docs/media/countdown.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-countdown; clear; DEMO_SNACKS=1 nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/meeting.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/Standup"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-x>; a countdown timer` Enter
Show
Ctrl+C Ctrl+X
Type ";"
Sleep 1.2s
Type "0:00:06"
Sleep 600ms
Enter
Sleep 3s
Sleep 5s
Sleep 2s
Sleep 1.5s
