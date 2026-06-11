#!/bin/zsh
# PostToolUse(Bash) hook: when a bead is claimed via `br|bd update <id> --claim`,
# rename THIS session's cmux workspace (the left-column item) to the bead's
# title, and color it by repo. Fires on every claim, agent- or human-driven.
#
# Safe no-op when: not inside cmux, cmux/br/jq unavailable, command isn't a
# claim, or the id/title can't be resolved. Never blocks the tool call.
#
# DRYRUN=1 prints the action instead of performing it (for testing).

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/Applications/cmux.app/Contents/Resources/bin:$PATH"

# Only meaningful inside a cmux workspace pane
[ -n "$CMUX_WORKSPACE_ID" ] || exit 0
command -v jq  >/dev/null 2>&1 || exit 0
command -v br  >/dev/null 2>&1 || exit 0
command -v cmux >/dev/null 2>&1 || exit 0

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$cmd" ] || exit 0

# Only act on an actual claim: `br|bd ... update <id> ... --claim`
# (bd is the cross-repo wrapper around br — claims now run through it; match both)
printf '%s' "$cmd" | grep -Eq '\b(br|bd)\b.*\bupdate\b.*--claim' || exit 0

# Bead id = first non-flag token after `update` (awk: portable, no \b reliance)
id="$(printf '%s' "$cmd" | awk '{for(i=1;i<=NF;i++) if($i=="update"){for(j=i+1;j<=NF;j++) if(substr($j,1,1)!="-"){print $j; exit}}}')"
[ -n "$id" ] || exit 0

# Resolve the bead's repo from its id prefix so this works regardless of cwd
# (a claim may be run from /dev, a worktree, or the repo itself).
DEV="${DEV_ROOT:-$HOME/dev}"
dbargs=()
# Discover beads repos, longest name first so the longest matching prefix wins.
for r in $(for d in "$DEV"/*/.beads; do
    [ -d "$d" ] || continue
    basename "$(dirname "$d")"
  done | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-); do
  case "$id" in "$r"-*) db="$DEV/$r/.beads/beads.db"; [ -f "$db" ] && dbargs=(--db "$db"); break;; esac
done

json="$(br show "$id" "${dbargs[@]}" --json 2>/dev/null)"
title="$(printf '%s' "$json" | jq -r '.[0].title // empty' 2>/dev/null)"
[ -n "$title" ] || exit 0
repo="$(printf '%s' "$json" | jq -r '.[0].source_repo // empty' 2>/dev/null)"

# Keep the narrow left column readable
short="$(printf '%s' "$title" | cut -c1-60)"

palette=(Blue Green Orange Purple Teal Indigo Magenta Olive)
if [ -n "$repo" ]; then
  idx=$(( $(printf '%s' "$repo" | cksum | cut -d' ' -f1) % ${#palette[@]} + 1 ))
  color="${palette[$idx]}"
else
  color=""
fi

if [ "$DRYRUN" = "1" ]; then
  echo "[cmux-label] id=$id repo=$repo color=${color:-none} title=\"$short\""
  exit 0
fi

cmux rename-workspace "$short" >/dev/null 2>&1 || true
[ -n "$color" ] && cmux workspace-action --action set-color --color "$color" >/dev/null 2>&1 || true
exit 0
