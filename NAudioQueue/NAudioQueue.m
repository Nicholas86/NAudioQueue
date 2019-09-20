//
//  NAudioQueue.m
//  NAudioQueue
//
//  Created by 泽娄 on 2019/9/20.
//  Copyright © 2019 泽娄. All rights reserved.
//

#import "NAudioQueue.h"
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <pthread.h>
#import "NAudioSession/NAudioSession.h"

#define kNumberOfBuffers 3              //AudioQueueBuffer数量，一般指明为3
#define kAQBufSize 128 * 1024           //每个AudioQueueBuffer的大小
#define kAudioFileBufferSize 2048       //文件读取数据的缓冲区大小
#define kMaxPacketDesc 512              //最大的AudioStreamPacketDescription个数


#warning http://www.it1352.com/933379.html 遇到的坑

@interface NAudioQueue ()
{
    AudioFileStreamID audioFileStreamID; /// 文件StreamID
    AudioFileID audioFileID; /// 文件FileID
    AudioStreamBasicDescription audioFileBasicDescription; /// 文件的基本格式
    AudioQueueBufferRef audioQueueBuffer[kNumberOfBuffers]; /// buffer数组
    bool inuse[kNumberOfBuffers]; /// 当前buffer使用标记
    AudioStreamPacketDescription audioStreamPacketDesc[kMaxPacketDesc]; /// 保存音频帧的数组
    AudioQueueRef audioQueue; /// audio queue实例
    
    AudioStreamPacketDescription *packetDescs;
    UInt32 numPacketsToRead;
    SInt64 packetIndex;
    
    double packetDuration;//每个packet的时长
    UInt32 packetMaxSize;//每个packet的最大size
    NSInteger dataOffset;//每个packet的偏移
    
    NSLock *lock;//线程锁
}

@property (nonatomic, copy)     NSString *path; /// 文件路径
@property (nonatomic, strong) NSFileHandle *audioFileHandle;//文件处理实例句柄
@property (nonatomic, strong) NSData *audioFileData;//每次读取到的文件数据
@property (nonatomic, assign) NSInteger audioFileDataOffset;//音频数据在文件中的偏移量
@property (nonatomic, assign) NSInteger audioFileLength;//音频文件大小
@property (nonatomic, assign) NSInteger audioBitRate;//音频采样率
@property (nonatomic, assign) CGFloat audioDuration;
@property (nonatomic, assign,getter=isPlaying) bool playing;

@property (nonatomic, assign) NSInteger audioPacketsFilled;//当前buffer填充了多少帧
@property (nonatomic, assign) NSInteger audioDataBytesFilled;//当前buffer填充的数据大小
@property (nonatomic, assign) NSInteger audioBufferIndex;//当前填充的buffer序号
@end

@implementation NAudioQueue

- (instancetype)initWithFilePath:(NSString *)path
{
    self = [super init];
    if (self) {
        self.audioFileHandle = [NSFileHandle fileHandleForReadingAtPath:path];
        lock = [[NSLock alloc] init];
        lock.name = @"audioQueue";
        _path = path;
        packetIndex = 0; /// 默认为0
        [self readFile];
    }return self;
}

