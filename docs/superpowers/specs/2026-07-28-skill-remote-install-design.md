# Skill Vault Remote Install Design

Date: 2026-07-28  
Status: approved; implemented

## Goal

Let users install skills into the central vault from **built-in whitelisted public GitHub skill repositories**, by browsing a list and downloading the **full skill directory** (not only `SKILL.md`).

This sits beside the existing lightweight **新建** flow under Settings → Integration → 本地技能 → 中央库技能.

## Decisions (locked)

| Topic | Choice |
| --- | --- |
| Discovery UX | Built-in whitelist + browsable list |
| Download payload | Full skill folder (`SKILL.md` + scripts/references/assets/…) |
| Custom repos | Out of scope for v1 |
| Transport | GitHub Contents / git tree APIs (no local `git` clone) |
| Conflicts | Same as create: refuse overwrite of existing vault folder/symlink |

## Non-goals

- Custom repository URLs / private repos / GitHub token UI
- Claude Code `/plugin marketplace` protocol parity
- Auto-update / version diff / reinstall-from-remote
- Only-download-`SKILL.md` mode
- Island-panel install UI (Settings only for v1)

## Built-in catalogs

v1 ships a static allowlist in code, for example:

| id | owner/repo | default_ref | skills_root |
| --- | --- | --- | --- |
| `anthropic-skills` | `anthropics/skills` | `main` | `skills` (scan under this prefix; each child dir with `SKILL.md` is a skill) |

Also include `template` only if it contains a real skill with `SKILL.md`; do not treat `.claude-plugin` / `spec` as skills unless they contain `SKILL.md`.

Rules:

- Only entries in this allowlist may be contacted.
- Network host is GitHub API (`api.github.com`) + raw/blob download URLs returned by GitHub for that repo.
- If a catalog’s layout is nested (e.g. skills under `skills/` or `document-skills/`), discovery walks the tree and treats any directory containing `SKILL.md` as an installable skill. Folder name for vault install is the directory’s last path component.

## Browse flow

1. User opens **从仓库安装** sheet from 中央库技能.
2. Pick a catalog (if more than one).
3. App fetches skill index (cached ~1 hour in memory or UserDefaults by catalog id + ref).
4. List rows: `folder_name`, optional `name` / `description` (from `SKILL.md` front matter when cheaply available; otherwise folder name first and lazy-load metadata), `already_installed` (vault has same `folder_name`).
5. Search filter on name / folder / description.
6. Rate-limit / network errors surface as a clear message; no silent empty list without explanation.

### Index strategy (recommended)

1. `GET /repos/{owner}/{repo}/git/trees/{ref}?recursive=1`
2. Collect paths ending in `/SKILL.md`
3. Skill path = parent directory of each `SKILL.md`
4. Optionally fetch each `SKILL.md` (or batch) for front matter — if too slow, show folder names first and fetch metadata for visible rows only

## Install flow

1. User selects a remote skill → **安装**
2. Resolve all files under that skill path via Contents API (recursive) or by filtering the recursive tree + downloading each blob
3. Create `<vault_root>/<folder_name>/` and write files preserving relative paths
4. On any failure: delete the partial destination directory; report error
5. If destination already exists (dir or symlink): abort before writing
6. On success: dismiss or keep sheet; refresh vault inventory; show status like「已安装 xxx」

Do **not** auto-link into agent skills dirs; linking remains the existing Island / consolidate flows.

## Persistence

- No new registry fields required for v1 install provenance (optional later: `installed_from` metadata).
- Catalog allowlist is compile-time (or bundled JSON), not UserDefaults.
- Short-lived index cache key: `SkillManager.remoteCatalogCache.v1` (optional); may also keep memory-only cache for the Settings session.

## Code map (planned)

| Piece | Responsibility |
| --- | --- |
| `SkillRemoteCatalog` | Allowlist definitions |
| `SkillRemoteCatalogClient` | GitHub tree/contents fetch, parse skill index, download tree into temp/vault |
| `SkillRemoteInstallService` | Orchestrate install into vault with conflict + rollback |
| Settings UI | 「从仓库安装」sheet: catalog picker, search, install actions |
| Docs / tests | Client parsing with fixtures; install conflict/rollback; docs update |

## Security / sandbox notes

- Developer ID / non–App Store builds: normal HTTPS to GitHub is fine.
- App Store / sandbox lane: confirm network entitlement already allows outbound HTTPS; do not write outside the configured vault root.
- Never execute downloaded scripts as part of install; only write files.

## Testing

- Parse a fixture recursive tree JSON → expected skill paths
- Install into temp vault copies multiple relative files
- Conflict when folder exists
- Rollback leaves no partial folder after forced write failure (injectable file writer seam if needed)
- Allowlist rejects non-listed owner/repo even if caller passes one

## Success criteria

- User can browse the built-in Anthropic skills catalog from Settings
- User can install a full skill folder into the central vault
- Existing same-named vault entry is not overwritten
- Softlink / owned inventory continues to work after install
- No custom-repo or marketplace scope creep in v1
