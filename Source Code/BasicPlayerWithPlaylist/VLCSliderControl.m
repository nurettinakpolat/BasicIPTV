#import "VLCSliderControl.h"

@implementation VLCSliderControl

+ (void)drawSlider:(NSRect)rect
            label:(NSString *)label
         minValue:(CGFloat)minValue
         maxValue:(CGFloat)maxValue
     currentValue:(CGFloat)currentValue
      labelColor:(NSColor *)labelColor
      sliderRect:(NSRect *)outSliderRect
     displayText:(NSString *)displayText {
    
    // Set up text attributes
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: labelColor,
        NSParagraphStyleAttributeName: style
    };
    
    // Draw label
    [label drawInRect:NSMakeRect(rect.origin.x, rect.origin.y, rect.size.width, 20) 
        withAttributes:labelAttrs];
    
    // Calculate slider rect
    NSRect sliderBgRect = NSMakeRect(rect.origin.x, 
                                    rect.origin.y - 25,  // Position below label
                                    rect.size.width - 40, // Leave space for value display
                                    8);  // Slider height
    
    if (outSliderRect) {
        // Store the interactive area (slightly larger than visible slider)
        *outSliderRect = NSMakeRect(sliderBgRect.origin.x - 10,
                                   sliderBgRect.origin.y - 10,
                                   sliderBgRect.size.width + 20,
                                   sliderBgRect.size.height + 20);
    }
    
    // Draw slider background with rounded corners
    [[NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:1.0] set];
    NSBezierPath *sliderBg = [NSBezierPath bezierPathWithRoundedRect:sliderBgRect 
                                                            xRadius:4 
                                                            yRadius:4];
    [sliderBg fill];
    
    // Calculate and draw the filled portion
    CGFloat fillProportion = (currentValue - minValue) / (maxValue - minValue);
    fillProportion = MAX(0.0, MIN(1.0, fillProportion));
    
    NSRect fillRect = NSMakeRect(sliderBgRect.origin.x,
                                sliderBgRect.origin.y,
                                sliderBgRect.size.width * fillProportion,
                                sliderBgRect.size.height);
    
    [[NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.8 alpha:1.0] set];
    NSBezierPath *fillPath = [NSBezierPath bezierPathWithRoundedRect:fillRect 
                                                            xRadius:4 
                                                            yRadius:4];
    [fillPath fill];
    
    // Draw slider thumb
    CGFloat thumbX = sliderBgRect.origin.x + (sliderBgRect.size.width * fillProportion) - 8;
    NSRect thumbRect = NSMakeRect(thumbX, sliderBgRect.origin.y - 4, 16, 16);
    
    // Add subtle shadow to thumb
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.3] set];
    NSBezierPath *thumbShadow = [NSBezierPath bezierPathWithOvalInRect:
                                NSOffsetRect(thumbRect, 1, -1)];
    [thumbShadow fill];
    
    // Draw thumb
    [[NSColor whiteColor] set];
    NSBezierPath *thumbPath = [NSBezierPath bezierPathWithOvalInRect:thumbRect];
    [thumbPath fill];
    
    // Draw value text
    if (displayText) {
        NSRect valueRect = NSMakeRect(rect.origin.x + rect.size.width - 35,
                                     rect.origin.y - 25,
                                     35,
                                     20);
        [displayText drawInRect:valueRect withAttributes:labelAttrs];
    }
    
    [style release];
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

@end 