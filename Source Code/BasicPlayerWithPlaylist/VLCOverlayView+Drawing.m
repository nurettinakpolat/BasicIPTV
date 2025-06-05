#import "VLCOverlayView+Drawing.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+PlayerControls.h"
#import "VLCSubtitleSettings.h"
#import <objc/runtime.h>
#import "VLCOverlayView+Utilities.h"
#import <math.h>
#import "VLCSliderControl.h"
#import "VLCOverlayView+Globals.h"

// Constants for slider types
#define SLIDER_TYPE_NONE 0
#define SLIDER_TYPE_TRANSPARENCY 1
#define SLIDER_TYPE_RED 2
#define SLIDER_TYPE_GREEN 3
#define SLIDER_TYPE_BLUE 4
#define SLIDER_TYPE_SUBTITLE 5

// Global variable to track menu fade-out state
extern BOOL isFadingOut;
extern NSTimeInterval lastFadeOutTime;
extern NSTimer *playerControlsTimer;
extern BOOL playerControlsVisible;

// Global variables for grid view and UI state
extern BOOL isGridViewActive;
extern NSMutableDictionary *gridLoadingQueue;
extern NSOperationQueue *coverDownloadQueue;
extern BOOL isPersistingHoverState;
extern NSInteger lastValidHoveredChannelIndex;
extern NSInteger lastValidHoveredGroupIndex;
extern NSInteger activeSliderType;
extern NSInteger currentViewMode;
extern BOOL isStackedViewActive;

@implementation VLCOverlayView (Drawing)

// Content from drawing_methods.txt will be inserted here
// This is a placeholder for the actual implementation


#pragma mark - UI Setup

- (void)setupEpgTimeOffsetDropdown {
    // Create EPG time offset dropdown with placeholder frame (will be updated in drawPlaylistSettingsWithComponents)
    NSRect placeholderFrame = NSMakeRect(0, 0, 100, 30);
    VLCDropdown *offsetDropdown = [self.dropdownManager createDropdownWithIdentifier:@"EPGTimeOffset" frame:placeholderFrame];
    
    // Add time offset options from -12 to +12 hours
    for (NSInteger offset = -12; offset <= 12; offset++) {
        NSString *displayText;
        if (offset == 0) {
            displayText = @"0 hours (UTC)";
        } else {
            displayText = [NSString stringWithFormat:@"%+ld hours", (long)offset];
        }
        
        [offsetDropdown addItemWithValue:[NSNumber numberWithInteger:offset] displayText:displayText];
        
        // Set default selection to 0 (UTC)
        if (offset == 0) {
            offsetDropdown.selectedIndex = [offsetDropdown.items count] - 1;
        }
    }
    
    // Set up selection callback
    offsetDropdown.onSelectionChanged = ^(VLCDropdown *dropdown, VLCDropdownItem *selectedItem, NSInteger selectedIndex) {
        if (selectedItem && selectedItem.value) {
            NSNumber *offsetValue = (NSNumber *)selectedItem.value;
            
            // Update the EPG time offset
            self.epgTimeOffsetHours = [offsetValue integerValue];
            
            //NSLog(@"EPG time offset changed to: %ld hours", (long)self.epgTimeOffsetHours);
            
            // Save settings
            if ([self respondsToSelector:@selector(saveSettingsState)]) {
                [self saveSettingsState];
            }
            
            // Refresh display
            [self setNeedsDisplay:YES];
        }
    };
    
    // Set the current selection based on the current EPG time offset
    NSInteger currentOffsetIndex = self.epgTimeOffsetHours + 12; // Convert -12..+12 to 0..24
    if (currentOffsetIndex >= 0 && currentOffsetIndex < [offsetDropdown.items count]) {
        offsetDropdown.selectedIndex = currentOffsetIndex;
    }
}

- (void)hideControls {
    // Remove all UI components from view hierarchy
    if (self.m3uTextField && [self.m3uTextField superview] != nil) {
        [self.m3uTextField removeFromSuperview];
    }
    if (self.epgLabel && [self.epgLabel superview] != nil) {
        [self.epgLabel removeFromSuperview];
    }
    if (self.searchTextField && [self.searchTextField superview] != nil) {
        [self.searchTextField removeFromSuperview];
    }
    // Also hide any other UI components that might be visible
    // This ensures a clean slate before showing the menu
}

// Method to draw all dropdowns at the end for proper z-ordering
- (void)drawDropdowns:(NSRect)rect {
    //NSLog(@"drawDropdowns called with rect: {{%.1f, %.1f}, {%.1f, %.1f}}", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
    
    if (!self.dropdownManager) {
        //NSLog(@"ERROR: Dropdown manager is nil in drawDropdowns!");
        return;
    }
    
    //NSLog(@"Dropdown manager has %ld active dropdowns", [self.dropdownManager.activeDropdowns count]);
    
    // Log each dropdown state
    for (NSString *identifier in self.dropdownManager.activeDropdowns) {
        VLCDropdown *dropdown = [self.dropdownManager.activeDropdowns objectForKey:identifier];
      //NSLog(@"Dropdown '%@': isOpen=%@, items=%ld", identifier, dropdown.isOpen ? @"YES" : @"NO", [dropdown.items count]);
    }
    
    // Use the new dropdown manager to draw all dropdowns
    [self.dropdownManager drawAllDropdowns:rect];
    //NSLog(@"Finished drawing dropdowns");
}

