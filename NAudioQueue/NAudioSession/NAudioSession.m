//
//  NAudioSession.m
//  NAudioSession
//
//  Created by 泽娄 on 2019/9/18.
//  Copyright © 2019 泽娄. All rights reserved.
//

#import "NAudioSession.h"
#import "AVAudioSession+RouteUtils.h"

const NSTimeInterval AUSAudioSessionLatency_Background = 0.0929;
const NSTimeInterval AUSAudioSessionLatency_Default = 0.0232;
const NSTimeInterval AUSAudioSessionLatency_LowLatency = 0.0058;

@implementation NAudioSession

+ (NAudioSession *)sharedInstance
{
    static NAudioSession *instance = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NAudioSession alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _preferredSampleRate = _currentSampleRate = 44100.0;
        _audioSession = [AVAudioSession sharedInstance];
    }return self;
}

- (void)addRouteChangeListener
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onNotificationAudioRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
    [self adjustOnRouteChange];
}

#pragma mark - notification observer
- (void)onNotificationAudioRouteChange:(NSNotification *)sender
{
    [self adjustOnRouteChange];
}

- (void)adjustOnRouteChange
{
    AVAudioSessionRouteDescription *currentRoute = [[AVAudioSession sharedInstance] currentRoute];
    if (currentRoute) {
        if ([[AVAudioSession sharedInstance] usingWiredMicrophone]) {
        } else {
            if (![[AVAudioSession sharedInstance] usingBlueTooth]) {
                [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
            }
        }
    }
}

#pragma setter && getter
- (void)setCategory:(NSString *)category
{
    _category = category;
    
    NSError *error = nil;
    BOOL isSucceed = [_audioSession setCategory:_category error:&error];
    if (!isSucceed) {
        NSLog(@"Could note set category on audio session: %@", error.localizedDescription);
    }
}

- (void)setPreferredSampleRate:(Float64)preferredSampleRate
{
    _preferredSampleRate = preferredSampleRate;
    
    NSError *error = nil;
    BOOL isSucceed = [_audioSession setPreferredSampleRate:_preferredSampleRate error:&error];
    if (!isSucceed) {
        NSLog(@"Error when setting sample rate on audio session: %@", error.localizedDescription);
    }
}

- (void)setActive:(BOOL)active
{
    _active = active;
    
    NSError *error = nil;
    BOOL isSucceed = [_audioSession setActive:_preferredSampleRate error:&error];
    if(!isSucceed){
        NSLog(@"Error when setting active state of audio session: %@", error.localizedDescription);
    }
    
    _currentSampleRate = [_audioSession sampleRate];
}


@end
