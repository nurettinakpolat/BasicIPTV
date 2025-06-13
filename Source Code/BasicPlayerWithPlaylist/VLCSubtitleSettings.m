//
//  VLCSubtitleSettings.m
//
//  Subtitle settings manager implementation
//

#import "VLCSubtitleSettings.h"

#if TARGET_OS_OSX
#import <VLCKit/VLCKit.h>

// Settings keys for persistence
static NSString *const kSubtitleFontSizeKey = @"VLCSubtitleFontSize";
static NSString *const kSubtitleFontNameKey = @"VLCSubtitleFontName";
static NSString *const kSubtitleTextColorKey = @"VLCSubtitleTextColor";
static NSString *const kSubtitleOutlineColorKey = @"VLCSubtitleOutlineColor";
static NSString *const kSubtitleOutlineThicknessKey = @"VLCSubtitleOutlineThickness";
static NSString *const kSubtitleShadowEnabledKey = @"VLCSubtitleShadowEnabled";
static NSString *const kSubtitleBackgroundEnabledKey = @"VLCSubtitleBackgroundEnabled";

@implementation VLCSubtitleSettings

static VLCSubtitleSettings *sharedInstance = nil;

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[VLCSubtitleSettings alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self resetToDefaults];
        [self loadSettings];
    }
    return self;
}

- (void)resetToDefaults {
    self.fontSize = 10;  // Default scale factor (1.0x)
    self.fontName = @"System";
    self.textColor = [NSColor whiteColor];
    self.outlineColor = [NSColor blackColor];
    self.outlineThickness = 1;
    self.shadowEnabled = NO;
    self.backgroundEnabled = NO;
}

- (void)applyToPlayer:(VLCMediaPlayer *)player {
    if (!player) {
        //NSLog(@"Cannot apply subtitle settings - no player provided");
        return;
    }
    
    //NSLog(@"Applying subtitle settings - Font size: %ld", (long)self.fontSize);
    
    // Use the modern VLCKit API for subtitle font scaling
    // Convert fontSize (which ranges from 1-20) to a scale factor
    // fontSize 10 = scale 1.0 (normal), fontSize 20 = scale 2.0 (double), fontSize 5 = scale 0.5 (half)
    float fontScale = (float)self.fontSize / 10.0f;
    
    // Clamp the scale to reasonable bounds (0.5x to 3.0x)
    fontScale = MAX(0.5f, MIN(3.0f, fontScale));
    
    //NSLog(@"Setting subtitle font scale to: %.2f (from fontSize: %ld)", fontScale, (long)self.fontSize);
    
    // Apply the font scale using the modern VLCKit API
    [player setCurrentSubTitleFontScale:fontScale];
    
    // Verify the setting was applied
    float currentScale = [player currentSubTitleFontScale];
    //NSLog(@"Current subtitle font scale after setting: %.2f", currentScale);
    
    //NSLog(@"Subtitle settings applied successfully using modern VLCKit API");
}

// Note: Other subtitle appearance settings (color, outline, shadow) are not currently
// supported by the modern VLCKit API's currentSubTitleFontScale property.
// These would require different VLCKit methods or VLC core configuration.

// Convenience method to apply settings to any available player
+ (void)applyCurrentSettingsToPlayer:(VLCMediaPlayer *)player {
    if (player) {
        [[VLCSubtitleSettings sharedInstance] applyToPlayer:player];
    }
}

- (void)loadSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Load settings with defaults
    self.fontSize = [defaults objectForKey:kSubtitleFontSizeKey] ? [defaults integerForKey:kSubtitleFontSizeKey] : 10;
    self.fontName = [defaults objectForKey:kSubtitleFontNameKey] ?: @"System";
    
    // Load colors
    NSData *textColorData = [defaults objectForKey:kSubtitleTextColorKey];
    if (textColorData) {
        self.textColor = [NSUnarchiver unarchiveObjectWithData:textColorData];
    }
    
    NSData *outlineColorData = [defaults objectForKey:kSubtitleOutlineColorKey];
    if (outlineColorData) {
        self.outlineColor = [NSUnarchiver unarchiveObjectWithData:outlineColorData];
    }
    
    self.outlineThickness = [defaults objectForKey:kSubtitleOutlineThicknessKey] ? [defaults integerForKey:kSubtitleOutlineThicknessKey] : 1;
    self.shadowEnabled = [defaults boolForKey:kSubtitleShadowEnabledKey];
    self.backgroundEnabled = [defaults boolForKey:kSubtitleBackgroundEnabledKey];
    
    //NSLog(@"Subtitle settings loaded - Font size: %ld", (long)self.fontSize);
}

