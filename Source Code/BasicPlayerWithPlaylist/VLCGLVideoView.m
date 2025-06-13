#import "VLCGLVideoView.h"

#if TARGET_OS_OSX
#import <OpenGL/gl.h>

@implementation VLCGLVideoView

- (instancetype)initWithFrame:(NSRect)frame {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFAColorSize, 24,
        0
    };
    NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    self = [super initWithFrame:frame pixelFormat:pf];
    if (self) {
        // Ensure we're opaque so video shows
        self.wantsLayer = YES;
        self.layer.opaque = YES;
    }
    return self;
}

- (void)setPlayer:(VLCMediaPlayer *)player {
    _player = player;
}

@end

#endif
