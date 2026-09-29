Output docs/media/video/clips/agenda.mp4
Source docs/media/video/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-video-agenda ; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/work.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms "set nohlsearch" Enter
Ctrl+G
Type@5ms "Cap" Enter
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oa a | the day agenda` Enter
Show
Type " oa" Sleep 700ms
Type "a" Sleep 2s
Type "n" Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap t d | mark it DONE from the agenda` Enter
Show
Type "t" Sleep 900ms
Type "d" Sleep 1.4s
Hide
Ctrl+G
Type@5ms `Cap vw | the whole week` Enter
Show
Type "vw" Sleep 2.5s
Sleep 500ms
