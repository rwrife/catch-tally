# Catch Tally — PLAN

## Scope

Offline, iPhone-only recreational fishing catch log. Core loop: define species → run
sessions → quick-tally catches one-handed → expand entries (length, keep/release, photo,
notes) at leisure → browse personal bests and spot history → own the data via backup/export.

Explicitly out of scope (see README non-goals): regulation databases, licenses, sales,
social features, cloud sync, fish-ID AI, weather, navigation, Android, native iPad.

## Architecture

```
┌─────────────────────────────────────────────┐
│ CatchTally app (SwiftUI, iPhone-only)        │
│  Views: QuickTally · SessionWorkbench ·      │
│         PBBoard · SpotHistory · Settings     │
│  TallyWorkspaceLayout  ← single dual-screen  │
│                            migration seam    │
├─────────────────────────────────────────────┤
│ CatchTallyKit (pure Swift package, no UI)    │
│  Domain: Species, Session, CatchEntry, Spot, │
│          PersonalBest derivation, kept-count │
│          vs user-limit-note evaluation         │
│  Store: GRDB SQLite w/ migrations            │
│  IO: JSON/ZIP backup, CSV export             │
└─────────────────────────────────────────────┘
```

- **Pure-domain package.** All tally math, PB derivation, kept-count logic, and backup
  schemas are pure Swift (deterministic, Linux-testable). The app target is thin.
- **Deterministic derivations.** Personal bests and per-spot totals are *derived views*
  over the entry table, recomputed on read or via materialized queries — never stored as
  independent truth that can drift.
- **Unknowns stay unknown.** Length absent ⇒ not eligible for PB, visibly "no length
  recorded". Limit note absent ⇒ kept-count shows plain count, no reminder state. No
  silent defaults.

## Technology choices

| Choice | Rationale |
|---|---|
| SwiftUI + Swift 6, iOS 26 SDK | Required primary platform; strict concurrency; current pinned toolchain |
| GRDB (SQLite) | Robust local relational store, migrations, deterministic queries for derivation views |
| Swift Package `CatchTallyKit` | Linux CI can run the entire domain/store test suite without Xcode |
| Zero-network by construction | Privacy core value; CI greps for network API usage against an empty allowlist |
| No iPad (`TARGETED_DEVICE_FAMILY = 1`) | User directive 2026-09-15; simplifies signing & submission |

## Milestones & dependency order

1. **M0 Skeleton** (issue #1): Xcode project + package, iPhone-only enforcement, CI matrix,
   zero-network gate, toolchain pin respected.
2. **M1 Domain core** (issue #2): entities, migrations, tally arithmetic, unit tests.
3. **M2 Quick Tally slice** (issue #3): one-handed tally UI wired to real store.
4. **M3 Session workbench** (issue #4): entry expansion, length/keep-release/photos,
   accessible forms; compact/spanned layouts behind `TallyWorkspaceLayout`.
5. **M4 Derived views** (issue #5): PB board, spot history, kept-count vs limit notes.
6. **M5 Data ownership** (issue #6): backup/restore, CSV export, privacy surfaces.
7. **M6 Release** (issue #7): signing, TestFlight upload via ASC API secrets, release gates.

## Testing strategy

- **Linux CI (host-runnable):** full `CatchTallyKit` swift-testing suite — tally counters,
  undo/batch semantics, PB derivation with missing lengths, kept-count evaluation, store
  migrations (fresh + upgrade), backup round-trip, CSV golden files.
- **macOS CI:** build + iPhone-only enforcement (`UIDeviceFamily == [1]` on built app),
  XCUITest launch/one tally flow smoke, zero-network gate, exact toolchain measurement.
- **No fabrication rule:** no claim of device/TestFlight results unless a real Apple run
  produced them; gaps disclosed.

## Packaging / distribution

- TestFlight builds from tagged main via Actions using `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_P8`, `ASC_TEAM_ID` (names only). Bundle `com.infinityball.catchtally` (registered).
- App Store submission after TestFlight validation; iPhone-only, free, privacy labels:
  data collected = none.

## Risks

| Risk | Mitigation |
|---|---|
| Dual-screen SDK never/late ships | Folded-mode is full product today; migration seam isolates all layout routing |
| Regulation-note misread as advice | Hard UI copy: user's own note, verbatim, labeled; no regulatory content shipped |
| Wet-glove mistaps corrupting data | Undo on every mutation, batch confirm on long-press, −1 never below zero |
| Photo storage bloat | App-private copies, JPEG downscale policy, storage meter in settings |
| Scope creep toward social/weather | Non-goals list is contractual for issue acceptance |

## Explicit non-goals

Same as README non-goals; additionally: no Apple Watch app, no Siri shortcuts, no
multi-device sync, no coordinate-based maps, no export to third-party services.
