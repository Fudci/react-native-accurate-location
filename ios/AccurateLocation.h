#ifdef RCT_NEW_ARCH_ENABLED
  #import "AccurateLocationSpec/AccurateLocationSpec.h"
#endif

#import <React/RCTBridgeModule.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef RCT_NEW_ARCH_ENABLED
@interface AccurateLocation : NativeAccurateLocationSpecBase <NativeAccurateLocationSpec, CLLocationManagerDelegate>
#else
@interface AccurateLocation : NSObject <RCTBridgeModule, CLLocationManagerDelegate>
#endif

@end

NS_ASSUME_NONNULL_END
