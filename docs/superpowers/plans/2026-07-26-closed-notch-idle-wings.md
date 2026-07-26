# Closed Notch Idle Wings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On physical-notch MacBooks in docked closed detailed mode, when there is no closed center summary text, shrink to system-notch height and show left/right ear wings; when summary text is present, keep the stacked below-camera layout.

**Architecture:** Wing/stacked math lives in `ClosedNotchPhysicalLayout`. `NotchViewModel` owns a `physicalClosedContentMode` (`.wings` / `.stacked`) that drives `closedHeight` and `closedWidth`. `NotchView` syncs that mode from center-summary presence and renders either the existing stacked header or a new wing header.

**Tech Stack:** Swift / SwiftUI, XCTest (`PingIslandTests`)

**Spec:** `docs/superpowers/specs/2026-07-26-closed-notch-idle-wings-design.md`

## Global Constraints

- Trigger: no displayable closed center summary (`closedNotchCenterText` nil/empty) → wings; otherwise stacked.
- Wings height = `ceil(deviceNotchRect.height)` (system notch).
- Wings width = `deviceNotchWidth + leftWing + rightWing` (not Settings module width).
- Default mode for detailed + physical = `.wings` (cold start with no summary).
- Stacked path keeps current `preferredClosedHeight` + Settings `notchModuleWidth`.
- Do not change compact / icon-only / non-physical-notch / opened / fullscreen-compact hide paths.
- Commits: only when the user explicitly asks; skip commit steps during execution unless requested.

---

## File Structure

| File | Role |
|---|---|
| `PingIsland/Models/ClosedNotchPhysicalLayout.swift` | Add wing constants + width helpers; keep stacked height math. |
| `PingIsland/Core/NotchViewModel.swift` | Add `PhysicalClosedContentMode`; resolve height/width from mode. |
| `PingIsland/UI/Views/NotchView.swift` | Sync mode from center text; add wing header branch. |
| `PingIslandTests/ClosedNotchPhysicalLayoutTests.swift` | Wing width unit tests. |
| `PingIslandTests/NotchViewModelTests.swift` | Wings vs stacked closed size tests; update existing detailed test to set stacked. |
| `AGENTS.md` | One-line note for idle wings vs stacked. |
| `docs/superpowers/specs/2026-07-26-closed-notch-idle-wings-design.md` | Mark status approved. |

No new Xcode target membership files (existing sources only).

---

### Task 1: Wing layout math (TDD)

**Files:**
- Modify: `PingIslandTests/ClosedNotchPhysicalLayoutTests.swift`
- Modify: `PingIsland/Models/ClosedNotchPhysicalLayout.swift`

**Interfaces:**
- Consumes: existing stacked helpers unchanged
- Produces:
  - `ClosedNotchPhysicalLayout.wingSideWidth: CGFloat == 28`
  - `ClosedNotchPhysicalLayout.wingUsageTrailingMinWidth: CGFloat == 34`
  - `ClosedNotchPhysicalLayout.wingTrailingWidth(hasExpandedUsage: Bool) -> CGFloat`
  - `ClosedNotchPhysicalLayout.preferredWingClosedWidth(deviceNotchWidth:leftWingWidth:rightWingWidth:) -> CGFloat`
  - `ClosedNotchPhysicalLayout.preferredWingClosedWidth(deviceNotchWidth:hasExpandedUsage:) -> CGFloat` convenience using `wingSideWidth` + `wingTrailingWidth`

- [ ] **Step 1: Add failing wing tests**

Append to `PingIslandTests/ClosedNotchPhysicalLayoutTests.swift`:

