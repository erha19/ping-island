# Closed Notch Visible Band Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On physical-notch MacBooks in closed detailed mode, grow the below-camera visible band by 6pt and keep the 16pt pet/title/badge row top-aligned inside that band.

**Architecture:** Keep all closed-height math in `ClosedNotchPhysicalLayout`. Add `visibleBandBottomPadding` / `visibleBandHeight`, make `preferredClosedHeight` = clearance + visible band. Update `NotchView.closedPhysicalNotchStackedHeader` so the content `HStack` sits in a top-aligned visible-band frame of that height. `NotchViewModel` already calls `preferredClosedHeight` and needs no logic change.

**Tech Stack:** Swift / SwiftUI, XCTest (`PingIslandTests`)

**Spec:** `docs/superpowers/specs/2026-07-26-closed-notch-visible-band-design.md`

## Global Constraints

- Camera clearance unchanged: `deviceNotchHeight + cameraLipPadding` (`cameraLipPadding` stays `6`).
- Content row height stays `textBandHeight == 16`.
- Visible band: `visibleBandHeight = textBandHeight + visibleBandBottomPadding` with `visibleBandBottomPadding == 6` → `22`.
- Content row vertical alignment inside the visible band: **top** (not centered).
- Do not change compact / icon-only / non-physical-notch / opened / fullscreen-compact paths.
- Do not retune side widths unless a test or obvious regression forces it.
- Commits: only when the user explicitly asks; skip commit steps during execution unless requested.

---

## File Structure

| File | Role |
|---|---|
| `PingIsland/Models/ClosedNotchPhysicalLayout.swift` | Layout constants + preferred closed height. |
| `PingIsland/UI/Views/NotchView.swift` | Physical stacked closed header: wrap content row in top-aligned visible band. |
| `PingIslandTests/ClosedNotchPhysicalLayoutTests.swift` | Unit tests for new visible-band math. |
| `PingIslandTests/NotchViewModelTests.swift` | Already asserts via `preferredClosedHeight`; re-run only (no hardcoded old height). |
| `AGENTS.md` | One-line update for below-camera visible band + top alignment. |

No new files. No Xcode project membership changes.

---

### Task 1: Visible-band layout math (TDD)

**Files:**
- Modify: `PingIslandTests/ClosedNotchPhysicalLayoutTests.swift`
- Modify: `PingIsland/Models/ClosedNotchPhysicalLayout.swift`

**Interfaces:**
- Consumes: existing `cameraClearanceHeight(deviceNotchHeight:)`, `cameraLipPadding`, `textBandHeight`
- Produces:
  - `ClosedNotchPhysicalLayout.visibleBandBottomPadding: CGFloat == 6`
  - `ClosedNotchPhysicalLayout.visibleBandHeight: CGFloat` (= `textBandHeight + visibleBandBottomPadding`)
  - `preferredClosedHeight(deviceNotchHeight:)` → `cameraClearanceHeight(...) + visibleBandHeight`

- [ ] **Step 1: Update tests to expect visible band (fail first)**

Replace the contents of `PingIslandTests/ClosedNotchPhysicalLayoutTests.swift` with:

```swift
import XCTest
@testable import Ping_Island

final class ClosedNotchPhysicalLayoutTests: XCTestCase {
    func testCameraClearanceUsesFullNotchPlusLip() {
        let clearance = ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 38)

        XCTAssertEqual(clearance, 38 + ClosedNotchPhysicalLayout.cameraLipPadding)
    }

    func testVisibleBandIsTextBandPlusBottomPadding() {
        XCTAssertEqual(ClosedNotchPhysicalLayout.textBandHeight, 16)
        XCTAssertEqual(ClosedNotchPhysicalLayout.visibleBandBottomPadding, 6)
        XCTAssertEqual(
            ClosedNotchPhysicalLayout.visibleBandHeight,
            ClosedNotchPhysicalLayout.textBandHeight
                + ClosedNotchPhysicalLayout.visibleBandBottomPadding
        )
        XCTAssertEqual(ClosedNotchPhysicalLayout.visibleBandHeight, 22)
    }

    func testPreferredClosedHeightUsesClearancePlusVisibleBand() {
        let height = ClosedNotchPhysicalLayout.preferredClosedHeight(deviceNotchHeight: 38)

        XCTAssertEqual(
            height,
            ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 38)
                + ClosedNotchPhysicalLayout.visibleBandHeight
        )
        XCTAssertEqual(height, 38 + 6 + 22)
    }

    func testCameraClearanceFallsBackWhenDeviceHeightIsMissing() {
        let clearance = ClosedNotchPhysicalLayout.cameraClearanceHeight(deviceNotchHeight: 0)

        XCTAssertEqual(clearance, 32 + ClosedNotchPhysicalLayout.cameraLipPadding)
    }
}
```

