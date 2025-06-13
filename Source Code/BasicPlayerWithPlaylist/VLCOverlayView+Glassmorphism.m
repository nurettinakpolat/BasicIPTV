#import "VLCOverlayView+Glassmorphism.h"

#if TARGET_OS_OSX
#import "VLCOverlayView_Private.h"
#import <objc/runtime.h>

// Associated object keys for performance settings
static char glassmorphismEnabledKey;
static char glassmorphismIntensityKey;
static char glassmorphismHighQualityKey;

// Associated object keys for granular controls
static char glassmorphismOpacityKey;
static char glassmorphismBlurRadiusKey;
static char glassmorphismBorderWidthKey;
static char glassmorphismCornerRadiusKey;
static char glassmorphismIgnoreTransparencyKey;
static char glassmorphismBackgroundRedKey;
static char glassmorphismBackgroundGreenKey;
static char glassmorphismBackgroundBlueKey;
static char glassmorphismSandedIntensityKey;

@implementation VLCOverlayView (Glassmorphism)

#pragma mark - Performance Settings Properties

- (BOOL)glassmorphismEnabled {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismEnabledKey);
    return value ? [value boolValue] : YES; // Default enabled
}

- (void)setGlassmorphismEnabled:(BOOL)enabled {
    objc_setAssociatedObject(self, &glassmorphismEnabledKey, @(enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGFloat)glassmorphismIntensity {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismIntensityKey);
    return value ? [value floatValue] : 1.0; // Default full intensity
}

- (void)setGlassmorphismIntensity:(CGFloat)intensity {
    objc_setAssociatedObject(self, &glassmorphismIntensityKey, @(intensity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)glassmorphismHighQuality {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismHighQualityKey);
    return value ? [value boolValue] : NO; // Default low quality for performance
}

- (void)setGlassmorphismHighQuality:(BOOL)highQuality {
    objc_setAssociatedObject(self, &glassmorphismHighQualityKey, @(highQuality), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Granular Control Properties

- (CGFloat)glassmorphismOpacity {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismOpacityKey);
    return value ? [value floatValue] : 0.6; // Default opacity
}

- (void)setGlassmorphismOpacity:(CGFloat)opacity {
    objc_setAssociatedObject(self, &glassmorphismOpacityKey, @(opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGFloat)glassmorphismBlurRadius {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismBlurRadiusKey);
    return value ? [value floatValue] : 15.0; // Default blur radius
}

- (void)setGlassmorphismBlurRadius:(CGFloat)blurRadius {
    objc_setAssociatedObject(self, &glassmorphismBlurRadiusKey, @(blurRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGFloat)glassmorphismBorderWidth {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismBorderWidthKey);
    return value ? [value floatValue] : 1.0; // Default border width
}

- (void)setGlassmorphismBorderWidth:(CGFloat)borderWidth {
    objc_setAssociatedObject(self, &glassmorphismBorderWidthKey, @(borderWidth), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGFloat)glassmorphismCornerRadius {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismCornerRadiusKey);
    return value ? [value floatValue] : 8.0; // Default corner radius
}

- (void)setGlassmorphismCornerRadius:(CGFloat)cornerRadius {
    objc_setAssociatedObject(self, &glassmorphismCornerRadiusKey, @(cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)glassmorphismIgnoreTransparency {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismIgnoreTransparencyKey);
    return value ? [value boolValue] : NO; // Default follow transparency
}

- (void)setGlassmorphismIgnoreTransparency:(BOOL)ignoreTransparency {
    objc_setAssociatedObject(self, &glassmorphismIgnoreTransparencyKey, @(ignoreTransparency), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Background Color Properties

- (CGFloat)glassmorphismBackgroundRed {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismBackgroundRedKey);
    return value ? [value floatValue] : 0.2; // Default blue-ish red component
}

- (void)setGlassmorphismBackgroundRed:(CGFloat)backgroundRed {
    objc_setAssociatedObject(self, &glassmorphismBackgroundRedKey, @(backgroundRed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGFloat)glassmorphismBackgroundGreen {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismBackgroundGreenKey);
    return value ? [value floatValue] : 0.3; // Default blue-ish green component
}

- (void)setGlassmorphismBackgroundGreen:(CGFloat)backgroundGreen {
    objc_setAssociatedObject(self, &glassmorphismBackgroundGreenKey, @(backgroundGreen), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (CGFloat)glassmorphismBackgroundBlue {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismBackgroundBlueKey);
    return value ? [value floatValue] : 0.5; // Default blue-ish blue component
}

- (void)setGlassmorphismBackgroundBlue:(CGFloat)backgroundBlue {
    objc_setAssociatedObject(self, &glassmorphismBackgroundBlueKey, @(backgroundBlue), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Sanded Effect Properties

- (CGFloat)glassmorphismSandedIntensity {
    NSNumber *value = objc_getAssociatedObject(self, &glassmorphismSandedIntensityKey);
    return value ? [value floatValue] : 0.0; // Default no sanded effect
}

- (void)setGlassmorphismSandedIntensity:(CGFloat)sandedIntensity {
    objc_setAssociatedObject(self, &glassmorphismSandedIntensityKey, @(sandedIntensity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Core Glassmorphism Drawing Methods

- (void)drawGlassmorphismBackground:(NSRect)rect opacity:(CGFloat)opacity blurRadius:(CGFloat)blurRadius {
    [NSGraphicsContext saveGraphicsState];
    
    // Apply heavy backdrop blur effect using the provided blur radius
    if (blurRadius > 0) {
        // Create multiple blur layers for much stronger effect
        NSInteger blurLayers = (NSInteger)(blurRadius / 2.0) + 3; // 3-18 layers based on radius
        blurLayers = MIN(blurLayers, 20); // Cap at 20 for performance
        
        for (int i = 0; i < blurLayers; i++) {
            CGFloat layerOffset = (i * blurRadius) / (blurLayers * 4.0);
            CGFloat layerOpacity = (0.12 * [self glassmorphismIntensity]) / (i + 1);
            
            // Create 8-directional blur offsets for maximum blur effect
            NSRect blurRects[] = {
                NSOffsetRect(rect, layerOffset, layerOffset),
                NSOffsetRect(rect, -layerOffset, layerOffset),
                NSOffsetRect(rect, layerOffset, -layerOffset),
                NSOffsetRect(rect, -layerOffset, -layerOffset),
                NSOffsetRect(rect, layerOffset, 0),
                NSOffsetRect(rect, -layerOffset, 0),
                NSOffsetRect(rect, 0, layerOffset),
                NSOffsetRect(rect, 0, -layerOffset)
            };
            
            // Use THEME COLORS for blur layers (not selection or separate background colors)
            CGFloat bgRed, bgGreen, bgBlue;
            
            switch (self.currentTheme) {
                case VLC_THEME_DARK:
                    bgRed = 0.15; bgGreen = 0.20; bgBlue = 0.30;
                    break;
                case VLC_THEME_DARKER:
                    bgRed = 0.10; bgGreen = 0.10; bgBlue = 0.10;
                    break;
                case VLC_THEME_BLUE:
                    bgRed = 0.10; bgGreen = 0.25; bgBlue = 0.45;
                    break;
                case VLC_THEME_GREEN:
                    bgRed = 0.10; bgGreen = 0.35; bgBlue = 0.20;
                    break;
                case VLC_THEME_PURPLE:
                    bgRed = 0.35; bgGreen = 0.20; bgBlue = 0.45;
                    break;
                case VLC_THEME_CUSTOM:
                    // Use the custom theme colors (NOT selection colors)
                    bgRed = self.customThemeRed;
                    bgGreen = self.customThemeGreen;
                    bgBlue = self.customThemeBlue;
                    break;
                default:
                    bgRed = 0.15; bgGreen = 0.20; bgBlue = 0.30;
                    break;
            }
            
            NSColor *blurColor = [NSColor colorWithRed:bgRed green:bgGreen blue:bgBlue alpha:layerOpacity];
            [blurColor set];
            
            for (int j = 0; j < 8; j++) {
                NSBezierPath *blurPath = [NSBezierPath bezierPathWithRoundedRect:blurRects[j] 
                                                                         xRadius:12 + layerOffset 
                                                                         yRadius:12 + layerOffset];
                [blurPath fill];
            }
        }
    }
    
    // Create the main glassmorphism background using background colors (not selection colors)
    NSGradient *glassGradient = [self createGlassmorphismBackgroundGradient:opacity];
    
    // Draw the background with slight roundedness
    NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:12 yRadius:12];
    [glassGradient drawInBezierPath:backgroundPath angle:135];
    
    // Enhanced highlight effect based on blur radius
    CGFloat highlightIntensity = 0.08 + (blurRadius / 50.0) * 0.20; // Scale with blur radius (stronger effect)
    NSRect highlightRect = NSMakeRect(rect.origin.x, rect.origin.y + rect.size.height * 0.6, 
                                     rect.size.width, rect.size.height * 0.4);
    NSBezierPath *highlightPath = [NSBezierPath bezierPathWithRoundedRect:highlightRect xRadius:12 yRadius:12];
    
    [[NSColor colorWithWhite:1.0 alpha:highlightIntensity] set];
    [highlightPath fill];
    
    // Add additional highlight layers for stronger blur effect
    if (blurRadius > 10.0) {
        NSRect topHighlight = NSMakeRect(rect.origin.x, rect.origin.y + rect.size.height * 0.8, 
                                        rect.size.width, rect.size.height * 0.2);
        NSBezierPath *topPath = [NSBezierPath bezierPathWithRoundedRect:topHighlight xRadius:12 yRadius:12];
        [[NSColor colorWithWhite:1.0 alpha:highlightIntensity * 0.6] set];
        [topPath fill];
    }
    
    // Enhanced border with stronger effect for higher blur
    NSGradient *borderGradient = [self createGlassmorphismBorderGradient:opacity];
    CGFloat borderWidth = 1.0 + (blurRadius / 50.0) * 2.5; // Thicker border with more blur (stronger effect)
    [backgroundPath setLineWidth:borderWidth];
    
    [NSGraphicsContext saveGraphicsState];
    [backgroundPath addClip];
    
    NSRect borderRect = NSInsetRect(rect, borderWidth * 0.5, borderWidth * 0.5);
    NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:borderRect xRadius:12 yRadius:12];
    [borderGradient drawInBezierPath:borderPath angle:135];
    
    [NSGraphicsContext restoreGraphicsState];
    
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawGlassmorphismPanel:(NSRect)rect opacity:(CGFloat)opacity cornerRadius:(CGFloat)cornerRadius {
    // Early return if glassmorphism is disabled
    if (!self.glassmorphismEnabled) {
        // Fall back to theme-aware transparent background that respects transparency settings
        CGFloat finalOpacity = opacity * self.themeAlpha;
        
        // Use theme-appropriate background color
        NSColor *backgroundColor;
        switch (self.currentTheme) {
            case VLC_THEME_DARK:
                backgroundColor = [NSColor colorWithRed:0.1 green:0.12 blue:0.16 alpha:finalOpacity];
                break;
            case VLC_THEME_DARKER:
                backgroundColor = [NSColor colorWithRed:0.05 green:0.05 blue:0.05 alpha:finalOpacity];
                break;
            case VLC_THEME_BLUE:
                backgroundColor = [NSColor colorWithRed:0.1 green:0.15 blue:0.25 alpha:finalOpacity];
                break;
            case VLC_THEME_GREEN:
                backgroundColor = [NSColor colorWithRed:0.05 green:0.2 blue:0.1 alpha:finalOpacity];
                break;
            case VLC_THEME_PURPLE:
                backgroundColor = [NSColor colorWithRed:0.15 green:0.1 blue:0.25 alpha:finalOpacity];
                break;
            case VLC_THEME_CUSTOM:
                backgroundColor = [NSColor colorWithRed:self.customThemeRed green:self.customThemeGreen blue:self.customThemeBlue alpha:finalOpacity];
                break;
            default:
                backgroundColor = [NSColor colorWithRed:0.1 green:0.12 blue:0.16 alpha:finalOpacity];
                break;
        }
        
        [backgroundColor set];
        NSBezierPath *simplePath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:cornerRadius yRadius:cornerRadius];
        [simplePath fill];
        return;
    }
    
    [NSGraphicsContext saveGraphicsState];
    
    // Apply intensity scaling
    CGFloat adjustedOpacity = opacity * self.glassmorphismIntensity;
    
    // Create backdrop blur effect (simulated with multiple layers) with proper corner radius
    [self drawFrostedGlass:rect opacity:adjustedOpacity cornerRadius:cornerRadius];
    
    // Main glass panel
    NSBezierPath *panelPath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:cornerRadius yRadius:cornerRadius];
    
    // Background gradient - now uses user-controlled background colors (separate from selection colors)
    NSGradient *backgroundGradient = [self createGlassmorphismBackgroundGradient:opacity];
    [backgroundGradient drawInBezierPath:panelPath angle:135];
    [backgroundGradient release];
    
    // Add subtle shadow for depth
    [NSGraphicsContext saveGraphicsState];
    NSSize shadowOffset = NSMakeSize(0, -2);
    [NSGraphicsContext currentContext].compositingOperation = NSCompositingOperationMultiply;
    [[NSColor colorWithWhite:0.0 alpha:0.3] set];
    
    NSBezierPath *shadowPath = [NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(rect, shadowOffset.width, shadowOffset.height) 
                                                               xRadius:cornerRadius yRadius:cornerRadius];
    [shadowPath fill];
    [NSGraphicsContext restoreGraphicsState];
    
    // Glass border - now uses theme-aware colors
    NSGradient *borderGradient = [self createGlassmorphismBorderGradient:opacity];
    
    [panelPath setLineWidth:[self glassmorphismBorderWidth]];
    [borderGradient drawInBezierPath:panelPath angle:45];
    [borderGradient release];
    
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawGlassmorphismButton:(NSRect)rect text:(NSString *)text isHovered:(BOOL)isHovered isSelected:(BOOL)isSelected {
    // Early return if glassmorphism is disabled
    if (!self.glassmorphismEnabled) {
        // Fall back to theme-aware selection background that respects transparency
        if (isSelected || isHovered) {
            CGFloat baseAlpha = isSelected ? 0.4 : 0.2;
            CGFloat finalAlpha = baseAlpha * self.themeAlpha < 0.7 ? 0.7 : baseAlpha * self.themeAlpha;
            
            NSColor *buttonColor;
            if (isSelected) {
                // Use theme selection colors for selected state
                buttonColor = [NSColor colorWithRed:self.customSelectionRed 
                                             green:self.customSelectionGreen 
                                              blue:self.customSelectionBlue 
                                             alpha:finalAlpha];
            } else {
                // Use darker selection colors for hover state (consistent with updateSelectionColors)
                CGFloat darkenFactor = 0.9; // Same factor as in updateSelectionColors
                CGFloat hoverRed = self.customSelectionRed * darkenFactor;
                CGFloat hoverGreen = self.customSelectionGreen * darkenFactor;
                CGFloat hoverBlue = self.customSelectionBlue * darkenFactor;
                
                buttonColor = [NSColor colorWithRed:hoverRed 
                                             green:hoverGreen 
                                              blue:hoverBlue 
                                             alpha:finalAlpha];
            }
            
            [buttonColor set];
            NSBezierPath *simplePath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:8 yRadius:8];
            [simplePath fill];
        }
        return;
    }
    
    [NSGraphicsContext saveGraphicsState];
    
    CGFloat baseOpacity = isSelected ? 0.4 : (isHovered ? 0.3 : 0.2);
    CGFloat glassOpacity = [self glassmorphismOpacity] * [self glassmorphismIntensity];
    CGFloat opacity;
    
    if ([self glassmorphismIgnoreTransparency]) {
        opacity = glassOpacity * baseOpacity;
    } else {
        opacity = glassOpacity * baseOpacity * self.themeAlpha;
    }
    
    CGFloat cornerRadius = [self glassmorphismCornerRadius];
    
    NSBezierPath *buttonPath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:cornerRadius yRadius:cornerRadius];
    
    // Background with glassmorphism effect - now theme-aware
    NSGradient *backgroundGradient;
    if (isSelected) {
        // Use theme selection colors for selected state
        backgroundGradient = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:opacity],
            [NSColor colorWithRed:self.customSelectionRed * 0.8 green:self.customSelectionGreen * 0.8 blue:self.customSelectionBlue * 0.8 alpha:opacity * 0.5],
            [NSColor colorWithRed:self.customSelectionRed * 0.6 green:self.customSelectionGreen * 0.6 blue:self.customSelectionBlue * 0.6 alpha:opacity * 0.75]
        ]];
    } else if (isHovered) {
        // Use darker selection colors for hover state
        CGFloat darkenFactor = 0.75; // Same factor as in updateSelectionColors
        CGFloat hoverRed = self.customSelectionRed * darkenFactor;
        CGFloat hoverGreen = self.customSelectionGreen * darkenFactor;
        CGFloat hoverBlue = self.customSelectionBlue * darkenFactor;
        
        backgroundGradient = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithRed:hoverRed green:hoverGreen blue:hoverBlue alpha:opacity],
            [NSColor colorWithRed:hoverRed * 0.8 green:hoverGreen * 0.8 blue:hoverBlue * 0.8 alpha:opacity * 0.5],
            [NSColor colorWithRed:hoverRed * 0.6 green:hoverGreen * 0.6 blue:hoverBlue * 0.6 alpha:opacity * 0.75]
        ]];
    } else {
        // Use theme-aware colors for normal states
        backgroundGradient = [self createGlassmorphismGradient:baseOpacity];
    }
    
    [backgroundGradient drawInBezierPath:buttonPath angle:135];
    [backgroundGradient release];
    
    // Glass border - theme-aware
    NSColor *borderColor = isSelected ? 
        [NSColor colorWithRed:self.customSelectionRed * 1.2 green:self.customSelectionGreen * 1.2 blue:self.customSelectionBlue * 1.2 alpha:opacity * 1.5] : 
        [self glassmorphismBorderColor:baseOpacity];
    [borderColor set];
    [buttonPath setLineWidth:[self glassmorphismBorderWidth]];
    [buttonPath stroke];
    
    // Add highlight on top edge for glass effect
    NSRect highlightRect = NSMakeRect(rect.origin.x + 1, rect.origin.y + rect.size.height - 2, 
                                     rect.size.width - 2, 1);
    NSBezierPath *highlightPath = [NSBezierPath bezierPathWithRoundedRect:highlightRect xRadius:cornerRadius yRadius:1];
    [[NSColor colorWithWhite:1.0 alpha:0.4] set];
    [highlightPath fill];
    
    // Draw text
    if (text) {
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentCenter];
        
        NSColor *textColor = isSelected ? 
            [NSColor colorWithRed:0.9 green:0.95 blue:1.0 alpha:1.0] :
            [NSColor colorWithWhite:0.9 alpha:0.9];
            
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSRect textRect = NSMakeRect(rect.origin.x + 8, 
                                    rect.origin.y + (rect.size.height - 16) / 2,
                                    rect.size.width - 16, 
                                    16);
        [text drawInRect:textRect withAttributes:attrs];
        [style release];
    }
    
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawGlassmorphismCard:(NSRect)rect opacity:(CGFloat)opacity cornerRadius:(CGFloat)cornerRadius borderWidth:(CGFloat)borderWidth {
    [NSGraphicsContext saveGraphicsState];
    
    NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:cornerRadius yRadius:cornerRadius];
    
    // Backdrop effect
    [self drawFrostedGlass:rect opacity:opacity cornerRadius:cornerRadius];
    
    // Main card background
    NSGradient *cardGradient = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:0.95 alpha:opacity * 0.15],
        [NSColor colorWithWhite:0.85 alpha:opacity * 0.08],
        [NSColor colorWithWhite:0.9 alpha:opacity * 0.12]
    ]];
    [cardGradient drawInBezierPath:cardPath angle:135];
    [cardGradient release];
    
    // Subtle inner glow
    NSRect glowRect = NSInsetRect(rect, 1, 1);
    NSBezierPath *glowPath = [NSBezierPath bezierPathWithRoundedRect:glowRect xRadius:cornerRadius-1 yRadius:cornerRadius-1];
    [[NSColor colorWithWhite:1.0 alpha:0.1] set];
    [glowPath setLineWidth:2.0];
    [glowPath stroke];
    
    // Border with glassmorphism gradient
    NSGradient *borderGradient = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:1.0 alpha:0.4],
        [NSColor colorWithWhite:0.9 alpha:0.1],
        [NSColor colorWithWhite:1.0 alpha:0.3]
    ]];
    
    [cardPath setLineWidth:borderWidth];
    [borderGradient drawInBezierPath:cardPath angle:45];
    [borderGradient release];
    
    [NSGraphicsContext restoreGraphicsState];
}

