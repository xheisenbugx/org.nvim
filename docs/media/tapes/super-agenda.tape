# org-super-agenda: the day agenda in groups, automatic groups and
# folding a group with <Tab>
Output docs/media/super-agenda.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-super; clear; nvim -u docs/media/demo/ql.lua $ORG_DEMO_DIR/work.org" Enter
Sleep 2.5s
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oa a | the day agenda, grouped` Enter
Show
Type " oa"
Sleep 800ms
Type "a"
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap gj | next group header` Enter
Show
Type "gg"
Sleep 400ms
Type "gj"
Sleep 700ms
Type "gj"
Sleep 900ms
Hide
Ctrl+G
Type@5ms `Cap Tab | fold the group` Enter
Show
Tab
Sleep 1.5s
Tab
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap gj Tab | fold Important too` Enter
Show
Type "gj"
Sleep 600ms
Tab
Sleep 1.8s
Tab
Sleep 800ms
Type "q"
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap :Org ql_search | org-ql results, grouped by category` Enter
Show
Type ":Org ql_search todo:"
Sleep 600ms
Enter
Hide
Type "gg"
Show
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 1s
