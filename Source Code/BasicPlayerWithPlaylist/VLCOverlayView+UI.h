#import "VLCOverlayView.h"

#if TARGET_OS_OSX

#import "VLCOverlayView+Drawing.h"
#import "VLCOverlayView+MouseHandling.h"
#import "VLCOverlayView+ContextMenu.h"
#import "VLCOverlayView+TextFields.h"
#import "VLCOverlayView+Search.h"
#import "VLCOverlayView+Globals.h"

@interface VLCOverlayView (UI)

// This category now serves as a coordination point for all UI functionality
// The actual method declarations are in their respective category headers:
// - VLCOverlayView+Drawing.h: UI setup and drawing methods
// - VLCOverlayView+MouseHandling.h: Mouse and keyboard event handling
// - VLCOverlayView+ContextMenu.h: Context menu functionality
// - VLCOverlayView+TextFields.h: Text field delegates and URL handling
// - VLCOverlayView+Search.h: Search functionality and selection persistence
// - VLCOverlayView+ViewModes.h: View mode management and stacked view drawing

// UI setup
- (void)setupTrackingArea;

// Icon helpers
- (NSImage *)iconForCategory:(NSString *)category;
- (NSImage *)createFallbackIconForCategory:(NSString *)category;

// Selection color customization
- (void)updateSelectionColors;

// Drawing methods
- (void)drawChannelList:(NSRect)rect;
- (void)drawCategories:(NSRect)rect;
- (void)drawGroups:(NSRect)rect;
- (void)drawSearchInterface:(NSRect)rect menuRect:(NSRect)menuRect;
- (void)drawLoadingIndicator:(NSRect)rect;
- (void)drawEpgPanel:(NSRect)rect;
- (void)drawSettingsPanel:(NSRect)rect;
- (void)drawURLInputField:(NSRect)rect;
- (void)drawPlayerControls:(NSRect)rect;
- (void)drawPlaylistSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width;
- (void)drawPlaylistSettingsWithComponents:(NSRect)rect x:(CGFloat)x width:(CGFloat)width;
- (void)setupEpgTimeOffsetDropdown;
- (void)updateUIComponentsVisibility;
- (void)hideControls;
- (void)drawGeneralSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width;
- (void)drawMovieInfoSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width;
- (void)drawSubtitleSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width;
- (void)drawThemeSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width;
- (void)drawStackedView:(NSRect)rect;

// Mouse handling
- (void)mouseDown:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)mouseEntered:(NSEvent *)event;
- (void)rightMouseDown:(NSEvent *)event;
- (void)mouseMoved:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;

// User interface helpers
- (void)showContextMenuForChannel:(VLCChannel *)channel atPoint:(NSPoint)point;
- (void)showContextMenuForGroup:(NSString *)group atPoint:(NSPoint)point;
- (BOOL)handleEpgProgramRightClick:(NSPoint)point withEvent:(NSEvent *)event;
- (void)showContextMenuForProgram:(VLCProgram *)program channel:(VLCChannel *)channel atPoint:(NSPoint)point withEvent:(NSEvent *)event;
- (void)playCatchUpFromMenu:(NSMenuItem *)sender;
- (void)playChannelFromEpgMenu:(NSMenuItem *)sender;
- (NSInteger)findChannelIndexForChannel:(VLCChannel *)targetChannel;
- (void)setViewState:(NSInteger)state;
- (void)updateCursorRects;
- (BOOL)handleClickAtPoint:(NSPoint)point;
- (NSInteger)simpleChannelIndexAtPoint:(NSPoint)point;
- (NSInteger)categoryIndexAtPoint:(NSPoint)point;
- (NSInteger)groupIndexAtPoint:(NSPoint)point;

// Text field handling
- (void)loadFromUrlButtonClicked;
- (void)updateEpgButtonClicked;
- (void)calculateCursorPositionForTextField:(BOOL)isM3uField withPoint:(NSPoint)point;
- (NSString *)generateEpgUrlFromM3uUrl:(NSString *)m3uUrl;

// Movie helper methods
- (NSString *)fileExtensionFromUrl:(NSString *)urlString;

// Cache directory methods
- (NSString *)postersCacheDirectory;

// Other UI methods
- (void)drawDropdowns:(NSRect)rect;
- (void)handleDropdownHover:(NSPoint)point;

// New timeshift methods
- (void)showTimeshiftOptionsForChannel:(NSMenuItem *)sender;
- (void)playTimeshiftFromMenu:(NSMenuItem *)sender;

// Search methods
- (void)performSearch:(NSString *)searchText;
- (void)performDelayedSearch:(NSTimer *)timer;
- (BOOL)channel:(VLCChannel *)channel matchesSearchText:(NSString *)searchText;

// Selection persistence methods
- (void)saveLastSelectedIndices;
- (void)loadAndRestoreLastSelectedIndices;
- (NSArray *)getGroupsForCategoryIndex:(NSInteger)categoryIndex;

// Smart search selection methods
- (void)saveOriginalLocationForSearchedChannel:(VLCChannel *)channel;
- (void)selectSearchAndRememberOriginalLocation:(VLCChannel *)channel;
- (void)restoreOriginalLocationOfSearchedChannel;

@end

#endif // TARGET_OS_OSX