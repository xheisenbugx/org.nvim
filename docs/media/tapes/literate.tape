# literate extension: saving init.org tangles it and runs the changed Lua
# blocks, so options change live; an error is a diagnostic on its org line
Output docs/media/literate.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-literate; clear; nvim -u docs/media/demo/literate.lua $ORG_DEMO_DIR/nvim/init.org" Enter
Sleep 2.5s
Ctrl+G
Type@5ms `call search('= false')` Enter
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap :w | tangle init.org and run the changed block` Enter
Show
Type "w"
Sleep 300ms
Type "ciwtrue"
Sleep 300ms
Escape
Sleep 400ms
Type "j$"
Sleep 200ms
Type "ciwtrue"
Sleep 300ms
Escape
Sleep 600ms
Type ":w" Enter
Sleep 3s
Hide
Ctrl+G
Type@5ms `Cap :w | an error shows on its org line` Enter
Show
Type "ovim.o.relativenumbr = true"
Sleep 400ms
Escape
Sleep 400ms
Type ":w" Enter
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap :w | fixed: the diagnostic goes, the option applies` Enter
Show
Type ":s/numbr/number/" Enter
Sleep 800ms
Type ":w" Enter
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
