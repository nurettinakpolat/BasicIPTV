#import "VLCOverlayView+Theming.h"

#if TARGET_OS_OSX
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+Glassmorphism.h"
#import <objc/runtime.h>

// Static variable to track initialization state
static BOOL isInitializingTheme = NO;

@implementation VLCOverlayView (Theming)

#pragma mark - Theme System

- (void)initializeThemeSystem {
    //NSLog(@"Theme System: Starting initialization");
    
    // Set initialization flag to prevent recursive updates
    isInitializingTheme = YES;
    
    // Load saved theme settings
    [self loadThemeSettings];
    
    // Clear initialization flag
    isInitializingTheme = NO;
    
    // Apply the loaded theme
    [self updateThemeColors];
    
    //NSLog(@"Theme System: Initialization complete");
}

- (void)applyTheme:(VLCColorTheme)theme {
    //NSLog(@"Theme System: Applying theme %ld", (long)theme);
    self.currentTheme = theme;
    [self updateThemeColors];
    
    // Save all settings including the new selection colors
    [self saveThemeSettings];
    [self setNeedsDisplay:YES];
    //NSLog(@"Theme System: Applied theme %ld with matching selection colors", (long)theme);
}

- (void)setTransparencyLevel:(VLCTransparencyLevel)level {
    //NSLog(@"Theme System: Setting transparency level %ld (isInitializing: %@)", (long)level, isInitializingTheme ? @"YES" : @"NO");
    
    // During initialization, just set the value and return immediately
    if (isInitializingTheme) {
        //NSLog(@"Theme System: Setting transparency level directly during initialization");
        
        // Use runtime to directly set the instance variable, completely bypassing any setter
        Ivar transparencyLevelIvar = class_getInstanceVariable([self class], "_transparencyLevel");
        if (transparencyLevelIvar != NULL) {
            object_setIvar(self, transparencyLevelIvar, (id)(NSInteger)level);
            //NSLog(@"Theme System: Successfully set _transparencyLevel directly to %ld", (long)level);
        } else {
            //NSLog(@"Theme System: WARNING - Could not find _transparencyLevel instance variable");
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
    
    //NSLog(@"Theme System: Updating colors and saving settings for transparency level %ld", (long)level);
    [self updateThemeColors];
    [self saveThemeSettings];
    
    // Update glassmorphism effects when transparency changes
    if ([self glassmorphismEnabled]) {
        // Glassmorphism effects will automatically use the new themeAlpha value
        [self setNeedsDisplay:YES];
    } else {
        [self setNeedsDisplay:YES];
    }
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
    //NSLog(@"Theme System: Updating theme colors for theme %ld with alpha %.2f", (long)self.currentTheme, self.themeAlpha);
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
    
    // Trigger glassmorphism effects update when theme changes
    if ([self glassmorphismEnabled]) {
        // Force a redraw to apply new theme colors to glassmorphism
        [self setNeedsDisplay:YES];
    }
}

- (void)saveThemeSettings {
    // Store theme settings in Application Support instead of UserDefaults
    NSString *themeSettingsPath = [self themeSettingsFilePath];
    NSMutableDictionary *themeDict = [NSMutableDictionary dictionary];
    
    [themeDict setObject:@(self.currentTheme) forKey:@"VLCOverlayTheme"];
    [themeDict setObject:@(self.transparencyLevel) forKey:@"VLCOverlayTransparency"];
    [themeDict setObject:@(self.themeAlpha) forKey:@"VLCOverlayThemeAlpha"];
    [themeDict setObject:@(self.customThemeRed) forKey:@"VLCOverlayCustomRed"];
    [themeDict setObject:@(self.customThemeGreen) forKey:@"VLCOverlayCustomGreen"];
    [themeDict setObject:@(self.customThemeBlue) forKey:@"VLCOverlayCustomBlue"];
    
    // Save selection color values
    [themeDict setObject:@(self.customSelectionRed) forKey:@"VLCOverlaySelectionRed"];
    [themeDict setObject:@(self.customSelectionGreen) forKey:@"VLCOverlaySelectionGreen"];
    [themeDict setObject:@(self.customSelectionBlue) forKey:@"VLCOverlaySelectionBlue"];
    
    // Save glassmorphism settings
    [themeDict setObject:@([self glassmorphismEnabled]) forKey:@"VLCOverlayGlassmorphismEnabled"];
    [themeDict setObject:@([self glassmorphismIntensity]) forKey:@"VLCOverlayGlassmorphismIntensity"];
    [themeDict setObject:@([self glassmorphismHighQuality]) forKey:@"VLCOverlayGlassmorphismHighQuality"];
    
    // Save granular glassmorphism settings
    [themeDict setObject:@([self glassmorphismOpacity]) forKey:@"VLCOverlayGlassmorphismOpacity"];
    [themeDict setObject:@([self glassmorphismBlurRadius]) forKey:@"VLCOverlayGlassmorphismBlurRadius"];
    [themeDict setObject:@([self glassmorphismBorderWidth]) forKey:@"VLCOverlayGlassmorphismBorderWidth"];
    [themeDict setObject:@([self glassmorphismCornerRadius]) forKey:@"VLCOverlayGlassmorphismCornerRadius"];
    [themeDict setObject:@([self glassmorphismIgnoreTransparency]) forKey:@"VLCOverlayGlassmorphismIgnoreTransparency"];
    [themeDict setObject:@([self glassmorphismSandedIntensity]) forKey:@"VLCOverlayGlassmorphismSandedIntensity"];
    
    // Write to file
    BOOL success = [themeDict writeToFile:themeSettingsPath atomically:YES];
    if (!success) {
        //NSLog(@"Failed to save theme settings to: %@", themeSettingsPath);
    }
}

- (void)loadThemeSettings {
    //NSLog(@"Theme System: Loading theme settings");
    
    // Ensure we're in initialization mode
    BOOL wasInitializing = isInitializingTheme;
    isInitializingTheme = YES;
    
    // Load theme settings from Application Support instead of UserDefaults
    NSString *themeSettingsPath = [self themeSettingsFilePath];
    NSDictionary *themeDict = [NSDictionary dictionaryWithContentsOfFile:themeSettingsPath];
    
    if (!themeDict) {
        // MIGRATION: Check if we have old UserDefaults theme data to migrate
        [self migrateThemeSettingsToApplicationSupport];
        // Try loading again after migration
        themeDict = [NSDictionary dictionaryWithContentsOfFile:themeSettingsPath];
    }
    
    if (!themeDict) {
        // No theme settings found, use defaults with 0.9 transparency
        //NSLog(@"No theme settings file found, using defaults with 0.9 transparency");
        
        // Set default theme alpha to 0.9 when no settings exist
        // Store values directly in instance variables during initialization to avoid setter side effects
        if (wasInitializing) {
            // Set currentTheme to dark theme
            [self setValue:@(VLC_THEME_DARK) forKey:@"currentTheme"];
            
            // Set transparencyLevel using runtime to completely bypass the setter
            // Use LIGHT transparency as the closest to 0.9 (which is 0.85, we'll override the alpha)
            Ivar transparencyLevelIvar = class_getInstanceVariable([self class], "_transparencyLevel");
            if (transparencyLevelIvar != NULL) {
                object_setIvar(self, transparencyLevelIvar, (id)(NSInteger)VLC_TRANSPARENCY_LIGHT);
            }
            
            // Set themeAlpha directly to 0.9 (overriding the transparency level calculation)
            [self setValue:@(0.9f) forKey:@"themeAlpha"];
            //NSLog(@"Theme System: Set default themeAlpha to 0.9");
        } else {
            self.currentTheme = VLC_THEME_DARK;
            self.transparencyLevel = VLC_TRANSPARENCY_LIGHT;
            self.themeAlpha = 0.9f;
        }
        
        // Set default custom theme RGB values
        self.customThemeRed = 0.10;
        self.customThemeGreen = 0.12;
        self.customThemeBlue = 0.16;
        
        // Set default selection colors
        self.customSelectionRed = 0.2;
        self.customSelectionGreen = 0.4;
        self.customSelectionBlue = 0.9;
        
        // Set default glassmorphism settings
        [self setGlassmorphismEnabled:YES];
        [self setGlassmorphismIntensity:1.0];
        [self setGlassmorphismHighQuality:NO]; // Default to low quality for performance
        
        // Set default granular glassmorphism settings
        [self setGlassmorphismOpacity:1.2];
        [self setGlassmorphismBlurRadius:25.0];
        [self setGlassmorphismBorderWidth:1.0];
        [self setGlassmorphismCornerRadius:8.0];
        [self setGlassmorphismIgnoreTransparency:NO];
        [self setGlassmorphismSandedIntensity:0.0]; // Default no sanded effect
        
        isInitializingTheme = wasInitializing;
        return;
    }
    
    // Load current theme
    NSNumber *savedTheme = [themeDict objectForKey:@"VLCOverlayTheme"];
    NSInteger themeValue = savedTheme ? [savedTheme integerValue] : VLC_THEME_DARK;
    self.currentTheme = themeValue;
    
    // Load transparency (default to VLC_TRANSPARENCY_MEDIUM) - avoid property setters during init
    NSNumber *savedTransparency = [themeDict objectForKey:@"VLCOverlayTransparency"];
    VLCTransparencyLevel loadedTransparency = savedTransparency ? [savedTransparency integerValue] : VLC_TRANSPARENCY_MEDIUM;
    if (loadedTransparency < VLC_TRANSPARENCY_OPAQUE || loadedTransparency > VLC_TRANSPARENCY_VERY_HIGH) {
        loadedTransparency = VLC_TRANSPARENCY_MEDIUM;
    }
    //NSLog(@"Theme System: Loaded transparency: %ld", (long)loadedTransparency);
    
    // Load custom RGB values (default to dark theme colors)
    NSNumber *savedRed = [themeDict objectForKey:@"VLCOverlayCustomRed"];
    NSNumber *savedGreen = [themeDict objectForKey:@"VLCOverlayCustomGreen"];
    NSNumber *savedBlue = [themeDict objectForKey:@"VLCOverlayCustomBlue"];
    
    CGFloat loadedRed = savedRed ? [savedRed floatValue] : 0.10;
    CGFloat loadedGreen = savedGreen ? [savedGreen floatValue] : 0.12;
    CGFloat loadedBlue = savedBlue ? [savedBlue floatValue] : 0.16;
    
    // If no custom values saved, use default dark theme values
    if (loadedRed == 0.0 && loadedGreen == 0.0 && loadedBlue == 0.0) {
        loadedRed = 0.10;
        loadedGreen = 0.12;
        loadedBlue = 0.16;
    }
    
    self.customThemeRed = loadedRed;
    self.customThemeGreen = loadedGreen;
    self.customThemeBlue = loadedBlue;
    //NSLog(@"Theme System: Loaded custom RGB: %.2f, %.2f, %.2f", loadedRed, loadedGreen, loadedBlue);
    
    // Load selection color values (default to nice blue if not saved)
    NSNumber *savedSelectionRed = [themeDict objectForKey:@"VLCOverlaySelectionRed"];
    NSNumber *savedSelectionGreen = [themeDict objectForKey:@"VLCOverlaySelectionGreen"];
    NSNumber *savedSelectionBlue = [themeDict objectForKey:@"VLCOverlaySelectionBlue"];
    
    CGFloat loadedSelectionRed = savedSelectionRed ? [savedSelectionRed floatValue] : 0.2;
    CGFloat loadedSelectionGreen = savedSelectionGreen ? [savedSelectionGreen floatValue] : 0.4;
    CGFloat loadedSelectionBlue = savedSelectionBlue ? [savedSelectionBlue floatValue] : 0.9;
    
    // If no selection colors saved, use default blue selection color
    if (loadedSelectionRed == 0.0 && loadedSelectionGreen == 0.0 && loadedSelectionBlue == 0.0) {
        loadedSelectionRed = 0.2;
        loadedSelectionGreen = 0.4;
        loadedSelectionBlue = 0.9;
    }
    
    self.customSelectionRed = loadedSelectionRed;
    self.customSelectionGreen = loadedSelectionGreen;
    self.customSelectionBlue = loadedSelectionBlue;
    //NSLog(@"Theme System: Loaded selection RGB: %.2f, %.2f, %.2f", 
    //      loadedSelectionRed, loadedSelectionGreen, loadedSelectionBlue);
    
    // Load glassmorphism settings (default to enabled with full intensity, low quality)
    NSNumber *savedGlassEnabled = [themeDict objectForKey:@"VLCOverlayGlassmorphismEnabled"];
    NSNumber *savedGlassIntensity = [themeDict objectForKey:@"VLCOverlayGlassmorphismIntensity"];
    NSNumber *savedGlassHighQuality = [themeDict objectForKey:@"VLCOverlayGlassmorphismHighQuality"];
    
    BOOL loadedGlassEnabled = savedGlassEnabled ? [savedGlassEnabled boolValue] : YES;
    CGFloat loadedGlassIntensity = savedGlassIntensity ? [savedGlassIntensity floatValue] : 1.0;
    BOOL loadedGlassHighQuality = savedGlassHighQuality ? [savedGlassHighQuality boolValue] : NO;
    
    [self setGlassmorphismEnabled:loadedGlassEnabled];
    [self setGlassmorphismIntensity:loadedGlassIntensity];
    [self setGlassmorphismHighQuality:loadedGlassHighQuality];
    
    // Load granular glassmorphism settings
    NSNumber *savedGlassOpacity = [themeDict objectForKey:@"VLCOverlayGlassmorphismOpacity"];
    NSNumber *savedGlassBlurRadius = [themeDict objectForKey:@"VLCOverlayGlassmorphismBlurRadius"];
    NSNumber *savedGlassBorderWidth = [themeDict objectForKey:@"VLCOverlayGlassmorphismBorderWidth"];
    NSNumber *savedGlassCornerRadius = [themeDict objectForKey:@"VLCOverlayGlassmorphismCornerRadius"];
    NSNumber *savedGlassIgnoreTransparency = [themeDict objectForKey:@"VLCOverlayGlassmorphismIgnoreTransparency"];
    NSNumber *savedGlassSandedIntensity = [themeDict objectForKey:@"VLCOverlayGlassmorphismSandedIntensity"];
    
            CGFloat loadedGlassOpacity = savedGlassOpacity ? [savedGlassOpacity floatValue] : 1.2;
            CGFloat loadedGlassBlurRadius = savedGlassBlurRadius ? [savedGlassBlurRadius floatValue] : 25.0;
    CGFloat loadedGlassBorderWidth = savedGlassBorderWidth ? [savedGlassBorderWidth floatValue] : 1.0;
    CGFloat loadedGlassCornerRadius = savedGlassCornerRadius ? [savedGlassCornerRadius floatValue] : 8.0;
    BOOL loadedGlassIgnoreTransparency = savedGlassIgnoreTransparency ? [savedGlassIgnoreTransparency boolValue] : NO;
    CGFloat loadedGlassSandedIntensity = savedGlassSandedIntensity ? [savedGlassSandedIntensity floatValue] : 0.0;
    
    [self setGlassmorphismOpacity:loadedGlassOpacity];
    [self setGlassmorphismBlurRadius:loadedGlassBlurRadius];
    [self setGlassmorphismBorderWidth:loadedGlassBorderWidth];
    [self setGlassmorphismCornerRadius:loadedGlassCornerRadius];
    [self setGlassmorphismIgnoreTransparency:loadedGlassIgnoreTransparency];
    [self setGlassmorphismSandedIntensity:loadedGlassSandedIntensity];
    
    // Load custom alpha value (for smooth transparency)
    NSNumber *savedAlpha = [themeDict objectForKey:@"VLCOverlayThemeAlpha"];
    CGFloat loadedAlpha = savedAlpha ? [savedAlpha floatValue] : [self alphaForTransparencyLevel:loadedTransparency];
    if (loadedAlpha == 0.0) {
        // If no custom alpha saved, calculate from transparency level
        loadedAlpha = [self alphaForTransparencyLevel:loadedTransparency];
    }
    
    // Store values directly in instance variables during initialization to avoid any setter side effects
    if (wasInitializing) {
        //NSLog(@"Theme System: Setting values directly during initialization");
        
        // Set currentTheme using KVC (this one doesn't have a custom setter causing issues)
        [self setValue:@(themeValue) forKey:@"currentTheme"];
        
        // Set transparencyLevel using runtime to completely bypass the setter
        Ivar transparencyLevelIvar = class_getInstanceVariable([self class], "_transparencyLevel");
        if (transparencyLevelIvar != NULL) {
            object_setIvar(self, transparencyLevelIvar, (id)(NSInteger)loadedTransparency);
            //NSLog(@"Theme System: Set _transparencyLevel directly to %ld", (long)loadedTransparency);
        } else {
            //NSLog(@"Theme System: WARNING - Could not find _transparencyLevel instance variable");
        }
        
        // Set themeAlpha to the saved value (or calculated value)
        [self setValue:@(loadedAlpha) forKey:@"themeAlpha"];
        //NSLog(@"Theme System: Set themeAlpha to %.2f", loadedAlpha);
    } else {
        //NSLog(@"Theme System: Using property setters (not during initialization)");
        self.currentTheme = themeValue;
        self.transparencyLevel = loadedTransparency;
        self.themeAlpha = loadedAlpha;
    }
    
    // Restore initialization flag
    isInitializingTheme = wasInitializing;
    
    // Apply theme colors after loading (unless we're already initializing)
    if (!wasInitializing) {
        [self updateThemeColors];
    }
    
    //NSLog(@"Theme System: Finished loading theme settings");
}

// Helper method to get the theme settings file path
- (NSString *)themeSettingsFilePath {
    NSString *appSupportDir = [self applicationSupportDirectory];
    return [appSupportDir stringByAppendingPathComponent:@"theme_settings.plist"];
}

// Migration method to move theme UserDefaults data to Application Support
- (void)migrateThemeSettingsToApplicationSupport {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *themeDict = [NSMutableDictionary dictionary];
    BOOL hasDataToMigrate = NO;
    
    // Check for existing theme settings in UserDefaults
    if ([defaults objectForKey:@"VLCOverlayTheme"]) {
        [themeDict setObject:@([defaults integerForKey:@"VLCOverlayTheme"]) forKey:@"VLCOverlayTheme"];
        hasDataToMigrate = YES;
    }
    
    if ([defaults objectForKey:@"VLCOverlayTransparency"]) {
        [themeDict setObject:@([defaults integerForKey:@"VLCOverlayTransparency"]) forKey:@"VLCOverlayTransparency"];
        hasDataToMigrate = YES;
    }
    
    if ([defaults objectForKey:@"VLCOverlayThemeAlpha"]) {
        [themeDict setObject:@([defaults floatForKey:@"VLCOverlayThemeAlpha"]) forKey:@"VLCOverlayThemeAlpha"];
        hasDataToMigrate = YES;
    }
    
    if ([defaults objectForKey:@"VLCOverlayCustomRed"]) {
        [themeDict setObject:@([defaults floatForKey:@"VLCOverlayCustomRed"]) forKey:@"VLCOverlayCustomRed"];
        hasDataToMigrate = YES;
    }
    
    if ([defaults objectForKey:@"VLCOverlayCustomGreen"]) {
        [themeDict setObject:@([defaults floatForKey:@"VLCOverlayCustomGreen"]) forKey:@"VLCOverlayCustomGreen"];
        hasDataToMigrate = YES;
    }
    
    if ([defaults objectForKey:@"VLCOverlayCustomBlue"]) {
        [themeDict setObject:@([defaults floatForKey:@"VLCOverlayCustomBlue"]) forKey:@"VLCOverlayCustomBlue"];
        hasDataToMigrate = YES;
    }
    
    if ([defaults objectForKey:@"VLCOverlaySelectionRed"]) {
        [themeDict setObject:@([defaults floatForKey:@"VLCOverlaySelectionRed"]) forKey:@"VLCOverlaySelectionRed"];
        hasDataToMigrate = YES;
    }
    
    if ([defaults objectForKey:@"VLCOverlaySelectionGreen"]) {
        [themeDict setObject:@([defaults floatForKey:@"VLCOverlaySelectionGreen"]) forKey:@"VLCOverlaySelectionGreen"];
        hasDataToMigrate = YES;
    }
    
    if ([defaults objectForKey:@"VLCOverlaySelectionBlue"]) {
        [themeDict setObject:@([defaults floatForKey:@"VLCOverlaySelectionBlue"]) forKey:@"VLCOverlaySelectionBlue"];
        hasDataToMigrate = YES;
    }
    
    if (hasDataToMigrate) {
        // Save migrated theme data to Application Support
        NSString *themeSettingsPath = [self themeSettingsFilePath];
        BOOL success = [themeDict writeToFile:themeSettingsPath atomically:YES];
        
        if (success) {
            //NSLog(@"Successfully migrated theme UserDefaults data to Application Support: %@", themeSettingsPath);
            
            // Clear the old UserDefaults theme data after successful migration
            [defaults removeObjectForKey:@"VLCOverlayTheme"];
            [defaults removeObjectForKey:@"VLCOverlayTransparency"];
            [defaults removeObjectForKey:@"VLCOverlayThemeAlpha"];
            [defaults removeObjectForKey:@"VLCOverlayCustomRed"];
            [defaults removeObjectForKey:@"VLCOverlayCustomGreen"];
            [defaults removeObjectForKey:@"VLCOverlayCustomBlue"];
            [defaults removeObjectForKey:@"VLCOverlaySelectionRed"];
            [defaults removeObjectForKey:@"VLCOverlaySelectionGreen"];
            [defaults removeObjectForKey:@"VLCOverlaySelectionBlue"];
            [defaults synchronize];
            
            //NSLog(@"Cleared old theme UserDefaults data after migration");
        } else {
            //NSLog(@"Failed to migrate theme UserDefaults data to Application Support");
        }
    }
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
    // The hover color is automatically calculated as a darker version of the selection color
    
    // Hover color calculation: make it darker than the selection color
    CGFloat darkenFactor = 0.9; // Make it 25% darker (multiply by 0.75)
    CGFloat hoverRed = self.customSelectionRed * darkenFactor;
    CGFloat hoverGreen = self.customSelectionGreen * darkenFactor;
    CGFloat hoverBlue = self.customSelectionBlue * darkenFactor;
    
    // Update the hoverColor property for backward compatibility
    self.hoverColor = [NSColor colorWithCalibratedRed:hoverRed green:hoverGreen blue:hoverBlue alpha:1.0]; // Increased alpha from 0.15
    
    // Save the settings
    [self saveThemeSettings];
    
    //NSLog(@"Selection Colors Updated: R=%.2f G=%.2f B=%.2f", 
    //      self.customSelectionRed, self.customSelectionGreen, self.customSelectionBlue);
    //NSLog(@"Calculated Hover Colors: R=%.2f G=%.2f B=%.2f", 
    //      hoverRed, hoverGreen, hoverBlue);
}

@end 

#endif // TARGET_OS_OSX 