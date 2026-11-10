# caldav: two-way sync with a CalDAV calendar. The calendar's events
# become headings, an entry becomes an event, changes travel both ways a
# field at a time, and a deletion asks first. The server is the specs'
# stand-in, run by the demo config and reached through real curl.
Output docs/media/caldav.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-caldav; clear; nvim -u docs/media/demo/caldav.lua $ORG_DEMO_DIR/calendar.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms `Cap :Org caldav_sync | the calendar's events come in, the entry goes out` Enter
Show
Sleep 1.5s
Ctrl+G
Type "Org caldav_sync"
Sleep 600ms
Enter
Sleep 4s
Hide
Ctrl+G
Type@5ms `Cap <leader>oa a | they are in the agenda` Enter
Show
Type " oa"
Sleep 800ms
Type "a"
Sleep 3.5s
Type "q"
Hide
Ctrl+G
Type@5ms `call search("Design review")` Enter
Ctrl+G
Type@5ms `Cap edit the heading, sync | only the title is sent` Enter
Show
Sleep 800ms
Type "A (final)"
Escape
Sleep 600ms
Ctrl+G
Type "Org caldav_sync"
Sleep 400ms
Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `CalServer design-review.ics` Enter
Ctrl+G
Type@5ms `Cap on the server | the attendee and the alarm are still there` Enter
Show
Sleep 4.5s
Hide
Ctrl+G
Type@5ms `only` Enter
Ctrl+G
Type@5ms `CalOther` Enter
Ctrl+G
Type@5ms `Cap moved in another calendar app, sync | the entry follows` Enter
Show
Sleep 1.2s
Ctrl+G
Type "Org caldav_sync"
Sleep 400ms
Enter
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `call search("Dentist")` Enter
Ctrl+G
Type@5ms `Cap delete an entry, sync | it asks before deleting the event` Enter
Show
Sleep 800ms
Ctrl+G
Type ".,+5delete"
Sleep 400ms
Enter
Sleep 800ms
Ctrl+G
Type "Org caldav_sync"
Sleep 400ms
Enter
Sleep 3s
Type "y"
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
