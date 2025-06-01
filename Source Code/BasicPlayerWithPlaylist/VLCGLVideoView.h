#import <Cocoa/Cocoa.h>
#import <VLCKit/VLCKit.h>

@interface VLCGLVideoView : NSOpenGLView

@property (nonatomic, retain) VLCMediaPlayer *player;

@end
