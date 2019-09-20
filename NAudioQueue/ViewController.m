//
//  ViewController.m
//  NAudioQueue
//
//  Created by 泽娄 on 2019/9/20.
//  Copyright © 2019 泽娄. All rights reserved.
//

#import "ViewController.h"
#import "NAudioQueue.h"
#import "utils/CommonUtil.h"

@interface ViewController ()
@property (nonatomic, strong) NAudioQueue *audioQueue;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    NSString *filePath = [CommonUtil bundlePath:@"MiAmor.mp3"];
    NSLog(@"path: %@", filePath);
    
    /// 必须属性接收, 否则内部AudioQueue回调会崩溃
    self.audioQueue = [[NAudioQueue alloc] initWithFilePath:filePath];
}

- (IBAction)start:(UIButton *)sender {
    [self.audioQueue play];
}

- (IBAction)pause:(UIButton *)sender {
    [self.audioQueue pause];
}

- (IBAction)stop:(UIButton *)sender {
    [self.audioQueue stop];
}

@end
