# Live transclusion: the transclusion extension (org-transclusion)
Output docs/media/transclusion.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-transclusion; clear; nvim -u docs/media/demo/transclusion.lua $ORG_DEMO_DIR/meeting.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms `Cap #+transclude: | a heading of roadmap.org and lines 4-11 of retry.py` Enter
Show
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap <CR> | edit the source in a float` Enter
Type "3G"
Show
Sleep 800ms
Enter
Sleep 1.5s
Type "6G"
Sleep 400ms
Type "o"
Escape
Type "i- [ ] Record the demo"
Escape
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap :w | write roadmap.org: the transclusion follows` Enter
Show
Type ":w" Enter
Sleep 1s
Type "q"
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap <prefix>uA | insert the text into the buffer` Enter
Show
Sleep 600ms
Type " ouA"
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap <prefix>uD | back to virtual lines` Enter
Show
Sleep 600ms
Type " ouD"
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap zM | virtual lines fold with their heading` Enter
Show
Sleep 600ms
Type "zM"
Sleep 2s
Type "zR"
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 1s