- [ ] **Step 2: Run tests — expect fail**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchPhysicalLayoutTests
```

Expected: FAIL — `visibleBandBottomPadding` / `visibleBandHeight` missing, and/or preferred height still uses `textBandHeight` only (old total `60` vs expected `66` for notch `38`).

- [ ] **Step 3: Implement layout constants**

Update `PingIsland/Models/ClosedNotchPhysicalLayout.swift` to:

```swift
import CoreGraphics

/// Layout helpers for closed detailed mode on camera-notch MacBooks.
///
/// The hardware cutout cannot show pixels, so detailed closed mode grows the
/// black island downward and places pet / title / badge on one row strictly
/// below the system notch inset (plus a small lip) so center text is not covered.
/// The below-camera visible band is slightly taller than the content row; the
/// row stays top-aligned inside that band with padding underneath.
enum ClosedNotchPhysicalLayout {
    /// Height of the content row under the camera (pet + title + badge).
    static let textBandHeight: CGFloat = 16

    /// Extra points under the content row inside the below-camera visible band.
    static let visibleBandBottomPadding: CGFloat = 6

    /// Full below-camera band: content row plus bottom breathing room.
    static var visibleBandHeight: CGFloat {
        textBandHeight + visibleBandBottomPadding
    }

    /// Extra points below the system notch inset before the content row starts.
    /// Clears the camera housing lip that still covers glyphs when the row is
    /// flush with `safeAreaTop`.
    static let cameraLipPadding: CGFloat = 6

    /// Empty band kept above the content row so center text clears the camera.
    static func cameraClearanceHeight(deviceNotchHeight: CGFloat) -> CGFloat {
        let base = deviceNotchHeight > 0 ? deviceNotchHeight : 32
        return base + cameraLipPadding
    }

    /// Closed island height: camera clearance plus the below-camera visible band.
    static func preferredClosedHeight(deviceNotchHeight: CGFloat) -> CGFloat {
        cameraClearanceHeight(deviceNotchHeight: deviceNotchHeight) + visibleBandHeight
    }
}
```

- [ ] **Step 4: Re-run layout tests — expect pass**

Run the same `xcodebuild ... ClosedNotchPhysicalLayoutTests` command as Step 2.

Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit** (only if user asked to commit)

```bash
git add PingIsland/Models/ClosedNotchPhysicalLayout.swift PingIslandTests/ClosedNotchPhysicalLayoutTests.swift
git commit -m "$(cat <<'EOF'
Add below-camera visible band height for closed detailed notch.

