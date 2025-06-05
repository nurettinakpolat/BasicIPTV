#import "VLCOverlayView.h"

@interface VLCOverlayView (Utilities)

// Safe accessor methods
- (NSArray *)safeGroupsForCategory:(NSString *)category;
- (NSArray *)safeTVGroups;
- (NSArray *)safeValueForKey:(NSString *)key fromDictionary:(NSDictionary *)dict;

// Data structure initialization
- (void)ensureFavoritesCategory;
- (void)ensureSettingsGroups;
- (void)ensureDataStructuresInitialized;

// File paths
- (NSString *)applicationSupportDirectory;
- (NSString *)localM3uFilePath;

// User interaction handling
- (void)markUserInteraction;
- (void)markUserInteractionWithMenuShow:(BOOL)shouldShowMenu;
- (void)scheduleInteractionCheck;
- (void)checkUserInteraction;
- (void)hideChannelList;
- (void)ensureCursorVisible;

// Loading progress
- (void)setLoadingStatusText:(NSString *)text;
- (void)startProgressRedrawTimer;
- (void)stopProgressRedrawTimer;

// UI helpers
- (void)prepareSimpleChannelLists;
- (NSInteger)simpleChannelIndexAtPoint:(NSPoint)point;
- (CGFloat)totalChannelsHeight;
- (CGFloat)visibleHeightForPanel;
- (CGFloat)maxScrollPositionForContentHeight:(CGFloat)contentHeight;
- (void)scrollToSelectedItems;

// Helper methods
- (BOOL)isNumeric:(NSString *)string;

// Auto-navigation functionality
- (void)autoNavigateToCurrentlyPlayingChannel;
- (void)centerSelectionInMenuAndSetHoverIndices;

@end 