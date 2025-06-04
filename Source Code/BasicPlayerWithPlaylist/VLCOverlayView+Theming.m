#import "VLCOverlayView+Theming.h"
#import "VLCOverlayView_Private.h"
#import <objc/runtime.h>

// Static variable to track initialization state
static BOOL isInitializingTheme = NO;

@implementation VLCOverlayView (Theming)

#pragma mark - Theme System

- (void)initializeThemeSystem {
    NSLog(@"Theme System: Starting initialization");
    
    // Set initialization flag to prevent recursive updates
    isInitializingTheme = YES;
    
    // Load saved theme settings
    [self loadThemeSettings];
    
    // Clear initialization flag
    isInitializingTheme = NO;
    
    // Apply the loaded theme
    [self updateThemeColors];
    
    NSLog(@"Theme System: Initialization complete");
}

- (void)applyTheme:(VLCColorTheme)theme {
    NSLog(@"Theme System: Applying theme %ld", (long)theme);
    self.currentTheme = theme;
    [self updateThemeColors];
    
    // Save all settings including the new selection colors
    [self saveThemeSettings];
    [self setNeedsDisplay:YES];
    NSLog(@"Theme System: Applied theme %ld with matching selection colors", (long)theme);
}

- (void)setTransparencyLevel:(VLCTransparencyLevel)level {
    NSLog(@"Theme System: Setting transparency level %ld (isInitializing: %@)", (long)level, isInitializingTheme ? @"YES" : @"NO");
    
    // During initialization, just set the value and return immediately
    if (isInitializingTheme) {
        NSLog(@"Theme System: Setting transparency level directly during initialization");
        
        // Use runtime to directly set the instance variable, completely bypassing any setter
        Ivar transparencyLevelIvar = class_getInstanceVariable([self class], "_transparencyLevel");
        if (transparencyLevelIvar != NULL) {
            object_setIvar(self, transparencyLevelIvar, (id)(NSInteger)level);
            NSLog(@"Theme System: Successfully set _transparencyLevel directly to %ld", (long)level);
        } else {
            NSLog(@"Theme System: WARNING - Could not find _transparencyLevel instance variable");
        }
        return;
    }
    
    // Normal operation (not during initialization)
    // Use runtime to set the instance variable to avoid recursion
    Ivar transparencyLevelIvar = class_getInstanceVariable([self class], "_transparencyLevel");
    if (transparencyLevelIvar != NULL) {
        object_setIvar(self, transparencyLevelIvar, (id)(NSInteger)level);
    }
    
    self.themeAlpha = [self alphaForTransparencyLevel:level];
    
    NSLog(@"Theme System: Updating colors and saving settings for transparency level %ld", (long)level);
    [self updateThemeColors];
    [self saveThemeSettings];
    [self setNeedsDisplay:YES];
}

- (CGFloat)alphaForTransparencyLevel:(VLCTransparencyLevel)level {
    switch (level) {
        case VLC_TRANSPARENCY_OPAQUE:     return 0.95f;
        case VLC_TRANSPARENCY_LIGHT:      return 0.85f;
        case VLC_TRANSPARENCY_MEDIUM:     return 0.75f;
        case VLC_TRANSPARENCY_HIGH:       return 0.65f;
        case VLC_TRANSPARENCY_VERY_HIGH:  return 0.5f;
        default:                          return 0.75f;
    }
}

