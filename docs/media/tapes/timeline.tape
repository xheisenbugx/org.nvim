# Timeline (timeline extension): a text Gantt chart of the plan, panning,
# zooming, clocked days and moving a deadline
Output docs/media/timeline.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-timeline; clear; nvim -u docs/media/demo/timeline.lua $ORG_DEMO_DIR/views/plan.org" Enter
Sleep 2.5s
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap :Org timeline | scheduled to deadline, Effort, today` Enter
Show
Type ":Org timeline"
Sleep 500ms
Enter
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap ] | pan to the future` Enter
Show
Type "]"
Sleep 1.8s
Type "["
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap - | zoom out to a column a day` Enter
Show
Type "-"
Sleep 2.5s
Type "+"
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap c | show the days that were clocked` Enter
Show
Type "c"
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap D | move the overdue deadline` Enter
Show
Type "j"
Sleep 800ms
Type "D"
Sleep 1.2s
Type "l"
Sleep 300ms
Type "l"
Sleep 300ms
Type "l"
Sleep 300ms
Type "l"
Sleep 300ms
Type "l"
Sleep 600ms
Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap <CR> | open the task` Enter
Show
Sleep 400ms
Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
