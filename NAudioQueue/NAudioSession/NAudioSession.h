//
//  NAudioSession.h
//  NAudioSession
//
//  Created by 泽娄 on 2019/9/18.
//  Copyright © 2019 泽娄. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

extern const NSTimeInterval AUSAudioSessionLatency_Background;
extern const NSTimeInterval AUSAudioSessionLatency_Default;
extern const NSTimeInterval AUSAudioSessionLatency_LowLatency;

@interface NAudioSession : NSObject

+ (NAudioSession *)sharedInstance;

/// 设置会话
@property (nonatomic, strong) AVAudioSession *audioSession;

/// 采样率
@property (nonatomic, assign) Float64 preferredSampleRate;

/// 记录当前采样率
@property(nonatomic, assign, readonly) Float64 currentSampleRate;

@property(nonatomic, assign) NSTimeInterval preferredLatency;

/// 激活会话
@property(nonatomic, assign) BOOL active;

/// 设置category
@property(nonatomic, copy) NSString *category;

/// 添加远程控制
- (void)addRouteChangeListener;

@end

NS_ASSUME_NONNULL_END
