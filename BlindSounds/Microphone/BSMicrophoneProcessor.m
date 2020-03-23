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

#import "source_wavread.h"
#import "ioutils.h"

#import <TPCircularBuffer+AudioBufferList.h>

#import <Speech/Speech.h>

#import <CoreML/CoreML.h>


typedef void (*aubio_source_do_t)(aubio_source_t * s, fvec_t * data, uint_t * read);
typedef void (*aubio_source_do_multi_t)(aubio_source_t * s, fmat_t * data, uint_t * read);
typedef uint_t (*aubio_source_get_samplerate_t)(aubio_source_t * s);
typedef uint_t (*aubio_source_get_channels_t)(aubio_source_t * s);
typedef uint_t (*aubio_source_get_duration_t)(aubio_source_t * s);
typedef uint_t (*aubio_source_seek_t)(aubio_source_t * s, uint_t seek);
typedef uint_t (*aubio_source_close_t)(aubio_source_t * s);
typedef void (*del_aubio_source_t)(aubio_source_t * s);
struct _aubio_source_t {
  void *source;
  aubio_source_do_t s_do;
  aubio_source_do_multi_t s_do_multi;
  aubio_source_get_samplerate_t s_get_samplerate;
  aubio_source_get_channels_t s_get_channels;
  aubio_source_get_duration_t s_get_duration;
  aubio_source_seek_t s_seek;
  aubio_source_close_t s_close;
  del_aubio_source_t s_del;
};

struct _aubio_source_wavread_t {
  uint_t hop_size;
  uint_t samplerate;
  uint_t channels;

  // some data about the file
  char_t *path;
  uint_t input_samplerate;
  uint_t input_channels;

  // internal stuff
  FILE *fid;

  uint_t read_samples;
  uint_t blockalign;
  uint_t bitspersample;
  uint_t read_index;
  uint_t eof;

  uint_t duration;

  size_t seek_start;

  unsigned char *short_output;
  fmat_t *output;
};


/** phasevocoder internal object */
struct _aubio_pvoc_t {
  uint_t win_s;       /** grain length */
  uint_t hop_s;       /** overlap step */
  aubio_fft_t * fft;  /** fft object */
  fvec_t * data;      /** current input grain, [win_s] frames */
  fvec_t * dataold;   /** memory of past grain, [win_s-hop_s] frames */
  fvec_t * synth;     /** current output grain, [win_s] frames */
  fvec_t * synthold;  /** memory of past grain, [win_s-hop_s] frames */
  fvec_t * w;         /** grain window [win_s] */
  uint_t start;       /** where to start additive synthesis */
  uint_t end;         /** where to end it */
  smpl_t scale;       /** scaling factor for synthesis */
  uint_t end_datasize;  /** size of memory to end */
  uint_t hop_datasize;  /** size of memory to hop_s */
};

struct _aubio_filterbank_t
{
  uint_t win_s;
  uint_t n_filters;
  fmat_t *filters;
  smpl_t norm;
  smpl_t power;
};

@interface BSMicrophoneProcessor()

@property (strong, nonatomic) AUAudioUnit *audioUnit;

@property (assign, nonatomic) BOOL enableRecording;
@property (assign, nonatomic) BOOL audioSessionActive;
@property (assign, nonatomic) BOOL audioSetupComplete;
@property (assign, nonatomic) BOOL isRecording;

@property (assign, nonatomic) smpl_t sampleRate;

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
@property (nonatomic) smpl_t min_freq;
@property (nonatomic) smpl_t max_freq;
@property (nonatomic) uint_t pvEndDump;
@property (nonatomic) uint_t frameNumber;
@property (nonatomic) uint_t realFrameNumber;


@property (nonatomic) aubio_source_t* audioFile;

@property (nonatomic) int wavreadSizeBuffer;

//@property (strong, nonatomic) SFSpeechRecognizer *speechRecognizer;
//@property (strong, nonatomic) SFSpeechAudioBufferRecognitionRequest *request;
//@property (strong, nonatomic) SFSpeechRecognitionTask *recognitionTask;

@end

@implementation BSMicrophoneProcessor

