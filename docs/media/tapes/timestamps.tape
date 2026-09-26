# Editing timestamps in place
Output docs/media/timestamps.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-timestamps; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/dates.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/10:00"
Enter
Sleep 400ms
Type "b"
Sleep 300ms
Hide
Ctrl+G
Type@5ms `Do <S-Right> one day later` Enter
Show
Sleep 900ms
Hide
Ctrl+G
Type@5ms `Do <S-Right> one day later` Enter
Show
Sleep 900ms
Hide
Ctrl+G
Type@5ms `Do <S-Left> one day earlier` Enter
Show
Sleep 900ms
Type "f:h"
Sleep 300ms
Hide
Ctrl+G
Type@5ms `Cap <C-a> on the hour: +1 hour` Enter
Show
Ctrl+A
Sleep 900ms
Ctrl+A
Sleep 900ms
Type "ll"
Hide
Ctrl+G
Type@5ms `Do <S-Up> on the minutes: +5 minutes` Enter
Show
Sleep 900ms
Hide
Ctrl+G
Type@5ms `Do <S-Up> on the minutes: +5 minutes` Enter
Show
Sleep 900ms
Type "/Conference"
Enter
Type "jw"
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap <CR> on a date: open the agenda for that day` Enter
Show
Enter
Sleep 2.5s
Sleep 1.5s
