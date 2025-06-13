#import "VLCSliderControl.h"

#if TARGET_OS_OSX

// Static variables to track active slider state
static NSString *activeSliderHandle = nil;
static BOOL isSliderBeingDragged = NO;

@implementation VLCSliderControl

+ (void)drawSlider:(NSRect)rect
            label:(NSString *)label
         minValue:(CGFloat)minValue
         maxValue:(CGFloat)maxValue
     currentValue:(CGFloat)currentValue
      labelColor:(NSColor *)labelColor
      sliderRect:(NSRect *)outSliderRect
     displayText:(NSString *)displayText {
    
    // Set up text attributes - modern non-bold font
    NSMutableParagraphStyle *labelStyle = [[NSMutableParagraphStyle alloc] init];
    [labelStyle setAlignment:NSTextAlignmentLeft];
    
    NSMutableParagraphStyle *valueStyle = [[NSMutableParagraphStyle alloc] init];
    [valueStyle setAlignment:NSTextAlignmentRight];
    
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14], // Regular weight, not bold
        NSForegroundColorAttributeName: labelColor,
        NSParagraphStyleAttributeName: labelStyle
    };
    
    NSDictionary *valueAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13], // Slightly smaller and regular weight
        NSForegroundColorAttributeName: [labelColor colorWithAlphaComponent:0.8], // Slightly dimmed
        NSParagraphStyleAttributeName: valueStyle
    };
    
    // Modern horizontal layout: Label on left, slider in center, value on right
    CGFloat labelWidth = 180;      // Fixed width for labels for alignment
    CGFloat valueWidth = 60;       // Space for value display
    CGFloat spacing = 15;          // Space between elements
    CGFloat sliderWidth = rect.size.width - labelWidth - valueWidth - (spacing * 2);
    
    // Calculate positions (all vertically centered)
    CGFloat centerY = rect.origin.y + (rect.size.height - 20) / 2; // Center label vertically
    NSRect labelRect = NSMakeRect(rect.origin.x, centerY, labelWidth, 20);
    
    // Draw label on the left
    [label drawInRect:labelRect withAttributes:labelAttrs];
    
    // Calculate slider rect in the center
    CGFloat sliderY = rect.origin.y + (rect.size.height - 8) / 2; // Center slider vertically
    NSRect sliderBgRect = NSMakeRect(rect.origin.x + labelWidth + spacing, 
                                    sliderY,
                                    sliderWidth,
                                    8);  // Slider height
    
    if (outSliderRect) {
        // Store the interactive area (slightly larger than visible slider)
        *outSliderRect = NSMakeRect(sliderBgRect.origin.x - 10,
                                   sliderBgRect.origin.y - 10,
                                   sliderBgRect.size.width + 20,
                                   sliderBgRect.size.height + 20);
    }
    
    // Draw slider background with glassmorphism effect
    [[NSColor colorWithWhite:0.2 alpha:0.3] set];
    NSBezierPath *sliderBg = [NSBezierPath bezierPathWithRoundedRect:sliderBgRect 
                                                            xRadius:4 
                                                            yRadius:4];
    [sliderBg fill];
    
    // Add glassmorphism border to background
    [[NSColor colorWithWhite:1.0 alpha:0.2] set];
    [sliderBg setLineWidth:1.0];
    [sliderBg stroke];
    
    // Calculate and draw the filled portion with glassmorphism gradient
    CGFloat fillProportion = (currentValue - minValue) / (maxValue - minValue);
    fillProportion = MAX(0.0, MIN(1.0, fillProportion));
    
    NSRect fillRect = NSMakeRect(sliderBgRect.origin.x,
                                sliderBgRect.origin.y,
                                sliderBgRect.size.width * fillProportion,
                                sliderBgRect.size.height);
    
    // Create glassmorphism gradient for fill
    NSGradient *fillGradient = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.7],
        [NSColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:0.5],
        [NSColor colorWithRed:0.3 green:0.6 blue:0.95 alpha:0.6]
    ]];
    
    NSBezierPath *fillPath = [NSBezierPath bezierPathWithRoundedRect:fillRect 
                                                            xRadius:4 
                                                            yRadius:4];
    [fillGradient drawInBezierPath:fillPath angle:135];
    [fillGradient release];
    
    // Add glassmorphism border to fill
    [[NSColor colorWithRed:0.5 green:0.8 blue:1.0 alpha:0.8] set];
    [fillPath setLineWidth:1.0];
    [fillPath stroke];
    
    // Draw glassmorphism slider thumb
    CGFloat thumbX = sliderBgRect.origin.x + (sliderBgRect.size.width * fillProportion) - 8;
    NSRect thumbRect = NSMakeRect(thumbX, sliderBgRect.origin.y - 4, 16, 16);
    
    // Add subtle shadow to thumb
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.3] set];
    NSBezierPath *thumbShadow = [NSBezierPath bezierPathWithOvalInRect:
                                NSOffsetRect(thumbRect, 1, -1)];
    [thumbShadow fill];
    
    // Draw glassmorphism thumb with gradient
    NSGradient *thumbGradient = [[NSGradient alloc] initWithColors:@[
        [NSColor colorWithWhite:1.0 alpha:0.9],
        [NSColor colorWithWhite:0.9 alpha:0.7],
        [NSColor colorWithWhite:0.95 alpha:0.8]
    ]];
    
    NSBezierPath *thumbPath = [NSBezierPath bezierPathWithOvalInRect:thumbRect];
    [thumbGradient drawInBezierPath:thumbPath angle:135];
    [thumbGradient release];
    
    // Add glassmorphism border to thumb
    [[NSColor colorWithWhite:1.0 alpha:0.6] set];
    [thumbPath setLineWidth:1.0];
    [thumbPath stroke];
    
    // Draw value text on the right
    if (displayText) {
        NSRect valueRect = NSMakeRect(rect.origin.x + labelWidth + spacing + sliderWidth + spacing,
                                     centerY,
                                     valueWidth,
                                     20);
        [displayText drawInRect:valueRect withAttributes:valueAttrs];
    }
    
    [labelStyle release];
    [valueStyle release];
}

