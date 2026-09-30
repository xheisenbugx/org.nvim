#!/usr/bin/env bash
# Records the extension clips at video size (1440x810) from the README tapes
# in docs/media/tapes, so the video and the GIFs show the same thing.
#   docs/media/video/extensions/record.sh            all of them
#   docs/media/video/extensions/record.sh kanban lsp some
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
names=("$@")
[[ ${#names[@]} -gt 0 ]] || names=(kanban timeline heatmap sidebar quickadd review pomodoro drill lsp code literate diagrams transclusion cli merge ics)
mkdir -p "$here/build/tapes" "$here/clips"
cd "$root"
for n in "${names[@]}"; do
  sed -e "s#^Output .*#Output docs/media/video/extensions/clips/$n.mp4#" \
      -e "s#^Source docs/media/tapes/common.tape#Source docs/media/video/tapes/common.tape#" \
      -e '/^Screenshot /d' \
      "docs/media/tapes/$n.tape" > "$here/build/tapes/$n.tape"
  vhs "docs/media/video/extensions/build/tapes/$n.tape" >/dev/null 2>&1 &
done
wait