- (instancetype)init {
    if (self = [super init]) {
        self.enableRecording = YES;
        self.audioSessionActive = NO;
        self.audioSetupComplete = NO;
        self.isRecording = NO;
        
        self.audioLevel = 0.0;
        
        self.micPermissionRequested = NO;
        self.micPermissionGranted = NO;
        
        self.audioInterrupted = NO;
        
        self.frameNumber = 0;
        self.sampleRate = 44100.0;
        self.win_size=2560;
        self.hop_size=690;
        self.n_bands=128;
        self.min_freq = 20.0;
        self.max_freq = self.sampleRate / 2.0;
        
        self.pv = new_aubio_pvoc(self.win_size, self.hop_size);
        self.fb = new_aubio_filterbank(self.n_bands, self.win_size);
        
        self.pvEndDump = self.pv->end;
        
        [self _hw_calculateMelFilterBank];
        
//        self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"ru"]];
//        self.request = [SFSpeechAudioBufferRecognitionRequest new];
        
//        [self prepareFile];
    }
    return self;
}

- (void)startRecording {
    
    
//    NSMutableString *line = [NSMutableString new];
//    do {
//        fvec_t *samples = [self getFileSamples];
//        fvec_t *result = [self processFrame:samples];
//        for (int i = 0; i < result->length; i++) {
//            [line appendFormat:@"%.8f ", result->data[i]];
//        }
//        [line appendString:@"\n"];
//    } while (self.realFrameNumber != self.frameNumber);
//    
//    NSLog(@"FILE: %@", line);
    
    
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
                                                                 interleaved:NO]; // true for interleaved stereo
    
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
                NSLog(@"error %d", (int)status);
            }
        }];
        
        NSError *error;
        
        [self _bs_freeCircularBuffer:&_circularBuffer];
        [self _bs_circularBuffer:&_circularBuffer withSize:self.sampleRate*5];
        [self.audioUnit allocateRenderResourcesAndReturnError:&error];
        [self.audioUnit startHardwareAndReturnError:&error]; // equivalent to AudioOutputUnitStart ???
        self.isRecording = YES;
        
//        // Analyze the speech
//        self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.request resultHandler:^(SFSpeechRecognitionResult * _Nullable result, NSError * _Nullable error) {
//            if (result) {
//                [self.delegate microphoneProcessor:self didRecognizeSpeach:result.bestTranscription.formattedString];
//            } else {
//                NSLog(@"%@", error);
//            }
//        }];
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
    
//    [self.recognitionTask cancel];
    [self _bs_freeCircularBuffer:&_circularBuffer];
}

- (void)recordMicrophoneInputSamples:(AudioBufferList *)inputDataList frameCount:(UInt32)frameCount {
    AVAudioFormat *audioFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 // pcmFormatInt16, pcmFormatFloat32,
                                                                  sampleRate:self.sampleRate // 44100.0 48000.0
                                                                    channels:1 // 1 or 2
                                                                 interleaved:NO]; // true for interleaved stereo
    
    AudioBuffer *pBuffer = &inputDataList->mBuffers[0];
    AVAudioPCMBuffer *outBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:audioFormat frameCapacity:pBuffer->mDataByteSize];
    outBuffer.frameLength = pBuffer->mDataByteSize / sizeof(float);
    float *pData = (float *)pBuffer->mData;
    memcpy(outBuffer.floatChannelData[0], pData, pBuffer->mDataByteSize);
    
//    [self.request appendAudioPCMBuffer:outBuffer];
    
    
    
    TPCircularBuffer *circularBuffer = [self _bs_circularBuffer];
    [self _bs_appendDataToCircularBuffer:circularBuffer fromAudioBufferList:inputDataList];
    
    uint32_t availableBytes;
    float *sourceBuffer = TPCircularBufferTail(circularBuffer, &availableBytes);
    availableBytes/=sizeof(float);
    
    //    if (availableBytes >= self.sampleRate * 4) {
    
    //        NSMutableString *textAudio = [NSMutableString new];
    //        for (int i = 0; i < self.sampleRate * 4; i ++) {
    //            [textAudio appendFormat:@"%f ", sourceBuffer[i]];
    //        }
    //
    //        NSLog(@"AUDIO\n%@", textAudio);
    
    uint32_t bytesToCopy = self.hop_size;
    //first time we should read 512, after 690
    if (_frameNumber == 0) {
        bytesToCopy = self.win_size / 2;
    }
    
    while (availableBytes >= bytesToCopy) {
        
        uint_t sampleCount = 0;
        
        fvec_t *samples = new_fvec(bytesToCopy);
        
        for (int i = 0; i < bytesToCopy; i ++) {
            float x = sourceBuffer[i];   // copy left  channel sample
            
            fvec_set_sample(samples, x, sampleCount);
            sampleCount +=1;
        }
        
        fvec_t *bands = [self processFrame:samples];
        
//        cvec_t *fftgrain = new_cvec(self.win_size);
//        aubio_pvoc_do(self.pv, samples, fftgrain);
//
//        fvec_t *bands = new_fvec(self.n_bands);
//        aubio_filterbank_do(self.fb, fftgrain, bands);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate microphoneProcessor:self didProcessBands:bands height:self.n_bands];
        });
        
        TPCircularBufferConsume(circularBuffer, bytesToCopy * sizeof(float));
        
        sourceBuffer = TPCircularBufferTail(circularBuffer, &availableBytes);
        availableBytes/=sizeof(float);
    }
    //    }
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
    //    double preferredIOBufferDuration = 0.5;  // секунд
    [audioSession setPreferredSampleRate:self.sampleRate error:&error]; // at 48000.0
    //    [audioSession setPreferredIOBufferDuration:preferredIOBufferDuration error:&error];
    
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

