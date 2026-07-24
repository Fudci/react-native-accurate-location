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
// Stabilization: previous sample <= acceptable + count of consecutive consistent samples.
@property (nonatomic, strong, nullable) CLLocation *lastAcceptable;
@property (nonatomic, assign) NSInteger stableCount;
// Plateau: token to cancel a stale plateau timer while accuracy is still improving.
@property (nonatomic, assign) NSInteger plateauToken;
@property (nonatomic, assign) BOOL plateauArmed;
// notDetermined: defer starting updates until the user answers the permission prompt.
@property (nonatomic, assign) BOOL awaitingAuthToFetch;
@property (nonatomic, assign) double pendingTimeoutMs;
// requestPermission(): promise waiting for the authorization result.
@property (nonatomic, copy, nullable) RCTPromiseResolveBlock permissionResolve;
@end

// Stabilization: require N consecutive consistent samples (small inter-sample distance).
static const NSInteger kRequiredStableSamples = 2;
static const CLLocationDistance kMaxJumpMeters = 5.0;
// Plateau: if accuracy does not improve by >kImproveEps within kPlateauMs -> resolve best.
static const double kPlateauMs = 2000.0;
static const CLLocationAccuracy kImproveEps = 1.0;
// Instant cache only if VERY fresh (< 1 second) and already accurate.
static const NSTimeInterval kInstantCacheMaxAge = 1.0;
// Samples older than this are ignored, so offline does not return a stale position.
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

    self.currentDesiredAccuracy = desiredAccuracyMeters;
    self.pendingTimeoutMs = timeoutMs;

    // notDetermined: request permission first, continue in didChangeAuthorization. Without
    // this, startUpdatingLocation shows no prompt and the request hangs until timeout.
    if (status == kCLAuthorizationStatusNotDetermined) {
        self.awaitingAuthToFetch = YES;
        [self.locationManager requestWhenInUseAuthorization];
        return;
    }

    // Fail-fast if location services (GPS) are off. Call on a background queue
    // to avoid the "may cause UI unresponsiveness" warning.
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
        // Instant cache only if very fresh & already meets the ideal target,
        // so a coarse/stale cache never compromises accuracy.
        if (age < kInstantCacheMaxAge && lastLoc.horizontalAccuracy > 0 && lastLoc.horizontalAccuracy <= desiredAccuracyMeters) {
            [self finishWithLocation:lastLoc];
            return;
        }
    }

    [self beginLocationUpdates];
}

// Arm the timeout + start continuous updates. Extracted so it can be re-invoked from
// didChangeAuthorization after the user answers the permission prompt (notDetermined case).
- (void)beginLocationUpdates {
    double timeoutMs = self.pendingTimeoutMs;
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
    double desiredAccuracyMeters = options[@"desiredAccuracyMeters"] ? [options[@"desiredAccuracyMeters"] doubleValue] : 8.0;
    double acceptableAccuracyMeters = options[@"acceptableAccuracyMeters"] ? [options[@"acceptableAccuracyMeters"] doubleValue] : 15.0;
    double timeoutMs = options[@"timeoutMs"] ? [options[@"timeoutMs"] doubleValue] : 15000.0;
    [self fetchLocationWithAccuracy:desiredAccuracyMeters acceptable:acceptableAccuracyMeters timeout:timeoutMs resolve:resolve reject:reject];
}

RCT_EXPORT_METHOD(cancel) {
    [self doCancel];
}

RCT_EXPORT_METHOD(requestPermission:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self doRequestPermission:resolve reject:reject];
}
#endif

// ─── CLLocationManagerDelegate ───────────────────────────────────────────────

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = [locations lastObject];
    if (!location) return;

    if (location.horizontalAccuracy <= 0) return;

    // Drop stale samples: CoreLocation may deliver an old cached fix as the first
    // update. When OFFLINE this is what makes the position "stick" at an old location.
    NSTimeInterval sampleAge = -[location.timestamp timeIntervalSinceNow];
    if (sampleAge > kMaxSampleAge) return;

    CLLocation *prevBest = self.bestLocation;
    BOOL improved = !prevBest || location.horizontalAccuracy < prevBest.horizontalAccuracy - kImproveEps;
    if (!prevBest || location.horizontalAccuracy < prevBest.horizontalAccuracy) {
        self.bestLocation = location;
    }
    CLLocation *best = self.bestLocation;
    if (!best) return;

    // Convergence (anti-jump): count consecutive samples close to each other.
    if (location.horizontalAccuracy <= self.currentAcceptableAccuracy) {
        CLLocation *prev = self.lastAcceptable;
        if (prev && [prev distanceFromLocation:location] <= kMaxJumpMeters) {
            self.stableCount += 1;
        } else {
            self.stableCount = 1;
        }
        self.lastAcceptable = location;
    }

    // Not settled yet -> do not resolve (avoid jittery points).
    if (self.stableCount < kRequiredStableSamples) return;

    // Ideal target reached -> finish (use the best location).
    if (best.horizontalAccuracy <= self.currentDesiredAccuracy) {
        [self finishWithLocation:best];
        return;
    }

    // Settled & good enough: keep chasing tighter accuracy, but if it does not improve
    // within kPlateauMs -> resolve the BEST location (not the latest).
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