- (void)setupTrackingArea {
    // Remove existing tracking area
    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
        [trackingArea release];
    }
    
    // Create a new tracking area covering the entire view with better tracking options
    NSTrackingAreaOptions options = (NSTrackingMouseMoved | 
                                    NSTrackingMouseEnteredAndExited | 
                                    NSTrackingActiveInKeyWindow |
                                    NSTrackingAssumeInside |      // Assume mouse is inside when view is first shown
                                    NSTrackingInVisibleRect |     // Update tracking rect automatically when view changes
                                    NSTrackingEnabledDuringMouseDrag); // Track even during drag operations
    
    trackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds]
                                                options:options
                                                  owner:self
                                               userInfo:nil];
    [self addTrackingArea:trackingArea];
    
    // Log that we're setting up tracking
    //NSLog(@"Setup tracking area with rect: %@", NSStringFromRect([self bounds]));
    
    // Reset interaction timer
    [self markUserInteraction];
    
    // Initialize grid loading queue if needed
    if (!gridLoadingQueue) {
        gridLoadingQueue = [[NSMutableDictionary alloc] init];
    }
    
    // Initialize download queue if needed
    if (!coverDownloadQueue) {
        coverDownloadQueue = [[NSOperationQueue alloc] init];
        [coverDownloadQueue setMaxConcurrentOperationCount:8]; // Allow 8 concurrent downloads
    }
}

#pragma mark - Drawing Methods

// Helper method to get category icons using SF Symbols
- (NSImage *)iconForCategory:(NSString *)category {
    NSImage *icon = nil;
    NSString *symbolName = nil;
    
    if ([category isEqualToString:@"SEARCH"]) {
        symbolName = @"magnifyingglass";
    } else if ([category isEqualToString:@"FAVORITES"]) {
        symbolName = @"heart.fill";
    } else if ([category isEqualToString:@"TV"]) {
        symbolName = @"tv";
    } else if ([category isEqualToString:@"MOVIES"]) {
        symbolName = @"film";
    } else if ([category isEqualToString:@"SERIES"]) {
        symbolName = @"play.tv";
    } else if ([category isEqualToString:@"SETTINGS"]) {
        symbolName = @"gearshape";
    }
    
    if (symbolName) {
        // Try to use SF Symbols if available (macOS 11+)
        if (@available(macOS 11.0, *)) {
            icon = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
            
            // Configure the icon size
            if (icon) {
                [icon setSize:NSMakeSize(16, 16)];
                
                // Create a white tinted version of the icon
                NSImage *tintedIcon = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
                [tintedIcon lockFocus];
                
                // Set white color for the icon
                [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] set];
                
                // Draw the icon as a template
                NSRect iconRect = NSMakeRect(0, 0, 16, 16);
                [icon drawInRect:iconRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
                
                // Apply the white tint using source atop
                NSRectFillUsingOperation(iconRect, NSCompositeSourceAtop);
                
                [tintedIcon unlockFocus];
                
                return [tintedIcon autorelease];
            }
        } else {
            // Fallback to creating simple icons for older macOS versions
            icon = [self createFallbackIconForCategory:category];
        }
    }
    
    return icon;
}

// Fallback method to create simple icons for older macOS versions
- (NSImage *)createFallbackIconForCategory:(NSString *)category {
    NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
    [icon lockFocus];
    
    // Set the drawing context
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];
    
    // Create a simple colored circle with a symbol
    NSRect iconRect = NSMakeRect(1, 1, 14, 14);
    NSBezierPath *circlePath = [NSBezierPath bezierPathWithOvalInRect:iconRect];
    
    // Set different colors for different categories
    if ([category isEqualToString:@"SEARCH"]) {
        [[NSColor colorWithCalibratedRed:0.3 green:0.7 blue:1.0 alpha:1.0] set];
    } else if ([category isEqualToString:@"FAVORITES"]) {
        [[NSColor colorWithCalibratedRed:1.0 green:0.4 blue:0.4 alpha:1.0] set];
    } else if ([category isEqualToString:@"TV"]) {
        [[NSColor colorWithCalibratedRed:0.4 green:0.8 blue:0.4 alpha:1.0] set];
    } else if ([category isEqualToString:@"MOVIES"]) {
        [[NSColor colorWithCalibratedRed:1.0 green:0.7 blue:0.3 alpha:1.0] set];
    } else if ([category isEqualToString:@"SERIES"]) {
        [[NSColor colorWithCalibratedRed:0.8 green:0.4 blue:1.0 alpha:1.0] set];
    } else if ([category isEqualToString:@"SETTINGS"]) {
        [[NSColor colorWithCalibratedRed:0.7 green:0.7 blue:0.7 alpha:1.0] set];
    } else {
        [[NSColor colorWithCalibratedRed:0.6 green:0.6 blue:0.6 alpha:1.0] set];
    }
    
    [circlePath fill];
    
    // Add a subtle border
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.3] set];
    [circlePath setLineWidth:0.5];
    [circlePath stroke];
    
    // Add a simple white symbol in the center
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:9],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    };
    
    NSString *symbolChar = @"?";
    if ([category isEqualToString:@"SEARCH"]) {
        symbolChar = @"🔍";
    } else if ([category isEqualToString:@"FAVORITES"]) {
        symbolChar = @"♥";
    } else if ([category isEqualToString:@"TV"]) {
        symbolChar = @"📺";
    } else if ([category isEqualToString:@"MOVIES"]) {
        symbolChar = @"🎬";
    } else if ([category isEqualToString:@"SERIES"]) {
        symbolChar = @"📺";
    } else if ([category isEqualToString:@"SETTINGS"]) {
        symbolChar = @"⚙";
    }
    
    // For better looking fallback icons, use simple letters instead of emoji
    if ([category isEqualToString:@"SEARCH"]) {
        symbolChar = @"S";
    } else if ([category isEqualToString:@"FAVORITES"]) {
        symbolChar = @"♥";
    } else if ([category isEqualToString:@"TV"]) {
        symbolChar = @"T";
    } else if ([category isEqualToString:@"MOVIES"]) {
        symbolChar = @"M";
    } else if ([category isEqualToString:@"SERIES"]) {
        symbolChar = @"S";
    } else if ([category isEqualToString:@"SETTINGS"]) {
        symbolChar = @"⚙";
    }
    
    NSRect textRect = NSMakeRect(0, 2, 16, 12);
    [symbolChar drawInRect:textRect withAttributes:attrs];
    
    [style release];
    [context restoreGraphicsState];
    [icon unlockFocus];
    
    return [icon autorelease];
}