#pragma mark - Glassmorphism Gradient Helpers

- (NSGradient *)createGlassmorphismGradient:(CGFloat)opacity {
    // Calculate final opacity based on user settings
    CGFloat baseOpacity = [self glassmorphismOpacity] * [self glassmorphismIntensity];
    CGFloat finalOpacity;
    
    if ([self glassmorphismIgnoreTransparency]) {
        finalOpacity = baseOpacity * opacity;
    } else {
        finalOpacity = baseOpacity * opacity * self.themeAlpha;
    }
    
    switch (self.currentTheme) {
        case VLC_THEME_DARK:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.15 green:0.20 blue:0.30 alpha:finalOpacity * 0.8],
                [NSColor colorWithRed:0.10 green:0.15 blue:0.25 alpha:finalOpacity * 0.5],
                [NSColor colorWithRed:0.20 green:0.25 blue:0.35 alpha:finalOpacity * 0.7]
            ]];
            
        case VLC_THEME_DARKER:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.12 green:0.12 blue:0.12 alpha:finalOpacity * 0.8],
                [NSColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:finalOpacity * 0.5],
                [NSColor colorWithRed:0.16 green:0.16 blue:0.16 alpha:finalOpacity * 0.7]
            ]];
            
        case VLC_THEME_BLUE:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.10 green:0.25 blue:0.45 alpha:finalOpacity * 0.8],
                [NSColor colorWithRed:0.05 green:0.15 blue:0.30 alpha:finalOpacity * 0.5],
                [NSColor colorWithRed:0.15 green:0.35 blue:0.55 alpha:finalOpacity * 0.7]
            ]];
            
        case VLC_THEME_GREEN:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.10 green:0.35 blue:0.20 alpha:finalOpacity * 0.8],
                [NSColor colorWithRed:0.05 green:0.25 blue:0.12 alpha:finalOpacity * 0.5],
                [NSColor colorWithRed:0.15 green:0.45 blue:0.28 alpha:finalOpacity * 0.7]
            ]];
            
        case VLC_THEME_PURPLE:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.35 green:0.20 blue:0.45 alpha:finalOpacity * 0.8],
                [NSColor colorWithRed:0.25 green:0.12 blue:0.30 alpha:finalOpacity * 0.5],
                [NSColor colorWithRed:0.45 green:0.28 blue:0.55 alpha:finalOpacity * 0.7]
            ]];
            
        case VLC_THEME_CUSTOM:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:self.customThemeRed * 1.5 green:self.customThemeGreen * 1.5 blue:self.customThemeBlue * 1.5 alpha:finalOpacity * 0.8],
                [NSColor colorWithRed:self.customThemeRed green:self.customThemeGreen blue:self.customThemeBlue alpha:finalOpacity * 0.5],
                [NSColor colorWithRed:self.customThemeRed * 1.8 green:self.customThemeGreen * 1.8 blue:self.customThemeBlue * 1.8 alpha:finalOpacity * 0.7]
            ]];
            
        default:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithWhite:0.7 alpha:finalOpacity * 0.8],
                [NSColor colorWithWhite:0.5 alpha:finalOpacity * 0.5],
                [NSColor colorWithWhite:0.6 alpha:finalOpacity * 0.7]
            ]];
    }
}