- (void)updateThemeColors {
    NSLog(@"Theme System: Updating theme colors for theme %ld with alpha %.2f", (long)self.currentTheme, self.themeAlpha);
    CGFloat alpha = self.themeAlpha;
    
    switch (self.currentTheme) {
        case VLC_THEME_DARK:
            // Default dark theme (current colors)
            self.themeCategoryStartColor = [NSColor colorWithCalibratedRed:0.08 green:0.10 blue:0.14 alpha:alpha];
            self.themeCategoryEndColor = [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:alpha];
            self.themeGroupStartColor = [NSColor colorWithCalibratedRed:0.08 green:0.10 blue:0.14 alpha:alpha];
            self.themeGroupEndColor = [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:alpha];
            self.themeChannelStartColor = [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:alpha];
            self.themeChannelEndColor = [NSColor colorWithCalibratedRed:0.12 green:0.14 blue:0.18 alpha:alpha];
            
            // Set theme-appropriate selection colors for dark theme
            self.customSelectionRed = 0.2;
            self.customSelectionGreen = 0.4;
            self.customSelectionBlue = 0.9;
            break;
            
        case VLC_THEME_DARKER:
            // Even darker theme
            self.themeCategoryStartColor = [NSColor colorWithCalibratedRed:0.05 green:0.05 blue:0.05 alpha:alpha];
            self.themeCategoryEndColor = [NSColor colorWithCalibratedRed:0.08 green:0.08 blue:0.08 alpha:alpha];
            self.themeGroupStartColor = [NSColor colorWithCalibratedRed:0.05 green:0.05 blue:0.05 alpha:alpha];
            self.themeGroupEndColor = [NSColor colorWithCalibratedRed:0.08 green:0.08 blue:0.08 alpha:alpha];
            self.themeChannelStartColor = [NSColor colorWithCalibratedRed:0.08 green:0.08 blue:0.08 alpha:alpha];
            self.themeChannelEndColor = [NSColor colorWithCalibratedRed:0.10 green:0.10 blue:0.10 alpha:alpha];
            
            // Set theme-appropriate selection colors for darker theme
            self.customSelectionRed = 0.3;
            self.customSelectionGreen = 0.5;
            self.customSelectionBlue = 1.0;
            break;
            
        case VLC_THEME_BLUE:
            // Blue accent theme
            self.themeCategoryStartColor = [NSColor colorWithCalibratedRed:0.05 green:0.08 blue:0.15 alpha:alpha];
            self.themeCategoryEndColor = [NSColor colorWithCalibratedRed:0.08 green:0.12 blue:0.20 alpha:alpha];
            self.themeGroupStartColor = [NSColor colorWithCalibratedRed:0.05 green:0.08 blue:0.15 alpha:alpha];
            self.themeGroupEndColor = [NSColor colorWithCalibratedRed:0.08 green:0.12 blue:0.20 alpha:alpha];
            self.themeChannelStartColor = [NSColor colorWithCalibratedRed:0.08 green:0.12 blue:0.20 alpha:alpha];
            self.themeChannelEndColor = [NSColor colorWithCalibratedRed:0.10 green:0.15 blue:0.25 alpha:alpha];
            
            // Set theme-appropriate selection colors for blue theme
            self.customSelectionRed = 0.1;
            self.customSelectionGreen = 0.5;
            self.customSelectionBlue = 1.0;
            break;
            
        case VLC_THEME_GREEN:
            // Green accent theme
            self.themeCategoryStartColor = [NSColor colorWithCalibratedRed:0.05 green:0.12 blue:0.08 alpha:alpha];
            self.themeCategoryEndColor = [NSColor colorWithCalibratedRed:0.08 green:0.16 blue:0.12 alpha:alpha];
            self.themeGroupStartColor = [NSColor colorWithCalibratedRed:0.05 green:0.12 blue:0.08 alpha:alpha];
            self.themeGroupEndColor = [NSColor colorWithCalibratedRed:0.08 green:0.16 blue:0.12 alpha:alpha];
            self.themeChannelStartColor = [NSColor colorWithCalibratedRed:0.08 green:0.16 blue:0.12 alpha:alpha];
            self.themeChannelEndColor = [NSColor colorWithCalibratedRed:0.10 green:0.20 blue:0.15 alpha:alpha];
            
            // Set theme-appropriate selection colors for green theme
            self.customSelectionRed = 0.1;
            self.customSelectionGreen = 0.8;
            self.customSelectionBlue = 0.3;
            break;
            
        case VLC_THEME_PURPLE:
            // Purple accent theme
            self.themeCategoryStartColor = [NSColor colorWithCalibratedRed:0.12 green:0.08 blue:0.15 alpha:alpha];
            self.themeCategoryEndColor = [NSColor colorWithCalibratedRed:0.16 green:0.12 blue:0.20 alpha:alpha];
            self.themeGroupStartColor = [NSColor colorWithCalibratedRed:0.12 green:0.08 blue:0.15 alpha:alpha];
            self.themeGroupEndColor = [NSColor colorWithCalibratedRed:0.16 green:0.12 blue:0.20 alpha:alpha];
            self.themeChannelStartColor = [NSColor colorWithCalibratedRed:0.16 green:0.12 blue:0.20 alpha:alpha];
            self.themeChannelEndColor = [NSColor colorWithCalibratedRed:0.20 green:0.15 blue:0.25 alpha:alpha];
            
            // Set theme-appropriate selection colors for purple theme
            self.customSelectionRed = 0.7;
            self.customSelectionGreen = 0.3;
            self.customSelectionBlue = 1.0;
            break;
            
        case VLC_THEME_CUSTOM:
            // Custom theme - use user-defined RGB values
            CGFloat baseR = self.customThemeRed;
            CGFloat baseG = self.customThemeGreen;
            CGFloat baseB = self.customThemeBlue;
            
            // Create gradient variations using the base custom color
            self.themeCategoryStartColor = [NSColor colorWithCalibratedRed:baseR * 0.8 green:baseG * 0.8 blue:baseB * 0.8 alpha:alpha];
            self.themeCategoryEndColor = [NSColor colorWithCalibratedRed:baseR green:baseG blue:baseB alpha:alpha];
            self.themeGroupStartColor = [NSColor colorWithCalibratedRed:baseR * 0.8 green:baseG * 0.8 blue:baseB * 0.8 alpha:alpha];
            self.themeGroupEndColor = [NSColor colorWithCalibratedRed:baseR green:baseG blue:baseB alpha:alpha];
            self.themeChannelStartColor = [NSColor colorWithCalibratedRed:baseR green:baseG blue:baseB alpha:alpha];
            self.themeChannelEndColor = [NSColor colorWithCalibratedRed:baseR * 1.2 green:baseG * 1.2 blue:baseB * 1.2 alpha:alpha];
            
            // For custom theme, keep the current selection colors unchanged
            // (user may have set them manually)
            break;
    }
    
    // Update the hover color after selection colors are set
    if (self.currentTheme != VLC_THEME_CUSTOM) {
        [self updateSelectionColors];
    }
}

