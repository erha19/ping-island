# Local Skill Manager

NotchCode’s opened-header **flag** opens a **local skill manager** (replacing the former AI-COS Mission panel):

1. Discover skills from common agent `skills` directories and any **manual roots** under **Settings → Integration → 本地技能**.
2. Set a **global default launch agent** (installed Integration profiles). Individual skills may override.
3. Select a skill → **复制并打开 [agent]** copies a short paste prompt and focuses that agent. Each successful copy increments that skill’s **use count** (keyed by `folder_name`).
4. Optional **链接到 Agent…** creates/removes symlinks under each agent’s skills directory (`<config-home>/skills/<skill-folder>` → skill path). Conflicts with real directories are reported, never overwritten.
5. **一键整理** (Settings → 本地技能 → 中央技能库) moves scattered skills into the central vault (default `~/.agents/skills`), dedupes same `folderName` by source priority (manual → Claude → Codex → others), and replaces former locations with symlinks. Preview + confirm before disk changes. External-only symlinks can be **adopted** as vault hub links without copying wiki content.
6. **中央库 CRUD（轻量）** (Settings → 本地技能 → 中央库技能):
   - **查**: list vault entries (name, description, directory vs symlink, inbound agent-link count, use count)
   - **增**: create owned vault skill (`folder_name` + name / description / short body → `SKILL.md`), or **从仓库安装** from a built-in allowlisted GitHub catalog (v1: `anthropics/skills` under `skills/`) by downloading the full skill folder
   - **改**: edit name / description / body for owned directories only (symlink hubs are not editable in-app)
   - **删**: remove vault hub + agent symlinks that pointed at it; external symlink targets are left intact; registry route keys for those paths are cleared. Usage counts are retained by `folder_name`.

Central routing state is stored under UserDefaults key `SkillManager.registry.v1` (`vault_root_path`, `global_launch_profile_id`, `manual_roots`, `routes`). Usage counts use `SkillManager.usage.v1` (`use_counts`). Legacy `AICOS.launchTargetProfileID.v1` is read as a fallback for the global launch target.

## Code map

| Piece | Path |
| --- | --- |
| Models | `PingIsland/Models/LocalSkillModels.swift` |
| Discovery / registry / paste / symlink / consolidate / vault inventory+writer+uninstall / usage / remote install | `PingIsland/Services/SkillManager/` |
| Island panel | `PingIsland/UI/Views/LocalSkillManagerPanelView.swift` |
| Entry | Opened-header flag in `NotchView`; host in `SessionListView`; Settings → Integration |
| Design / plan | `docs/superpowers/specs/2026-07-28-local-skill-manager-design.md`, consolidation / CRUD-usage / remote-install specs under `docs/superpowers/specs/` |
| Tests | `PingIslandTests/LocalSkillManagerTests.swift`, `SkillConsolidateTests.swift`, `SkillVaultLifecycleTests.swift`, `SkillVaultWriterTests.swift`, `SkillUsageStoreTests.swift`, `SkillRemoteInstallTests.swift` |

## Out of scope (v1)

- Full Markdown / multi-file skill IDE
- Editing external targets through vault hub symlinks
- Renaming `folder_name` after create
- Custom / private remote skill repositories and GitHub token UI
- Remote skill auto-update / version diff
- Writing agent settings/hooks JSON
- Auto-injecting prompts into app-server threads
- Inferring usage from transcripts / hooks
- Dedicated AI-COS L1/L2/L3 / Investment Decision panel actions (legacy pack builders may remain for tests)