- (NSGradient *)createGlassmorphismBackgroundGradient:(CGFloat)opacity {
    // Calculate final opacity based on user settings
    CGFloat baseOpacity = [self glassmorphismOpacity] * [self glassmorphismIntensity];
    CGFloat finalOpacity;
    
    if ([self glassmorphismIgnoreTransparency]) {
        finalOpacity = baseOpacity * opacity;
    } else {
        finalOpacity = baseOpacity * opacity * self.themeAlpha;
    }
    
    // Use THEME COLORS for glassmorphism background (not separate background colors)
    CGFloat bgRed, bgGreen, bgBlue;
    
    switch (self.currentTheme) {
        case VLC_THEME_DARK:
            bgRed = 0.15; bgGreen = 0.20; bgBlue = 0.30;
            break;
        case VLC_THEME_DARKER:
            bgRed = 0.10; bgGreen = 0.10; bgBlue = 0.10;
            break;
        case VLC_THEME_BLUE:
            bgRed = 0.10; bgGreen = 0.25; bgBlue = 0.45;
            break;
        case VLC_THEME_GREEN:
            bgRed = 0.10; bgGreen = 0.35; bgBlue = 0.20;
            break;
        case VLC_THEME_PURPLE:
            bgRed = 0.35; bgGreen = 0.20; bgBlue = 0.45;
            break;
        case VLC_THEME_CUSTOM:
            // Use the custom theme colors (NOT selection colors)
            bgRed = self.customThemeRed;
            bgGreen = self.customThemeGreen;
            bgBlue = self.customThemeBlue;
            break;
        default:
            bgRed = 0.15; bgGreen = 0.20; bgBlue = 0.30;
            break;
    }
    
    return [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithRed:bgRed * 1.2 green:bgGreen * 1.2 blue:bgBlue * 1.2 alpha:finalOpacity * 0.8],
        [NSColor colorWithRed:bgRed green:bgGreen blue:bgBlue alpha:finalOpacity * 0.5],
        [NSColor colorWithRed:bgRed * 1.4 green:bgGreen * 1.4 blue:bgBlue * 1.4 alpha:finalOpacity * 0.7]
    ]];
}

