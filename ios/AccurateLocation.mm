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
@property (nonatomic, assign) double currentAcceptableAccuracy;
@property (nonatomic, strong, nullable) CLLocation *bestLocation;
// Plateau: token to cancel a stale plateau timer while accuracy is still improving.
@property (nonatomic, assign) NSInteger plateauToken;
@property (nonatomic, assign) BOOL plateauArmed;
// notDetermined: defer starting updates until the user answers the permission prompt.
@property (nonatomic, assign) BOOL awaitingAuthToFetch;
@property (nonatomic, assign) double pendingTimeoutMs;
// Per-request tuning, mirroring the Android module.
@property (nonatomic, assign) double currentMaxFixAgeMs;
@property (nonatomic, assign) double currentMinSettleMs;
@property (nonatomic, assign) BOOL smoothingEnabled;
@property (nonatomic, assign) BOOL adaptiveTimeoutEnabled;
@property (nonatomic, assign) BOOL allowStaleFallbackEnabled;
// Monotonic start of the request, so a system clock change cannot skew the settle window.
@property (nonatomic, assign) NSTimeInterval startUptime;
// Token so the timeout can be re-armed (cold-start extension) without the old one firing.
@property (nonatomic, assign) NSInteger timeoutToken;
// Recent accepted fixes, oldest first, used to median away multipath scatter.
@property (nonatomic, strong) NSMutableArray<CLLocation *> *recentLocations;
// Warmup: keeps CoreLocation running so the next fetch resolves fast.
@property (nonatomic, assign) BOOL warmupActive;
@property (nonatomic, assign) NSInteger warmupToken;
// requestPermission(): promise waiting for the authorization result.
@property (nonatomic, copy, nullable) RCTPromiseResolveBlock permissionResolve;
@end

// If accuracy does not improve by >kImproveEps within kPlateauMs, resolve the best fix.
static const double kPlateauMs = 6000.0;
static const CLLocationAccuracy kImproveEps = 0.3;

// A fix reports the accuracy it had WHEN IT WAS TAKEN, so an old one keeps claiming a tight
// accuracy for a place the device has already left — precise, but wrong. Older ones are refused.
static const double kDefaultMaxFixAgeMs = 3000.0;

// GNSS converges over time and its earliest fixes are its worst, so returning immediately is
// what makes a one-shot read lose to a maps app that has simply been listening for longer.
static const double kDefaultMinSettleMs = 4000.0;
static const CLLocationAccuracy kExcellentAccuracy = 5.0;

// Without a network assist the almanac has to come from the satellites themselves and the first
// fix can take far longer than the default deadline allows. If nothing has arrived by the probe
// mark, the deadline is stretched rather than giving up on a chip that was nearly ready.
static const double kColdStartProbeMs = 10000.0;
static const double kColdStartTimeoutMs = 45000.0;

// Multipath scatters fixes around the true position rather than dragging them off it, so the
// median of recent samples lands closer than any single one.
static const NSUInteger kSmoothingWindow = 8;
static const double kSmoothingAccuracySlack = 1.5;

// A jump implying a speed no phone-carrying person reaches is a bad fix, not movement.
static const double kMaxPlausibleSpeedMps = 50.0;

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

- (void)fetchLocationWithAcceptable:(double)acceptableAccuracyMeters
                        maxCacheAge:(double)maxCacheAgeMs
                          maxFixAge:(double)maxFixAgeMs
                          minSettle:(double)minSettleMs
                          smoothing:(BOOL)smoothing
                    adaptiveTimeout:(BOOL)adaptiveTimeout
                 allowStaleFallback:(BOOL)allowStaleFallback
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
    self.plateauToken = 0;
    self.plateauArmed = NO;
    self.currentAcceptableAccuracy = acceptableAccuracyMeters;
    self.currentMaxFixAgeMs = maxFixAgeMs;
    self.currentMinSettleMs = minSettleMs;
    self.smoothingEnabled = smoothing;
    self.adaptiveTimeoutEnabled = adaptiveTimeout;
    self.allowStaleFallbackEnabled = allowStaleFallback;
    self.recentLocations = [NSMutableArray array];
    self.startUptime = NSProcessInfo.processInfo.systemUptime;
    // Asking for ten metres caps the hardware below a tighter target, so the request could never
    // be satisfied and would always fall through to the plateau. Match the ask instead.
    self.locationManager.desiredAccuracy = acceptableAccuracyMeters < 10.0
        ? kCLLocationAccuracyBest
        : kCLLocationAccuracyNearestTenMeters;

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

    self.pendingTimeoutMs = timeoutMs;

    if (status == kCLAuthorizationStatusNotDetermined) {
        self.awaitingAuthToFetch = YES;
        [self.locationManager requestWhenInUseAuthorization];
        return;
    }

    __block BOOL servicesEnabled = YES;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        servicesEnabled = [CLLocationManager locationServicesEnabled];
    });
    if (!servicesEnabled) {
        self.isFetching = NO;
        reject(@"LOCATION_SERVICES_DISABLED", @"Location services (GPS) are turned off", nil);
        return;
    }

    // Optional instant path: only a VERY fresh cache already within the accuracy target.
    // Off by default (maxCacheAgeMs=0) so a moving device never returns a stale position.
    CLLocation *lastLoc = self.locationManager.location;
    if (maxCacheAgeMs > 0 && lastLoc && lastLoc.horizontalAccuracy > 0 &&
        lastLoc.horizontalAccuracy <= acceptableAccuracyMeters) {
        NSTimeInterval ageMs = -[lastLoc.timestamp timeIntervalSinceNow] * 1000.0;
        if (ageMs < maxCacheAgeMs) {
            [self finishWithLocation:lastLoc];
            return;
        }
    }

    [self beginLocationUpdates];
}

