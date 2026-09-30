#!/bin/sh
# Builds the git repository merge.tape records: tasks.org on `main` and two
# branches, `phone` (merges cleanly) and `laptop` (one conflicting entry).
#
#   sh docs/media/demo/merge-setup.sh /tmp/org-demo-merge-repo
set -e
repo=${1:-/tmp/org-demo-merge-repo}
rm -rf "$repo"
mkdir -p "$repo"
cd "$repo"
export GIT_AUTHOR_NAME=Demo GIT_AUTHOR_EMAIL=demo@example.com
export GIT_COMMITTER_NAME=Demo GIT_COMMITTER_EMAIL=demo@example.com
g() { git -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
g init -q

cat > tasks.org <<'EOF'
#+TITLE: Tasks
#+TODO: TODO NEXT WAITING | DONE

* NEXT Ship the release                                              :work:
DEADLINE: <2026-10-02 Fri>
:PROPERTIES:
:ID: 5b1c
:EFFORT: 3:00
:END:
:LOGBOOK:
CLOCK: [2026-09-25 Fri 14:00]--[2026-09-25 Fri 15:00] =>  1:00
:END:
- [ ] changelog
- [ ] tag

- [ ] announce
* TODO Plan the offsite                                              :team:
Venue ideas.
* Reading
** TODO Designing Data-Intensive Applications
** TODO The Pragmatic Programmer
EOF
g add tasks.org
g commit -q -m "Tasks"

# phone: a tag, a property, a clock, a TODO state, a new entry
g checkout -q -b phone
cat > tasks.org <<'EOF'
#+TITLE: Tasks
#+TODO: TODO NEXT WAITING | DONE

* NEXT Ship the release                                         :work:urgent:
DEADLINE: <2026-10-02 Fri>
:PROPERTIES:
:ID: 5b1c
:EFFORT: 3:00
:OWNER: sam
:END:
:LOGBOOK:
CLOCK: [2026-09-29 Tue 16:00]--[2026-09-29 Tue 17:00] =>  1:00
CLOCK: [2026-09-25 Fri 14:00]--[2026-09-25 Fri 15:00] =>  1:00
:END:
- [ ] changelog
- [ ] tag

- [ ] announce on the blog
* WAITING Plan the offsite                                           :team:
Venue ideas.
Waiting for the budget.
* Reading
** TODO Designing Data-Intensive Applications
** TODO The Pragmatic Programmer
** TODO Crafting Interpreters
EOF
g commit -q -am "Edits from the phone"

# laptop: closes the offsite, which phone set to WAITING
g checkout -q main
g checkout -q -b laptop
cat > tasks.org <<'EOF'
#+TITLE: Tasks
#+TODO: TODO NEXT WAITING | DONE

* NEXT Ship the release                                              :work:
DEADLINE: <2026-10-02 Fri>
:PROPERTIES:
:ID: 5b1c
:EFFORT: 3:00
:END:
:LOGBOOK:
CLOCK: [2026-09-25 Fri 14:00]--[2026-09-25 Fri 15:00] =>  1:00
:END:
- [ ] changelog
- [ ] tag

- [ ] announce
* DONE Plan the offsite                                              :team:
CLOSED: [2026-09-29 Tue 18:10]
Venue ideas.
* Reading
** TODO Designing Data-Intensive Applications
** TODO The Pragmatic Programmer
EOF
g commit -q -am "Edits from the laptop"

# main: an effort, a clock, a checkbox, a new entry
g checkout -q main
cat > tasks.org <<'EOF'
#+TITLE: Tasks
#+TODO: TODO NEXT WAITING | DONE

* NEXT Ship the release                                              :work:
DEADLINE: <2026-10-02 Fri>
:PROPERTIES:
:ID: 5b1c
:EFFORT: 4:00
:END:
:LOGBOOK:
CLOCK: [2026-09-28 Mon 09:00]--[2026-09-28 Mon 11:30] =>  2:30
CLOCK: [2026-09-25 Fri 14:00]--[2026-09-25 Fri 15:00] =>  1:00
:END:
- [X] changelog
- [ ] tag

- [ ] announce
* TODO Plan the offsite                                              :team:
Venue ideas.
* Reading
** TODO Designing Data-Intensive Applications
** TODO The Pragmatic Programmer
** TODO A Philosophy of Software Design
EOF
g commit -q -am "Edits on main"
