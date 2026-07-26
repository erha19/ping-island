# Closed Notch Pet Identity Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Docked closed-notch leading icon uses a miniaturized settings pet (`MascotView` at `.idle`) for client identity, with the existing pixel status bar still carrying idle / working / warning.

**Architecture:** Evolve `ClosedNotchDotIcon` in place into an `HStack` of `MascotView` + status-only Canvas. Remap status-bar geometry from the old shared 10×4 canvas (cols 8–9) onto a local 2×4 grid. Delete per-kind silhouette glyphs. `NotchView.closedLeadingPetIcon` keeps calling `ClosedNotchDotIcon` when docked.

**Tech Stack:** Swift / SwiftUI, XCTest (`PingIslandTests`)

**Spec:** `docs/superpowers/specs/2026-07-26-closed-notch-pet-identity-design.md`

## Global Constraints

- Left pet always `MascotStatus.idle` (no working/warning halo on the pet).
- Right bar alone uses the real `status` for tone + spin / blink / static.
- Outer frame stays `size × size` (default 16 from `NotchView.petIconSize`).
- Pet size ≈ `size * 0.72`; status bar takes remaining width with ~1pt gap.
- Detached / opened paths keep full `MascotView`; do not change them.
- No new settings toggles; no closed-notch widening solely for this icon.
- Commits: only when the user explicitly asks; skip commit steps during execution unless requested.

---

## File Structure

| File | Role |
|---|---|
| `PingIsland/Models/ClosedNotchDotIconModel.swift` | Keep tone / motion; remap status bar to local 2×4; delete silhouette / `points(for:)`. |
| `PingIsland/UI/Components/ClosedNotchDotIcon.swift` | Compose `MascotView` + status Canvas. |
| `PingIslandTests/ClosedNotchDotIconTests.swift` | Drop silhouette uniqueness; assert local 2×4 status bar + keep tone/motion/spin. |
| `PingIslandTests/ZCodeHookInstallerTests.swift` | Drop silhouette assertions; keep mascot kind / brand checks. |
| `PingIsland/UI/Views/NotchView.swift` | Comment only (docked path still `ClosedNotchDotIcon`). |
| `PingIsland/Models/ClosedNotchMascotCarousel.swift` | Comment: rotate pet identity, not silhouette. |
| `AGENTS.md` | Closed icon = mini pet + status bar. |
| `docs/superpowers/specs/2026-07-26-closed-notch-pet-identity-design.md` | Mark status approved. |

No new source files; no Xcode project membership changes.

---

### Task 1: Local 2×4 status-bar geometry (TDD)

**Files:**
- Modify: `PingIslandTests/ClosedNotchDotIconTests.swift`
- Modify: `PingIsland/Models/ClosedNotchDotIconModel.swift`

**Interfaces:**
- Consumes: existing `ClosedNotchDotTone`, `ClosedNotchDotStatusMotion`, `ClosedNotchDotPoint`
- Produces (after this task):
  - `ClosedNotchDotGlyph.canvasColumns == 2`
  - `ClosedNotchDotGlyph.canvasRows == 4`
  - `ClosedNotchDotGlyph.statusBarPoints` = all cells `(0…1, 0…3)`
  - `ClosedNotchDotGlyph.statusBarCenter == (x: 0.5, y: 1.5)`
  - `rotatedPoint` / `rotatedStatusBarCenters` unchanged API, new center math
  - No `silhouette(for:)` / `points(for:)` yet removed in this task (Task 2)

- [ ] **Step 1: Rewrite status-bar / layout / spin tests for the local grid**

Replace `testStatusBarOccupiesRightColumnAndLayoutSeparatesIdentityFromStatus` and update `testWorkingSpinRotatesStatusBarAroundItsCenter` in `PingIslandTests/ClosedNotchDotIconTests.swift` so they match the local 2×4 canvas. Also change `testEveryMascotKindHasNonEmptyDistinctSilhouette` into a temporary no-op delete in Task 2 — for this task, leave silhouette tests untouched so Task 1 stays focused.

Replace the status-bar layout test with:

```swift
    func testStatusBarFillsLocalTwoByFourCanvas() {
        XCTAssertEqual(ClosedNotchDotGlyph.canvasColumns, 2)
        XCTAssertEqual(ClosedNotchDotGlyph.canvasRows, 4)

        let bar = ClosedNotchDotGlyph.statusBarPoints
        XCTAssertEqual(bar.count, 8)
        XCTAssertEqual(Set(bar.map(\.x)), Set([0, 1]))
        XCTAssertEqual(Set(bar.map(\.y)), Set([0, 1, 2, 3]))
    }
```

Replace the spin-center assertions with:

