#import "PlatformBridge.h"
#import <VLCKit/VLCKit.h>

#if TARGET_OS_OSX
@interface VLCGLVideoView : NSOpenGLView

@property (nonatomic, retain) VLCMediaPlayer *player;

@end
#endif
