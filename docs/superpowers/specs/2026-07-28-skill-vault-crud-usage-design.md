# Local Skill Vault Create / Update / Usage Design

Date: 2026-07-28  
Status: approved; implemented

## Goal

Extend the central skill vault lifecycle beyond 查 + 删:

1. **Create** a new owned skill in the vault with lightweight metadata.
2. **Update** name / description / short body for owned (non-symlink) vault skills.
3. **Track usage** as a counter incremented when Island “复制并打开” succeeds, and show `已使用 n 次` beside `已链接 n 处` in Settings vault inventory.

## Decisions (locked)

| Topic | Choice |
| --- | --- |
| Create / update depth | Lightweight metadata only (not a full Markdown IDE) |
| Usage event | +1 on successful Island “复制并打开” |
| Symlink skills | Read / open / delete only — no in-app edit through the hub |
| Approach | Settings sheet + separate usage UserDefaults store keyed by `folder_name` |

## Non-goals

- Full Markdown / multi-file skill IDE
- Editing external targets through vault hub symlinks
- Renaming `folder_name` (would break agent symlinks)
- Inferring usage from transcripts / hooks
- Auto-clearing usage counts on uninstall
- Create/update UI inside the Island skill panel (panel stays launch-focused)

## Create

**Entry:** Settings → Integration → 本地技能 → 中央库技能 → **新建**

**Fields:**

- `folder_name` — vault directory name; validated as lowercase kebab-safe `[a-z0-9][a-z0-9_-]*` (reject empty / uppercase / path separators)
- `name` — front-matter `name` (defaults to `folder_name` if blank)
- `description` — optional front-matter `description`
- `body` — optional short markdown body after front matter

**Disk effect:**

- Create `<vault_root>/<folder_name>/`
- Write `<vault_root>/<folder_name>/SKILL.md` with YAML front matter + body
- If path already exists (directory or symlink), fail with a clear error; never overwrite

**Template shape:**

```markdown
---
name: <name>
description: <description>
---

<body or empty>
```

## Update

**Entry:** vault inventory row → **编辑** (only when `is_symlink == false`)

**Editable:** `name`, `description`, `body`  
**Not editable:** `folder_name`

**Disk effect:**

- Rewrite `SKILL.md` for that owned vault directory
- v1 rewrite policy: replace the whole file with the standard template above (name / description / body from the form). Do not attempt to preserve unknown front-matter keys in v1.
- Refuse update if the entry is a symlink or the path is missing

## Usage statistics

**Storage:** UserDefaults key `SkillManager.usage.v1`

```json
{
  "use_counts": {
    "<folder_name>": 3
  }
}
```

**Increment:**

- When `LocalSkillManagerPanelView` successfully completes “复制并打开” (clipboard copy + launch/focus attempt that the existing success path treats as done), call `SkillUsageStore.recordUse(folderName:)`
- Key by `LocalSkill.folderName` (last path component), so vault skills and linked agent paths that share the same folder name share one counter

**Display:**

- Settings vault inventory row: `已链接 n 处 · 已使用 m 次` (m defaults to 0)
- Optional later: Island panel can show the same count; not required for this slice

**Delete interaction:**

- Uninstall does **not** remove usage counts for that `folder_name`
- Same-named recreate continues the prior counter

## Code map (planned)

| Piece | Responsibility |
| --- | --- |
| `SkillVaultWriter` (new) | Create + update `SKILL.md` under vault; validation |
| `SkillUsageStore` (new) | Load / save / increment `use_counts` |
| `SkillVaultCatalog` / `SkillVaultEntry` | Expose `use_count` when listing (joined from usage store) |
| `SettingsWindowView` | New / Edit sheet; show usage next to link count |
| `LocalSkillManagerPanelView` | Record use on copy-and-open success |
| Tests | Writer validation/conflict; usage increment; catalog join |
| Docs | `docs/local-skill-manager.md`, `AGENTS.md` |

## UI sketch (Settings)

```
中央库技能                          [新建]
[搜索…]
┌─────────────────────────────────────────┐
│ name  [目录|软链]                        │
│ description…                             │
│ 已链接 2 处 · 已使用 5 次                │
│                    [打开] [编辑?] [删除] │
└─────────────────────────────────────────┘
```

- Softlink rows omit **编辑**
- New/Edit presented as a compact sheet (not a full settings page)

## Testing

- Create succeeds and produces readable front matter via existing catalog parser
- Create fails on duplicate folder
- Update rewrites owned skill; refused for symlink fixture
- Usage store increments and persists; catalog/list shows joined count
- Copy-and-open path unit-tests the store call (or thin recorder seam) without requiring UI automation

## Success criteria

- User can create an owned vault skill from Settings without leaving the app
- User can edit name/description/body of owned vault skills
- Softlink skills remain non-editable in Island Settings
- Vault list shows link count and use count side by side
- Each successful Island copy-and-open increments that skill’s use count