- (void)createAudioSession
{
    [[NAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback]; /// 只支持音频播放
    [[NAudioSession sharedInstance] setPreferredSampleRate:44100];
    [[NAudioSession sharedInstance] setActive:YES];
    [[NAudioSession sharedInstance] addRouteChangeListener];
}

- (void)readFile
{
    if ([_path length] == 0) {
        NSLog(@"path is null");
        return;
    }
    OSStatus status;
    
    /// 读取文件, 获取文件基本数据格式
    status = AudioFileOpenURL((__bridge CFURLRef _Nonnull)([self urlWithString:_path]), kAudioFileReadPermission, 0, &audioFileID);
    
    if (status != noErr) {
        NSLog(@"AudioFileOpenURL 失败");
    }
    
    /// 赋值并获取audioFileBasicDescription
    UInt32 ioDataSize = sizeof(audioFileBasicDescription);
    AudioFileGetProperty(audioFileID,  kAudioFilePropertyDataFormat, &ioDataSize, &audioFileBasicDescription);
    
    /// 创建AudioQueue
    [self createAudioQueue];
    
    [self printAudioStreamBasicDescription:audioFileBasicDescription];
    
    if (audioFileBasicDescription.mBytesPerPacket == 0 || audioFileBasicDescription.mFramesPerPacket == 0) {
        UInt32 maxPacketSize;
        UInt32 size = sizeof(maxPacketSize);
        status = AudioFileGetProperty(audioFileID, kAudioFilePropertyPacketSizeUpperBound, &size, &maxPacketSize);
        
        if (status != noErr) {
            NSLog(@"kAudioFilePropertyPacketSizeUpperBound 失败");
        }
        
        if (maxPacketSize > kAQBufSize) {
            maxPacketSize = kAQBufSize;
        }
        
        numPacketsToRead = kAQBufSize/maxPacketSize;
        packetDescs = malloc(sizeof(AudioStreamPacketDescription)*numPacketsToRead);
    }else{
        numPacketsToRead = kAQBufSize/audioFileBasicDescription.mBytesPerPacket;
        packetDescs = nil;
    }
    
    UInt32 cookieSize;
    Boolean writeable;
    status = AudioFileGetProperty(audioFileID, kAudioFilePropertyMagicCookieData, &cookieSize, &writeable);
    if (status != noErr) {
        NSLog(@"kAudioFilePropertyMagicCookieSize 失败");
    }
    if (cookieSize > 0) {
        char *cookieData = malloc(sizeof(char) * cookieSize);
        status = AudioFileGetProperty(audioFileID, kAudioFilePropertyMagicCookieData, &cookieSize, cookieData);
        
        if (status != noErr) {
            NSLog(@"kAudioFilePropertyMagicCookieData 失败");
        }
        status = AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
        
        if (status != noErr) {
            NSLog(@"kAudioQueueProperty_MagicCookie 失败");
        }
    }
    
    packetIndex = 0;
    
    /// 创建buffer
    [self createBuffer];
    
    Float32 gain = 1.0;
    //设置音量
    status = AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, gain);
    if (status != noErr) {
        NSLog(@"AudioQueueSetParameter 失败!!!");
    }
}

/*
 参数及返回说明如下：
 1. inFormat：该参数指明了即将播放的音频的数据格式
 2. inCallbackProc：该回调用于当AudioQueue已使用完一个缓冲区时通知用户，用户可以继续填充音频数据
 3. inUserData：由用户传入的数据指针，用于传递给回调函数
 4. inCallbackRunLoop：指明回调事件发生在哪个RunLoop之中，如果传递NULL，表示在AudioQueue所在的线程上执行该回调事件，一般情况下，传递NULL即可。
 5. inCallbackRunLoopMode：指明回调事件发生的RunLoop的模式，传递NULL相当于kCFRunLoopCommonModes，通常情况下传递NULL即可
 6. outAQ：该AudioQueue的引用实例，
 */
- (void)createAudioQueue
{
    OSStatus status;
    status = AudioQueueNewOutput(&audioFileBasicDescription, NAudioQueueOutputCallback, (__bridge void * _Nullable)(self), CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &audioQueue);
    
    if (status != noErr) {
        NSLog(@"AudioQueueNewOutput 失败");
    }
}

- (void)_createAudioQueue
{
    OSStatus status;
    status = AudioQueueNewOutput(&audioFileBasicDescription, AudioQueueOutput_Callback, (__bridge void * _Nullable)(self), CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &audioQueue);
    
    if (status != noErr) {
        NSLog(@"AudioQueueNewOutput 失败");
    }
}

/*
 该方法的作用是为存放音频数据的缓冲区开辟空间

 参数及返回说明如下：
 1. inAQ：AudioQueue的引用实例
 2. inBufferByteSize：需要开辟的缓冲区的大小
 3. outBuffer：开辟的缓冲区的引用实例
 
 */
