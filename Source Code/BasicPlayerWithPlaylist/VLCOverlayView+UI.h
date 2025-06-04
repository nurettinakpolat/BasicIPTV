#import "VLCOverlayView.h"

@interface VLCOverlayView (UI)

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

@end
