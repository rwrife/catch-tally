# Catch Tally

**Pitch:** Local-first iPhone fishing catch log: quick one-handed tallies at the rail, full dock-side entries with personal bests, spots, and user-defined limit reminders — no accounts, no cloud.

Catch Tally is an offline recreational fishing log. At the rail, one hand on the reel, you tap
a species and count fish in seconds. Back at the dock, you expand the session: measurements,
release/keep, spot, notes, and photos. Over seasons it becomes your personal scoreboard —
personal bests per species, per-spot history, and honest totals — all stored on-device and
exportable by you, on demand.

## Motivation

Existing fishing apps are social networks with a log bolted on: accounts, cloud sync, ads,
and licensed map data subscriptions. Most anglers' actual need is smaller and more private:
*remember what I caught, where, how big, and beat my own records* — without creating another
account or paying a subscription. Catching fish is wet, cold, and one-handed; logging should
survive that.

## Target users

- Recreational anglers (freshwater and saltwater) who want a private catch record.
- Families and buddies who share a spot list but not a social feed.
- Anyone tracking personal-best progress or youth "first fish" milestones.

## Concrete use cases

1. **Rail-side tally.** Boat is drifting, fish are coming: open the app, pick "Walleye",
   tap +1 three times, done in five seconds with wet hands.
2. **Dock-side detail.** After the session: add lengths to two keepers, mark the rest
   released, tag the spot, attach two photos, close the session.
3. **Personal-best check.** Spring next year: the personal-best board shows your walleye PB
   was 19" at Cedar Point; the spot history shows the pattern.
4. **Limit awareness.** You recorded your own note for the species ("5/day, min 15""): the
   session dashboard counts kept fish against *your* note, with a clear reminder that you
   must confirm actual local regulations yourself.
5. **Own your data.** End of season: export a CSV of every catch, or back up a full ZIP and
   restore it on a new phone.

## How to use (intended workflow)

1. Create your species list once (add, rename, or delete any species — nothing is pre-baked
   as truth).
2. Start a session: date defaults to now, pick or create a spot, optional method notes.
3. Tally catches as they happen (one-handed Quick Tally mode).
4. End of session: expand entries — length, release/keep, photo, notes.
5. Browse derived views: session history, personal bests, per-spot stats.
6. Export CSV or a private JSON/ZIP backup whenever you want.

## MVP feature list

- Species catalog (user-owned, user-defined; per-species optional keep-limit *note* you type yourself)
- Fishing sessions with spot (user-defined named spots), date, and freeform notes
- Quick Tally: per-species counters with +1 / long-press batch / −1 / undo, safe one-handed layout
- Catch entries: length with unit, release/keep state, optional on-device photo, notes
- Personal-best board per species (derived from entries with recorded lengths)
- Spot history: sessions and totals per spot
- Kept-count vs. your own keep-limit note shown on the session dashboard
- Local data store with migrations, private JSON/ZIP backup & restore, CSV export
- VoiceOver/Dynamic Type accessible; zero network access

## Non-goals

- **No regulation database.** No licensed regulatory content, no claims about current law.
  User notes are the user's own; the app repeats them back and never advises.
- No fishing licenses, no buy/sell, no fish-for-sale features.
- No social feed, friends, leaderboards between people, or accounts.
- No fish identification AI/OCR, no weather integration.
- No cloud sync, analytics, ads, or telemetry — the app has no network calls at all.
- No native iPad app and no Android in MVP (see Platform scope).
- No navigation/chartplotter functionality; spots are names + optional freeform description.
- No health or nutrition advice about consumption.

## iPhone Duo dual-screen value story

Catch Tally is designed around the folded/unfolded split from day one:

- **Folded (compact, one-handed):** Quick Tally surface only — big species wheel, oversized
  +1 targets, live session counters, one-thumb undo. This is the at-the-rail mode.
- **Unfolded (spanned):** the session workbench — entry list beside the detail editor, the
  personal-best board and spot history as a two-panel view, photo review at full size.

**Current build shape (SDK gap):** full dual-screen/fold SDK APIs do not exist yet, so Catch
Tally ships as a **standard iPhone app with iPad support disabled**
(`TARGETED_DEVICE_FAMILY = 1`; built `UIDeviceFamily == [1]` verified in CI where an Apple
environment is available). Folded-mode Quick Tally is fully functional on any iPhone today.

**Migration path:** all layout routing lives behind a single `TallyWorkspaceLayout` seam.
When Apple ships dual-screen APIs, compact mode maps to the front screen and the workbench to
the spanned/unfolded presentation, without touching the domain layer or data model. Dual-screen
behavior is a documented design target, **not** a claim of tested compatibility on unreleased
hardware or SDKs.

## Privacy, permissions, and data storage

- **Zero network.** No server, no accounts, no analytics; CI enforces a zero-network gate.
- Storage: app-private SQLite (GRDB) database; photos in app-private storage (copies, never
  library write-back).
- Permissions: at most `NSPhotoLibraryUsageEntry`-style *add-only/read* photo access, and only
  if/when photo attach ships; notifications are not required for MVP.
- Backup files are user-initiated, app-private by default; CSV export is previewed before sharing.
- No serial identifiers, no location permission in MVP (spots are names, not coordinates).
- Regulation-note disclaimers: your limit notes are your own text; the app is not legal advice
  and never asserts current regulations.

## iOS bundle ID & App Store Connect

- Bundle ID: `com.infinityball.catchtally` — App Store Connect registration: **CREATED** ✅
- Repository Actions secrets configured (names only): `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_P8`, `ASC_TEAM_ID`. Values are never stored in this repository.

## Current status

**M3 (session workbench) landed.** `CatchTally.xcodeproj` (SwiftUI app target, bundle id
`com.infinityball.catchtally`), `Packages/CatchTallyKit` (pure-Swift domain package),
iPhone-only + zero-network + Xcode-pin CI gates, and a privacy manifest are in place.
The Quick Tally slice and the session workbench (entry detail editing, quick filters,
app-private photo copies with VoiceOver alt text, close-with-freeze + audited date
edits, `TallyWorkspaceLayout` seam) are implemented.
No device/simulator test results, archive, or TestFlight binary exist yet — macOS CI
builds for the simulator and asserts the iPhone-only/toolchain gates; the domain
package test suite runs on Linux CI.

Milestones:
1. ✅ Repo scaffold (README, PLAN, toolchain pin, backlog)
2. ✅ Skeleton + CI (iPhone-only, iOS 26 SDK pin, zero-network gate)
3. ✅ Domain layer + Quick Tally vertical slice
4. ✅ Session detail workbench (photos, filters, frozen-date audit, layout seam)
   — personal-best board and spot history still ahead
5. ⬜ Backup/export + privacy controls
6. ⬜ TestFlight release pipeline

## Development / build quickstart

Platform: native SwiftUI, iOS 26 SDK or newer (see `toolchain.json`; current pin: Xcode
26.0.1 (17A400), iOS SDK 26.0, Swift 6). Pure domain logic lives in a Swift package that
builds and tests on Linux CI; UI builds on macOS runners. iPhone-only is enforced pre-build
(grep `TARGETED_DEVICE_FAMILY = 1`) and post-build (`UIDeviceFamily == [1]`).

```bash
swift test --package-path Packages/CatchTallyKit          # Linux or macOS
bash scripts/check_zero_network.sh                        # empty-allowlist network scan
xcodebuild -project CatchTally.xcodeproj -scheme CatchTally -sdk iphonesimulator build
```

Signing/TestFlight: releases build against the iOS 26-or-newer SDK and upload via the App
Store Connect API using the Actions secrets listed above (secret names only).