- (void)createBuffer
{
    OSStatus status;
    for (int i = 0; i < kNumberOfBuffers; i++) {
        status = AudioQueueAllocateBuffer(audioQueue, kAQBufSize, &audioQueueBuffer[i]);
        if (status != noErr) {
            NSLog(@"AudioQueueAllocateBuffer 失败!!!");
            continue;
        }
        //读取包数据
        if ([self readPacketsIntoBuffer:audioQueueBuffer[i]] == 1) {
            break;
        }
    }
}

- (void)_createBuffer
{
    OSStatus status;
    for (int i = 0; i < kNumberOfBuffers; i++) {
        status = AudioQueueAllocateBuffer(audioQueue, kAQBufSize, &audioQueueBuffer[i]);
        if (status != noErr) {
            NSLog(@"AudioQueueAllocateBuffer 失败!!!");
            continue;
        }
    }
}

- (void)play
{
    if (!audioQueue) {
        NSLog(@"audioQueue is null!!!");
        return;
    }
    
    OSStatus status;
    //队列处理开始，此后系统开始自动调用回调(Callback)函数
    status = AudioQueueStart(audioQueue, nil);
    
    if (status != noErr) {
        NSLog(@"AudioQueueStart 失败!!!");
    }
}

- (void)nStart
{
//    [self createAudioSession];

    NSError *error;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    
    if (audioFileStreamID == NULL) {
        
        //        AudioFileStreamOpen的参数说明如下：
        //        1. inClientData：用户指定的数据，用于传递给回调函数，这里我们指定(__bridge LocalAudioPlayer*)self
        //        2. inPropertyListenerProc：当解析到一个音频信息时，将回调该方法
        //        3. inPacketsProc：当解析到一个音频帧时，将回调该方法
        //        4. inFileTypeHint：指明音频数据的格式，如果你不知道音频数据的格式，可以传0
        //        5. outAudioFileStream：AudioFileStreamID实例，需保存供后续使用
        
        AudioFileStreamOpen((__bridge void *)self, AudioFileStreamPropertyListenerProc, AudioFileStreamPacketsProc, 0, &audioFileStreamID);
    }
    
    do {
        self.audioFileData = [self.audioFileHandle readDataOfLength:kAudioFileBufferSize];
        
        //        参数的说明如下：
        //        1. inAudioFileStream：AudioFileStreamID实例，由AudioFileStreamOpen打开
        //        2. inDataByteSize：此次解析的数据字节大小
        //        3. inData：此次解析的数据大小
        //        4. inFlags：数据解析标志，其中只有一个值kAudioFileStreamParseFlag_Discontinuity = 1，表示解析的数据是否是不连续的，目前我们可以传0。
        
        OSStatus error = AudioFileStreamParseBytes(audioFileStreamID, (UInt32)self.audioFileData.length, self.audioFileData.bytes, 0);
        if (error != noErr) {
            NSLog(@"AudioFileStreamParseBytes 失败");
        }
    } while (self.audioFileData != nil && self.audioFileData.length > 0);
    
    
    //    [NSThread detachNewThreadSelector:@selector(startTimer) toTarget:self withObject:nil];
    
    //    dispatch_async(dispatch_get_main_queue(), ^{
    //        [self startTimer];
    //    });
    
    [self.audioFileHandle closeFile];
    
}

- (void)pause
{
    if (audioQueue && self.isPlaying) {
        AudioQueuePause(audioQueue);
        self.playing = NO;
    }
}

- (void)stop
{
    if (audioQueue && self.isPlaying) {
        AudioQueueStop(audioQueue,true);
        self.playing = NO;
    }
    AudioQueueReset(audioQueue);
}