- (NSGradient *)createGlassmorphismBorderGradient:(CGFloat)opacity {
    // Calculate final opacity based on user settings
    CGFloat baseOpacity = [self glassmorphismOpacity] * [self glassmorphismIntensity];
    CGFloat finalOpacity;
    
    if ([self glassmorphismIgnoreTransparency]) {
        finalOpacity = baseOpacity * opacity;
    } else {
        finalOpacity = baseOpacity * opacity * self.themeAlpha;
    }
    
    switch (self.currentTheme) {
        case VLC_THEME_DARK:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:finalOpacity * 1.0],
                [NSColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:finalOpacity * 0.6],
                [NSColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:finalOpacity * 0.8]
            ]];
            
        case VLC_THEME_DARKER:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithWhite:0.8 alpha:finalOpacity * 1.0],
                [NSColor colorWithWhite:0.6 alpha:finalOpacity * 0.6],
                [NSColor colorWithWhite:0.9 alpha:finalOpacity * 0.8]
            ]];
            
        case VLC_THEME_BLUE:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:finalOpacity * 1.0],
                [NSColor colorWithRed:0.1 green:0.4 blue:0.8 alpha:finalOpacity * 0.6],
                [NSColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:finalOpacity * 0.8]
            ]];
            
        case VLC_THEME_GREEN:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:finalOpacity * 1.0],
                [NSColor colorWithRed:0.1 green:0.7 blue:0.3 alpha:finalOpacity * 0.6],
                [NSColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:finalOpacity * 0.8]
            ]];
            
        case VLC_THEME_PURPLE:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:0.8 green:0.4 blue:1.0 alpha:finalOpacity * 1.0],
                [NSColor colorWithRed:0.6 green:0.3 blue:0.8 alpha:finalOpacity * 0.6],
                [NSColor colorWithRed:0.9 green:0.5 blue:1.0 alpha:finalOpacity * 0.8]
            ]];
            
        case VLC_THEME_CUSTOM:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithRed:self.customThemeRed * 1.5 green:self.customThemeGreen * 1.5 blue:self.customThemeBlue * 1.5 alpha:finalOpacity * 1.0],
                [NSColor colorWithRed:self.customThemeRed green:self.customThemeGreen blue:self.customThemeBlue alpha:finalOpacity * 0.6],
                [NSColor colorWithRed:self.customThemeRed * 1.8 green:self.customThemeGreen * 1.8 blue:self.customThemeBlue * 1.8 alpha:finalOpacity * 0.8]
            ]];
            
        default:
            return [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithWhite:0.9 alpha:finalOpacity * 1.0],
                [NSColor colorWithWhite:0.7 alpha:finalOpacity * 0.6],
                [NSColor colorWithWhite:1.0 alpha:finalOpacity * 0.8]
            ]];
    }
}

