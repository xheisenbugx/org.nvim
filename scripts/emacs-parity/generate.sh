#!/bin/sh
# Regenerate the Emacs parity fixtures under tests/fixtures/emacs/.
#
#   scripts/emacs-parity/generate.sh [area...]    (areas: visibility agenda
#                                                  export clocktable lint)
#
# EMACS   the Emacs binary (default: emacs)
# ORG_DIR an Org 9.8.10 checkout/ELPA dir put first on the load-path
#         (default: the Org bundled with Emacs, which must then be 9.8.10)
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
EMACS=${EMACS:-emacs}

if [ $# -eq 0 ]; then
  set -- visibility agenda export clocktable lint
fi

for area in "$@"; do
  echo "== $area"
  # A fixed zone and locale: weekday names, clock sums and "now" don't
  # depend on the machine generating the fixtures.
  PARITY_ROOT=$root TZ=UTC0 LC_ALL=C LANG=C \
    "$EMACS" -Q --batch ${ORG_DIR:+-L "$ORG_DIR"} \
    -l "$here/common.el" -l "$here/$area.el" </dev/null
done
