//
//  VLCUIVideoView.m
//  BasicIPTV - iOS/tvOS Video View
//
//  UIKit-based video view implementation for iOS and tvOS
//

#import "VLCUIVideoView.h"

#if TARGET_OS_IOS || TARGET_OS_TV

@implementation VLCUIVideoView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor blackColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)setPlayer:(VLCMediaPlayer *)player {
    _player = player;
    if (player) {
        [player setDrawable:self];
    }
}

@end

#endif 