// iOS 14+
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    CLAuthorizationStatus status;
    if (@available(iOS 14.0, *)) {
        status = manager.authorizationStatus;
    } else {
        status = [CLLocationManager authorizationStatus];
    }
    [self handleAuthorizationStatus:status];
}

// iOS < 14
- (void)locationManager:(CLLocationManager *)manager
    didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    [self handleAuthorizationStatus:status];
}

- (void)handleAuthorizationStatus:(CLAuthorizationStatus)status {
    // notDetermined is still waiting for the user's answer; ignore this early callback.
    if (status == kCLAuthorizationStatusNotDetermined) return;

    BOOL authorized = (status == kCLAuthorizationStatusAuthorizedWhenInUse ||
                       status == kCLAuthorizationStatusAuthorizedAlways);

    // 1) Resolve a pending requestPermission().
    if (self.permissionResolve) {
        RCTPromiseResolveBlock resolve = self.permissionResolve;
        self.permissionResolve = nil;
        resolve(authorized ? @"granted" : @"blocked");
    }

    // 2) Continue a getCurrentLocation() that was waiting for permission (notDetermined case).
    if (self.awaitingAuthToFetch) {
        self.awaitingAuthToFetch = NO;
        if (authorized) {
            [self beginLocationUpdates];
        } else {
            [self finishWithError:@"LOCATION_PERMISSION_DENIED" message:@"Location permission denied"];
        }
    }
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
    self.awaitingAuthToFetch = NO;
    [self.locationManager stopUpdatingLocation];
    self.bestLocation = nil;

    if (self.rejectBlock) {
        self.rejectBlock(code, message, nil);
        self.resolveBlock = nil;
        self.rejectBlock  = nil;
    }
}

// ─── cancel / requestPermission (shared core) ────────────────────────────────

- (void)doCancel {
    if (self.isFetching) {
        [self finishWithError:@"LOCATION_CANCELLED" message:@"Location request was cancelled"];
    }
}

- (void)doRequestPermission:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject {
    CLAuthorizationStatus status;
    if (@available(iOS 14.0, *)) {
        status = self.locationManager.authorizationStatus;
    } else {
        status = [CLLocationManager authorizationStatus];
    }

    switch (status) {
        case kCLAuthorizationStatusAuthorizedWhenInUse:
        case kCLAuthorizationStatusAuthorizedAlways:
            resolve(@"granted");
            return;
        case kCLAuthorizationStatusDenied:
        case kCLAuthorizationStatusRestricted:
            resolve(@"blocked");
            return;
        case kCLAuthorizationStatusNotDetermined:
        default:
            // Resolved in handleAuthorizationStatus after the user answers the prompt.
            self.permissionResolve = resolve;
            [self.locationManager requestWhenInUseAuthorization];
            return;
    }
}

// ─── New Architecture TurboModule ────────────────────────────────────────────

#ifdef RCT_NEW_ARCH_ENABLED
- (void)getCurrentLocation:(JS::NativeAccurateLocation::AccurateLocationOptions &)options
                   resolve:(RCTPromiseResolveBlock)resolve
                    reject:(RCTPromiseRejectBlock)reject {
    double desiredAccuracyMeters = options.desiredAccuracyMeters().has_value() ? options.desiredAccuracyMeters().value() : 8.0;
    double acceptableAccuracyMeters = options.acceptableAccuracyMeters().has_value() ? options.acceptableAccuracyMeters().value() : 15.0;
    double timeoutMs = options.timeoutMs().has_value() ? options.timeoutMs().value() : 15000.0;
    [self fetchLocationWithAccuracy:desiredAccuracyMeters acceptable:acceptableAccuracyMeters timeout:timeoutMs resolve:resolve reject:reject];
}

- (void)cancel {
    [self doCancel];
}

- (void)requestPermission:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject {
    [self doRequestPermission:resolve reject:reject];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
    return std::make_shared<facebook::react::NativeAccurateLocationSpecJSI>(params);
}
#endif

@end