- (void)saveSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    [defaults setInteger:self.fontSize forKey:kSubtitleFontSizeKey];
    [defaults setObject:self.fontName forKey:kSubtitleFontNameKey];
    
    // Save colors
    NSData *textColorData = [NSArchiver archivedDataWithRootObject:self.textColor];
    [defaults setObject:textColorData forKey:kSubtitleTextColorKey];
    
    NSData *outlineColorData = [NSArchiver archivedDataWithRootObject:self.outlineColor];
    [defaults setObject:outlineColorData forKey:kSubtitleOutlineColorKey];
    
    [defaults setInteger:self.outlineThickness forKey:kSubtitleOutlineThicknessKey];
    [defaults setBool:self.shadowEnabled forKey:kSubtitleShadowEnabledKey];
    [defaults setBool:self.backgroundEnabled forKey:kSubtitleBackgroundEnabledKey];
    
    [defaults synchronize];
    
    //NSLog(@"Subtitle settings saved - Font size: %ld", (long)self.fontSize);
}

- (void)dealloc {
    [_fontName release];
    [_textColor release];
    [_outlineColor release];
    [super dealloc];
}

@end

#pragma mark - Reusable UI Controls

@implementation VLCSettingsControl

+ (NSView *)createLabeledTextField:(NSString *)label 
                             value:(NSString *)value 
                            target:(id)target 
                            action:(SEL)action 
                               tag:(NSInteger)tag 
                             width:(CGFloat)width {
    
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 50)];
    
    // Label
    NSTextField *labelField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 25, width, 20)];
    [labelField setStringValue:label];
    [labelField setBezeled:NO];
    [labelField setDrawsBackground:NO];
    [labelField setEditable:NO];
    [labelField setSelectable:NO];
    [labelField setTextColor:[NSColor whiteColor]];
    [labelField setFont:[NSFont systemFontOfSize:14]];
    [container addSubview:labelField];
    
    // Text field
    NSTextField *textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, width, 22)];
    [textField setStringValue:value ?: @""];
    [textField setTag:tag];
    if (target && action) {
        [textField setTarget:target];
        [textField setAction:action];
    }
    [textField setBackgroundColor:[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0]];
    [textField setTextColor:[NSColor whiteColor]];
    [textField setBordered:YES];
    [container addSubview:textField];
    
    [labelField release];
    [textField release];
    
    return [container autorelease];
}

+ (NSView *)createLabeledSlider:(NSString *)label 
                        minValue:(double)minValue 
                        maxValue:(double)maxValue 
                           value:(double)value 
                          target:(id)target 
                          action:(SEL)action 
                             tag:(NSInteger)tag 
                           width:(CGFloat)width {
    
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 50)];
    
    // Label with value
    NSTextField *labelField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 25, width, 20)];
    [labelField setStringValue:[NSString stringWithFormat:@"%@: %.0f", label, value]];
    [labelField setBezeled:NO];
    [labelField setDrawsBackground:NO];
    [labelField setEditable:NO];
    [labelField setSelectable:NO];
    [labelField setTextColor:[NSColor whiteColor]];
    [labelField setFont:[NSFont systemFontOfSize:14]];
    [container addSubview:labelField];
    
    // Slider
    NSSlider *slider = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, width, 22)];
    [slider setMinValue:minValue];
    [slider setMaxValue:maxValue];
    [slider setDoubleValue:value];
    [slider setTag:tag];
    if (target && action) {
        [slider setTarget:target];
        [slider setAction:action];
    }
    [container addSubview:slider];
    
    [labelField release];
    [slider release];
    
    return [container autorelease];
}

+ (NSView *)createLabeledCheckbox:(NSString *)label 
                            value:(BOOL)value 
                           target:(id)target 
                           action:(SEL)action 
                              tag:(NSInteger)tag {
    
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 25)];
    
    // Checkbox
    NSButton *checkbox = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 22)];
    [checkbox setButtonType:NSButtonTypeSwitch];
    [checkbox setTitle:label];
    [checkbox setState:value ? NSControlStateValueOn : NSControlStateValueOff];
    [checkbox setTag:tag];
    if (target && action) {
        [checkbox setTarget:target];
        [checkbox setAction:action];
    }
    [checkbox setTextColor:[NSColor whiteColor]];
    [checkbox setFont:[NSFont systemFontOfSize:14]];
    [container addSubview:checkbox];
    
    [checkbox release];
    
    return [container autorelease];
}

+ (NSView *)createLabeledColorWell:(NSString *)label 
                             color:(NSColor *)color 
                            target:(id)target 
                            action:(SEL)action 
                               tag:(NSInteger)tag {
    
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 50)];
    
    // Label
    NSTextField *labelField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 25, 150, 20)];
    [labelField setStringValue:label];
    [labelField setBezeled:NO];
    [labelField setDrawsBackground:NO];
    [labelField setEditable:NO];
    [labelField setSelectable:NO];
    [labelField setTextColor:[NSColor whiteColor]];
    [labelField setFont:[NSFont systemFontOfSize:14]];
    [container addSubview:labelField];
    
    // Color well
    NSColorWell *colorWell = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 50, 22)];
    [colorWell setColor:color ?: [NSColor whiteColor]];
    [colorWell setTag:tag];
    if (target && action) {
        [colorWell setTarget:target];
        [colorWell setAction:action];
    }
    [container addSubview:colorWell];
    
    [labelField release];
    [colorWell release];
    
    return [container autorelease];
}

@end 

#endif // TARGET_OS_OSX
