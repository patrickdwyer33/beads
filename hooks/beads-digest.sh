#!/bin/sh
# beads-digest.sh — SessionStart cross-repo beads digest for /dev sessions.
#
# Built 2026-06-06 to fix a double-work race: the old digest piped
# `coordination status` (a diagnostic of work ALREADY in progress) through
# `grep '^- '`, which kept bead TITLES but dropped the assignee/status lines —
# so in-flight beads showed up looking like available backlog. An agent picked
# one (w0s) that was already in progress.
#
# This version separates the two cleanly, per repo:
#   ▸ ready     — scheduler-ranked, unblocked, NOT in-progress  → safe to claim
#   🔒 in-flight — already claimed/in-progress, shown WITH assignee → do NOT pick
#
# The banner also carries the post-claim worktree instruction (added
# 2026-06-06): twice, agents claimed a bead then asked the user to open a new
# `claude` session, because the in-session EnterWorktree tool is DEFERRED (its
# schema isn't loaded, so it's invisible in the tool list) and the only
# always-in-context guidance was this banner. The banner now tells the agent to
# ToolSearch+EnterWorktree in THIS session and never to send the user off to a
# new session. Keep that line — it's the decisive prompt at claim time.
#
# Read-only: it never claims or mutates anything. The DB is the live shared
# source of truth (one .beads/beads.db per repo; worktrees redirect to it), so
# this reflects every agent's claims — BUT it is still a point-in-time snapshot
# taken at session start. The real anti-collision guarantee is claiming before
# you work (`br update <id> --claim`), which is what the banner tells agents.

export PATH="$HOME/.local/bin:$PATH"
export NO_COLOR=1
command -v br >/dev/null 2>&1 || exit 0

REPOS="dwyerlab-api dwyerlab-remix astrid-macos astrid-browser astrid-ios devops"
READY_N=5
INFLIGHT_N=8

echo '## Beads — cross-repo backlog digest (launched in /dev)'
echo 'CLAIM BEFORE YOU WORK with `bd`, NOT `br`: `bd update <id> --claim` is atomic (assignee + status=in_progress) and drops the bead from every other agent'\''s ready list. Use `bd` (not bare `br`) because `bd` ROUTES a fully-qualified id (e.g. `dwyerlab-api-lmk2`) to its home repo'\''s DB from ANY cwd, and stamps a SESSION-DISTINCT actor (your branch) so a parallel same-user session'\''s claim is visibly not yours. Bare `br` only sees the cwd'\''s DB — it CANNOT see/claim a bead from another repo'\''s worktree or from /dev, which is exactly how two sessions once double-worked one bead. ▸ ready = safe to claim. 🔒 in-flight = already claimed (assignee shown) — do NOT pick.'
echo 'CROSS-REPO BEADS: a bead'\''s id prefix is its TRACKING repo, which is often NOT the repo the code lands in (the api repo is the orchestrator; epics there have children whose work is in dwyerlab-remix/ios/macos — see the bead'\''s "Repo:" line). Claiming + EnterWorktree therefore target DIFFERENT repos: `bd update <id> --claim` (routes to the id'\''s home DB) → `EnterWorktree` into the WORK repo → write code there. `bd` makes the claim work regardless of which worktree you end up in.'
echo 'AFTER YOU CLAIM, do the work IN THIS SESSION — NEVER tell the user to open a new terminal or start a new `claude` session. Step into an isolated worktree with the **EnterWorktree** tool: from /dev use the repo-prefixed name, e.g. `EnterWorktree(name: "dwyerlab-remix/lmk2-escalation-card")`; already inside a repo session use `EnterWorktree(name: "<branch>")`. NOTE: EnterWorktree/ExitWorktree are DEFERRED tools — their schemas are NOT loaded and a direct call fails, so FIRST run `ToolSearch(query: "select:EnterWorktree,ExitWorktree")` to load them, THEN call. (To read a single repo'\''s FULL backlog, `cd` into it / point `bd --db` at its DB — that does NOT mean having the user launch a session.)'

for d in $REPOS; do
  db="$HOME/dev/$d/.beads/beads.db"
  [ -f "$db" ] || continue

  cs=$(br --db "$db" coordination status 2>/dev/null)
  sm=$(printf '%s\n' "$cs" | grep -E '^Workspace:' | head -1)
  echo "• $d — ${sm:-(empty)}"

  # ▸ ready — scheduler-ranked available work. scheduler ranks only READY
  # candidates (open, unblocked, not deferred), so in-progress beads can't leak
  # in. Keep just the numbered recommendation lines (drop the score-breakdown).
  ready=$(br --db "$db" scheduler --limit "$READY_N" 2>/dev/null | grep -E '^[0-9]+\. score ' | head -"$READY_N")
  if [ -n "$ready" ]; then
    printf '    ▸ ready (claim before working):\n'
    printf '%s\n' "$ready" | sed 's/^/        /'
  fi

  # 🔒 in-flight — claimed/in-progress, WITH assignee so taken work is obvious.
  # coordination status prints "- <id> [Px] title" then an indented
  # "assignee: … | age: … | classification: …" line; keep exactly those two
  # (drops the verbose advisory/evidence/deps/comment lines).
  inflight=$(printf '%s\n' "$cs" | grep -E '^- |^[[:space:]]+assignee:' | head -$((INFLIGHT_N * 2)))
  if [ -n "$inflight" ]; then
    printf '    🔒 in-flight (already claimed — do NOT pick):\n'
    printf '%s\n' "$inflight" | sed 's/^/        /'
  fi
done
true
