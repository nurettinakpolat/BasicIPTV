#import "VLCOverlayView.h"

@interface VLCOverlayView (Drawing)

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

// Other UI methods
- (void)drawDropdowns:(NSRect)rect;

@end 