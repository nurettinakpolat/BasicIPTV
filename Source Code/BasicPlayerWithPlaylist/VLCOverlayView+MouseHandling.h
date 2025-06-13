#import "VLCOverlayView.h"
#import "PlatformBridge.h"

#if TARGET_OS_OSX

@interface VLCOverlayView (MouseHandling)

// Mouse handling
- (void)mouseDown:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)mouseEntered:(NSEvent *)event;
- (void)rightMouseDown:(NSEvent *)event;
- (void)mouseMoved:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;

// User interface helpers
- (void)setViewState:(NSInteger)state;
- (void)updateCursorRects;
- (BOOL)handleClickAtPoint:(NSPoint)point;
- (NSInteger)simpleChannelIndexAtPoint:(NSPoint)point;
- (NSInteger)categoryIndexAtPoint:(NSPoint)point;
- (NSInteger)groupIndexAtPoint:(NSPoint)point;

// Dropdown handling
- (void)handleDropdownHover:(NSPoint)point;

@end 

#endif // TARGET_OS_OSX 
