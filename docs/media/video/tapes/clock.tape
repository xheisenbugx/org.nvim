Output docs/media/video/clips/clock.mp4
Source docs/media/video/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-video-clock ; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/work.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms "set nohlsearch" Enter
Ctrl+G
Type@5ms "Cap" Enter
Show
Sleep 800ms
Shift+Tab Sleep 300ms
Shift+Tab Sleep 600ms
Type "/Ship" Enter Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oxi | clock in` Enter
Show
Type " oxi" Sleep 2.2s
Hide
Ctrl+G
Type@5ms `Cap <leader>oxo | clock out` Enter
Show
Type " oxo" Sleep 1.2s
Type "/Reports" Enter Sleep 300ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oxr | a clock report` Enter
Show
Type " oxr" Sleep 800ms
Type ":s/subtree/file/" Enter Sleep 300ms
Ctrl+C Ctrl+C Sleep 2.5s
