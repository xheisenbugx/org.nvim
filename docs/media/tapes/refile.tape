# Refile and archive
Output docs/media/refile.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-refile; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/inbox.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/Book"
Enter
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap <leader>or refile to another heading` Enter
Show
Type " or"
Sleep 1.5s
Sleep 800ms
Type "13"
Sleep 600ms
Enter
Sleep 1.5s
Type "/Order"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>o$ archive the subtree` Enter
Show
Type " o$"
Sleep 1.5s
Type ":e $ORG_DEMO_DIR/work.org"
Enter
Sleep 600ms
Shift+Tab
Sleep 400ms
Shift+Tab
Sleep 1.5s
Sleep 1.5s
