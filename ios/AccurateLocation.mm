#import "AccurateLocation.h"
#import <React/RCTLog.h>

#ifdef RCT_NEW_ARCH_ENABLED
#import "AccurateLocationSpec/AccurateLocationSpec.h"
#import "AccurateLocationSpecJSI.h"
#endif

@interface AccurateLocation ()
@property (nonatomic, strong) CLLocationManager *locationManager;
@property (nonatomic, copy) RCTPromiseResolveBlock resolveBlock;
@property (nonatomic, copy) RCTPromiseRejectBlock rejectBlock;
@property (nonatomic, assign) BOOL isFetching;
@property (nonatomic, strong, nullable) CLLocation *bestLocation;
@property (nonatomic, assign) double currentDesiredAccuracy;
@property (nonatomic, assign) double currentAcceptableAccuracy;
// Stabilisasi: sample <= acceptable sebelumnya + hitungan beruntun konsisten.
@property (nonatomic, strong, nullable) CLLocation *lastAcceptable;
@property (nonatomic, assign) NSInteger stableCount;
// Plateau: token untuk membatalkan timer plateau lama saat akurasi masih membaik.
@property (nonatomic, assign) NSInteger plateauToken;
@property (nonatomic, assign) BOOL plateauArmed;
@end

// Stabilisasi: butuh N sample beruntun yang konsisten (jarak antar-sample kecil).
static const NSInteger kRequiredStableSamples = 2;
static const CLLocationDistance kMaxJumpMeters = 5.0;
// Plateau: kalau akurasi tak membaik >kImproveEps selama kPlateauMs -> resolve terbaik.
static const double kPlateauMs = 2000.0;
static const CLLocationAccuracy kImproveEps = 1.0;
// Cache instan hanya bila SANGAT baru (< 1 detik) dan sudah akurat.
static const NSTimeInterval kInstantCacheMaxAge = 1.0;
// Sample lebih tua dari ini diabaikan, supaya offline tidak mengembalikan posisi lama.
static const NSTimeInterval kMaxSampleAge = 10.0;

@implementation AccurateLocation

RCT_EXPORT_MODULE(AccurateLocation)

- (instancetype)init {
    if (self = [super init]) {
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _isFetching = NO;
    }
    return self;
}

// ─── Core Logic ─────────────────────────────────────────────────────────────

- (void)fetchLocationWithAccuracy:(double)desiredAccuracyMeters
                       acceptable:(double)acceptableAccuracyMeters
                          timeout:(double)timeoutMs
                          resolve:(RCTPromiseResolveBlock)resolve
                           reject:(RCTPromiseRejectBlock)reject {
    if (self.isFetching) {
        reject(@"LOCATION_FETCH_IN_PROGRESS", @"A location fetch is already in progress.", nil);
        return;
    }

    self.resolveBlock = resolve;
    self.rejectBlock = reject;
    self.isFetching = YES;
    self.bestLocation = nil;
    self.lastAcceptable = nil;
    self.stableCount = 0;
    self.plateauToken = 0;
    self.plateauArmed = NO;
    self.currentAcceptableAccuracy = acceptableAccuracyMeters;

    // Set desired accuracy level for CLLocationManager
    if (desiredAccuracyMeters <= 5.0) {
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    } else if (desiredAccuracyMeters <= 10.0) {
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest;
    } else if (desiredAccuracyMeters <= 100.0) {
        self.locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
    } else {
        self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
    }

    // Check authorization
    CLAuthorizationStatus status;
    if (@available(iOS 14.0, *)) {
        status = self.locationManager.authorizationStatus;
    } else {
        status = [CLLocationManager authorizationStatus];
    }

    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) {
        self.isFetching = NO;
        reject(@"LOCATION_PERMISSION_DENIED", @"Location permission denied", nil);
        return;
    }

    // Fail-fast bila location services (GPS) mati. Panggil di background queue
    // untuk menghindari peringatan "may cause UI unresponsiveness".
    __block BOOL servicesEnabled = YES;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        servicesEnabled = [CLLocationManager locationServicesEnabled];
    });
    if (!servicesEnabled) {
        self.isFetching = NO;
        reject(@"LOCATION_SERVICES_DISABLED", @"Location services (GPS) are turned off", nil);
        return;
    }

    // Fast path: use cache if fresh (< 1 second) and already meets target
    CLLocation *lastLoc = self.locationManager.location;
    if (lastLoc) {
        NSTimeInterval age = -[lastLoc.timestamp timeIntervalSinceNow];
        // Cache instan hanya bila sangat baru & sudah memenuhi target ideal,
        // supaya cache kasar/lama tidak mengorbankan akurasi.
        if (age < kInstantCacheMaxAge && lastLoc.horizontalAccuracy > 0 && lastLoc.horizontalAccuracy <= desiredAccuracyMeters) {
            [self finishWithLocation:lastLoc];
            return;
        }
    }

    // Set timeout to return best available if target not reached
    self.currentDesiredAccuracy = desiredAccuracyMeters;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (self.isFetching) {
            if (self.bestLocation && self.bestLocation.horizontalAccuracy > 0) {
                [self finishWithLocation:self.bestLocation];
            } else {
                [self finishWithError:@"LOCATION_TIMEOUT" message:@"Location request timed out"];
            }
        }
    });

    // Start continuous updates (polls every update from GPS until target is met)
    [self.locationManager startUpdatingLocation];
}

// ─── RCT_EXPORT_METHOD (Old Arch bridge fallback) ────────────────────────────