+ (BOOL)isPoint:(NSPoint)point inSliderRect:(NSRect)sliderRect {
    return NSPointInRect(point, sliderRect);
}

+ (CGFloat)valueForPoint:(NSPoint)point 
              sliderRect:(NSRect)sliderRect 
               minValue:(CGFloat)minValue 
               maxValue:(CGFloat)maxValue {
    
    // Calculate the proportion based on x position
    CGFloat proportion = (point.x - sliderRect.origin.x) / sliderRect.size.width;
    proportion = MAX(0.0, MIN(1.0, proportion));
    
    // Convert to value
    return minValue + (proportion * (maxValue - minValue));
}

#pragma mark - Slider Activation Handling

+ (BOOL)handleMouseDown:(NSPoint)point 
             sliderRect:(NSRect)sliderRect 
           sliderHandle:(NSString *)sliderHandle {
    
    // Check if point is within this slider's rect
    if (![self isPoint:point inSliderRect:sliderRect]) {
        return NO;
    }
    
    // If no slider is currently active, activate this one
    if (!isSliderBeingDragged) {
        activeSliderHandle = [sliderHandle copy];
        isSliderBeingDragged = YES;
        //NSLog(@"🎛️ Slider activated: %@", sliderHandle);
        return YES;
    }
    
    // If this slider is already active, continue
    if ([activeSliderHandle isEqualToString:sliderHandle]) {
        return YES;
    }
    
    // Another slider is active, ignore this one
    return NO;
}

+ (BOOL)handleMouseDragged:(NSPoint)point 
                sliderRect:(NSRect)sliderRect 
              sliderHandle:(NSString *)sliderHandle {
    
    // Only respond if this slider is the active one
    if (!isSliderBeingDragged || ![activeSliderHandle isEqualToString:sliderHandle]) {
        return NO;
    }
    
    // Allow dragging even if mouse moves outside the slider rect for better UX
    return YES;
}

+ (void)handleMouseUp {
    // Deactivate all sliders
    if (activeSliderHandle) {
        //NSLog(@"🎛️ Slider deactivated: %@", activeSliderHandle);
        [activeSliderHandle release];
        activeSliderHandle = nil;
    }
    isSliderBeingDragged = NO;
}

+ (BOOL)isSliderActive:(NSString *)sliderHandle {
    return isSliderBeingDragged && [activeSliderHandle isEqualToString:sliderHandle];
}

+ (NSString *)activeSliderHandle {
    return activeSliderHandle;
}

@end 

#else
// iOS/tvOS implementation - stub for now
@implementation VLCSliderControl

+ (void)drawSlider:(PlatformRect)rect
            label:(NSString *)label
         minValue:(CGFloat)minValue
         maxValue:(CGFloat)maxValue
     currentValue:(CGFloat)currentValue
      labelColor:(PlatformColor *)labelColor
      sliderRect:(PlatformRect *)outSliderRect
     displayText:(NSString *)displayText {
    // iOS/tvOS implementation would use UIKit drawing here
    // For now, just set the slider rect for touch handling
    if (outSliderRect) {
        *outSliderRect = rect;
    }
}

+ (BOOL)isPoint:(PlatformPoint)point inSliderRect:(PlatformRect)sliderRect {
    return CGRectContainsPoint(sliderRect, point);
}

+ (CGFloat)valueForPoint:(PlatformPoint)point 
              sliderRect:(PlatformRect)sliderRect 
               minValue:(CGFloat)minValue 
               maxValue:(CGFloat)maxValue {
    CGFloat proportion = (point.x - sliderRect.origin.x) / sliderRect.size.width;
    proportion = MAX(0.0, MIN(1.0, proportion));
    return minValue + (proportion * (maxValue - minValue));
}

+ (BOOL)handleMouseDown:(PlatformPoint)point 
             sliderRect:(PlatformRect)sliderRect 
           sliderHandle:(NSString *)sliderHandle {
    return [self isPoint:point inSliderRect:sliderRect];
}

+ (BOOL)handleMouseDragged:(PlatformPoint)point 
                sliderRect:(PlatformRect)sliderRect 
              sliderHandle:(NSString *)sliderHandle {
    return YES;
}

+ (void)handleMouseUp {
    // iOS/tvOS implementation
}

+ (BOOL)isSliderActive:(NSString *)sliderHandle {
    return NO;
}

+ (NSString *)activeSliderHandle {
    return nil;
}

@end

#endif