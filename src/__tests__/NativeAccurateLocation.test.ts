/**
 * JS-layer tests: native module selection vs fallback.
 * Native code (Kotlin/ObjC++) is not tested here — only the TS wrapper behavior.
 */

const mockGet = jest.fn();

jest.mock('react-native', () => ({
  Platform: { OS: 'ios' },
  TurboModuleRegistry: { get: mockGet },
}));

describe('NativeAccurateLocation', () => {
  beforeEach(() => {
    jest.resetModules();
    mockGet.mockReset();
  });

  it('rejects with the fallback message when the native module is unavailable', async () => {
    mockGet.mockReturnValue(null);
    const mod = require('../NativeAccurateLocation').default;

    await expect(mod.getCurrentLocation()).rejects.toThrow(
      /Native module is not available/,
    );
  });

  it('forwards the call to the native module when available', async () => {
    const fakeResult = {
      latitude: 1,
      longitude: 2,
      accuracy: 5,
      time: 123,
      provider: 'fused',
      isMocked: false,
    };
    const native = {
      getCurrentLocation: jest.fn().mockResolvedValue(fakeResult),
    };
    mockGet.mockReturnValue(native);

    const mod = require('../NativeAccurateLocation').default;
    const opts = { desiredAccuracyMeters: 8 };
    await expect(mod.getCurrentLocation(opts)).resolves.toBe(fakeResult);
    expect(native.getCurrentLocation).toHaveBeenCalledWith(opts);
  });
});
