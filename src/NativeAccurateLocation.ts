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

export interface Spec extends TurboModule {
  getCurrentLocation(
    options?: AccurateLocationOptions,
  ): Promise<AccurateLocationResult>;
}

const nativeModule = TurboModuleRegistry.get<Spec>('AccurateLocation');

const fallback = {
  getCurrentLocation: async () => {
    throw new Error(
      `[AccurateLocation] Native module tidak tersedia di platform ${Platform.OS}. Pastikan sudah rebuild native.`,
    );
  },
  addListener: () => { },
  removeListeners: () => { },
} as unknown as Spec;

export default (nativeModule ?? fallback) as Spec;
