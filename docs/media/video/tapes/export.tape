Output docs/media/video/clips/export.mp4
Source docs/media/video/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-video-export ; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/export.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms "set nohlsearch" Enter
Ctrl+G
Type@5ms "Cap" Enter
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oe | export to Markdown, HTML, LaTeX…` Enter
Show
Sleep 1.3s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Type " oe" Sleep 1.2s
Type "m" Sleep 900ms
Type "M" Sleep 3s
