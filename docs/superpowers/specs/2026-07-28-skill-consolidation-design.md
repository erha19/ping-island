# One-Click Skill Consolidation Design

Date: 2026-07-28  
Status: approved

## Goal

Provide **one-click consolidation** that moves scattered agent skills into a central vault at `~/.agents/skills` (configurable), replaces former locations with symlinks, and keeps the Local Skill Manager’s central route registry as the dispatcher. This is the foundation for later **update** and **uninstall**.

## Decisions

| Topic | Choice |
| --- | --- |
| Ingest mode | **Move** (not copy) |
| Default vault | `~/.agents/skills` |
| Same-name merge | Auto-pick by source priority |
| Relink scope | Only locations that already had that `folderName` |
| Confirm UX | Preview summary, then execute |

## Source priority (high → low)

1. Skills under configured **manual roots**
2. `.claude/skills`
3. `.codex/skills`
4. All other discovered roots (WorkBuddy, Cursor, …)

If the vault already contains `folderName`, that vault copy is the canonical target (no overwrite). Other locations are relinked to it.

## Algorithm

1. Discover skills (existing `LocalSkillCatalog`).
2. Group by `folderName`.
3. For each group, build a plan entry:
   - Resolve canonical destination = `vaultRoot/folderName`.
   - If destination exists: `action = relinkOnly` (skip move).
   - Else: pick highest-priority real directory (not already a symlink into the vault) as winner → `action = moveThenRelink`.
   - Collect all other group paths as `relink_paths`.
   - Skip paths that already correctly symlink to the destination.
   - Mark conflicts when destination exists as a non-directory / non-symlink obstacle, or when a relink target is a non-empty real directory we refuse to delete without it being a losing duplicate (losing duplicates are replaced by design after preview confirm).
4. Show preview counts: move / relink / skip / conflict.
5. On confirm, execute with `FileManager` (create vault, move, replace losers with symlinks).
6. Ensure vault root is present in discovery (default auto root already includes `.agents/skills`).

## Persistence

Extend `SkillManager.registry.v1`:

```json
{
  "vault_root_path": "/Users/me/.agents/skills",
  "global_launch_profile_id": "...",
  "manual_roots": [],
  "routes": {}
}
```

Empty / missing `vault_root_path` → default `~/(.agents)/skills`.

## UI

Settings → Integration → 本地技能:

- Central vault path row (choose / open / reset default)
- **一键整理** button → confirmation alert with preview counts → result status

## Non-goals (v1)

- Marketplace / remote update
- Uninstall UI (v1.1)
- Interactive per-skill conflict picker
- Relinking into agents that never had the skill

## Success criteria

1. After consolidate, canonical skills live under the vault root.
2. Former agent skill folders for those names are symlinks to the vault.
3. Preview runs without mutating disk; confirm mutates as planned.
4. Unit tests cover priority picking, already-in-vault relink, and conflict skip.
