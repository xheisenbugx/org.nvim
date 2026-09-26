# Appointment reminders for timed entries
Output docs/media/reminders.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-reminders; clear; DEMO_SNACKS=1 DEMO_NOTIFY=1 nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/reminders.org" Enter
Sleep 2.5s
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap :Org notifications_start | appointment reminders` Enter
Show
Type ":Org notifications_start"
Enter
Sleep 4s
Hide
Ctrl+G
Type@5ms `Cap <leader>oa a | they come from the agenda` Enter
Show
Type " oa"
Sleep 800ms
Type "a"
Sleep 3s
Sleep 1.5s
