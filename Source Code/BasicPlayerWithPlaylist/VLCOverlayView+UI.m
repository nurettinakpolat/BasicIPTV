#import "VLCOverlayView+UI.h"
#import "VLCOverlayView+Drawing.h"
#import "VLCOverlayView+MouseHandling.h"
#import "VLCOverlayView+ContextMenu.h"
#import "VLCOverlayView+TextFields.h"
#import "VLCOverlayView+Search.h"
#import "VLCOverlayView+Globals.h"

// This file now serves as a bridge to include all the split functionality
// The actual implementations are in the separate category files:
// - VLCOverlayView+Drawing.m: UI setup and drawing methods
// - VLCOverlayView+MouseHandling.m: Mouse and keyboard event handling
// - VLCOverlayView+ContextMenu.m: Context menu functionality
// - VLCOverlayView+TextFields.m: Text field delegates and URL handling
// - VLCOverlayView+Search.m: Search functionality and selection persistence
// - VLCOverlayView+ViewModes.m: View mode management and stacked view drawing
// - VLCOverlayView+Globals.m: Shared global variables

@implementation VLCOverlayView (UI)

// All implementations have been moved to their respective category files
// This implementation is now empty as it serves as a coordination point

@end 