- (void)drawCategories:(NSRect)rect {
    CGFloat catWidth = 200;
    
    // Draw background with modern gradient
    NSRect menuRect = NSMakeRect(0, 0, catWidth, self.bounds.size.height);
    NSGradient *backgroundGradient = [[NSGradient alloc] initWithStartingColor:self.themeCategoryStartColor ? self.themeCategoryStartColor : [NSColor colorWithCalibratedRed:0.08 green:0.10 blue:0.14 alpha:0.75]
                                                                   endingColor:self.themeCategoryEndColor ? self.themeCategoryEndColor : [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:0.75]];
    [backgroundGradient drawInRect:menuRect angle:90];
    [backgroundGradient release];
    
    // Calculate total height for scroll bar
    CGFloat rowHeight = 40;
    CGFloat totalCategoriesHeight = [self.categories count] * rowHeight;
    
    // Draw each category with modern styling and icons
    for (NSInteger i = 0; i < [self.categories count]; i++) {
        NSRect itemRect = NSMakeRect(0, 
                                     self.bounds.size.height - ((i+1) * rowHeight) + categoryScrollPosition, 
                                     catWidth, 
                                     rowHeight);
        
        // Skip drawing if not visible
        if (!NSIntersectsRect(itemRect, rect)) {
            continue;
        }
        
        // Draw selection/hover background with rounded corners
        if (i == self.selectedCategoryIndex) {
            NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:
                                         NSInsetRect(itemRect, 4, 2)
                                                                         xRadius:6
                                                                         yRadius:6];
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.3] set];
            [selectionPath fill];
            
            // Add subtle highlight
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.2] set];
            [selectionPath stroke];
        } else if (i == self.hoveredCategoryIndex) {
            // Hover state - lighter version of selection
            NSBezierPath *hoverPath = [NSBezierPath bezierPathWithRoundedRect:
                                     NSInsetRect(itemRect, 4, 2)
                                                                     xRadius:6
                                                                     yRadius:6];
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.25] set]; // Increased alpha from 0.15
            [hoverPath fill];
            
            // Add subtle highlight
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.15] set]; // Increased stroke alpha from 0.1
            [hoverPath stroke];
        }
        
        // Get category name and icon
        NSString *category = [self.categories objectAtIndex:i];
        NSImage *categoryIcon = [self iconForCategory:category];
        
        // Calculate icon and text positions
        CGFloat iconSize = 16;
        CGFloat iconPadding = 12;
        CGFloat textLeftMargin = iconPadding + iconSize + 8; // Icon + spacing
        
        // Draw icon if available
        if (categoryIcon) {
            NSRect iconRect = NSMakeRect(
                itemRect.origin.x + iconPadding,
                itemRect.origin.y + (itemRect.size.height - iconSize) / 2,
                iconSize,
                iconSize
            );
            
            // Tint the icon to match the text color
            [categoryIcon drawInRect:iconRect 
                            fromRect:NSZeroRect 
                           operation:NSCompositeSourceOver 
                            fraction:0.9];
        }
        
        // Draw the category name with shadow
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentLeft];
        
        NSDictionary *shadowDict = @{
            NSShadowAttributeName: ({
                NSShadow *shadow = [[NSShadow alloc] init];
                shadow.shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.3];
                shadow.shadowOffset = NSMakeSize(0, -1);
                shadow.shadowBlurRadius = 2;
                shadow;
            })
        };
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0],
            NSParagraphStyleAttributeName: style,
            NSShadowAttributeName: shadowDict[NSShadowAttributeName]
        };
        
        NSRect textRect = NSMakeRect(itemRect.origin.x + textLeftMargin,
                                   itemRect.origin.y + (itemRect.size.height - 16) / 2,
                                   itemRect.size.width - textLeftMargin - 16,
                                   16);
        
        [category drawInRect:textRect withAttributes:attrs];
        
        [style release];
        [shadowDict[NSShadowAttributeName] release];
    }
    
    // Draw scroll bar if needed
    [self drawScrollBar:menuRect contentHeight:totalCategoriesHeight scrollPosition:categoryScrollPosition];
}

