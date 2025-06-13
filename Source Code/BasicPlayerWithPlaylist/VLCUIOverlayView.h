//
//  VLCUIOverlayView.h
//  BasicIPTV - iOS/tvOS Overlay View
//
//  UIKit-based overlay view for iOS and tvOS
//  Shares the same interface and functionality as macOS VLCOverlayView
//

#import "PlatformBridge.h"

#if TARGET_OS_IOS || TARGET_OS_TV

#import <VLCKit/VLCKit.h>
@class VLCChannel;
@class VLCProgram;
@class VLCDataManager;

@interface VLCUIOverlayView : UIView <UITextFieldDelegate>

#pragma mark - Player and Media

// Player instance (shared with macOS)
@property (nonatomic, strong) VLCMediaPlayer *player;

// File paths and URLs (shared with macOS)
@property (nonatomic, strong) NSString *m3uFilePath;
@property (nonatomic, strong) NSString *epgUrl;

// Data management (shared with macOS)
@property (nonatomic, readonly) VLCDataManager *dataManager;

#pragma mark - UI State (Shared Interface)

// Channel list visibility and selection
@property (nonatomic, assign, getter=isChannelListVisible) BOOL isChannelListVisible;
@property (nonatomic, assign) NSInteger selectedCategoryIndex;
@property (nonatomic, assign) NSInteger selectedGroupIndex;
@property (nonatomic, assign) NSInteger hoveredChannelIndex;
@property (nonatomic, assign) NSInteger selectedChannelIndex;

// Loading states
@property (nonatomic, assign, getter=isLoading) BOOL isLoading;
@property (nonatomic, assign) float loadingProgress;
@property (nonatomic, strong) NSString *loadingStatusText;
@property (nonatomic, strong) NSTimer *loadingProgressTimer;

// Hover state management
@property (nonatomic, strong) NSTimer *hoverClearTimer;

// EPG related (shared with macOS)
@property (nonatomic, assign, getter=isEpgLoaded) BOOL isEpgLoaded;
@property (nonatomic, assign) BOOL showEpgPanel;
@property (nonatomic, assign, getter=isLoadingEpg) BOOL isLoadingEpg;
@property (nonatomic, assign) float epgLoadingProgress;
@property (nonatomic, strong) NSString *epgLoadingStatusText;
@property (nonatomic, strong) NSMutableDictionary *epgData;
@property (nonatomic, assign) CGFloat epgTimeOffsetHours;

#pragma mark - Data Collections (Shared with macOS)

// Channel collections (read-only, shared interface)
@property (nonatomic, strong, readonly) NSMutableArray *channels;
@property (nonatomic, strong, readonly) NSMutableArray *groups;
@property (nonatomic, strong, readonly) NSMutableDictionary *channelsByGroup;
@property (nonatomic, strong, readonly) NSArray *categories;
@property (nonatomic, strong, readonly) NSMutableDictionary *groupsByCategory;

// Simple channel lists for display (read-only, shared interface)
@property (nonatomic, strong, readonly) NSArray *simpleChannelNames;
@property (nonatomic, strong, readonly) NSArray *simpleChannelUrls;

#pragma mark - UI Appearance (Shared Theme System)

// Colors (matching macOS theme system)
// Note: backgroundColor inherited from UIView, no need to redeclare
@property (nonatomic, strong) UIColor *hoverColor;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, strong) UIColor *groupColor;

// Theme colors (used by macOS category methods)
@property (nonatomic, strong) UIColor *themeChannelStartColor;
@property (nonatomic, strong) UIColor *themeChannelEndColor;
@property (nonatomic, strong) UIColor *themeCategoryStartColor;
@property (nonatomic, strong) UIColor *themeCategoryEndColor;
@property (nonatomic, assign) CGFloat themeAlpha;

// Theme system properties (shared with macOS)
typedef NS_ENUM(NSInteger, VLCColorTheme) {
    VLC_THEME_DARK = 0,
    VLC_THEME_DARKER = 1,
    VLC_THEME_BLUE = 2,
    VLC_THEME_GREEN = 3,
    VLC_THEME_PURPLE = 4,
    VLC_THEME_CUSTOM = 5
};

