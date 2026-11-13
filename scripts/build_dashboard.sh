#!/bin/zsh
# Builds dashboard/clearbook.lvdash.json from dashboard/dashboard.jq. Needs jq.
set -e
here=${0:A:h}
jq -n -f "$here/../dashboard/dashboard.jq" > "$here/../dashboard/clearbook.lvdash.json"
echo "wrote dashboard/clearbook.lvdash.json"
