# Spaced repetition: the drill extension (org-drill)
Output docs/media/drill.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-drill; clear; nvim -u docs/media/demo/drill.lua $ORG_DEMO_DIR/cards.org" Enter
Sleep 2.5s
Show
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap :Org drill | review the cards that are due` Enter
Show
Sleep 800ms
Type ":Org drill" Enter
Sleep 2s
Hide
Ctrl+G
Type@5ms `Cap <Space> show the answer` Enter
Show
Sleep 500ms
Type " "
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap 0-5 | grade the answer: 4 = good` Enter
Show
Sleep 500ms
Type "4"
Sleep 2s
Type " "
Sleep 1.5s
Type "5"
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap cloze | [text||hint] is hidden` Enter
Show
Sleep 2s
Type " "
Sleep 1.8s
Type "3"
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap twosided | one side is the question` Enter
Show
Sleep 2s
Type " "
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap 1 | a failed card comes back` Enter
Show
Sleep 500ms
Type "1"
Sleep 2s
Type " "
Sleep 1s
Type "4"
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap <Esc> | the schedule is in the file` Enter
Show
Escape
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Do <S-Tab>zR | show everything` Enter
Show
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
