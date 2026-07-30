# Local Skill Manager Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox syntax.

**Goal:** Replace AI-COS Mission with a local skill manager (discover, central route, paste+open, symlink).

**Architecture:** `LocalSkillCatalog` + `SkillRouteRegistry` + `SkillPasteBuilder` + `SkillSymlinkLinker`; reuse `AICOSCodexActivator` / launch-target resolution for opening agents.

**Tech Stack:** Swift / SwiftUI / XCTest / UserDefaults JSON

## Global Constraints

- API / persisted JSON fields: `snake_case`
- Do not edit skill file bodies from Island
- Symlink only; never overwrite non-symlink directories
- Keep Island panel minimal

## File map

| File | Role |
| --- | --- |
| `PingIsland/Models/LocalSkillModels.swift` | `LocalSkill`, registry DTO |
| `PingIsland/Services/SkillManager/*` | Catalog, registry, paste, symlink, skills-path helper |
| `PingIsland/UI/Views/LocalSkillManagerPanelView.swift` | Island panel (replaces Mission UI) |
| `PingIsland/UI/Views/SessionListView.swift` | Host new panel |
| `PingIsland/UI/Views/SettingsWindowView.swift` | Skill Manager settings card |
| `PingIslandTests/LocalSkillManagerTests.swift` | Unit tests |
| `docs/local-skill-manager.md` + `AGENTS.md` | Docs |

## Tasks

### Task 1: Models + registry + catalog + paste + linker

- [ ] Add models and services with injectable paths/FileManager for tests
- [ ] Tests: discovery, launch resolve, paste, symlink conflict
- [ ] Run `PingIslandTests/LocalSkillManagerTests`

### Task 2: Island panel replacement

- [ ] Add `LocalSkillManagerPanelView`
- [ ] Wire `SessionListView` / header help strings / view-model comments
- [ ] Remove Mission-only UI from the flag flow

### Task 3: Settings + docs

- [ ] Replace Settings AI-COS card with Skill Manager
- [ ] Update `docs/local-skill-manager.md`, point `docs/ai-cos-mission-pack.md`, update `AGENTS.md`
- [ ] Add Localizable strings (zh-Hans / en)
- [ ] Build / run focused tests
