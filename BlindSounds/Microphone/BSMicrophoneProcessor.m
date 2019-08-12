//
//  BSMicrophoneProcessor.m
//  BlindSounds
//
//  Created by Roma Bakenbard on 09/08/2019.
//  Copyright © 2019 Roma Bakenbard. All rights reserved.
//

#import "BSMicrophoneProcessor.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioUnit/AudioUnit.h>

#import <TPCircularBuffer+AudioBufferList.h>

#import <aubio/aubio.h>

#import <Speech/Speech.h>

#import <CoreML/CoreML.h>

@interface BSMicrophoneProcessor()

@property (strong, nonatomic) AUAudioUnit *audioUnit;

@property (assign, nonatomic) BOOL enableRecording;
@property (assign, nonatomic) BOOL audioSessionActive;
@property (assign, nonatomic) BOOL audioSetupComplete;
@property (assign, nonatomic) BOOL isRecording;

@property (assign, nonatomic) double sampleRate;

@property (nonatomic) TPCircularBuffer circularBuffer;

//@property (assign, nonatomic) int circBuffSize;
//@property (assign, nonatomic) float *circBuffer;
//@property (assign, nonatomic) int circInIdx;
//@property (assign, nonatomic) int circOutIdx;

@property (assign, nonatomic) float audioLevel;

@property (assign, nonatomic) BOOL micPermissionRequested;
@property (assign, nonatomic) BOOL micPermissionGranted;

@property (assign, nonatomic) BOOL audioInterrupted;

@property (nonatomic) AURenderBlock renderBlock;

@property (nonatomic) aubio_pvoc_t *pv;
@property (nonatomic) aubio_filterbank_t *fb;

@property (nonatomic) uint_t win_size;
@property (nonatomic) uint_t hop_size;
@property (nonatomic) uint_t n_bands;

@property (strong, nonatomic) SFSpeechRecognizer *speechRecognizer;
@property (strong, nonatomic) SFSpeechAudioBufferRecognitionRequest *request;
@property (strong, nonatomic) SFSpeechRecognitionTask *recognitionTask;

@end

@implementation BSMicrophoneProcessor

- (instancetype)init {
    if (self = [super init]) {
        self.enableRecording = YES;
        self.audioSessionActive = NO;
        self.audioSetupComplete = NO;
        self.isRecording = NO;
        
        self.sampleRate = 44100.0;      // desired audio sample rate
//        self.circBuffSize = 32768;        // lock-free circular fifo/buffer size
//        self.circBuffer = malloc(sizeof(float) * self.circBuffSize);
//        memset(self.circBuffer,0,sizeof(float) * self.circBuffSize);
//
//        self.circInIdx = 0;            // sample input  index
//        self.circOutIdx = 0;            // sample output index
        
        self.audioLevel = 0.0;
        
        self.micPermissionRequested = NO;
        self.micPermissionGranted = NO;
        
        self.audioInterrupted = NO;
        
        self.win_size=1024;
        self.hop_size=512;
        self.n_bands=40;
        
        self.pv = new_aubio_pvoc(self.win_size, self.hop_size);
        self.fb = new_aubio_filterbank(self.n_bands, self.win_size);
        aubio_filterbank_set_mel_coeffs_slaney(self.fb, self.sampleRate);
        
        self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"ru"]];
        self.request = [SFSpeechAudioBufferRecognitionRequest new];
    }
    return self;
}

