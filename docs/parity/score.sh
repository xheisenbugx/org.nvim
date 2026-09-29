#!/bin/sh
# Score inventory.tsv (LIBRARY, SYMBOL, cmd|opt, STATUS, EVIDENCE, NOTE) per
# area and overall. STATUS is done, vim (stock Neovim covers it), partial
# (counts half), missing, emacs-only, or na (Emacs internals, not counted):
#   overall = (done + vim + partial/2) / (total - na - emacs-only)
#   strict  = (done + vim + partial/2) / (total - na)
# Usage: docs/parity/score.sh [inventory.tsv]
file=${1:-$(dirname "$0")/inventory.tsv}
printf '%-16s %5s %5s %4s %4s %4s %5s %4s  %7s %7s\n' \
  area total done vim part miss emacs na overall strict
awk -F'\t' '
function area(f) {
  if (f ~ /^org-agenda$|^org-habit$/) return "Agenda"
  if (f ~ /^org-table$|^org-plot$/) return "Tables"
  if (f == "org-colview") return "Column-view"
  if (f == "org-list") return "Lists"
  if (f ~ /^org-clock$|^org-timer$/) return "Clocking"
  if (f ~ /^org-capture$|^org-datetree$/) return "Capture"
  if (f ~ /^org-refile$|^org-archive$/) return "Refile/archive"
  if (f ~ /^org-attach|^org-id$|^org-crypt$|^org-footnote$|^org-lint$|^org-ctags$|^org-protocol$/) return "Attach/ID/misc"
  if (f ~ /^org-mobile$|^org-feed$/) return "Feeds/MobileOrg"
  if (f ~ /^ol/) return "Links"
  if (f ~ /^ob/ || f == "org-src") return "Babel/src"
  if (f ~ /^oc/) return "Citations"
  if (f ~ /^ox/) return "Export"
  return "Core"
}
function row(name, n, d, v, p, m, e, x) {
  s = d + v + 0.5 * p
  return sprintf("%-16s %5d %5d %4d %4d %4d %5d %4d  %6.1f%% %6.1f%%", name, n, d, v, p, m, e, x, 100 * s / (n - x - e), 100 * s / (n - x))
}
{ a = area($1); n[a]++; c[a, $4]++; N++; C[$4]++ }
END {
  for (a in n)
    print row(a, n[a], c[a, "done"], c[a, "vim"], c[a, "partial"], c[a, "missing"], c[a, "emacs-only"], c[a, "na"]) | "sort"
  close("sort")
  print row("ALL", N, C["done"], C["vim"], C["partial"], C["missing"], C["emacs-only"], C["na"])
}' "$file"
