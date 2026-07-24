# AccurateLocation Example

Minimal demo app to test `react-native-accurate-location` on a physical device.

The JS files (`App.tsx`, `index.js`, config) are already provided. The native folders
(`ios/`, `android/`) are **not generated yet** because native projects must be created by
the RN CLI to match your installed RN version. Generate them once with the steps below.

## 1. Generate the native project

From the repo root:

```sh
pnpm install
```

Then generate the native template into `example/` (match the RN version in `package.json`):

```sh
# from the example/ folder
npx @react-native-community/cli init AccurateLocationExample \
  --version 0.86.0 --directory . --skip-install --pm pnpm
```

Keep the `App.tsx` / `index.js` / `app.json` / `metro.config.js` / `babel.config.js` from this
repo (do not let the template overwrite them).

## 2. Configure permissions

- **iOS** — add to `example/ios/AccurateLocationExample/Info.plist`:

  ```xml
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>This app needs your location to show an accurate position.</string>
  ```

- **Android** — `ACCESS_FINE_LOCATION` is merged automatically from the library manifest.

## 3. Run (a physical device is recommended for real GPS)

```sh
pnpm --filter AccurateLocationExample start
pnpm --filter AccurateLocationExample android
pnpm --filter AccurateLocationExample ios   # run `pod install` in example/ios first
```

## What to test

- Get Location with `desired/acceptable/timeout` parameters.
- The Cancel button (aborts an in-flight request).
- Behavior when permission is denied and when GPS/Location Services are off.
- Offline test (turn off WiFi + cellular data) — a fix is still obtained from satellites, just slower.
