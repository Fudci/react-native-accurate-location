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
   */
  timeoutMs?: number;
  /**
   * If > 0, a cached fix younger than this (ms) AND already within
   * `acceptableAccuracyMeters` is returned instantly. Default 0 (always take a fresh
   * fix) — important when moving, so you never get a stale position.
   */
  maxCacheAgeMs?: number;
};

export type AccurateLocationResult = {
  latitude: number;
  longitude: number;
  accuracy: number;
  altitude?: number;
  bearing?: number;
  speed?: number;
  time: number;
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
  requestPermission: async (): Promise<PermissionStatus> => 'unavailable',
  addListener: () => {},
  removeListeners: () => {},
} as unknown as Spec;

export default (nativeModule ?? fallback) as Spec;