// Arm the timeout + start continuous updates. Extracted so it can be re-invoked from
// didChangeAuthorization after the user answers the permission prompt (notDetermined case).
- (void)beginLocationUpdates {
    [self armTimeout:self.pendingTimeoutMs];

    // Cold start with no assistance data: stretch the deadline instead of giving up on a chip
    // that simply has not decoded the almanac yet. Only ever extends, never shortens.
    if (self.adaptiveTimeoutEnabled && self.pendingTimeoutMs < kColdStartTimeoutMs) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kColdStartProbeMs * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (self.isFetching && self.bestLocation == nil) {
                double remaining = kColdStartTimeoutMs - [self elapsedMs];
                if (remaining > 0) [self armTimeout:remaining];
            }
        });
    }

    // The settle window may close after the target was already met, so re-check then.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.currentMinSettleMs * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.isFetching && self.bestLocation &&
            self.bestLocation.horizontalAccuracy > 0 &&
            self.bestLocation.horizontalAccuracy <= self.currentAcceptableAccuracy) {
            [self finishWithLocation:self.bestLocation];
        }
    });

    [self.locationManager startUpdatingLocation];
}

- (double)elapsedMs {
    return (NSProcessInfo.processInfo.systemUptime - self.startUptime) * 1000.0;
}

// Age of a fix in ms. CoreLocation only exposes a wall-clock timestamp, so unlike Android this
// cannot be read from the monotonic clock.
- (double)ageMsOf:(CLLocation *)location {
    return -[location.timestamp timeIntervalSinceNow] * 1000.0;
}

- (void)armTimeout:(double)ms {
    self.timeoutToken += 1;
    NSInteger token = self.timeoutToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.isFetching && token == self.timeoutToken) [self timedOut];
    });
}

// The deadline passed. Return the best fresh fix; failing that, fall back to the last known
// position at any age rather than failing outright — a worse answer beats no answer, and
// `ageMs` on the result says how old it is.
- (void)timedOut {
    if (self.bestLocation && self.bestLocation.horizontalAccuracy > 0) {
        [self finishWithLocation:self.bestLocation];
        return;
    }
    CLLocation *cached = self.allowStaleFallbackEnabled ? self.locationManager.location : nil;
    if (cached && cached.horizontalAccuracy > 0) {
        // Deliberately unfiltered: no age limit, no accuracy gate, no smoothing.
        [self.recentLocations removeAllObjects];
        [self finishWithLocation:cached];
    } else if (self.allowStaleFallbackEnabled) {
        [self finishWithError:@"LOCATION_TIMEOUT"
                      message:@"Location request timed out and no last known position is available"];
    } else {
        [self finishWithError:@"LOCATION_TIMEOUT" message:@"Location request timed out"];
    }
}

// ─── RCT_EXPORT_METHOD (Old Arch bridge fallback) ────────────────────────────

#ifndef RCT_NEW_ARCH_ENABLED
RCT_EXPORT_METHOD(getCurrentLocation:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    double acceptable = options[@"acceptableAccuracyMeters"] ? [options[@"acceptableAccuracyMeters"] doubleValue] : 15.0;
    double maxCacheAgeMs = options[@"maxCacheAgeMs"] ? [options[@"maxCacheAgeMs"] doubleValue] : 0.0;
    BOOL explicitTimeout = options[@"timeoutMs"] != nil;
    double timeoutMs = explicitTimeout ? [options[@"timeoutMs"] doubleValue] : 15000.0;
    double maxFixAgeMs = options[@"maxFixAgeMs"] ? [options[@"maxFixAgeMs"] doubleValue] : kDefaultMaxFixAgeMs;
    double minSettleMs = options[@"minSettleMs"] ? [options[@"minSettleMs"] doubleValue] : kDefaultMinSettleMs;
    BOOL smoothing = options[@"smoothing"] ? [options[@"smoothing"] boolValue] : YES;
    // A timeout the caller wrote down is a promise, so it is never stretched behind their back.
    BOOL adaptiveTimeout = options[@"adaptiveTimeout"] ? [options[@"adaptiveTimeout"] boolValue] : !explicitTimeout;
    BOOL allowStaleFallback = options[@"allowStaleFallback"] ? [options[@"allowStaleFallback"] boolValue] : YES;
    [self fetchLocationWithAcceptable:acceptable
                          maxCacheAge:maxCacheAgeMs
                            maxFixAge:maxFixAgeMs
                            minSettle:minSettleMs
                            smoothing:smoothing
                      adaptiveTimeout:adaptiveTimeout
                   allowStaleFallback:allowStaleFallback
                              timeout:timeoutMs
                              resolve:resolve
                               reject:reject];
}