```swift
    func testWorkingSpinRotatesStatusBarAroundItsCenter() {
        let center = ClosedNotchDotGlyph.statusBarCenter
        XCTAssertEqual(center.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(center.y, 1.5, accuracy: 0.001)

        let upright = ClosedNotchDotGlyph.rotatedStatusBarCenters(angleRadians: 0)
        XCTAssertEqual(upright.count, ClosedNotchDotGlyph.statusBarPoints.count)

        // Corner (1, 0) around (0.5, 1.5) by 180° → (0, 3)
        let flipped = ClosedNotchDotGlyph.rotatedPoint(
            ClosedNotchDotPoint(1, 0),
            angleRadians: .pi,
            around: center
        )
        XCTAssertEqual(flipped.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(flipped.y, 3.0, accuracy: 0.001)

        let quarter = ClosedNotchDotGlyph.rotatedStatusBarCenters(angleRadians: .pi / 2)
        XCTAssertNotEqual(
            Set(upright.map { String(format: "%.2f,%.2f", $0.x, $0.y) }),
            Set(quarter.map { String(format: "%.2f,%.2f", $0.x, $0.y) })
        )
    }
```

Keep `testToneMapsIdleToOrangeWorkingToGreenWarningToRed` and `testStatusMotionUsesSpinForWorkingAndBlinkForWarning` unchanged.

- [ ] **Step 2: Run tests — expect fail**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchDotIconTests
```

Expected: FAIL — status bar still on cols 8–9 / center `(8.5, 1.5)` / `canvasColumns == 10`.

- [ ] **Step 3: Remap glyph geometry**

In `PingIsland/Models/ClosedNotchDotIconModel.swift`, update `ClosedNotchDotGlyph` header comment and geometry to:

```swift
/// Status-bar pixel grid for the closed docked notch (identity is `MascotView`).
enum ClosedNotchDotGlyph {
    static let canvasColumns = 2
    static let canvasRows = 4

    /// Geometric center of the status bar (pivot for working spin).
    static var statusBarCenter: (x: CGFloat, y: CGFloat) {
        (x: 0.5, y: 1.5)
    }

    /// Full 2×4 status column.
    static let statusBarPoints: [ClosedNotchDotPoint] = [
        ClosedNotchDotPoint(0, 0), ClosedNotchDotPoint(1, 0),
        ClosedNotchDotPoint(0, 1), ClosedNotchDotPoint(1, 1),
        ClosedNotchDotPoint(0, 2), ClosedNotchDotPoint(1, 2),
        ClosedNotchDotPoint(0, 3), ClosedNotchDotPoint(1, 3),
    ]

    // keep rotatedPoint + rotatedStatusBarCenters unchanged
    // keep silhouette(for:) + points(for:) temporarily for Task 2 cleanup
}
```

Leave `silhouette` / `points(for:)` in place until Task 2 so the still-present silhouette tests compile.

- [ ] **Step 4: Run tests — expect pass for geometry / tone / motion**

Run the same `ClosedNotchDotIconTests` command.

Expected: PASS for tone, motion, new status-bar, and spin tests. Silhouette tests still pass if unchanged.

---

### Task 2: Remove silhouette API and dependent tests

**Files:**
- Modify: `PingIslandTests/ClosedNotchDotIconTests.swift`
- Modify: `PingIslandTests/ZCodeHookInstallerTests.swift`
- Modify: `PingIsland/Models/ClosedNotchDotIconModel.swift`

**Interfaces:**
- Consumes: Task 1 local grid
- Produces: `ClosedNotchDotGlyph` with **no** `silhouette(for:)` or `points(for:)`

- [ ] **Step 1: Delete silhouette tests first**

In `PingIslandTests/ClosedNotchDotIconTests.swift`, delete entire `testEveryMascotKindHasNonEmptyDistinctSilhouette`.

In `PingIslandTests/ZCodeHookInstallerTests.swift`, inside the ZCode mascot assertion block, delete only:

```swift
        let silhouette = ClosedNotchDotGlyph.silhouette(for: .zcode)
        XCTAssertFalse(silhouette.isEmpty)
        XCTAssertNotEqual(silhouette, ClosedNotchDotGlyph.silhouette(for: .claude))
        XCTAssertNotEqual(silhouette, ClosedNotchDotGlyph.silhouette(for: .pi))
```

Keep brand / `MascotKind.zcode` / subtitle assertions.

- [ ] **Step 2: Run tests — expect fail only if view still calls silhouette after Step 3; for now compile may still succeed**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchDotIconTests -only-testing:PingIslandTests/ZCodeHookInstallerTests
```

Expected: PASS (silhouette helpers still exist; tests no longer call them).

- [ ] **Step 3: Delete silhouette implementation**

In `PingIsland/Models/ClosedNotchDotIconModel.swift`, remove:

- `static func silhouette(for kind: MascotKind) -> Set<ClosedNotchDotPoint>`
- `private static func points(for kind: MascotKind) -> [(Int, Int)]` and the entire `switch kind { ... }` body

- [ ] **Step 4: Confirm production compile fails on old view (expected)**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: FAIL — `ClosedNotchDotIcon.swift` still references `ClosedNotchDotGlyph.silhouette(for:)`.

(If you prefer not to leave the tree red between tasks, jump immediately into Task 3 after deleting the API.)

---

### Task 3: Compose mini pet + status Canvas in `ClosedNotchDotIcon`

**Files:**
- Modify: `PingIsland/UI/Components/ClosedNotchDotIcon.swift`
- Modify: `PingIsland/UI/Views/NotchView.swift` (comment only)

**Interfaces:**
- Consumes:
  - `MascotView(kind:status:size:)`
  - `ClosedNotchDotGlyph` local 2×4 helpers from Task 1
  - `ClosedNotchDotTone` / `ClosedNotchDotStatusMotion`
- Produces: same public struct API
  - `ClosedNotchDotIcon(kind:status:size:)` unchanged

- [ ] **Step 1: Replace the view body**

Rewrite `PingIsland/UI/Components/ClosedNotchDotIcon.swift` to:

```swift
import SwiftUI

/// Docked closed-notch icon: miniaturized settings pet + pixel status bar.
struct ClosedNotchDotIcon: View {
    let kind: MascotKind
    let status: MascotStatus
    var size: CGFloat = 16

    @ObservedObject private var energyGovernor = EnergyGovernor.shared

    private var tone: ClosedNotchDotTone {
        ClosedNotchDotTone.from(status: status)
    }

    private var motion: ClosedNotchDotStatusMotion {
        ClosedNotchDotStatusMotion.from(status: status)
    }

    private var petSize: CGFloat {
        max(8, size * 0.72)
    }

    private var statusWidth: CGFloat {
        max(3, size - petSize - 1)
    }

    var body: some View {
        HStack(spacing: 1) {
            MascotView(kind: kind, status: .idle, size: petSize)
                .frame(width: petSize, height: petSize)

            if shouldAnimate {
                TimelineView(.periodic(from: .now, by: animationInterval)) { context in
                    statusCanvas(at: context.date)
                }
            } else {
                statusCanvas(at: nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("\(kind.title), \(status.displayName)"))
    }

    private var shouldAnimate: Bool {
        guard energyGovernor.policy.animationLevel != .staticFrames else { return false }
        switch motion {
        case .spin, .blink:
            return true
        case .staticBar:
            return false
        }
    }

    private var animationInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            return 1.0 / 12.0
        case .reduced:
            return 1.0 / 5.0
        case .staticFrames:
            return 1.0 / 12.0
        }
    }

    private func statusCanvas(at date: Date?) -> some View {
        let color = tone.color
        let columns = ClosedNotchDotGlyph.canvasColumns
        let rows = ClosedNotchDotGlyph.canvasRows
        let gapFraction: CGFloat = 0.18
        let spinAngle = spinAngleRadians(at: date)
        let blink = blinkOpacity(at: date)

        return Canvas { context, canvasSize in
            let cell = min(canvasSize.width / CGFloat(columns), canvasSize.height / CGFloat(rows))
            let drawnWidth = cell * CGFloat(columns)
            let drawnHeight = cell * CGFloat(rows)
            let originX = (canvasSize.width - drawnWidth) / 2
            let originY = (canvasSize.height - drawnHeight) / 2
            let dot = max(1, cell * (1 - gapFraction))
            let inset = (cell - dot) / 2

            func fillGrid(_ point: ClosedNotchDotPoint, opacity: Double) {
                let rect = CGRect(
                    x: originX + CGFloat(point.x) * cell + inset,
                    y: originY + CGFloat(point.y) * cell + inset,
                    width: dot,
                    height: dot
                )
                context.fill(Path(rect), with: .color(color.opacity(opacity)))
            }

            func fillLogical(x: CGFloat, y: CGFloat, opacity: Double) {
                let rect = CGRect(
                    x: originX + x * cell + inset,
                    y: originY + y * cell + inset,
                    width: dot,
                    height: dot
                )
                context.fill(Path(rect), with: .color(color.opacity(opacity)))
            }

            switch motion {
            case .staticBar:
                for point in ClosedNotchDotGlyph.statusBarPoints {
                    fillGrid(point, opacity: 0.55)
                }
            case .spin:
                for center in ClosedNotchDotGlyph.rotatedStatusBarCenters(angleRadians: spinAngle) {
                    fillLogical(x: center.x, y: center.y, opacity: 1.0)
                }
            case .blink:
                for point in ClosedNotchDotGlyph.statusBarPoints {
                    fillGrid(point, opacity: blink)
                }
            }
        }
        .frame(width: statusWidth, height: size)
    }

    private func spinAngleRadians(at date: Date?) -> Double {
        guard let date else { return 0 }
        let period: TimeInterval = energyGovernor.policy.animationLevel == .reduced ? 1.6 : 1.0
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return progress * 2 * .pi
    }

    private func blinkOpacity(at date: Date?) -> Double {
        guard let date else { return 0.95 }
        let period: TimeInterval = energyGovernor.policy.animationLevel == .reduced ? 1.6 : 0.9
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return 0.45 + 0.55 * (0.5 + 0.5 * sin(progress * 2 * .pi))
    }
}
```

