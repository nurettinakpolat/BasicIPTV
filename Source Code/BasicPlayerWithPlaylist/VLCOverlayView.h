#import "PlatformBridge.h"

#if TARGET_OS_OSX

#import <Cocoa/Cocoa.h>

@class VLCMediaPlayer;
@class VLCChannel;
@class VLCProgram;

@interface VLCOverlayView : NSView

// Player instance
@property (nonatomic, retain) VLCMediaPlayer *player;

// Channel list settings
@property (nonatomic, retain) NSString *m3uFilePath;
@property (nonatomic, assign, getter=isChannelListVisible) BOOL isChannelListVisible;
@property (nonatomic, assign) NSInteger hoveredChannelIndex;
@property (nonatomic, assign) NSInteger selectedChannelIndex;

// Scroll positions
@property (nonatomic, assign) CGFloat scrollPosition;
@property (nonatomic, assign) CGFloat epgScrollPosition; // For program guide scrolling
@property (nonatomic, assign) CGFloat movieInfoScrollPosition; // For movie info scrolling

// Channel collections (read-only)
@property (nonatomic, retain, readonly) NSMutableArray *channels;
@property (nonatomic, retain, readonly) NSMutableArray *groups;
@property (nonatomic, retain, readonly) NSMutableDictionary *channelsByGroup;
@property (nonatomic, retain, readonly) NSArray *categories;
@property (nonatomic, retain, readonly) NSMutableDictionary *groupsByCategory;

// Simple channel lists for display (read-only)
@property (nonatomic, retain, readonly) NSArray *simpleChannelNames;
@property (nonatomic, retain, readonly) NSArray *simpleChannelUrls;

// EPG related
@property (nonatomic, retain) NSString *epgUrl;
@property (nonatomic, assign, getter=isEpgLoaded) BOOL isEpgLoaded;
@property (nonatomic, assign) BOOL showEpgPanel;
@property (nonatomic, assign, getter=isLoadingEpg) BOOL isLoadingEpg;
@property (nonatomic, assign) float epgLoadingProgress;
@property (nonatomic, retain) NSString *epgLoadingStatusText;
@property (nonatomic, retain) NSMutableDictionary *epgData;

// UI state
@property (nonatomic, assign, getter=isLoading) BOOL isLoading;
@property (nonatomic, assign) float loadingProgress;
@property (nonatomic, retain) NSString *loadingStatusText;
@property (nonatomic, retain) NSTimer *loadingProgressTimer;
@property (nonatomic, assign) NSInteger selectedCategoryIndex;
@property (nonatomic, assign) NSInteger selectedGroupIndex;

// UI components
@property (nonatomic, retain) PlatformColor *backgroundColor;
@property (nonatomic, retain) PlatformColor *hoverColor;
@property (nonatomic, retain) PlatformColor *textColor;
@property (nonatomic, retain) PlatformColor *groupColor;

// Selection color customization
@property (nonatomic, assign) CGFloat customSelectionRed;
@property (nonatomic, assign) CGFloat customSelectionGreen;
@property (nonatomic, assign) CGFloat customSelectionBlue;

// Selection color slider rects for interaction
@property (nonatomic, assign) PlatformRect selectionRedSliderRect;
@property (nonatomic, assign) PlatformRect selectionGreenSliderRect;
@property (nonatomic, assign) PlatformRect selectionBlueSliderRect;

// URL input
@property (nonatomic, retain) NSString *inputUrlString;
@property (nonatomic, assign) BOOL isTextFieldActive;
@property (nonatomic, retain) VLCChannel *tmpCurrentChannel;

// Arrow key navigation state
@property (nonatomic, assign) BOOL isArrowKeyNavigating;

#pragma mark - Startup Progress System (macOS)

// Startup progress window and components
@property (nonatomic, retain) NSView *startupProgressWindow;
@property (nonatomic, retain) NSTextField *startupProgressTitle;
@property (nonatomic, retain) NSTextField *startupProgressStep;
@property (nonatomic, retain) NSProgressIndicator *startupProgressBar;
@property (nonatomic, retain) NSTextField *startupProgressPercent;
@property (nonatomic, retain) NSTextField *startupProgressDetails;

// Startup progress tracking
@property (nonatomic, assign) float currentStartupProgress;
@property (nonatomic, retain) NSString *currentStartupStep;
@property (nonatomic, assign) BOOL isStartupInProgress;

// Main public methods
- (void)loadChannelsFromM3uFile:(NSString *)path; 
- (void)loadChannelsFile;
- (void)playChannel:(NSInteger)index;
- (void)ensureDataStructuresInitialized;

// Settings persistence methods
- (void)saveSettings;
- (void)loadSettings;

// Initialize with frame
- (id)initWithFrame:(PlatformRect)frame;

// Startup progress methods
- (void)showStartupProgressWindow;
- (void)hideStartupProgressWindow;
- (void)updateStartupProgress:(float)progress step:(NSString *)step details:(NSString *)details;
- (void)setStartupPhase:(NSString *)phase;

@end

// Import all the categories
#import "VLCOverlayView+UI.h"
#import "VLCOverlayView+ChannelManagement.h"
// #import "VLCOverlayView+EPG.h" - REMOVED: Old EPG system eliminated
#import "VLCOverlayView+Favorites.h"
#import "VLCOverlayView+Utilities.h"
#import "VLCOverlayView+PlayerControls.h"

#endif // TARGET_OS_OSX


