#import <Cocoa/Cocoa.h>

@interface VLCSliderControl : NSObject

// Create a slider with label and value display
+ (void)drawSlider:(NSRect)rect
            label:(NSString *)label
         minValue:(CGFloat)minValue
         maxValue:(CGFloat)maxValue
     currentValue:(CGFloat)currentValue
      labelColor:(NSColor *)labelColor
      sliderRect:(NSRect *)outSliderRect
     displayText:(NSString *)displayText;

// Helper to check if a point is within the slider's interactive area
+ (BOOL)isPoint:(NSPoint)point inSliderRect:(NSRect)sliderRect;

// Calculate slider value from point
+ (CGFloat)valueForPoint:(NSPoint)point 
              sliderRect:(NSRect)sliderRect 
               minValue:(CGFloat)minValue 
               maxValue:(CGFloat)maxValue;

@end 