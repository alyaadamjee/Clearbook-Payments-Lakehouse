#!/bin/zsh
# Creates the Clearbook Genie space from genie/space.json.
# usage: scripts/deploy_genie.sh <catalog.schema> <warehouse_id> [profile]
set -e
schema=$1; wh=$2; profile=${3:-DEFAULT}; here=${0:A:h}
id() { uuidgen | tr -d '-' | tr 'A-F' 'a-f'; }
jq --arg s "$schema" --arg wh "$wh" --arg ids "$(for i in {1..20}; do id; done)" '
  ($ids | split("\n")) as $ids |
  {title, description, warehouse_id: $wh, serialized_space: ({
     version: 2,
     config: {sample_questions: [.sample_questions | to_entries[] | {id: $ids[.key], question: [.value]}]},
     data_sources: {tables: [.tables | sort[] | {identifier: "\($s).\(.)"}]},
     instructions: {text_instructions: [{id: $ids[19], content: [.instructions[] | . + "\n"]}]}
   } | tojson)}' "$here/../genie/space.json" > "${TMPDIR:-/tmp}/genie_space.json"
databricks api post /api/2.0/genie/spaces -p "$profile" --json @"${TMPDIR:-/tmp}/genie_space.json" | jq -r '"space_id: \(.space_id)"'
