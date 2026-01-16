#import <CallKit/CallKit.h>
#import <Foundation/Foundation.h>

typedef void (^CallKitVoidCallback)(void);
typedef void (^CallKitStringCallback)(NSString *);
typedef void (^CallKitBoolCallback)(BOOL);

@interface CallKitManager : NSObject <CXProviderDelegate>

@property(nonatomic, copy) CallKitVoidCallback onCallStarted;
@property(nonatomic, copy) CallKitVoidCallback onCallEnded;
@property(nonatomic, copy) CallKitStringCallback onCallFailed;
@property(nonatomic, copy) CallKitBoolCallback onCallMuted;
@property(nonatomic, copy) CallKitBoolCallback onCallHeld;
@property(nonatomic, readonly) BOOL hasActiveCall;

- (void)startCallWithDisplayName:(NSString *)displayName isVideo:(BOOL)isVideo;
- (void)endCall;

@end
