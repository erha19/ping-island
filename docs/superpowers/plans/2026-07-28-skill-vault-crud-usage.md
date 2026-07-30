# Skill Vault Create / Update / Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add lightweight vault skill create/update in Settings, and show `已使用 n 次` next to link counts, incremented on Island “复制并打开”.

**Architecture:** `SkillVaultWriter` writes owned `SKILL.md` files under the vault; `SkillUsageStore` persists `folder_name → count` in UserDefaults; catalog joins counts into `SkillVaultEntry.use_count`; Settings sheet handles create/edit; Island panel records use after copy+activate.

**Tech Stack:** Swift / SwiftUI / UserDefaults / XCTest (`PingIslandTests`)

## Global Constraints

- DTO / persisted JSON fields: `snake_case` (`use_counts`, `folder_name`, `use_count`)
- Create/update: metadata only (`name`, `description`, short `body`); no full Markdown IDE
- Symlink vault entries: never editable via writer
- Usage: +1 only on Island copy-and-open success path (after clipboard write; count even if agent focus fails — still a intentional use)
- Spec: `docs/superpowers/specs/2026-07-28-skill-vault-crud-usage-design.md`
- Do not commit unless the user asks

---

## File map

| File | Role |
| --- | --- |
| `PingIsland/Models/LocalSkillModels.swift` | Add `usageDefaultsKey`, usage snapshot type if needed |
| `PingIsland/Services/SkillManager/SkillUsageStore.swift` | Create — load/save/increment |
| `PingIsland/Services/SkillManager/SkillVaultWriter.swift` | Create — create/update + validation |
| `PingIsland/Services/SkillManager/SkillVaultCatalog.swift` | Add `use_count`, `body` for edit form; join usage |
| `PingIsland/UI/Views/SettingsWindowView.swift` | New/Edit sheet + inventory buttons + usage label |
| `PingIsland/UI/Views/LocalSkillManagerPanelView.swift` | `recordUse` on copyAndOpen |
| `PingIslandTests/SkillVaultWriterTests.swift` | Create |
| `PingIslandTests/SkillUsageStoreTests.swift` | Create |
| `docs/local-skill-manager.md`, `AGENTS.md` | Docs |

---

### Task 1: SkillUsageStore

**Files:**
- Create: `PingIsland/Services/SkillManager/SkillUsageStore.swift`
- Modify: `PingIsland/Models/LocalSkillModels.swift` (add `usageDefaultsKey`)
- Test: `PingIslandTests/SkillUsageStoreTests.swift`

**Interfaces:**
- Produces:
  - `SkillUsageSnapshot` with `use_counts: [String: Int]`
  - `SkillUsageStore.load(defaults:) -> SkillUsageSnapshot`
  - `SkillUsageStore.useCount(folderName:defaults:) -> Int`
  - `SkillUsageStore.recordUse(folderName:defaults:) -> Int` (returns new count)
  - `SkillManagerConstants.usageDefaultsKey = "SkillManager.usage.v1"`

- [ ] **Step 1: Add constant + store + failing tests, then implement until green**

```swift
// LocalSkillModels.swift — inside SkillManagerConstants
static let usageDefaultsKey = "SkillManager.usage.v1"

struct SkillUsageSnapshot: Codable, Equatable, Sendable {
    var use_counts: [String: Int]
    static let empty = SkillUsageSnapshot(use_counts: [:])
}

enum SkillUsageStore {
    nonisolated static func load(defaults: UserDefaults = .standard) -> SkillUsageSnapshot { ... }
    nonisolated static func save(_ snapshot: SkillUsageSnapshot, defaults: UserDefaults = .standard) { ... }
    nonisolated static func useCount(folderName: String, defaults: UserDefaults = .standard) -> Int { ... }
    @discardableResult
    nonisolated static func recordUse(folderName: String, defaults: UserDefaults = .standard) -> Int { ... }
}
```

Rules:
- Ignore blank `folderName`
- `recordUse` increments by 1 and persists
- Use ephemeral `UserDefaults(suiteName:)` in tests

Run: `xcodebuild ... -only-testing:PingIslandTests/SkillUsageStoreTests`

---

### Task 2: SkillVaultWriter + catalog body/use_count

**Files:**
- Create: `PingIsland/Services/SkillManager/SkillVaultWriter.swift`
- Modify: `PingIsland/Services/SkillManager/SkillVaultCatalog.swift`
- Test: `PingIslandTests/SkillVaultWriterTests.swift` (extend lifecycle coverage)

**Interfaces:**
- Produces:
  - `SkillVaultDraft` (`folder_name`, `name`, `description`, `body`)
  - `SkillVaultWriter.validateFolderName(_:) -> String?` (error message or nil)
  - `SkillVaultWriter.renderSKILLMarkdown(name:description:body:) -> String`
  - `SkillVaultWriter.create(draft:vaultRoot:fileManager:) throws -> String` (path)
  - `SkillVaultWriter.update(path:name:description:body:fileManager:) throws`
  - `SkillVaultWriter.readBody(fromMarkdown:) -> String`
  - `SkillVaultEntry.use_count: Int` and `body: String` (body from markdown after front matter)
  - `listEntries(..., useCounts: [String: Int] = SkillUsageStore.load().use_counts)`

Validation regex conceptually: `^[a-z0-9][a-z0-9_-]*$`

Create: mkdir + write SKILL.md; fail if path exists.  
Update: refuse if symlink; rewrite whole SKILL.md with template.

- [ ] **Step 1: TDD writer create/update/validation + catalog joins use_count**

Run: `xcodebuild ... -only-testing:PingIslandTests/SkillVaultWriterTests`

---

### Task 3: Settings UI (新建 / 编辑 + 已使用)

**Files:**
- Modify: `PingIsland/UI/Views/SettingsWindowView.swift`

**Interfaces:**
- Consumes: `SkillVaultWriter`, `SkillVaultEntry.use_count`, `SkillVaultEntry.body`, `SkillVaultEntry.is_symlink`
- Produces: sheet for create/edit; inventory shows `已链接 n 处 · 已使用 m 次`; Edit hidden for symlinks

ViewModel methods:
- `createSkillVaultEntry(draft:) -> String?` (error)
- `updateSkillVaultEntry(entry:name:description:body:) -> String?`
- `skillVaultDraftForEdit(_ entry) -> SkillVaultDraft`

- [ ] **Step 1: Wire inventory label, New/Edit buttons, confirmation-free sheet, refresh after save**

Manual check: Settings → 本地技能 → 中央库技能 shows counts; New creates skill; Edit on owned only.

---

### Task 4: Island usage increment + docs

**Files:**
- Modify: `PingIsland/UI/Views/LocalSkillManagerPanelView.swift` (`copyAndOpen`)
- Modify: `docs/local-skill-manager.md`
- Modify: `AGENTS.md`

After `SkillPasteBuilder.copyPromptToClipboard(prompt)`:
`SkillUsageStore.recordUse(folderName: skill.folderName)`

Update docs: create/update/usage; remove “editing out of scope” for metadata.

- [ ] **Step 1: Record use + docs; run SkillUsageStoreTests + SkillVaultWriterTests + SkillVaultLifecycleTests**

---

## Spec coverage checklist

| Spec item | Task |
| --- | --- |
| Create owned skill | 2, 3 |
| Update owned metadata | 2, 3 |
| Refuse symlink edit | 2, 3 |
| Usage store + display | 1, 2, 3 |
| Increment on copy-and-open | 4 |
| Docs | 4 |

## Execution note

Inline execution in the approving session unless the user requests subagent-driven mode.
