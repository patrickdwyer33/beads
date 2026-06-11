#!/bin/sh
# notify-ntfy.sh — Claude Code hook → ntfy.sh push notification to your phone.
#
# DISABLED BY DEFAULT. To enable:
#   1. Install the ntfy app on your phone (ntfy.sh) and subscribe to a topic
#      with a LONG, RANDOM name (public server = the topic name is the only
#      access control — anyone who knows it can read/publish).
#   2. Put that topic on the first non-comment line of:
#        ~/.claude/hooks/ntfy-topic.txt
#      (or export CLAUDE_NTFY_TOPIC in your environment).
# Until a real topic is set, this script is a silent no-op — nothing is sent.
#
# Wired in ~/.claude/settings.json under hooks.Notification (fires when Claude
# needs your input / has been waiting). Add it under "Stop" or "SessionEnd" too
# if you want end-of-turn / end-of-session pings (Stop fires every turn → noisy).

set -u

# --- resolve topic (env wins, else the topic file) ---
TOPIC="${CLAUDE_NTFY_TOPIC:-}"
TOPIC_FILE="$HOME/.claude/hooks/ntfy-topic.txt"
if [ -z "$TOPIC" ] && [ -f "$TOPIC_FILE" ]; then
  TOPIC=$(grep -vE '^[[:space:]]*#' "$TOPIC_FILE" 2>/dev/null | head -1 | tr -d '[:space:]')
fi

# Disabled / still the placeholder → do nothing, succeed.
case "$TOPIC" in
  "" | *REPLACE-WITH* | *PLACEHOLDER*) exit 0 ;;
esac

# --- read hook event JSON from stdin (best-effort) ---
payload=$(cat 2>/dev/null || printf '')
parsed=$(printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
print(d.get("hook_event_name", ""))
print((d.get("message", "") or "").replace("\n", " ")[:200])
print(d.get("cwd", ""))
' 2>/dev/null)

event=$(printf '%s\n' "$parsed" | sed -n '1p')
msg=$(printf   '%s\n' "$parsed" | sed -n '2p')
cwd=$(printf   '%s\n' "$parsed" | sed -n '3p')

# Sensible default text per event (Stop/SessionEnd carry no "message" field).
if [ -z "$msg" ]; then
  case "$event" in
    Notification) msg="Needs your attention." ;;
    Stop)         msg="Finished responding — your turn." ;;
    SubagentStop) msg="A subagent finished." ;;
    SessionEnd)   msg="Session ended." ;;
    *)            msg="Claude Code: ${event:-event}" ;;
  esac
fi
# A distinct ntfy tag/emoji per event for quick glanceability.
case "$event" in
  Notification) tag="bell" ;;
  Stop|SubagentStop) tag="white_check_mark" ;;
  SessionEnd) tag="checkered_flag" ;;
  *) tag="robot" ;;
esac
# Title includes the project folder name so you know which session.
proj=${cwd##*/}
title="Claude Code${proj:+ — $proj}"

curl -fsS --max-time 5 \
  -H "Title: $title" \
  -H "Tags: $tag" \
  -d "$msg" \
  "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true

exit 0
