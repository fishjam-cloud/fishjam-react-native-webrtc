#import "H264BackgroundSafeEncoderFactory.h"

#import "H264BackgroundSafeEncoder.h"

@implementation H264BackgroundSafeEncoderFactory {
    id<RTCVideoEncoderFactory> _innerFactory;
}

- (instancetype)initWithInnerFactory:(id<RTCVideoEncoderFactory>)innerFactory {
    self = [super init];
    if (self) {
        _innerFactory = innerFactory;
    }
    return self;
}

- (nullable id<RTCVideoEncoder>)createEncoder:(RTCVideoCodecInfo *)info {
    if ([info.name caseInsensitiveCompare:kRTCVideoCodecH264Name] == NSOrderedSame) {
        return [[H264BackgroundSafeEncoder alloc] initWithInnerFactory:_innerFactory codecInfo:info];
    }
    return [_innerFactory createEncoder:info];
}

- (NSArray<RTCVideoCodecInfo *> *)supportedCodecs {
    return [_innerFactory supportedCodecs];
}

@end
