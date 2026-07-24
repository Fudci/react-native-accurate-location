# react-native-accurate-location

Native TurboModule to get high accuracy device location on iOS and Android.

> Requires React Native **New Architecture** (TurboModules). After installing you
> must rebuild the native app — this cannot be delivered via OTA / Expo Go.

## Installation

```sh
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
| `desiredAccuracyMeters` | `number` | Target accuracy; resolves early once reached. |
| `acceptableAccuracyMeters` | `number` | Minimum acceptable accuracy on timeout. |
| `timeoutMs` | `number` | Max time to wait for a fix. |

Result: `{ latitude, longitude, accuracy, altitude?, bearing?, speed?, time, provider, isMocked }`

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
