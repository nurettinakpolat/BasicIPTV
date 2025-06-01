#import <Cocoa/Cocoa.h>

@class VLCMediaPlayer;
@class VLCChannel;
@class VLCProgram;

// Forward declarations to avoid circular imports
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
@property (nonatomic, retain) NSColor *backgroundColor;
@property (nonatomic, retain) NSColor *hoverColor;
@property (nonatomic, retain) NSColor *textColor;
@property (nonatomic, retain) NSColor *groupColor;

// URL input
@property (nonatomic, retain) NSString *inputUrlString;
@property (nonatomic, assign) BOOL isTextFieldActive;
@property (nonatomic, retain) VLCChannel *tmpCurrentChannel;

// Main public methods
- (void)loadChannelsFromM3uFile:(NSString *)path; 
- (void)loadChannelsFile;
- (void)playChannel:(NSInteger)index;
- (void)ensureDataStructuresInitialized;

// Settings persistence methods
- (void)saveSettings;
- (void)loadSettings;

// Initialize with frame
- (id)initWithFrame:(NSRect)frame;

@end

// Import all the categories
#import "VLCOverlayView+UI.h"
#import "VLCOverlayView+ChannelManagement.h"
#import "VLCOverlayView+EPG.h"
#import "VLCOverlayView+Favorites.h"
#import "VLCOverlayView+Caching.h"
#import "VLCOverlayView+Utilities.h"
#import "VLCOverlayView+PlayerControls.h"