- (void)saveThemeSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.currentTheme forKey:@"VLCOverlayTheme"];
    [defaults setInteger:self.transparencyLevel forKey:@"VLCOverlayTransparency"];
    [defaults setFloat:self.themeAlpha forKey:@"VLCOverlayThemeAlpha"];
    [defaults setFloat:self.customThemeRed forKey:@"VLCOverlayCustomRed"];
    [defaults setFloat:self.customThemeGreen forKey:@"VLCOverlayCustomGreen"];
    [defaults setFloat:self.customThemeBlue forKey:@"VLCOverlayCustomBlue"];
    
    // Save selection color values
    [defaults setFloat:self.customSelectionRed forKey:@"VLCOverlaySelectionRed"];
    [defaults setFloat:self.customSelectionGreen forKey:@"VLCOverlaySelectionGreen"];
    [defaults setFloat:self.customSelectionBlue forKey:@"VLCOverlaySelectionBlue"];
    
    [defaults synchronize];
}

- (void)loadThemeSettings {
    NSLog(@"Theme System: Loading theme settings");
    
    // Ensure we're in initialization mode
    BOOL wasInitializing = isInitializingTheme;
    isInitializingTheme = YES;
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Load current theme
    NSInteger savedTheme = [defaults integerForKey:@"VLCOverlayTheme"];
    self.currentTheme = savedTheme;
    
    // Load transparency (default to VLC_TRANSPARENCY_MEDIUM) - avoid property setters during init
    VLCTransparencyLevel loadedTransparency = [defaults integerForKey:@"VLCOverlayTransparency"];
    if (loadedTransparency < VLC_TRANSPARENCY_OPAQUE || loadedTransparency > VLC_TRANSPARENCY_VERY_HIGH) {
        loadedTransparency = VLC_TRANSPARENCY_MEDIUM;
    }
    NSLog(@"Theme System: Loaded transparency: %ld", (long)loadedTransparency);
    
    // Load custom RGB values (default to dark theme colors)
    CGFloat loadedRed = [defaults floatForKey:@"VLCOverlayCustomRed"];
    CGFloat loadedGreen = [defaults floatForKey:@"VLCOverlayCustomGreen"];
    CGFloat loadedBlue = [defaults floatForKey:@"VLCOverlayCustomBlue"];
    
    // If no custom values saved, use default dark theme values
    if (loadedRed == 0.0 && loadedGreen == 0.0 && loadedBlue == 0.0) {
        loadedRed = 0.10;
        loadedGreen = 0.12;
        loadedBlue = 0.16;
    }
    
    self.customThemeRed = loadedRed;
    self.customThemeGreen = loadedGreen;
    self.customThemeBlue = loadedBlue;
    NSLog(@"Theme System: Loaded custom RGB: %.2f, %.2f, %.2f", loadedRed, loadedGreen, loadedBlue);
    
    // Load selection color values (default to nice blue if not saved)
    CGFloat loadedSelectionRed = [defaults floatForKey:@"VLCOverlaySelectionRed"];
    CGFloat loadedSelectionGreen = [defaults floatForKey:@"VLCOverlaySelectionGreen"];
    CGFloat loadedSelectionBlue = [defaults floatForKey:@"VLCOverlaySelectionBlue"];
    
    // If no selection colors saved, use default blue selection color
    if (loadedSelectionRed == 0.0 && loadedSelectionGreen == 0.0 && loadedSelectionBlue == 0.0) {
        loadedSelectionRed = 0.2;
        loadedSelectionGreen = 0.4;
        loadedSelectionBlue = 0.9;
    }
    
    self.customSelectionRed = loadedSelectionRed;
    self.customSelectionGreen = loadedSelectionGreen;
    self.customSelectionBlue = loadedSelectionBlue;
    NSLog(@"Theme System: Loaded selection RGB: %.2f, %.2f, %.2f", 
          loadedSelectionRed, loadedSelectionGreen, loadedSelectionBlue);
    
    // Load custom alpha value (for smooth transparency)
    CGFloat loadedAlpha = [defaults floatForKey:@"VLCOverlayThemeAlpha"];
    if (loadedAlpha == 0.0) {
        // If no custom alpha saved, calculate from transparency level
        loadedAlpha = [self alphaForTransparencyLevel:loadedTransparency];
    }
    
    // Store values directly in instance variables during initialization to avoid any setter side effects
    if (wasInitializing) {
        NSLog(@"Theme System: Setting values directly during initialization");
        
        // Set currentTheme using KVC (this one doesn't have a custom setter causing issues)
        [self setValue:@(savedTheme) forKey:@"currentTheme"];
        
        // Set transparencyLevel using runtime to completely bypass the setter
        Ivar transparencyLevelIvar = class_getInstanceVariable([self class], "_transparencyLevel");
        if (transparencyLevelIvar != NULL) {
            object_setIvar(self, transparencyLevelIvar, (id)(NSInteger)loadedTransparency);
            NSLog(@"Theme System: Set _transparencyLevel directly to %ld", (long)loadedTransparency);
        } else {
            NSLog(@"Theme System: WARNING - Could not find _transparencyLevel instance variable");
        }
        
        // Set themeAlpha to the saved value (or calculated value)
        [self setValue:@(loadedAlpha) forKey:@"themeAlpha"];
        NSLog(@"Theme System: Set themeAlpha to %.2f", loadedAlpha);
    } else {
        NSLog(@"Theme System: Using property setters (not during initialization)");
        self.currentTheme = savedTheme;
        self.transparencyLevel = loadedTransparency;
        self.themeAlpha = loadedAlpha;
    }
    
    // Restore initialization flag
    isInitializingTheme = wasInitializing;
    
    // Apply theme colors after loading (unless we're already initializing)
    if (!wasInitializing) {
        [self updateThemeColors];
    }
    
    NSLog(@"Theme System: Finished loading theme settings");
}