/// 读取包数据
- (UInt32)readPacketsIntoBuffer:(AudioQueueBufferRef)buffer
{
    UInt32 numBytes = buffer->mAudioDataBytesCapacity;
    UInt32 numPackets = numPacketsToRead;
    
    /// 从文件中接受数据并保存到缓存(buffer)中
    NSLog(@"从文件中接受数据并保存到缓存(buffer)中");

    OSStatus status = AudioFileReadPacketData(audioFileID, NO, &numBytes, packetDescs, packetIndex, &numPackets, buffer->mAudioData);
    if (status != noErr) {
        NSLog(@"AudioFileReadPackets 失败");
    }
    
    /// 插入Buffer
    if(numPackets >0){
        buffer->mAudioDataByteSize=numBytes;
        AudioQueueEnqueueBuffer(audioQueue, buffer, (packetDescs ? numPackets : 0), packetDescs);
        packetIndex += numPackets;
    }else{
        return 1;//意味着我们没有读到任何的包
    }
    return 0;//0代表正常的退出
}

/// 回调
static void NAudioQueueOutputCallback(void *inUserData, AudioQueueRef inAQ,
                                        AudioQueueBufferRef buffer){
        
    NAudioQueue *_audioQueue = (__bridge NAudioQueue *)inUserData;
    
    OSStatus status;
    
    /// 读取包数据
    UInt32 numBytes = buffer->mAudioDataBytesCapacity;
    UInt32 numPackets = _audioQueue->numPacketsToRead;
    
    status = AudioFileReadPacketData(_audioQueue->audioFileID, NO, &numBytes, _audioQueue->packetDescs, _audioQueue->packetIndex,&numPackets, buffer->mAudioData);
    
    if (status != noErr) {
        NSLog(@"AudioFileReadPackets 失败");
        return;
    }
    
    NSLog(@"读取包数据, status: %d", status);
    
    //成功读取时
    if (numPackets>0) {
        //将缓冲的容量设置为与读取的音频数据一样大小(确保内存空间)
        buffer->mAudioDataByteSize = numBytes;
        //完成给队列配置缓存的处理
        status = AudioQueueEnqueueBuffer(_audioQueue->audioQueue, buffer, numPackets, _audioQueue->packetDescs);
        //移动包的位置
        _audioQueue->packetIndex += numPackets;
        
        /// 标识播放状态
        _audioQueue.playing = YES;
    }
}

