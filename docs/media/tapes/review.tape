# Weekly review: the review extension, step by step
Output docs/media/review.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-review; clear; nvim -u docs/media/demo/review.lua $ORG_DEMO_DIR/notes.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms `Cap :Org review | start the weekly review` Enter
Show
Sleep 800ms
Type ":Org review" Enter
Sleep 2s
Hide
Ctrl+G
Type@5ms `Cap s | schedule an inbox entry` Enter
Show
Sleep 600ms
Type "s"
Sleep 1.2s
Type "i"
Sleep 500ms
Type "fri"
Sleep 900ms
Enter
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap d | delete a done one` Enter
Show
Type "jj"
Sleep 600ms
Type "d"
Sleep 1s
Type "y"
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap n | next step: stuck projects, waiting, overdue` Enter
Show
Type "n"
Sleep 1.8s
Type "n"
Sleep 1.5s
Type "n"
Sleep 1.8s
Hide
Ctrl+G
Type@5ms `Cap n | the next two weeks, someday, time spent` Enter
Show
Type "n"
Sleep 2.2s
Type "n"
Sleep 1.5s
Type "n"
Sleep 2.2s
Hide
Ctrl+G
Type@5ms `Cap <CR> | reflect: answer a question` Enter
Show
Type "n"
Sleep 1.2s
Enter
Sleep 1s
Type "Shipped the 1.0 release candidate"
Sleep 600ms
Escape
Ctrl+C
Ctrl+C
Sleep 1.8s
Hide
Ctrl+G
Type@5ms `Cap F | finish: the review goes into the log` Enter
Show
Type "F"
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 1s
