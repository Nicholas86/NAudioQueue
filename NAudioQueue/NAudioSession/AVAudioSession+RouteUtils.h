//
//  AVAudioSession+RouteUtils.h
//  NAudioSession
//
//  Created by 泽娄 on 2019/9/18.
//  Copyright © 2019 泽娄. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AVAudioSession (RouteUtils)

- (BOOL)usingBlueTooth;

- (BOOL)usingWiredMicrophone;

- (BOOL)shouldShowEarphoneAlert;

@end

NS_ASSUME_NONNULL_END
