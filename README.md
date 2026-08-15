# react-native-accurate-location

[![npm version](https://img.shields.io/npm/v/react-native-accurate-location.svg)](https://www.npmjs.com/package/react-native-accurate-location)
[![license](https://img.shields.io/npm/l/react-native-accurate-location.svg)](./LICENSE)

Fast, tunable high-accuracy **one-shot** geolocation for iOS and Android. It takes a
**fresh** fix and resolves the instant that fix meets your accuracy threshold — and if
the threshold is never reached, it returns the **best fix seen so far** instead of just
failing. Built-in mock-location detection.

> Requires React Native **New Architecture** (TurboModules). After installing you
> must rebuild the native app — this cannot be delivered via OTA / Expo Go.

> **v2.0.0 is a breaking change.** `desiredAccuracyMeters` was removed and
> `acceptableAccuracyMeters` is now the *resolve threshold* (the request returns as
> soon as a fresh fix is at least this accurate). See [Migration](#migrating-from-1x).

## Installation

```sh
pnpm add react-native-accurate-location
# or
npm install react-native-accurate-location
# or
yarn add react-native-accurate-location
```

### iOS

```sh
cd ios && pod install
```

Add a location usage description to `ios/<App>/Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>We need your location to check you in accurately.</string>
```

### Android

Requires `ACCESS_FINE_LOCATION`. Add to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
```

Then rebuild:

```sh
npx react-native run-android
```

## Usage

```ts
import AccurateLocation from 'react-native-accurate-location';

const location = await AccurateLocation.getCurrentLocation({
  acceptableAccuracyMeters: 15, // resolve as soon as a fresh fix is ≤ 15 m
  timeoutMs: 15000,
});

console.log(location.latitude, location.longitude, location.accuracy);
```

### API

`getCurrentLocation(options?): Promise<AccurateLocationResult>`

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `acceptableAccuracyMeters` | `number` | `15` | The speed/accuracy knob. Resolves the moment a **fresh** fix is at least this accurate — no waiting for a tighter one. Raise it (e.g. `30`) for faster, coarser results. |
| `timeoutMs` | `number` | `15000` | Safety timeout. If the threshold is never met, the **best fix seen so far** is returned when this elapses (only rejects if *no* fix arrived). |
| `maxCacheAgeMs` | `number` | `0` | If `> 0`, a cached fix younger than this **and** already within `acceptableAccuracyMeters` is returned instantly. `0` = always take a fresh fix — important when moving, so you never get a stale position. |

Result: `{ latitude, longitude, accuracy, altitude?, bearing?, speed?, time, provider, isMocked }`.
Behavior and defaults are identical on iOS & Android.

> **Pick `acceptableAccuracyMeters` above what the environment can actually deliver.**
> The real accuracy floor is set by the hardware + surroundings (e.g. an older phone
> indoors may floor at ~35 m). Asking for a tighter value than the floor just makes the
> request wait until timeout. No library — free or paid — can beat that floor; only
> moving to open sky does.

`cancel(): void`

Cancels the in-flight `getCurrentLocation` request. The pending promise rejects with code
`LOCATION_CANCELLED`. Safe to call even when no request is active.

`warmup(durationMs?: number): void` / `stopWarmup(): void`

Pre-warms the GPS so the **first** `getCurrentLocation` resolves fast, avoiding the
cold-start delay. Call `warmup()` when you know a read is coming soon (e.g. when the
screen opens); it keeps the GPS active for `durationMs` (default `30000`) then stops
itself. Requires location permission to have any effect. Example:

```ts
useEffect(() => {
  AccurateLocation.warmup(30000);      // start warming on screen open
  return () => AccurateLocation.stopWarmup();
}, []);
// ...later, the user taps a button:
const loc = await AccurateLocation.getCurrentLocation({ acceptableAccuracyMeters: 15 });
```

`requestPermission(): Promise<PermissionStatus>`

Requests location permission from the system. `PermissionStatus` = `'granted' | 'denied' | 'blocked' | 'unavailable'`.

- iOS: triggers the prompt when status is `notDetermined`; `denied`/`restricted` map to `'blocked'`.
- Android: `'granted'`/`'denied'`. Pure native **cannot** distinguish a plain `denied` from
  "don't ask again" (blocked) — if you need that, use `PermissionsAndroid` in JS.
- `'unavailable'` is returned when there is no Activity (Android) or the native module is not installed.

### Permission behavior

`getCurrentLocation` does **not** request permission automatically on Android — make sure it is
already granted (via `requestPermission()` or `PermissionsAndroid`) before calling it, otherwise it
rejects with `LOCATION_PERMISSION_DENIED`. On iOS, when the status is `notDetermined`,
`getCurrentLocation` shows the permission prompt first and then continues automatically.

### Error codes

| Code | When it happens |
| --- | --- |
| `LOCATION_PERMISSION_DENIED` | Location permission not granted. |
| `LOCATION_SERVICES_DISABLED` | Device Location Services / GPS are turned off. |
| `LOCATION_TIMEOUT` | Timeout elapsed and **no** fix arrived at all. If any fix arrived, the request resolves with the best one instead of rejecting. |
| `LOCATION_CANCELLED` | Cancelled via `cancel()`. |
| `LOCATION_REQUEST_FAILED` (Android) | Fused provider failed & hardware GPS unavailable. |
| `LOCATION_ERROR` (iOS) | Non-transient CoreLocation error. |
| `LOCATION_FETCH_IN_PROGRESS` (iOS) | A request is already running (iOS processes one at a time). |

### Offline behavior

The module reads GPS satellites directly, so it **does not need internet/cellular signal** to be
accurate. What is lost offline is Assisted-GPS, so the *first fix* from a cold start can be slower
(tens of seconds). By default (`maxCacheAgeMs: 0`) a fresh fix is always taken, so the position
never "sticks" at an old point — important while moving. On Android the fused provider and the raw
GPS provider run in parallel, so a fix is still produced if Play Services is unavailable.

> `isMocked` is only reliable on **iOS 15+** and **Android 12 (S)+**. On older versions iOS always
> returns `false`; Android falls back to the deprecated `isFromMockProvider` API.

## Comparison with other libraries

Compared with commonly used React Native geolocation libraries. The points below
are a reference based on each library's general feature set and may vary between
versions — check each library's docs before deciding.

This table is scoped to **one-shot `getCurrentLocation`** (single fix), where this
library focuses. `expo-location` behavior below is verified against its
[iOS source](https://github.com/expo/expo/blob/main/packages/expo-location/ios/Providers/LocationRequester.swift);
the other columns reflect each library's general feature set and may change between
versions — check their docs before deciding.

| Feature (one-shot) | **accurate-location** | `@react-native-community/geolocation` | `react-native-geolocation-service` | `expo-location` |
| --- | --- | --- | --- | --- |
| Architecture | TurboModule (New Arch) | Legacy bridge | Legacy bridge | Expo module |
| Resolve strategy | **Fresh, on accuracy threshold** | First fix in timeout | First fix in timeout | **First fix, no filter** |
| Tunable accuracy threshold | ✅ `acceptableAccuracyMeters` | ❌ | ❌ | ❌ (`accuracy` is only a hint) |
| Returns **best fix** on timeout | ✅ | ❌ (rejects) | ❌ (rejects) | ❌ |
| Fresh-first / anti stale-cache | ✅ (default) | ⚠️ `maximumAge` may return stale | ⚠️ `maximumAge` | ⚠️ |
| Dual provider (fused + raw GPS) | ✅ (Android) | ❌ | ⚠️ | ❌ |
| Mock detection (`isMocked`) | ✅ | ❌ | ✅ (Android) | ⚠️ limited |
| Requires Expo | ❌ | ❌ | ❌ | ✅ |
| Watch / streaming | ❌ | ✅ | ✅ | ✅ |
| Background / geofencing | ❌ | ❌ | ⚠️ limited | ✅ |
| Maturity (battle-tested) | ⚠️ new | ✅✅✅ | ✅✅ | ✅✅✅ |

> **Note on accuracy:** "best" here means the smartest *speed/accuracy trade-off*, not
> more accurate coordinates. The physical accuracy floor is identical across every
> library — it is set by the device GPS chip and surroundings, not the SDK.

### Pros

- **Tunable one-shot**: resolve the instant a fresh fix meets your threshold — a knob
  neither `expo-location` nor `@react-native-community/geolocation` expose.
- **Best-on-timeout**: returns the best fix instead of failing when the threshold
  isn't reached (most libraries reject).
- **Fresh-first**: never returns a stale cached position by default — correct while moving.
- **Dual provider on Android** (fused + raw GPS) for offline / flaky Play Services.
- **Built-in `isMocked`** for check-in / anti-fraud.
- **TurboModule (New Architecture)**, type-safe via codegen. No Expo required.

### Cons

- **Requires New Architecture** and a native rebuild — no OTA / Expo Go.
- **One-shot only**: no `watchPosition` streaming, background, or geofencing.
- **Newer / smaller ecosystem** than the mainstream libraries — less battle-tested.

Use this when you need **one location read, fast and as accurate as the device allows**
(e.g. attendance / check-in). For continuous or background tracking, use
`react-native-geolocation-service`, `expo-location`, or `react-native-background-geolocation`.

## Migrating from 1.x

`getCurrentLocation` options changed:

| 1.x | 2.0 |
| --- | --- |
| `desiredAccuracyMeters` | **removed** — there is no separate "ideal" target anymore |
| `acceptableAccuracyMeters` (timeout floor) | now the **resolve threshold**: the request returns as soon as a fresh fix is at least this accurate |
| — | `maxCacheAgeMs` (new, default `0` = always fresh) |
| `timeoutMs` | unchanged, but on timeout it now **resolves with the best fix** rather than rejecting |

```diff
- await AccurateLocation.getCurrentLocation({ desiredAccuracyMeters: 8, acceptableAccuracyMeters: 15 });
+ await AccurateLocation.getCurrentLocation({ acceptableAccuracyMeters: 15 });
```

## License

MIT
