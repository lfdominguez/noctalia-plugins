#!/bin/sh
# focus.sh PID: bring the terminal running Claude session PID to the front.
# - kitty (KITTY_PID / KITTY_WINDOW_ID in the session's environment, and kitty remote control
#   enabled): jump to the exact tab/split, then focus that kitty OS window.
# - tmux (TMUX / TMUX_PANE in the session's environment): select the session's pane in a tmux
#   client, then focus that client's terminal window.
# - any other terminal: walk up the process tree to the first process that owns a window.
. "$(dirname "$0")/wm.sh"

# focus_up PID: focus the window of PID or of its closest ancestor that owns one.
focus_up() {
  p=$1
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    wm_focus_pid "$p" && return 0
    # The parent pid is the second field after the ")" that ends the command name. Counting
    # fields from the start breaks on names with spaces, such as "tmux: server".
    p=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | cut -d' ' -f2)
  done
  return 1
}

pid=$1
env=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || exit 1
kpid=$(printf '%s\n' "$env" | sed -n 's/^KITTY_PID=//p')
wid=$(printf '%s\n' "$env" | sed -n 's/^KITTY_WINDOW_ID=//p')

if [ -n "$kpid" ] && [ -n "$wid" ] && command -v kitty >/dev/null; then
  sock="unix:@kitty-$kpid"
  if kitty @ --to "$sock" focus-window --match "id:$wid" >/dev/null 2>&1; then
    # The OS window's title is its active window's title, which is now ours: use it to pick the
    # right OS window when one kitty process owns several.
    title=$(kitty @ --to "$sock" ls --match "id:$wid" 2>/dev/null | jq -r '.[0].tabs[0].windows[0].title // empty')
    wm_focus_pid "$kpid" "$title"
    exit 0
  fi
fi

# The tmux server is not a child of any terminal, so walking up from a session inside tmux never
# finds a window. Walk up from a tmux client instead: preferably one already showing the pane's
# session, otherwise the most recently active one, which is switched to that session.
tmux_env=$(printf '%s\n' "$env" | sed -n 's/^TMUX=//p')
pane=$(printf '%s\n' "$env" | sed -n 's/^TMUX_PANE=//p')
if [ -n "$tmux_env" ] && [ -n "$pane" ] && command -v tmux >/dev/null; then
  tsock=${tmux_env%%,*}
  tab=$(printf '\t')
  session=$(tmux -S "$tsock" display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  clients=$(tmux -S "$tsock" list-clients \
    -F "#{client_activity}$tab#{client_pid}$tab#{client_name}$tab#{session_name}" 2>/dev/null | sort -rn)
  client=$(printf '%s\n' "$clients" | awk -F "$tab" -v s="$session" '$4 == s { print; exit }')
  [ -n "$client" ] || client=$(printf '%s\n' "$clients" | head -n 1)
  if [ -n "$session" ] && [ -n "$client" ]; then
    cpid=$(printf '%s\n' "$client" | cut -f2)
    cname=$(printf '%s\n' "$client" | cut -f3)
    tmux -S "$tsock" select-window -t "$pane" \; select-pane -t "$pane" \
      \; switch-client -c "$cname" -t "$pane" >/dev/null 2>&1
    focus_up "$cpid" && exit 0
  fi
fi

focus_up "$pid" && exit 0
exit 1
