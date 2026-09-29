# Key menus: sections, toggles on the right, submenus and <BS> to go back
Output docs/media/menus.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-menus; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/export.org" Enter
Sleep 2.5s
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <leader>oe | toggle b s, submenu h, back <BS>` Enter
Show
Type " oe"
Sleep 1.8s
Type "b"
Sleep 1.2s
Type "s"
Sleep 1.5s
Type "h"
Sleep 1.8s
Backspace
Sleep 1.5s
Escape
Sleep 600ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oa agenda dispatcher` Enter
Show
Type " oa"
Sleep 2.5s
Escape
Sleep 1s
