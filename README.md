# react-native-accurate-location

Native TurboModule to get high accuracy device location on iOS and Android.

> Requires React Native **New Architecture** (TurboModules). After installing you
> must rebuild the native app — this cannot be delivered via OTA / Expo Go.

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
  desiredAccuracyMeters: 5,
  acceptableAccuracyMeters: 15,
  timeoutMs: 15000,
});

console.log(location.latitude, location.longitude, location.accuracy);
```

### API

`getCurrentLocation(options?): Promise<AccurateLocationResult>`

| Option | Type | Description |
| --- | --- | --- |
| `desiredAccuracyMeters` | `number` | Target accuracy; resolves early once reached. Default `8`. |
| `acceptableAccuracyMeters` | `number` | Minimum acceptable accuracy on timeout. Default `15`. |
| `timeoutMs` | `number` | Max time to wait for a fix. Default `15000`. |

Result: `{ latitude, longitude, accuracy, altitude?, bearing?, speed?, time, provider, isMocked }`

Defaults (when an option is omitted): `desiredAccuracyMeters: 8`,
`acceptableAccuracyMeters: 15`, `timeoutMs: 15000` — identical on iOS & Android.

`cancel(): void`

Cancels the in-flight `getCurrentLocation` request. The pending promise rejects with code
`LOCATION_CANCELLED`. Safe to call even when no request is active.

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
| `LOCATION_ACCURACY_TIMEOUT` (Android) / `LOCATION_TIMEOUT` (iOS) | Timeout reached without a fix meeting the target. |
| `LOCATION_CANCELLED` | Cancelled via `cancel()`. |
| `LOCATION_REQUEST_FAILED` (Android) | Fused provider failed & hardware GPS unavailable. |
| `LOCATION_ERROR` (iOS) | Non-transient CoreLocation error. |
| `LOCATION_FETCH_IN_PROGRESS` (iOS) | A request is already running (iOS processes one at a time). |

### Offline behavior

The module reads GPS satellites directly, so it **does not need internet/cellular signal** to be
accurate. What is lost offline is Assisted-GPS, so the *first fix* from a cold start can be slower
(tens of seconds). A stale location cache is intentionally ignored beyond ~10 seconds so the offline
position does not "stick" at an old point.

> `isMocked` is only reliable on **iOS 15+** and **Android 12 (S)+**. On older versions iOS always
> returns `false`; Android falls back to the deprecated `isFromMockProvider` API.

## Comparison with other libraries

Compared with commonly used React Native geolocation libraries. The points below
are a reference based on each library's general feature set and may vary between
versions — check each library's docs before deciding.

| Feature | **accurate-location** | `@react-native-community/geolocation` | `react-native-geolocation-service` | `expo-location` |
| --- | --- | --- | --- | --- |
| Architecture | TurboModule (New Arch) | Legacy bridge | Legacy bridge | Expo module |
| High-accuracy focus (target + timeout) | ✅ built-in | ⚠️ manual via `enableHighAccuracy` | ✅ | ⚠️ via `Accuracy` enum |
| Auto-resolve once accuracy reached | ✅ | ❌ | ❌ | ❌ |
| Mock location detection (`isMocked`) | ✅ | ❌ | ✅ (Android) | ⚠️ limited |
| Requires Expo | ❌ | ❌ | ❌ | ✅ |
| Watch / location streaming | ❌ (single fix only) | ✅ | ✅ | ✅ |
| Background location | ❌ | ❌ | ⚠️ limited | ✅ |

### Pros

- **Built for high accuracy**: `desiredAccuracyMeters` +
  `acceptableAccuracyMeters` + `timeoutMs` in a single API, resolving faster as
  soon as the target accuracy is reached — no manual polling.
- **TurboModule (New Architecture)**: lower overhead and type-safe via codegen,
  without the legacy async bridge.
- **Built-in `isMocked`** to detect fake locations — useful for check-in /
  anti-fraud use cases.
- **No Expo required**: works in bare React Native projects.

### Cons

- **Requires New Architecture (TurboModules)** and a native rebuild — cannot be
  delivered via OTA / Expo Go.
- **Single fix only**: no `watchPosition` / location streaming yet.
- **No background location support** yet.
- Smaller ecosystem compared to more mature mainstream libraries.

Use this library when you need **one location read as accurate as possible**
(e.g. attendance / check-in). For continuous or background tracking,
`react-native-geolocation-service` or `expo-location` are a better fit.

## License

MIT