- (void)drawGroups:(NSRect)rect {
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat rowHeight = 40;
    
    // Draw background with modern gradient
    NSRect menuRect = NSMakeRect(catWidth, 0, groupWidth, self.bounds.size.height);
    NSGradient *backgroundGradient = [[NSGradient alloc] initWithStartingColor:self.themeGroupStartColor ? self.themeGroupStartColor : [NSColor colorWithCalibratedRed:0.08 green:0.10 blue:0.14 alpha:0.75]
                                                                   endingColor:self.themeGroupEndColor ? self.themeGroupEndColor : [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:0.75]];
    [backgroundGradient drawInRect:menuRect angle:90];
    [backgroundGradient release];

    // Get appropriate groups based on selected category
    NSArray *groups = nil;
    if (self.selectedCategoryIndex == CATEGORY_SEARCH) {
        // When Search is selected, show search textbox instead of groups
        if (!isFadingOut)
            [self drawSearchInterface:rect menuRect:menuRect];
        return;
    } else if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
        groups = [self safeGroupsForCategory:@"FAVORITES"];
    } else if (self.selectedCategoryIndex == CATEGORY_TV) {
        groups = [self safeTVGroups];
    } else if (self.selectedCategoryIndex == CATEGORY_MOVIES) {
        groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
    } else if (self.selectedCategoryIndex == CATEGORY_SERIES) {
        groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
    } else if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
        groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
    }
    
    if (!groups) return;
        
    // Draw each group with modern styling
    for (NSInteger i = 0; i < [groups count]; i++) {
        NSRect itemRect = NSMakeRect(catWidth, 
                                   self.bounds.size.height - ((i+1) * rowHeight) + groupScrollPosition,
                                     groupWidth, 
                                     rowHeight);
        
        if (!NSIntersectsRect(itemRect, rect)) continue;
        
        NSString *group = [groups objectAtIndex:i];
        
        // Draw selection/hover background
        if (i == self.selectedGroupIndex) {
            NSBezierPath *selectionPath = [NSBezierPath bezierPathWithRoundedRect:
                                         NSInsetRect(itemRect, 4, 2)
                                                                         xRadius:6
                                                                         yRadius:6];
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.3] set];
            [selectionPath fill];
            
            // Add subtle highlight
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.2] set];
            [selectionPath stroke];
        } else if (i == self.hoveredGroupIndex) {
            // Hover state - lighter version of selection
            NSBezierPath *hoverPath = [NSBezierPath bezierPathWithRoundedRect:
                                     NSInsetRect(itemRect, 4, 2)
                                                                     xRadius:6
                                                                     yRadius:6];
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.25] set]; // Increased alpha from 0.15
            [hoverPath fill];
        
            // Add subtle highlight
            [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.15] set]; // Increased stroke alpha from 0.1
            [hoverPath stroke];
        }
        
        // Draw group name with shadow
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentLeft];
        
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithCalibratedWhite:0.0 alpha:0.3];
        shadow.shadowOffset = NSMakeSize(0, -1);
        shadow.shadowBlurRadius = 2;
        
        // Get channel count for this group
        NSArray *channelsInGroup = [self.channelsByGroup objectForKey:group];
        NSString *displayText;
        
        // Only show count for non-settings categories
        if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
            // For settings, just show the group name without count
            displayText = group;
        } else {
            // For other categories (TV, MOVIES, etc.), show count
            displayText = [NSString stringWithFormat:@"%@ (%ld)", 
                          group, 
                          (long)[channelsInGroup count]];
        }
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.95 alpha:1.0],
            NSParagraphStyleAttributeName: style,
            NSShadowAttributeName: shadow
        };
        
        NSRect textRect = NSMakeRect(itemRect.origin.x + 16,
                                        itemRect.origin.y + (itemRect.size.height - 16) / 2, 
                                   itemRect.size.width - 32,
                                   16);
        
        [displayText drawInRect:textRect withAttributes:attrs];
        
        // Draw catchup icon if this group contains channels with catchup support
        BOOL groupHasCatchupChannels = [self groupHasCatchupChannels:group];
        if (groupHasCatchupChannels) {
            NSRect catchupIconRect = NSMakeRect(
                itemRect.origin.x + itemRect.size.width - 28, // Position on the right side  
                itemRect.origin.y + (itemRect.size.height - 14) / 2, // Center vertically
                14, 
                14
            );
            
            // Draw catchup icon (clock with arrow) - slightly smaller for groups
            [[NSColor colorWithCalibratedRed:0.2 green:0.7 blue:1.0 alpha:0.9] set];
            
            // Draw clock circle
            NSBezierPath *clockCircle = [NSBezierPath bezierPathWithOvalInRect:catchupIconRect];
            [clockCircle setLineWidth:1.2];
            [clockCircle stroke];
            
            // Draw clock hands pointing to 10:10 (classic clock position)
            NSPoint center = NSMakePoint(catchupIconRect.origin.x + catchupIconRect.size.width/2, 
                                        catchupIconRect.origin.y + catchupIconRect.size.height/2);
            
            // Hour hand (pointing to 10) - smaller for group icon
            NSBezierPath *hourHand = [NSBezierPath bezierPath];
            [hourHand moveToPoint:center];
            [hourHand lineToPoint:NSMakePoint(center.x - 2.5, center.y + 1.5)];
            [hourHand setLineWidth:1.2];
            [hourHand stroke];
            
            // Minute hand (pointing to 2) - smaller for group icon
            NSBezierPath *minuteHand = [NSBezierPath bezierPath];
            [minuteHand moveToPoint:center];
            [minuteHand lineToPoint:NSMakePoint(center.x + 3, center.y + 1)];
            [minuteHand setLineWidth:1.0];
            [minuteHand stroke];
            
            // Center dot
            NSBezierPath *centerDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - 0.5, center.y - 0.5, 1, 1)];
            [centerDot fill];
            
            // Draw small arrow to indicate rewind capability - smaller for group
            NSBezierPath *rewindArrow = [NSBezierPath bezierPath];
            [rewindArrow moveToPoint:NSMakePoint(center.x - 5, center.y - 5)];
            [rewindArrow lineToPoint:NSMakePoint(center.x - 2.5, center.y - 3.5)];
            [rewindArrow lineToPoint:NSMakePoint(center.x - 2.5, center.y - 6.5)];
            [rewindArrow closePath];
            [rewindArrow fill];
        }
        
        [style release];
        [shadow release];
    }
}

- (void)drawSearchInterface:(NSRect)rect menuRect:(NSRect)menuRect {
    // FIXED: Only create/show search interface when menu is actually visible
    // This prevents the search textbox from being recreated when menu fades back in
    if (!self.isChannelListVisible) {
        return;
    }
    
    // Calculate textbox position
    CGFloat padding = 20;
    CGFloat textboxHeight = 35;
    CGFloat textboxY = menuRect.size.height - 80; // Position near top
    
    NSRect searchRect = NSMakeRect(menuRect.origin.x + padding,
                                  textboxY,
                                  menuRect.size.width - (padding * 2),
                                  textboxHeight);
    
    // Only create search textfield if it doesn't exist or if it's not in the superview
    if (!self.searchTextField || ![self.subviews containsObject:self.searchTextField]) {
        // Store previous search value if textfield exists but is not in superview
        NSString *previousSearchValue = nil;
        if (self.searchTextField) {
            previousSearchValue = [self.searchTextField stringValue];
            [self.searchTextField release];
        }
        
        // Create new search textfield
        self.searchTextField = [[VLCReusableTextField alloc] initWithFrame:searchRect identifier:@"search"];
        self.searchTextField.textFieldDelegate = self;
        [self.searchTextField setPlaceholderText:@"Search channels..."];
        
        // Restore previous search value if it existed
        if (previousSearchValue && [previousSearchValue length] > 0) {
            [self.searchTextField setStringValue:previousSearchValue];
        }
        
        // Add to superview
        [self addSubview:self.searchTextField];
    } else {
        // Just update frame if textfield already exists and is in superview
        [self.searchTextField setFrame:searchRect];
    }
    
    // Make sure search textfield is visible and active
    [self.searchTextField setHidden:NO];
    
    // Draw search label
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    };
    
    NSRect labelRect = NSMakeRect(searchRect.origin.x, searchRect.origin.y + textboxHeight + 10, 100, 20);
    [@"Search:" drawInRect:labelRect withAttributes:labelAttrs];
    [style release];
}

