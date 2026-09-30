# Diagrams: mermaid blocks rendered to files by the diagrams extension,
# a generated file name, render on save and the content-hash cache.
# Needs mmdc on $PATH, or $DEMO_MMDC (see docs/media/demo/diagrams.lua).
Output docs/media/diagrams.gif
Source docs/media/tapes/common.tape

Hide
Type "export ORG_DEMO_DIR=/tmp/org-demo-diagrams; clear; nvim -u docs/media/demo/diagrams.lua $ORG_DEMO_DIR/diagrams.org" Enter
Sleep 2.5s
Show
Sleep 1.2s
Hide
Ctrl+G
Type@5ms `Cap C-c C-c | render the mermaid block` Enter
Type "5G"
Show
Sleep 1s
Ctrl+C
Ctrl+C
Sleep 4s
Hide
Ctrl+G
Type@5ms `Cap :!file | the result is a real PNG` Enter
Show
Type ":!file %:h/flow.png" Sleep 500ms Enter
Sleep 3s
Enter
Sleep 500ms
Hide
Ctrl+G
Type@5ms `Cap :w | render_on_save: every diagram, no :file needed` Enter
Show
Sleep 800ms
Type ":w" Sleep 400ms Enter
Sleep 4.5s
Hide
Ctrl+G
Type@5ms `Cap edit + :w | changed diagrams render again, the rest come from the cache` Enter
Type "17G"
Show
Sleep 800ms
Type "oPhone->>Laptop: ack"
Escape
Sleep 500ms
Type ":w" Sleep 400ms Enter
Sleep 4.5s
Hide
Ctrl+G
Type@5ms `Cap :!ls | the rendered files` Enter
Show
Type ":!ls %:h/*.png %:h/diagrams" Sleep 500ms Enter
Sleep 3.5s
Enter
Hide
Ctrl+G
Type@5ms `Cap` Enter
Show
Sleep 1s
