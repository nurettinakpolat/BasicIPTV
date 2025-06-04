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
    CATEGORY_SEARCH = 0,
    CATEGORY_FAVORITES = 1,
    CATEGORY_TV = 2,
    CATEGORY_MOVIES = 3,
    CATEGORY_SERIES = 4,
    CATEGORY_SETTINGS = 5
};

// Theme system enums
typedef NS_ENUM(NSInteger, VLCColorTheme) {
    VLC_THEME_DARK = 0,         // Default dark theme
    VLC_THEME_DARKER = 1,       // Even darker theme
    VLC_THEME_BLUE = 2,         // Blue accent theme
    VLC_THEME_GREEN = 3,        // Green accent theme
    VLC_THEME_PURPLE = 4,       // Purple accent theme
    VLC_THEME_CUSTOM = 5        // User custom colors
};

typedef NS_ENUM(NSInteger, VLCTransparencyLevel) {
    VLC_TRANSPARENCY_OPAQUE = 0,     // 0.95 alpha
    VLC_TRANSPARENCY_LIGHT = 1,      // 0.85 alpha
    VLC_TRANSPARENCY_MEDIUM = 2,     // 0.75 alpha
    VLC_TRANSPARENCY_HIGH = 3,       // 0.65 alpha
    VLC_TRANSPARENCY_VERY_HIGH = 4   // 0.5 alpha
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
    
    // Performance optimization timers
    NSTimer *movieInfoDebounceTimer;
    NSTimer *displayUpdateTimer;
    
    // Cursor hiding tracking
    NSTimeInterval lastMouseMoveTime;
    BOOL isCursorHidden;
    
    // EPG auto-scroll tracking
    NSInteger lastAutoScrolledChannelIndex;
    BOOL hasUserScrolledEpg;
    
    // EPG program context menu tracking
    VLCProgram *rightClickedProgram;
    VLCChannel *rightClickedProgramChannel;
    
    // Theme initialization flag to prevent recursion
    BOOL isInitializingTheme;
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
@property (nonatomic, retain) VLCReusableTextField *searchTextField;
@property (nonatomic, retain) VLCClickableLabel *epgLabel;
@property (nonatomic, retain) NSMutableArray *searchResults;
@property (nonatomic, assign) BOOL isSearchActive;
@property (nonatomic, retain) NSTimer *searchTimer;
@property (nonatomic, retain) dispatch_queue_t searchQueue;
@property (nonatomic, retain) NSMutableArray *searchChannelResults;
@property (nonatomic, retain) NSMutableArray *searchMovieResults;
@property (nonatomic, assign) CGFloat searchChannelScrollPosition;
@property (nonatomic, assign) CGFloat searchMovieScrollPosition;

// Theme Settings UI Components - using dropdown manager
@property (nonatomic, assign) NSRect themeDropdownRect;
@property (nonatomic, assign) NSRect transparencyDropdownRect;
@property (nonatomic, assign) NSRect themeSettingsRect;
@property (nonatomic, assign) NSRect transparencySliderRect;
@property (nonatomic, assign) NSRect redSliderRect;
@property (nonatomic, assign) NSRect greenSliderRect;
@property (nonatomic, assign) NSRect blueSliderRect;

// Add property to track which slider is currently being dragged
@property (nonatomic, assign) NSInteger activeSliderType; // 0=none, 1=transparency, 2=red, 3=green, 4=blue, 5=subtitle

// Add property to track stacked view mode for movies
@property (nonatomic, assign) BOOL isStackedViewActive; // For horizontal layout with cover on left, details on right

// Custom theme RGB values (0.0 to 1.0)
@property (nonatomic, assign) CGFloat customThemeRed;
@property (nonatomic, assign) CGFloat customThemeGreen;
@property (nonatomic, assign) CGFloat customThemeBlue;

// Theme system properties
@property (nonatomic, assign) VLCColorTheme currentTheme;
@property (nonatomic, assign) VLCTransparencyLevel transparencyLevel;
@property (nonatomic, retain) NSColor *themeCategoryStartColor;
@property (nonatomic, retain) NSColor *themeCategoryEndColor;
@property (nonatomic, retain) NSColor *themeGroupStartColor;
@property (nonatomic, retain) NSColor *themeGroupEndColor;
@property (nonatomic, retain) NSColor *themeChannelStartColor;
@property (nonatomic, retain) NSColor *themeChannelEndColor;
@property (nonatomic, assign) CGFloat themeAlpha;

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

// Theme system methods
//- (void)initializeThemeSystem;
- (void)applyTheme:(VLCColorTheme)theme;
- (void)setTransparencyLevel:(VLCTransparencyLevel)level;
- (void)updateThemeColors;
- (void)saveThemeSettings;
- (void)loadThemeSettings;
- (CGFloat)alphaForTransparencyLevel:(VLCTransparencyLevel)level;

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
@property (nonatomic, assign) NSInteger hoveredCategoryIndex;
@property (nonatomic, assign) NSInteger hoveredGroupIndex;
@property (nonatomic, assign) BOOL isPendingMovieInfoFetch;
@property (nonatomic, assign) BOOL isHoveringMovieInfoPanel;

@end 