@property (nonatomic, assign) VLCColorTheme currentTheme;
@property (nonatomic, assign) CGFloat customThemeRed;
@property (nonatomic, assign) CGFloat customThemeGreen;
@property (nonatomic, assign) CGFloat customThemeBlue;

// Selection color customization (shared with macOS)
@property (nonatomic, assign) CGFloat customSelectionRed;
@property (nonatomic, assign) CGFloat customSelectionGreen;
@property (nonatomic, assign) CGFloat customSelectionBlue;

// Glassmorphism settings (shared with macOS)
@property (nonatomic, assign) BOOL glassmorphismEnabled;
@property (nonatomic, assign) CGFloat glassmorphismIntensity;
@property (nonatomic, assign) BOOL glassmorphismHighQuality;

// Advanced glassmorphism controls (matching macOS)
@property (nonatomic, assign) CGFloat glassmorphismOpacity;
@property (nonatomic, assign) CGFloat glassmorphismBlurRadius;
@property (nonatomic, assign) CGFloat glassmorphismBorderWidth;
@property (nonatomic, assign) CGFloat glassmorphismCornerRadius;
@property (nonatomic, assign) BOOL glassmorphismIgnoreTransparency;
@property (nonatomic, assign) CGFloat glassmorphismSandedIntensity;

#pragma mark - Touch/Remote Navigation (iOS/tvOS Specific)

// Touch navigation state
@property (nonatomic, assign) BOOL isTouchNavigating;

// Text input handling
@property (nonatomic, strong) NSString *inputUrlString;
@property (nonatomic, assign) BOOL isTextFieldActive;

// Temporary channel for operations
@property (nonatomic, strong) VLCChannel *tmpCurrentChannel;

// iOS-specific UI elements for settings
@property (nonatomic, strong) UIScrollView *settingsScrollViewiOS;
@property (nonatomic, strong) UITextField *m3uTextFieldiOS;
@property (nonatomic, strong) UILabel *epgLabeliOS;
@property (nonatomic, strong) UIButton *timeOffsetButtoniOS;

// Button references for state management
@property (nonatomic, strong) UIButton *loadUrlButtoniOS;
@property (nonatomic, strong) UIButton *updateEpgButtoniOS;

// Specialized settings scroll views
@property (nonatomic, strong) UIScrollView *themeSettingsScrollView;
@property (nonatomic, strong) UIScrollView *subtitleSettingsScrollView;
#if TARGET_OS_IOS
@property (nonatomic, strong) UISlider *subtitleFontSizeSlider;
#endif
@property (nonatomic, strong) UILabel *subtitleFontSizeLabel;

// Button rectangles for touch handling
@property (nonatomic, assign) CGRect clearMovieInfoCacheButtonRect;

#pragma mark - Scroll Positions (iOS/tvOS Specific)

// Scroll positions for touch scrolling
@property (nonatomic, assign) CGFloat scrollPosition;
@property (nonatomic, assign) CGFloat epgScrollPosition;
@property (nonatomic, assign) CGFloat movieInfoScrollPosition;

// Momentum scrolling state
@property (nonatomic, weak) CADisplayLink *groupMomentumDisplayLink;
@property (nonatomic, weak) CADisplayLink *channelMomentumDisplayLink;
@property (nonatomic, assign) CGFloat groupMomentumVelocity;
@property (nonatomic, assign) CGFloat channelMomentumVelocity;
@property (nonatomic, assign) CGFloat groupMomentumMaxScroll;
@property (nonatomic, assign) CGFloat channelMomentumMaxScroll;

// EPG navigation (shared between iOS and tvOS)
@property (nonatomic, assign) NSInteger selectedEpgProgramIndex;
@property (nonatomic, assign) BOOL epgNavigationMode;

#if TARGET_OS_TV
// tvOS continuous scrolling
@property (nonatomic, strong) NSTimer *continuousScrollTimer;
@property (nonatomic, assign) UIPressType currentPressType;
#endif

#pragma mark - Startup Progress System (All Platforms)