#pragma mark - Glassmorphism Color Helpers

- (NSColor *)glassmorphismBackgroundColor:(CGFloat)opacity {
    // Calculate final opacity based on user settings
    CGFloat baseOpacity = [self glassmorphismOpacity] * [self glassmorphismIntensity];
    CGFloat finalOpacity;
    
    if ([self glassmorphismIgnoreTransparency]) {
        // Use only glassmorphism-specific opacity settings
        finalOpacity = baseOpacity * opacity;
    } else {
        // Integrate with transparency slider
        finalOpacity = baseOpacity * opacity * self.themeAlpha;
    }
    
    // Make glassmorphism colors theme-aware with stronger colors
    switch (self.currentTheme) {
        case VLC_THEME_DARK:
            return [NSColor colorWithRed:0.15 green:0.20 blue:0.30 alpha:finalOpacity * 0.6];
            
        case VLC_THEME_DARKER:
            return [NSColor colorWithRed:0.10 green:0.10 blue:0.10 alpha:finalOpacity * 0.6];
            
        case VLC_THEME_BLUE:
            return [NSColor colorWithRed:0.10 green:0.20 blue:0.40 alpha:finalOpacity * 0.6];
            
        case VLC_THEME_GREEN:
            return [NSColor colorWithRed:0.10 green:0.30 blue:0.15 alpha:finalOpacity * 0.6];
            
        case VLC_THEME_PURPLE:
            return [NSColor colorWithRed:0.25 green:0.15 blue:0.35 alpha:finalOpacity * 0.6];
            
        case VLC_THEME_CUSTOM:
            return [NSColor colorWithRed:self.customThemeRed * 1.5 green:self.customThemeGreen * 1.5 blue:self.customThemeBlue * 1.5 alpha:finalOpacity * 0.6];
            
        default:
            return [NSColor colorWithWhite:0.6 alpha:finalOpacity * 0.6];
    }
}

