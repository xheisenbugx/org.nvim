# Heatmap (heatmap extension): clocked time per day over nine months,
# a day's details, closed tasks, a tag filter and a day's agenda
Output docs/media/heatmap.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-heatmap; clear; nvim -u docs/media/demo/heatmap.lua $ORG_DEMO_DIR/notes.org" Enter
Sleep 2.5s
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap :Org heatmap | time clocked per day` Enter
Show
Type ":Org heatmap"
Sleep 500ms
Enter
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap h k | a day's total and its tasks` Enter
Show
Type "h"
Sleep 700ms
Type "h"
Sleep 700ms
Type "k"
Sleep 700ms
Type "k"
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap Tab | tasks closed per day` Enter
Show
Tab
Sleep 3s
Type "q"
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap :Org heatmap clock oss | one tag only` Enter
Show
Type ":Org heatmap clock oss"
Sleep 500ms
Enter
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap <CR> | the agenda of that day` Enter
Show
Sleep 500ms
Enter
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