- (void)performSearch:(NSString *)searchText {
    // Cancel previous timer if running
    if (self.searchTimer) {
        [self.searchTimer invalidate];
        self.searchTimer = nil;
    }
    
    if (!searchText || [searchText length] == 0) {
        // Clear search results immediately if search text is empty
        self.searchResults = [NSMutableArray array];
        self.isSearchActive = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsDisplay:YES];
        });
        return;
    }
    
    // Debounce search - wait 300ms after user stops typing
    self.searchTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                        target:self
                                                      selector:@selector(performDelayedSearch:)
                                                      userInfo:@{@"searchText": searchText}
                                                       repeats:NO];
}

- (void)performDelayedSearch:(NSTimer *)timer {
    NSString *searchText = [[timer userInfo] objectForKey:@"searchText"];
    
    // Create search queue if needed
    if (!self.searchQueue) {
        self.searchQueue = dispatch_queue_create("com.vlc.search", DISPATCH_QUEUE_SERIAL);
    }
    
    // Perform search on background thread
    dispatch_async(self.searchQueue, ^{
        NSMutableArray *allResults = [NSMutableArray array];
        NSMutableArray *channelResults = [NSMutableArray array];
        NSMutableArray *movieResults = [NSMutableArray array];
        NSString *lowercaseSearchText = [searchText lowercaseString];
        
        // Search in channels (regular TV channels)
        if (self.channels) {
            for (VLCChannel *channel in self.channels) {
                if ([self channel:channel matchesSearchText:lowercaseSearchText]) {
                    // Check if this is a movie/series or regular channel based on group
                    if (channel.group && 
                        ([[channel.group lowercaseString] containsString:@"movie"] ||
                         [[channel.group lowercaseString] containsString:@"series"] ||
                         [[channel.group lowercaseString] containsString:@"film"] ||
                         [[channel.group lowercaseString] containsString:@"cinema"])) {
                        [movieResults addObject:channel];
                    } else {
                        [channelResults addObject:channel];
                    }
                    [allResults addObject:channel];
                }
            }
        }
        
        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            self.searchResults = allResults;
            self.searchChannelResults = channelResults;
            self.searchMovieResults = movieResults;
            self.isSearchActive = ([allResults count] > 0 || [searchText length] > 0);
            [self setNeedsDisplay:YES];
        });
    });
}

- (BOOL)channel:(VLCChannel *)channel matchesSearchText:(NSString *)searchText {
    if (!channel || !searchText) return NO;
    
    // Search in channel name
    if (channel.name && [[channel.name lowercaseString] containsString:searchText]) {
        return YES;
    }
    
    // Search in channel group
    if (channel.group && [[channel.group lowercaseString] containsString:searchText]) {
        return YES;
    }
    
    // Search in channel URL (for specific stream names) 
    if (channel.url && [[channel.url lowercaseString] containsString:searchText]) {
        return YES;
    }
    
    return NO;
}

#pragma mark - Subtitle Settings Drawing