#pragma mark - Custom Theme RGB Helper

- (void)customRGBValueChanged {
    // Only update theme if we're in custom theme mode and not initializing
    if (self.currentTheme == VLC_THEME_CUSTOM && !isInitializingTheme) {
        [self updateThemeColors];
        [self saveThemeSettings];
        [self setNeedsDisplay:YES];
    }
}

// Method to update selection colors and calculate hover color
- (void)updateSelectionColors {
    // Store the values for use throughout the app
    // The hover color is automatically calculated as a lighter version of the selection color
    
    // Hover color calculation: blend with white for a softer hover effect
    CGFloat blendFactor = 0.5; // 50% blend with white (increased from 0.3 for better visibility)
    CGFloat hoverRed = self.customSelectionRed + (1.0 - self.customSelectionRed) * blendFactor;
    CGFloat hoverGreen = self.customSelectionGreen + (1.0 - self.customSelectionGreen) * blendFactor;
    CGFloat hoverBlue = self.customSelectionBlue + (1.0 - self.customSelectionBlue) * blendFactor;
    
    // Update the hoverColor property for backward compatibility
    self.hoverColor = [NSColor colorWithCalibratedRed:hoverRed green:hoverGreen blue:hoverBlue alpha:0.25]; // Increased alpha from 0.15
    
    // Save the settings
    [self saveThemeSettings];
    
    NSLog(@"Selection Colors Updated: R=%.2f G=%.2f B=%.2f", 
          self.customSelectionRed, self.customSelectionGreen, self.customSelectionBlue);
    NSLog(@"Calculated Hover Colors: R=%.2f G=%.2f B=%.2f", 
          hoverRed, hoverGreen, hoverBlue);
}

@end 