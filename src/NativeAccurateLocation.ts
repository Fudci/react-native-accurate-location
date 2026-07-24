import type { TurboModule } from 'react-native';
import { Platform, TurboModuleRegistry } from 'react-native';

export type AccurateLocationOptions = {
  desiredAccuracyMeters?: number;
  acceptableAccuracyMeters?: number;
  timeoutMs?: number;
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
