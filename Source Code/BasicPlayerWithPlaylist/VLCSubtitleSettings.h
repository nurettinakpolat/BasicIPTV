//
//  VLCSubtitleSettings.h
//
//  Subtitle settings manager with configurable font size and appearance
//

#import <Foundation/Foundation.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>

@class VLCMediaPlayer;

@interface VLCSubtitleSettings : NSObject

// Singleton instance
+ (instancetype)sharedInstance;

// Settings properties
@property (nonatomic, assign) NSInteger fontSize;           // Font scale factor (1-30, default: 10 = 1.0x scale)
@property (nonatomic, retain) NSString *fontName;          // Font name (default: system)
@property (nonatomic, retain) NSColor *textColor;          // Text color (default: white)
@property (nonatomic, retain) NSColor *outlineColor;       // Outline color (default: black)
@property (nonatomic, assign) NSInteger outlineThickness;  // Outline thickness (0-3, default: 1)
@property (nonatomic, assign) BOOL shadowEnabled;          // Shadow enabled (default: NO)
@property (nonatomic, assign) BOOL backgroundEnabled;      // Background enabled (default: NO)

// Apply settings to VLC player
- (void)applyToPlayer:(VLCMediaPlayer *)player;

// Convenience method to apply current settings to any player
+ (void)applyCurrentSettingsToPlayer:(VLCMediaPlayer *)player;

// Load/Save settings
- (void)loadSettings;
- (void)saveSettings;

// Reset to defaults
- (void)resetToDefaults;

@end

#endif // TARGET_OS_OSX

#if TARGET_OS_OSX
// Reusable UI Controls for Settings
@interface VLCSettingsControl : NSObject

// Create a labeled text field with validation
+ (NSView *)createLabeledTextField:(NSString *)label 
                             value:(NSString *)value 
                            target:(id)target 
                            action:(SEL)action 
                               tag:(NSInteger)tag 
                             width:(CGFloat)width;

// Create a labeled slider with value display
+ (NSView *)createLabeledSlider:(NSString *)label 
                        minValue:(double)minValue 
                        maxValue:(double)maxValue 
                           value:(double)value 
                          target:(id)target 
                          action:(SEL)action 
                             tag:(NSInteger)tag 
                           width:(CGFloat)width;

// Create a labeled checkbox
+ (NSView *)createLabeledCheckbox:(NSString *)label 
                            value:(BOOL)value 
                           target:(id)target 
                           action:(SEL)action 
                              tag:(NSInteger)tag;

// Create a labeled color well
+ (NSView *)createLabeledColorWell:(NSString *)label 
                             color:(NSColor *)color 
                            target:(id)target 
                            action:(SEL)action 
                               tag:(NSInteger)tag;

@end 

#endif // TARGET_OS_OSX