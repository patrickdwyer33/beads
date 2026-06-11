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
dbargs=()
for r in dwyerlab-remix dwyerlab-api astrid-browser astrid-macos astrid-ios devops; do
  case "$id" in "$r"-*) db="$HOME/dev/$r/.beads/beads.db"; [ -f "$db" ] && dbargs=(--db "$db"); break;; esac
done

json="$(br show "$id" "${dbargs[@]}" --json 2>/dev/null)"
title="$(printf '%s' "$json" | jq -r '.[0].title // empty' 2>/dev/null)"
[ -n "$title" ] || exit 0
repo="$(printf '%s' "$json" | jq -r '.[0].source_repo // empty' 2>/dev/null)"

# Keep the narrow left column readable
short="$(printf '%s' "$title" | cut -c1-60)"

case "$repo" in
  *remix*)   color=Blue ;;
  *devops*)  color=Orange ;;
  *ios*)     color=Purple ;;
  *browser*) color=Teal ;;
  *macos*)   color=Indigo ;;
  *api*)     color=Green ;;
  *)         color="" ;;
esac

if [ "$DRYRUN" = "1" ]; then
  echo "[cmux-label] id=$id repo=$repo color=${color:-none} title=\"$short\""
  exit 0
fi

cmux rename-workspace "$short" >/dev/null 2>&1 || true
[ -n "$color" ] && cmux workspace-action --action set-color --color "$color" >/dev/null 2>&1 || true
exit 0
