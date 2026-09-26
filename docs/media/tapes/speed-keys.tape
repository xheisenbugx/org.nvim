# Speed keys at the start of a heading
Output docs/media/speed-keys.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-speed-keys; clear; DEMO_SNACKS=1 DEMO_SPEED=1 nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/projects.org" Enter
Sleep 2.5s
Show
Sleep 1s
Shift+Tab
Sleep 300ms
Shift+Tab
Sleep 800ms
Type "gg"
Type "/Website"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap 0i Insert mode at the start of a heading` Enter
Show
Type "0i"
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap n next heading` Enter
Show
Type "n"
Sleep 1s
Type "n"
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap t change the TODO state` Enter
Show
Type "t"
Sleep 1.2s
Type "t"
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap U move the subtree up` Enter
Show
Type "U"
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap c cycle its visibility` Enter
Show
Type "c"
Sleep 1.2s
Type "c"
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap ? every speed key` Enter
Show
Type "?"
Sleep 2.5s
Escape
Sleep 600ms
Escape
Sleep 800ms
Sleep 1.5s
