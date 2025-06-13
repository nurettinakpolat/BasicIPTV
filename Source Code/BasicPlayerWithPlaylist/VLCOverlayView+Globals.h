#import <Foundation/Foundation.h>

// Constants for slider types
#define SLIDER_TYPE_NONE 0
#define SLIDER_TYPE_TRANSPARENCY 1
#define SLIDER_TYPE_RED 2
#define SLIDER_TYPE_GREEN 3
#define SLIDER_TYPE_BLUE 4
#define SLIDER_TYPE_SUBTITLE 5

// Global variables declarations
extern BOOL isFadingOut;
extern NSTimeInterval lastFadeOutTime;
extern NSTimer *playerControlsTimer;
extern BOOL playerControlsVisible;
extern BOOL isGridViewActive; // Legacy global - will be phased out
extern NSMutableDictionary *gridLoadingQueue;
extern NSOperationQueue *coverDownloadQueue;

// Category-specific view modes
extern NSMutableDictionary *categoryViewModes; // Stores view mode for each category
extern BOOL isPersistingHoverState;
extern NSInteger lastValidHoveredChannelIndex;
extern NSInteger lastValidHoveredGroupIndex;
extern NSInteger activeSliderType;
extern NSInteger currentViewMode;
extern BOOL isStackedViewActive;

// Scroll bar globals
extern NSTimer *scrollBarFadeTimer;
extern float scrollBarAlpha; 