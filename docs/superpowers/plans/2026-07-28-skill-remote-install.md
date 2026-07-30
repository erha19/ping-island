# Skill Remote Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Browse built-in GitHub skill catalogs and install full skill folders into the central vault from Settings.

**Architecture:** Static allowlist → GitHub recursive git tree for index → raw.githubusercontent.com downloads for files under each skill path → write into vault with conflict checks and rollback. Settings sheet for browse/install.

**Tech Stack:** Swift, URLSession, SwiftUI, XCTest

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-28-skill-remote-install-design.md`
- Only allowlisted `owner/repo`; v1 catalog: `anthropics/skills` with `skills_root = skills` (also accept `template` if it has SKILL.md via tree scan under configured roots)
- Full directory install; refuse overwrite; rollback partial dirs
- DTO fields `snake_case`
- Do not commit unless asked

## File map

| File | Role |
| --- | --- |
| `PingIsland/Services/SkillManager/SkillRemoteCatalog.swift` | Allowlist + remote skill models |
| `PingIsland/Services/SkillManager/SkillRemoteCatalogClient.swift` | Tree fetch, index parse, file download |
| `PingIsland/Services/SkillManager/SkillRemoteInstallService.swift` | Install into vault |
| `PingIsland/UI/Views/SettingsWindowView.swift` | 「从仓库安装」sheet |
| `PingIslandTests/SkillRemoteInstallTests.swift` | Fixture-based tests |
| `docs/local-skill-manager.md`, `AGENTS.md` | Docs |

---

### Task 1: Catalog + client parse/download + install service (TDD)

**Interfaces:**
- `SkillRemoteCatalogDefinition(id, title, owner, repo, default_ref, skills_roots: [String])`
- `SkillRemoteCatalog.builtIn: [SkillRemoteCatalogDefinition]`
- `SkillRemoteSkillSummary(folder_name, remote_path, name?, description?, catalog_id)`
- `SkillRemoteCatalogClient.listSkills(catalog:session:) async throws -> [SkillRemoteSkillSummary]`
- `SkillRemoteCatalogClient.downloadSkillFiles(catalog:remotePath:session:) async throws -> [(relativePath, Data)]`
- `SkillRemoteInstallService.install(summary:vaultRoot:existingFolderNames:session:fileManager:) async throws -> String`

- [ ] Implement + tests with tree fixture JSON and mock downloader / temp vault

### Task 2: Settings UI

- [ ] Add 「从仓库安装」 next to 「新建」; sheet with search, installed badge, install button; refresh vault on success

### Task 3: Docs

- [ ] Update `docs/local-skill-manager.md`, `AGENTS.md`, mark spec implemented

## Execution

Inline in approving session.
