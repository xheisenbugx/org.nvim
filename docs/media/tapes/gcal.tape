# The gcal extension against the local stand-in for Google Calendar
# (tests/support/gcal_server.lua): no Google account, no network. The
# recording shows a banner saying so.
Output docs/media/gcal.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=${ORG_DEMO_DIR:-/tmp/org-demo-gcal}; clear; nvim -u docs/media/demo/gcal/init.lua $ORG_DEMO_DIR/schedule.org" Enter
Sleep 2.5s
Type ":Cap :Org gcal_fetch | fetch the calendar into schedule.org" Enter
Show
Sleep 1.2s
Type ":Org gcal_fetch" Sleep 500ms Enter
Sleep 2.5s

Hide
Type ":Cap :Org agenda week | the events in the agenda" Enter
Show
Sleep 600ms
Type ":Org agenda week" Sleep 400ms Enter
Sleep 3s
Type "q" Sleep 800ms

Hide
Type ":Cap edit, then :Org gcal_post_at_point | push the change" Enter
Show
Type "/Design review" Enter Sleep 600ms
Type "A: agenda views" Sleep 300ms Escape Sleep 800ms
Type ":Org gcal_post_at_point" Sleep 400ms Enter
Sleep 1.5s
Type "y"
Sleep 2s

Hide
Type ":Cap :DemoServer | what the server now has" Enter
Show
Type ":DemoServer" Enter
Sleep 3s
Type "q" Sleep 600ms

Hide
Type ":Cap :Org gcal_fetch | an event edited on the web comes back" Enter
Show
Type ":DemoWebEdit" Enter Sleep 1.5s
Type ":Org gcal_fetch" Sleep 400ms Enter
Sleep 1.5s
Type "/Lunch" Enter Sleep 800ms
Type "jj" Sleep 300ms Tab
Sleep 3s