//当解析到一个音频信息时，将回调该方法
void AudioFileStreamPropertyListenerProc(void *inClientData,
                                         AudioFileStreamID inAudioFileStream,
                                         AudioFileStreamPropertyID inPropertyID,
                                         UInt32 *ioFlags){
    NAudioQueue *audioPlayer = (__bridge NAudioQueue *)inClientData;
    
    switch (inPropertyID) {
            //该属性指明了音频数据的格式信息，返回的数据是一个AudioStreamBasicDescription结构
        case kAudioFileStreamProperty_DataFormat:{
            if (audioPlayer->audioFileBasicDescription.mSampleRate == 0) {
                UInt32 ioPropertyDataSize = sizeof(audioPlayer->audioFileBasicDescription);
                //获取音频数据格式
                OSStatus error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &ioPropertyDataSize, &audioPlayer->audioFileBasicDescription);
                if (error != noErr) {
                    NSLog(@"获取音频数据格式 失败");
                    break;
                }
                [audioPlayer printAudioStreamBasicDescription:audioPlayer->audioFileBasicDescription];
                
                if (audioPlayer->audioFileBasicDescription.mSampleRate > 0) {
                    audioPlayer->packetDuration=audioPlayer->audioFileBasicDescription.mFramesPerPacket/audioPlayer->audioFileBasicDescription.mSampleRate;
                }
            }
        }
            break;
            //每个packet的最大size
        case kAudioFileStreamProperty_PacketSizeUpperBound:{
            if (audioPlayer->packetMaxSize == 0) {
                UInt32 sizeOfUInt32 = sizeof(UInt32);
                UInt32 packetMaxSize = 0;
                OSStatus error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfUInt32, &packetMaxSize);
                if (error != noErr) {
                    NSLog(@"kAudioFileStreamProperty_PacketSizeUpperBound 失败");
                }
                audioPlayer->packetMaxSize = packetMaxSize;
            }
        }
            break;
            
        case kAudioFileStreamProperty_MaximumPacketSize:{
            if (audioPlayer->packetMaxSize == 0) {
                UInt32 sizeOfUInt32 = sizeof(UInt32);
                UInt32 packetMaxSize=0;
                OSStatus error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfUInt32, &packetMaxSize);
                if (error != noErr) {
                    NSLog(@"kAudioFileStreamProperty_MaximumPacketSize 失败");
                }
                audioPlayer->packetMaxSize = packetMaxSize;
            }
        }
            break;
            
            //该属性告诉我们，已经解析到完整的音频帧数据，准备产生音频帧，之后会调用到另外一个回调函数，我们在这里创建音频队列AudioQueue，如果音频数据中有Magic Cookie Data，则先调用AudioFileStreamGetPropertyInfo，获取该数据是否可写，如果可写再取出该属性值，并写入到AudioQueue。之后便是音频数据帧的解析。
        case kAudioFileStreamProperty_ReadyToProducePackets:{
            
            OSStatus error = noErr;
            
            //创建audioqueue
            [audioPlayer _createAudioQueue];
            
            [audioPlayer _createBuffer];
            
            //get the cookie size
            UInt32 cookieSize;
            Boolean writeable;
            error = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writeable);
            if (error != noErr) {
                NSLog(@"get cookieSize error");
                break;
            }
            
            //get the cookie data
            void *cookieData = calloc(1, cookieSize);
            error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, cookieData);
            if (error != noErr) {
                NSLog(@"get cookieData error");
                break;
            }
            
            //set the cookie on the queue
            error = AudioQueueSetProperty(audioPlayer->audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
            if (error != noErr) {
                NSLog(@"set cookieData error");
                break;
            }
            
            //listen for kAudioQueueProperty_IsRunning
            error = AudioQueueAddPropertyListener(audioPlayer->audioQueue, kAudioQueueProperty_IsRunning, MyAudioQueueIsRunningCallback, (__bridge void *)audioPlayer);
            if (error != noErr) {
                NSLog(@"audioqueue listen error");
                break;
            }
            
        }
            break;
            
            //该属性指明了音频数据的编码格式，如MPEG等
        case kAudioFileStreamProperty_FileFormat:{
            UInt32 fileFormat,ioPropertyDataSize = sizeof(fileFormat);
            OSStatus error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FileFormat, &ioPropertyDataSize, &fileFormat);
            if (error != noErr) {
                NSLog(@"获取音频数据的编码格式失败");
                break;
            }
        }
            break;
            
            //            该属性可获取到音频数据的长度，可用于计算音频时长，计算公式为：
            //            时长 = (音频数据字节大小 * 8) / 采样率
        case kAudioFileStreamProperty_AudioDataByteCount:{
            UInt64 dataByteCount;
            UInt32 ioPropertyDataSize = sizeof(dataByteCount);
            OSStatus error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &ioPropertyDataSize, &dataByteCount);
            if(error != noErr){
                NSLog(@"kAudioFileStreamProperty_AudioDataByteCount 失败");
                break;
            }
            audioPlayer.audioFileLength += dataByteCount;
            
            if (dataByteCount != 0) {
                audioPlayer.audioDuration = (dataByteCount * 8)/audioPlayer.audioBitRate;
            }
        }
            break;
            
            //该属性指明了音频文件中共有多少帧
        case kAudioFileStreamProperty_AudioDataPacketCount:{
            UInt64 dataBytesCount;
            UInt32 ioPropertyDataSize = sizeof(dataBytesCount);
            OSStatus error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataPacketCount, &ioPropertyDataSize, &dataBytesCount);
            if(error != noErr){
                NSLog(@"kAudioFileStreamProperty_AudioDataPacketCount 失败");
                break;
            }
        }
            break;
            
            //            该属性指明了音频数据在整个音频文件中的偏移量：
            //            音频文件总大小 = 偏移量 + 音频数据字节大小
        case kAudioFileStreamProperty_DataOffset:{
            SInt64 audioDataOffset;
            UInt32 ioPropertyDataSize = sizeof(audioDataOffset);
            
            OSStatus error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataOffset, &ioPropertyDataSize, &audioDataOffset);
            if(error != noErr){
                NSLog(@"kAudioFileStreamProperty_DataOffset 失败");
                break;
            }
            audioPlayer.audioFileDataOffset = audioDataOffset;
            
            if (audioPlayer.audioFileDataOffset != 0) {
                audioPlayer.audioFileLength += audioPlayer.audioFileDataOffset;
            }
        }
            break;
            
            //该属性可获取到音频的采样率，可用于计算音频时长
        case kAudioFileStreamProperty_BitRate:{
            UInt32 bitRate;
            UInt32 ioPropertyDataSize = sizeof(bitRate);
            
            OSStatus error = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_BitRate, &ioPropertyDataSize, &bitRate);
            
            if(error != noErr){
                NSLog(@"kAudioFileStreamProperty_BitRate 失败");
                break;
            }
            
            if (bitRate != 0) {
                audioPlayer.audioBitRate = bitRate;
            }
            
            if (audioPlayer.audioFileLength != 0) {
                audioPlayer.audioDuration = (audioPlayer.audioFileLength * 8)/audioPlayer.audioBitRate;
            }
        }
            break;
            
        default:
            break;
    }
}
//当解析到一个音频帧时，将回调该方法
void AudioFileStreamPacketsProc(void *inClientData,
                                UInt32 inNumberBytes,
                                UInt32 inNumberPackets,
                                const void *inInputData,
                                AudioStreamPacketDescription *inPacketDescriptions){
    
    NAudioQueue *_audioQueue = (__bridge NAudioQueue *)inClientData;
    
    if (inPacketDescriptions) {
        for (int i = 0; i < inNumberPackets; i++) {
            SInt64 mStartOffset = inPacketDescriptions[i].mStartOffset;
            UInt32 mDataByteSize = inPacketDescriptions[i].mDataByteSize;
            
            //如果当前要填充的数据大于缓冲区剩余大小，将当前buffer送入播放队列，指示将当前帧放入到下一个buffer
            if (mDataByteSize > kAudioFileBufferSize - _audioQueue.audioDataBytesFilled) {
                NSLog(@"当前buffer_%ld已经满了，送给audioqueue去播吧",(long)_audioQueue->_audioBufferIndex);
                _audioQueue->inuse[_audioQueue.audioBufferIndex] = YES;
                
                OSStatus err = AudioQueueEnqueueBuffer(_audioQueue->audioQueue, _audioQueue->audioQueueBuffer[_audioQueue.audioBufferIndex], (UInt32)_audioQueue.audioPacketsFilled, _audioQueue->audioStreamPacketDesc);
                if (err == noErr) {
                    
                    if (!_audioQueue.isPlaying) {
                        err = AudioQueueStart(_audioQueue->audioQueue, NULL);
                        if (err != noErr) {
                            NSLog(@"play failed");
                            continue;
                        }
                        _audioQueue.playing = YES;
                    }
                    
                    _audioQueue.audioBufferIndex = (++_audioQueue.audioBufferIndex) % kNumberOfBuffers;
                    _audioQueue.audioPacketsFilled = 0;
                    _audioQueue.audioDataBytesFilled = 0;
                    
                    //                    // wait until next buffer is not in use
                    //                    pthread_mutex_lock(&audioPlayer->mutex);
                    //                    while (audioPlayer->inuse[audioPlayer.audioBufferIndex]) {
                    //                        printf("... WAITING ...\n");
                    //                        pthread_cond_wait(&audioPlayer->cond, &audioPlayer->mutex);
                    //                    }
                    //                    pthread_mutex_unlock(&audioPlayer->mutex);
                    //                    printf("WaitForFreeBuffer->unlock\n");
                    
                    while (_audioQueue->inuse[_audioQueue->_audioBufferIndex]);
                }
            }
            
            NSLog(@"给当前buffer_%ld填装数据中",(long)_audioQueue->_audioBufferIndex);
            AudioQueueBufferRef currentFillBuffer = _audioQueue->audioQueueBuffer[_audioQueue.audioBufferIndex];
            memcpy(currentFillBuffer->mAudioData + _audioQueue.audioDataBytesFilled, inInputData + mStartOffset, mDataByteSize);
            currentFillBuffer->mAudioDataByteSize = (UInt32)(_audioQueue.audioDataBytesFilled + mDataByteSize);
            
            _audioQueue->audioStreamPacketDesc[_audioQueue.audioPacketsFilled] = inPacketDescriptions[i];
            _audioQueue->audioStreamPacketDesc[_audioQueue.audioPacketsFilled].mStartOffset = _audioQueue.audioDataBytesFilled;
            _audioQueue.audioDataBytesFilled += mDataByteSize;
            _audioQueue.audioPacketsFilled += 1;
        }
    }else{
        
    }
}

