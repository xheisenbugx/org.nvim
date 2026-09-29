Output docs/media/video/clips/tables.mp4
Source docs/media/video/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-video-tables ; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/tables.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms "set nohlsearch" Enter
Ctrl+G
Type@5ms "Cap" Enter
Show
Sleep 800ms
Type "G" Sleep 200ms
Hide
Ctrl+G
Type@5ms `Cap | Tab | tables that align as you type` Enter
Show
Type@40ms "i|Item|Qty|Price|Total|" Escape Sleep 150ms
Type@40ms "o|-" Escape Sleep 150ms
Type@40ms "o|Coffee|3|4.5|" Escape Sleep 150ms
Type@40ms "o|Keyboard|1|120|" Escape Sleep 150ms
Type@40ms "o|Stickers|10|0.85|" Escape Sleep 150ms
Type@40ms "o|-" Escape Sleep 150ms
Type@40ms "o|Sum" Escape Sleep 150ms
Hide
Ctrl+G
Type@5ms `Cap #+TBLFM | spreadsheet formulas` Enter
Show
Type@35ms "o#+TBLFM: @2$4..@4$4=$2*$3::@5$4=vsum(@2..@4)" Escape Sleep 700ms
Ctrl+C Ctrl+C Sleep 1.5s
Type "/120" Enter Sleep 300ms
Hide
Ctrl+G
Type@5ms `Cap edit a cell, everything recalculates` Enter
Show
Type "ciw99" Escape Sleep 500ms
Type "G" Ctrl+C Ctrl+C Sleep 2s
