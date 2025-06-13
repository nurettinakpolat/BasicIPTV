#import "PlatformBridge.h"

@interface VLCSliderControl : NSObject

// Create a slider with label and value display
+ (void)drawSlider:(PlatformRect)rect
            label:(NSString *)label
         minValue:(CGFloat)minValue
         maxValue:(CGFloat)maxValue
     currentValue:(CGFloat)currentValue
      labelColor:(PlatformColor *)labelColor
      sliderRect:(PlatformRect *)outSliderRect
     displayText:(NSString *)displayText;

// Helper to check if a point is within the slider's interactive area
+ (BOOL)isPoint:(PlatformPoint)point inSliderRect:(PlatformRect)sliderRect;

// Calculate slider value from point
+ (CGFloat)valueForPoint:(PlatformPoint)point 
              sliderRect:(PlatformRect)sliderRect 
               minValue:(CGFloat)minValue 
               maxValue:(CGFloat)maxValue;

// New methods for slider activation tracking
+ (BOOL)handleMouseDown:(PlatformPoint)point 
             sliderRect:(PlatformRect)sliderRect 
           sliderHandle:(NSString *)sliderHandle;

+ (BOOL)handleMouseDragged:(PlatformPoint)point 
                sliderRect:(PlatformRect)sliderRect 
              sliderHandle:(NSString *)sliderHandle;

+ (void)handleMouseUp;

+ (BOOL)isSliderActive:(NSString *)sliderHandle;

+ (NSString *)activeSliderHandle;

@end 