#pragma mark - Processing

- (fvec_t *)processFrame:(fvec_t *)input {
    cvec_t *fftgrain = new_cvec(self.win_size);

    int end = self.pvEndDump;
    int hopSize = self.hop_size;
    //we should set end to win_size / 2 for first index to get 512 - 512 for first frame
    if (self.frameNumber == 0) {
        end = self.win_size / 2;
        hopSize = self.win_size / 2;
    }
    [self pvocInputProcessingInput:input fftGrain:fftgrain end:end hopSize:hopSize];
    fvec_t *bands = new_fvec(self.n_bands);
    {
        fvec_t tmp;
        tmp.length = fftgrain->length;
        tmp.data = fftgrain->norm;

        if (_fb->power != 1.) fvec_pow(&tmp, _fb->power);

        for (int i = 0; i < bands->length; i++)
            bands->data[i] = 0;

        for (int j = 0; j < _fb->filters->height; j++) {
            for (int k = 0; k < _fb->filters->length; k++) {
                smpl_t audioData = (&tmp)->data[k];
                smpl_t melband = _fb->filters->data[j][k];
                bands->data[j] += audioData * melband;
            }
        }
    }

    _frameNumber++;
    
    return bands;
}

- (void)pvocInputProcessingInput:(fvec_t *)dataNew fftGrain:(cvec_t *)fftGrain end:(int)end hopSize:(int)hopSize {
    //first of all we have to add win_length / 2 piece of data to the beggining and to the end of pv->data
    /* slide  */
    smpl_t * data = self.pv->data->data;
    smpl_t * dataold = self.pv->dataold->data;
    if (self.frameNumber == 0) {
        for (int i = 1; i < end + 1; i++)
            data[i] = 0;// datanew1[end - 1 - i]; //should assign reverse of datanew
    }
    else {
        for (int i = 0; i < end; i++)
            data[i] = dataold[i];
    }

    //last frame, we should read rest and add zero to win_s
    if (dataNew->length < self.hop_size) {
        for (int i = 0; i < dataNew->length; i++)
            data[end + i] = dataNew->data[i];

        //allign to _winSize with zeros
        for (int i = 0; i < self.win_size - (end + dataNew->length); i++)
            data[end + i] = 0;
    }
    else {
        for (int i = 0; i < hopSize; i++)
            data[end + i] = dataNew->data[i];
    }

    if (_frameNumber == 0) {
        for (int i = 0; i < self.pv->dataold->length; i++) {
            dataold[i] = data[i + end + hopSize - self.pv->dataold->length];
        }
    }
    else {
        for (int i = 0; i < end; i++) {
            dataold[i] = data[i + self.pv->hop_s];
        }
    }
    /*```````````````````````````````````````*/
    /* windowing */
    fvec_weight(self.pv->data, self.pv->w);
    /* fft */
    aubio_fft_do(self.pv->fft, self.pv->data, fftGrain);
    for (int i = 0; i < fftGrain->length; i++)
        fftGrain->norm[i] = pow(fftGrain->norm[i], 2);
}

#pragma mark - Mel Freq

- (smpl_t)_hw_aubio_hztomel:(smpl_t)freq {
    const smpl_t lin_space = 3./200.;
    const smpl_t split_hz = 1000.;
    const smpl_t split_mel = split_hz * lin_space;
    const smpl_t log_space = 27./log(6400/1000.);
    if (freq < 0) {
        NSLog(@"hztomel: input frequency should be >= 0\n");
        return 0;
    }
    if (freq < split_hz)
    {
        return freq * lin_space;
    } else {
        return split_mel + log_space * log (freq / split_hz);
    }
}