```swift
    func testWingSideWidthConstant() {
        XCTAssertEqual(ClosedNotchPhysicalLayout.wingSideWidth, 28)
        XCTAssertEqual(ClosedNotchPhysicalLayout.wingUsageTrailingMinWidth, 34)
    }

    func testWingTrailingWidthUsesUsageFloor() {
        XCTAssertEqual(
            ClosedNotchPhysicalLayout.wingTrailingWidth(hasExpandedUsage: false),
            ClosedNotchPhysicalLayout.wingSideWidth
        )
        XCTAssertEqual(
            ClosedNotchPhysicalLayout.wingTrailingWidth(hasExpandedUsage: true),
            ClosedNotchPhysicalLayout.wingUsageTrailingMinWidth
        )
    }

    func testPreferredWingClosedWidthAddsBothWings() {
        let width = ClosedNotchPhysicalLayout.preferredWingClosedWidth(
            deviceNotchWidth: 220,
            hasExpandedUsage: false
        )
        XCTAssertEqual(width, 220 + 28 + 28)

        let usageWidth = ClosedNotchPhysicalLayout.preferredWingClosedWidth(
            deviceNotchWidth: 220,
            hasExpandedUsage: true
        )
        XCTAssertEqual(usageWidth, 220 + 28 + 34)
    }
```

- [ ] **Step 2: Run tests — expect fail**

Run:

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchPhysicalLayoutTests
```

Expected: FAIL — `wingSideWidth` / helpers missing.

- [ ] **Step 3: Implement wing helpers**

Add to `PingIsland/Models/ClosedNotchPhysicalLayout.swift` (keep existing stacked API):

```swift
    /// Side cap width for idle ear-wing closed mode (pet / compact badge).
    static let wingSideWidth: CGFloat = 28

    /// Minimum trailing wing width when closed usage remainder is shown.
    static let wingUsageTrailingMinWidth: CGFloat = 34

    static func wingTrailingWidth(hasExpandedUsage: Bool) -> CGFloat {
        hasExpandedUsage ? max(wingSideWidth, wingUsageTrailingMinWidth) : wingSideWidth
    }

    static func preferredWingClosedWidth(
        deviceNotchWidth: CGFloat,
        leftWingWidth: CGFloat,
        rightWingWidth: CGFloat
    ) -> CGFloat {
        max(0, deviceNotchWidth) + leftWingWidth + rightWingWidth
    }

    static func preferredWingClosedWidth(
        deviceNotchWidth: CGFloat,
        hasExpandedUsage: Bool
    ) -> CGFloat {
        preferredWingClosedWidth(
            deviceNotchWidth: deviceNotchWidth,
            leftWingWidth: wingSideWidth,
            rightWingWidth: wingTrailingWidth(hasExpandedUsage: hasExpandedUsage)
        )
    }
