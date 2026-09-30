# Structural git merges: the merge extension's driver merges two branches
# that changed the same org file, then leaves one conflict scoped to the
# single entry both changed
Output docs/media/merge.gif
Source docs/media/tapes/common.tape

Hide
Type@5ms "export ORG_DEMO_DIR=/tmp/org-demo-merge R=$PWD GIT_MERGE_AUTOEDIT=no GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false" Enter
Type@5ms "export GIT_PAGER=cat PAGER=cat GIT_AUTHOR_NAME=Demo GIT_AUTHOR_EMAIL=demo@example.com GIT_COMMITTER_NAME=Demo GIT_COMMITTER_EMAIL=demo@example.com" Enter
Type@5ms "sh docs/media/demo/merge-setup.sh /tmp/org-demo-merge-repo && cd /tmp/org-demo-merge-repo" Enter
Type@5ms `alias v="nvim -u $R/docs/media/demo/merge.lua"; PS1='notes (main) $ '; clear` Enter
Sleep 1s
Show
Sleep 500ms
Type "git log --oneline --graph --all" Enter
Sleep 3s
Type "v tasks.org" Enter
Sleep 2.5s
Hide
Ctrl+G
Type@5ms `Cap :Org merge_install | use the Org merge driver in this repo` Enter
Show
Sleep 800ms
Type ":Org merge_install" Enter
Sleep 2s
Type "1" Enter
Sleep 2.5s
Type ":q" Enter
Sleep 500ms
Type "clear; cat .gitattributes" Enter
Sleep 1.5s
Type "git merge phone" Enter
Sleep 3s
Type "v tasks.org" Enter
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap merged | tags, properties, clocks and new entries of both sides` Enter
Show
Sleep 5s
Type ":q" Enter
Sleep 500ms
Type "clear; git merge laptop" Enter
Sleep 3s
Type "v tasks.org" Enter
Sleep 1.5s
Hide
Ctrl+G
Type@5ms `Cap conflict | only around the one headline both changed` Enter
Show
Sleep 5s
