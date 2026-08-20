# Changelog

## 2.2.0

### Added

All new options are opt-out; existing calls keep working.

- **`maxFixAgeMs`** (default `3000`) — reject fixes older than this. A fix reports the
  accuracy it had *when it was taken*, so an old one keeps claiming a tight accuracy for
  a place the device has already left. This is the usual cause of a position that looks
  precise (±2 m) yet sits tens of metres away.
- **`minSettleMs`** (default `4000`) — don't resolve before this elapses unless the fix
  is already better than 5 m. GNSS converges over time and its earliest fixes are its
  worst.
- **`smoothing`** (default `true`) — return the median of recent comparable fixes
  instead of a single sample. Multipath scatters fixes *around* the true position, so
  the median lands closer than any individual fix.
- **`adaptiveTimeout`** — extend the deadline to 45 s when no fix at all has arrived
  after 10 s. Defaults to `true` only when `timeoutMs` is left at its default, so an
  explicit `timeoutMs` is never stretched behind your back.
- **`allowStaleFallback`** (default `true`) — when the deadline passes with no fresh fix,
  resolve with the last known position instead of rejecting. Keeps a fully offline cold
  device from failing outright.
- **`ageMs`** on the result — age of the fix when returned. A large value means it came
  from the `allowStaleFallback` path.

## 2.1.0

### Added

- **`warmup(durationMs?)` / `stopWarmup()`** — pre-warm the GPS (e.g. when a screen
  opens) so the *first* `getCurrentLocation` resolves fast instead of paying the GPS
  cold-start delay. It **stops automatically once a `getCurrentLocation` finishes**
  (success or timeout), or after `durationMs` (default 30000) if no read happens —
  whichever is first, so the GPS is never left on longer than needed.

## 2.0.1

### Fixed

- **No more waiting out the full timeout when the accuracy target is unreachable.**
  `getCurrentLocation` now resolves with the best fix as soon as accuracy stops
  improving (~2.5s plateau), instead of blocking until `timeoutMs`. This fixes the
  common indoor case (e.g. target 15 m but the room floors at ~35 m) that previously
  looked like a constant timeout even on capable phones.

## 2.0.0

### Breaking

- `getCurrentLocation` options reworked for a faster, simpler one-shot:
  - **Removed** `desiredAccuracyMeters`.
  - `acceptableAccuracyMeters` is now the **resolve threshold** — the request
    returns as soon as a fresh fix is at least this accurate (default `15`).
  - Added `maxCacheAgeMs` (default `0` = always take a fresh fix).
- On timeout the request now **resolves with the best fix seen so far** instead of
  rejecting (it only rejects with `LOCATION_TIMEOUT` when no fix arrived at all).
- The Android timeout code is now `LOCATION_TIMEOUT` (was `LOCATION_ACCURACY_TIMEOUT`).

### Changed

- **Fresh-first by default**: a stale cached position is never returned unless
  `maxCacheAgeMs > 0`, so a moving device always gets its current location.
- Dropped the stabilization + plateau wait, so fixes resolve markedly faster while
  the `accuracy` field still reports true quality.

See [Migrating from 1.x](./README.md#migrating-from-1x).

## 1.1.0

- `cancel()` and `requestPermission()` APIs, example app, tests and tooling.
