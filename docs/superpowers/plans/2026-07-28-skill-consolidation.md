# Skill Consolidation Implementation Plan

> **For agentic workers:** Implement task-by-task.

**Goal:** One-click move+relink of scattered skills into `~/.agents/skills` with priority dedupe.

**Architecture:** `SkillConsolidatePlanner` builds a dry-run plan; `SkillConsolidator` executes; Settings triggers preview/confirm; vault path stored on `SkillRouteRegistrySnapshot`.

**Tech Stack:** Swift / SwiftUI / XCTest / FileManager

## Tasks

### Task 1: Models + planner + consolidator + tests
### Task 2: Registry vault path + Settings UI + docs