- (void)startRecording {
    
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
    }];
    
    if (self.isRecording) { return; }
    
    if (self.audioSessionActive == NO) {
        // configure and activate Audio Session, this might change the sampleRate
        [self setupAudioSessionForRecording];
    }
    
    if (self.micPermissionGranted == NO || self.audioSessionActive == NO) { return; }
    
    AVAudioFormat *audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 // pcmFormatInt16, pcmFormatFloat32,
                                                                  sampleRate:self.sampleRate // 44100.0 48000.0
                                                                    channels:1 // 1 or 2
                                                                 interleaved:YES]; // true for interleaved stereo
    
    if (self.audioUnit == nil) {
        [self setupRemoteIOAudioUnitForRecord:audioFormat];
    }
    
    self.renderBlock = self.audioUnit.renderBlock;  //  returns AURenderBlock()
    
    if (   self.enableRecording
        && self.micPermissionGranted
        && self.audioSetupComplete
        && self.audioSessionActive
        && self.isRecording == NO ) {
        
        self.audioUnit.inputEnabled = YES;
        __weak __typeof(self)weakSelf = self;
        
        [self.audioUnit setInputHandler:^(AudioUnitRenderActionFlags * _Nonnull actionFlags, const AudioTimeStamp * _Nonnull timestamp, AUAudioFrameCount frameCount, NSInteger inputBusNumber) {
            
            AudioBuffer inBuffer;
            inBuffer.mNumberChannels = audioFormat.channelCount;
            inBuffer.mDataByteSize = 0;
            
            AudioBufferList buffers;
            buffers.mNumberBuffers = 1;
            buffers.mBuffers[0] = inBuffer;
            
            OSStatus status = weakSelf.renderBlock(actionFlags, timestamp, frameCount, inputBusNumber, &buffers, nil);
            if (status == noErr) {
                [weakSelf recordMicrophoneInputSamples:&buffers frameCount:frameCount];
            } else {
                NSLog(@"error %d", status);
            }
        }];
        
        NSError *error;
        
        [self _bs_freeCircularBuffer:&_circularBuffer];
        [self _bs_circularBuffer:&_circularBuffer withSize:24576*5];
        [self.audioUnit allocateRenderResourcesAndReturnError:&error];
        [self.audioUnit startHardwareAndReturnError:&error]; // equivalent to AudioOutputUnitStart ???
        self.isRecording = YES;
        
        // Analyze the speech
        self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.request resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
            if (result) {
                [self.delegate microphoneProcessor:self didRecognizeSpeach:result.bestTranscription.formattedString];
            } else {
                NSLog(@"%@", error);
            }
        }];
    }
}

- (void)stopRecording {
    
    if (self.isRecording) {
        [self.audioUnit stopHardware];
        self.isRecording = NO;
    }
    if (self.audioSessionActive) {
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        [audioSession setActive:NO error:nil];
        
        self.audioSessionActive = NO;
    }
    
    [self.recognitionTask cancel];
    [self _bs_freeCircularBuffer:&_circularBuffer];
}

- (void)recordMicrophoneInputSamples:(AudioBufferList *)inputDataList frameCount:(UInt32)frameCount {
    AVAudioFormat *audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 // pcmFormatInt16, pcmFormatFloat32,
                                                                  sampleRate:self.sampleRate // 44100.0 48000.0
                                                                    channels:1 // 1 or 2
                                                                 interleaved:YES]; // true for interleaved stereo

    AudioBuffer *pBuffer = &inputDataList->mBuffers[0];
    AVAudioPCMBuffer *outBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:audioFormat frameCapacity:pBuffer->mDataByteSize];
    outBuffer.frameLength = pBuffer->mDataByteSize / sizeof(float);
    float *pData = (float *)pBuffer->mData;
    memcpy(outBuffer.floatChannelData[0], pData, pBuffer->mDataByteSize);

    [self.request appendAudioPCMBuffer:outBuffer];
    
    
    
    TPCircularBuffer *circularBuffer = [self _bs_circularBuffer];
    [self _bs_appendDataToCircularBuffer:circularBuffer fromAudioBufferList:inputDataList];

    uint32_t availableBytes;
    float *sourceBuffer = TPCircularBufferTail(circularBuffer, &availableBytes);

    uint32_t bytesToCopy = self.hop_size;
    if (availableBytes >= bytesToCopy) {

        uint_t sampleCount = 0;

        fvec_t *samples = new_fvec(self.hop_size);

        for (int i = 0; i < bytesToCopy; i ++) {
            float x = sourceBuffer[i];   // copy left  channel sample

            fvec_set_sample(samples, x, sampleCount);
            sampleCount +=1;
        }

        cvec_t *fftgrain = new_cvec(self.win_size);
        aubio_pvoc_do(self.pv, samples, fftgrain);

        fvec_t *bands = new_fvec(self.n_bands);
        aubio_filterbank_do(self.fb, fftgrain, bands);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate microphoneProcessor:self didProcessBands:bands height:self.n_bands];
        });

        TPCircularBufferConsume(circularBuffer, bytesToCopy);
    }
}

