# org-roam extension: find a node, the backlinks window, insert a link to
# a new node, and daily notes
Output docs/media/roam.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-roam DEMO_SNACKS=1; clear; nvim -u docs/media/demo/roam.lua $ORG_DEMO_DIR/roam/zettelkasten.org" Enter
Sleep 3s
Show
Sleep 1s
# find a node by fuzzy title
Hide
Ctrl+G
Type@5ms `Cap <leader>omf find a node` Enter
Show
Type " omf"
Sleep 1s
Type@150ms "neov"
Sleep 1s
Enter
Sleep 1.5s
# the backlinks window follows the node at point
Hide
Ctrl+G
Type@5ms `Cap <leader>oml backlinks and unlinked references` Enter
Show
Type " oml"
Sleep 3s
Type " oml"
Sleep 800ms
# insert a link to a node that doesn't exist yet: typing a new title creates it
Hide
Type "8GA See " Escape
Ctrl+G
Type@5ms `Cap <leader>omi insert a link (a new node)` Enter
Show
Sleep 800ms
Type " omi"
Sleep 1s
Type@90ms "Lua plugins"
Sleep 1s
Enter
Sleep 1.5s
Type@60ms "Plugins written in Lua."
Sleep 800ms
Escape
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-c> finish the note` Enter
Show
Sleep 600ms
Ctrl+C Ctrl+C
Sleep 2s
# daily notes
Hide
Ctrl+G
Type@5ms `Cap <leader>omj capture to today's note` Enter
Show
Type " omj"
Sleep 1.2s
Type@60ms "Recorded the roam demo"
Sleep 600ms
Escape Ctrl+C Ctrl+C
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap <leader>omdt open today's note` Enter
Show
Type " omdt"
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 1s
