Output docs/media/video/clips/outline.mp4
Source docs/media/video/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-video-outline ; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/notes.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms "set nohlsearch" Enter
Ctrl+G
Type@5ms "Cap" Enter
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap S-Tab | cycle the whole outline` Enter
Show
Shift+Tab Sleep 900ms
Shift+Tab Sleep 1.2s
Type "/Ideas" Enter Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oK | move the subtree up` Enter
Show
Type " oK" Sleep 700ms
Type " oK" Sleep 1.2s
Type "/changelog" Enter Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap C-c C-c | tick a checkbox` Enter
Show
Ctrl+C Ctrl+C Sleep 700ms
Type "j" Ctrl+C Ctrl+C Sleep 1.2s
Type "?Release" Enter Sleep 300ms
Hide
Ctrl+G
Type@5ms `Do <S-Right> | cycle the TODO state` Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Do <S-Right> | cycle the TODO state` Enter
Show
Sleep 1.5s
Sleep 800ms
