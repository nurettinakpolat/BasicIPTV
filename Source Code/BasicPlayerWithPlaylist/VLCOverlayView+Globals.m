#import "VLCOverlayView+Globals.h"

// Global variable definitions (from the original VLCOverlayView+UI.m)
BOOL isFadingOut = NO;
NSTimeInterval lastFadeOutTime = 0;
NSTimer *playerControlsTimer = nil;
BOOL playerControlsVisible = NO; // Start with controls hidden

// Grid view and UI state variables
BOOL isGridViewActive = NO;
NSMutableDictionary *gridLoadingQueue = nil;
NSOperationQueue *coverDownloadQueue = nil;

// Hover state tracking
BOOL isPersistingHoverState = NO;
NSInteger lastValidHoveredChannelIndex = -1;
NSInteger lastValidHoveredGroupIndex = -1;

// Active slider tracking
NSInteger activeSliderType = SLIDER_TYPE_NONE;

// View mode properties
NSInteger currentViewMode = 0; // 0 = Stacked, 1 = Grid, 2 = List
BOOL isStackedViewActive = YES; // Start with stacked view

// Scroll bar variables
NSTimer *scrollBarFadeTimer = nil;
float scrollBarAlpha = 0.0; 