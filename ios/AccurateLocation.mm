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
// notDetermined: defer starting updates until the user answers the permission prompt.
@property (nonatomic, assign) BOOL awaitingAuthToFetch;
@property (nonatomic, assign) double pendingTimeoutMs;
// requestPermission(): promise waiting for the authorization result.
@property (nonatomic, copy, nullable) RCTPromiseResolveBlock permissionResolve;
@end

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
    self.currentAcceptableAccuracy = acceptableAccuracyMeters;
    // NearestTenMeters resolves noticeably faster than Best; we resolve as soon as a
    // fix meets the acceptable threshold anyway, so this is only a hardware hint.
    self.locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters;

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
    double timeoutMs = self.pendingTimeoutMs;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (self.isFetching) {
            // Return the best fresh fix seen so far; only error if nothing arrived.
            if (self.bestLocation && self.bestLocation.horizontalAccuracy > 0) {
                [self finishWithLocation:self.bestLocation];
            } else {
                [self finishWithError:@"LOCATION_TIMEOUT" message:@"Location request timed out"];
            }
        }
    });
    [self.locationManager startUpdatingLocation];
}

// ─── RCT_EXPORT_METHOD (Old Arch bridge fallback) ────────────────────────────

#ifndef RCT_NEW_ARCH_ENABLED
RCT_EXPORT_METHOD(getCurrentLocation:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
    double acceptable = options[@"acceptableAccuracyMeters"] ? [options[@"acceptableAccuracyMeters"] doubleValue] : 15.0;
    double maxCacheAgeMs = options[@"maxCacheAgeMs"] ? [options[@"maxCacheAgeMs"] doubleValue] : 0.0;
    double timeoutMs = options[@"timeoutMs"] ? [options[@"timeoutMs"] doubleValue] : 15000.0;
    [self fetchLocationWithAcceptable:acceptable maxCacheAge:maxCacheAgeMs timeout:timeoutMs resolve:resolve reject:reject];
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
    if (!location || location.horizontalAccuracy <= 0) return;
    // Track the best fresh fix; resolve the instant one meets the accuracy target.
    if (!self.bestLocation || location.horizontalAccuracy < self.bestLocation.horizontalAccuracy) {
        self.bestLocation = location;
    }
    if (location.horizontalAccuracy <= self.currentAcceptableAccuracy) {
        [self finishWithLocation:location];
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
    double acceptable = options.acceptableAccuracyMeters().has_value() ? options.acceptableAccuracyMeters().value() : 15.0;
    double timeoutMs = options.timeoutMs().has_value() ? options.timeoutMs().value() : 15000.0;
    double maxCacheAgeMs = options.maxCacheAgeMs().has_value() ? options.maxCacheAgeMs().value() : 0.0;
    [self fetchLocationWithAcceptable:acceptable maxCacheAge:maxCacheAgeMs timeout:timeoutMs resolve:resolve reject:reject];
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