- (NSColor *)glassmorphismBorderColor:(CGFloat)opacity {
    // Calculate final opacity based on user settings
    CGFloat baseOpacity = [self glassmorphismOpacity] * [self glassmorphismIntensity];
    CGFloat finalOpacity;
    
    if ([self glassmorphismIgnoreTransparency]) {
        finalOpacity = baseOpacity * opacity;
    } else {
        finalOpacity = baseOpacity * opacity * self.themeAlpha;
    }
    
    switch (self.currentTheme) {
        case VLC_THEME_DARK:
            return [NSColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:finalOpacity * 0.8];
            
        case VLC_THEME_DARKER:
            return [NSColor colorWithWhite:0.8 alpha:finalOpacity * 0.7];
            
        case VLC_THEME_BLUE:
            return [NSColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:finalOpacity * 0.8];
            
        case VLC_THEME_GREEN:
            return [NSColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:finalOpacity * 0.8];
            
        case VLC_THEME_PURPLE:
            return [NSColor colorWithRed:0.8 green:0.4 blue:1.0 alpha:finalOpacity * 0.8];
            
        case VLC_THEME_CUSTOM:
            return [NSColor colorWithRed:self.customThemeRed * 1.5 green:self.customThemeGreen * 1.5 blue:self.customThemeBlue * 1.5 alpha:finalOpacity * 0.8];
            
        default:
            return [NSColor colorWithWhite:0.9 alpha:finalOpacity * 0.8];
    }
}

- (NSColor *)glassmorphismHighlightColor:(CGFloat)opacity {
    // Calculate final opacity based on user settings
    CGFloat baseOpacity = [self glassmorphismOpacity] * [self glassmorphismIntensity];
    CGFloat finalOpacity;
    
    if ([self glassmorphismIgnoreTransparency]) {
        finalOpacity = baseOpacity * opacity;
    } else {
        finalOpacity = baseOpacity * opacity * self.themeAlpha;
    }
    
    return [NSColor colorWithWhite:1.0 alpha:finalOpacity * 0.2];
}

#pragma mark - Blur and Backdrop Effects