```

Also extend the file comment to mention idle wings mode briefly.

- [ ] **Step 4: Re-run tests — expect pass**

Same `xcodebuild` command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit** — skip unless user asks.

---

### Task 2: ViewModel wings vs stacked sizing (TDD)

**Files:**
- Modify: `PingIsland/Core/NotchViewModel.swift`
- Modify: `PingIslandTests/NotchViewModelTests.swift`

**Interfaces:**
- Consumes: `ClosedNotchPhysicalLayout.preferredClosedHeight`, `preferredWingClosedWidth(deviceNotchWidth:hasExpandedUsage:)`
- Produces:
  - `enum PhysicalClosedContentMode { case wings, stacked }` (nested in `NotchViewModel` or file-level next to it)
  - `@Published private(set) var physicalClosedContentMode: PhysicalClosedContentMode` default `.wings`
  - `func setPhysicalClosedContentMode(_ mode: PhysicalClosedContentMode, hasExpandedUsage: Bool = false)`
  - `resolvedClosedHeight()` / `resolvedClosedWidth()` honor mode when `hasPhysicalNotch && detailed`
  - Setting mode refreshes `closedWidth` via existing `syncClosedWidth`

- [ ] **Step 1: Update existing detailed test to set stacked; add wings tests (fail first)**

In `testDetailedPhysicalNotchClosedHeightGrowsForBelowCameraTitle`, after creating the viewModel, add:

```swift
viewModel.setPhysicalClosedContentMode(.stacked)
```

before the assertions (stacked still expects module width + preferred stacked height).

Add new tests:

```swift
    func testDetailedPhysicalNotchDefaultsToWingClosedSize() async {
        await MainActor.run {
            let viewModel = NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in false },
                notchModuleWidthProvider: { 180 },
                notchDisplayModeProvider: { .detailed }
            )

            let expectedWidth = ClosedNotchPhysicalLayout.preferredWingClosedWidth(
                deviceNotchWidth: 220,
                hasExpandedUsage: false
            )
            XCTAssertEqual(viewModel.physicalClosedContentMode, .wings)
            XCTAssertEqual(viewModel.closedHeight, 38)
            XCTAssertEqual(viewModel.closedWidth, expectedWidth)
            XCTAssertEqual(viewModel.closedSize, CGSize(width: expectedWidth, height: 38))
        }
    }

    func testDetailedPhysicalNotchWingModeHonorsExpandedUsageTrailing() async {
        await MainActor.run {
            let viewModel = NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in false },
                notchModuleWidthProvider: { 180 },
                notchDisplayModeProvider: { .detailed }
            )

            viewModel.setPhysicalClosedContentMode(.wings, hasExpandedUsage: true)

            let expectedWidth = ClosedNotchPhysicalLayout.preferredWingClosedWidth(
                deviceNotchWidth: 220,
                hasExpandedUsage: true
            )
            XCTAssertEqual(viewModel.closedWidth, expectedWidth)
            XCTAssertEqual(viewModel.closedHeight, 38)
        }
    }

    func testSwitchingPhysicalClosedContentModeUpdatesClosedSize() async {
        await MainActor.run {
            let preferredModuleWidth: CGFloat = 180
            let viewModel = NotchViewModel(
                deviceNotchRect: CGRect(x: 0, y: 0, width: 220, height: 38),
                screenRect: CGRect(x: 0, y: 0, width: 1512, height: 982),
                windowHeight: 320,
                hasPhysicalNotch: true,
                enableEventMonitoring: false,
                observeSystemEnvironment: false,
                fullscreenActivityProvider: { _ in false },
                notchModuleWidthProvider: { preferredModuleWidth },
                notchDisplayModeProvider: { .detailed }
            )

            viewModel.setPhysicalClosedContentMode(.stacked)
            let stackedHeight = ClosedNotchPhysicalLayout.preferredClosedHeight(deviceNotchHeight: 38)
            XCTAssertEqual(viewModel.closedWidth, preferredModuleWidth)
            XCTAssertEqual(viewModel.closedHeight, stackedHeight)

            viewModel.setPhysicalClosedContentMode(.wings, hasExpandedUsage: false)
            let wingWidth = ClosedNotchPhysicalLayout.preferredWingClosedWidth(
                deviceNotchWidth: 220,
                hasExpandedUsage: false
            )
            XCTAssertEqual(viewModel.closedWidth, wingWidth)
            XCTAssertEqual(viewModel.closedHeight, 38)
        }
    }
```

- [ ] **Step 2: Run ViewModel tests — expect fail**

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/NotchViewModelTests
```

Expected: FAIL — `setPhysicalClosedContentMode` / `physicalClosedContentMode` missing; and/or detailed default still stacked height.

- [ ] **Step 3: Implement ViewModel mode**

Near the top of `NotchViewModel` (or just above the class):

```swift
enum PhysicalClosedContentMode: Equatable {
    case wings
    case stacked
}
```

Add property:

```swift
@Published private(set) var physicalClosedContentMode: PhysicalClosedContentMode = .wings
private var physicalClosedHasExpandedUsage = false
```

Replace `resolvedClosedHeight()`:

```swift
private func resolvedClosedHeight() -> CGFloat {
    let base = detectedClosedHeight
    guard hasPhysicalNotch,
          notchDisplayModeProvider() == .detailed else {
        return base
    }
    switch physicalClosedContentMode {
    case .wings:
        return base
    case .stacked:
        return ClosedNotchPhysicalLayout.preferredClosedHeight(deviceNotchHeight: base)
    }
}
```

