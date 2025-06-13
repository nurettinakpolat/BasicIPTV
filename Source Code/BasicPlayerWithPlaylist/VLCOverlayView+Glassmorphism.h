#import "VLCOverlayView.h"
#import <QuartzCore/QuartzCore.h>

#if TARGET_OS_OSX

@interface VLCOverlayView (Glassmorphism)

// Performance settings
@property (nonatomic, assign) BOOL glassmorphismEnabled;
@property (nonatomic, assign) CGFloat glassmorphismIntensity; // 0.0 to 1.0
@property (nonatomic, assign) BOOL glassmorphismHighQuality; // High vs low quality mode

// Granular glassmorphism controls
@property (nonatomic, assign) CGFloat glassmorphismOpacity; // Independent opacity control (0.0 to 1.0)
@property (nonatomic, assign) CGFloat glassmorphismBlurRadius; // Blur amount (0.0 to 30.0)
@property (nonatomic, assign) CGFloat glassmorphismBorderWidth; // Border thickness (0.0 to 5.0)
@property (nonatomic, assign) CGFloat glassmorphismCornerRadius; // Corner rounding (0.0 to 20.0)
@property (nonatomic, assign) BOOL glassmorphismIgnoreTransparency; // Whether to ignore main transparency slider

// Background color controls (separate from selection colors)
@property (nonatomic, assign) CGFloat glassmorphismBackgroundRed; // Background red component (0.0 to 1.0)
@property (nonatomic, assign) CGFloat glassmorphismBackgroundGreen; // Background green component (0.0 to 1.0)
@property (nonatomic, assign) CGFloat glassmorphismBackgroundBlue; // Background blue component (0.0 to 1.0)

// Sanded effect control
@property (nonatomic, assign) CGFloat glassmorphismSandedIntensity; // Sanded/frosted texture intensity (0.0 to 3.0)

// Core glassmorphism drawing methods
- (void)drawGlassmorphismBackground:(NSRect)rect opacity:(CGFloat)opacity blurRadius:(CGFloat)blurRadius;
- (void)drawGlassmorphismPanel:(NSRect)rect opacity:(CGFloat)opacity cornerRadius:(CGFloat)cornerRadius;
- (void)drawGlassmorphismButton:(NSRect)rect text:(NSString *)text isHovered:(BOOL)isHovered isSelected:(BOOL)isSelected;
- (void)drawGlassmorphismCard:(NSRect)rect opacity:(CGFloat)opacity cornerRadius:(CGFloat)cornerRadius borderWidth:(CGFloat)borderWidth;

// Glassmorphism gradient helpers
- (NSGradient *)createGlassmorphismGradient:(CGFloat)opacity;
- (NSGradient *)createGlassmorphismBackgroundGradient:(CGFloat)opacity; // For backgrounds only
- (NSGradient *)createGlassmorphismBorderGradient:(CGFloat)opacity;

// Glassmorphism color helpers
- (NSColor *)glassmorphismBackgroundColor:(CGFloat)opacity;
- (NSColor *)glassmorphismBorderColor:(CGFloat)opacity;
- (NSColor *)glassmorphismHighlightColor:(CGFloat)opacity;

// Blur and backdrop effects
- (void)applyBackdropBlur:(NSRect)rect;
- (void)drawFrostedGlass:(NSRect)rect opacity:(CGFloat)opacity cornerRadius:(CGFloat)cornerRadius;

@end

#endif // TARGET_OS_OSX 