void MyAudioQueueIsRunningCallback(void *inClientData,AudioQueueRef inAQ,AudioQueuePropertyID inID){
    
    NAudioQueue *audioQueue = (__bridge NAudioQueue *)inClientData;
    
    UInt32 running;
    UInt32 size;
    OSStatus err = AudioQueueGetProperty(inAQ, kAudioQueueProperty_IsRunning, &running, &size);
    if (err == noErr) {
        if (!running) {
            
            //            printf("MyAudioQueueIsRunningCallback->lock\n");
            //            pthread_mutex_lock(&audioPlayer->mutex);
            //            pthread_cond_signal(&audioPlayer->done);
            //            printf("MyAudioQueueIsRunningCallback->unlock\n");
            //            pthread_mutex_unlock(&audioPlayer->mutex);
            
            AudioQueueReset(audioQueue->audioQueue);
            for (int i = 0; i < kNumberOfBuffers; i++) {
                AudioQueueFreeBuffer(audioQueue->audioQueue, audioQueue->audioQueueBuffer[i]);
            }
            
            AudioQueueDispose(audioQueue->audioQueue, true);
            audioQueue->audioQueue = NULL;
            
            AudioFileStreamClose(audioQueue->audioFileStreamID);
        }
    }
    
}

//该回调用于当AudioQueue已使用完一个缓冲区时通知用户，用户可以继续填充音频数据
void AudioQueueOutput_Callback(void *inClientData,AudioQueueRef inAQ,AudioQueueBufferRef inBuffer){
    
    NAudioQueue *_audioQueue = (__bridge NAudioQueue *)inClientData;
    
    for (int i = 0; i < kNumberOfBuffers; i++) {
        if (inBuffer == _audioQueue->audioQueueBuffer[i]) {
            [_audioQueue->lock lock];
            NSLog(@"当前buffer_%d的数据已经播放完了 还给程序继续装数据去吧！！！！！！",i);
            _audioQueue->inuse[i] = NO;
            [_audioQueue->lock unlock];
        }
    }
}