- (smpl_t)_hw_aubio_meltohz:(smpl_t)mel {
    const smpl_t lin_space = 200./3.;
    const smpl_t split_hz = 1000.;
    const smpl_t split_mel = split_hz / lin_space;
    const smpl_t logSpacing = pow(6400/1000., 1/27.);
    if (mel < 0) {
        NSLog(@"meltohz: input mel should be >= 0\n");
        return 0;
    }
    if (mel < split_mel) {
        return lin_space * mel;
    } else {
        return split_hz * pow(logSpacing, mel - split_mel);
    }
}

- (void)_hw_calculateMelFilterBank {
    uint_t m;
    smpl_t start = self.min_freq, end = self.max_freq, step;
    fvec_t *freqs;
    fmat_t *coeffs = aubio_filterbank_get_coeffs(self.fb);
    uint_t n_bands = coeffs->height;
    
    start = [self _hw_aubio_hztomel:start];
    end = [self _hw_aubio_hztomel:end];
    
    freqs = new_fvec(n_bands + 2);
    step = (end - start) / (n_bands + 1);
    
    for (m = 0; m < n_bands + 2; m++)
    {
        freqs->data[m] = MIN([self _hw_aubio_meltohz:start + step * m], self.sampleRate / 2.);
    }
    
//    aubio_filterbank_set_triangle_bands(self.fb, freqs, self.sampleRate);
    
    fmat_t *filters = aubio_filterbank_get_coeffs(_fb);
    uint_t n_filters = filters->height, win_s = filters->length;
    fvec_t *lower_freqs, *upper_freqs, *center_freqs;
    fvec_t *triangle_heights, *fft_freqs;
    uint_t fn;                    /* filter counter */
    uint_t bin;                   /* bin counter */

    double riseInc, downInc;

    /* freqs define the bands of triangular overlapping windows.
     throw a warning if filterbank object fb is too short. */

    /* convenience reference to lower/center/upper frequency for each triangle */
    lower_freqs = new_fvec(n_filters);
    upper_freqs = new_fvec(n_filters);
    center_freqs = new_fvec(n_filters);

    /* height of each triangle */
    triangle_heights = new_fvec(n_filters);

    /* lookup table of each bin frequency in hz */
    fft_freqs = new_fvec(win_s);

    /* fill up the lower/center/upper */
    for (fn = 0; fn < n_filters; fn++) {
        lower_freqs->data[fn] = freqs->data[fn];
        center_freqs->data[fn] = freqs->data[fn + 1];
        upper_freqs->data[fn] = freqs->data[fn + 2];
    }

    /* compute triangle heights so that each triangle has unit area */
    if (self.fb->norm) {
        for (fn = 0; fn < n_filters; fn++) {
            triangle_heights->data[fn] = 2. / (upper_freqs->data[fn] - lower_freqs->data[fn]);
        }
    }
    else {
        fvec_ones(triangle_heights);
    }

    /* fill fft_freqs lookup table, which assigns the frequency in hz to each bin */
    for (bin = 0; bin < win_s; bin++) {
        fft_freqs->data[bin] =
        aubio_bintofreq(bin, self.sampleRate, (win_s - 1) * 2);
    }

    /* zeroing of all filters */
    fmat_zeros(filters);

    /* building each filter table */
    for (fn = 0; fn < n_filters; fn++) {

        /* skip first elements */
        for (bin = 0; bin < win_s - 1; bin++) {
            if (fft_freqs->data[bin] <= lower_freqs->data[fn] &&
                fft_freqs->data[bin + 1] > lower_freqs->data[fn]) {
                bin++;
                break;
            }
        }

        /* compute positive slope step size */
        riseInc = triangle_heights->data[fn]
        / (center_freqs->data[fn] - lower_freqs->data[fn]);
        /* compute negative slope step size */
        downInc = triangle_heights->data[fn]
        / (upper_freqs->data[fn] - center_freqs->data[fn]);
        /* compute coefficients in positive slope */
        for (; bin < win_s - 1; bin++) {

            smpl_t positiveSlope = (fft_freqs->data[bin] - lower_freqs->data[fn]) * riseInc;
            smpl_t negativeSlope = (upper_freqs->data[fn] - fft_freqs->data[bin]) * downInc;

            filters->data[fn][bin] = MAX(0., MIN(positiveSlope, negativeSlope));

            if (fft_freqs->data[bin + 1] >= center_freqs->data[fn]) {
                bin++;
                break;
            }
        }

        /* compute coefficents in negative slope */
        for (; bin < win_s - 1; bin++) {
            smpl_t positiveSlope = (fft_freqs->data[bin] - lower_freqs->data[fn]) * riseInc;
            smpl_t negativeSlope = (upper_freqs->data[fn] - fft_freqs->data[bin]) * downInc;

            filters->data[fn][bin] = MAX(0., MIN(positiveSlope, negativeSlope));

            if (fft_freqs->data[bin + 1] >= upper_freqs->data[fn])
                break;
        }
        /* nothing else to do */
    }
    /* destroy temporarly allocated vectors */
    del_fvec(lower_freqs);
    del_fvec(upper_freqs);
    del_fvec(center_freqs);

    del_fvec(triangle_heights);
    del_fvec(fft_freqs);

    aubio_filterbank_set_coeffs(_fb, filters);
}

