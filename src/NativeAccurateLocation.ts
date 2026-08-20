import type { TurboModule } from 'react-native';
import { Platform, TurboModuleRegistry } from 'react-native';

export type AccurateLocationOptions = {
  /**
   * Resolve as soon as a FRESH fix is at least this accurate (meters). Default 15.
   * This is the speed/accuracy knob: the request returns the moment a new fix meets
   * it — no waiting for a tighter one. Raise it (e.g. 30) for faster, coarser results.
   */
  acceptableAccuracyMeters?: number;
  /**
   * Safety timeout (ms). If the accuracy target is never met, the best fix seen so
   * far is returned when this elapses. Default 15000.
   *
   * Passing this makes it a hard ceiling: the cold-start extension in `adaptiveTimeout` only
   * applies when you leave the timeout at its default, so a value you wrote is never stretched
   * behind your back. See also `allowStaleFallback`, which decides whether hitting the deadline
   * with nothing fresh in hand fails or returns the last known position.
   */
  timeoutMs?: number;
  /**
   * If > 0, a cached fix younger than this (ms) AND already within
   * `acceptableAccuracyMeters` is returned instantly. Default 0 (always take a fresh
   * fix) — important when moving, so you never get a stale position.
   */
  maxCacheAgeMs?: number;
  /**
   * Reject any fix older than this (ms) instead of returning it. Default 3000.
   *
   * A fix carries the accuracy it had at the moment it was taken, so an old one keeps claiming a
   * tight accuracy for a place the device has already left — the usual cause of a position that
   * is precise yet tens of metres wrong. Set to 0 to accept fixes of any age.
   */
  maxFixAgeMs?: number;
  /**
   * Do not resolve before this many ms have passed, unless the fix is already better than 5 m.
   * Default 4000.
   *
   * GNSS converges over time and its earliest fixes are its worst, so returning immediately is
   * what makes a one-shot read lose to a maps app that has simply been listening for longer.
   * Lower it for speed, raise it for accuracy.
   */
  minSettleMs?: number;
  /**
   * Return the median position of recent comparable fixes rather than a single sample.
   * Default true.
   *
   * Multipath scatters fixes around the true position instead of dragging them off it, so the
   * median lands closer than any individual fix.
   */
  smoothing?: boolean;
  /**
   * Extend the timeout to 45s when no fix has arrived after 10s.
   *
   * Defaults to true only when `timeoutMs` is left at its default — an explicit `timeoutMs` is
   * honoured exactly unless you also pass this as true. Offline there is no A-GPS, so the
   * ephemeris must be decoded from the satellites themselves and the first fix can take 30-60s;
   * without this, a 15s deadline expires before the chip has had any chance to speak. It only
   * ever extends the deadline, never shortens it.
   */
  adaptiveTimeout?: boolean;
  /**
   * When the deadline passes with no fresh fix at all, resolve with the last known position at
   * any age instead of rejecting. Default true.
   *
   * This is what keeps a fully offline, cold device from failing outright: a coarse or outdated
   * position beats none. Check `ageMs` on the result to see what you got — a large value means
   * it is this fallback. Set to false if a wrong position is worse than an error for your use
   * case (geofencing, attendance).
   */
  allowStaleFallback?: boolean;
};

export type AccurateLocationResult = {
  latitude: number;
  longitude: number;
  accuracy: number;
  altitude?: number;
  bearing?: number;
  speed?: number;
  time: number;
  /**
   * Age of the fix in ms when it was returned.
   *
   * Normally a few hundred ms. A large value means this came from `allowStaleFallback` — the
   * last known position, returned because no fresh fix could be obtained in time.
   */
  ageMs?: number;
  provider: string;
  isMocked: boolean;
};

export type PermissionStatus = 'granted' | 'denied' | 'blocked' | 'unavailable';

export interface Spec extends TurboModule {
  getCurrentLocation(
    options?: AccurateLocationOptions,
  ): Promise<AccurateLocationResult>;
  /** Cancel the in-flight location request. Safe to call when no request is active. */
  cancel(): void;
  /**
   * Pre-warm the GPS so the next `getCurrentLocation` resolves fast (avoids the cold-start
   * delay). Call it when you know a location read is coming soon — e.g. when the screen
   * opens. It stops automatically as soon as a `getCurrentLocation` finishes (success or
   * timeout), or after `durationMs` (default 30000) if no read happens — whichever comes
   * first, so the GPS is never left running longer than needed. Safe to call repeatedly.
   */
  warmup(durationMs?: number): void;
  /** Stop a warmup started with `warmup()`. Safe to call when not warming up. */
  stopWarmup(): void;
  /** Request location permission from the system. Resolves with the final status. */
  requestPermission(): Promise<PermissionStatus>;
}

const nativeModule = TurboModuleRegistry.get<Spec>('AccurateLocation');

const fallback = {
  getCurrentLocation: async () => {
    throw new Error(
      `[AccurateLocation] Native module is not available on platform ${Platform.OS}. Make sure you have rebuilt the native app.`,
    );
  },
  cancel: () => {},
  warmup: () => {},
  stopWarmup: () => {},
  requestPermission: async (): Promise<PermissionStatus> => 'unavailable',
  addListener: () => {},
  removeListeners: () => {},
} as unknown as Spec;

export default (nativeModule ?? fallback) as Spec;
