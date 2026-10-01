#!/bin/sh
# JSON array of the $1 most recently touched sessions: {sessionId, cwd, title, prompt, mtime}.
find ~/.claude/projects -mindepth 2 -maxdepth 2 -name '*.jsonl' -printf '%T@ %p\n' | sort -rn | head -n "${1:-20}" |
while read -r t f; do
  sid=$(basename "$f" .jsonl)
  cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$f" | cut -d'"' -f4)
  [ -n "$cwd" ] || continue
  title=$(grep -F '"type":"ai-title"' "$f" | tail -n 1 | jq -r '.aiTitle // empty')
  prompt=$(grep -F "\"sessionId\":\"$sid\"" ~/.claude/history.jsonl | tail -n 1 | jq -r '.display // empty')
  [ -n "$title$prompt" ] || continue
  jq -nc --arg s "$sid" --arg c "$cwd" --arg t "$title" --arg p "$prompt" --argjson m "${t%.*}" \
    '{sessionId: $s, cwd: $c, title: $t, prompt: ($p | gsub("\\s+"; " ") | .[0:120]), mtime: ($m * 1000)}'
done | jq -sc .
