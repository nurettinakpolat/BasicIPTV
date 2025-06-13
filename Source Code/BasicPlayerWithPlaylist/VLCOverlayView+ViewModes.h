#import "VLCOverlayView.h"

#if TARGET_OS_OSX

@interface VLCOverlayView (ViewModes)

// Stacked view drawing
- (void)drawStackedView:(NSRect)rect;

// View mode calculation methods
- (NSRange)calculateVisibleChannelRange;

// View mode preferences (currently empty but reserved for future expansion)

@end

#endif // TARGET_OS_OSX 