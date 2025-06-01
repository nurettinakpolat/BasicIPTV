#import "VLCOverlayView.h"
#import "VLCChannel.h"
#import "VLCProgram.h"
#import "VLCDropdownManager.h"
#import "VLCReusableTextField.h"
#import "VLCClickableLabel.h"
#import <VLCKit/VLCKit.h>

// Global progress message for loading indicator
extern NSString *gProgressMessage;
extern NSLock *gProgressMessageLock;

// Menu category indexes as a readable enum
typedef NS_ENUM(NSInteger, VLCMenuCategory) {
    CATEGORY_FAVORITES = 0,
    CATEGORY_TV = 1,
    CATEGORY_MOVIES = 2,
    CATEGORY_SERIES = 3,
    CATEGORY_SETTINGS = 4
};

// For debugging - add this helper function 
static void LogObjectType(NSString *label, id obj) {
    if (obj == nil) {
        NSLog(@"%@: nil", label);
    } else {
        NSLog(@"%@: %@ (%@)", label, [obj class], obj);
    }
}

// Private interface for VLCOverlayView
// Shared variables that can be accessed from multiple categories
extern int totalProgramCount;

@interface VLCOverlayView () <VLCReusableTextFieldDelegate, VLCClickableLabelDelegate> {
    NSTrackingArea *trackingArea;
    NSTimer *autoHideTimer;
    NSPoint lastMousePosition;
    BOOL isDragging;
    NSTimeInterval lastInteractionTime; // Track last interaction time
    BOOL isUserInteracting;             // Flag for active interaction
    
    // Scroll positions for each panel
    CGFloat categoryScrollPosition;
    CGFloat groupScrollPosition;
    CGFloat channelScrollPosition;
    
    // Which panel is being scrolled (0=none, 1=categories, 2=groups, 3=channels)
    NSInteger activeScrollPanel;
    
    // Timer for progress redraw during loading
    NSTimer *redrawTimer;
    
    // Variables for XML parsing
    NSMutableDictionary *currentEpgData;
    NSMutableDictionary *currentChannel;
    NSMutableArray *currentChannelPrograms;
    VLCProgram *currentProgram;
    NSString *currentElement;
    NSMutableString *currentText;
    
    // Thread synchronization
    NSLock *channelsLock;
    NSLock *epgDataLock;
    dispatch_queue_t serialAccessQueue;
    
    // EPG URL connection variables
    NSMutableData *receivedData;
    long long expectedBytes;
    
    // EPG XML parsing tracking variables
    int totalProgramCount;
    int totalChannelCount;
    NSTimeInterval lastProgressUpdate;
    dispatch_source_t progressTimer;
    
    // Movie info hover tracking
    NSTimer *movieInfoHoverTimer;
    NSTimeInterval lastHoverTime;
    NSInteger lastHoveredChannelIndex;
    
    // Cursor hiding tracking
    NSTimeInterval lastMouseMoveTime;
    BOOL isCursorHidden;
    
    // EPG auto-scroll tracking
    NSInteger lastAutoScrolledChannelIndex;
    BOOL hasUserScrolledEpg;
    
    // EPG program context menu tracking
    VLCProgram *rightClickedProgram;
    VLCChannel *rightClickedProgramChannel;
}

// Properly redeclare readonly properties as readwrite
@property (nonatomic, retain, readwrite) NSMutableArray *channels;
@property (nonatomic, retain, readwrite) NSMutableArray *groups;
@property (nonatomic, retain, readwrite) NSMutableDictionary *channelsByGroup;
@property (nonatomic, retain, readwrite) NSArray *categories;
@property (nonatomic, retain, readwrite) NSMutableDictionary *groupsByCategory;

// Additional private properties (not declared in public header)
@property (nonatomic, assign) CGFloat channelListWidth;
@property (nonatomic, assign) CGFloat channelRowHeight;
@property (nonatomic, assign) CGFloat maxVisibleRows;
@property (nonatomic, assign) BOOL isHovering;

// Layout properties
@property (nonatomic, assign) CGFloat categoriesWidth;
@property (nonatomic, assign) CGFloat groupsWidth;

// Simple channel lists for reliable rendering
@property (nonatomic, retain) NSArray *simpleChannelNames;
@property (nonatomic, retain) NSArray *simpleChannelUrls;

