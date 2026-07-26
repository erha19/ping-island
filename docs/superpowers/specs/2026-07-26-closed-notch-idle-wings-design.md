# Closed Notch Idle Wings Layout

Date: 2026-07-26  
Status: approved  


## Spec self-review

- No placeholders left; wing default **28pt** is explicit and tunable in QA.
- Default ViewModel mode for detailed + physical should be **wings** (matches cold start with no summary); stacked is set when center text appears. Existing ViewModel tests that assume always-stacked detailed height must set stacked mode explicitly.
- Scope stays docked closed detailed + physical only; compact / menu-bar / fullscreen hide / opened are non-goals.

## Goal

On physical-notch MacBooks in docked **closed detailed** mode, when there is **no closed center summary text**, shrink the island back to the system notch height and show only left/right **ear wings** hugging the hardware Dynamic Island — not a below-camera stacked row.

When center summary text is present, keep today’s stacked-below-camera layout.

## Decisions (locked)

| Topic | Choice |
|---|---|
| Trigger | No displayable `closedNotchCenterText` (option 3) |
| Idle height | System notch height only (option 1) |
| Idle silhouette | Ear wings hugging the native notch (option A / visual 1) |
| Approach | Mode switch: wings when idle summary absent; stacked when present |

## Current behavior

- Detailed + physical notch → `ClosedNotchPhysicalLayout.preferredClosedHeight` grows the black island downward.
- `NotchView.closedPhysicalNotchStackedHeader` clears the camera band, then places pet / title / badge in the below-camera visible band.
- Closed width always comes from Settings `notchModuleWidth`.

## Desired behavior

### Mode A — Wings (no center summary)

1. **Height** = `ceil(deviceNotchRect.height)` (same as compact / non-detailed physical closed height).
2. **Width** = `deviceNotchRect.width + leftWingWidth + rightWingWidth` (not Settings module width).
3. **Layout** = single row at system notch height:
   - Left wing: leading pet / closed leading icon
   - Center: empty (hardware cutout / black overlap with system notch)
   - Right wing: existing `closedTrailingBadge` (attention / usage / session count)
4. Wings are modest side caps that make the black shape read as extensions of the native island, not a full-width module bar.

### Mode B — Stacked (center summary present)

Unchanged from current detailed physical layout:

- Height = `preferredClosedHeight(deviceNotchHeight:)`
- Width = Settings `notchModuleWidth`
- Header = `closedPhysicalNotchStackedHeader` (camera clearance + below-camera content row)

### Transitions

- Switching between Mode A and Mode B should use the existing closed-notch resize animation (`closedNotchResizeAnimation`).
- Opened / expand / detach paths remain unchanged aside from reading the correct closed size as the collapse baseline.

## Trigger definition

Use the same source of truth as today’s closed center label:

- `settings.notchDisplayMode == .detailed`
- AND a non-nil, non-empty closed center message from the existing carousel / representative session path (`closedNotchCenterText`)

If that message is nil or empty → Mode A (wings).  
Otherwise → Mode B (stacked).

Trailing badge presence alone does **not** force Mode B.

## Layout constants

Extend `ClosedNotchPhysicalLayout` (or an adjacent helper in the same file) with wing sizing:

- `wingSideWidth` — default fixed side cap for pet / compact badge (proposed **28pt**; tune if visual QA needs it).
- `wingTrailingWidth(hasExpandedUsage: Bool)` — at least `wingSideWidth`, and **≥ 34** when the closed trailing usage remainder is shown (matches today’s usage trailing min width).
- `preferredWingClosedWidth(deviceNotchWidth:left:right:)` → `deviceNotchWidth + left + right`.

Do not invent a second camera-clearance path for wings; content sits in the native notch vertical band.

## ViewModel sizing contract

`NotchViewModel` must expose closed size that reflects the active mode:

- Add a published / settable closed physical content mode, e.g. `physicalClosedContentMode: .wings | .stacked` (name may vary), updated from `NotchView` when the center-summary presence changes.
- `resolvedClosedHeight()`:
  - detailed + physical + **stacked** → `preferredClosedHeight`
  - detailed + physical + **wings** → detected system notch height
  - otherwise unchanged
- `resolvedClosedWidth()` / docked closed width target:
  - detailed + physical + **wings** → wing width from device notch + wing sides
  - otherwise Settings module width (including stacked detailed)

Fullscreen physical compact hide (`usesPhysicalNotchClosedPresentation`) stays as today: closed size collapses to `deviceNotchRect.size` with no Island content.

## View layout contract (`NotchView`)

Header branch order (closed, not opened):

1. `shouldHideClosedContent` → clear native footprint
2. `usesClosedIconOnlyLayout` → icon-only (unchanged)
3. **physical + detailed + stacked** → existing `closedPhysicalNotchStackedHeader`
4. **physical + detailed + wings** → new wing header: leading icon | flexible empty center sized to device notch width | trailing badge
5. else → existing non-physical / compact HStack

Keep pet `matchedGeometryEffect` id stable across wing ↔ stacked switches.

## Non-goals

- No change to compact display mode behavior.
- No change to non-physical-notch (menu-bar) closed layout.
- No dual independent floating wing windows / hollow center mask (approach C).
- No change to opened header, AICOS entry, or detached island compact pets beyond any shared size baseline already driven by ViewModel.
- No redesign of badge semantics or carousel timing.
- No requirement that Settings module width still apply while wings are active.

## Tests

- `ClosedNotchPhysicalLayout` (or helper) unit tests for wing width math and trailing usage floor.
- `NotchViewModelTests`: detailed + physical + wings → system height and wing width; detailed + physical + stacked → preferred stacked height and module width; mode flip updates size.
- Keep existing stacked visible-band height tests green.

## Docs

- Short `AGENTS.md` note under the physical-notch closed detailed bullet: idle (no center summary) uses notch-height ear wings; summary present keeps stacked below-camera band.
- This spec is the durable design record.

## Success criteria

1. No center summary on a physical-notch Mac in closed detailed → island height matches system notch; pet left / badge right as ear wings.
2. Center summary appears → island grows downward and shows the stacked below-camera row as today.
3. Compact / menu-bar / fullscreen hide / opened paths look unchanged.
4. Unit tests cover wing vs stacked sizing.