- (void)applyBackdropBlur:(NSRect)rect {
    // Since we can't use real blur filters easily in NSView drawing,
    // we simulate the effect with multiple translucent layers based on user blur radius
    [NSGraphicsContext saveGraphicsState];
    
    // Use the user's blur radius setting to determine blur intensity
    CGFloat blurRadius = [self glassmorphismBlurRadius];
    CGFloat intensity = [self glassmorphismIntensity];
    
    // Calculate number of blur layers based on radius (more radius = more layers)
    NSInteger blurLayers = (NSInteger)(blurRadius / 3.0) + 2; // 2-12 layers depending on radius
    blurLayers = MIN(blurLayers, 15); // Cap at 15 layers for performance
    
    // Draw multiple layers with offsets and varying opacities
    for (int i = 0; i < blurLayers; i++) {
        CGFloat offset = (i * blurRadius) / (blurLayers * 8.0); // Scale offset with blur radius
        CGFloat layerOpacity = (0.08 * intensity) / (i + 1); // Fade each layer
        
        // Create multiple offset rects for stronger blur effect
        NSRect blurRect1 = NSOffsetRect(rect, offset, offset);
        NSRect blurRect2 = NSOffsetRect(rect, -offset, offset);
        NSRect blurRect3 = NSOffsetRect(rect, offset, -offset);
        NSRect blurRect4 = NSOffsetRect(rect, -offset, -offset);
        
        // Use THEME COLORS for blur layers (not selection or separate background colors)
        CGFloat bgRed, bgGreen, bgBlue;
        
        switch (self.currentTheme) {
            case VLC_THEME_DARK:
                bgRed = 0.15; bgGreen = 0.20; bgBlue = 0.30;
                break;
            case VLC_THEME_DARKER:
                bgRed = 0.10; bgGreen = 0.10; bgBlue = 0.10;
                break;
            case VLC_THEME_BLUE:
                bgRed = 0.10; bgGreen = 0.25; bgBlue = 0.45;
                break;
            case VLC_THEME_GREEN:
                bgRed = 0.10; bgGreen = 0.35; bgBlue = 0.20;
                break;
            case VLC_THEME_PURPLE:
                bgRed = 0.35; bgGreen = 0.20; bgBlue = 0.45;
                break;
            case VLC_THEME_CUSTOM:
                bgRed = self.customThemeRed;
                bgGreen = self.customThemeGreen;
                bgBlue = self.customThemeBlue;
                break;
            default:
                bgRed = 0.15; bgGreen = 0.20; bgBlue = 0.30;
                break;
        }
        
        NSColor *blurColor = [NSColor colorWithRed:bgRed green:bgGreen blue:bgBlue alpha:layerOpacity];
        [blurColor set];
        
        NSRectFill(blurRect1);
        NSRectFill(blurRect2);
        NSRectFill(blurRect3);
        NSRectFill(blurRect4);
    }
    
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawFrostedGlass:(NSRect)rect opacity:(CGFloat)opacity cornerRadius:(CGFloat)cornerRadius {
    [NSGraphicsContext saveGraphicsState];
    
    // Use user-configured corner radius if not specified
    CGFloat actualCornerRadius = cornerRadius > 0 ? cornerRadius : [self glassmorphismCornerRadius];
    
    // Create a frosted glass effect with optimized approach
    NSBezierPath *glassPath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:actualCornerRadius yRadius:actualCornerRadius];
    
    // Base frosted layer - now integrates with transparency and theme
    CGFloat baseOpacity = [self glassmorphismOpacity] * [self glassmorphismIntensity];
    CGFloat finalOpacity;
    
    if ([self glassmorphismIgnoreTransparency]) {
        finalOpacity = baseOpacity * opacity;
    } else {
        finalOpacity = baseOpacity * opacity * self.themeAlpha;
    }
    
    NSColor *baseColor = [self glassmorphismBackgroundColor:opacity];
    [baseColor set];
    [glassPath fill];
    
    // Apply backdrop blur effect using user's blur radius setting
    CGFloat userBlurRadius = [self glassmorphismBlurRadius];
    if (userBlurRadius > 0) {
        [self applyBackdropBlur:rect];
    }
    
    // Add texture effects based on quality mode and blur settings
    if ([self glassmorphismHighQuality] && rect.size.width * rect.size.height < 50000) {
        // High quality: Enhanced noise pattern with blur radius influence
        CGFloat blurFactor = userBlurRadius / 25.0; // Normalize blur radius (25.0 is mid-range)
        NSInteger step = MAX(3, 12 - (NSInteger)(blurFactor * 6)); // Smaller steps for higher blur
        
        for (int x = 0; x < rect.size.width; x += step) {
            for (int y = 0; y < rect.size.height; y += step) {
                if ((x + y) % (step * 2) == 0) {
                    // Create multiple noise points for stronger blur effect
                    NSInteger noiseRadius = MAX(1, (NSInteger)(blurFactor * 3));
                    for (int dx = 0; dx < noiseRadius; dx++) {
                        for (int dy = 0; dy < noiseRadius; dy++) {
                            NSRect noiseRect = NSMakeRect(rect.origin.x + x + dx, rect.origin.y + y + dy, 1, 1);
                            CGFloat noiseOpacity = finalOpacity * 0.08 * (1.0 + blurFactor);
                            [[NSColor colorWithWhite:1.0 alpha:noiseOpacity] set];
                            NSRectFill(noiseRect);
                        }
                    }
                }
            }
        }
    } else {
        // Low quality: Enhanced gradient overlay with blur influence
        CGFloat blurFactor = userBlurRadius / 25.0;
        CGFloat gradientOpacity = finalOpacity * (0.3 + blurFactor * 0.4); // Stronger opacity with more blur
        
        NSGradient *noiseGradient = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithWhite:1.0 alpha:gradientOpacity * 0.8],
            [NSColor colorWithWhite:0.7 alpha:gradientOpacity * 0.4],
            [NSColor colorWithWhite:0.9 alpha:gradientOpacity * 0.6],
            [NSColor colorWithWhite:1.0 alpha:gradientOpacity * 0.5]
        ]];
        [noiseGradient drawInBezierPath:glassPath angle:45];
        [noiseGradient release];
        
        // Add additional blur layers for stronger effect
        if (blurFactor > 0.5) {
            NSGradient *secondGradient = [[NSGradient alloc] initWithColors:@[
                [NSColor colorWithWhite:0.8 alpha:gradientOpacity * 0.3],
                [NSColor colorWithWhite:1.0 alpha:gradientOpacity * 0.1],
                [NSColor colorWithWhite:0.6 alpha:gradientOpacity * 0.2]
            ]];
            [secondGradient drawInBezierPath:glassPath angle:135];
            [secondGradient release];
        }
    }
    
    // Add sophisticated sanded effect if enabled
    CGFloat sandedIntensity = [self glassmorphismSandedIntensity];
    if (sandedIntensity > 0.0) {
        [self drawSandedTexture:rect 
                    glassPath:glassPath 
                      opacity:finalOpacity 
                    intensity:sandedIntensity 
                   blurFactor:userBlurRadius / 25.0
                  highQuality:[self glassmorphismHighQuality]];
    }
    
    [NSGraphicsContext restoreGraphicsState];
}