// Settings UI properties
@property (nonatomic, assign) NSRect loadButtonRect;
@property (nonatomic, assign) NSRect epgButtonRect;
@property (nonatomic, assign) NSRect m3uFieldRect;
@property (nonatomic, assign) NSRect epgFieldRect;
@property (nonatomic, assign) NSRect movieInfoRefreshButtonRect;
@property (nonatomic, assign) NSRect movieInfoProgressBarRect;
@property (nonatomic, assign) BOOL isRefreshingMovieInfo;
@property (nonatomic, assign) NSInteger movieRefreshProgress; // 0-100
@property (nonatomic, assign) NSInteger movieRefreshTotal;
@property (nonatomic, assign) NSInteger movieRefreshCompleted;
@property (nonatomic, assign) NSRect epgTimeOffsetDropdownRect;
@property (nonatomic, assign) BOOL m3uFieldActive;
@property (nonatomic, assign) BOOL epgFieldActive;
@property (nonatomic, assign) BOOL epgTimeOffsetDropdownActive;
@property (nonatomic, assign) NSInteger epgTimeOffsetDropdownHoveredIndex; // -1 = no hover
@property (nonatomic, retain) NSString *tempM3uUrl;
@property (nonatomic, retain) NSString *tempEpgUrl;
@property (nonatomic, assign) NSInteger m3uCursorPosition;
@property (nonatomic, assign) NSInteger epgCursorPosition;
@property (nonatomic, assign) NSInteger epgTimeOffsetHours; // -12 to +12 hours
@property (nonatomic, assign) NSTimer *cursorBlinkTimer;

// Dropdown Manager
@property (nonatomic, retain) VLCDropdownManager *dropdownManager;

// New UI Components
@property (nonatomic, retain) VLCReusableTextField *m3uTextField;
@property (nonatomic, retain) VLCClickableLabel *epgLabel;

// Internal utility methods
- (NSArray *)safeGroupsForCategory:(NSString *)category;
- (NSArray *)safeTVGroups;
- (NSArray *)safeValueForKey:(NSString *)key fromDictionary:(NSDictionary *)dict;
- (NSString *)channelCacheFilePath:(NSString *)sourcePath;
- (NSString *)epgCacheFilePath;
- (void)ensureFavoritesCategory;
- (void)ensureSettingsGroups;
- (void)prepareSimpleChannelLists;
- (void)markUserInteraction;
- (void)scheduleInteractionCheck;
- (BOOL)safeAddGroupToCategory:(NSString *)group category:(NSString *)category;
- (void)startProgressRedrawTimer;
- (void)stopProgressRedrawTimer;
- (void)setupTrackingArea;
- (void)ensureCursorVisible;
- (void)refreshCurrentEPGInfo;

// Hover state
@property (nonatomic, assign) NSInteger hoveredGroupIndex;
@property (nonatomic, assign) BOOL isPendingMovieInfoFetch;
@property (nonatomic, assign) BOOL isHoveringMovieInfoPanel;

// Catch-up detection methods
- (NSString *)constructLiveStreamsApiUrl;
- (void)fetchCatchupInfoFromAPI;
- (void)processCatchupInfoFromAPI:(NSArray *)apiChannels;
- (NSString *)extractStreamIdFromChannelUrl:(NSString *)urlString;
- (NSString *)generateTimeshiftUrlForChannel:(VLCChannel *)channel atTime:(NSDate *)targetTime;
- (void)autoFetchCatchupInfo;

// Channel management methods
- (void)loadChannelsFile;
- (void)playChannelWithUrl:(NSString *)urlString;
- (void)playChannelAtIndex:(NSInteger)index;
- (void)forceReloadChannelsAndEpg;

// Timeshift methods
- (NSString *)generateTimeshiftUrlForProgram:(VLCProgram *)program channel:(VLCChannel *)channel;
- (void)playTimeshiftForProgram:(VLCProgram *)program channel:(VLCChannel *)channel;
- (void)hideChannelListWithFade;
- (void)playCatchUpFromMenu:(NSMenuItem *)sender;

// Timeshift cache management methods
- (void)cacheTimeshiftChannel:(VLCChannel *)channel;
- (VLCChannel *)getCachedTimeshiftChannel;
- (void)clearCachedTimeshiftChannel;
- (void)clearCachedTimeshiftProgramInfo;
- (void)clearFrozenTimeValues;

@end 