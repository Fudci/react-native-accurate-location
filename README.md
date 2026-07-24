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

## License

MIT
