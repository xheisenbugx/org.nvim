# Lists: bullet styles, new items, indenting, moving, checkboxes
Output docs/media/lists.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-lists; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/lists.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/milk"
Enter
Sleep 600ms
Hide
Ctrl+G
Type@5ms `Do <S-Right> cycle the bullet style` Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Do <S-Right> cycle the bullet style` Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Do <S-Right> cycle the bullet style` Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Do <S-Right> cycle the bullet style` Enter
Show
Sleep 1.2s
Type "/bread"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Do <M-CR> new item` Enter
Show
Sleep 600ms
Type "butter"
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Do <M-CR> new item` Enter
Show
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap <Tab> on an empty item: indent it` Enter
Show
Tab
Sleep 800ms
Type "salted"
Escape
Sleep 1s
Type "/Tag the"
Enter
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Do <M-Up> move the item up, renumbered` Enter
Show
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Do <M-Up> move the item up, renumbered` Enter
Show
Sleep 1.2s
Type "/Passport"
Enter
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap V<leader>o- turn the lines into a list` Enter
Show
Type "Vj"
Sleep 500ms
Type " o-"
Sleep 1.2s
Escape
Type "j"
Hide
Ctrl+G
Type@5ms `Do <M-S-CR> new checkbox item` Enter
Show
Sleep 600ms
Type "Toothbrush"
Escape
Sleep 600ms
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-c> toggle the checkbox` Enter
Show
Ctrl+C Ctrl+C
Sleep 1.5s
Sleep 1.5s