#pragma mark - Sanded Glass Texture Effects

- (void)drawSandedTexture:(NSRect)rect 
                glassPath:(NSBezierPath *)glassPath 
                  opacity:(CGFloat)opacity 
                intensity:(CGFloat)intensity 
               blurFactor:(CGFloat)blurFactor
              highQuality:(BOOL)highQuality {
    // Early exit if intensity is 0% - skip all sanded texture processing
    if (intensity <= 0.1) {
        return;
    }
    
    [NSGraphicsContext saveGraphicsState];
    
    // Clip to the glass shape to ensure texture stays within bounds
    [glassPath addClip];
    
    if (highQuality && rect.size.width * rect.size.height < 80000) {
        // High quality sanded effect with multiple sophisticated patterns
        [self drawHighQualitySandedTexture:rect opacity:opacity intensity:intensity blurFactor:blurFactor];
    } else {
        // Performance-optimized sanded effect
        [self drawOptimizedSandedTexture:rect glassPath:glassPath opacity:opacity intensity:intensity blurFactor:blurFactor];
    }
    
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawHighQualitySandedTexture:(NSRect)rect 
                             opacity:(CGFloat)opacity 
                           intensity:(CGFloat)intensity 
                          blurFactor:(CGFloat)blurFactor {
    // Early exit if intensity is 0% - skip all processing
    if (intensity <= 0.1) {
        return;
    }
    
    // Enhanced sanded glass texture with support for high intensity values
    
    // Scale opacity based on intensity (can now go up to 3.0)
    CGFloat textureOpacity = intensity * (0.4 + blurFactor * 0.2); // Much higher base opacity
    
    // More dots at higher intensities - scales significantly with intensity
    NSInteger maxDots = MIN(400 + (NSInteger)(intensity * 200), (NSInteger)(rect.size.width * rect.size.height * intensity * 0.0006));
    
    for (NSInteger i = 0; i < maxDots; i++) {
        CGFloat x = rect.origin.x + (arc4random_uniform((uint32_t)rect.size.width));
        CGFloat y = rect.origin.y + (arc4random_uniform((uint32_t)rect.size.height));
        
        // Larger dots at higher intensities
        CGFloat dotSize = 1.0 + (intensity * 0.8) + (blurFactor * 0.5) + (arc4random_uniform(150) / 100.0);
        CGFloat dotOpacity = textureOpacity * (0.5 + (arc4random_uniform(100) / 100.0));
        
        // Cap opacity for extreme intensities
        dotOpacity = MIN(0.9, dotOpacity);
        
        [[NSColor colorWithWhite:1.0 alpha:dotOpacity] set];
        
        NSRect dotRect = NSMakeRect(x - dotSize/2, y - dotSize/2, dotSize, dotSize);
        NSRectFill(dotRect);
    }
}

- (void)drawOptimizedSandedTexture:(NSRect)rect 
                          glassPath:(NSBezierPath *)glassPath 
                            opacity:(CGFloat)opacity 
                          intensity:(CGFloat)intensity 
                         blurFactor:(CGFloat)blurFactor {
    // Early exit if intensity is 0% - skip all processing
    if (intensity <= 0.1) {
        return;
    }
    
    // Enhanced optimized sanded glass texture for high intensity values
    
    // Scale gradients based on intensity (can now go up to 3.0)
    CGFloat baseAlpha = intensity * (0.3 + blurFactor * 0.15); // Much higher base alpha
    
    // First gradient - stronger with higher intensities
    NSGradient *sandedGradient = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:1.0 alpha:baseAlpha * 1.2],
        [NSColor colorWithWhite:0.9 alpha:baseAlpha * 0.8],
        [NSColor colorWithWhite:1.0 alpha:baseAlpha * 1.0],
        [NSColor colorWithWhite:0.95 alpha:baseAlpha * 0.6]
    ]];
    
    [sandedGradient drawInBezierPath:glassPath angle:45];
    [sandedGradient release];
    
    // Second gradient - enhanced for texture depth
    NSGradient *textureGradient = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:0.85 alpha:baseAlpha * 0.9],
        [NSColor colorWithWhite:1.0 alpha:baseAlpha * 0.5],
        [NSColor colorWithWhite:0.9 alpha:baseAlpha * 0.7]
    ]];
    
    [textureGradient drawInBezierPath:glassPath angle:135];
    [textureGradient release];
    
    // Add additional gradients for high intensity values
    if (intensity > 1.5) {
        NSGradient *extraGradient = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithWhite:1.0 alpha:baseAlpha * 0.8],
            [NSColor colorWithWhite:0.8 alpha:baseAlpha * 0.4],
            [NSColor colorWithWhite:0.95 alpha:baseAlpha * 0.6]
        ]];
        
        [extraGradient drawInBezierPath:glassPath angle:90];
        [extraGradient release];
    }
    
    // Add extreme intensity gradient for values > 2.5
    if (intensity > 2.5) {
        NSGradient *extremeGradient = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithWhite:0.9 alpha:baseAlpha * 0.7],
            [NSColor colorWithWhite:1.0 alpha:baseAlpha * 0.3],
            [NSColor colorWithWhite:0.85 alpha:baseAlpha * 0.5]
        ]];
        
        [extremeGradient drawInBezierPath:glassPath angle:0];
        [extremeGradient release];
    }
}

@end 

#endif // TARGET_OS_OSX 