- (void)drawSubtitleSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 20;
    CGFloat startY = self.bounds.size.height - 100;
    CGFloat controlWidth = width - (padding * 2);
    CGFloat yOffset = 0;
    
    // Draw a section title
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect titleRect = NSMakeRect(x + padding, startY, controlWidth, 20);
    [@"Subtitle Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    // Description
    NSDictionary *descAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect descRect = NSMakeRect(x + padding, startY - 25, controlWidth, 16);
    [@"Move the slider to adjust subtitle text size in real-time" drawInRect:descRect withAttributes:descAttrs];
    
    // Get settings instance
    VLCSubtitleSettings *settings = [VLCSubtitleSettings sharedInstance];
    
    yOffset = 60;
    
    // Font Size Control
    CGFloat sliderY = startY - yOffset;
    NSString *fontSizeLabel = [NSString stringWithFormat:@"Font Size: %ld px", (long)settings.fontSize];
    
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect fontSizeLabelRect = NSMakeRect(x + padding, sliderY, controlWidth, 20);
    [fontSizeLabel drawInRect:fontSizeLabelRect withAttributes:labelAttrs];
    
    // Draw slider background with rounded corners
    NSRect sliderRect = NSMakeRect(x + padding, sliderY - 25, controlWidth - 40, 8); // Made thicker for easier interaction
    [[NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:1.0] set];
    NSBezierPath *sliderBg = [NSBezierPath bezierPathWithRoundedRect:sliderRect xRadius:4 yRadius:4];
    [sliderBg fill];
    
    // Draw slider fill (representing current value)
    CGFloat sliderProgress = (settings.fontSize - 6.0) / (30.0 - 6.0); // Range 6-30px
    sliderProgress = MAX(0.0, MIN(1.0, sliderProgress));
    NSRect sliderFillRect = NSMakeRect(sliderRect.origin.x, sliderRect.origin.y, 
                                       sliderRect.size.width * sliderProgress, sliderRect.size.height);
    [[NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.8 alpha:1.0] set];
    NSBezierPath *sliderFill = [NSBezierPath bezierPathWithRoundedRect:sliderFillRect xRadius:4 yRadius:4];
    [sliderFill fill];
    
    // Draw slider thumb with better design
    CGFloat thumbX = sliderRect.origin.x + (sliderRect.size.width * sliderProgress) - 8;
    NSRect thumbRect = NSMakeRect(thumbX, sliderRect.origin.y - 4, 16, 16);
    
    // Add subtle shadow to thumb
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.3] set];
    NSBezierPath *thumbShadow = [NSBezierPath bezierPathWithOvalInRect:NSOffsetRect(thumbRect, 1, -1)];
    [thumbShadow fill];
    
    // Thumb
    [[NSColor whiteColor] set];
    NSBezierPath *thumbPath = [NSBezierPath bezierPathWithOvalInRect:thumbRect];
    [thumbPath fill];
    
    // Store slider rectangle for click handling (expand hitbox for easier interaction)
    NSRect interactionRect = NSMakeRect(sliderRect.origin.x - 10, sliderRect.origin.y - 10, 
                                        sliderRect.size.width + 20, sliderRect.size.height + 20);
    objc_setAssociatedObject(self, "subtitleFontSizeSliderRect", [NSValue valueWithRect:interactionRect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [style release];
}

#pragma mark - Theme Settings Drawing

- (void)drawThemeSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 30;
    CGFloat startY = self.bounds.size.height - 80;
    CGFloat controlWidth = width - (padding * 2);
    CGFloat yOffset = 0;
    CGFloat controlHeight = 35;
    CGFloat verticalSpacing = 25;
    
    // Draw a section title
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:18],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect titleRect = NSMakeRect(x + padding, startY, controlWidth, 25);
    [@"Theme Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    // Draw Theme Selector
    yOffset += 45;
    NSRect themeLabelRect = NSMakeRect(x + padding, startY - yOffset, 100, 20);
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    [@"Theme:" drawInRect:themeLabelRect withAttributes:labelAttrs];
    
    // Theme dropdown button
    self.themeDropdownRect = NSMakeRect(x + padding + 110, startY - yOffset, controlWidth - 120, controlHeight);
    
    // Draw theme dropdown
    [self drawDropdownButton:self.themeDropdownRect 
                        text:[self getCurrentThemeDisplayText]
                  identifier:@"theme"];
    
    yOffset += controlHeight + verticalSpacing;
    
    // Show RGB sliders only when Custom theme is selected
    if (self.currentTheme == VLC_THEME_CUSTOM) {
        // Red slider
        NSRect redRect = NSMakeRect(x + padding, startY - yOffset, controlWidth, controlHeight);
        NSString *redDisplayText = [NSString stringWithFormat:@"%d", (int)(self.customThemeRed * 255)];
        
        NSRect redSliderInteractionRect;
        [VLCSliderControl drawSlider:redRect
                              label:@"Red:"
                           minValue:0.0
                           maxValue:1.0
                       currentValue:self.customThemeRed
                        labelColor:self.textColor
                        sliderRect:&redSliderInteractionRect
                       displayText:redDisplayText];
        self.redSliderRect = redSliderInteractionRect;
        
        yOffset += controlHeight + verticalSpacing;
        
        // Green slider
        NSRect greenRect = NSMakeRect(x + padding, startY - yOffset, controlWidth, controlHeight);
        NSString *greenDisplayText = [NSString stringWithFormat:@"%d", (int)(self.customThemeGreen * 255)];
        
        NSRect greenSliderInteractionRect;
        [VLCSliderControl drawSlider:greenRect
                              label:@"Green:"
                           minValue:0.0
                           maxValue:1.0
                       currentValue:self.customThemeGreen
                        labelColor:self.textColor
                        sliderRect:&greenSliderInteractionRect
                       displayText:greenDisplayText];
        self.greenSliderRect = greenSliderInteractionRect;
        
        yOffset += controlHeight + verticalSpacing;
        
        // Blue slider
        NSRect blueRect = NSMakeRect(x + padding, startY - yOffset, controlWidth, controlHeight);
        NSString *blueDisplayText = [NSString stringWithFormat:@"%d", (int)(self.customThemeBlue * 255)];
        
        NSRect blueSliderInteractionRect;
        [VLCSliderControl drawSlider:blueRect
                              label:@"Blue:"
                           minValue:0.0
                           maxValue:1.0
                       currentValue:self.customThemeBlue
                        labelColor:self.textColor
                        sliderRect:&blueSliderInteractionRect
                       displayText:blueDisplayText];
        self.blueSliderRect = blueSliderInteractionRect;
        
        yOffset += controlHeight + verticalSpacing;
    
    // Add a section separator for Selection Colors
    yOffset += 15;
    NSRect selectionSectionRect = NSMakeRect(x + padding, startY - yOffset, controlWidth, 25);
    NSDictionary *sectionAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    [@"Selection Colors" drawInRect:selectionSectionRect withAttributes:sectionAttrs];
    yOffset += 35;
    
        // Selection Color RGB sliders (only shown for custom theme)
    // Selection Red slider
    NSRect selectionRedRect = NSMakeRect(x + padding, startY - yOffset, controlWidth, controlHeight);
    NSString *selectionRedDisplayText = [NSString stringWithFormat:@"%d", (int)(self.customSelectionRed * 255)];
    
    NSRect selectionRedSliderInteractionRect;
    [VLCSliderControl drawSlider:selectionRedRect
                          label:@"Selection Red:"
                       minValue:0.0
                       maxValue:1.0
                   currentValue:self.customSelectionRed
                    labelColor:self.textColor
                    sliderRect:&selectionRedSliderInteractionRect
                   displayText:selectionRedDisplayText];
    self.selectionRedSliderRect = selectionRedSliderInteractionRect;
    
    yOffset += controlHeight + verticalSpacing;
    
    // Selection Green slider
    NSRect selectionGreenRect = NSMakeRect(x + padding, startY - yOffset, controlWidth, controlHeight);
    NSString *selectionGreenDisplayText = [NSString stringWithFormat:@"%d", (int)(self.customSelectionGreen * 255)];
    
    NSRect selectionGreenSliderInteractionRect;
    [VLCSliderControl drawSlider:selectionGreenRect
                          label:@"Selection Green:"
                       minValue:0.0
                       maxValue:1.0
                   currentValue:self.customSelectionGreen
                    labelColor:self.textColor
                    sliderRect:&selectionGreenSliderInteractionRect
                   displayText:selectionGreenDisplayText];
    self.selectionGreenSliderRect = selectionGreenSliderInteractionRect;
    
    yOffset += controlHeight + verticalSpacing;
    
    // Selection Blue slider
    NSRect selectionBlueRect = NSMakeRect(x + padding, startY - yOffset, controlWidth, controlHeight);
    NSString *selectionBlueDisplayText = [NSString stringWithFormat:@"%d", (int)(self.customSelectionBlue * 255)];
    
    NSRect selectionBlueSliderInteractionRect;
    [VLCSliderControl drawSlider:selectionBlueRect
                          label:@"Selection Blue:"
                       minValue:0.0
                       maxValue:1.0
                   currentValue:self.customSelectionBlue
                    labelColor:self.textColor
                    sliderRect:&selectionBlueSliderInteractionRect
                   displayText:selectionBlueDisplayText];
    self.selectionBlueSliderRect = selectionBlueSliderInteractionRect;
    
    yOffset += controlHeight + verticalSpacing;
    } else {
        // Clear RGB slider rects when theme is not custom to make them non-interactive
        self.redSliderRect = NSZeroRect;
        self.greenSliderRect = NSZeroRect;
        self.blueSliderRect = NSZeroRect;
        
        // Also clear selection color slider rects when theme is not custom
        self.selectionRedSliderRect = NSZeroRect;
        self.selectionGreenSliderRect = NSZeroRect;
        self.selectionBlueSliderRect = NSZeroRect;
        
        // Reset slider activation state if any RGB or selection sliders were active
        NSString *activeSlider = [VLCSliderControl activeSliderHandle];
        if (activeSlider && ([activeSlider isEqualToString:@"red"] || 
                            [activeSlider isEqualToString:@"green"] || 
                            [activeSlider isEqualToString:@"blue"] ||
                            [activeSlider isEqualToString:@"selectionRed"] ||
                            [activeSlider isEqualToString:@"selectionGreen"] ||
                            [activeSlider isEqualToString:@"selectionBlue"])) {
            [VLCSliderControl handleMouseUp];
        }
    }
    
    // Draw Transparency Slider (always shown)
    NSRect transparencyRect = NSMakeRect(x + padding, startY - yOffset, controlWidth, controlHeight);
    
    // Convert transparency level to continuous slider value (0.5 to 0.95)
    CGFloat currentValue = self.themeAlpha;
    NSString *displayText = [NSString stringWithFormat:@"%.0f%%", currentValue * 100];
    
    // Use a local variable to store the slider rect for interaction
    NSRect sliderInteractionRect;
    [VLCSliderControl drawSlider:transparencyRect
                          label:@"Transparency:"
                       minValue:0.0
                       maxValue:1.0
                   currentValue:currentValue
                    labelColor:self.textColor
                    sliderRect:&sliderInteractionRect
                   displayText:displayText];
    
    // Store the slider rect in the property for later use
    self.transparencySliderRect = sliderInteractionRect;
    
    [style release];
}

