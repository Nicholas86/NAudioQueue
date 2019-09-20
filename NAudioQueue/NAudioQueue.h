//
//  NAudioQueue.h
//  NAudioQueue
//
//  Created by 泽娄 on 2019/9/20.
//  Copyright © 2019 泽娄. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NAudioQueue : NSObject

- (instancetype)initWithFilePath:(NSString *)path;

- (void)play;

- (void)pause;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