RCT_EXPORT_METHOD(cancel) {
    [self doCancel];
}

RCT_EXPORT_METHOD(warmup:(double)durationMs) {
    [self doWarmup:durationMs];
}

RCT_EXPORT_METHOD(stopWarmup) {
    [self doStopWarmup];
}

RCT_EXPORT_METHOD(requestPermission:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    [self doRequestPermission:resolve reject:reject];
}
#endif

// ─── CLLocationManagerDelegate ───────────────────────────────────────────────

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = [locations lastObject];
    if (!location || location.horizontalAccuracy <= 0) return;

    // Refuse stale fixes. CoreLocation hands over its cached location as an early update, which
    // would otherwise resolve the request with a position the device has already left.
    if (self.currentMaxFixAgeMs > 0 && [self ageMsOf:location] > self.currentMaxFixAgeMs) return;

    // Refuse physically impossible jumps — a multipath outlier, not movement.
    CLLocation *previousAccepted = self.recentLocations.lastObject;
    if (previousAccepted) {
        NSTimeInterval seconds =
            [location.timestamp timeIntervalSinceDate:previousAccepted.timestamp];
        if (seconds > 0 &&
            [location distanceFromLocation:previousAccepted] / seconds > kMaxPlausibleSpeedMps) {
            return;
        }
    }

    [self.recentLocations addObject:location];
    while (self.recentLocations.count > kSmoothingWindow) {
        [self.recentLocations removeObjectAtIndex:0];
    }

    CLLocation *prev = self.bestLocation;
    BOOL improved = !prev || location.horizontalAccuracy < prev.horizontalAccuracy - kImproveEps;
    if (!prev || location.horizontalAccuracy < prev.horizontalAccuracy) {
        self.bestLocation = location;
    }
    CLLocation *best = self.bestLocation;

    // Target reached, but only stop early once the receiver has had time to converge — or if the
    // fix is already so tight that waiting cannot meaningfully improve it.
    if (best.horizontalAccuracy <= self.currentAcceptableAccuracy &&
        ([self elapsedMs] >= self.currentMinSettleMs ||
         best.horizontalAccuracy <= kExcellentAccuracy)) {
        [self finishWithLocation:best];
        return;
    }
    // Otherwise, once accuracy stops improving for kPlateauMs, settle for the best fix
    // — keeps it fast indoors where the target may be physically unreachable.
    if (improved || !self.plateauArmed) {
        self.plateauArmed = YES;
        self.plateauToken += 1;
        NSInteger token = self.plateauToken;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPlateauMs * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{
            if (!self.isFetching || token != self.plateauToken) return;
            // Accuracy has bottomed out, but honour the settle window so a plateau hit in the
            // first seconds does not cut the read short.
            double remaining = self.currentMinSettleMs - [self elapsedMs];
            if (remaining > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    if (self.isFetching && token == self.plateauToken) {
                        [self finishWithLocation:self.bestLocation];
                    }
                });
            } else {
                [self finishWithLocation:self.bestLocation];
            }
        });
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

static double MedianOfSorted(NSArray<NSNumber *> *values) {
    NSArray<NSNumber *> *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger mid = sorted.count / 2;
    if (sorted.count % 2 == 0) {
        return (sorted[mid - 1].doubleValue + sorted[mid].doubleValue) / 2.0;
    }
    return sorted[mid].doubleValue;
}