Replace `resolvedClosedWidth(preferredModuleWidthOverride:)`:

```swift
private func resolvedClosedWidth(preferredModuleWidthOverride: CGFloat? = nil) -> CGFloat {
    if hasPhysicalNotch,
       notchDisplayModeProvider() == .detailed,
       physicalClosedContentMode == .wings {
        return ClosedNotchPhysicalLayout.preferredWingClosedWidth(
            deviceNotchWidth: ceil(deviceNotchRect.width),
            hasExpandedUsage: physicalClosedHasExpandedUsage
        )
    }
    return preferredModuleWidthOverride ?? preferredModuleWidth
}
```

Add:

```swift
func setPhysicalClosedContentMode(
    _ mode: PhysicalClosedContentMode,
    hasExpandedUsage: Bool = false
) {
    let usageChanged = physicalClosedHasExpandedUsage != hasExpandedUsage
    let modeChanged = physicalClosedContentMode != mode
    physicalClosedHasExpandedUsage = hasExpandedUsage
    if modeChanged {
        physicalClosedContentMode = mode
    }
    guard modeChanged || usageChanged else { return }
    syncClosedWidth(animated: false)
}
```

Ensure `closedSize` / `closedHeight` re-read `resolvedClosedHeight()` after mode changes (they already compute from mode; SwiftUI will refresh when `physicalClosedContentMode` / `closedWidth` publish). If any caller caches height independently, also bump a published dependency — `physicalClosedContentMode` `@Published` is enough for views observing the ViewModel.

- [ ] **Step 4: Re-run ViewModel tests — expect pass**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit** — skip unless user asks.

---

### Task 3: NotchView wing header + mode sync

**Files:**
- Modify: `PingIsland/UI/Views/NotchView.swift`

**Interfaces:**
- Consumes: `viewModel.setPhysicalClosedContentMode`, `physicalClosedContentMode`, `ClosedNotchPhysicalLayout.wingSideWidth`, `wingTrailingWidth`, `deviceNotchRect`
- Produces: wing header UI; mode stays in sync with center summary presence

- [ ] **Step 1: Add helpers for mode sync and wing layout flags**

Near `usesPhysicalNotchStackedLayout`, replace/extend with:

```swift
private var hasClosedCenterSummary: Bool {
    guard let message = closedCenterMessage else { return false }
    return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private var usesPhysicalNotchStackedLayout: Bool {
    viewModel.status != .opened
        && viewModel.hasPhysicalNotch
        && settings.notchDisplayMode == .detailed
        && !usesClosedIconOnlyLayout
        && hasClosedCenterSummary
}

private var usesPhysicalNotchWingLayout: Bool {
    viewModel.status != .opened
        && viewModel.hasPhysicalNotch
        && settings.notchDisplayMode == .detailed
        && !usesClosedIconOnlyLayout
        && !hasClosedCenterSummary
}
```

- [ ] **Step 2: Sync ViewModel mode from the view**

Add a private method:

```swift
private func syncPhysicalClosedContentMode() {
    guard viewModel.hasPhysicalNotch, settings.notchDisplayMode == .detailed else { return }
    let mode: PhysicalClosedContentMode = hasClosedCenterSummary ? .stacked : .wings
    viewModel.setPhysicalClosedContentMode(
        mode,
        hasExpandedUsage: closedTrailingUsageWindow != nil
    )
}
```

Call it from an `.onAppear` / `.onChange` on the main closed notch container (same place other session-driven effects live). Prefer observing:

- `closedCenterMessage` (or session list / carousel inputs that feed it)
- `closedTrailingUsageWindow != nil`
- `settings.notchDisplayMode`

Exact wiring: attach to the root `body`/`notchLayout` with:

