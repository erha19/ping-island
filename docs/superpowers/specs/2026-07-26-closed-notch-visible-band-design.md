# Closed Notch Visible Band Layout

Date: 2026-07-26  
Branch: `feature/notch-visual-polish`  
Status: approved for planning

## Goal

On physical-notch MacBooks in docked **closed detailed** mode, improve the below-camera content band so the pet / title / badge row has a little breathing room under it, without recentering that row in the visible band.

## Current behavior

`ClosedNotchPhysicalLayout` sizes the closed island as:

- camera clearance = device notch height + `cameraLipPadding` (6pt)
- content row = `textBandHeight` (16pt)
- preferred closed height = clearance + text band

`NotchView.closedPhysicalNotchStackedHeader` places a clear top band for the camera, then an `HStack` of pet / title / badge, then a bottom `Spacer` for rounding slack. With height ≈ clearance + 16, there is effectively no visible padding under the content row.

## Desired behavior

1. **Camera clearance unchanged** — still full system notch inset + lip so center text clears the camera housing.
2. **Below-camera visible band taller by +6pt** — `visibleBandHeight = textBandHeight + 6` (= 22pt).
3. **Content row stays 16pt** — pet, session title, and trailing badge remain on one 16pt-tall row.
4. **Vertical alignment inside the visible band: top** — the 16pt row pins to the top of the 22pt band; the extra 6pt sits below as breathing room (not vertically centered).
5. **Preferred closed height** = camera clearance + visible band height.

## Non-goals

- No change to compact / icon-only closed layouts.
- No change to non-physical-notch (menu-bar) closed layout.
- No change to opened-state header layout or expand/collapse animation.
- No change to fullscreen physical-notch compact hide behavior.
- No redesign of side widths, carousel timing, or badge contents beyond what height constants imply.

## Design

### Layout constants (`ClosedNotchPhysicalLayout`)

| Constant | Value | Role |
|---|---|---|
| `textBandHeight` | 16 | Content row height (pet / title / badge) |
| `visibleBandBottomPadding` | 6 | Extra space under the content row |
| `visibleBandHeight` | 22 | `textBandHeight + visibleBandBottomPadding` |
| `cameraLipPadding` | 6 | Unchanged |
| `cameraClearanceHeight(deviceNotchHeight:)` | notch + lip | Unchanged |
| `preferredClosedHeight(deviceNotchHeight:)` | clearance + `visibleBandHeight` | Island closed height |

Keep naming explicit: do not overload `textBandHeight` to mean the full visible band.

### View structure (`NotchView`)

In `closedPhysicalNotchStackedHeader`:

```
VStack(alignment: .top, spacing: 0)
  Color.clear                    // height: cameraClearance
  VStack/ZStack (top-aligned)    // height: visibleBandHeight
    HStack pet | title | badge   // height: textBandHeight
    Spacer(minLength: 0)         // absorbs the +6pt (and any rounding slack)
```

Outer frame height remains `closedNotchSize.height`. Side-width helpers that currently key off `physicalTopBandHeight` stay as-is unless tests show imbalance after the height bump.

### State / ownership

- Layout math stays in `ClosedNotchPhysicalLayout` (pure, testable).
- `NotchViewModel.resolvedClosedHeight()` already calls `preferredClosedHeight`; no new settings or feature flags.
- UI wiring stays in `NotchView` physical stacked header only.

### Tests

Update / extend `ClosedNotchPhysicalLayoutTests`:

- clearance still = notch + lip
- preferred height = clearance + 22 (visible band), not clearance + 16
- visible band = text band + 6

If `NotchViewModelTests` asserts closed height for physical detailed mode against the old formula, update those expectations to the new preferred height.

### Docs

- Short note in `AGENTS.md` under the physical-notch closed detailed bullet: content row is top-aligned in a below-camera visible band with bottom padding.

## Success criteria

- On a physical-notch Mac in closed detailed mode, pet / title / badge sit just under the camera lip (top of the visible band), with a small empty strip under that row.
- Island is 6pt taller than today for the same device notch height.
- Compact, icon-only, menu-bar, opened, and fullscreen-compact paths are unchanged.
- Unit tests for layout math pass.

## Out of scope follow-ups

- Further tuning of `cameraLipPadding` or side widths after visual QA on device.
- Vertical centering of the content row (explicitly rejected in favor of top alignment).
