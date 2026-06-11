---
name: create
description: Use when adding a new work item (bead) to a beads-inited repo's backlog — bugs, features, tasks, epics, or quick captures.
---

# Create a bead

From the target repo (or anywhere, with a fully-qualified parent/epic id):

- Standard: `bd create "<title>" --type bug|feature|task|epic -p 0..4 --slug <kebab> --description "<body>"`
- Child of an epic: add `--parent <epic-id>`.
- Quick capture (triage later): `bd q "<note>"`
- Dependencies (child blocked by parent): `bd dep add <child-id> <parent-id>`

Priority guide: 0 = drop everything, 4 = someday. Default to 2 unless told.
After creating, confirm the id back to the user. Do NOT claim it unless the
user asks to start work now (then use the beads-orc:start skill).
