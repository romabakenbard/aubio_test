//
//  ViewController.m
//  BlindSounds
//
//  Created by Roma Bakenbard on 08/08/2019.
//  Copyright © 2019 Roma Bakenbard. All rights reserved.
//

#import "ViewController.h"

#import <aubio/aubio.h>

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    NSString *path = [[NSBundle mainBundle] pathForResource:@"27d43eba" ofType:@"wav"];
//    [self getMelbandsForFilePath:path];
    [self getMFCCForFilePath:path];
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


@end
