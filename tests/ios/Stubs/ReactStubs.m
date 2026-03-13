#import "React/RCTEventEmitter.h"

@implementation RCTEventEmitter

- (instancetype)init {
    self = [super init];
    if (self) {
        _capturedEvents = [NSMutableArray new];
    }

    return self;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[];
}

- (void)sendEventWithName:(NSString *)name body:(id)body {
    [self.capturedEvents addObject:@{@"name" : name ?: @"", @"body" : body ?: [NSNull null]}];
}

@end
