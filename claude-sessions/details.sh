#!/bin/sh
# Print a JSON summary of Claude transcript $1 (session id $2). Titles/mode/todos can be far back, so
# grep the whole file for them; everything else comes from the tail (transcripts grow to many MB).
# The last typed prompt comes from history.jsonl, since tool/agent traffic buries it in the transcript.
# Cost sums every billed message of the session and its subagents (only "usage" lines, so it stays fast).
dir=$(dirname "$0")
prompt=$(grep -F "\"sessionId\":\"$2\"" ~/.claude/history.jsonl | tail -n 1 | jq -r '.display // empty')
cost=$(cat "$1" "${1%.jsonl}"/subagents/*.jsonl 2>/dev/null | grep -F '"usage"' \
  | jq -sc --slurpfile p ~/.claude/pricing-cache.json -f "$dir/cost.jq" 2>/dev/null)
{ grep -h -e '"type":"ai-title"' -e '"type":"permission-mode"' -e '"name":"TodoWrite"' "$1"; tail -c 300000 "$1" | tail -n +2; } \
  | jq -sc --arg prompt "$prompt" --argjson cost "${cost:-null}" -f "$dir/details.jq"
