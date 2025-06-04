#import "VLCOverlayView.h"
#import "VLCOverlayView_Private.h"

@interface VLCOverlayView (Theming)

// Theme system methods
- (void)initializeThemeSystem;
- (void)applyTheme:(VLCColorTheme)theme;
- (void)setTransparencyLevel:(VLCTransparencyLevel)level;
- (void)updateThemeColors;
- (void)saveThemeSettings;
- (void)loadThemeSettings;
- (CGFloat)alphaForTransparencyLevel:(VLCTransparencyLevel)level;

@end 