// Startup progress window and components
#if TARGET_OS_IOS || TARGET_OS_TV
@property (nonatomic, strong) UIView *startupProgressWindow;
@property (nonatomic, strong) UILabel *startupProgressTitle;
@property (nonatomic, strong) UILabel *startupProgressStep;
@property (nonatomic, strong) UIProgressView *startupProgressBar;
@property (nonatomic, strong) UILabel *startupProgressPercent;
@property (nonatomic, strong) UILabel *startupProgressDetails;
#else
@property (nonatomic, strong) NSView *startupProgressWindow;
@property (nonatomic, strong) NSTextField *startupProgressTitle;
@property (nonatomic, strong) NSTextField *startupProgressStep;
@property (nonatomic, strong) NSProgressIndicator *startupProgressBar;
@property (nonatomic, strong) NSTextField *startupProgressPercent;
@property (nonatomic, strong) NSTextField *startupProgressDetails;
#endif

// Startup progress tracking
@property (nonatomic, assign) float currentStartupProgress;
@property (nonatomic, strong) NSString *currentStartupStep;
@property (nonatomic, assign) BOOL isStartupInProgress;

// Manual loading operations tracking
@property (nonatomic, assign) BOOL isManualLoadingInProgress;
@property (nonatomic, assign) BOOL isLoadingBothChannelsAndEPG;

#pragma mark - Auto-Hide Timer (iOS/tvOS)

// Auto-hide timer methods
- (void)resetAutoHideTimer;
- (void)stopAutoHideTimer;
- (void)autoHideTimerFired:(NSTimer *)timer;

// Auto-alignment timer (all platforms)
@property (nonatomic, strong) NSTimer *autoAlignmentTimer;
- (void)startAutoAlignmentTimer;
- (void)stopAutoAlignmentTimer;
- (void)autoAlignmentTimerFired:(NSTimer *)timer;

#pragma mark - Player Controls (iOS/tvOS)

// Player controls methods
- (void)showPlayerControls;
- (void)hidePlayerControls;
- (void)togglePlayerControls;
- (void)hideAllControls;
- (void)hideAllControlsExceptStartupProgress;
- (void)drawPlayerControlsOnRect:(CGRect)rect;
- (BOOL)handlePlayerControlsTap:(CGPoint)tapPoint;

#pragma mark - Current Program Detection (iOS/tvOS)

// Current program detection
- (VLCChannel *)getCurrentlyPlayingChannel;
- (VLCProgram *)getCurrentlyPlayingProgram;

#pragma mark - Shared Methods (Common Interface with macOS)

// Channel loading and management
- (void)loadChannelsFromM3uFile:(NSString *)path;
- (void)loadChannelsFromUrl:(NSString *)urlStr;
- (void)loadChannelsFile;
- (void)ensureDataStructuresInitialized;

// Playback control
- (void)startEarlyPlaybackIfAvailable;
- (void)saveCurrentPlaybackPosition;
- (NSString *)getLastPlayedChannelUrl;

// Settings and cache management (shared with macOS)
- (void)loadSettings;
- (void)loadThemeSettings;
- (void)loadViewModePreference;
- (BOOL)loadChannelsFromCache:(NSString *)sourcePath;
- (void)loadEpgFromCacheOnly;
- (BOOL)shouldUpdateM3UAtStartup;
- (BOOL)shouldUpdateEPGAtStartup;
- (void)loadEpgDataAtStartup;

// File paths (shared interface)
- (NSString *)localM3uFilePath;

#pragma mark - Startup Progress Methods (All Platforms)

// Startup progress window management
- (void)showStartupProgressWindow;
- (void)hideStartupProgressWindow;
- (void)updateStartupProgress:(float)progress step:(NSString *)step details:(NSString *)details;
- (void)setStartupPhase:(NSString *)phase;

#pragma mark - Platform-Specific Methods (iOS/tvOS)

// Touch/gesture handling
- (void)playChannelAtIndex:(NSInteger)index;
- (void)playChannelWithUrl:(NSString *)urlString;
- (void)updateMenuSelectionForChannel:(VLCChannel *)channel inGroup:(NSString *)groupName atIndex:(NSInteger)channelIndex;

// Background alignment methods (all platforms)
- (void)alignMenuToPlayingChannelInBackground;
- (void)alignEpgToPlayingProgramInBackground;
- (void)performBackgroundAlignment;

// Settings persistence (shared interface, platform-specific implementation)
- (void)saveSettings;

// Helper methods
- (BOOL)groupHasCatchupChannels:(NSString *)groupName;

// Initialization
- (instancetype)initWithFrame:(CGRect)frame;

@end

#endif // TARGET_OS_IOS || TARGET_OS_TV 