- (void)drawDropdownButton:(NSRect)rect text:(NSString *)text identifier:(NSString *)identifier {
    // Check if this dropdown is open
    VLCDropdown *dropdown = [self.dropdownManager dropdownWithIdentifier:identifier];
    BOOL isOpen = dropdown && dropdown.isOpen;
    
    // Draw button background
    NSColor *bgColor = isOpen ? self.hoverColor : self.backgroundColor;
    [bgColor set];
    NSBezierPath *bgPath = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:3 yRadius:3];
    [bgPath fill];
    
    // Draw border
    [self.textColor set];
    [bgPath stroke];
    
    // Draw text
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect textRect = NSMakeRect(rect.origin.x + 8,
                                rect.origin.y + (rect.size.height - 16) / 2,
                                rect.size.width - 28,
                                16);
    [text drawInRect:textRect withAttributes:attrs];
    
    // Draw dropdown arrow
    NSRect arrowRect = NSMakeRect(rect.origin.x + rect.size.width - 20,
                                 rect.origin.y + (rect.size.height - 10) / 2,
                                 10, 10);
    [[NSColor lightGrayColor] set];
    NSBezierPath *arrowPath = [NSBezierPath bezierPath];
    if (isOpen) {
        // Up arrow when dropdown is open
        [arrowPath moveToPoint:NSMakePoint(arrowRect.origin.x, arrowRect.origin.y)];
        [arrowPath lineToPoint:NSMakePoint(arrowRect.origin.x + arrowRect.size.width/2, arrowRect.origin.y + arrowRect.size.height)];
        [arrowPath lineToPoint:NSMakePoint(arrowRect.origin.x + arrowRect.size.width, arrowRect.origin.y)];
    } else {
        // Down arrow when dropdown is closed
        [arrowPath moveToPoint:NSMakePoint(arrowRect.origin.x, arrowRect.origin.y + arrowRect.size.height)];
        [arrowPath lineToPoint:NSMakePoint(arrowRect.origin.x + arrowRect.size.width/2, arrowRect.origin.y)];
        [arrowPath lineToPoint:NSMakePoint(arrowRect.origin.x + arrowRect.size.width, arrowRect.origin.y + arrowRect.size.height)];
    }
    [arrowPath closePath];
    [arrowPath fill];
    
    [style release];
}

