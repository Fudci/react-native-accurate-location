# Changelog

## 2.1.0

### Added

- **`warmup(durationMs?)` / `stopWarmup()`** — pre-warm the GPS (e.g. when a screen
  opens) so the *first* `getCurrentLocation` resolves fast instead of paying the GPS
  cold-start delay. Runs for `durationMs` (default 30000) then stops itself.

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
