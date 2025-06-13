//
//  VLCUIVideoView.h
//  BasicIPTV - iOS/tvOS Video View
//
//  UIKit-based video view for iOS and tvOS
//

#import "PlatformBridge.h"

#if TARGET_OS_IOS || TARGET_OS_TV

#import <VLCKit/VLCKit.h>

@interface VLCUIVideoView : UIView

@property (nonatomic, strong) VLCMediaPlayer *player;

@end

#endif 