#ifndef RCT_NEW_ARCH_ENABLED
RCT_EXPORT_METHOD(getCurrentLocation:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    double desiredAccuracyMeters = options[@"desiredAccuracyMeters"] ? [options[@"desiredAccuracyMeters"] doubleValue] : 7.0;
    double acceptableAccuracyMeters = options[@"acceptableAccuracyMeters"] ? [options[@"acceptableAccuracyMeters"] doubleValue] : desiredAccuracyMeters;
    double timeoutMs = options[@"timeoutMs"] ? [options[@"timeoutMs"] doubleValue] : 10000.0;
    [self fetchLocationWithAccuracy:desiredAccuracyMeters acceptable:acceptableAccuracyMeters timeout:timeoutMs resolve:resolve reject:reject];
}
#endif

// ─── CLLocationManagerDelegate ───────────────────────────────────────────────

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = [locations lastObject];
    if (!location) return;

    if (location.horizontalAccuracy <= 0) return;

    // Buang sample basi: CoreLocation bisa mengirim fix cache lama sebagai update
    // pertama. Saat OFFLINE ini yang bikin posisi "nyangkut" di lokasi lama.
    NSTimeInterval sampleAge = -[location.timestamp timeIntervalSinceNow];
    if (sampleAge > kMaxSampleAge) return;

    CLLocation *prevBest = self.bestLocation;
    BOOL improved = !prevBest || location.horizontalAccuracy < prevBest.horizontalAccuracy - kImproveEps;
    if (!prevBest || location.horizontalAccuracy < prevBest.horizontalAccuracy) {
        self.bestLocation = location;
    }
    CLLocation *best = self.bestLocation;
    if (!best) return;

    // Konvergensi (anti-lompat): hitung sample beruntun yang dekat satu sama lain.
    if (location.horizontalAccuracy <= self.currentAcceptableAccuracy) {
        CLLocation *prev = self.lastAcceptable;
        if (prev && [prev distanceFromLocation:location] <= kMaxJumpMeters) {
            self.stableCount += 1;
        } else {
            self.stableCount = 1;
        }
        self.lastAcceptable = location;
    }

    // Belum settle -> jangan resolve dulu (hindari titik jitter).
    if (self.stableCount < kRequiredStableSamples) return;

    // Sudah mencapai target ideal -> selesai (pakai lokasi terbaik).
    if (best.horizontalAccuracy <= self.currentDesiredAccuracy) {
        [self finishWithLocation:best];
        return;
    }

    // Sudah settle & cukup baik: kejar akurasi lebih rapat, tapi kalau tidak membaik
    // selama kPlateauMs -> resolve lokasi TERBAIK (bukan yang terakhir).
    if (best.horizontalAccuracy <= self.currentAcceptableAccuracy) {
        if (!self.plateauArmed || improved) {
            self.plateauArmed = YES;
            self.plateauToken += 1;
            NSInteger token = self.plateauToken;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPlateauMs * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                if (self.isFetching && token == self.plateauToken) {
                    [self finishWithLocation:self.bestLocation];
                }
            });
        }
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    // kCLErrorLocationUnknown is transient, keep waiting
    if (error.code == kCLErrorLocationUnknown) return;
    [self finishWithError:@"LOCATION_ERROR" message:error.localizedDescription];
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

- (void)finishWithLocation:(CLLocation *)location {
    if (!self.isFetching) return;
    self.isFetching = NO;
    [self.locationManager stopUpdatingLocation];
    self.bestLocation = nil;

    if (self.resolveBlock) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"latitude"]  = @(location.coordinate.latitude);
        result[@"longitude"] = @(location.coordinate.longitude);
        result[@"accuracy"]  = @(location.horizontalAccuracy);
        result[@"altitude"]  = @(location.altitude);
        result[@"time"]      = @([location.timestamp timeIntervalSince1970] * 1000.0);
        result[@"provider"]  = @"core-location";

        if (location.course >= 0) result[@"bearing"] = @(location.course);
        if (location.speed  >= 0) result[@"speed"]   = @(location.speed);

        BOOL isMocked = NO;
        if (@available(iOS 15.0, *)) {
            isMocked = location.sourceInformation.isSimulatedBySoftware;
        }
        result[@"isMocked"] = @(isMocked);

        self.resolveBlock(result);
        self.resolveBlock = nil;
        self.rejectBlock  = nil;
    }
}

- (void)finishWithError:(NSString *)code message:(NSString *)message {
    if (!self.isFetching) return;
    self.isFetching = NO;
    [self.locationManager stopUpdatingLocation];
    self.bestLocation = nil;

    if (self.rejectBlock) {
        self.rejectBlock(code, message, nil);
        self.resolveBlock = nil;
        self.rejectBlock  = nil;
    }
}

// ─── New Architecture TurboModule ────────────────────────────────────────────

#ifdef RCT_NEW_ARCH_ENABLED
- (void)getCurrentLocation:(JS::NativeAccurateLocation::AccurateLocationOptions &)options
                   resolve:(RCTPromiseResolveBlock)resolve
                    reject:(RCTPromiseRejectBlock)reject {
    double desiredAccuracyMeters = options.desiredAccuracyMeters().has_value() ? options.desiredAccuracyMeters().value() : 7.0;
    double acceptableAccuracyMeters = options.acceptableAccuracyMeters().has_value() ? options.acceptableAccuracyMeters().value() : desiredAccuracyMeters;
    double timeoutMs = options.timeoutMs().has_value() ? options.timeoutMs().value() : 10000.0;
    [self fetchLocationWithAccuracy:desiredAccuracyMeters acceptable:acceptableAccuracyMeters timeout:timeoutMs resolve:resolve reject:reject];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
    return std::make_shared<facebook::react::NativeAccurateLocationSpecJSI>(params);
}
#endif

@end
