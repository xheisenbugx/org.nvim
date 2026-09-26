Output docs/media/tables.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-tables; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/tables.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "G" Sleep 300ms
Type "i|Item|Qty|Price|Total|" Escape Sleep 200ms
Type "o|-" Escape Sleep 200ms
Type "o|Coffee|3|4.5|" Escape Sleep 200ms
Type "o|Keyboard|1|120|" Escape Sleep 200ms
Type "o|Stickers|10|0.85|" Escape Sleep 200ms
Type "o|-" Escape Sleep 200ms
Type "o|Sum" Escape Sleep 200ms
Type "o#+TBLFM: @2$4..@4$4=$2*$3::@5$4=vsum(@2..@4)" Escape Sleep 1s
Ctrl+C Ctrl+C Sleep 1.5s
Type "/120" Enter Sleep 400ms
Type "ciw99" Escape Sleep 600ms
Type " oTf" Sleep 1.5s
Sleep 1s
