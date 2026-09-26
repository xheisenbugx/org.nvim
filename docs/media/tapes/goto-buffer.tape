# Go to a heading of the buffer with a picker
Output docs/media/goto-buffer.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-goto-buffer; clear; DEMO_SNACKS=1 nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/projects.org" Enter
Sleep 2.5s
Show
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <leader>o. go to a heading in this file` Enter
Show
Type " o."
Sleep 1.5s
Type "dark"
Sleep 1.2s
Enter
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap <C-c><C-j> the Emacs key (org-goto)` Enter
Show
Ctrl+C Ctrl+J
Sleep 1.2s
Type "rust"
Sleep 1.2s
Enter
Sleep 1.5s
Sleep 1.5s
