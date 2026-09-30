# Quick add: the quickadd extension, a Todoist-style line with a live
# preview, added under the matching heading
Output docs/media/quickadd.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-quickadd; clear; nvim -u docs/media/demo/quickadd.lua $ORG_DEMO_DIR/planner.org" Enter
Sleep 2.5s
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <leader>oq | quick add with a live preview` Enter
Show
Sleep 600ms
Type " oq"
Sleep 800ms
Type@60ms "Call the recruiter fri 3pm #phone !A ~30m @hiring"
Sleep 2.5s
Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap due/every/*NEXT | deadlines, repeaters, keywords` Enter
Show
Sleep 400ms
Type " oq"
Sleep 600ms
Type@60ms "Publish release notes *NEXT due mon 5pm every 2w #web @website"
Sleep 2.5s
Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap :Org quickadd | no @target: the Inbox` Enter
Show
Sleep 400ms
Type@50ms ":Org quickadd Water the plants every weekday 8am #home p3"
Sleep 800ms
Enter
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 1s