- (void)printAudioStreamBasicDescription:(AudioStreamBasicDescription)asbd
{
    char formatID[5];
    UInt32 mFormatID = CFSwapInt32HostToBig(asbd.mFormatID);
    bcopy (&mFormatID, formatID, 4);
    formatID[4] = '\0';
    printf("Sample Rate:         %10.0f\n",  asbd.mSampleRate);
    printf("Format ID:           %10s\n",    formatID);
    printf("Format Flags:        %10X\n",    (unsigned int)asbd.mFormatFlags);
    printf("Bytes per Packet:    %10d\n",    (unsigned int)asbd.mBytesPerPacket);
    printf("Frames per Packet:   %10d\n",    (unsigned int)asbd.mFramesPerPacket);
    printf("Bytes per Frame:     %10d\n",    (unsigned int)asbd.mBytesPerFrame);
    printf("Channels per Frame:  %10d\n",    (unsigned int)asbd.mChannelsPerFrame);
    printf("Bits per Channel:    %10d\n",    (unsigned int)asbd.mBitsPerChannel);
    printf("\n");
}

- (NSURL *)urlWithString:(NSString *)path
{
    return [NSURL URLWithString:path];
}

- (void)dealloc
{
    if (audioQueue != NULL){
        AudioQueueDispose(audioQueue,true);
        audioQueue = NULL;
    }
}

@end