- [ ] **Step 2: Update the NotchView call-site comment**

In `PingIsland/UI/Views/NotchView.swift`, change the comment above `closedLeadingPetIcon` / docked branch from silhouette wording to:

```swift
    /// Docked closed notch uses mini settings pet + status bar; other surfaces keep MascotView.
```

Keep the `if viewModel.presentationMode == .docked { ClosedNotchDotIcon(...) } else { MascotView(...) }` branch as-is.

- [ ] **Step 3: Build + unit tests**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchDotIconTests -only-testing:PingIslandTests/ZCodeHookInstallerTests
```

Expected: BUILD SUCCEEDED; both test suites PASS.

- [ ] **Step 4: Manual visual check (debug app)**

Run `./scripts/run-debug.sh` (or equivalent). Verify docked closed:

1. Claude vs Codex vs Gemini pets are recognizable at ~16pt.
2. Settings pet override changes the closed leading pet.
3. Working → green spinning bar; warning → blinking red; pet stays idle-looking.
4. Detached compact / opened header still show full `MascotView`.

---

### Task 4: Docs and wording cleanup

**Files:**
- Modify: `AGENTS.md`
- Modify: `PingIsland/Models/ClosedNotchMascotCarousel.swift` (file / method comments)
- Modify: `docs/superpowers/specs/2026-07-26-closed-notch-pet-identity-design.md`

**Interfaces:** none (docs only)

- [ ] **Step 1: Update AGENTS.md routing lines**

Change:

```markdown
- Docked closed-notch pixel status icon (agent silhouette + status bar): ...
- Closed-notch multi-agent silhouette rotation: ...
```

To:

```markdown
- Docked closed-notch status icon (miniaturized settings pet + pixel status bar): `PingIsland/Models/ClosedNotchDotIconModel.swift`, `PingIsland/UI/Components/ClosedNotchDotIcon.swift` (wired from `NotchView` closed header only; detached / opened still use full `MascotView`)
- Closed-notch multi-agent pet rotation: `PingIsland/Models/ClosedNotchMascotCarousel.swift` cycles prompt-attention and active sessions every 2s in docked closed and detached compact pets so concurrent working agents remain visible without widening the island
```

In the ZCode bullet, change `closed-notch Z silhouette plus mascot draw` to `dedicated MascotKind.zcode plus mascot draw`, and keep tracing through `ClientProfile`, `MascotView`, `ClosedNotchDotIconModel`, and mascot settings.

- [ ] **Step 2: Soften carousel comments**

In `PingIsland/Models/ClosedNotchMascotCarousel.swift`:

- File comment: `Rotates the closed-notch pet identity across live agents...`
- Status helper comment: `Per-session status for the currently shown pet.`

- [ ] **Step 3: Mark spec approved**

In `docs/superpowers/specs/2026-07-26-closed-notch-pet-identity-design.md`, set:

```markdown
Status: approved
```

- [ ] **Step 4: Final verification**

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchDotIconTests -only-testing:PingIslandTests/ZCodeHookInstallerTests
rg "silhouette\\(for:" PingIsland PingIslandTests
```

Expected: tests PASS; `rg` finds no remaining `silhouette(for:` call sites.

---

## Plan Self-Review

1. **Spec coverage:** Mini pet + idle left / status bar right → Task 3; geometry remap → Task 1; silhouette removal + ZCode/test cleanup → Task 2; AGENTS / comments → Task 4; NotchView API unchanged → Task 3 comment-only. Out-of-scope items (detached, toggles, widening) are constrained and not tasked.
2. **Placeholders:** None; concrete code and commands included.
3. **Type consistency:** `ClosedNotchDotGlyph.canvasColumns/Rows`, `statusBarCenter (0.5, 1.5)`, `statusBarPoints` 2×4, `ClosedNotchDotIcon(kind:status:size:)` public API unchanged across tasks.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-26-closed-notch-pet-identity.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks  
2. **Inline Execution** — execute tasks in this session with checkpoints  

Which approach?