// Replaces the coordinates with the median of the comparable samples around them. Multipath
// scatters fixes around the true position, so the median sits closer to it than any one sample.
// The accuracy and timestamp of `best` are kept as-is.
- (CLLocation *)smoothed:(CLLocation *)best {
    if (!self.smoothingEnabled) return best;
    NSMutableArray<NSNumber *> *lats = [NSMutableArray array];
    NSMutableArray<NSNumber *> *lons = [NSMutableArray array];
    for (CLLocation *loc in self.recentLocations) {
        if (loc.horizontalAccuracy > 0 &&
            loc.horizontalAccuracy <= best.horizontalAccuracy * kSmoothingAccuracySlack) {
            [lats addObject:@(loc.coordinate.latitude)];
            [lons addObject:@(loc.coordinate.longitude)];
        }
    }
    if (lats.count < 3) return best;
    CLLocationCoordinate2D coord =
        CLLocationCoordinate2DMake(MedianOfSorted(lats), MedianOfSorted(lons));
    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:best.altitude
                               horizontalAccuracy:best.horizontalAccuracy
                                 verticalAccuracy:best.verticalAccuracy
                                           course:best.course
                                            speed:best.speed
                                        timestamp:best.timestamp];
}

- (void)finishWithLocation:(CLLocation *)rawLocation {
    if (!self.isFetching) return;
    // Age is read before smoothing, since smoothing rebuilds the object.
    double ageMs = [self ageMsOf:rawLocation];
    CLLocation *location = [self smoothed:rawLocation];
    self.isFetching = NO;
    // The read is done, so warmup has served its purpose -> stop it (saves battery).
    self.warmupActive = NO;
    self.warmupToken += 1;
    [self.locationManager stopUpdatingLocation];
    self.bestLocation = nil;
    [self.recentLocations removeAllObjects];

    if (self.resolveBlock) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"latitude"]  = @(location.coordinate.latitude);
        result[@"longitude"] = @(location.coordinate.longitude);
        result[@"accuracy"]  = @(location.horizontalAccuracy);
        result[@"altitude"]  = @(location.altitude);
        result[@"time"]      = @([location.timestamp timeIntervalSince1970] * 1000.0);
        // How old the fix is. A large value means this is the stale last-known fallback rather
        // than a live reading, and the caller can decide whether that is good enough.
        result[@"ageMs"]     = @(ageMs);
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
    // The read is done, so warmup has served its purpose -> stop it (saves battery).
    self.warmupActive = NO;
    self.warmupToken += 1;
    [self.locationManager stopUpdatingLocation];
    self.bestLocation = nil;
    [self.recentLocations removeAllObjects];

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

- (void)doWarmup:(double)durationMs {
    CLAuthorizationStatus status;
    if (@available(iOS 14.0, *)) {
        status = self.locationManager.authorizationStatus;
    } else {
        status = [CLLocationManager authorizationStatus];
    }
    if (status == kCLAuthorizationStatusDenied || status == kCLAuthorizationStatusRestricted) return;
    self.warmupActive = YES;
    self.locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;
    [self.locationManager startUpdatingLocation];
    self.warmupToken += 1;
    NSInteger token = self.warmupToken;
    double dur = durationMs > 0 ? durationMs : 30000.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (token == self.warmupToken) [self doStopWarmup];
    });
}

- (void)doStopWarmup {
    self.warmupActive = NO;
    self.warmupToken += 1;
    if (!self.isFetching) [self.locationManager stopUpdatingLocation];
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
    double acceptable = options.acceptableAccuracyMeters().has_value() ? options.acceptableAccuracyMeters().value() : 15.0;
    BOOL explicitTimeout = options.timeoutMs().has_value();
    double timeoutMs = explicitTimeout ? options.timeoutMs().value() : 15000.0;
    double maxCacheAgeMs = options.maxCacheAgeMs().has_value() ? options.maxCacheAgeMs().value() : 0.0;
    double maxFixAgeMs = options.maxFixAgeMs().has_value() ? options.maxFixAgeMs().value() : kDefaultMaxFixAgeMs;
    double minSettleMs = options.minSettleMs().has_value() ? options.minSettleMs().value() : kDefaultMinSettleMs;
    BOOL smoothing = options.smoothing().has_value() ? options.smoothing().value() : YES;
    // A timeout the caller wrote down is a promise, so it is never stretched behind their back.
    BOOL adaptiveTimeout = options.adaptiveTimeout().has_value()
        ? options.adaptiveTimeout().value()
        : !explicitTimeout;
    BOOL allowStaleFallback = options.allowStaleFallback().has_value()
        ? options.allowStaleFallback().value()
        : YES;
    [self fetchLocationWithAcceptable:acceptable
                          maxCacheAge:maxCacheAgeMs
                            maxFixAge:maxFixAgeMs
                            minSettle:minSettleMs
                            smoothing:smoothing
                      adaptiveTimeout:adaptiveTimeout
                   allowStaleFallback:allowStaleFallback
                              timeout:timeoutMs
                              resolve:resolve
                               reject:reject];
}

- (void)cancel {
    [self doCancel];
}

- (void)warmup:(NSNumber *)durationMs {
    [self doWarmup:durationMs ? [durationMs doubleValue] : 0.0];
}

- (void)stopWarmup {
    [self doStopWarmup];
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
