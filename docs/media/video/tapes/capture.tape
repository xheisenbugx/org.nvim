Output docs/media/video/clips/capture.mp4
Source docs/media/video/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-video-capture ; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/notes.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms "set nohlsearch" Enter
Ctrl+G
Type@5ms "Cap" Enter
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oc | capture from anywhere` Enter
Show
Type " oc" Sleep 1.2s
Type "w" Sleep 800ms
Type "t" Sleep 1s
Type "Fix the flaky agenda test" Sleep 700ms
Hide
Ctrl+G
Type@5ms `Cap C-c C-c | file it and get back to work` Enter
Show
Escape Ctrl+C Ctrl+C Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Type ":e $ORG_DEMO_DIR/work.org" Enter Sleep 500ms
Shift+Tab Sleep 400ms
Shift+Tab Sleep 2s
