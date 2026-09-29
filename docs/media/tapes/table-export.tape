# Exporting a table: the format is picked from a list
Output docs/media/table-export.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-table-export; clear; nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/budget.org" Enter
Sleep 2.5s
Show
Sleep 1s
Type "/Coffee"
Enter
Sleep 600ms
Hide
Ctrl+G
Type@5ms `Cap :Org table_export | j/k pick a format, e add parameters` Enter
Show
Type ":Org table_export"
Sleep 500ms
Enter
Sleep 800ms
Type "/tmp/org-demo-table-export/budget.tex"
Sleep 500ms
Enter
Sleep 1.8s
Type "j"
Sleep 600ms
Type "j"
Sleep 600ms
Type "k"
Sleep 600ms
Type "k"
Sleep 1.2s
Type "e"
Sleep 800ms
Type " :splice t"
Sleep 1s
Enter
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap budget.tex the exported file` Enter
Ctrl+G
Type@5ms `vsplit /tmp/org-demo-table-export/budget.tex` Enter
Show
Sleep 3s
