# ics: subscribed iCalendar events in the week agenda next to org tasks,
# and copying one into an org file with ics_import
Output docs/media/ics.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-ics; clear; nvim -u docs/media/demo/ics.lua $ORG_DEMO_DIR/work.org" Enter
Sleep 2.5s
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oa a | the day agenda with calendar events` Enter
Show
Type " oa"
Sleep 800ms
Type "a"
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap vw | the week: events from two .ics calendars` Enter
Show
Type "vw"
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `call search("^Wednesday") | normal! zt` Enter
Ctrl+G
Type@5ms `Cap scroll | the rest of the week` Enter
Show
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `call search("London")` Enter
Ctrl+G
Type@5ms `Cap :Org ics_import | copy an event into an org file` Enter
Show
Sleep 1.2s
Ctrl+G
Type "Org ics_import"
Sleep 600ms
Enter
Sleep 2s
Hide
Ctrl+G
Type@5ms `edit $ORG_DEMO_DIR/inbox.org` Enter
Type "G"
Ctrl+G
Type@5ms `Cap inbox.org | the imported heading` Enter
Show
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
