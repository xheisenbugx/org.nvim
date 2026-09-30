# code extension: capture a Visual selection with its context, follow the
# code: link back to the function, and the project agenda with the
# repository's TODO comments (the demo config makes the git repository)
Output docs/media/code.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-code; clear; nvim -u docs/media/demo/code.lua $ORG_DEMO_DIR/app/src/app.lua" Enter
Sleep 3s
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap V <leader>ojc | capture the selected code` Enter
Show
Type "13G"
Sleep 300ms
Type "V4j"
Sleep 900ms
Type " ojc"
Sleep 2.2s
Type "Why does start print?"
Sleep 800ms
Escape
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap C-c C-c | file it in the repo's .org/tasks.org` Enter
Show
Sleep 600ms
Ctrl+C
Ctrl+C
Sleep 1s
Hide
Ctrl+G
Type@5ms `Cap <leader>ojp | open the project file` Enter
Show
Type " ojp"
Sleep 2.8s
Hide
Ctrl+G
Type@5ms `call search('code:')` Enter
Ctrl+G
Type@5ms `Cap RET | follow the code: link to the function` Enter
Show
Sleep 1.2s
Enter
Sleep 2.5s
Type " oja"
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap <leader>oja | project agenda with the code TODOs` Enter
Show
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `call search('escape')` Enter
Ctrl+G
Type@5ms `Cap RET | open the TODO comment's line` Enter
Show
Sleep 1.5s
Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