EOF
)"
```

---

### Task 2: Top-align content row inside visible band in NotchView

**Files:**
- Modify: `PingIsland/UI/Views/NotchView.swift` (`closedPhysicalNotchStackedHeader`, ~766–811)
- Modify: `AGENTS.md` (physical-notch closed detailed bullet)

**Interfaces:**
- Consumes: `ClosedNotchPhysicalLayout.textBandHeight`, `ClosedNotchPhysicalLayout.visibleBandHeight`, `physicalTopBandHeight`, existing pet/title/badge builders
- Produces: stacked header with camera clearance + top-aligned 16pt content row inside a 22pt visible band

- [ ] **Step 1: Restructure `closedPhysicalNotchStackedHeader`**

In `PingIsland/UI/Views/NotchView.swift`, replace `closedPhysicalNotchStackedHeader` with:

```swift
@ViewBuilder
private var closedPhysicalNotchStackedHeader: some View {
    VStack(spacing: 0) {
        // Full notch inset + lip so center text clears the camera housing.
        Color.clear
            .frame(width: closedInnerWidth, height: physicalTopBandHeight)

        // Below-camera visible band: content row top-aligned, padding underneath.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsClosedLeadingIcon {
                    closedLeadingPetIcon(size: petIconSize)
                        .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showsClosedLeadingIcon)
                        .frame(width: physicalContentSideWidth, height: ClosedNotchPhysicalLayout.textBandHeight)
                }

                Group {
                    if closedCarouselSessions.count > 1 {
                        TimelineView(.periodic(from: .now, by: ClosedNotchMascotCarousel.interval)) { context in
                            closedCenterMessageLabel(
                                closedCenterMessage(at: context.date),
                                width: physicalContentCenterWidth,
                                alignment: .center
                            )
                        }
                    } else {
                        closedCenterMessageLabel(
                            closedCenterMessage,
                            width: physicalContentCenterWidth,
                            alignment: .center
                        )
                    }
                }
                .frame(width: physicalContentCenterWidth, height: ClosedNotchPhysicalLayout.textBandHeight, alignment: .center)

                closedTrailingBadge
                    .frame(
                        width: physicalContentTrailingWidth,
                        height: ClosedNotchPhysicalLayout.textBandHeight,
                        alignment: .trailing
                    )
            }
            .frame(width: closedInnerWidth, height: ClosedNotchPhysicalLayout.textBandHeight, alignment: .top)

            Spacer(minLength: 0)
        }
        .frame(
            width: closedInnerWidth,
            height: ClosedNotchPhysicalLayout.visibleBandHeight,
            alignment: .top
        )

        // Absorb any outer rounding slack so the bands stay pinned up.
        Spacer(minLength: 0)
    }
    .frame(width: closedInnerWidth, height: closedNotchSize.height, alignment: .top)
}
```

Do not change `physicalContentSideWidth` / trailing / center width helpers in this task.

- [ ] **Step 2: Update AGENTS.md bullet**

In `AGENTS.md`, replace the physical-notch closed detailed bullet with:

```markdown
  - On physical-notch MacBooks, closed detailed mode grows the island downward and places pet, center title, and trailing badge on one top-aligned row inside a below-camera visible band (`ClosedNotchPhysicalLayout`: full system notch inset + camera lip clearance, then `visibleBandHeight` with bottom padding under the 16pt content row) so center text is not covered by the hardware cutout.
```

- [ ] **Step 3: Run layout + view-model height tests**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchPhysicalLayoutTests -only-testing:PingIslandTests/NotchViewModelTests/testDetailedPhysicalNotchClosedHeightGrowsForBelowCameraTitle
```

Expected: PASS. `testDetailedPhysicalNotchClosedHeightGrowsForBelowCameraTitle` already compares against `ClosedNotchPhysicalLayout.preferredClosedHeight(deviceNotchHeight: 38)` and should now expect `66` without code edits.

- [ ] **Step 4: Commit** (only if user asked to commit)

```bash
git add PingIsland/UI/Views/NotchView.swift AGENTS.md
git commit -m "$(cat <<'EOF'
Top-align closed notch content in a taller below-camera band.

EOF
)"
```

---

### Task 3: Verification sweep

**Files:**
- None required unless a test fails and needs a one-line expectation fix

- [ ] **Step 1: Run full PingIslandTests slice for notch layout**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchPhysicalLayoutTests -only-testing:PingIslandTests/NotchViewModelTests
```

Expected: PASS for all tests in those classes. If any test hardcodes the old closed height `60` (`38+6+16`), update that literal to `ClosedNotchPhysicalLayout.preferredClosedHeight(...)` or `66` — prefer calling the helper.

- [ ] **Step 2: Manual visual check (physical-notch Mac)**

On a camera-notch MacBook, Debug build + docked detailed closed mode:

1. Content row sits just under the camera lip (not vertically centered in the black drop).
2. Small empty strip (~6pt) is visible under pet/title/badge.
3. Island is slightly taller than before.
4. Compact / icon-only / opened / menu-bar (no physical notch) look unchanged.

- [ ] **Step 3: Final commit** (only if user asked to commit)

```bash
git add -A
git status
git commit -m "$(cat <<'EOF'
Polish physical-notch closed detailed visible band layout.

EOF
)"
```

Only stage files touched by this plan; leave unrelated dirty files alone.

---

## Spec coverage check

| Spec requirement | Task |
|---|---|
| Camera clearance unchanged | Task 1 (constants keep lip/clearance) |
| Visible band +6pt (=22) | Task 1 |
| Content row stays 16pt | Task 1 + Task 2 |
| Top alignment in visible band | Task 2 |
| `preferredClosedHeight` uses visible band | Task 1; ViewModel picks it up |
| Tests updated | Task 1 + Task 3 |
| AGENTS.md note | Task 2 |
| Non-goals (compact/opened/etc.) | Explicitly untouched |

## Self-review notes

- No placeholders.
- Names match across tasks: `visibleBandBottomPadding`, `visibleBandHeight`, `textBandHeight`.
- `NotchViewModel` needs no code change; Task 3 re-runs its existing preferred-height assertion.
