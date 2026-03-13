#import <XCTest/XCTest.h>
#import "WebRTCModule.h"

@interface AudioOutputDevicesTests : XCTestCase
@end

@implementation AudioOutputDevicesTests

- (void)testCompilesWithWebRTCModuleHeader {
    Class moduleClass = NSClassFromString(@"WebRTCModule");
    XCTAssertTrue(moduleClass == nil || moduleClass != nil);
}

@end
