# org-ql: sexp and plain queries, a sorted view, acting on a result and
# the org-ql dynamic block
Output docs/media/ql.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-ql; clear; nvim -u docs/media/demo/ql.lua $ORG_DEMO_DIR/notes.org" Enter
Sleep 2.5s
Show
Sleep 800ms
Hide
Ctrl+G
Type@5ms `Cap :Org ql_search | a sexp query` Enter
Show
Type ":Org ql_search (and (todo) (or (tags " Type '"oss"' Type ") (priority " Type '"A"' Type ")))"
Sleep 600ms
Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap t | change a result's TODO state` Enter
Show
Sleep 600ms
Type "t"
Sleep 1s
Type "n"
Sleep 1.8s
Type "q"
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap :Org ql_search | the same in plain syntax` Enter
Show
Type ":Org ql_search todo:TODO,NEXT,WAITING !tags:habit"
Sleep 600ms
Enter
Sleep 2.5s
Type "q"
Sleep 400ms
Hide
Ctrl+G
Type@5ms `Cap :Org ql_view | a saved view sorted by deadline` Enter
Show
Type ":Org ql_view Deadlines"
Sleep 600ms
Enter
Sleep 2.5s
Type "q"
Sleep 400ms
Hide
Ctrl+G
Type@5ms `edit $ORG_DEMO_DIR/ql-report.org` Enter
Ctrl+G
Type@5ms `Cap C-c C-c | update the org-ql dynamic block` Enter
Type "4G"
Show
Sleep 1.2s
Ctrl+C
Ctrl+C
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 1s
