# Local Skill Manager Design

Date: 2026-07-28  
Status: approved

## Goal

Replace the AI-COS Mission panel with a **local skill manager**: discover skills on disk, centrally route them to Integration agents (launch + symlink), and paste a short “use this skill” prompt into the selected agent.

## Product decisions

| Decision | Choice |
| --- | --- |
| AI-COS Mission panel | **Fully replaced** by the skill manager |
| Skill discovery | Auto-discover common agent skill dirs + manual roots |
| Soft routing | **Both** launch routing and disk symlinks |
| Routing source of truth | One central registry |
| Default granularity | **Global default launch agent** + per-skill overrides |

## Non-goals (v1)

- Editing `SKILL.md` inside Island
- Writing agent settings / hooks JSON
- Auto-injecting into app-server threads
- Full AI-COS state machine write-back
- Marketplace / remote skill install

## Architecture

```text
LocalSkillCatalog  →  [LocalSkill]
SkillRouteRegistry →  global_default_launch + routes[skill_id]
SkillPasteBuilder  →  clipboard text
SkillSymlinkLinker →  symlink under agent skills dirs
AICOSCodexActivator (reuse) → open/focus launch target
```

Island panel and Settings both read/write `SkillRouteRegistry`. AI-COS L1/L2/L3 / Investment Decision are no longer dedicated panel flows; leftover AICOS pack builders may remain for tests until removed in a follow-up.

## Skill discovery

A skill = directory containing `SKILL.md`.

**Auto roots** (when the directory exists), relative to the user’s home:

- `~/.claude/skills`
- `~/.codex/skills`
- `~/.agents/skills`
- `~/.cursor/skills`
- `~/.cursor/plugins/*/skills` (one level of plugin packs)
- `~/.gemini/skills`
- `~/.qwen/skills`
- `~/.kimi/skills`
- Plus each installed managed hook profile’s inferred skills directory (`<config-home>/skills`)

**Manual roots:** persisted path list; recursive scan for `SKILL.md` (bounded depth, e.g. 4).

Dedup by standardized absolute path. Identity: `skill_id = standardized path`.

Parse optional YAML front matter from `SKILL.md` for `name` / `description`; fall back to folder name.

## Central registry

Persistence key: `SkillManager.registry.v1` (JSON).

```json
{
  "global_launch_profile_id": "codex-hooks",
  "manual_roots": ["/Users/me/skills"],
  "routes": {
    "/Users/me/.claude/skills/foo": {
      "launch_profile_id": "workbuddy-hooks",
      "linked_profile_ids": ["claude-hooks", "codex-hooks"]
    }
  }
}
```

Legacy: if `global_launch_profile_id` is empty, fall back to `AICOS.launchTargetProfileID.v1`.

### Launch resolution

`launch_profile_id = route.launch_profile_id ?? global_launch_profile_id`, then resolve against currently installed Integration profiles (same fallback order as today’s AI-COS launch target resolver).

### Symlink linking

For each `linked_profile_ids` entry, ensure:

`{agentSkillsDir}/{skillFolderName} → {skill.directory}`

- Create parent `skills` dir if missing  
- Refuse to overwrite a real (non-symlink) directory  
- Broken symlink → replace  
- Unlink when user removes a profile from the skill’s linked set  
- Settings / panel can show link health (ok / missing / conflict)

## Island panel UX

Flag header entry opens **技能管理** (not AI-COS Mission).

1. Searchable skill list (name + source tag)  
2. Selection shows description + resolved launch agent  
3. Primary: **复制并打开 [agent]**  
4. Secondary: **链接到 Agent…** multi-select of installed profiles  
5. Optional inline picker to override launch agent for this skill (clear = use global)

## Settings → Integration

Replace the AI-COS card with **本地技能**:

- Global default launch target (installed agents)  
- Manual skill roots (add / reveal / remove)  
- Short status: discovered skill count  

Protocol-root-only AI-COS path UI is removed from Settings in this change.

## Paste template (v1)

Language follows app localization:

```text
请使用以下本地技能执行我的请求：
- 名称: {name}
- 路径: {path}
- 说明: {description}

请先阅读该路径下的 SKILL.md，再按技能要求执行。
```

Do not dump the full skill body onto the clipboard.

## Migration

| From | To |
| --- | --- |
| Flag → AI-COS Mission panel | Flag → Local Skill Manager panel |
| `AICOS.launchTargetProfileID.v1` | Read as fallback for global launch |
| Settings AI-COS path / launch rows | Skill Manager settings card |
| `docs/ai-cos-mission-pack.md` | Superseded by `docs/local-skill-manager.md` (keep short pointer) |

## Success criteria

1. User can see skills from auto + manual roots in the Island panel.  
2. Copy+open uses global default unless the skill has an override.  
3. Linking creates valid symlinks under selected agent skill dirs; conflicts are reported, not clobbered.  
4. AI-COS protocol / investment dedicated buttons are gone from the Island UI.  
5. Unit tests cover discovery dedupe, launch resolution, paste text, and symlink conflict handling.
