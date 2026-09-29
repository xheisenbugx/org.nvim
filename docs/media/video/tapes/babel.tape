Output docs/media/video/clips/babel.mp4
Source docs/media/video/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-video-babel ; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/babel.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms "set nohlsearch" Enter
Ctrl+G
Type@5ms "Cap" Enter
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap C-c C-c | run the block, results inline` Enter
Show
Type "/import" Enter Sleep 500ms
Ctrl+C Ctrl+C Sleep 1.8s
Type "/printf" Enter Sleep 500ms
Ctrl+C Ctrl+C Sleep 1.5s
Type "/vim.version" Enter Sleep 500ms
Ctrl+C Ctrl+C Sleep 1.2s
Type "zz" Sleep 1.5s
