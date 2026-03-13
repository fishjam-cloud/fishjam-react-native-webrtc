#import <Foundation/Foundation.h>

@interface RCTEventEmitter : NSObject

@property(nonatomic, strong) NSMutableArray<NSDictionary *> *capturedEvents;

- (NSArray<NSString *> *)supportedEvents;
- (void)sendEventWithName:(NSString *)name body:(id)body;

@end