// set up and activate Audio Session
- (void)setupAudioSessionForRecording {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    if (self.micPermissionGranted == NO) {
        if (self.micPermissionRequested == NO) {
            self.micPermissionRequested = YES;
            [audioSession requestRecordPermission:^(BOOL granted) {
                if (granted) {
                    self.micPermissionGranted = YES;
                    [self startRecording];
                } else {
                    self.enableRecording = NO;
                }
            }];
        }
        return;
    }
    
    NSError *error;
    
    if (self.enableRecording) {
        [audioSession setCategory:AVAudioSessionCategoryRecord error:&error];
    }
    double preferredIOBufferDuration = 0.0053;  // 5.3 milliseconds = 256 samples
    [audioSession setPreferredSampleRate:self.sampleRate error:&error]; // at 48000.0
    [audioSession setPreferredIOBufferDuration:preferredIOBufferDuration error:&error];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(myAudioSessionInterruptionHandler:) name:AVAudioSessionInterruptionNotification object:nil];
    
    [audioSession setActive:YES error:&error];
    self.audioSessionActive = YES;
}

// find and set up the sample format for the RemoteIO Audio Unit
- (void)setupRemoteIOAudioUnitForRecord:(AVAudioFormat*)audioFormat {
    AudioComponentDescription audioComponentDescription;
    audioComponentDescription.componentType = kAudioUnitType_Output;
    audioComponentDescription.componentSubType = kAudioUnitSubType_RemoteIO;
    audioComponentDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    audioComponentDescription.componentFlags = 0;
    audioComponentDescription.componentFlagsMask = 0;
    
    NSError *error;
    
    self.audioUnit = [[AUAudioUnit alloc] initWithComponentDescription:audioComponentDescription error:&error];
    // bus 1 is for data that the microphone exports out to the handler block
    AUAudioUnitBus *bus1 = self.audioUnit.outputBusses[self.audioUnit.outputBusses.count-1];
    [bus1 setFormat:audioFormat error:&error]; // for microphone bus
    self.audioSetupComplete = YES;
}

- (void)myAudioSessionInterruptionHandler:(NSNotification *)notification {
    NSDictionary *interuptionDict = notification.userInfo;
    NSNumber *interuptionType = interuptionDict[AVAudioSessionInterruptionTypeKey];
    if (interuptionType) {
        AVAudioSessionInterruptionType interuptionVal = interuptionType.unsignedIntegerValue;
        if (interuptionVal == AVAudioSessionInterruptionTypeBegan) {
            if (self.isRecording) {
                [self.audioUnit stopHardware];
                self.isRecording = NO;
                AVAudioSession *audioSession = [AVAudioSession sharedInstance];
                [audioSession setActive:NO error:nil];
                self.audioSessionActive = NO;
                self.audioInterrupted = YES;
            }
        } else if (interuptionVal == AVAudioSessionInterruptionTypeEnded) {
            if (self.audioInterrupted) {
                AVAudioSession *audioSession = [AVAudioSession sharedInstance];
                [audioSession setActive:YES error:nil];
                self.audioSessionActive = YES;
                if (self.audioUnit.renderResourcesAllocated == NO) {
                    [self.audioUnit allocateRenderResourcesAndReturnError:nil];
                }
                [self.audioUnit startHardwareAndReturnError:nil];
                self.isRecording = YES;
            }
        }
    }
}

-(void)_bs_circularBuffer:(TPCircularBuffer *)circularBuffer withSize:(int)size {
    TPCircularBufferInit(circularBuffer,size);
}

-(void)_bs_appendDataToCircularBuffer:(TPCircularBuffer*)circularBuffer
                  fromAudioBufferList:(AudioBufferList*)audioBufferList {
    TPCircularBufferProduceBytes(circularBuffer,
                                 audioBufferList->mBuffers[0].mData,
                                 audioBufferList->mBuffers[0].mDataByteSize);
}

-(void)_bs_freeCircularBuffer:(TPCircularBuffer *)circularBuffer {
    TPCircularBufferClear(circularBuffer);
    TPCircularBufferCleanup(circularBuffer);
}

-(TPCircularBuffer *)_bs_circularBuffer {
    return &_circularBuffer;
}

@end
