//
//  ViewController.m
//  BlindSounds
//
//  Created by Roma Bakenbard on 08/08/2019.
//  Copyright © 2019 Roma Bakenbard. All rights reserved.
//

#import "ViewController.h"

#import "BSMicrophoneProcessor.h"

#import <TPCircularBuffer+AudioBufferList.h>

@interface ViewController () <BSMicrophoneProcessorDelegate>

@property (strong, nonatomic) BSMicrophoneProcessor *microphone;

@property (weak, nonatomic) IBOutlet UIImageView *imageView;
@property (weak, nonatomic) IBOutlet UITextView *textView;

@property (nonatomic) TPCircularBuffer circularBuffer;
@property (nonatomic) uint_t bandsHeight;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self _bs_circularBuffer:self._bs_circularBuffer withSize:24576*5];
    
    self.microphone = [BSMicrophoneProcessor new];
    self.microphone.delegate = self;
    [self.microphone startRecording];
    
    
//    NSString *path = [[NSBundle mainBundle] pathForResource:@"27d43eba" ofType:@"wav"];
//    [self getMelbandsForFilePath:path];
//    [self getMFCCForFilePath:path];
}

- (void)getMelbandsForFilePath:(NSString *)filePath {
    // from https://github.com/aubio/aubio/issues/206
    // Spectrogram parameters
    uint_t samplerate=44100;
    uint_t win_size=1024;
    uint_t hop_size=512;
    uint_t n_bands=40;
    
    aubio_source_t *src = new_aubio_source([filePath UTF8String], 0, hop_size); // source file
    samplerate = aubio_source_get_samplerate(src);
    
    aubio_pvoc_t *pv = new_aubio_pvoc(win_size, hop_size);
    aubio_filterbank_t *fb = new_aubio_filterbank(n_bands, win_size);
    aubio_filterbank_set_mel_coeffs_slaney(fb, samplerate);
    
    uint_t read = 0;
    while (YES) {
        fvec_t *samples = new_fvec(hop_size);
        aubio_source_do(src, samples, &read); // read file
        
        cvec_t *fftgrain = new_cvec(win_size);
        aubio_pvoc_do(pv, samples, fftgrain);
        
        fvec_t *bands = new_fvec(n_bands);
        aubio_filterbank_do(fb, fftgrain, bands);
        
        fvec_print(bands);
        
        if (read < hop_size) {
            break;
        }
    }
}

- (void)getMFCCForFilePath:(NSString *)filePath {
    // https://github.com/aubio/aubio/blob/master/examples/utils.c
    uint_t samplerate=44100;
    uint_t hop_size = 256;
    uint_t buffer_size  = 512;
    uint_t n_filters = 40;
    uint_t n_coefs = 13;
    
    aubio_source_t *src = new_aubio_source([filePath UTF8String], 0, hop_size); // source file
    samplerate = aubio_source_get_samplerate(src);
    
    aubio_pvoc_t *pv = new_aubio_pvoc (buffer_size, hop_size);    // a phase vocoder
    cvec_t *fftgrain = new_cvec (buffer_size);    // outputs a spectrum
    aubio_mfcc_t *mfcc = new_aubio_mfcc(buffer_size, n_filters, n_coefs, samplerate); // which the mfcc will process
    fvec_t *mfcc_out = new_fvec(n_coefs);   // to get the output coefficients
    
    uint_t read = 0;
    
    fvec_t *input_buffer = new_fvec (hop_size);
    fvec_t *output_buffer = new_fvec (hop_size);
    
    while (YES) {
        aubio_source_do (src, input_buffer, &read);
        
        fvec_zeros(output_buffer);
        //compute mag spectrum
        aubio_pvoc_do (pv, input_buffer, fftgrain);
        //compute mfccs
        aubio_mfcc_do(mfcc, fftgrain, mfcc_out);
        fvec_print (mfcc_out);
        
        if (read != hop_size) {
            break;
        }
    }
}

#pragma mark - BSMicrophoneProcessorDelegate

- (void)microphoneProcessor:(BSMicrophoneProcessor *)processor didRecognizeSpeach:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textView.text = text;
    });
}

