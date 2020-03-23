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

#import <CoreML/CoreML.h>
#import "aux_skip_attention_coreml_003.h"

@interface BSModelResult : NSObject

@property (strong, nonatomic) NSString *name;
@property (assign, nonatomic) double percent;

@end
@implementation BSModelResult
@end

@interface ViewController () <BSMicrophoneProcessorDelegate>

@property (strong, nonatomic) BSMicrophoneProcessor *microphone;

@property (weak, nonatomic) IBOutlet UIImageView *imageView;
@property (weak, nonatomic) IBOutlet UITextView *textView;

@property (nonatomic) TPCircularBuffer circularBuffer;
@property (nonatomic) uint_t bandsHeight;

@property (strong, nonatomic) aux_skip_attention_coreml_003 *mlModel;
@property (strong, nonatomic) NSTimer *updateTimer;

@property (weak, nonatomic) IBOutlet UILabel *testOutputLabel;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.textView.backgroundColor = [UIColor whiteColor];
    
    [self _bs_circularBuffer:self._bs_circularBuffer withSize:256*128*sizeof(float) * 4];
    
    self.microphone = [BSMicrophoneProcessor new];
    self.microphone.delegate = self;
    [self.microphone startRecording];
    
    self.mlModel = [[aux_skip_attention_coreml_003 alloc] init];
    
    self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(_bs_processBuffer) userInfo:nil repeats:YES];
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
}

- (void)_bs_processBuffer {
    uint32_t availableBytes;
    float *sourceBuffer = TPCircularBufferTail(self._bs_circularBuffer, &availableBytes);
    availableBytes /= sizeof(float);
    
    if (availableBytes == 0 || self.bandsHeight == 0) {
        return;
    }
    int availableColumns = availableBytes/self.bandsHeight;
    
    CGFloat screenWidth = 256;
    
    if (availableColumns >= screenWidth) {
        int startColumn = 0;
        
        NSMutableArray <NSMutableArray *> *matrix = [NSMutableArray new];
        NSMutableArray *column = [NSMutableArray new];
        
        float maxValue = 0;
        float minValue = 999;
        
        for (int i = startColumn * self.bandsHeight; i < (screenWidth * self.bandsHeight); i++) {
            if (i % self.bandsHeight == 0) {
                if (column.count > 0) {
                    [matrix addObject:[NSMutableArray arrayWithArray:column]];
                }
                column = [NSMutableArray new];
            }
            
            float value = sourceBuffer[i];
            float valueLog = log10f(value)/10.0;
            
            maxValue = MAX(valueLog, maxValue);
            minValue = MIN(valueLog, minValue);
            
            [column addObject:@(valueLog)];
        }
        [matrix addObject:[NSMutableArray arrayWithArray:column]];
        
        NSMutableArray <NSMutableArray *> *transposedMatrix = [NSMutableArray new];
        NSUInteger Width = matrix.count;
        NSUInteger Height = matrix.firstObject.count;
        
        for (int i = 0; i < Height; i ++) {
            NSMutableArray *transposedColumn = [NSMutableArray new];
            for (int j = 0; j < Width; j ++) {
                [transposedColumn addObject:@([matrix[j][i] floatValue])];
            }
            [transposedMatrix addObject:transposedColumn];
        }
        
        MLMultiArrayDataType dataType = MLMultiArrayDataTypeFloat32;
        NSError *error = nil;
        
        MLMultiArray *theMultiArray =  [[MLMultiArray alloc] initWithShape:@[@1, @128, @256]
                                                                  dataType:dataType
                                                                     error:&error];
        
        NSInteger theMultiArrayIndex = 0;
        for (int row = 0; row < transposedMatrix.count; row ++) {
            NSArray *rowArray = transposedMatrix[row];
            for (int column = 0; column < rowArray.count; column ++) {
                [theMultiArray setObject:[NSNumber numberWithFloat:[rowArray[column] floatValue]] atIndexedSubscript:theMultiArrayIndex];
                theMultiArrayIndex++;
            }
        }
        
        aux_skip_attention_coreml_003Output * mlModelOutput = [self.mlModel predictionFromSpectrogram:theMultiArray error:&error];
        NSMutableArray <BSModelResult *> *results = [NSMutableArray new];
        for (NSString *outputKey in mlModelOutput.classLabelLogits.allKeys) {
            NSNumber *outputValue = mlModelOutput.classLabelLogits[outputKey];
            BSModelResult *result = [BSModelResult new];
            result.percent = 1.0 / (1.0 + exp(-outputValue.floatValue));
            result.name = outputKey;
            [results addObject:result];
        }
        
        [results sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"percent" ascending:NO]]];
        
        NSMutableString *resultString = [NSMutableString new];
        for (int i = 0; i < 3; i ++) {
            if (results.count > i) {
                [resultString appendFormat:@"%@ %.2f%%\n", results[i].name, results[i].percent * 100.0];
            }
        }
        
        if (resultString.length > 0) {
            [resultString replaceCharactersInRange:NSMakeRange(resultString.length - 1, 1) withString:@""];
        }
        
        self.testOutputLabel.text = resultString;
        
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
        
        
        TPCircularBufferConsume(self._bs_circularBuffer, (screenWidth/4.0) * self.bandsHeight * sizeof(float));
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
    completion(image);
}

#pragma mark - Circular

-(void)_bs_circularBuffer:(TPCircularBuffer *)circularBuffer withSize:(int)size {
    TPCircularBufferInit(circularBuffer,size);
}

-(void)_bs_appendDataToCircularBuffer:(TPCircularBuffer*)circularBuffer fromBands:(fvec_t *)bands {
    TPCircularBufferProduceBytes(circularBuffer, bands->data, bands->length * sizeof(bands->data[0]));
}

-(void)_bs_freeCircularBuffer:(TPCircularBuffer *)circularBuffer {
    TPCircularBufferClear(circularBuffer);
    TPCircularBufferCleanup(circularBuffer);
}

-(TPCircularBuffer *)_bs_circularBuffer {
    return &_circularBuffer;
}

@end
