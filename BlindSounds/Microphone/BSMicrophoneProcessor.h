//
//  BSMicrophoneProcessor.h
//  BlindSounds
//
//  Created by Roma Bakenbard on 09/08/2019.
//  Copyright © 2019 Roma Bakenbard. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "aubio.h"

@class BSMicrophoneProcessor;
@protocol BSMicrophoneProcessorDelegate <NSObject>

- (void)microphoneProcessor:(BSMicrophoneProcessor *)processor didRecognizeSpeach:(NSString *)text;
- (void)microphoneProcessor:(BSMicrophoneProcessor *)processor didProcessBands:(fvec_t *)bands height:(uint_t)height;

@end

@interface BSMicrophoneProcessor : NSObject

@property (weak, nonatomic) id <BSMicrophoneProcessorDelegate> delegate;

- (void)startRecording;
- (void)stopRecording;

@end
