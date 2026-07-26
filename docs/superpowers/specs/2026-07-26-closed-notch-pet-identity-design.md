# Closed Notch Pet Identity Icon

Date: 2026-07-26  
Status: approved  


## Spec self-review

- No placeholders; left pet is always `.idle` and right bar alone carries status.
- Silhouette glyphs are removed from the render path; tone / motion / spin math stay.
- Scope is docked closed leading icon only; detached and opened keep full `MascotView`.

## Goal

Make the docked closed-notch leading icon easier to tell apart by client: use a miniaturized copy of the settings pet (`MascotView`) for identity, while keeping the existing pixel status bar for idle / working / warning.

## Decisions (locked)

| Topic | Choice |
|---|---|
| Visual | Option A — settings pet shrink + existing status bar |
| Implementation | Approach 1 — evolve `ClosedNotchDotIcon` in place |
| Left pet status | Always `.idle` (no working/warning halo on the pet) |
| Right indicator | Keep current tone colors + spin / blink / static bar |
| Call sites | `NotchView.closedLeadingPetIcon` stays docked → `ClosedNotchDotIcon` |

## Current behavior

- Docked closed: `ClosedNotchDotIcon` draws a monochrome 6×4 agent silhouette (cols 0…5) plus a 2×4 status column (cols 8…9) on a 10×4 pixel canvas.
- Detached / opened: full colorful `MascotView`.
- Kind already comes from `settings.mascotKind(for:)` (overrides + carousel).

## Desired behavior

### Composite icon (`ClosedNotchDotIcon`)

1. Outer frame remains `size × size` (default 16 from `NotchView.petIconSize`).
2. Horizontal layout: left identity + right status, small gap (~1pt).
3. **Left:** `MascotView(kind: kind, status: .idle, size: ≈ size * 0.72)`.
   - Same artwork / kind mapping as Mascot Settings.
   - Respect `mascotAnimationsEnabled` and EnergyGovernor like other small mascot embeds.
4. **Right:** pixel status bar only (tone + motion from the real `status` argument).
   - Idle / dragging → static bar  
   - Working → spin around bar center  
   - Warning → blink  
5. Accessibility label unchanged in spirit: `"\(kind.title), \(status.displayName)"`.

### Out of scope

- Detached compact pet and opened header pets (already `MascotView`).
- Redesigning status colors or motion timing.
- New settings toggles.
- Widening the closed notch solely for this icon.

## Code changes

| Area | Change |
|---|---|
| `ClosedNotchDotIcon.swift` | Compose `MascotView` + status-bar Canvas; stop drawing silhouette |
| `ClosedNotchDotIconModel.swift` | Keep tone / motion / status-bar geometry helpers; remove `silhouette` / per-kind `points(for:)` from the live path |
| `NotchView.swift` | No API change expected |
| `AGENTS.md` | Describe closed icon as mini pet + status bar (not silhouette) |
| ZCode / mascot docs notes | Drop “closed-notch Z silhouette” wording where it implies pixel identity |

## Testing

Keep:

- Tone mapping (idle orange / working green / warning red).
- Status motion mapping (spin / blink / static).
- Status-bar spin rotation math around bar center.

Remove or rewrite:

- “Every `MascotKind` has a non-empty distinct silhouette.”
- Layout tests that assume identity lives in columns 0…5 of the shared 10×4 canvas.
- ZCode tests that only assert silhouette uniqueness vs Claude/Pi.

Optional light assertion: status-bar points still occupy a right-hand 2-column strip on the status-only canvas (coordinates may be remapped to a smaller local grid; document the chosen local grid in the model if remapped).

## Verification

- Docked closed: Claude / Codex / Gemini (and a custom override) are visually distinct at 16pt.
- Working → green spinning bar; warning → blinking red bar; pet stays idle-looking.
- Detached compact and opened headers still show full animated `MascotView`.
- `xcodebuild … -only-testing:PingIslandTests/ClosedNotchDotIconTests` (and any ZCode silhouette assertions) pass.
