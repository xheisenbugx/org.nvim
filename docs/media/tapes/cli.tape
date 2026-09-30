# The org command line (bin/org): the agenda as text and JSON, capture
# and the clock, from a shell
Output docs/media/cli.gif
Source docs/media/tapes/common.tape
Set TypingSpeed 45ms

Hide
Type `export ORG_DEMO_DIR=/tmp/org-demo-cli ORG_NVIM_CONFIG=$PWD/docs/media/demo/cli.lua PATH=$PWD/bin:$PATH` Enter
Type `export XDG_DATA_HOME=$ORG_DEMO_DIR/xdg XDG_STATE_HOME=$ORG_DEMO_DIR/xdg PS1='\[\e[38;2;166;219;255m\]~/org\[\e[0m\] $ '` Enter
Type "rm -rf $ORG_DEMO_DIR; org agenda >/dev/null; clear" Enter
Sleep 1.5s
Show
Sleep 500ms
Type "# today's agenda, printed by a headless Neovim" Enter
Type "org agenda" Enter
Sleep 3.5s
Hide
Type "clear" Enter
Show
Type "# JSON for status bars and scripts" Enter
Type "org agenda --json | jq -c '.items[] | {time, todo, title}'" Enter
Sleep 3.5s
Hide
Type "clear" Enter
Show
Type "# capture from anywhere" Enter
Type `org capture "Call the dentist"` Enter
Sleep 1.5s
Type "tail -4 $ORG_DEMO_DIR/inbox.org" Enter
Sleep 2.5s
Hide
Type "clear" Enter
Show
Type "# clock in, check it (e.g. in a tmux status line), clock out" Enter
Type `org clock in "Q4 roadmap"` Enter
Sleep 1.5s
Type "org clock status" Enter
Sleep 1.5s
Type "org clock status --format '#[fg=green]%e %t'" Enter
Sleep 2s
Type "org clock status --json | jq -c ." Enter
Sleep 2.5s
Type "org clock out" Enter
Sleep 3s