- (void)microphoneProcessor:(BSMicrophoneProcessor *)processor didProcessBands:(fvec_t *)bands height:(uint_t)height {
    self.bandsHeight = height;
    [self _bs_appendDataToCircularBuffer:self._bs_circularBuffer fromBands:bands];
    
    uint32_t availableBytes;
    float *sourceBuffer = TPCircularBufferTail(self._bs_circularBuffer, &availableBytes);
    int availableColumns = availableBytes/self.bandsHeight;
    
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    
    if (availableColumns > screenWidth) {
        int startColumn = 0;
        
        NSMutableArray *matrix = [NSMutableArray new];
        NSMutableArray *column = [NSMutableArray new];
        
        float maxValue = 0;
        float minValue = 999;
        
        for (int i = startColumn * self.bandsHeight; i < availableBytes; i++) {
            if (i % self.bandsHeight == 0) {
                if (column.count > 0) {
                    [matrix addObject:[NSMutableArray arrayWithArray:column]];
                }
                column = [NSMutableArray new];
            }
            
            float value = sourceBuffer[i];
            maxValue = MAX(value, maxValue);
            minValue = MIN(value, minValue);
            
            [column addObject:@(value)];
        }
        [matrix addObject:[NSMutableArray arrayWithArray:column]];
        
        float scope = (maxValue - minValue);
        
        // Normalize matrix
        for (int i = 0; i < matrix.count; i++) {
            NSMutableArray *matrixColumn = matrix[i];
            for (int j = 0; j < matrixColumn.count; j ++) {
                float value = [matrixColumn[j] floatValue];
                
                float diff = (value - minValue);
                float normalValue;
                
                if(diff != 0.0) {
                    normalValue = diff / scope;
                } else {
                    normalValue = 0.0f;
                }
                [matrixColumn replaceObjectAtIndex:j withObject:@(normalValue)];
            }
        }
        
        [self createImageWithMatrix:matrix completion:^(UIImage *image) {
            self.imageView.image = image;
        }];
        TPCircularBufferConsume(self._bs_circularBuffer, availableColumns * self.bandsHeight);
    }
}

- (void)createImageWithMatrix:(NSArray <NSArray *> *)matrix completion:(void(^)(UIImage *image))completion {
        const size_t Width = matrix.count;
        const size_t Height = matrix.firstObject.count;
        const size_t Area = Width * Height;
        const size_t ComponentsPerPixel = 4; // rgba
        
        uint8_t pixelData[Area * ComponentsPerPixel];
        
        size_t offset = 0;
        for (int i = 0; i < Height; i ++) {
            for (int j = 0; j < Width; j ++) {
                float value = [matrix[j][i] floatValue];
                pixelData[offset] = 0;
                pixelData[offset+1] = 255.0 * value;
                pixelData[offset+2] = 0;
                pixelData[offset+3] = UINT8_MAX; // opaque
                offset += ComponentsPerPixel;
            }
        }
        
        // create the bitmap context:
        const size_t BitsPerComponent = 8;
        const size_t BytesPerRow=((BitsPerComponent * Width) / 8) * ComponentsPerPixel;
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef gtx = CGBitmapContextCreate(&pixelData[0], Width, Height, BitsPerComponent, BytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast);
        
        // create the image:
        CGImageRef toCGImage = CGBitmapContextCreateImage(gtx);
        UIImage * image = [[UIImage alloc] initWithCGImage:toCGImage];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(image);
        });
}

#pragma mark - Circular

-(void)_bs_circularBuffer:(TPCircularBuffer *)circularBuffer withSize:(int)size {
    TPCircularBufferInit(circularBuffer,size);
}

-(void)_bs_appendDataToCircularBuffer:(TPCircularBuffer*)circularBuffer fromBands:(fvec_t *)bands {
    TPCircularBufferProduceBytes(circularBuffer, bands->data, bands->length);
}

-(void)_bs_freeCircularBuffer:(TPCircularBuffer *)circularBuffer {
    TPCircularBufferClear(circularBuffer);
    TPCircularBufferCleanup(circularBuffer);
}

-(TPCircularBuffer *)_bs_circularBuffer {
    return &_circularBuffer;
}

@end