```swift
.onAppear { syncPhysicalClosedContentMode() }
.onChange(of: hasClosedCenterSummary) { _ in syncPhysicalClosedContentMode() }
.onChange(of: closedTrailingUsageWindow != nil) { _ in syncPhysicalClosedContentMode() }
.onChange(of: settings.notchDisplayMode) { _ in syncPhysicalClosedContentMode() }
```

If `onChange` of `Bool` from `closedTrailingUsageWindow != nil` is awkward, store `private var hasClosedTrailingUsage: Bool { closedTrailingUsageWindow != nil }` and observe that.

- [ ] **Step 3: Branch header to wing layout**

In `headerRow`, after icon-only and before/with stacked:

```swift
} else if usesPhysicalNotchStackedLayout {
    closedPhysicalNotchStackedHeader
} else if usesPhysicalNotchWingLayout {
    closedPhysicalNotchWingHeader
} else {
```

Implement:

```swift
@ViewBuilder
private var closedPhysicalNotchWingHeader: some View {
    HStack(spacing: 0) {
        if showsClosedLeadingIcon {
            closedLeadingPetIcon(size: petIconSize)
                .matchedGeometryEffect(id: "pet", in: activityNamespace, isSource: showsClosedLeadingIcon)
                .frame(width: ClosedNotchPhysicalLayout.wingSideWidth, height: closedNotchSize.height)
        }

        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: closedNotchSize.height)
            .allowsHitTesting(false)

        closedTrailingBadge
            .frame(
                width: ClosedNotchPhysicalLayout.wingTrailingWidth(
                    hasExpandedUsage: closedTrailingUsageWindow != nil
                ),
                height: closedNotchSize.height,
                alignment: .trailing
            )
    }
    .frame(width: closedInnerWidth, height: closedNotchSize.height)
}
```

Keep stacked header unchanged.

- [ ] **Step 4: Build sanity check**

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit** — skip unless user asks.

---

### Task 4: Docs + regression tests

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/superpowers/specs/2026-07-26-closed-notch-idle-wings-design.md` (status → approved)
- Re-run: layout + ViewModel tests

- [ ] **Step 1: Update AGENTS.md physical-notch bullet**

Replace the existing physical-notch closed detailed bullet with:

```markdown
  - On physical-notch MacBooks, closed detailed mode uses ear wings at system-notch height when there is no center summary (`ClosedNotchPhysicalLayout` wing width = device notch + side caps); when a center summary is present it grows downward and places pet, title, and trailing badge on one top-aligned row inside a below-camera visible band (camera clearance + `visibleBandHeight`)
```

- [ ] **Step 2: Mark spec approved**

In the design spec header, set `Status: approved`.

- [ ] **Step 3: Run focused tests**

```bash
xcodebuild -project PingIsland.xcodeproj -scheme PingIsland -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:PingIslandTests/ClosedNotchPhysicalLayoutTests -only-testing:PingIslandTests/NotchViewModelTests
```

Expected: all PASS.

- [ ] **Step 4: Manual visual check (physical-notch Mac)**

1. Closed detailed, no active summary → island height matches system notch; pet left / badge right as ears.
2. Start a session that produces center summary → island grows down; stacked row under camera.
3. Summary clears → returns to wings.
4. Compact / menu-bar / opened unchanged.

- [ ] **Step 5: Commit** — skip unless user asks.

---

## Spec coverage check

| Spec requirement | Task |
|---|---|
| Wings when no center summary | Task 2 + 3 |
| Stacked when summary present | Task 2 + 3 |
| System notch height for wings | Task 2 |
| Width = device notch + wings | Task 1 + 2 |
| Trailing usage floor ≥ 34 | Task 1 + 2 + 3 |
| Default mode wings | Task 2 |
| Resize via existing animation path | Task 2 (`syncClosedWidth`); View observes published size |
| Non-goals (compact / menu-bar / fullscreen hide / opened) | untouched |
| Tests | Task 1, 2, 4 |
| AGENTS.md | Task 4 |

## Placeholder scan

No TBD / “implement later” steps; concrete code and commands included.