#pragma mark - File

- (void)prepareFile {
    self.wavreadSizeBuffer = 2048;
    NSString* filePath = [[NSBundle mainBundle] pathForResource:@"27d43eba" ofType:@"wav"];
    
    self.audioFile = new_aubio_source(filePath.UTF8String, 0, self.hop_size); // source file
    aubio_source_wavread_t *src = (aubio_source_wavread_t*)(self.audioFile->source);
    self.realFrameNumber = (src->duration / self.hop_size) + 1;
    //need to reinit with different size
    if (src->short_output) free(src->short_output);
    if (src->output) del_fmat(src->output);
    src->output = new_fmat(src->input_channels, _wavreadSizeBuffer);
    src->short_output = (unsigned char *)calloc(src->blockalign, _wavreadSizeBuffer);
}

- (fvec_t *)getFileSamples {
    aubio_source_wavread_t *src = (aubio_source_wavread_t*)(self.audioFile->source);
    fvec_t *samples;
    int hopSize;
    int readFrames;
    //first time we should read 512, after 690
    if (self.frameNumber == 0) {
        hopSize = self.win_size / 2;
        readFrames = self.win_size / 2;

        samples = new_fvec(self.win_size / 2);
    }
    else {
        readFrames = _wavreadSizeBuffer;
        hopSize = self.hop_size;

        samples = new_fvec(hopSize);
    }

    uint_t i, j;
    uint_t end = 0;
    uint_t total_wrote = 0;
    uint_t length = aubio_source_validate_input_length("source_wavread", src->path,
        hopSize, samples->length);
    while (total_wrote < length) {
        end = MIN(src->read_samples - src->read_index, length - total_wrote);
        for (i = 0; i < end; i++) {
            samples->data[i + total_wrote] = 0;
            for (j = 0; j < src->input_channels; j++) {
                samples->data[i + total_wrote] += src->output->data[j][i + src->read_index];
            }
            samples->data[i + total_wrote] /= (smpl_t)(src->input_channels);
        }
        total_wrote += end;
        if (total_wrote < length) {
            uint_t wavread_read = 0;
            [self readWavFromSrc:src wavread_read:&wavread_read];
            src->read_samples = wavread_read;
            src->read_index = 0;
            if (src->eof) {
                break;
            }
        }
        else {
            src->read_index += end;
        }
    }

    if (total_wrote == 0) {
        return new_fvec(1);
    } else if (total_wrote < samples->length) {
        //allignment
        memset(samples->data + total_wrote, 0,
            (samples->length - total_wrote) * sizeof(smpl_t));
    }

    return samples;
}

- (void)readWavFromSrc:(aubio_source_wavread_t *)s wavread_read:(uint_t *)wavread_read {
    unsigned char *short_ptr = s->short_output;
    uint_t read = (uint_t)fread(short_ptr, s->blockalign, _wavreadSizeBuffer, s->fid);
    uint_t i, j, b, bitspersample = s->bitspersample;
    uint_t wrap_at = (1 << (bitspersample - 1));
    uint_t wrap_with = (1 << bitspersample);
    smpl_t scaler = 1. / wrap_at;
    int signed_val = 0;
    unsigned int unsigned_val = 0;
    for (j = 0; j < read; j++) {
        for (i = 0; i < s->input_channels; i++) {
            unsigned_val = 0;
            for (b = 0; b < bitspersample; b += 8) {
                unsigned_val += *(short_ptr) << b;
                short_ptr++;
            }
            signed_val = unsigned_val;
            // FIXME why does 8 bit conversion maps [0;255] to [-128;127]
            // instead of [0;127] to [0;127] and [128;255] to [-128;-1]
            if (bitspersample == 8) signed_val -= wrap_at;
            else if (unsigned_val >= wrap_at) signed_val = unsigned_val - wrap_with;
            s->output->data[i][j] = signed_val * scaler;
        }
    }

    *wavread_read = read;

    if (read == 0) {
        s->eof = 1;
    }
}

@end
