# Footnotes
Output docs/media/footnotes.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-footnotes; clear; DEMO_SNACKS=1 nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/essay.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/editor"
Enter
Type "e"
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oif insert a footnote` Enter
Show
Type " oif"
Sleep 1.5s
Type "Org mode itself dates from 2003."
Escape
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-c> on the definition: back to the reference` Enter
Show
Type "0"
Ctrl+C Ctrl+C
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-c> on the reference: to the definition` Enter
Show
Ctrl+C Ctrl+C
Sleep 1.5s
Sleep 1.5s
