# lsp extension: org-lint diagnostics inline, document symbols, hover on a
# timestamp and on a link, and a rename that updates links in another file
Output docs/media/lsp.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-lsp; clear; nvim -u docs/media/demo/lsp.lua" Enter
Sleep 2s
# opened after startup: the config creates the files
Ctrl+G
Type@5ms `edit $ORG_DEMO_DIR/lsp/project.org` Enter
Sleep 1.5s
Ctrl+G
Type@5ms `Cap org-lint | diagnostics, inline` Enter
Show
Sleep 2.5s
# document symbols in the location list
Hide
Ctrl+G
Type@5ms `Cap document_symbol() | the outline as symbols` Enter
Show
Type@40ms ":lua vim.lsp.buf.document_symbol()"
Sleep 400ms
Enter
Sleep 3s
Hide
Ctrl+G
Type@5ms `lclose` Enter
# hover on a timestamp
Type "3Gf<"
Ctrl+G
Type@5ms `Cap K | hover a timestamp` Enter
Show
Sleep 600ms
Type "K"
Sleep 3.2s
# hover on a link
Hide
Type "11Gf["
Ctrl+G
Type@5ms `Cap K | hover a link: its target` Enter
Show
Sleep 600ms
Type "K"
Sleep 3s
# rename the CUSTOM_ID: every link follows, in both files
Hide
Type "5G$"
Ctrl+G
Type@5ms `Cap grn | rename the CUSTOM_ID` Enter
Show
Sleep 800ms
Type "grn"
Sleep 1s
Ctrl+U
Type@90ms "beta-launch"
Sleep 600ms
Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `botright 8split %:h/journal.org` Enter
Ctrl+G
Type@5ms `Cap journal.org | its links were renamed too` Enter
Show
Sleep 3.5s
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 800ms