- (NSString *)getCurrentThemeDisplayText {
    switch (self.currentTheme) {
        case VLC_THEME_DARK: return @"Dark";
        case VLC_THEME_DARKER: return @"Darker";
        case VLC_THEME_BLUE: return @"Blue";
        case VLC_THEME_GREEN: return @"Green";
        case VLC_THEME_PURPLE: return @"Purple";
        case VLC_THEME_CUSTOM: return @"Custom";
        default: return @"Dark";
    }
}

- (NSString *)getCurrentTransparencyDisplayText {
    switch (self.transparencyLevel) {
        case VLC_TRANSPARENCY_OPAQUE: return @"Opaque";
        case VLC_TRANSPARENCY_LIGHT: return @"Light";
        case VLC_TRANSPARENCY_MEDIUM: return @"Medium";
        case VLC_TRANSPARENCY_HIGH: return @"High";
        case VLC_TRANSPARENCY_VERY_HIGH: return @"Very High";
        default: return @"Medium";
    }
}

- (void)setupThemeDropdowns {
    if (!self.dropdownManager) {
        return;
    }
    
    // Create theme dropdown
    VLCDropdown *themeDropdown = [self.dropdownManager createDropdownWithIdentifier:@"theme" frame:self.themeDropdownRect];
    [themeDropdown addItemWithValue:@(VLC_THEME_DARK) displayText:@"Dark"];
    [themeDropdown addItemWithValue:@(VLC_THEME_DARKER) displayText:@"Darker"];
    [themeDropdown addItemWithValue:@(VLC_THEME_BLUE) displayText:@"Blue"];
    [themeDropdown addItemWithValue:@(VLC_THEME_GREEN) displayText:@"Green"];
    [themeDropdown addItemWithValue:@(VLC_THEME_PURPLE) displayText:@"Purple"];
    [themeDropdown addItemWithValue:@(VLC_THEME_CUSTOM) displayText:@"Custom"];
    
    // Find the correct index for the current theme instead of using the enum value directly
    NSInteger selectedIndex = 0; // Default to first item (Dark)
    for (NSInteger i = 0; i < [themeDropdown.items count]; i++) {
        VLCDropdownItem *item = [themeDropdown.items objectAtIndex:i];
        if ([item.value integerValue] == self.currentTheme) {
            selectedIndex = i;
            break;
        }
    }
    themeDropdown.selectedIndex = selectedIndex;
    
    // Set theme dropdown callback
    themeDropdown.onSelectionChanged = ^(VLCDropdown *dropdown, VLCDropdownItem *selectedItem, NSInteger index) {
        VLCColorTheme newTheme = [selectedItem.value integerValue];
        NSLog(@"Theme changed from %ld to: %@ (%ld)", (long)self.currentTheme, selectedItem.displayText, (long)newTheme);
        [self applyTheme:newTheme];
        [self setNeedsDisplay:YES];
        NSLog(@"After applying theme: currentTheme = %ld", (long)self.currentTheme);
    };
    
    // Create transparency slider
    CGFloat currentValue = [self alphaForTransparencyLevel:self.transparencyLevel];
    NSString *displayText = [NSString stringWithFormat:@"%.0f%%", currentValue * 100];
    
    NSRect sliderInteractionRect;
    [VLCSliderControl drawSlider:self.transparencyDropdownRect
                          label:@"Transparency:"
                       minValue:0.0
                       maxValue:1.0
                   currentValue:currentValue
                    labelColor:self.textColor
                    sliderRect:&sliderInteractionRect
                   displayText:displayText];
    
    self.transparencySliderRect = sliderInteractionRect;
}

- (void)handleThemeDropdownClick:(NSPoint)point {
    if (NSPointInRect(point, self.themeDropdownRect)) {
        VLCDropdown *dropdown = [self.dropdownManager dropdownWithIdentifier:@"theme"];
        if (dropdown) {
            if (dropdown.isOpen) {
                [self.dropdownManager hideDropdown:@"theme"];
                } else {
                // Update dropdown frame to current position
                dropdown.frame = self.themeDropdownRect;
                [self.dropdownManager showDropdown:@"theme"];
            }
        } else {
            [self setupThemeDropdowns];
            [self.dropdownManager showDropdown:@"theme"];
        }
    }
}

#pragma mark - Theme Controls Management

- (void)showThemeControls {
    // Setup theme dropdowns when in theme settings
    [self setupThemeDropdowns];
}

- (void)hideThemeControls {
    // Hide theme dropdowns when not in theme settings
    if (self.dropdownManager) {
        [self.dropdownManager hideDropdown:@"theme"];
    }
}

- (void)updateUIComponentsVisibility {
    BOOL isSettingsVisible = (self.selectedCategoryIndex == CATEGORY_SETTINGS);
    BOOL isSearchVisible = (self.selectedCategoryIndex == CATEGORY_SEARCH);
    BOOL isThemeGroupSelected = NO;
    
    if (isSettingsVisible) {
        // Check if Themes group is selected
        NSArray *settingsGroups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
        if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < [settingsGroups count]) {
            NSString *selectedGroup = [settingsGroups objectAtIndex:self.selectedGroupIndex];
            isThemeGroupSelected = [selectedGroup isEqualToString:@"Themes"];
        }
    }
    
    // Manage search textfield visibility
    if (isSearchVisible) {
        // Force a redraw to show the search interface
        [self setNeedsDisplay:YES];
    } else {
        if (self.searchTextField) {
            [self.searchTextField setHidden:YES];
            [self.searchTextField deactivateField];
        }
        
        // Clear search results when leaving search mode
        if (self.isSearchActive) {
            self.searchResults = [NSMutableArray array];
            self.isSearchActive = NO;
            [self setNeedsDisplay:YES];
        }
    }
    
    // Manage theme controls visibility
    if (isThemeGroupSelected) {
        [self showThemeControls];
    } else {
        [self hideThemeControls];
    }
}

@end
