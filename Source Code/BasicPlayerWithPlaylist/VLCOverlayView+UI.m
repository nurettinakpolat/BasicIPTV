#import "VLCOverlayView+UI.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+PlayerControls.h"
#import "VLCSubtitleSettings.h"
#import <objc/runtime.h>
#import "VLCOverlayView+Utilities.h"
#import <math.h>

// Global variable to track menu fade-out state
BOOL isFadingOut = NO;

// Add this variable at the top near the other globals
// Add this right after the "BOOL isFadingOut = NO;" line
NSTimeInterval lastFadeOutTime = 0;

// Add timer for auto-hiding player controls
NSTimer *playerControlsTimer = nil;
BOOL playerControlsVisible = NO; // Start with controls hidden

@implementation VLCOverlayView (UI)

// Need to add these properties for the new grid view feature
BOOL isGridViewActive = NO;
NSMutableDictionary *gridLoadingQueue = nil;
NSOperationQueue *coverDownloadQueue = nil;

// Add properties to track hover state across panels
BOOL isPersistingHoverState = NO;
NSInteger lastValidHoveredChannelIndex = -1;
NSInteger lastValidHoveredGroupIndex = -1;

#pragma mark - UI Setup

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

- (void)drawCategories:(NSRect)rect {
    CGFloat rowHeight = 40;
    CGFloat catWidth = 200;
    
    // Draw background with consistent semi-transparent black
    NSRect menuRect = NSMakeRect(0, 0, catWidth, self.bounds.size.height);
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.7] set];
    NSRectFill(menuRect);
    
    // Calculate total height for scroll bar
    CGFloat totalCategoriesHeight = [self.categories count] * rowHeight;
    
    // Draw each category
    for (NSInteger i = 0; i < [self.categories count]; i++) {
        NSRect itemRect = NSMakeRect(0, 
                                     self.bounds.size.height - ((i+1) * rowHeight) + categoryScrollPosition, 
                                     catWidth, 
                                     rowHeight);
        
        // Skip drawing if not visible
        if (!NSIntersectsRect(itemRect, rect)) {
            continue;
        }
        
        // Highlight selected category
        if (i == self.selectedCategoryIndex) {
            [self.hoverColor set];
            NSRectFill(itemRect);
        }
        
        // Draw the category name
        NSString *category = [self.categories objectAtIndex:i];
        
        // Draw with white text
        [self.textColor set];
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentLeft];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSString *displayName = category;
        NSRect textRect = NSMakeRect(itemRect.origin.x + 10, 
                                     itemRect.origin.y + (itemRect.size.height - 20) / 2, 
                                     itemRect.size.width - 20, 
                                     20);
        
        [displayName drawInRect:textRect withAttributes:attrs];
        [style release];
    }
    
    // Draw scroll bar if needed
    [self drawScrollBar:menuRect contentHeight:totalCategoriesHeight scrollPosition:categoryScrollPosition];
}

- (void)drawGroups:(NSRect)rect {
    if (self.selectedCategoryIndex < 0 || self.selectedCategoryIndex >= [self.categories count]) {
        return;
    }
    
    CGFloat rowHeight = 40;
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    
    // Draw background with consistent semi-transparent black
    NSRect menuRect = NSMakeRect(catWidth, 0, groupWidth, self.bounds.size.height);
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.7] set];
    NSRectFill(menuRect);
    
    // Get the appropriate groups based on category
    NSArray *groups;
    NSString *categoryName = [self.categories objectAtIndex:self.selectedCategoryIndex];
    
    if ([categoryName isEqualToString:@"FAVORITES"]) {
        groups = [self safeGroupsForCategory:@"FAVORITES"];
    } else if ([categoryName isEqualToString:@"TV"]) {
        groups = [self safeTVGroups];
    } else if ([categoryName isEqualToString:@"MOVIES"]) {
        groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
    } else if ([categoryName isEqualToString:@"SERIES"]) {
        groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
    } else if ([categoryName isEqualToString:@"SETTINGS"]) {
        groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
    } else {
        return;
    }
    
    // Draw each group
    for (NSInteger i = 0; i < [groups count]; i++) {
        // Calculate visible position based on scroll
        NSInteger visibleIndex = i - (NSInteger)floor(groupScrollPosition / rowHeight);
        
        NSRect itemRect = NSMakeRect(catWidth, 
                                     self.bounds.size.height - ((visibleIndex+1) * rowHeight), 
                                     groupWidth, 
                                     rowHeight);
        
        // Skip drawing if not visible
        if (!NSIntersectsRect(itemRect, rect)) {
            continue;
        }
        
        // Highlight selected or hovered group
        if (i == self.selectedGroupIndex) {
            [self.hoverColor set];
            NSRectFill(itemRect);
        } else if (i == self.hoveredGroupIndex) {
            // Use a lighter hover color for just hovering
            [[self.hoverColor colorWithAlphaComponent:0.5] set];
            NSRectFill(itemRect);
        }
        
        // Draw the group name
        NSString *group = [groups objectAtIndex:i];
        
        // Check if this group has catch-up channels
        BOOL hasCatchup = [self groupHasCatchupChannels:group];
        
        // Draw with white text
        [self.textColor set];
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentLeft];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: style
        };
        
        // Adjust text rect to make room for catch-up icon if needed
        CGFloat iconSpace = hasCatchup ? 20 : 0;
        NSRect textRect = NSMakeRect(itemRect.origin.x + 10, 
                                     itemRect.origin.y + (itemRect.size.height - 20) / 2, 
                                     itemRect.size.width - 20 - iconSpace, 
                                     20);
        
        [group drawInRect:textRect withAttributes:attrs];
        
        // Draw catch-up icon if this group has catch-up channels
        if (hasCatchup) {
            NSRect iconRect = NSMakeRect(itemRect.origin.x + itemRect.size.width - 25, 
                                        itemRect.origin.y + (itemRect.size.height - 16) / 2, 
                                        16, 
                                        16);
            
            // Draw a clock/rewind icon to indicate catch-up availability
            [[NSColor colorWithCalibratedRed:0.3 green:0.7 blue:1.0 alpha:1.0] set];
            
            // Draw clock circle
            NSBezierPath *clockCircle = [NSBezierPath bezierPathWithOvalInRect:iconRect];
            [clockCircle setLineWidth:1.5];
            [clockCircle stroke];
            
            // Draw clock hands
            NSPoint center = NSMakePoint(iconRect.origin.x + iconRect.size.width/2, 
                                        iconRect.origin.y + iconRect.size.height/2);
            
            // Hour hand (pointing to 10)
            NSBezierPath *hourHand = [NSBezierPath bezierPath];
            [hourHand moveToPoint:center];
            [hourHand lineToPoint:NSMakePoint(center.x - 3, center.y + 2)];
            [hourHand setLineWidth:1.5];
            [hourHand stroke];
            
            // Minute hand (pointing to 2)
            NSBezierPath *minuteHand = [NSBezierPath bezierPath];
            [minuteHand moveToPoint:center];
            [minuteHand lineToPoint:NSMakePoint(center.x + 4, center.y + 1)];
            [minuteHand setLineWidth:1.0];
            [minuteHand stroke];
            
            // Center dot
            NSRect centerDot = NSMakeRect(center.x - 1, center.y - 1, 2, 2);
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:centerDot];
            [dot fill];
        }
        
        [style release];
    }
    
    // Only draw scroll bar if we have groups and they need scrolling
    if (groups && [groups count] > 0) {
        // Calculate total height for groups
        CGFloat totalGroupsHeight = [groups count] * rowHeight;
        
        // Draw scroll bar if needed
        [self drawScrollBar:menuRect contentHeight:totalGroupsHeight scrollPosition:groupScrollPosition];
    }
}

- (void)drawChannelList:(NSRect)rect {
    CGFloat rowHeight = 40;
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat channelListX = catWidth + groupWidth;
    
    // Reduce channel list width to make space for program guide on right
    CGFloat programGuideWidth = 400; // Increased width for program guide
    CGFloat channelListWidth = self.bounds.size.width - channelListX - programGuideWidth;
    
    // Draw background with consistent semi-transparent black
    NSRect menuRect = NSMakeRect(channelListX, 0, channelListWidth, self.bounds.size.height);
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.7] set];
    NSRectFill(menuRect);
    
    // Define the content rect for the channel list
    NSRect contentRect = NSMakeRect(channelListX, 0, channelListWidth, self.bounds.size.height);
    
    // Calculate total content height
    CGFloat totalContentHeight = [self.simpleChannelNames count] * rowHeight;
    
    // Add extra space at bottom to ensure last item is fully visible when scrolled to the end
    totalContentHeight += rowHeight;
    
    // Update scroll limits to ensure last item is fully visible
    CGFloat maxScroll = MAX(0, totalContentHeight - contentRect.size.height);
    CGFloat scrollPosition = MIN(channelScrollPosition, maxScroll);
    
    // Draw each channel - removed header bar completely
    for (NSInteger i = 0; i < [self.simpleChannelNames count]; i++) {
        // Calculate visible position accounting for scroll
        NSInteger visibleIndex = i - (NSInteger)floor(scrollPosition / rowHeight);
        
        // Adjusted positioning to start from top with no header offset
        NSRect itemRect = NSMakeRect(channelListX, 
                                     self.bounds.size.height - ((visibleIndex+1) * rowHeight), 
                                     channelListWidth, 
                                     rowHeight);
        
        // Skip drawing if not visible
        if (!NSIntersectsRect(itemRect, rect)) {
            continue;
        }
        
        // Highlight hovered or selected channel
        if (i == self.hoveredChannelIndex || i == self.selectedChannelIndex) {
            [self.hoverColor set];
            NSRectFill(itemRect);
        }
        
        // Draw channel name
        NSString *channelName = [self.simpleChannelNames objectAtIndex:i];
        
        [self.textColor set];
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentLeft];
        
        NSDictionary *channelAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:14],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: style
        };
        
        // Channel name takes less space to make room for program info
        NSRect channelTextRect = NSMakeRect(itemRect.origin.x + 10, 
                                     itemRect.origin.y + (itemRect.size.height - 23),
                                     itemRect.size.width - 20,
                                     20);
        
        [channelName drawInRect:channelTextRect withAttributes:channelAttrs];
        
        // Draw timeshift indicator if channel supports catchup (before getting channel object)
        // We need to get the channel object first to check timeshift support
        VLCChannel *tempChannel = nil;
        NSString *tempCurrentGroup = nil;
        NSArray *tempGroups = nil;
        
        // Get current category and group to find the channel
        NSString *tempCurrentCategory = nil;
        if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
            tempCurrentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
            
            // Get the appropriate groups based on category
            if ([tempCurrentCategory isEqualToString:@"FAVORITES"]) {
                tempGroups = [self safeGroupsForCategory:@"FAVORITES"];
            } else if ([tempCurrentCategory isEqualToString:@"TV"]) {
                tempGroups = [self safeTVGroups];
            } else if ([tempCurrentCategory isEqualToString:@"MOVIES"]) {
                tempGroups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
            } else if ([tempCurrentCategory isEqualToString:@"SERIES"]) {
                tempGroups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
            }
            
            // Get the current group
            if (tempGroups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < tempGroups.count) {
                tempCurrentGroup = [tempGroups objectAtIndex:self.selectedGroupIndex];
                
                // Get channels for this group
                NSArray *tempChannelsInGroup = [self.channelsByGroup objectForKey:tempCurrentGroup];
                if (tempChannelsInGroup && i < tempChannelsInGroup.count) {
                    tempChannel = [tempChannelsInGroup objectAtIndex:i];
                }
            }
        }
        
        // Draw timeshift indicator if channel supports catchup
        if (tempChannel && tempChannel.supportsCatchup) {
            NSRect timeshiftIconRect = NSMakeRect(
                itemRect.origin.x + itemRect.size.width - 30, // Position on the right side
                itemRect.origin.y + (itemRect.size.height - 16) / 2 + 8, // Center vertically, slightly down
                16, 
                16
            );
            
            // Draw timeshift icon (clock with arrow)
            [[NSColor colorWithCalibratedRed:0.2 green:0.7 blue:1.0 alpha:0.9] set];
            
            // Draw clock circle
            NSBezierPath *clockCircle = [NSBezierPath bezierPathWithOvalInRect:timeshiftIconRect];
            [clockCircle setLineWidth:1.5];
            [clockCircle stroke];
            
            // Draw clock hands pointing to 10:10 (classic clock position)
            NSPoint center = NSMakePoint(timeshiftIconRect.origin.x + timeshiftIconRect.size.width/2, 
                                        timeshiftIconRect.origin.y + timeshiftIconRect.size.height/2);
            
            // Hour hand (pointing to 10)
            NSBezierPath *hourHand = [NSBezierPath bezierPath];
            [hourHand moveToPoint:center];
            [hourHand lineToPoint:NSMakePoint(center.x - 3, center.y + 2)];
            [hourHand setLineWidth:1.5];
            [hourHand stroke];
            
            // Minute hand (pointing to 2)
            NSBezierPath *minuteHand = [NSBezierPath bezierPath];
            [minuteHand moveToPoint:center];
            [minuteHand lineToPoint:NSMakePoint(center.x + 4, center.y + 1)];
            [minuteHand setLineWidth:1.0];
            [minuteHand stroke];
            
            // Center dot
            NSBezierPath *centerDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - 1, center.y - 1, 2, 2)];
            [centerDot fill];
            
            // Draw small arrow to indicate rewind capability
            NSBezierPath *rewindArrow = [NSBezierPath bezierPath];
            [rewindArrow moveToPoint:NSMakePoint(center.x - 6, center.y - 6)];
            [rewindArrow lineToPoint:NSMakePoint(center.x - 3, center.y - 4)];
            [rewindArrow lineToPoint:NSMakePoint(center.x - 3, center.y - 8)];
            [rewindArrow closePath];
            [rewindArrow fill];
        }
        
        // Get the actual channel object to access program info
        VLCChannel *channel = nil;
        NSString *currentGroup = nil;
        NSArray *groups = nil;
        
        // Get current category and group
        NSString *currentCategory = nil;
        if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
            currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
            
            // Get the appropriate groups based on category
            if ([currentCategory isEqualToString:@"FAVORITES"]) {
                groups = [self safeGroupsForCategory:@"FAVORITES"];
            } else if ([currentCategory isEqualToString:@"TV"]) {
                groups = [self safeTVGroups];
            } else if ([currentCategory isEqualToString:@"MOVIES"]) {
                groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
            } else if ([currentCategory isEqualToString:@"SERIES"]) {
                groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
            }
            
            // Get the current group
            if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
                currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
                
                // Get channels for this group
                NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
                if (channelsInGroup && i < channelsInGroup.count) {
                    channel = [channelsInGroup objectAtIndex:i];
                    
                    // Proactively start loading movie info for movie channels
                    if ([currentCategory isEqualToString:@"MOVIES"] && 
                        channel && 
                        !channel.hasLoadedMovieInfo && 
                        !channel.hasStartedFetchingMovieInfo) {
                        
                        // Check if this is one of the visible items
                        NSInteger start = (NSInteger)floor(scrollPosition / rowHeight);
                        NSInteger end = start + (NSInteger)(self.bounds.size.height / rowHeight) + 2;
                        
                        if (i >= start && i <= end) {
                            // Check cache first
                            BOOL loadedFromCache = [self loadMovieInfoFromCacheForChannel:channel];
                            
                            // If not in cache, trigger an async load
                            if (!loadedFromCache) {
                                // Flag to prevent multiple fetches
                                channel.hasStartedFetchingMovieInfo = YES;
                                
                                // Queue the fetch on a background thread
                                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                    [self fetchMovieInfoForChannel:channel];
                                    
                                    // Trigger UI update on main thread
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        [self setNeedsDisplay:YES];
                                    });
                                });
                            }
                        }
                    }
                }
            }
        }
        
        // If we have a channel and EPG data, show current program
        if (channel) {
            VLCProgram *currentProgram = [channel currentProgramWithTimeOffset:self.epgTimeOffsetHours];
            
            // Debug logging for time offset issues
            
            // Check if the channel has EPG data
            BOOL hasEpgData = (self.isEpgLoaded && currentProgram != nil);
            if (hasEpgData) {
                // Draw current program name with smaller font
                NSDictionary *programAttrs = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:12],
                    NSForegroundColorAttributeName: [NSColor lightGrayColor],
                    NSParagraphStyleAttributeName: style
                };
                
                // Program info below channel name
                NSRect programTextRect = NSMakeRect(itemRect.origin.x + 8,
                                           itemRect.origin.y + 5,
                                           itemRect.size.width - 100, // Leave space for time on right
                                           16);
                
                // Truncate program title if needed
                NSString *programTitle = currentProgram.title;
                if (programTitle.length > 30) {
                    programTitle = [[programTitle substringToIndex:27] stringByAppendingString:@"..."];
                }
                [programTitle drawInRect:programTextRect withAttributes:programAttrs];
                
                // Draw program time on right side
                NSRect timeRect = NSMakeRect(itemRect.origin.x + itemRect.size.width - 90, 
                                           itemRect.origin.y + 5, 
                                           80, 
                                           16);
                
                [[currentProgram formattedTimeRangeWithOffset:self.epgTimeOffsetHours] drawInRect:timeRect withAttributes:programAttrs];
                
                // Draw progress bar
                NSDate *now = [NSDate date];
                // Apply EPG time offset for progress calculation
                NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600.0;
                NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
                NSTimeInterval totalDuration = [currentProgram.endTime timeIntervalSinceDate:currentProgram.startTime];
                NSTimeInterval elapsed = [adjustedNow timeIntervalSinceDate:currentProgram.startTime];
                CGFloat progress = totalDuration > 0 ? (elapsed / totalDuration) : 0;
                progress = MAX(0, MIN(progress, 1.0)); // Clamp between 0 and 1
                
                // Draw thin progress bar
                CGFloat progressBarHeight = 2;
                NSRect progressBarBg = NSMakeRect(itemRect.origin.x + 10, 
                                                itemRect.origin.y + 3, 
                                                itemRect.size.width - 20, 
                                                progressBarHeight);
                
                // Background bar
                [[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:0.7] set];
                NSRectFill(progressBarBg);
                
                // Progress fill
                NSRect progressBarFill = NSMakeRect(progressBarBg.origin.x, 
                                                 progressBarBg.origin.y, 
                                                 progressBarBg.size.width * progress, 
                                                 progressBarHeight);
                
                // Use a color based on how far along we are
                if (progress < 0.25) {
                    [[NSColor colorWithCalibratedRed:0.2 green:0.7 blue:0.3 alpha:0.8] set]; // Green for just started
                } else if (progress < 0.75) {
                    [[NSColor colorWithCalibratedRed:0.2 green:0.5 blue:0.8 alpha:0.8] set]; // Blue for middle
                } else {
                    [[NSColor colorWithCalibratedRed:0.8 green:0.3 blue:0.2 alpha:0.8] set]; // Red for almost over
                }
                NSRectFill(progressBarFill);
            } else {
                // No EPG data available for this channel
                if (self.isEpgLoaded) {
                    // EPG is loaded but no program data for this specific channel
                    NSDictionary *noDataAttrs = @{
                        NSFontAttributeName: [NSFont systemFontOfSize:10],
                        NSForegroundColorAttributeName: [NSColor darkGrayColor],
                        NSParagraphStyleAttributeName: style
                    };
                    
                    NSRect noDataRect = NSMakeRect(itemRect.origin.x + 10, 
                                            itemRect.origin.y + 5, 
                                            itemRect.size.width - 20, 
                                            16);
                    
                    [@"No program data available" drawInRect:noDataRect withAttributes:noDataAttrs];
                } else if (self.isLoadingEpg) {
                    // EPG is still loading, but don't show any text
                    // The progress bar in the bottom right corner will indicate loading status
                }
            }
        }
        
        [style release];
    }
    
    // Show program guide when hovering over a channel
    if (self.hoveredChannelIndex >= 0 && self.hoveredChannelIndex < [self.simpleChannelNames count]) {
        [self drawProgramGuideForHoveredChannel];
    }
    
    // Draw scroll bar
    [self drawScrollBar:contentRect contentHeight:totalContentHeight scrollPosition:scrollPosition];
}

- (void)drawLoadingIndicator:(NSRect)rect {
    if (!self.isLoading) {
        return; // Don't draw anything if we're not in loading state
    }
    
    // Create a more visible overlay in the bottom right
    CGFloat overlayWidth = 350; // Width for detailed info
    CGFloat overlayHeight = 120; // Height to fit content
    CGFloat padding = 20; // Padding from screen edges
    
    // Calculate position for bottom right corner
    NSRect overlayRect = NSMakeRect(
        self.bounds.size.width - overlayWidth - padding,
        padding,
        overlayWidth, 
        overlayHeight
    );
    
    // Draw more visible rounded background with stronger colors
    NSBezierPath *bgPath = [NSBezierPath bezierPathWithRoundedRect:overlayRect xRadius:8 yRadius:8];
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.8] set]; // Darker background
    [bgPath fill];
    
    // Draw border
    [[NSColor colorWithCalibratedWhite:0.7 alpha:0.7] set];
    [bgPath setLineWidth:1.0];
    [bgPath stroke];
    
    // Draw title and loading text
    NSString *titleText;
    
    // Determine if we're downloading or processing
    NSString *currentStatus = @"";
    if (gProgressMessageLock) {
        [gProgressMessageLock lock];
        if (gProgressMessage) {
            currentStatus = [NSString stringWithString:gProgressMessage];
        }
        [gProgressMessageLock unlock];
    }
    
    if ([currentStatus rangeOfString:@"Downloading:"].location != NSNotFound) {
        titleText = @"Downloading...";
    } else if ([currentStatus rangeOfString:@"Processing:"].location != NSNotFound) {
        titleText = @"Processing...";
    } else if ([currentStatus rangeOfString:@"Download complete"].location != NSNotFound) {
        titleText = @"Download Complete";
    } else {
        titleText = @"Please Wait...";
    }
    
    // Draw title
    NSMutableParagraphStyle *centerStyle = [[NSMutableParagraphStyle alloc] init];
    [centerStyle setAlignment:NSCenterTextAlignment];
    
    // Use a smaller font for the title to save space
    NSFont *titleFont = [NSFont boldSystemFontOfSize:14.0];
    NSDictionary *titleAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
                              titleFont, NSFontAttributeName,
                              [NSColor colorWithCalibratedWhite:1.0 alpha:0.9], NSForegroundColorAttributeName,
                              centerStyle, NSParagraphStyleAttributeName,
                              nil];
    
    NSRect titleRect = NSMakeRect(
        overlayRect.origin.x + 10,
        overlayRect.origin.y + overlayRect.size.height - 30,
        overlayRect.size.width - 20,
        20
    );
    
    [titleText drawInRect:titleRect withAttributes:titleAttrs];
    
    // Draw detail status text (if available)
    NSString *statusText = @"";
    if (gProgressMessageLock) {
        [gProgressMessageLock lock];
        if (gProgressMessage) {
            statusText = [NSString stringWithString:gProgressMessage];
        }
        [gProgressMessageLock unlock];
    }
    
    if (!statusText || [statusText length] == 0) {
        statusText = @"Please wait...";
    }
    
    // Use a smaller font for status text
    NSFont *statusFont = [NSFont systemFontOfSize:12.0];
    NSDictionary *statusAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
                               statusFont, NSFontAttributeName,
                               [NSColor colorWithCalibratedWhite:1.0 alpha:0.9], NSForegroundColorAttributeName,
                               centerStyle, NSParagraphStyleAttributeName,
                               nil];
    
    NSRect statusRect = NSMakeRect(
        overlayRect.origin.x + 10,
        overlayRect.origin.y + overlayRect.size.height - 55, // Position below title
        overlayRect.size.width - 20,
        20
    );
    
    [statusText drawInRect:statusRect withAttributes:statusAttrs];
    [centerStyle release];
    
    // Draw progress bar
    CGFloat progressBarHeight = 16;
    CGFloat progressBarWidth = overlayRect.size.width - 40; // Leave margin on sides
    NSRect progressBarBgRect = NSMakeRect(
        overlayRect.origin.x + 20,
        overlayRect.origin.y + 20, // Position at bottom
        progressBarWidth,
        progressBarHeight
    );
    
    // Draw progress bar background
    NSBezierPath *progressBgPath = [NSBezierPath bezierPathWithRoundedRect:progressBarBgRect xRadius:4 yRadius:4];
    [[NSColor colorWithCalibratedWhite:0.2 alpha:1.0] set]; // Darker background
    [progressBgPath fill];
    
    // Determine progress value to show
    float progressValue = 0.0;
    if (self.isLoadingEpg) {
        progressValue = self.epgLoadingProgress;
    } else {
        progressValue = self.loadingProgress;
    }
    
    // Avoid NaN or negative values
    if (isnan(progressValue) || progressValue < 0.0) {
        progressValue = 0.0;
    }
    
    // Draw actual progress
    if (progressValue > 0.0) {
        NSRect progressFilledRect = NSMakeRect(
            progressBarBgRect.origin.x,
            progressBarBgRect.origin.y,
            progressBarBgRect.size.width * MIN(1.0, progressValue),
                                               progressBarBgRect.size.height
        );
        
        NSBezierPath *progressFilledPath = [NSBezierPath bezierPathWithRoundedRect:progressFilledRect xRadius:4 yRadius:4];
        
        // Use a bright color for the progress
        [[NSColor colorWithCalibratedRed:0.2 green:0.6 blue:1.0 alpha:1.0] set];
        [progressFilledPath fill];
    } else {
        // Draw animated indicator for indeterminate progress
        static float animationOffset = 0.0;
        animationOffset += 0.01;
        if (animationOffset > 1.0) {
            animationOffset = 0.0;
        }
        
        // Create a moving segment
        CGFloat segmentWidth = progressBarWidth * 0.25; // 25% of the total width
        NSRect progressFilledRect = NSMakeRect(
            progressBarBgRect.origin.x + ((progressBarWidth - segmentWidth) * animationOffset),
            progressBarBgRect.origin.y,
            segmentWidth,
                                               progressBarBgRect.size.height
        );
        
        NSBezierPath *progressFilledPath = [NSBezierPath bezierPathWithRoundedRect:progressFilledRect xRadius:4 yRadius:4];
        
        // Use a bright color for the progress
        [[NSColor colorWithCalibratedRed:0.2 green:0.6 blue:1.0 alpha:1.0] set];
        [progressFilledPath fill];
    }
    
    // Draw percentage text on progress bar
    NSString *percentText;
    
    // Get the current status text from global variable - use progressStatus to avoid redefining currentStatus
    NSString *progressStatus = @"";
    if (gProgressMessageLock) {
        [gProgressMessageLock lock];
        if (gProgressMessage) {
            progressStatus = [NSString stringWithString:gProgressMessage];
        }
        [gProgressMessageLock unlock];
    }
    
    if (progressValue > 0.0) {
        // Use the value from status text if it contains download information
        if ([progressStatus rangeOfString:@"Downloading:"].location != NSNotFound) {
            percentText = progressStatus;
        } else {
            percentText = [NSString stringWithFormat:@"%.0f%%", progressValue * 100.0];
        }
    } else {
        percentText = @"Processing...";
    }
    
    NSFont *percentFont = [NSFont boldSystemFontOfSize:12.0];
    NSDictionary *percentAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
                                percentFont, NSFontAttributeName,
                                [NSColor whiteColor], NSForegroundColorAttributeName,
                                nil];
    
    NSRect percentRect = NSMakeRect(
        progressBarBgRect.origin.x,
        progressBarBgRect.origin.y,
        progressBarBgRect.size.width,
        progressBarBgRect.size.height
    );
    
    // Center the percentage text
    NSMutableParagraphStyle *percentStyle = [[NSMutableParagraphStyle alloc] init];
    [percentStyle setAlignment:NSCenterTextAlignment];
    percentAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
                  percentFont, NSFontAttributeName,
                  [NSColor whiteColor], NSForegroundColorAttributeName,
                  percentStyle, NSParagraphStyleAttributeName,
                  nil];
    
    [percentText drawInRect:percentRect withAttributes:percentAttrs];
    [percentStyle release];
}

- (void)drawEpgPanel:(NSRect)rect {
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat epgPanelX = catWidth + groupWidth;
    CGFloat epgPanelWidth = self.bounds.size.width - epgPanelX;
    CGFloat rowHeight = 40;
    
    // Draw background
    NSRect epgRect = NSMakeRect(epgPanelX, 0, epgPanelWidth, self.bounds.size.height);
    [self.backgroundColor set];
    NSRectFill(epgRect);
    
    // Remove the header bar completely
    
    // Draw EPG data
    if (self.selectedChannelIndex < 0 || self.selectedChannelIndex >= [self.simpleChannelNames count]) {
        // No channel selected, just show a message
        NSString *message = @"Select a channel to view program guide";
        
        [self.textColor set];
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentCenter];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:16],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSRect messageRect = NSMakeRect(epgPanelX + 20, 
                                        self.bounds.size.height / 2 - 10, 
                                        epgPanelWidth - 40, 
                                        20);
        
        [message drawInRect:messageRect withAttributes:attrs];
        [style release];
    } else {
        // Show EPG data for selected channel
        NSString *channelName = [self.simpleChannelNames objectAtIndex:self.selectedChannelIndex];
        
        // Draw channel name
        [self.textColor set];
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentCenter];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:18],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: style
        };
        
        // Adjust position without the header
        NSRect channelRect = NSMakeRect(epgPanelX + 20, 
                                        self.bounds.size.height - rowHeight - 10, 
                                        epgPanelWidth - 40, 
                                        rowHeight);
        
        [channelName drawInRect:channelRect withAttributes:attrs];
        [style release];
        
        // TODO: Draw actual EPG data when available
    }
}

- (void)drawSettingsPanel:(NSRect)rect {
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat settingsPanelX = catWidth + groupWidth;
    CGFloat settingsPanelWidth = self.bounds.size.width - settingsPanelX;
    CGFloat rowHeight = 40;
    
    // Draw background
    NSRect settingsRect = NSMakeRect(settingsPanelX, 0, settingsPanelWidth, self.bounds.size.height);
    [self.backgroundColor set];
    NSRectFill(settingsRect);
    
    // Draw header
    NSRect headerRect = NSMakeRect(settingsPanelX, self.bounds.size.height - rowHeight, settingsPanelWidth, rowHeight);
    [self.groupColor set];
    NSRectFill(headerRect);
    
    [self.textColor set];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    // Get the selected settings group
    NSString *headerText = @"Settings";
    NSArray *settingsGroups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
    
    if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < [settingsGroups count]) {
        NSString *selectedGroup = [settingsGroups objectAtIndex:self.selectedGroupIndex];
        headerText = [NSString stringWithFormat:@"Settings - %@", selectedGroup];
    }
    
    [headerText drawInRect:headerRect withAttributes:attrs];
    
    // Only draw settings content if a settings group is selected
    if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < [settingsGroups count]) {
        NSString *selectedGroup = [settingsGroups objectAtIndex:self.selectedGroupIndex];
        
        if ([selectedGroup isEqualToString:@"Playlist"]) {
            // Draw Playlist settings
            [self drawPlaylistSettingsWithComponents:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"General"]) {
            // Draw General settings
            [self drawGeneralSettings:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"Subtitles"]) {
            // Draw Subtitle settings
            [self drawSubtitleSettings:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"Movie Info"]) {
            // Draw Movie Info settings
            [self drawMovieInfoSettings:rect x:settingsPanelX width:settingsPanelWidth];
        }
    } else {
        // No group selected, show a helper message
        NSDictionary *helpAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSRect helpRect = NSMakeRect(settingsPanelX + 20, 
                                    self.bounds.size.height / 2 - 10, 
                                    settingsPanelWidth - 40, 
                                    20);
        
        [@"Select a settings group from the left panel" drawInRect:helpRect withAttributes:helpAttrs];
    }
    
    [style release];
}

- (void)drawPlaylistSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 20;
    CGFloat fieldHeight = 30;
    CGFloat labelHeight = 20;
    CGFloat verticalSpacing = 10; // Add spacing between label and field
    CGFloat startY = self.bounds.size.height - 100;
    CGFloat fieldWidth = width - (padding * 2);
    
    // Draw a section title
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect titleRect = NSMakeRect(x + padding, startY, width - (padding * 2), 20);
    [@"Playlist Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    // Calculate vertical positions with proper spacing
    CGFloat m3uLabelY = startY - 40;
    CGFloat m3uFieldY = m3uLabelY - labelHeight - verticalSpacing;
    CGFloat epgLabelY = m3uFieldY - fieldHeight - verticalSpacing;
    CGFloat epgFieldY = epgLabelY - labelHeight - verticalSpacing;
    
    // Draw labels
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    // M3U URL label
    NSRect m3uLabelRect = NSMakeRect(x + padding, m3uLabelY, fieldWidth, labelHeight);
    [@"M3U URL:" drawInRect:m3uLabelRect withAttributes:labelAttrs];
    
    // EPG URL label
    NSRect epgLabelRect = NSMakeRect(x + padding, epgLabelY, fieldWidth, labelHeight);
    [@"EPG XML URL (auto-generated, click to copy):" drawInRect:epgLabelRect withAttributes:labelAttrs];
    
    // Create or update M3U text field
    NSRect m3uFieldRect = NSMakeRect(x + padding, m3uFieldY, fieldWidth, fieldHeight);
    if (!self.m3uTextField) {
        self.m3uTextField = [[VLCReusableTextField alloc] initWithFrame:m3uFieldRect identifier:@"m3u"];
        self.m3uTextField.textFieldDelegate = self;
        [self.m3uTextField setPlaceholderText:@"Enter a URL or click 'Load From URL' to download a playlist"];
        // Don't add to subview here - will be managed by updateUIComponentsVisibility
    } else {
        [self.m3uTextField setFrame:m3uFieldRect];
    }
    
    // Update M3U text field value only if not currently being edited
    if (!self.m3uTextField.isActive) {
        NSString *m3uUrl = self.m3uFilePath;
        if ([m3uUrl hasPrefix:@"http://"] || [m3uUrl hasPrefix:@"https://"]) {
            [self.m3uTextField setTextValue:m3uUrl];
        } else {
            [self.m3uTextField setTextValue:@""];
        }
    }
    
    // Create or update EPG clickable label
    NSRect epgFieldRect = NSMakeRect(x + padding, epgFieldY, fieldWidth, fieldHeight);
    if (!self.epgLabel) {
        self.epgLabel = [[VLCClickableLabel alloc] initWithFrame:epgFieldRect identifier:@"epg"];
        self.epgLabel.delegate = self;
        [self.epgLabel setPlaceholderText:@"EPG URL will be auto-generated from M3U URL"];
        // Don't add to subview here - will be managed by updateUIComponentsVisibility
    } else {
        [self.epgLabel setFrame:epgFieldRect];
    }
    
    // Update EPG label text
    NSString *epgUrl = self.epgUrl;
    if (epgUrl && [epgUrl length] > 0) {
        [self.epgLabel setText:epgUrl];
    } else {
        [self.epgLabel setText:@""];
    }
    
    // Store field rects for click handling (keep for compatibility)
    self.m3uFieldRect = m3uFieldRect;
    self.epgFieldRect = epgFieldRect;
    
    // Calculate button and help text positions based on new layout
    CGFloat buttonY = epgFieldY - fieldHeight - verticalSpacing * 2;
    
    // Continue with the rest of the method (EPG Time Offset dropdown, buttons, etc.)
    // Add EPG Time Offset dropdown between EPG field and buttons
    CGFloat offsetLabelY = epgFieldY - fieldHeight - verticalSpacing;
    CGFloat offsetDropdownY = offsetLabelY - labelHeight - verticalSpacing;
    
    // EPG Time Offset label
    NSRect offsetLabelRect = NSMakeRect(x + padding, offsetLabelY, fieldWidth, labelHeight);
    [@"EPG Time Offset:" drawInRect:offsetLabelRect withAttributes:labelAttrs];
    
    // EPG Time Offset dropdown using new dropdown manager
    CGFloat dropdownWidth = 150; // Smaller width for dropdown
    NSRect offsetDropdownRect = NSMakeRect(x + padding, offsetDropdownY, dropdownWidth, fieldHeight);
    
    // Store the dropdown rect for click handling
    self.epgTimeOffsetDropdownRect = offsetDropdownRect;
    
    // Draw dropdown background
    if (self.epgTimeOffsetDropdownActive) {
        [[NSColor colorWithCalibratedRed:0.2 green:0.3 blue:0.4 alpha:1.0] set];
    } else {
        [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0] set];
    }
    NSRectFill(offsetDropdownRect);
    
    // Draw dropdown border
    if (self.epgTimeOffsetDropdownActive) {
        [[NSColor blueColor] set];
    } else {
        [[NSColor grayColor] set];
    }
    NSFrameRect(offsetDropdownRect);
    
    // Draw current offset value
    NSString *offsetText = [NSString stringWithFormat:@"%+d hours", (int)self.epgTimeOffsetHours];
    NSRect offsetValueRect = NSMakeRect(offsetDropdownRect.origin.x + 10, 
                                       offsetDropdownRect.origin.y + 7, 
                                       offsetDropdownRect.size.width - 30, 
                                       offsetDropdownRect.size.height - 14);
    
    NSDictionary *offsetAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    };
    [offsetText drawInRect:offsetValueRect withAttributes:offsetAttrs];
    
    // Draw dropdown arrow
    NSRect arrowRect = NSMakeRect(offsetDropdownRect.origin.x + offsetDropdownRect.size.width - 20, 
                                 offsetDropdownRect.origin.y + 10, 
                                 10, 10);
    [[NSColor lightGrayColor] set];
    NSBezierPath *arrowPath = [NSBezierPath bezierPath];
    [arrowPath moveToPoint:NSMakePoint(arrowRect.origin.x, arrowRect.origin.y + arrowRect.size.height)];
    [arrowPath lineToPoint:NSMakePoint(arrowRect.origin.x + arrowRect.size.width/2, arrowRect.origin.y)];
    [arrowPath lineToPoint:NSMakePoint(arrowRect.origin.x + arrowRect.size.width, arrowRect.origin.y + arrowRect.size.height)];
    [arrowPath closePath];
    [arrowPath fill];
    
    // Update button Y position
    buttonY = offsetDropdownY - fieldHeight - verticalSpacing;
    
    // Draw buttons
    CGFloat buttonWidth = 120;
    CGFloat buttonHeight = 30;
    CGFloat buttonSpacing = 20;
    
    // Load From URL button
    NSRect loadButtonRect = NSMakeRect(x + padding, buttonY, buttonWidth, buttonHeight);
    self.loadButtonRect = loadButtonRect;
    
    [[NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.6 alpha:1.0] set];
    NSRectFill(loadButtonRect);
    [[NSColor whiteColor] set];
    NSFrameRect(loadButtonRect);
    
    NSRect loadButtonTextRect = NSMakeRect(loadButtonRect.origin.x + 5, 
                                          loadButtonRect.origin.y + 7, 
                                          loadButtonRect.size.width - 10, 
                                          loadButtonRect.size.height - 14);
    [@"Load From URL" drawInRect:loadButtonTextRect withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    }];
    
    // Update EPG button
    NSRect epgButtonRect = NSMakeRect(x + padding + buttonWidth + buttonSpacing, buttonY, buttonWidth, buttonHeight);
    self.epgButtonRect = epgButtonRect;
    
    [[NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.4 alpha:1.0] set];
    NSRectFill(epgButtonRect);
    [[NSColor whiteColor] set];
    NSFrameRect(epgButtonRect);
    
    NSRect epgButtonTextRect = NSMakeRect(epgButtonRect.origin.x + 5, 
                                         epgButtonRect.origin.y + 7, 
                                         epgButtonRect.size.width - 10, 
                                         epgButtonRect.size.height - 14);
    [@"Update EPG" drawInRect:epgButtonTextRect withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    }];
    
    [style release];
}

- (void)updateEpgButtonClicked {
    // Check if we have a valid EPG URL
    NSString *epgUrlToLoad = nil;
    
    // Priority 1: If there's a temp URL being edited, use that
    if (self.tempEpgUrl && [self.tempEpgUrl length] > 0) {
        epgUrlToLoad = self.tempEpgUrl;
    } 
    // Priority 2: If there's a saved epgUrl, use that
    else if (self.epgUrl && [self.epgUrl length] > 0) {
        epgUrlToLoad = self.epgUrl;
        // Also update the temp URL for display
        self.tempEpgUrl = [[NSString alloc] initWithString:self.epgUrl];
    }
    
    // Only load if we have a non-empty URL
    if (epgUrlToLoad && [epgUrlToLoad length] > 0) {
        // Make sure it has http:// prefix
        if (![epgUrlToLoad hasPrefix:@"http://"] && ![epgUrlToLoad hasPrefix:@"https://"]) {
            epgUrlToLoad = [@"http://" stringByAppendingString:epgUrlToLoad];
            self.tempEpgUrl = epgUrlToLoad;
        }
        
        // Set the EPG URL
        self.epgUrl = epgUrlToLoad;
        
        // Save settings to user defaults
        [self saveSettings];
        
        // Set loading state and start the progress timer
        self.isLoading = YES;
        self.isLoadingEpg = YES;
        [self startProgressRedrawTimer];
        [self setLoadingStatusText:@"Updating EPG data..."];
        [self setNeedsDisplay:YES];
        
        // Load EPG data immediately - force refresh from URL
        [self loadEpgData];
        
        // Deactivate text fields but keep the values
        self.m3uFieldActive = NO;
        self.epgFieldActive = NO;
    } else {
        // Show error for empty URL
        [self setLoadingStatusText:@"Error: Please enter an EPG URL"];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            [self stopProgressRedrawTimer];
            [self setNeedsDisplay:YES];
            
            // Clear error message after a delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    [gProgressMessage release];
                    gProgressMessage = nil;
                    [gProgressMessageLock unlock];
                }
                [self setNeedsDisplay:YES];
            });
        });
    }
}

- (void)drawGeneralSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 20;
    CGFloat startY = self.bounds.size.height - 100;
    
    // Draw a section title
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect titleRect = NSMakeRect(x + padding, startY, width - (padding * 2), 20);
    [@"General Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    // Additional general settings would go here
    
    [style release];
}

- (void)drawURLInputField:(NSRect)rect {
    // Draw semi-transparent background over the entire view
    [[[NSColor blackColor] colorWithAlphaComponent:0.7] set];
    NSRectFill(self.bounds);
    
    // Create a dialog box in the center
    CGFloat dialogWidth = 500;
    CGFloat dialogHeight = 150;
    NSRect dialogRect = NSMakeRect((self.bounds.size.width - dialogWidth) / 2,
                                  (self.bounds.size.height - dialogHeight) / 2,
                                  dialogWidth,
                                  dialogHeight);
    
    // Draw dialog background
    [[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:0.9] set];
    NSRectFill(dialogRect);
    
    // Draw border
    [[NSColor whiteColor] set];
    NSFrameRect(dialogRect);
    
    // Draw title
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    };
    
    NSRect titleRect = NSMakeRect(dialogRect.origin.x + 10,
                                 dialogRect.origin.y + dialogRect.size.height - 40,
                                 dialogRect.size.width - 20,
                                 30);
    
    [@"Enter URL" drawInRect:titleRect withAttributes:titleAttrs];
    
    // Draw text field
    NSRect textFieldRect = NSMakeRect(dialogRect.origin.x + 20,
                                     dialogRect.origin.y + dialogRect.size.height / 2 - 15,
                                     dialogRect.size.width - 40,
                                     30);
    
    [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0] set];
    NSRectFill(textFieldRect);
    [[NSColor whiteColor] set];
    NSFrameRect(textFieldRect);
    
    // Draw text
    NSDictionary *textAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    };
    
    NSRect valueRect = NSMakeRect(textFieldRect.origin.x + 5,
                                 textFieldRect.origin.y + 5,
                                 textFieldRect.size.width - 10,
                                 textFieldRect.size.height - 10);
    
    [self.inputUrlString drawInRect:valueRect withAttributes:textAttrs];
    
    // Draw helper text
    NSString *helperText = @"Press Enter to confirm, Esc to cancel";
    NSDictionary *helperAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor lightGrayColor],
        NSParagraphStyleAttributeName: style
    };
    
    NSRect helperRect = NSMakeRect(dialogRect.origin.x + 10,
                                  dialogRect.origin.y + 10,
                                  dialogRect.size.width - 20,
                                  20);
    
    [helperText drawInRect:helperRect withAttributes:helperAttrs];
    
    [style release];
}

#pragma mark - Mouse Handling

- (void)mouseDown:(NSEvent *)event {
    [self markUserInteraction];
    
    // Handle dropdown manager clicks first
    if ([self.dropdownManager handleMouseDown:event]) {
        // Dropdown manager handled the click
        return;
    }
    
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // If menu is hidden, only handle player controls - skip ALL menu processing
    if (!self.isChannelListVisible) {
        // Check if we have a player and the click is on player controls
        if (self.player) {
            BOOL handled = [self handlePlayerControlsClickAtPoint:point];
            if (handled) {
                return;
            }
            
            // Don't hide controls on any click - let them stay visible
            NSLog(@"Click outside controls - keeping controls visible");
        }
        // If no player or click not on controls, do nothing - menu is hidden
        return;
    }
    
    // Everything below this point is ONLY for when the menu is visible
    
    // Check if we're in one of the menus
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    
    if (point.x < catWidth) {
        // Category menu
        [self handleCategoryClick:point];
    } else if (point.x < catWidth + groupWidth) {
        // Group menu
        [self handleGroupClick:point];
    } else {
        // If in grid view and clicking in the grid area
        if (isGridViewActive) {
            [self handleGridViewClick:point];
        } else {
            // Normal channel list
            BOOL handled = [self handleClickAtPoint:point];
            if (handled) {
                return;
            }
        }
    }
}

// Handle clicks in grid view
- (void)handleGridViewClick:(NSPoint)point {
    NSInteger gridIndex = [self gridItemIndexAtPoint:point];
    if (gridIndex >= 0) {
        // Get the channel at this index
        NSArray *channels = [self getChannelsForCurrentGroup];
        if (channels && gridIndex < channels.count) {
            VLCChannel *channel = [channels objectAtIndex:gridIndex];
            if (channel) {
                // Set selected channel index
                self.selectedChannelIndex = gridIndex;
                
                // Play the channel
                [self playChannelAtIndex:gridIndex];
                
                // Trigger redraw
                [self setNeedsDisplay:YES];
            }
        }
    }
}

- (void)handleCategoryClick:(NSPoint)point {
    CGFloat rowHeight = 40;
    NSInteger index = (NSInteger)((self.bounds.size.height - point.y) / rowHeight);
    
    if (index >= 0 && index < [self.categories count]) {
        // Hide all controls before changing category
        [self hideControls];
        
        self.selectedCategoryIndex = index;
        self.selectedGroupIndex = -1; // Reset group selection
        self.selectedChannelIndex = -1; // Reset channel selection
        
        [self setNeedsDisplay:YES];
    }
}

- (void)handleGroupClick:(NSPoint)point {
    if (self.selectedCategoryIndex < 0 || self.selectedCategoryIndex >= [self.categories count]) {
        return;
    }
    
    CGFloat rowHeight = 40;
    // Calculate group index accounting for scroll position
    NSInteger index = (NSInteger)((self.bounds.size.height - point.y) / rowHeight + groupScrollPosition / rowHeight);
    
    NSArray *groups;
    NSString *categoryName = [self.categories objectAtIndex:self.selectedCategoryIndex];
    
    if ([categoryName isEqualToString:@"FAVORITES"]) {
        groups = [self safeGroupsForCategory:@"FAVORITES"];
    } else if ([categoryName isEqualToString:@"TV"]) {
        groups = [self safeTVGroups];
    } else if ([categoryName isEqualToString:@"MOVIES"]) {
        groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
    } else if ([categoryName isEqualToString:@"SERIES"]) {
        groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
    } else if ([categoryName isEqualToString:@"SETTINGS"]) {
        groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
    } else {
        return;
    }
    
    if (index >= 0 && index < [groups count]) {
        // Hide all controls before changing group
        [self hideControls];
        
        self.selectedGroupIndex = index;
        self.selectedChannelIndex = -1; // Reset channel selection
        
        // Make sure channels are prepared when a group is clicked
        [self prepareSimpleChannelLists];
        
        // Reset scroll positions
        channelScrollPosition = 0;
        
        // Reset grid loading queue to force reloading images for the new group
        if (isGridViewActive) {
            if (gridLoadingQueue) {
                [gridLoadingQueue removeAllObjects];
            }
        }
        
        // Log that a group was selected for debugging
        NSLog(@"Group selected: %@, with %lu channels", 
              [groups objectAtIndex:index],
              (unsigned long)[[self.channelsByGroup objectForKey:[groups objectAtIndex:index]] count]);
        
        [self setNeedsDisplay:YES];
    }
}

- (BOOL)handleClickAtPoint:(NSPoint)point {
    // Define exact boundaries for the channel list area
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    
    // Calculate channelListWidth dynamically to match the UI layout
    CGFloat programGuideWidth = 350; // Width reserved for program guide
    CGFloat channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
    
    // Calculate the exact start and end points of channel list
    CGFloat channelListStartX = catWidth + groupWidth;
    CGFloat channelListEndX = channelListStartX + channelListWidth;
    
    // Log click coordinates for debugging
    NSLog(@"Click at point: (%.1f, %.1f) - Channel list bounds: X from %.1f to %.1f", 
          point.x, point.y, channelListStartX, channelListEndX);
    
    // Check if we're in the settings panel FIRST (before movie info panel check)
    // because settings uses the same area as movie info panel
    if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
        NSLog(@"Click in settings panel - handling with settings handler");
        return [self handleSettingsClickAtPoint:point];
    }
    
    // Don't process clicks in the movie info panel area (only if NOT in settings)
    if (point.x >= channelListEndX) {
        // This is a click in the movie info panel, just update display
        NSLog(@"Click in movie info panel area - ignoring for channel selection");
        [self setNeedsDisplay:YES];
        return YES;  // Return YES to indicate we handled it (by ignoring it for channel selection)
    }
    
    // Don't process clicks in the categories or groups area
    if (point.x < channelListStartX) {
        NSLog(@"Click in categories/groups area - not handling as channel click");
        return NO;
    }
    
    // Use simpleChannelIndexAtPoint which now has improved boundary checking
    NSInteger channelIndex = [self simpleChannelIndexAtPoint:point];
    NSLog(@"Channel index at click point: %ld", (long)channelIndex);
    
    if (channelIndex >= 0) {
        NSLog(@"Valid channel clicked - playing channel %ld", (long)channelIndex);
        self.selectedChannelIndex = channelIndex;
        [self playChannelAtIndex:channelIndex];
        [self setNeedsDisplay:YES];
        return YES;
    }
    
    return NO;
}

- (BOOL)handleSettingsClickAtPoint:(NSPoint)point {
    // Check for clicks on settings UI elements
    
    // Get the selected settings group
    NSString *selectedGroup = nil;
    NSArray *settingsGroups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
    
    if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < [settingsGroups count]) {
        selectedGroup = [settingsGroups objectAtIndex:self.selectedGroupIndex];
    }
    
    // Check for clicks on Movie Info refresh button
    if (selectedGroup && [selectedGroup isEqualToString:@"Movie Info"] && 
        NSPointInRect(point, self.movieInfoRefreshButtonRect)) {
        
        // Prevent multiple clicks while already refreshing
        if (self.isRefreshingMovieInfo) {
            NSLog(@"Movie Info refresh already in progress - ignoring click");
            return YES;
        }
        
        NSLog(@"Movie Info refresh button clicked");
        [self startMovieInfoRefresh];
        return YES;
    }
    
    // If either text field is active, any click outside deactivates it
    if (self.m3uFieldActive || self.epgFieldActive) {
        // If clicked on another text field, switch active field
        if (NSPointInRect(point, self.m3uFieldRect) && !self.m3uFieldActive) {
            self.m3uFieldActive = YES;
            self.epgFieldActive = NO;
            
            // Initialize temp URL if needed
            if (!self.tempM3uUrl) {
                if ([self.m3uFilePath hasPrefix:@"http://"] || [self.m3uFilePath hasPrefix:@"https://"]) {
                    self.tempM3uUrl = [[NSString alloc] initWithString:self.m3uFilePath];
                } else {
                    self.tempM3uUrl = [[NSString alloc] initWithString:@""];
                }
            }
            
            // Calculate cursor position based on click position
            [self calculateCursorPositionForTextField:YES withPoint:point];
            
            [self setNeedsDisplay:YES];
            return YES;
        } 
        else if (NSPointInRect(point, self.epgFieldRect) && !self.epgFieldActive) {
            self.epgFieldActive = YES;
            self.m3uFieldActive = NO;
            
            // Initialize temp URL if needed
            if (!self.tempEpgUrl) {
                if (self.epgUrl && [self.epgUrl length] > 0) {
                    self.tempEpgUrl = [[NSString alloc] initWithString:self.epgUrl];
                } else {
                    self.tempEpgUrl = [[NSString alloc] initWithString:@""];
                }
            }
            
            // Calculate cursor position based on click position
            [self calculateCursorPositionForTextField:NO withPoint:point];
            
            [self setNeedsDisplay:YES];
            return YES;
        }
        else {
            // Click outside text fields, deactivate both
            self.m3uFieldActive = NO;
            self.epgFieldActive = NO;
            [self setNeedsDisplay:YES];
        }
    }
    
    // Check for clicks on the Load button
    if (NSPointInRect(point, self.loadButtonRect)) {
        [self loadFromUrlButtonClicked];
        return YES;
    }
    
    // Check for clicks on the EPG button
    if (NSPointInRect(point, self.epgButtonRect)) {
        [self updateEpgButtonClicked];
        return YES;
    }
    
    // Check for clicks on the M3U URL field (now handled by VLCReusableTextField)
    if (NSPointInRect(point, self.m3uFieldRect)) {
        // Activate the text field component
        if (self.m3uTextField) {
            [self.m3uTextField activateField];
        }
        return YES;
    }
    
    // Check for clicks on the EPG URL field (now handled by VLCClickableLabel)
    if (NSPointInRect(point, self.epgFieldRect)) {
        // The clickable label will handle the click and copy to clipboard
        // No need to do anything here as the label handles its own clicks
        return YES;
    }
    
    // Check for clicks on the EPG Time Offset dropdown
    if (NSPointInRect(point, self.epgTimeOffsetDropdownRect)) {
        NSLog(@"Click detected on EPG Time Offset dropdown at point: (%.1f, %.1f)", point.x, point.y);
        
        // Only handle dropdown clicks in the Playlist settings group
        if (selectedGroup && [selectedGroup isEqualToString:@"Playlist"]) {
            NSLog(@"In Playlist settings group, proceeding with dropdown handling");
            self.m3uFieldActive = NO;
            self.epgFieldActive = NO;
            
            // Use dropdown manager to handle the click
            VLCDropdown *offsetDropdown = [self.dropdownManager dropdownWithIdentifier:@"EPGTimeOffset"];
            if (offsetDropdown) {
                //NSLog(@"Found dropdown, isOpen: %@", offsetDropdown.isOpen ? @"YES" : @"NO");
                if (offsetDropdown.isOpen) {
                    // Dropdown is open - let dropdown manager handle the click
                    if ([self.dropdownManager handleMouseDown:[NSApp currentEvent]]) {
                        // Click was handled by dropdown manager
                        //NSLog(@"Click handled by dropdown manager");
                        return YES;
                    }
                } else {
                    // Open dropdown
                    //NSLog(@"Opening dropdown...");
                    [self.dropdownManager showDropdown:@"EPGTimeOffset"];
                    //NSLog(@"Dropdown opened, isOpen: %@", offsetDropdown.isOpen ? @"YES" : @"NO");
                    return YES;
                }
            } else {
                //NSLog(@"ERROR: Dropdown not found!");
            }
        } else {
            //NSLog(@"EPG dropdown click ignored - not in Playlist settings group. Current group: %@", selectedGroup ? selectedGroup : @"none");
        }
    }
    
    // Check for clicks on subtitle settings slider (only in Subtitles group)
    if (selectedGroup && [selectedGroup isEqualToString:@"Subtitles"]) {
        NSValue *sliderRectValue = objc_getAssociatedObject(self, "subtitleFontSizeSliderRect");
        if (sliderRectValue) {
            NSRect sliderRect = [sliderRectValue rectValue];
            if (NSPointInRect(point, sliderRect)) {
                // Calculate new font size based on click position
                // Remove interaction rect padding to get actual slider rect
                NSRect actualSliderRect = NSMakeRect(sliderRect.origin.x + 10, sliderRect.origin.y + 10, 
                                                    sliderRect.size.width - 20, sliderRect.size.height - 20);
                
                CGFloat clickProgress = (point.x - actualSliderRect.origin.x) / actualSliderRect.size.width;
                clickProgress = MAX(0.0, MIN(1.0, clickProgress)); // Clamp to 0-1
                
                // Convert to font scale factor (5-30 range, where 10 = 1.0x scale)
                NSInteger newFontSize = (NSInteger)(5 + (clickProgress * (30 - 5)));
                
                // Update settings and apply to player immediately
                VLCSubtitleSettings *settings = [VLCSubtitleSettings sharedInstance];
                settings.fontSize = newFontSize;
                [settings saveSettings];
                
                // Apply to VLC player in real-time
                if (self.player) {
                    [settings applyToPlayer:self.player];
                }
                
                NSLog(@"Subtitle font scale changed to: %ld (%.2fx)", (long)newFontSize, (float)newFontSize / 10.0f);
                
                // Redraw to show updated slider position
                [self setNeedsDisplay:YES];
                return YES;
            }
        }
    }
    
    return NO;     return NO;
}

// Helper method to calculate cursor position in text field when clicked
- (void)calculateCursorPositionForTextField:(BOOL)isM3uField withPoint:(NSPoint)point {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *fieldAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    };
    
    NSRect fieldRect = isM3uField ? self.m3uFieldRect : self.epgFieldRect;
    NSRect valueRect = NSMakeRect(fieldRect.origin.x + 10, 
                                 fieldRect.origin.y + 7, 
                                 fieldRect.size.width - 20, 
                                 fieldRect.size.height - 14);
    
    NSString *text = isM3uField ? (self.tempM3uUrl ? self.tempM3uUrl : @"") 
                                : (self.tempEpgUrl ? self.tempEpgUrl : @"");
    CGFloat clickX = point.x - valueRect.origin.x;
    NSInteger cursorPosition = 0;
    
    // Find the closest character position to the click
    for (NSInteger i = 1; i <= [text length]; i++) {
        NSString *textUpToI = [text substringToIndex:i];
        CGFloat width = [textUpToI sizeWithAttributes:fieldAttrs].width;
        
        if (width > clickX) {
            // If we're closer to the previous position, use that
            if (i > 0 && width - clickX > clickX - [textUpToI substringToIndex:i-1 > 0 ? i-1 : 0].length) {
                cursorPosition = i - 1;
            } else {
                cursorPosition = i;
            }
            break;
        }
        
        // If we reach the end, put cursor at the end
        if (i == [text length]) {
            cursorPosition = i;
        }
    }
    
    // Update the appropriate cursor position
    if (isM3uField) {
        self.m3uCursorPosition = cursorPosition;
    } else {
        self.epgCursorPosition = cursorPosition;
    }
    
    [style release];
}

- (void)loadFromUrlButtonClicked {
    // Set loading state and start the progress timer immediately
    self.isLoading = YES;
    [self startProgressRedrawTimer];
    [self setLoadingStatusText:@"Preparing to load channel list..."];
    [self setNeedsDisplay:YES];
    
    // Check the M3U URL first - either use temporary edit field or the saved path
    NSString *urlToLoad = nil;
    
    // Priority 1: If there's a temp URL being edited, use that
    if (self.tempM3uUrl && [self.tempM3uUrl length] > 0) {
        urlToLoad = self.tempM3uUrl;
    } 
    // Priority 2: If there's a saved m3uFilePath and it's a URL, use that
    else if (self.m3uFilePath && ([self.m3uFilePath hasPrefix:@"http://"] || [self.m3uFilePath hasPrefix:@"https://"])) {
        urlToLoad = self.m3uFilePath;
        // Also update the temp URL for display
        self.tempM3uUrl = [[NSString alloc] initWithString:self.m3uFilePath];
    }
    
    // Only load if we have a non-empty URL
    if (urlToLoad && [urlToLoad length] > 0) {
        // Check if the URL begins with http:// or https://
        if (![urlToLoad hasPrefix:@"http://"] && ![urlToLoad hasPrefix:@"https://"]) {
            urlToLoad = [@"http://" stringByAppendingString:urlToLoad];
            self.tempM3uUrl = urlToLoad;
        }
        
        // Basic URL validation - use a less strict pattern to allow query params
        NSString *urlPattern = @"^https?://[-A-Za-z0-9+&@#/%?=~_|!:,.;]*[-A-Za-z0-9+&@#/%=~_|]";
        NSPredicate *urlTest = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", urlPattern];
        BOOL isValid = [urlTest evaluateWithObject:urlToLoad];
        
        if (!isValid) {
            // Show an error message
            [self setLoadingStatusText:@"Error: Invalid URL format"];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                [self stopProgressRedrawTimer];
                [self setNeedsDisplay:YES];
                
                // Clear error message after a delay
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (gProgressMessageLock) {
                        [gProgressMessageLock lock];
                        [gProgressMessage release];
                        gProgressMessage = nil;
                        [gProgressMessageLock unlock];
                    }
                    [self setNeedsDisplay:YES];
                });
            });
            return;
        }
        
        // Set the M3U file path
        self.m3uFilePath = urlToLoad;
        
        // Similarly check EPG URL
        NSString *epgUrlToLoad = nil;
        
        // Priority 1: If there's a temp EPG URL being edited, use that
        if (self.tempEpgUrl && [self.tempEpgUrl length] > 0) {
            epgUrlToLoad = self.tempEpgUrl;
        } 
        // Priority 2: If there's a saved epgUrl and it's a URL, use that
        else if (self.epgUrl && [self.epgUrl length] > 0) {
            epgUrlToLoad = self.epgUrl;
            // Also update the temp URL for display
            self.tempEpgUrl = [[NSString alloc] initWithString:self.epgUrl];
        }
        // Priority 3: Try to auto-generate EPG URL
        else {
            NSString *generatedEpgUrl = [self generateEpgUrlFromM3uUrl:urlToLoad];
            if (generatedEpgUrl) {
                epgUrlToLoad = generatedEpgUrl;
                self.epgUrl = generatedEpgUrl;
                self.tempEpgUrl = generatedEpgUrl;
                NSLog(@"Auto-generated EPG URL: %@", self.epgUrl);
            }
        }
        
        // Save settings to user defaults
        [self saveSettings];
        
        // Save EPG URL but don't load EPG data yet - wait for channels to load first
        if (epgUrlToLoad && [epgUrlToLoad length] > 0) {
            // Make sure it has http:// prefix
            if (![epgUrlToLoad hasPrefix:@"http://"] && ![epgUrlToLoad hasPrefix:@"https://"]) {
                epgUrlToLoad = [@"http://" stringByAppendingString:epgUrlToLoad];
                self.tempEpgUrl = epgUrlToLoad;
            }
            
            self.epgUrl = epgUrlToLoad;
            // EPG data will be loaded after channels are loaded successfully
        }
        
        // Use the force reload method to always download fresh data
        if ([self respondsToSelector:@selector(forceReloadChannelsAndEpg)]) {
            NSLog(@"Force reloading channels and EPG data from settings menu");
            [self forceReloadChannelsAndEpg];
        } else {
            // Fallback to regular load if the force method isn't available
            [self loadChannelsFile];
        }
        
        // Deactivate text fields but keep the values
        self.m3uFieldActive = NO;
        self.epgFieldActive = NO;
    } else {
        // Show error for empty URL
        [self setLoadingStatusText:@"Error: Please enter a URL"];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            [self stopProgressRedrawTimer];
            [self setNeedsDisplay:YES];
            
            // Clear error message after a delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    [gProgressMessage release];
                    gProgressMessage = nil;
                    [gProgressMessageLock unlock];
                }
                [self setNeedsDisplay:YES];
            });
        });
    }
}

- (void)mouseMoved:(NSEvent *)event {
    // Handle dropdown manager mouse events first
    if ([self.dropdownManager handleMouseMoved:event]) {
        // Dropdown manager handled the event, redraw and return
        [self setNeedsDisplay:YES];
        return;
    }
    
    // Get the current mouse position
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // Calculate 10% of the window width for the activation zone
    CGFloat activationZone = self.bounds.size.width * 0.1;
    
    // Only show menu when mouse is in the activation zone (left edge)
    // If we're in a fade-out animation, moving the mouse shouldn't trigger showing the menu
    extern BOOL isFadingOut;
    extern NSTimeInterval lastFadeOutTime;
    
    // Check if we're in the cooldown period after a fade-out
    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    CGFloat fadeOutCooldown = 0.5; // Half-second cooldown to prevent immediate fade-in
    BOOL isInFadeOutCooldown = (currentTime - lastFadeOutTime < fadeOutCooldown);
    
    // Update mouse movement time and show cursor if hidden
    // Call markUserInteraction to properly update both interaction and mouse movement times
    // This ensures cursor hiding works correctly
    if (isCursorHidden) {
        [NSCursor unhide];
        isCursorHidden = NO;
        //NSLog(@"Cursor shown due to mouse movement in UI");
    }
    
    // Update the mouse movement time for cursor hiding logic
    lastMouseMoveTime = currentTime;
    
    // Ensure the cursor hiding timer is running
    // This is important for cursor hiding to work even when not in the activation zone
    if (!autoHideTimer) {
        [self scheduleInteractionCheck];
    }
    
    if (point.x <= activationZone && !isInFadeOutCooldown && !isFadingOut) {
        // Only when mouse is in left activation zone, mark interaction and show menu
        [self markUserInteractionWithMenuShow:YES];
    } else if (self.isChannelListVisible && !isFadingOut) {
        // If menu is visible but mouse is not in activation zone, keep the menu visible
        // but don't trigger showing if it's hidden
        lastInteractionTime = [NSDate timeIntervalSinceReferenceDate];
    }
    
    // Handle player controls visibility - call the new method from PlayerControls category
    // Only trigger showing player controls if menu is not visible
    if (!self.isChannelListVisible) {
        [self handleMouseMovedForPlayerControls];
        return; // Skip ALL menu processing when menu is hidden
    }
    
    // Everything below this point is ONLY for when the menu is visible
    
    // Check if we're currently scrolling (set in scrollWheel method)
    static BOOL isScrolling = NO;
    
    // If scrolling, don't process hover/fetching
    if (isScrolling) {
        return;
    }
    
    // Determine which region the mouse is in
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    
    // Calculate channelListWidth dynamically to match the UI layout
    CGFloat programGuideWidth = 350; // Width reserved for program guide
    CGFloat channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
    CGFloat movieInfoX = catWidth + groupWidth + channelListWidth;
    
    // Check if we're hovering over the movie info panel or the EPG panel
    BOOL wasHoveringMovieInfo = self.isHoveringMovieInfoPanel;
    BOOL isInMovieInfoArea = (self.selectedChannelIndex >= 0 && point.x >= movieInfoX);
    BOOL isInEpgPanelArea = self.showEpgPanel && (point.x >= catWidth + groupWidth);
    
    // Handle movie info panel hover
    if (isInMovieInfoArea || isInEpgPanelArea) {
        // We're hovering over the movie info panel or EPG panel
        self.isHoveringMovieInfoPanel = isInMovieInfoArea;
        
        // When entering either panel, restore the last valid hover state
        if ((!wasHoveringMovieInfo || isInEpgPanelArea) && isPersistingHoverState) {
            if (lastValidHoveredChannelIndex >= 0) {
                self.hoveredChannelIndex = lastValidHoveredChannelIndex;
            }
        }
        
        // Mark that we're retaining hover state for either panel
        isPersistingHoverState = YES;
    } else {
        self.isHoveringMovieInfoPanel = NO;
    }
    
    // If we just entered or left the movie info panel, redraw
    if (wasHoveringMovieInfo != self.isHoveringMovieInfoPanel) {
        [self setNeedsDisplay:YES];
    }
    
    // If hovering over movie info panel or EPG panel, don't process other hover states,
    // but keep the last valid hover state active
    // Both cases are handled by isPersistingHoverState flag
    if (self.isHoveringMovieInfoPanel || (self.showEpgPanel && isPersistingHoverState)) {
        // When in any detail panel, we're intentionally keeping the hover state
        isPersistingHoverState = YES;
        return;
    }
    
    // We're back in the main UI, so we can reset the persistence flag
    isPersistingHoverState = NO;
    
    // Store previous hover states
    NSInteger prevHoveredGroupIndex = self.hoveredGroupIndex;
    NSInteger prevHoveredChannelIndex = self.hoveredChannelIndex;
    
    // Only reset hover indices if we're in the channel list or another actionable area
    // This prevents clearing when moving to EPG panel
    if (point.x >= catWidth && point.x < catWidth + groupWidth + channelListWidth) {
    self.hoveredGroupIndex = -1;
    
    if (point.x >= catWidth && point.x < catWidth + groupWidth) {
        // Mouse is in the group list
        if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < [self.categories count]) {
            // Calculate group index with precision to avoid fractional errors
            CGFloat effectiveY = self.bounds.size.height - point.y;
            NSInteger itemsScrolled = (NSInteger)floor(groupScrollPosition / 40);
            NSInteger visibleIndex = (NSInteger)floor(effectiveY / 40);
            NSInteger groupIndex = visibleIndex + itemsScrolled;
            
            // Validate index against current group list
            NSArray *groups = nil;
            NSString *categoryName = [self.categories objectAtIndex:self.selectedCategoryIndex];
            
            if ([categoryName isEqualToString:@"FAVORITES"]) {
                groups = [self safeGroupsForCategory:@"FAVORITES"];
            } else if ([categoryName isEqualToString:@"TV"]) {
                groups = [self safeTVGroups];
            } else if ([categoryName isEqualToString:@"MOVIES"]) {
                groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
            } else if ([categoryName isEqualToString:@"SERIES"]) {
                groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
            } else if ([categoryName isEqualToString:@"SETTINGS"]) {
                groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
            }
            
            if (groups && groupIndex >= 0 && groupIndex < [groups count]) {
                self.hoveredGroupIndex = groupIndex;
            }
        }
    }
    } // Close the if-block opened earlier for restricting hover reset
    
    // Define exact channel list boundaries for clarity
    CGFloat channelListStartX = catWidth + groupWidth;
    CGFloat channelListEndX = channelListStartX + channelListWidth;
    
    // Check if we're in the channel list area
    BOOL isInChannelListArea = (point.x >= channelListStartX && point.x < channelListEndX);
   // NSLog(@"Mouse is %s channel list area", isInChannelListArea ? "in" : "outside");
    
    // If we're in grid view, handle channel hovering differently
    if (isGridViewActive && isInChannelListArea) {
        NSInteger gridIndex = [self gridItemIndexAtPoint:point];
        if (gridIndex != self.hoveredChannelIndex) {
            self.hoveredChannelIndex = gridIndex;
            [self setNeedsDisplay:YES];
            
            // If valid grid item is hovered, initiate movie info loading
            if (gridIndex >= 0) {
                NSArray *channels = [self getChannelsForCurrentGroup];
                if (channels && gridIndex < channels.count) {
                    VLCChannel *channel = [channels objectAtIndex:gridIndex];
                    // Queue async loading for this channel if needed
                    [self queueAsyncLoadForGridChannel:channel atIndex:gridIndex];
                }
            }
        }
    } else if (isInChannelListArea) {
        // In list view, use the regular channel hover logic - only when actually in the channel list area
    NSInteger channelIndex = [self simpleChannelIndexAtPoint:point];
        //NSLog(@"Channel index at point: %ld", (long)channelIndex);
    
    if (channelIndex != self.hoveredChannelIndex) {
        // Cancel any pending movie info timer if the user moved to a different channel
        if (movieInfoHoverTimer) {
            [movieInfoHoverTimer invalidate];
            movieInfoHoverTimer = nil;
            self.isPendingMovieInfoFetch = NO;
        }
        
        self.hoveredChannelIndex = channelIndex;
        
        // Add debug logging to check if channel hover is detected
        if (channelIndex >= 0) {
            //NSLog(@"Hovering over channel index: %ld", (long)channelIndex);
            
            // Get the actual channel object to show more info
            VLCChannel *channel = [self getChannelAtHoveredIndex];
            if (channel) {
                //NSLog(@"Hover channel: %@, logo: %@, category: %@", 
                //      channel.name, channel.logo ? channel.logo : @"No logo", 
                //      channel.category ? channel.category : @"No category");
                
                // If it's a movie channel, set up delayed fetch
                if ([channel.category isEqualToString:@"MOVIES"] && !channel.hasLoadedMovieInfo) {
                    // Store the current hovered channel index and timestamp
                    lastHoveredChannelIndex = channelIndex;
                    lastHoverTime = [NSDate timeIntervalSinceReferenceDate];
                    
                    // Set flag to indicate a pending fetch
                    self.isPendingMovieInfoFetch = YES;
                    
                    // Create a timer that will trigger after the hover delay (0.7 seconds)
                    if (movieInfoHoverTimer) {
                        [movieInfoHoverTimer invalidate];
                    }
                    
                    movieInfoHoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.7
                                                                          target:self
                                                                        selector:@selector(checkAndFetchMovieInfo:)
                                                                        userInfo:nil
                                                                         repeats:NO];
                }
            }
        } else {
            //NSLog(@"No channel hovered");
        }
        
        [self setNeedsDisplay:YES];
        }
    }
    
    // Only redraw if the hover state changed
    if (prevHoveredGroupIndex != self.hoveredGroupIndex || 
        prevHoveredChannelIndex != self.hoveredChannelIndex) {
        [self setNeedsDisplay:YES];
    }
    
    // Handle dropdown hover states
    [self handleDropdownHover:point];
}

// Timer callback to check if we should fetch movie info
- (void)checkAndFetchMovieInfo:(NSTimer *)timer {
    // Only proceed if still hovering on same channel
    if (self.hoveredChannelIndex == lastHoveredChannelIndex && self.isPendingMovieInfoFetch) {
        VLCChannel *channel = [self getChannelAtHoveredIndex];
        if (channel && [channel.category isEqualToString:@"MOVIES"] && !channel.hasLoadedMovieInfo) {
            NSLog(@"Hover timer elapsed - fetching movie info for: %@", channel.name);
            
            // Check if movie info is already cached in user defaults first
            BOOL loadedFromCache = [self loadMovieInfoFromCacheForChannel:channel];
            
            // Only fetch from network if not successfully loaded from cache
            if (!loadedFromCache) {
                // Add a property to track that fetching has started but not completed
                channel.hasStartedFetchingMovieInfo = YES;
                // Don't mark hasLoadedMovieInfo as true yet - wait until fetch completes
                
                // Use GCD to perform the fetch in background
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self fetchMovieInfoForChannelAsync:channel];
                });
            }
        }
    }
    
    // Reset the flag
    self.isPendingMovieInfoFetch = NO;
    movieInfoHoverTimer = nil;
}

// Add a method to save movie info to cache
- (void)saveMovieInfoToCache:(VLCChannel *)channel {
    if (!channel || !channel.name) return;
    
    // Get the movie info cache directory
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *movieInfoCacheDir = [appSupportDir stringByAppendingPathComponent:@"MovieInfo"];
    
    // Create the directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:movieInfoCacheDir]) {
        NSError *dirError = nil;
        [fileManager createDirectoryAtPath:movieInfoCacheDir 
                withIntermediateDirectories:YES 
                                 attributes:nil 
                                      error:&dirError];
        if (dirError) {
            NSLog(@"Error creating movie info cache directory: %@", dirError);
            return;
        } else {
            NSLog(@"Created movie info cache directory: %@", movieInfoCacheDir);
        }
    }
    
    // Create a safe filename from the channel name
    NSString *safeFilename = [self md5HashForString:channel.name];
    NSString *cacheFilePath = [movieInfoCacheDir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@.plist", safeFilename]];
    
    // Create dictionary with all movie properties
    NSMutableDictionary *movieInfo = [NSMutableDictionary dictionary];
    if (channel.movieId) [movieInfo setObject:channel.movieId forKey:@"movieId"];
    if (channel.movieDescription) [movieInfo setObject:channel.movieDescription forKey:@"description"];
    if (channel.movieGenre) [movieInfo setObject:channel.movieGenre forKey:@"genre"];
    if (channel.movieYear) [movieInfo setObject:channel.movieYear forKey:@"year"];
    if (channel.movieRating) [movieInfo setObject:channel.movieRating forKey:@"rating"];
    if (channel.movieDuration) [movieInfo setObject:channel.movieDuration forKey:@"duration"];
    if (channel.logo) [movieInfo setObject:channel.logo forKey:@"logo"];
    
    // Only save if we have some data
    if (movieInfo.count > 0) {
        // Add timestamp for cache invalidation
        [movieInfo setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"timestamp"];
        
        // Write to a temporary file first for atomicity
        NSString *tempPath = [cacheFilePath stringByAppendingString:@".temp"];
        BOOL success = [movieInfo writeToFile:tempPath atomically:YES];
        
        if (success) {
            NSError *moveError = nil;
            // Remove existing file if it exists
            if ([fileManager fileExistsAtPath:cacheFilePath]) {
                [fileManager removeItemAtPath:cacheFilePath error:nil];
            }
            // Move the temp file to the final location
            BOOL moveSuccess = [fileManager moveItemAtPath:tempPath toPath:cacheFilePath error:&moveError];
            
            if (moveSuccess) {
                NSLog(@"Saved movie info for '%@' to cache file: %@", channel.name, cacheFilePath);
            } else {
                NSLog(@"Failed to move temp file to cache path: %@, error: %@", cacheFilePath, moveError);
            }
        } else {
            NSLog(@"Failed to write movie info to temp file: %@", tempPath);
        }
    }
}

// Add a method to load movie info from cache
- (BOOL)loadMovieInfoFromCacheForChannel:(VLCChannel *)channel {
    if (!channel || !channel.name) return NO;
    
    // Get the movie info cache directory
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *movieInfoCacheDir = [appSupportDir stringByAppendingPathComponent:@"MovieInfo"];
    
    // Create a safe filename from the channel name
    NSString *safeFilename = [self md5HashForString:channel.name];
    NSString *cacheFilePath = [movieInfoCacheDir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@.plist", safeFilename]];
    
    // Check if cache file exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cacheFilePath]) {
        return NO;
    }
    
    // Load the plist file
    NSDictionary *movieInfo = [NSDictionary dictionaryWithContentsOfFile:cacheFilePath];
    
    // Check if we have cached data and it's not too old (30 days)
    if (movieInfo) {
        NSNumber *timestamp = [movieInfo objectForKey:@"timestamp"];
        if (timestamp) {
            NSTimeInterval cacheAge = [[NSDate date] timeIntervalSince1970] - [timestamp doubleValue];
            if (cacheAge < (30 * 24 * 60 * 60)) { // 30 days in seconds (extended from 7 days)
                // Load data from cache
                channel.movieId = [movieInfo objectForKey:@"movieId"];
                channel.movieDescription = [movieInfo objectForKey:@"description"];
                channel.movieGenre = [movieInfo objectForKey:@"genre"];
                channel.movieYear = [movieInfo objectForKey:@"year"];
                channel.movieRating = [movieInfo objectForKey:@"rating"];
                channel.movieDuration = [movieInfo objectForKey:@"duration"];
                
                // Mark as loaded
                channel.hasStartedFetchingMovieInfo = YES;
                channel.hasLoadedMovieInfo = YES;
                
                // Also try to load cached poster image from disk
                [self loadCachedPosterImageForChannel:channel];
                
                NSLog(@"Loaded movie info for '%@' from cache: %@", channel.name, cacheFilePath);
                return YES;
            }
        }
    }
    
    return NO;
}

// Add methods for persistent image caching
- (NSString *)cacheDirectoryPath {
    // Use Application Support instead of NSCachesDirectory for better persistence
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *cacheDir = [appSupportDir stringByAppendingPathComponent:@"Cache"];
    
    // Create directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cacheDir]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Error creating cache directory: %@", [error localizedDescription]);
        } else {
            NSLog(@"Created cache directory: %@", cacheDir);
        }
    }
    
    return cacheDir;
}

// Get the posters cache directory
- (NSString *)postersCacheDirectory {
    NSString *postersDir = [[self cacheDirectoryPath] stringByAppendingPathComponent:@"Posters"];
    
    // Create directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:postersDir]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:postersDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Error creating posters cache directory: %@", [error localizedDescription]);
        } else {
            NSLog(@"Created posters cache directory: %@", postersDir);
        }
    }
    
    return postersDir;
}

- (NSString *)cachePathForImageURL:(NSString *)url {
    if (!url || url.length == 0) return nil;
    
    // Create a unique filename based on the URL
    NSString *filename = [self md5HashForString:url];
    
    // Add the original extension if it exists
    NSString *extension = [url pathExtension];
    if (extension && extension.length > 0) {
        filename = [filename stringByAppendingFormat:@".%@", extension];
    } else {
        filename = [filename stringByAppendingString:@".png"];
    }
    
    return [[self postersCacheDirectory] stringByAppendingPathComponent:filename];
}

// Save poster image to disk cache
- (void)savePosterImageToDiskCache:(NSImage *)image forURL:(NSString *)url {
    if (!image || !url || url.length == 0) return;
    
    NSString *cachePath = [self cachePathForImageURL:url];
    if (cachePath) {
        // Make sure the directory exists
        NSString *directory = [cachePath stringByDeletingLastPathComponent];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if (![fileManager fileExistsAtPath:directory]) {
            NSError *dirError = nil;
            [fileManager createDirectoryAtPath:directory 
                    withIntermediateDirectories:YES 
                                     attributes:nil 
                                          error:&dirError];
            if (dirError) {
                NSLog(@"Error creating movie poster cache directory: %@", dirError);
                return;
            }
        }
        
        // Convert NSImage to data using TIFF representation
        NSData *imageData = [image TIFFRepresentation];
        if (!imageData) {
            NSLog(@"Failed to get TIFF representation for image");
            return;
        }
        
        NSBitmapImageRep *imageRep = [NSBitmapImageRep imageRepWithData:imageData];
        if (!imageRep) {
            NSLog(@"Failed to create bitmap rep from image data");
            return;
        }
        
        NSDictionary *imageProps = @{NSImageCompressionFactor: @0.8};
        NSData *pngData = [imageRep representationUsingType:NSPNGFileType properties:imageProps];
        
        if (pngData) {
            // Write to a temporary file first, then move to final location for atomicity
            NSString *tempPath = [cachePath stringByAppendingString:@".temp"];
            BOOL tempSuccess = [pngData writeToFile:tempPath atomically:YES];
            
            if (tempSuccess) {
                NSError *moveError = nil;
                // Remove existing file if it exists
                if ([fileManager fileExistsAtPath:cachePath]) {
                    [fileManager removeItemAtPath:cachePath error:nil];
                }
                // Move the temp file to the final location
                BOOL moveSuccess = [fileManager moveItemAtPath:tempPath toPath:cachePath error:&moveError];
                
                if (moveSuccess) {
                    NSLog(@"Successfully saved image to disk cache: %@", cachePath);
                } else {
                    NSLog(@"Failed to move temp file to cache path: %@, error: %@", cachePath, moveError);
                }
            } else {
                NSLog(@"Failed to write image to temp path: %@", tempPath);
            }
        } else {
            NSLog(@"Failed to create PNG data from image representation");
        }
    } else {
        NSLog(@"Invalid cache path for URL: %@", url);
    }
}

// Load poster image from disk cache
- (void)loadCachedPosterImageForChannel:(VLCChannel *)channel {
    if (!channel || !channel.logo || channel.logo.length == 0) return;
    
    NSString *cachePath = [self cachePathForImageURL:channel.logo];
    if (cachePath) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:cachePath]) {
            NSData *imageData = [NSData dataWithContentsOfFile:cachePath];
            if (imageData) {
                NSImage *cachedImage = [[NSImage alloc] initWithData:imageData];
                if (cachedImage) {
                    channel.cachedPosterImage = cachedImage;
                    //NSLog(@"Loaded poster image from disk cache for channel: %@", channel.name);
                    [cachedImage release];
                }
            }
        }
    }
}

// Improve fetchMovieInfoForChannelAsync to properly mark hasLoadedMovieInfo and save to cache
- (void)fetchMovieInfoForChannelAsync:(VLCChannel *)channel {
    // Call the actual movie info fetching logic from ChannelManagement category
    if (channel && [channel respondsToSelector:@selector(setHasLoadedMovieInfo:)]) {
        // Make sure we call the real implementation in the channel management category
        [self fetchMovieInfoForChannel:channel];
        
        // Save the info to cache after fetching
        [self saveMovieInfoToCache:channel];
        
        // Log that we're fetching
        NSLog(@"Asynchronously fetched movie info for: %@", channel.name);
    }
}

- (void)mouseExited:(NSEvent *)event {
    // Cancel any pending movie info timer
    if (movieInfoHoverTimer) {
        [movieInfoHoverTimer invalidate];
        movieInfoHoverTimer = nil;
        self.isPendingMovieInfoFetch = NO;
    }
    
    // Store the last valid hover states before clearing them
    if (self.hoveredChannelIndex >= 0) {
        lastValidHoveredChannelIndex = self.hoveredChannelIndex;
        isPersistingHoverState = YES;
        
        //NSLog(@"Stored last hovered channel index: %ld", (long)lastValidHoveredChannelIndex);
    }
    
    if (self.hoveredGroupIndex >= 0) {
        lastValidHoveredGroupIndex = self.hoveredGroupIndex;
        isPersistingHoverState = YES;
    }
    
    // Only clear the hover indices but don't redraw yet
    // This allows the movie info panel or EPG panel to continue showing content
    // based on the last hovered channel
    self.hoveredChannelIndex = -1;
    self.hoveredGroupIndex = -1;
    
    // Only redraw if we're not preserving hover state
    // We'll keep the movie info panel or EPG panel visible with the last selected channel
    if (!isPersistingHoverState) {
        [self setNeedsDisplay:YES];
    }
}

- (void)scrollWheel:(NSEvent *)event {
    [self markUserInteraction];
    
    // Check for dropdown scrolling first
    if (self.dropdownManager && [self.dropdownManager handleScrollWheel:event]) {
        return; // Dropdown handled the scroll, don't process other scrolling
    }
    
    // If menu is not visible, don't process any menu-related scrolling
    if (!self.isChannelListVisible) {
        return;
    }
    
    // Set a flag to indicate we're scrolling (to disable movie info fetching)
    static BOOL isScrolling = NO;
    isScrolling = YES;
    
    // Cancel any pending movie info requests when scrolling starts
    if (movieInfoHoverTimer) {
        [movieInfoHoverTimer invalidate];
        movieInfoHoverTimer = nil;
        self.isPendingMovieInfoFetch = NO;
    }
    
    // Make scroll bars visible when scrolling starts
    scrollBarAlpha = 1.0;
    
    // Reset fade timer if it exists
    if (scrollBarFadeTimer) {
        [scrollBarFadeTimer invalidate];
        scrollBarFadeTimer = nil;
    }
    
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // Determine which panel to scroll
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    
    // Calculate channelListWidth dynamically to match the UI layout
    CGFloat programGuideWidth = 350; // Width reserved for program guide
    CGFloat channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
    CGFloat movieInfoX = catWidth + groupWidth + channelListWidth;
    
    // Check for EPG panel scrolling - using programGuideWidth value that matches drawProgramGuideForHoveredChannel
    programGuideWidth = 400; // Match the width used in drawProgramGuideForHoveredChannel
    CGFloat guidePanelX = catWidth + groupWidth + channelListWidth;
    CGFloat guideEndX = self.bounds.size.width; // EPG panel extends to the right edge
    
    // Check if mouse is in program guide area
    BOOL isInEpgPanelArea = (point.x >= guidePanelX);
    
    // Handle EPG panel scrolling
    if (isInEpgPanelArea && (self.hoveredChannelIndex >= 0 || self.selectedChannelIndex >= 0)) {
        // Calculate scroll amount exactly like the channel list, using -deltaY * 12
        CGFloat scrollAmount = -[event deltaY] * 12;
        
        // Get the appropriate channel for calculations
        VLCChannel *channel = nil;
        if (self.hoveredChannelIndex >= 0) {
            channel = [self getChannelAtHoveredIndex];
        } 
        else if (self.selectedChannelIndex >= 0) {
            channel = [self getChannelAtIndex:self.selectedChannelIndex];
        }
        
        if (channel && channel.programs) {
            // Calculate program count and dimensions exactly as in the drawing code
            NSInteger programCount = [channel.programs count];
            CGFloat entryHeight = 65;
            CGFloat entrySpacing = 8;
            
            // Calculate total content height
            CGFloat totalContentHeight = (programCount * (entryHeight + entrySpacing));
            
            // Calculate visible height
            CGFloat visibleHeight = self.bounds.size.height;
            
            // Calculate maxScroll
            CGFloat maxScroll = MAX(0, totalContentHeight - visibleHeight);
            
            // Update scroll position
            self.epgScrollPosition += scrollAmount;
            self.epgScrollPosition = MAX(0, self.epgScrollPosition);
            self.epgScrollPosition = MIN(maxScroll, self.epgScrollPosition);
            
            // Mark that user has manually scrolled the EPG
            hasUserScrolledEpg = YES;
            
            //NSLog(@"EPG scrolling: position=%.1f, maxScroll=%.1f, programs=%ld, contentHeight=%.1f", 
            //      self.epgScrollPosition, maxScroll, (long)programCount, totalContentHeight);
        }
        
        // Redraw
        [self setNeedsDisplay:YES];
        
        // Return here to prevent other panels from scrolling
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            isScrolling = NO;
        });
        return;
    }
    
    // Check movie info area
    if (point.x >= movieInfoX) {
        // We're in the movie info panel area - only scroll this panel if it's active
        if (self.selectedChannelIndex >= 0) {
            NSLog(@"Scrolling movie info panel");
            // Calculate scroll amount (inverted for natural scroll direction)
            CGFloat scrollAmount = -[event deltaY] * 20; // Doubled scroll speed for better responsiveness
            
            // Get the selected channel
            VLCChannel *selectedChannel = [self getChannelAtIndex:self.selectedChannelIndex];
            if (selectedChannel) {
                // Adjust the movie info scroll position
                self.movieInfoScrollPosition += scrollAmount;
                self.movieInfoScrollPosition = MAX(0, self.movieInfoScrollPosition);
                
                            // Calculate maximum scroll position based on content
            // Set to a very high value to ensure sufficient scrolling range
            CGFloat contentHeight = 5000; // Significantly increased to guarantee scrollable content
            
            // Adjust based on actual content (description length, etc.)
            if (selectedChannel.movieDescription) {
                // Much more aggressive scaling factor to ensure scrolling works
                NSInteger descriptionLength = [selectedChannel.movieDescription length];
                // Using a much higher scaling factor - this is key to making scrolling work
                contentHeight = MAX(contentHeight, 1000 + (descriptionLength * 5.0)); // Very aggressive approximation
                
                NSLog(@"SCROLL EVENT: Movie description length: %ld, calculated content height: %.1f, current scroll pos: %.1f", 
                      (long)descriptionLength, contentHeight, self.movieInfoScrollPosition);
            }
            
            // Calculate max scroll with extra buffer
            CGFloat maxScroll = MAX(0, contentHeight - self.bounds.size.height);
            CGFloat oldScrollPos = self.movieInfoScrollPosition;
            self.movieInfoScrollPosition = MIN(maxScroll, self.movieInfoScrollPosition);
            
            NSLog(@"Movie info scrolling: oldPos=%.1f, newPos=%.1f, delta=%.1f, maxScroll=%.1f", 
                  oldScrollPos, self.movieInfoScrollPosition, 
                  self.movieInfoScrollPosition - oldScrollPos, maxScroll);
                
                // Redraw the movie info panel
                [self setNeedsDisplay:YES];
            }
            
            // Return here to prevent scrolling other panels when mouse is in movie info area
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                isScrolling = NO;
            });
            return;
        }
    }
    
    // Calculate scroll amount (inverted for natural scroll direction)
    CGFloat scrollAmount = -[event deltaY] * 10; // Negative sign inverts direction
    
    if (point.x < catWidth) {
        // Scroll categories
        categoryScrollPosition += scrollAmount;
        
        // Limit scrolling
        categoryScrollPosition = MAX(0, categoryScrollPosition);
        // Add extra space to ensure the last item is fully visible
        CGFloat maxScroll = MAX(0, ([self.categories count] * 40 + 40) - self.bounds.size.height);
        categoryScrollPosition = MIN(maxScroll, categoryScrollPosition);
    } else if (point.x < catWidth + groupWidth) {
        // Scroll groups
        if (self.selectedCategoryIndex < 0 || self.selectedCategoryIndex >= [self.categories count]) {
            return;
        }
        
        groupScrollPosition += scrollAmount;
        
        // Limit scrolling
        groupScrollPosition = MAX(0, groupScrollPosition);
        
        NSArray *groups;
        NSString *categoryName = [self.categories objectAtIndex:self.selectedCategoryIndex];
        
        if ([categoryName isEqualToString:@"FAVORITES"]) {
            groups = [self safeGroupsForCategory:@"FAVORITES"];
        } else if ([categoryName isEqualToString:@"TV"]) {
            groups = [self safeTVGroups];
        } else if ([categoryName isEqualToString:@"MOVIES"]) {
            groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
        } else if ([categoryName isEqualToString:@"SERIES"]) {
            groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
        } else if ([categoryName isEqualToString:@"SETTINGS"]) {
            groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
        } else {
            return;
        }
        
        // Add extra space to ensure the last item is fully visible
        CGFloat maxScroll = MAX(0, ([groups count] * 40 + 40) - self.bounds.size.height);
        groupScrollPosition = MIN(maxScroll, groupScrollPosition);
    } else {
        // Calculate channel list boundaries
        CGFloat channelListStartX = catWidth + groupWidth;
        CGFloat channelListEndX = channelListStartX + channelListWidth;
        
        // Only scroll the channel list if the mouse is actually in the channel list area
        BOOL isInChannelListArea = (point.x >= channelListStartX && point.x < channelListEndX);
        
        // Only scroll if in the channel list section
        if (isInChannelListArea) {
            // Scroll channels or grid
            if (isGridViewActive) {
                // For grid view, get the content dimensions
                NSArray *channels = [self getChannelsForCurrentGroup];
                if (channels && channels.count > 0) {
                    // Calculate grid metrics
                    CGFloat gridX = catWidth + groupWidth;
                    CGFloat gridWidth = self.bounds.size.width - gridX;
                    CGFloat itemPadding = 10;
                    CGFloat itemWidth = MIN(180, (gridWidth / 2) - (itemPadding * 2));
                    CGFloat itemHeight = itemWidth * 1.5;
                    CGFloat contentHeight = self.bounds.size.height - 40; // Account for header
                    
                    // Calculate how many columns and rows
                    NSInteger maxColumns = MAX(1, (NSInteger)((gridWidth - itemPadding) / (itemWidth + itemPadding)));
                    NSInteger numRows = (NSInteger)ceilf((float)channels.count / (float)maxColumns);
                    CGFloat totalGridHeight = numRows * (itemHeight + itemPadding) + itemPadding;
                    
                    // Add extra padding to ensure last row is fully visible 
                    totalGridHeight += itemHeight;
                    
                    // Update scroll position
                    channelScrollPosition += scrollAmount;
                    channelScrollPosition = MAX(0, channelScrollPosition);
                    CGFloat maxScroll = MAX(0, totalGridHeight - contentHeight);
                    channelScrollPosition = MIN(maxScroll, channelScrollPosition);
                }
            } else {
                // Scroll channel list
        channelScrollPosition += scrollAmount;
        
        // Limit scrolling
        channelScrollPosition = MAX(0, channelScrollPosition);
                // Add extra space to ensure the last item is fully visible
                CGFloat maxScroll = MAX(0, ([self.simpleChannelNames count] * 40 + 40) - (self.bounds.size.height));
        channelScrollPosition = MIN(maxScroll, channelScrollPosition);
    }
        } else {
            // We're not in the channel list area, but should still allow scrolling 
            // in the movie info panel if it's active and the mouse is in that area
            if (point.x >= movieInfoX && self.selectedChannelIndex >= 0) {
                NSLog(@"Handling scroll in movie info section");
                
                // Calculate scroll amount (inverted for natural scroll direction)
                CGFloat scrollAmount = -[event deltaY] * 20; // Doubled scroll speed for better responsiveness
                
                // Get the selected channel
                VLCChannel *selectedChannel = [self getChannelAtIndex:self.selectedChannelIndex];
                if (selectedChannel) {
                    // Adjust the movie info scroll position
                    self.movieInfoScrollPosition += scrollAmount;
                    self.movieInfoScrollPosition = MAX(0, self.movieInfoScrollPosition);
                    
                    // Calculate maximum scroll position based on content
                    // Set to a very high value to ensure sufficient scrolling range
                    CGFloat contentHeight = 5000; // Significantly increased to guarantee scrollable content
                    
                    // Adjust based on actual content (description length, etc.)
                    if (selectedChannel.movieDescription) {
                        // Much more aggressive scaling factor to ensure scrolling works
                        NSInteger descriptionLength = [selectedChannel.movieDescription length];
                        // Using a much higher scaling factor - this is key to making scrolling work
                        contentHeight = MAX(contentHeight, 1000 + (descriptionLength * 5.0)); // Very aggressive approximation
                        
                        NSLog(@"SCROLL EVENT: Movie description length: %ld, calculated content height: %.1f, current scroll pos: %.1f", 
                              (long)descriptionLength, contentHeight, self.movieInfoScrollPosition);
                    }
                    
                    // Calculate max scroll with extra buffer
                    CGFloat maxScroll = MAX(0, contentHeight - self.bounds.size.height);
                    CGFloat oldScrollPos = self.movieInfoScrollPosition;
                    self.movieInfoScrollPosition = MIN(maxScroll, self.movieInfoScrollPosition);
                    
                    NSLog(@"Movie info scrolling: oldPos=%.1f, newPos=%.1f, delta=%.1f, maxScroll=%.1f", 
                          oldScrollPos, self.movieInfoScrollPosition, 
                          self.movieInfoScrollPosition - oldScrollPos, maxScroll);
                    
                    // Trigger a redraw to update the scrolled content
    [self setNeedsDisplay:YES];
                }
            }
            // If not in channel list or movie info area, ignore scroll event
        }
    }
    
    [self setNeedsDisplay:YES];
    
    // Reset scrolling flag after a short delay (to prevent fetching immediately after scroll)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        isScrolling = NO;
        
        // Start fading out scroll bars after scrolling ends
        if (scrollBarFadeTimer) {
            [scrollBarFadeTimer invalidate];
        }
        scrollBarFadeTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                         target:self
                                                       selector:@selector(fadeScrollBars:)
                                                       userInfo:nil
                                                        repeats:YES];
    });
}

#pragma mark - Context Menu

- (void)rightMouseDown:(NSEvent *)event {
    [self markUserInteraction];
    
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // Check if right-click was in the EPG panel first
    if ([self handleEpgProgramRightClick:point withEvent:event]) {
        return;
    }
    
    // Check if right-click was in a text field
    if ((self.m3uFieldActive || NSPointInRect(point, self.m3uFieldRect)) ||
        (self.epgFieldActive || NSPointInRect(point, self.epgFieldRect))) {
        
        // Activate the appropriate field if not already active
        if (NSPointInRect(point, self.m3uFieldRect)) {
            self.m3uFieldActive = YES;
            self.epgFieldActive = NO;
        } else if (NSPointInRect(point, self.epgFieldRect)) {
            self.m3uFieldActive = NO;
            self.epgFieldActive = YES;
        }
        
        // Create a context menu
        NSMenu *menu = [[NSMenu alloc] init];
        
        // Add menu items
        NSMenuItem *pasteItem = [[NSMenuItem alloc] initWithTitle:@"Paste" 
                                                         action:@selector(paste:) 
                                                  keyEquivalent:@"v"];
        [pasteItem setKeyEquivalentModifierMask:NSCommandKeyMask];
        [pasteItem setTarget:self];
        [menu addItem:pasteItem];
        [pasteItem release];
        
        // Only add Copy if there's text to copy
        NSString *active = self.m3uFieldActive ? self.tempM3uUrl : self.tempEpgUrl;
        if (active && [active length] > 0) {
            NSMenuItem *copyItem = [[NSMenuItem alloc] initWithTitle:@"Copy" 
                                                             action:@selector(copy:) 
                                                      keyEquivalent:@"c"];
            [copyItem setKeyEquivalentModifierMask:NSCommandKeyMask];
            [copyItem setTarget:self];
            [menu addItem:copyItem];
            [copyItem release];
        }
        
        // Show the menu
        [NSMenu popUpContextMenu:menu withEvent:event forView:self];
        [menu release];
        
        [self setNeedsDisplay:YES];
        return;
    }
    
    // Check if right-click was on a group
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    if (point.x >= catWidth && point.x < catWidth + groupWidth) {
        // Calculate which group was clicked
        CGFloat effectiveY = self.bounds.size.height - point.y;
        NSInteger itemsScrolled = (NSInteger)floor(groupScrollPosition / 40);
        NSInteger visibleIndex = (NSInteger)floor(effectiveY / 40);
        NSInteger groupIndex = visibleIndex + itemsScrolled;
        
        // Get the appropriate groups based on current category
        NSArray *groups = nil;
        NSString *categoryName = nil;
        
        if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
            categoryName = [self.categories objectAtIndex:self.selectedCategoryIndex];
            
            if ([categoryName isEqualToString:@"FAVORITES"]) {
                groups = [self safeGroupsForCategory:@"FAVORITES"];
            } else if ([categoryName isEqualToString:@"TV"]) {
                groups = [self safeTVGroups];
            } else if ([categoryName isEqualToString:@"MOVIES"]) {
                groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
            } else if ([categoryName isEqualToString:@"SERIES"]) {
                groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
            }
        }
        
        // Check if the index is valid
        if (groups && groupIndex >= 0 && groupIndex < [groups count]) {
            NSString *groupName = [groups objectAtIndex:groupIndex];
            [self showContextMenuForGroup:groupName category:categoryName atPoint:point];
            return;
        }
    }
    
    // Check if right-click was on a channel
    NSInteger channelIndex = [self simpleChannelIndexAtPoint:point];
    if (channelIndex >= 0 && channelIndex < [self.simpleChannelNames count]) {
        // Find the actual channel object
        NSString *currentGroup = nil;
        NSArray *groups = nil;
        
        // Get current category and group
        NSString *currentCategory = nil;
        if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
            currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
        }
        
        // Get the appropriate groups based on category
        if ([currentCategory isEqualToString:@"FAVORITES"]) {
            groups = [self safeGroupsForCategory:@"FAVORITES"];
        } else if ([currentCategory isEqualToString:@"TV"]) {
            groups = [self safeTVGroups];
        } else if ([currentCategory isEqualToString:@"MOVIES"]) {
            groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
        } else if ([currentCategory isEqualToString:@"SERIES"]) {
            groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
        }
        
        // Get the current group from the selected index
        if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
            currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
        }
        
        // Get the channel
        VLCChannel *channel = nil;
        if (currentGroup) {
            NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
            if (channelsInGroup && channelIndex < channelsInGroup.count) {
                channel = [channelsInGroup objectAtIndex:channelIndex];
            }
        }
        
        // If we found the channel, show the context menu
        if (channel) {
            [self showContextMenuForChannel:channel atPoint:point];
        }
    }
}

- (void)showContextMenuForChannel:(VLCChannel *)channel atPoint:(NSPoint)point {
    NSMenu *menu = [[NSMenu alloc] init];
    
    // Play option
    NSMenuItem *playItem = [[NSMenuItem alloc] initWithTitle:@"Play Channel" 
                                                      action:@selector(playChannelFromMenu:) 
                                               keyEquivalent:@""];
    [playItem setTarget:self];
    [playItem setRepresentedObject:channel];
    [menu addItem:playItem];
    [playItem release];
    
    // Add separator
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Timeshift options if channel supports catchup
    if (channel.supportsCatchup) {
        // Add timeshift menu item
        NSString *timeshiftTitle = [NSString stringWithFormat:@"Timeshift (%ld days available)", (long)channel.catchupDays];
        NSMenuItem *timeshiftItem = [[NSMenuItem alloc] initWithTitle:timeshiftTitle 
                                                              action:@selector(showTimeshiftOptionsForChannel:) 
                                                       keyEquivalent:@""];
        [timeshiftItem setTarget:self];
        [timeshiftItem setRepresentedObject:channel];
        [menu addItem:timeshiftItem];
        [timeshiftItem release];
        
        // Add separator after timeshift options
        [menu addItem:[NSMenuItem separatorItem]];
    }
    
    // Channel info
    NSMenuItem *infoItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Channel: %@", channel.name] 
                                                     action:nil 
                                              keyEquivalent:@""];
    [infoItem setEnabled:NO]; // Disabled, just for display
    [menu addItem:infoItem];
    [infoItem release];
    
    // Add separator
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Favorites options
    BOOL isInFavorites = [self isChannelInFavorites:channel];
    
    if (isInFavorites) {
        NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove from Favorites" 
                                                           action:@selector(removeChannelFromFavoritesAction:) 
                                                    keyEquivalent:@""];
        [removeItem setTarget:self];
        [removeItem setRepresentedObject:channel];
        [menu addItem:removeItem];
        [removeItem release];
    } else {
        NSMenuItem *addItem = [[NSMenuItem alloc] initWithTitle:@"Add to Favorites" 
                                                        action:@selector(addChannelToFavoritesAction:) 
                                                 keyEquivalent:@""];
        [addItem setTarget:self];
        [addItem setRepresentedObject:channel];
        [menu addItem:addItem];
        [addItem release];
    }
    
    // Show menu
    [NSMenu popUpContextMenu:menu withEvent:[NSApp currentEvent] forView:self];
    [menu release];
}

- (void)showContextMenuForGroup:(NSString *)groupName category:(NSString *)category atPoint:(NSPoint)point {
    if (!groupName) return;
    
    NSMenu *menu = [[NSMenu alloc] init];
    
    // Add group title
    NSMenuItem *titleItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Group: %@", groupName] 
                                                      action:nil 
                                               keyEquivalent:@""];
    [titleItem setEnabled:NO]; // Disabled, just for display
    [menu addItem:titleItem];
    [titleItem release];
    
    // Add separator
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Get channels in this group
    NSArray *channelsInGroup = [self.channelsByGroup objectForKey:groupName];
    
    // Add "Play First Channel" option if the group has channels
    if (channelsInGroup && [channelsInGroup count] > 0) {
        NSMenuItem *playItem = [[NSMenuItem alloc] initWithTitle:@"Play First Channel" 
                                                         action:@selector(playFirstChannelInGroupAction:) 
                                                  keyEquivalent:@""];
        [playItem setTarget:self];
        [playItem setRepresentedObject:groupName];
        [menu addItem:playItem];
        [playItem release];
        
        // Add separator after play option
        [menu addItem:[NSMenuItem separatorItem]];
    }
    
    // Favorites options - only show if not already in FAVORITES category
    if (![category isEqualToString:@"FAVORITES"]) {
        // Check if group is already in favorites
        BOOL isInFavorites = [self isGroupInFavorites:groupName];
        
        if (isInFavorites) {
            NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove Group from Favorites" 
                                                               action:@selector(removeGroupFromFavoritesAction:) 
                                                        keyEquivalent:@""];
            [removeItem setTarget:self];
            [removeItem setRepresentedObject:groupName];
            [menu addItem:removeItem];
            [removeItem release];
        } else {
            NSMenuItem *addItem = [[NSMenuItem alloc] initWithTitle:@"Add Group to Favorites" 
                                                            action:@selector(addGroupToFavoritesAction:) 
                                                     keyEquivalent:@""];
            [addItem setTarget:self];
            [addItem setRepresentedObject:groupName];
            [menu addItem:addItem];
            [addItem release];
            
            // Add debugging log to verify menu item creation
            NSLog(@"Added 'Add to Favorites' menu item for group: %@", groupName);
        }
    } else {
        // If in favorites category, only show remove option
        NSMenuItem *removeItem = [[NSMenuItem alloc] initWithTitle:@"Remove Group from Favorites" 
                                                           action:@selector(removeGroupFromFavoritesAction:) 
                                                    keyEquivalent:@""];
        [removeItem setTarget:self];
        [removeItem setRepresentedObject:groupName];
        [menu addItem:removeItem];
        [removeItem release];
    }
    
    // Add channels count
    NSMenuItem *infoItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Channels: %ld", (long)[channelsInGroup count]] 
                                                     action:nil 
                                              keyEquivalent:@""];
    [infoItem setEnabled:NO]; // Disabled, just for display
    [menu addItem:infoItem];
    [infoItem release];
    
    // Show menu
    [NSMenu popUpContextMenu:menu withEvent:[NSApp currentEvent] forView:self];
    [menu release];
}

- (void)playChannelFromMenu:(NSMenuItem *)sender {
    VLCChannel *channel = [sender representedObject];
    if (channel) {
        [self playChannelWithUrl:channel.url];
    }
}

- (void)showTimeshiftOptionsForChannel:(NSMenuItem *)sender {
    VLCChannel *channel = [sender representedObject];
    if (!channel || !channel.supportsCatchup) {
        return;
    }
    
    NSMenu *timeshiftMenu = [[NSMenu alloc] init];
    
    // Add title
    NSMenuItem *titleItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Timeshift: %@", channel.name] 
                                                      action:nil 
                                               keyEquivalent:@""];
    [titleItem setEnabled:NO];
    [timeshiftMenu addItem:titleItem];
    [titleItem release];
    
    // Add separator
    [timeshiftMenu addItem:[NSMenuItem separatorItem]];
    
    // Add timeshift options for different time periods
    NSArray *timeshiftOptions = @[
        @{@"title": @"Go back 1 hour", @"hours": @1},
        @{@"title": @"Go back 2 hours", @"hours": @2},
        @{@"title": @"Go back 4 hours", @"hours": @4},
        @{@"title": @"Go back 8 hours", @"hours": @8},
        @{@"title": @"Go back 12 hours", @"hours": @12},
        @{@"title": @"Go back 24 hours", @"hours": @24}
    ];
    
    for (NSDictionary *option in timeshiftOptions) {
        NSInteger hours = [[option objectForKey:@"hours"] integerValue];
        NSString *title = [option objectForKey:@"title"];
        
        // Only show options that are within the catchup window
        if (hours <= (channel.catchupDays * 24)) {
            NSMenuItem *timeshiftOptionItem = [[NSMenuItem alloc] initWithTitle:title 
                                                                        action:@selector(playTimeshiftFromMenu:) 
                                                                 keyEquivalent:@""];
            [timeshiftOptionItem setTarget:self];
            
            // Store both channel and hours in a dictionary
            NSDictionary *timeshiftData = @{
                @"channel": channel,
                @"hours": @(hours)
            };
            [timeshiftOptionItem setRepresentedObject:timeshiftData];
            [timeshiftMenu addItem:timeshiftOptionItem];
            [timeshiftOptionItem release];
        }
    }
    
    // Show the submenu
    [NSMenu popUpContextMenu:timeshiftMenu withEvent:[NSApp currentEvent] forView:self];
    [timeshiftMenu release];
}

- (void)playTimeshiftFromMenu:(NSMenuItem *)sender {
    NSDictionary *timeshiftData = [sender representedObject];
    VLCChannel *channel = [timeshiftData objectForKey:@"channel"];
    NSNumber *hoursBack = [timeshiftData objectForKey:@"hours"];
    
    if (!channel || !hoursBack) {
        return;
    }
    
    // Calculate target time
    NSTimeInterval hoursBackInterval = [hoursBack doubleValue] * 3600; // Convert hours to seconds
    NSDate *targetTime = [[NSDate date] dateByAddingTimeInterval:-hoursBackInterval];
    
    // Generate timeshift URL
    NSString *timeshiftUrl = [self generateTimeshiftUrlForChannel:channel atTime:targetTime];
    
    if (timeshiftUrl) {
        NSLog(@"Playing timeshift for channel '%@' going back %@ hours", channel.name, hoursBack);
        
        // Stop current playback
        if (self.player) {
            [self saveCurrentPlaybackPosition];
            [self.player stop];
        }
        
        // Brief pause to allow VLC to reset
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Create media object with timeshift URL
            NSURL *url = [NSURL URLWithString:timeshiftUrl];
            VLCMedia *media = [VLCMedia mediaWithURL:url];
            
            // Set the media to the player
            [self.player setMedia:media];
            
            // Apply subtitle settings
            if ([VLCSubtitleSettings respondsToSelector:@selector(applyCurrentSettingsToPlayer:)]) {
                [VLCSubtitleSettings applyCurrentSettingsToPlayer:self.player];
            }
            
            // Start playing
            [self.player play];
            
            NSLog(@"Started timeshift playback for URL: %@", timeshiftUrl);
            
            // Force UI update
            [self setNeedsDisplay:YES];
        });
        
        // Save the timeshift URL as last played for resume functionality
        [self saveLastPlayedChannelUrl:timeshiftUrl];
        
        // Hide the channel list after starting playback
        [self hideChannelListWithFade];
    } else {
        NSLog(@"Failed to generate timeshift URL for channel: %@", channel.name);
    }
}

- (void)showEpgForChannel:(VLCChannel *)channel {
    // This method is no longer used as the EPG panel has been removed
    // We'll leave it in place to avoid breaking anything
    // but it won't do anything when called
}

- (void)playFirstChannelInGroupAction:(NSMenuItem *)sender {
    NSString *groupName = [sender representedObject];
    if (groupName) {
        // Get channels in this group
        NSArray *channelsInGroup = [self.channelsByGroup objectForKey:groupName];
        if (channelsInGroup && [channelsInGroup count] > 0) {
            // Get the first channel
            VLCChannel *firstChannel = [channelsInGroup objectAtIndex:0];
            if (firstChannel && firstChannel.url) {
                // Play the first channel
                [self playChannelWithUrl:firstChannel.url];
                
                // Select the group
                NSInteger categoryIndex = -1;
                NSArray *groups = nil;
                
                // Find which category contains this group
                for (NSInteger i = 0; i < [self.categories count]; i++) {
                    NSString *category = [self.categories objectAtIndex:i];
                    NSArray *categoryGroups = [self.groupsByCategory objectForKey:category];
                    
                    if ([categoryGroups containsObject:groupName]) {
                        categoryIndex = i;
                        groups = categoryGroups;
                        break;
                    }
                }
                
                // If found, update selection
                if (categoryIndex >= 0 && groups) {
                    // Hide all controls before changing category
                    [self hideControls];
                    
                    self.selectedCategoryIndex = categoryIndex;
                    self.selectedGroupIndex = [groups indexOfObject:groupName];
                    
                    // Select the first channel
                    [self prepareSimpleChannelLists];
                    if ([self.simpleChannelNames count] > 0) {
                        self.selectedChannelIndex = 0;
                    }
                    
                    [self setNeedsDisplay:YES];
                }
            }
        }
    }
}

- (void)keyDown:(NSEvent *)event {
    [self markUserInteraction];
    
    // Handle escape key to hide the menu
    unichar key = [[event charactersIgnoringModifiers] characterAtIndex:0];
    if (key == 27) { // ESC key
        // Hide the menu immediately
        if (self.isChannelListVisible) {
            // Hide all controls before hiding the menu
            [self hideControls];
            self.isChannelListVisible = NO;
            [self setNeedsDisplay:YES];
            return;
        }
        
        // If channel list is already hidden, hide player controls
        if (playerControlsVisible) {
            [self hidePlayerControls:nil];
            //NSLog(@"Player controls hidden");
            return;
        }
        
        // If both are hidden, log that there's nothing to hide
        NSLog(@"Nothing to hide");
    }
    
    // Handle 'g' key to toggle grid view
    if (key == 'g' || key == 'G') {
        // Only switch to grid view if we're in a valid category with a selected group
        if ([self getChannelsForCurrentGroup]) {
            isGridViewActive = YES;
            self.hoveredChannelIndex = -1; // Reset hover state
            
            // Reset the grid loading queue when switching to grid view
            [gridLoadingQueue removeAllObjects];
            
            // Reset scroll position
            channelScrollPosition = 0;
            
            [self setNeedsDisplay:YES];
        }
        return;
    }
    
    // Handle 'l' key to return to list view
    if (key == 'l' || key == 'L') {
        if (isGridViewActive) {
            isGridViewActive = NO;
            [self setNeedsDisplay:YES];
        }
        return;
    }
    
    // Handle Up/Down arrow keys for scrolling program guide when in program guide area
    if (key == NSUpArrowFunctionKey || key == NSDownArrowFunctionKey) {
        // Determine if we're in the program guide area
        NSPoint mouseLocation = [NSEvent mouseLocation];
        NSPoint point = [self convertPoint:[NSEvent mouseLocation] fromView:nil];
        
        // Calculate the boundaries for the program guide area
        CGFloat catWidth = 200;
        CGFloat groupWidth = 250;
        CGFloat programGuideWidth = 350;
        CGFloat channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
        CGFloat guidePanelX = catWidth + groupWidth + channelListWidth;
        CGFloat movieInfoX = guidePanelX + programGuideWidth;
        
        // Check if mouse is in the program guide area
        BOOL isInProgramGuideArea = (point.x >= guidePanelX && point.x < movieInfoX);
        
        if (isInProgramGuideArea) {
            // Use same scroll amount as mouse wheel for consistency - 35px per key press
            CGFloat scrollAmount = (key == NSUpArrowFunctionKey) ? -35 : 35;
            
            // Adjust epg scroll position
            self.epgScrollPosition += scrollAmount;
            self.epgScrollPosition = MAX(0, self.epgScrollPosition);
            
            // Mark that user has manually scrolled the EPG
            hasUserScrolledEpg = YES;
            
            // Get the appropriate channel for scrolling limits
            VLCChannel *channel = nil;
            if (self.hoveredChannelIndex >= 0) {
                channel = [self getChannelAtHoveredIndex];
            } else if (self.selectedChannelIndex >= 0) {
                channel = [self getChannelAtIndex:self.selectedChannelIndex];
            }
            
            // Calculate max scroll if we have a channel
            if (channel && channel.programs) {
                NSInteger programCount = [channel.programs count];
                CGFloat entryHeight = 65;
                CGFloat entrySpacing = 8;
                
                // Calculate total content height for all programs
                CGFloat totalContentHeight = (programCount * (entryHeight + entrySpacing));
                
                // Get visible height
                CGFloat visibleHeight = self.bounds.size.height;
                
                // Get backing scale factor for Retina displays
                NSWindow *window = [self window];
                
                
                // Calculate total content height with proper scaling
                totalContentHeight = (programCount * (entryHeight + entrySpacing));
                CGFloat scaledContentHeight = totalContentHeight;
                
                // Calculate maxScroll correctly
                CGFloat maxScroll = scaledContentHeight - visibleHeight;
                maxScroll = MAX(0, maxScroll);
                self.epgScrollPosition = MIN(maxScroll, self.epgScrollPosition);
            }
            
            // Redraw the display
            [self setNeedsDisplay:YES];
            return;
        }
    }
    
    // Handle editing in settings text fields
    if (self.m3uFieldActive || self.epgFieldActive) {
        unichar key = [[event charactersIgnoringModifiers] characterAtIndex:0];
        NSString *active = self.m3uFieldActive ? self.tempM3uUrl : self.tempEpgUrl;
        NSInteger currentCursorPosition = self.m3uFieldActive ? self.m3uCursorPosition : self.epgCursorPosition;
        NSInteger textLength = active ? [active length] : 0;
        
        // Handle keyboard shortcuts with command key
        if ([event modifierFlags] & NSCommandKeyMask) {
            // Handle copy/paste
            if (key == 'v') {
                // Paste from clipboard
                NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
                NSString *string = [pasteboard stringForType:NSPasteboardTypeString];
                
                if (string != nil) {
                    // Insert clipboard contents at cursor position
                    NSString *newValue;
                    if (active) {
                        NSString *beforeCursor = [active substringToIndex:MIN(currentCursorPosition, textLength)];
                        NSString *afterCursor = [active substringFromIndex:MIN(currentCursorPosition, textLength)];
                        newValue = [NSString stringWithFormat:@"%@%@%@", beforeCursor, string, afterCursor];
                    } else {
                        newValue = string;
                    }
                    
                    if (self.m3uFieldActive) {
                        self.tempM3uUrl = newValue;
                        
                        // Automatically update EPG URL as user types in M3U URL
                        // Only do this if the EPG URL is empty or hasn't been manually edited
                        if (!self.tempEpgUrl || [self.tempEpgUrl length] == 0) {
                            // Generate EPG URL using helper method
                            NSString *epgUrl = [self generateEpgUrlFromM3uUrl:newValue];
                            if (epgUrl) {
                                self.tempEpgUrl = epgUrl;
                            }
                        }
                    } else {
                        self.tempEpgUrl = newValue;
                    }
                    
                    // Move cursor position after the pasted text
                    currentCursorPosition += [string length];
                    if (self.m3uFieldActive) {
                        self.m3uCursorPosition = currentCursorPosition;
                    } else {
                        self.epgCursorPosition = currentCursorPosition;
                    }
                    
                    [self setNeedsDisplay:YES];
                }
                return;
            } else if (key == 'c') {
                // Copy to clipboard
                if (active && [active length] > 0) {
                    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
                    [pasteboard clearContents];
                    [pasteboard setString:active forType:NSPasteboardTypeString];
                }
                return;
            } else if (key == 'a') {
                // Select all (not currently implemented visually, but we could add this)
                return;
            }
        }
        
        // Handle navigation keys
        if (key == NSLeftArrowFunctionKey) {
            // Move cursor left if possible
            if (currentCursorPosition > 0) {
                currentCursorPosition--;
                if (self.m3uFieldActive) {
                    self.m3uCursorPosition = currentCursorPosition;
                } else {
                    self.epgCursorPosition = currentCursorPosition;
                }
                [self setNeedsDisplay:YES];
            }
            return;
        } else if (key == NSRightArrowFunctionKey) {
            // Move cursor right if possible
            if (currentCursorPosition < textLength) {
                currentCursorPosition++;
                if (self.m3uFieldActive) {
                    self.m3uCursorPosition = currentCursorPosition;
                } else {
                    self.epgCursorPosition = currentCursorPosition;
                }
                [self setNeedsDisplay:YES];
            }
            return;
        } else if (key == NSHomeFunctionKey) {
            // Move cursor to beginning
            if (self.m3uFieldActive) {
                self.m3uCursorPosition = 0;
            } else {
                self.epgCursorPosition = 0;
            }
            [self setNeedsDisplay:YES];
            return;
        } else if (key == NSEndFunctionKey) {
            // Move cursor to end
            if (self.m3uFieldActive) {
                self.m3uCursorPosition = textLength;
            } else {
                self.epgCursorPosition = textLength;
            }
            [self setNeedsDisplay:YES];
            return;
        }
        
        if (key == 13) { // Enter
            // Apply the current values
            if (self.m3uFieldActive) {
                self.m3uFieldActive = NO;
                
                // Generate EPG URL from M3U URL if we have a valid URL and EPG field is empty
                if (self.tempM3uUrl && [self.tempM3uUrl length] > 0) {
                    // Set the actual m3u file path 
                    NSString *urlToLoad = self.tempM3uUrl;
                    if (![urlToLoad hasPrefix:@"http://"] && ![urlToLoad hasPrefix:@"https://"]) {
                        urlToLoad = [@"http://" stringByAppendingString:urlToLoad];
                        self.tempM3uUrl = urlToLoad;
                    }
                    self.m3uFilePath = urlToLoad;
                
                    if (!self.tempEpgUrl || [self.tempEpgUrl length] == 0) {
                        // Generate EPG URL using helper method
                        NSString *epgUrl = [self generateEpgUrlFromM3uUrl:self.tempM3uUrl];
                        if (epgUrl) {
                            self.tempEpgUrl = epgUrl;
                            self.epgUrl = epgUrl;
                        }
                    }
                    
                    // Save settings
                    [self saveSettings];
                }
            } else if (self.epgFieldActive) {
                self.epgFieldActive = NO;
                
                // Update EPG URL if valid
                if (self.tempEpgUrl && [self.tempEpgUrl length] > 0) {
                    NSString *epgUrl = self.tempEpgUrl;
                    if (![epgUrl hasPrefix:@"http://"] && ![epgUrl hasPrefix:@"https://"]) {
                        epgUrl = [@"http://" stringByAppendingString:epgUrl];
                        self.tempEpgUrl = epgUrl;
                    }
                    self.epgUrl = epgUrl;
                    
                    // Save settings
                    [self saveSettings];
                    
                    // Load EPG data
                    [self loadEpgData];
                }
            }
            [self setNeedsDisplay:YES];
        } else if (key == 27) { // Escape
            // Cancel input
            self.m3uFieldActive = NO;
            self.epgFieldActive = NO;
            self.epgTimeOffsetDropdownActive = NO;
            [self setNeedsDisplay:YES];
        } else if (key == 126 || key == 125) { // Up arrow (126) or Down arrow (125)
            if (self.epgTimeOffsetDropdownActive) {
                // Navigate dropdown with arrow keys
                if (key == 126) { // Up arrow
                    if (self.epgTimeOffsetHours < 12) {
                        self.epgTimeOffsetHours++;
                        [self saveSettings];
                        NSLog(@"EPG time offset changed to: %+d hours", (int)self.epgTimeOffsetHours);
                    }
                } else { // Down arrow
                    if (self.epgTimeOffsetHours > -12) {
                        self.epgTimeOffsetHours--;
                        [self saveSettings];
                        NSLog(@"EPG time offset changed to: %+d hours", (int)self.epgTimeOffsetHours);
                    }
                }
                [self setNeedsDisplay:YES];
            }
        } else if (key == 9) { // Tab - switch between fields
            if (self.m3uFieldActive) {
                self.m3uFieldActive = NO;
                self.epgFieldActive = YES;
                self.epgTimeOffsetDropdownActive = NO;
                self.epgCursorPosition = self.tempEpgUrl ? [self.tempEpgUrl length] : 0;
            } else if (self.epgFieldActive) {
                self.epgFieldActive = NO;
                self.m3uFieldActive = NO;
                self.epgTimeOffsetDropdownActive = YES;
            } else if (self.epgTimeOffsetDropdownActive) {
                self.epgTimeOffsetDropdownActive = NO;
                self.m3uFieldActive = YES;
                self.m3uCursorPosition = self.tempM3uUrl ? [self.tempM3uUrl length] : 0;
            } else {
                self.m3uFieldActive = YES;
                self.epgFieldActive = NO;
                self.epgTimeOffsetDropdownActive = NO;
                self.m3uCursorPosition = self.tempM3uUrl ? [self.tempM3uUrl length] : 0;
            }
            [self setNeedsDisplay:YES];
        } else if (key == NSDeleteCharacter || key == NSBackspaceCharacter) {
            // Delete/backspace
            if (textLength > 0 && currentCursorPosition > 0) {
                // Delete character before cursor
                NSString *beforeCursor = [active substringToIndex:currentCursorPosition - 1];
                NSString *afterCursor = [active substringFromIndex:currentCursorPosition];
                NSString *newValue = [beforeCursor stringByAppendingString:afterCursor];
                
                if (self.m3uFieldActive) {
                    self.tempM3uUrl = newValue;
                    
                    // Automatically update EPG URL as user types in M3U URL
                    // Only do this if the EPG URL is empty or hasn't been manually edited
                    if (!self.tempEpgUrl || [self.tempEpgUrl length] == 0) {
                        // Generate EPG URL using helper method
                        NSString *epgUrl = [self generateEpgUrlFromM3uUrl:newValue];
                        if (epgUrl) {
                            self.tempEpgUrl = epgUrl;
                        }
                    }
                } else {
                    self.tempEpgUrl = newValue;
                }
                
                // Move cursor back
                currentCursorPosition--;
                if (self.m3uFieldActive) {
                    self.m3uCursorPosition = currentCursorPosition;
                } else {
                    self.epgCursorPosition = currentCursorPosition;
                }
                
                [self setNeedsDisplay:YES];
            }
        } else {
            // Regular character - insert at cursor position
            NSString *character = [event characters];
            if (character) {
                NSString *newValue;
                if (active) {
                    NSString *beforeCursor = [active substringToIndex:MIN(currentCursorPosition, textLength)];
                    NSString *afterCursor = [active substringFromIndex:MIN(currentCursorPosition, textLength)];
                    newValue = [NSString stringWithFormat:@"%@%@%@", beforeCursor, character, afterCursor];
                } else {
                    newValue = character;
                }
                
                if (self.m3uFieldActive) {
                    self.tempM3uUrl = newValue;
                    
                    // Automatically update EPG URL as user types in M3U URL
                    // Only do this if the EPG URL is empty or hasn't been manually edited
                    if (!self.tempEpgUrl || [self.tempEpgUrl length] == 0) {
                        // Generate EPG URL using helper method
                        NSString *epgUrl = [self generateEpgUrlFromM3uUrl:newValue];
                        if (epgUrl) {
                            self.tempEpgUrl = epgUrl;
                        }
                    }
                } else {
                    self.tempEpgUrl = newValue;
                }
                
                // Move cursor forward
                currentCursorPosition += [character length];
                if (self.m3uFieldActive) {
                    self.m3uCursorPosition = currentCursorPosition;
                } else {
                    self.epgCursorPosition = currentCursorPosition;
                }
                
                [self setNeedsDisplay:YES];
            }
        }
        
        return;
    }
    
    // Handle keyboard input for URL field
    if (self.isTextFieldActive) {
        unichar key = [[event charactersIgnoringModifiers] characterAtIndex:0];
        
        if (key == 13) { // Enter
            // Process the URL
            [self processUrlInput];
            
            // Hide the input field
            self.isTextFieldActive = NO;
            [self setNeedsDisplay:YES];
        } else if (key == 27) { // Escape
            // Cancel input
            self.isTextFieldActive = NO;
            [self setNeedsDisplay:YES];
        } else if (key == NSDeleteCharacter || key == NSBackspaceCharacter) {
            // Delete/backspace
            if ([self.inputUrlString length] > 0) {
                self.inputUrlString = [[self.inputUrlString substringToIndex:[self.inputUrlString length] - 1] retain];
                [self setNeedsDisplay:YES];
            }
        } else {
            // Append character
            NSString *character = [event characters];
            if (character) {
                self.inputUrlString = [[self.inputUrlString stringByAppendingString:character] retain];
                [self setNeedsDisplay:YES];
            }
        }
    } else {
        // Regular keyboard shortcuts
        unichar key = [[event charactersIgnoringModifiers] characterAtIndex:0];
        
        switch (key) {
            case 'f':
                // Toggle fullscreen
                break;
                
            case 's':
                // Show settings
                // Hide all controls before changing to settings
                [self hideControls];
                
                self.selectedCategoryIndex = CATEGORY_SETTINGS;
                self.selectedGroupIndex = 0; // General settings
                [self setNeedsDisplay:YES];
                break;
                
            case 'o':
                // Open URL
                self.isTextFieldActive = YES;
                self.inputUrlString = [@"" retain];
                [self setNeedsDisplay:YES];
                break;
                
            default:
                break;
        }
    }
}
- (void)mouseDragged:(NSEvent *)event {
    [self markUserInteraction];
    
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // Check if we're in the settings panel and Subtitles group
    if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
        NSString *selectedGroup = nil;
        NSArray *settingsGroups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
        
        if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < [settingsGroups count]) {
            selectedGroup = [settingsGroups objectAtIndex:self.selectedGroupIndex];
        }
        
        // Handle subtitle slider dragging (only in Subtitles group)
        if (selectedGroup && [selectedGroup isEqualToString:@"Subtitles"]) {
            NSValue *sliderRectValue = objc_getAssociatedObject(self, "subtitleFontSizeSliderRect");
            if (sliderRectValue) {
                NSRect sliderRect = [sliderRectValue rectValue];
                
                // Allow dragging even if mouse is slightly outside the slider for better UX
                NSRect expandedRect = NSMakeRect(sliderRect.origin.x - 20, sliderRect.origin.y - 20, 
                                               sliderRect.size.width + 40, sliderRect.size.height + 40);
                
                if (NSPointInRect(point, expandedRect)) {
                    // Calculate new font size based on drag position
                    NSRect actualSliderRect = NSMakeRect(sliderRect.origin.x + 10, sliderRect.origin.y + 10, 
                                                        sliderRect.size.width - 20, sliderRect.size.height - 20);
                    
                    CGFloat clickProgress = (point.x - actualSliderRect.origin.x) / actualSliderRect.size.width;
                    clickProgress = MAX(0.0, MIN(1.0, clickProgress)); // Clamp to 0-1
                    
                    // Convert to font scale factor (5-30 range, where 10 = 1.0x scale)
                    NSInteger newFontSize = (NSInteger)(5 + (clickProgress * (30 - 5)));
                    
                    // Update settings and apply to player immediately
                    VLCSubtitleSettings *settings = [VLCSubtitleSettings sharedInstance];
                    if (settings.fontSize != newFontSize) {
                        settings.fontSize = newFontSize;
                        [settings saveSettings];
                        
                        // Apply to VLC player in real-time
                        if (self.player) {
                            [settings applyToPlayer:self.player];
                        }
                        
                        NSLog(@"Subtitle font scale dragged to: %ld (%.2fx)", (long)newFontSize, (float)newFontSize / 10.0f);
                        
                        // Redraw to show updated slider position
                        [self setNeedsDisplay:YES];
                    }
                    return;
                }
            }
        }
    }
    
    // Call super for other drag handling
    [super mouseDragged:event];
}

- (void)processUrlInput {
    if ([self.inputUrlString length] > 0) {
        [self playChannelWithUrl:self.inputUrlString];
    }
}

// Add a method to handle paste from contextual menu
- (IBAction)paste:(id)sender {
    if (self.m3uFieldActive || self.epgFieldActive) {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSString *string = [pasteboard stringForType:NSPasteboardTypeString];
        
        if (string != nil) {
            NSString *active = self.m3uFieldActive ? self.tempM3uUrl : self.tempEpgUrl;
            NSString *newValue = active ? [active stringByAppendingString:string] : string;
            
            if (self.m3uFieldActive) {
                self.tempM3uUrl = newValue;
                
                // Automatically update EPG URL as user types in M3U URL
                // Only do this if the EPG URL is empty or hasn't been manually edited
                if (!self.tempEpgUrl || [self.tempEpgUrl length] == 0) {
                    // Generate EPG URL using helper method
                    NSString *epgUrl = [self generateEpgUrlFromM3uUrl:newValue];
                    if (epgUrl) {
                        self.tempEpgUrl = epgUrl;
                    }
                }
            } else {
                self.tempEpgUrl = newValue;
            }
            
            [self setNeedsDisplay:YES];
        }
    }
}

// Override to support cut/copy/paste menu items
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    SEL action = [menuItem action];
    
    if (action == @selector(paste:)) {
        return (self.m3uFieldActive || self.epgFieldActive) && 
               [[NSPasteboard generalPasteboard] availableTypeFromArray:@[NSPasteboardTypeString]] != nil;
    } else if (action == @selector(copy:) || action == @selector(cut:)) {
        NSString *active = self.m3uFieldActive ? self.tempM3uUrl : self.tempEpgUrl;
        return (self.m3uFieldActive || self.epgFieldActive) && active && [active length] > 0;
    }
    
    return [super validateMenuItem:menuItem];
}

// Add copy method
- (IBAction)copy:(id)sender {
    if (self.m3uFieldActive || self.epgFieldActive) {
        NSString *active = self.m3uFieldActive ? self.tempM3uUrl : self.tempEpgUrl;
        
        if (active && [active length] > 0) {
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            [pasteboard clearContents];
            [pasteboard setString:active forType:NSPasteboardTypeString];
        }
    }
}

// Override to become first responder
- (BOOL)acceptsFirstResponder {
    return YES;
}

// Override to maintain responder chain
- (BOOL)becomeFirstResponder {
    return YES;
}

// Override to properly handle key events
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Handle CMD+V paste
    if (([event modifierFlags] & NSCommandKeyMask) && 
        [[event charactersIgnoringModifiers] isEqualToString:@"v"] &&
        (self.m3uFieldActive || self.epgFieldActive)) {
        [self paste:self];
        return YES;
    }
    
    // Handle CMD+C copy
    if (([event modifierFlags] & NSCommandKeyMask) && 
        [[event charactersIgnoringModifiers] isEqualToString:@"c"] &&
        (self.m3uFieldActive || self.epgFieldActive)) {
        [self copy:self];
        return YES;
    }
    
    return [super performKeyEquivalent:event];
}

// Helper method to generate EPG URL from M3U URL following XMLTV standards
- (NSString *)generateEpgUrlFromM3uUrl:(NSString *)m3uUrl {
    if (!m3uUrl || [m3uUrl length] == 0) {
        return nil;
    }
    
    // Parse the M3U URL to extract components
    NSURL *url = [NSURL URLWithString:m3uUrl];
    if (!url) {
        // If not a valid URL, try adding http://
        if (![m3uUrl hasPrefix:@"http://"] && ![m3uUrl hasPrefix:@"https://"]) {
            url = [NSURL URLWithString:[@"http://" stringByAppendingString:m3uUrl]];
        }
        
        if (!url) {
            return nil; // Still not a valid URL
        }
    }
    
    // Extract the basic URL components
    NSString *host = [url host];
    if (!host) {
        return nil;
    }
    
    NSString *scheme = [url scheme] ?: @"http";
    NSNumber *port = [url port];
    NSString *portString = port ? [NSString stringWithFormat:@":%@", port] : @"";
    
    // Extract query parameters to find username and password
    NSString *username = @"";
    NSString *password = @"";
    
    // Parse the query string
    NSString *query = [url query];
    if (query) {
        NSArray *queryItems = [query componentsSeparatedByString:@"&"];
        for (NSString *item in queryItems) {
            NSArray *keyValue = [item componentsSeparatedByString:@"="];
            if (keyValue.count == 2) {
                NSString *key = keyValue[0];
                NSString *value = keyValue[1];
                
                if ([key isEqualToString:@"username"]) {
                    username = value;
                } else if ([key isEqualToString:@"password"]) {
                    password = value;
                }
            }
        }
    }
    
    // If no username/password in query, look for them in the URL path
    if (username.length == 0 || password.length == 0) {
        NSString *path = [url path];
        if (path) {
            // Look for patterns like /path/username/password/ or /path/username/password/stream
            NSArray *pathComponents = [path pathComponents];
            if (pathComponents.count >= 3) {
                // Try to identify username and password components
                // Typically, username and password are consecutive path components
                for (NSInteger i = 1; i < pathComponents.count - 1; i++) {
                    // Check for common username patterns (non-empty, not standard directories)
                    NSString *potentialUsername = pathComponents[i];
                    if (potentialUsername.length > 0 && 
                        ![potentialUsername isEqualToString:@"live"] &&
                        ![potentialUsername isEqualToString:@"iptv"] &&
                        ![potentialUsername isEqualToString:@"api"] &&
                        ![potentialUsername isEqualToString:@"xmltv"]) {
                        username = potentialUsername;
                        
                        // Next component might be password
                        if (i + 1 < pathComponents.count) {
                            NSString *potentialPassword = pathComponents[i+1];
                            if (potentialPassword.length > 0) {
                                password = potentialPassword;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Build the EPG URL in the standard format
    // http://SERVER_URL:PORT/xmltv.php?username=YOUR_USERNAME&password=YOUR_PASSWORD&type=m3u_plus&output=ts
    NSString *epgUrl = [NSString stringWithFormat:@"%@://%@%@/xmltv.php", scheme, host, portString];
    
    // Add query parameters if we have username/password
    if (username.length > 0 || password.length > 0) {
        epgUrl = [epgUrl stringByAppendingFormat:@"?username=%@&password=%@&type=m3u_plus&output=ts", 
                  username, password];
    }
    
    return epgUrl;
}

// Draw program guide panel for hovered channel
- (void)drawProgramGuideForHoveredChannel {
    // Get the hovered channel
    VLCChannel *channel = nil;
    NSString *currentGroup = nil;
    NSArray *groups = nil;
    
    // Get current category and group
    NSString *currentCategory = nil;
    if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
        currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
        
        // Get the appropriate groups based on category
        if ([currentCategory isEqualToString:@"FAVORITES"]) {
            groups = [self safeGroupsForCategory:@"FAVORITES"];
        } else if ([currentCategory isEqualToString:@"TV"]) {
            groups = [self safeTVGroups];
        } else if ([currentCategory isEqualToString:@"MOVIES"]) {
            groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
        } else if ([currentCategory isEqualToString:@"SERIES"]) {
            groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
        }
        
        // Get the current group
        if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
            currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
            
            // Get channels for this group
            NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
            if (channelsInGroup && self.hoveredChannelIndex < channelsInGroup.count) {
                channel = [channelsInGroup objectAtIndex:self.hoveredChannelIndex];
            }
        }
    }
    
    if (!channel) {
        return;
    }
    
    // Calculate position for the panel
    CGFloat rowHeight = 40;
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat channelListX = catWidth + groupWidth;
    
    // Calculate channel list width as specified in drawChannelList
    CGFloat programGuideWidth = 400; // Increased width for program guide
    CGFloat channelListWidth = self.bounds.size.width - channelListX - programGuideWidth;
    
    // Guide panel starts after channel list
    CGFloat guidePanelX = channelListX + channelListWidth;
    CGFloat guidePanelWidth = programGuideWidth;
    CGFloat guidePanelHeight = self.bounds.size.height;
    
    // Draw background with consistent semi-transparent black
    NSRect guidePanelRect = NSMakeRect(guidePanelX, 0, guidePanelWidth, guidePanelHeight);
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.7] set];
    NSRectFill(guidePanelRect);
    
    // Add a subtle left border to separate from channel list
    [[NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:1.0] set];
    NSRect borderRect = NSMakeRect(guidePanelX, 0, 1, guidePanelHeight);
    NSRectFill(borderRect);
    
    // No header with channel name
    NSMutableParagraphStyle *headerStyle = [[NSMutableParagraphStyle alloc] init];
    [headerStyle setAlignment:NSTextAlignmentCenter];
    [headerStyle release];
    
    // Check if this is a movie channel (category = MOVIES)
    BOOL isMovie = [channel.category isEqualToString:@"MOVIES"];
    
    // For movie channels, show movie info with enhanced styling
    if (isMovie) {
        // Make sure we load the movie information if not already loaded
        if (!channel.hasLoadedMovieInfo && !channel.hasStartedFetchingMovieInfo) {
            // Check cache first
            BOOL loadedFromCache = [self loadMovieInfoFromCacheForChannel:channel];
            
            // If not in cache, trigger an async load
            if (!loadedFromCache) {
                channel.hasStartedFetchingMovieInfo = YES;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self fetchMovieInfoForChannel:channel];
                    
                    // Save to cache
                    [self saveMovieInfoToCache:channel];
                    
                    // Trigger redraw on main thread
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self setNeedsDisplay:YES];
                    });
                });
            }
        }
        
        [self drawMovieInfoForChannel:channel inRect:guidePanelRect];
        return;
    }
    
    // Continue with regular program guide display for non-movies
    if (!channel.programs || [channel.programs count] == 0) {
        // No program data available
        NSRect messageRect = NSMakeRect(guidePanelX + 20, 
                                      guidePanelHeight / 2, 
                                      guidePanelWidth - 40, 
                                      20);
        
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentCenter];
        
        NSDictionary *msgAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor lightGrayColor],
            NSParagraphStyleAttributeName: style
        };
        
        [@"No program data available for this channel" drawInRect:messageRect withAttributes:msgAttrs];
        [style release];
        return;
    }
    
    // Sort programs by start time
    NSArray *sortedPrograms = [channel.programs sortedArrayUsingComparator:^NSComparisonResult(VLCProgram *a, VLCProgram *b) {
        return [a.startTime compare:b.startTime];
    }];
    
    // Get current time to highlight current program
    NSDate *now = [NSDate date];
    // Apply EPG time offset to current time for program detection
    // NOTE: Apply offset in opposite direction to correctly find current program
    NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600;
    NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
    NSInteger currentProgramIndex = -1;
    
    // Check if we're playing timeshift content and get the timeshift playing program
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    VLCProgram *timeshiftPlayingProgram = nil;
    NSInteger timeshiftProgramIndex = -1;
    
    if (isTimeshiftPlaying) {
        timeshiftPlayingProgram = [self getCurrentTimeshiftPlayingProgram];
        
        // Find the index of the timeshift playing program
        if (timeshiftPlayingProgram && channel.programs) {
            for (NSInteger i = 0; i < channel.programs.count; i++) {
                VLCProgram *program = [channel.programs objectAtIndex:i];
                if ([program.title isEqualToString:timeshiftPlayingProgram.title] &&
                    [program.startTime isEqualToDate:timeshiftPlayingProgram.startTime]) {
                    timeshiftProgramIndex = i;
                    break;
                }
            }
        }
    }
    
    // Find current live program index (for non-timeshift highlighting)
    if (channel.programs && channel.programs.count > 0) {
        for (NSInteger i = 0; i < channel.programs.count; i++) {
            VLCProgram *program = [channel.programs objectAtIndex:i];
            if (program.startTime && program.endTime) {
                if ([adjustedNow compare:program.startTime] != NSOrderedAscending && 
                    [adjustedNow compare:program.endTime] == NSOrderedAscending) {
                    currentProgramIndex = i;
                    break;
                }
            }
        }
    }
    
    // If we couldn't find current program, find the next program
    if (currentProgramIndex == -1) {
        for (NSInteger i = 0; i < [sortedPrograms count]; i++) {
            VLCProgram *program = [sortedPrograms objectAtIndex:i];
            if ([adjustedNow compare:program.startTime] == NSOrderedAscending) {
                currentProgramIndex = i;
                break;
            }
        }
    }
    
    // If we still couldn't find a program, use the first one
    if (currentProgramIndex == -1 && [sortedPrograms count] > 0) {
        currentProgramIndex = 0;
    }
    
    // Create paragraph styles for program items
    NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
    [titleStyle setAlignment:NSTextAlignmentLeft];
    
    NSMutableParagraphStyle *timeStyle = [[NSMutableParagraphStyle alloc] init];
    [timeStyle setAlignment:NSTextAlignmentRight];
    
    NSMutableParagraphStyle *descStyle = [[NSMutableParagraphStyle alloc] init];
    [descStyle setAlignment:NSTextAlignmentLeft];
    
    // Draw programs
    NSInteger visiblePrograms = 10; // Number of programs to show
    NSInteger startProgram = MAX(0, currentProgramIndex - 1); // Start 1 program before current
    
    // No program guide title or header
    NSMutableParagraphStyle *programListStyle = [[NSMutableParagraphStyle alloc] init];
    [programListStyle setAlignment:NSTextAlignmentLeft];
    
    [programListStyle release];
    
    // Draw actual program entries with modern card-based design
    CGFloat entryHeight = 65;
    CGFloat entrySpacing = 8;
    
    // Calculate content height with proper scaling
    CGFloat totalContentHeight = ([sortedPrograms count] * (entryHeight + entrySpacing));
    
    // Get visible height (guidePanelHeight is full height of the panel)
    CGFloat visibleContentHeight = guidePanelHeight;
    
    // Calculate correct maxScroll
    CGFloat maxScrollPosition = MAX(0, totalContentHeight - visibleContentHeight);
    
    // Auto-scroll to current program when EPG is first displayed for a new channel
    // Only auto-scroll if this is a new channel being hovered or user hasn't manually scrolled
    if (currentProgramIndex >= 0 && 
        (lastAutoScrolledChannelIndex != self.hoveredChannelIndex || !hasUserScrolledEpg)) {
        
        // Calculate the Y position of the current program
        CGFloat currentProgramY = guidePanelHeight - ((currentProgramIndex + 1) * (entryHeight + entrySpacing));
        
        // Calculate the center of the visible area
        CGFloat visibleCenter = visibleContentHeight / 2;
        
        // Calculate the desired scroll position to center the current program
        CGFloat desiredScrollPosition = -(currentProgramY - visibleCenter + (entryHeight / 2));
        
        // Ensure the desired position is within valid bounds
        desiredScrollPosition = MAX(0, desiredScrollPosition);
        desiredScrollPosition = MIN(maxScrollPosition, desiredScrollPosition);
        
        // Set the scroll position to center the current program
        self.epgScrollPosition = desiredScrollPosition;
        
        // Mark that we've auto-scrolled for this channel
        lastAutoScrolledChannelIndex = self.hoveredChannelIndex;
        hasUserScrolledEpg = NO; // Reset user scroll flag for new channel
    }
    
    // Ensure scroll position is within bounds
    self.epgScrollPosition = MIN(self.epgScrollPosition, maxScrollPosition);
    self.epgScrollPosition = MAX(0, self.epgScrollPosition);
    
    // Show all programs, not just a limited number
    NSInteger endProgram = [sortedPrograms count];
    
    // Create a clipping rect for the panel to ensure nothing draws outside
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];
    
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRect:guidePanelRect];
    [clipPath setClip];
    
    for (NSInteger i = 0; i < endProgram; i++) {
        VLCProgram *program = [sortedPrograms objectAtIndex:i];
        
        // Calculate Y position for this item
        // Items start from the top and go down, accounting for scroll position
        CGFloat itemY = guidePanelHeight - ((i + 1) * (entryHeight + entrySpacing)) + self.epgScrollPosition;
        
        // Skip items that are completely outside the visible area
        if (itemY + entryHeight < 0 || itemY > guidePanelHeight) {
            continue;
        }
        
        // Draw program entry as a card with rounded corners
        NSRect entryRect = NSMakeRect(
            guidePanelX + 10,
            itemY,
            guidePanelWidth - 20,
            entryHeight
        );
        
        // Draw card background with gradient
        NSColor *cardBgColor;
        NSColor *cardBorderColor;
        NSColor *timeColor;
        NSColor *titleColor;
        NSColor *descColor;
        CGFloat cornerRadius = 8.0;
        
        // Style based on current program, timeshift program, catch-up availability, or standard
        if (isTimeshiftPlaying && i == timeshiftProgramIndex) {
            // Timeshift playing program gets special orange/amber highlight
            cardBgColor = [NSColor colorWithCalibratedRed:0.35 green:0.25 blue:0.10 alpha:0.7];
            cardBorderColor = [NSColor colorWithCalibratedRed:1.0 green:0.6 blue:0.2 alpha:0.9];
            timeColor = [NSColor colorWithCalibratedRed:1.0 green:0.8 blue:0.4 alpha:1.0];
            titleColor = [NSColor whiteColor];
            descColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1.0];
        } else if (i == currentProgramIndex) {
            // Current live program gets highlight colors
            if (program.hasArchive) {
                // Current program with catch-up: blue highlight with green tint
                cardBgColor = [NSColor colorWithCalibratedRed:0.10 green:0.28 blue:0.35 alpha:0.6];
                cardBorderColor = [NSColor colorWithCalibratedRed:0.3 green:0.8 blue:0.6 alpha:0.8];
            } else {
                // Current program without catch-up: standard blue highlight
                cardBgColor = [NSColor colorWithCalibratedRed:0.12 green:0.24 blue:0.4 alpha:0.5];
                cardBorderColor = [NSColor colorWithCalibratedRed:0.4 green:0.7 blue:1.0 alpha:0.7];
            }
            timeColor = [NSColor colorWithCalibratedRed:0.6 green:0.9 blue:1.0 alpha:1.0];
            titleColor = [NSColor whiteColor];
            descColor = [NSColor colorWithCalibratedWhite:0.85 alpha:1.0];
        } else if (program.hasArchive) {
            // Non-current program with catch-up: light green tint
            cardBgColor = [NSColor colorWithCalibratedRed:0.12 green:0.22 blue:0.15 alpha:0.5];
            cardBorderColor = [NSColor colorWithCalibratedRed:0.2 green:0.5 blue:0.3 alpha:0.5];
            timeColor = [NSColor colorWithCalibratedRed:0.7 green:0.9 blue:0.7 alpha:1.0];
            titleColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0];
            descColor = [NSColor colorWithCalibratedRed:0.8 green:0.9 blue:0.8 alpha:1.0];
        } else {
            // Other programs get standard card colors with more transparency
            cardBgColor = [NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.15 alpha:0.5];
            cardBorderColor = [NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:0.4];
            timeColor = [NSColor colorWithCalibratedRed:0.7 green:0.7 blue:0.7 alpha:1.0];
            titleColor = [NSColor whiteColor];
            descColor = [NSColor colorWithCalibratedWhite:0.75 alpha:1.0];
        }
        
        // Draw rounded rectangle for card
        NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:entryRect xRadius:cornerRadius yRadius:cornerRadius];
        [cardBgColor set];
        [cardPath fill];
        
        // Draw a subtle border
        [cardPath setLineWidth:1.0];
        [cardBorderColor set];
        [cardPath stroke];
        
        // Create proper text styles
        NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
        [titleStyle setAlignment:NSTextAlignmentLeft];
        [titleStyle setLineBreakMode:NSLineBreakByTruncatingTail];
        
        NSMutableParagraphStyle *timeStyle = [[NSMutableParagraphStyle alloc] init];
        [timeStyle setAlignment:NSTextAlignmentLeft];
        
        NSMutableParagraphStyle *descStyle = [[NSMutableParagraphStyle alloc] init];
        [descStyle setAlignment:NSTextAlignmentLeft];
        [descStyle setLineBreakMode:NSLineBreakByTruncatingTail];
        
        // Calculate padding inside card
        CGFloat padding = 10;
        CGFloat timeHeight = 15;
        CGFloat titleHeight = 20;
        CGFloat descHeight = 18;
        
        // Draw time at the top
        NSString *timeString = [program formattedTimeRangeWithOffset:self.epgTimeOffsetHours];
        if (!timeString) {
            timeString = @"";
        }
        
        // Debug: Log what times we're showing in the program guide
        //if (i == currentProgramIndex) {
            //NSLog(@"PROGRAM GUIDE - Current program: %@ (%@ - %@)", program.title, program.startTime, program.endTime);
            //NSLog(@"PROGRAM GUIDE - Formatted time: %@", timeString);
            //NSLog(@"PROGRAM GUIDE - EPG offset: %ld hours", (long)self.epgTimeOffsetHours);
        //}
        
        NSDictionary *timeAttrs = @{
            NSFontAttributeName: [NSFont fontWithName:@"HelveticaNeue-Medium" size:12] ?: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: timeColor,
            NSParagraphStyleAttributeName: timeStyle
        };
        
        NSRect timeRect = NSMakeRect(
            entryRect.origin.x + padding,
            entryRect.origin.y + entryHeight - timeHeight - padding,
            entryRect.size.width - (padding * 2),
            timeHeight
        );
        
        [timeString drawInRect:timeRect withAttributes:timeAttrs];
        
        // Draw title below time
        NSString *titleString = program.title ? program.title : @"Unknown Program";
        
        NSDictionary *titleAttrs = @{
            NSFontAttributeName: [NSFont fontWithName:@"HelveticaNeue-Bold" size:14] ?: [NSFont boldSystemFontOfSize:14],
            NSForegroundColorAttributeName: titleColor,
            NSParagraphStyleAttributeName: titleStyle
        };
        
        NSRect titleRect = NSMakeRect(
            entryRect.origin.x + padding,
            timeRect.origin.y - titleHeight,
            entryRect.size.width - (padding * 2),
            titleHeight
        );
        
        [titleString drawInRect:titleRect withAttributes:titleAttrs];
        
        // Draw description at the bottom with extra padding from title
        NSString *descText = program.programDescription;
        if (!descText) descText = @"No description available";
        if ([descText length] > 110) { // Allow longer descriptions
            descText = [[descText substringToIndex:107] stringByAppendingString:@"..."];
        }
        
        // Make description text lighter and more readable
        NSColor *lighterDescColor = [NSColor colorWithCalibratedRed:0.9 green:0.9 blue:0.9 alpha:1.0];
        if (i == currentProgramIndex) {
            // For current program, use a brighter color
            lighterDescColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0];
        } else {
            // For other programs, use a lighter gray
            lighterDescColor = [NSColor colorWithCalibratedWhite:0.9 alpha:1.0];
        }
        
        NSDictionary *descAttrs = @{
            NSFontAttributeName: [NSFont fontWithName:@"HelveticaNeue-Light" size:12] ?: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: lighterDescColor,
            NSParagraphStyleAttributeName: descStyle
        };
        
        // Add 6 pixels of padding between title and description
        NSRect descRect = NSMakeRect(
            entryRect.origin.x + padding,
            entryRect.origin.y + padding,
            entryRect.size.width - (padding * 2),
            descHeight
        );
        
        // Move the description down by 6 pixels from its base position
        descRect.origin.y -= 6;
        
        [descText drawInRect:descRect withAttributes:descAttrs];
        
        // Draw catch-up indicator if available
        if (program.hasArchive) {
            // Draw a small "C" indicator in the top-right corner
            NSRect catchupIndicatorRect = NSMakeRect(
                entryRect.origin.x + entryRect.size.width - 25,
                entryRect.origin.y + entryHeight - 20,
                18,
                15
            );
            
            // Draw background circle for the indicator
            NSBezierPath *indicatorBg = [NSBezierPath bezierPathWithOvalInRect:catchupIndicatorRect];
            [[NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.3 alpha:0.8] set];
            [indicatorBg fill];
            
            // Draw "C" text
            NSDictionary *catchupTextAttrs = @{
                NSFontAttributeName: [NSFont fontWithName:@"HelveticaNeue-Bold" size:10] ?: [NSFont boldSystemFontOfSize:10],
                NSForegroundColorAttributeName: [NSColor whiteColor]
            };
            
            NSRect catchupTextRect = NSMakeRect(
                catchupIndicatorRect.origin.x + 5,
                catchupIndicatorRect.origin.y + 2,
                catchupIndicatorRect.size.width - 10,
                catchupIndicatorRect.size.height - 4
            );
            
            [@"C" drawInRect:catchupTextRect withAttributes:catchupTextAttrs];
        }
        
        // If it's the current program, draw a little indicator
        if (i == currentProgramIndex) {
            NSRect indicatorRect = NSMakeRect(
                entryRect.origin.x,
                entryRect.origin.y,
                4,
                entryHeight
            );
            
            if (program.hasArchive) {
                // Current program with catch-up: green-blue indicator
                [[NSColor colorWithCalibratedRed:0.3 green:0.8 blue:0.6 alpha:0.8] set];
            } else {
                // Current program without catch-up: standard blue indicator
                [[NSColor colorWithCalibratedRed:0.4 green:0.7 blue:1.0 alpha:0.7] set];
            }
            
            NSBezierPath *indicatorPath = [NSBezierPath bezierPathWithRoundedRect:indicatorRect 
                                                                          xRadius:2 
                                                                          yRadius:2];
            [indicatorPath fill];
        }
        
        // Highlight the timeshift playing program with reduced transparency
        if (isTimeshiftPlaying && timeshiftProgramIndex == i) {
            NSColor *highlightColor = [NSColor colorWithCalibratedRed:0.1 green:0.2 blue:0.3 alpha:0.3];
            [highlightColor set];
            NSRectFillUsingOperation(entryRect, NSCompositeSourceOver);
        }
        
        [titleStyle release];
        [timeStyle release];
        [descStyle release];
    }
    
    // Restore graphics state after clipping
    [context restoreGraphicsState];
    
    // Draw scroll indicator if content is scrollable
    if (totalContentHeight > visibleContentHeight) { // Show scroll indicator if content exceeds visible area
        // Use the standard drawScrollBar method to match channel list appearance
        NSRect contentRect = NSMakeRect(guidePanelX, 0, guidePanelWidth, guidePanelHeight);
        
        // Make scroll bar visible when there's content to scroll
        if (scrollBarAlpha < 1.0) {
            scrollBarAlpha = 1.0; // Ensure scrollbar is visible
        }
        
        [self drawScrollBar:contentRect contentHeight:totalContentHeight scrollPosition:self.epgScrollPosition];
    }
}

// Draw movie info when hovering over a movie item - fix the top bar and title overlapping
- (void)drawMovieInfoForChannel:(VLCChannel *)channel inRect:(NSRect)panelRect {
    if (!channel) return;
    
    // Debug logging
    NSLog(@"Drawing movie info for channel: %@", channel.name);
    NSLog(@"Channel logo URL: %@", channel.logo);
    NSLog(@"Channel category: %@", channel.category);
    
    // Define constant for the increased background height
    CGFloat backgroundHeightIncrease = 30.0;
    
    // Determine loading status based on channel properties
    BOOL isFetchingInfo = channel.hasStartedFetchingMovieInfo && !channel.hasLoadedMovieInfo;
    
    // Calculate base measurements based on available space
    CGFloat padding = MAX(10, panelRect.size.width * 0.02); // Responsive padding (min 10px)
    CGFloat rowHeight = 40;
    
    // Apply scroll position with debugging
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];
    
    // Use the standard panel rect for clipping to avoid issues
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRect:panelRect];
    [clipPath setClip];
    
    // Apply the scroll offset to the content - this is critical for scrolling to work
    CGFloat scrollOffset = self.movieInfoScrollPosition;
    NSLog(@"Applying scroll offset: %.1f to movie info panel", scrollOffset);
    
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:0 yBy:scrollOffset];
    [transform concat];
    
    // Get the available space (no header)
    CGFloat availableHeight = panelRect.size.height;
    CGFloat availableWidth = panelRect.size.width - (padding * 2);
    
    // Create paragraph styles
    NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
    [titleStyle setAlignment:NSTextAlignmentCenter];
    
    NSMutableParagraphStyle *descStyle = [[NSMutableParagraphStyle alloc] init];
    [descStyle setAlignment:NSTextAlignmentCenter];
    
    NSMutableParagraphStyle *metadataStyle = [[NSMutableParagraphStyle alloc] init];
    [metadataStyle setAlignment:NSTextAlignmentLeft];
    
    // Draw background - standard height to avoid clipping issues
    NSColor *bgColor = self.isHoveringMovieInfoPanel ? 
                      [self.backgroundColor colorWithAlphaComponent:1.0] : 
                      [self.backgroundColor colorWithAlphaComponent:0.9];
    [bgColor set];
    NSRectFill(panelRect);
    
    // If hovering, draw a subtle border to indicate this panel is active
    if (self.isHoveringMovieInfoPanel) {
        NSBezierPath *borderPath = [NSBezierPath bezierPathWithRect:NSInsetRect(panelRect, 1, 1)];
        [borderPath setLineWidth:2.0];
        [[NSColor colorWithWhite:0.5 alpha:0.3] set];
        [borderPath stroke];
    }
    
    // Declare the posterImage variable and initialize it to nil
    NSImage *posterImage = nil;
    
    // Draw movie title (height of 40px or 5% of available height, whichever is larger)
    CGFloat titleHeight = MAX(40, availableHeight * 0.05);
    NSRect titleRect = NSMakeRect(
        panelRect.origin.x + padding,
        panelRect.size.height - titleHeight,
        availableWidth,
        titleHeight
    );
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:18],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: titleStyle
    };
    
    // Use a more specific title to avoid duplication with the one already on screen
    [channel.name drawInRect:titleRect withAttributes:titleAttrs];
    
    // Check if we have a logo URL (movie poster)
    BOOL hasLogo = (channel.logo != nil && [channel.logo length] > 0);
    NSLog(@"Has logo: %@", hasLogo ? @"YES" : @"NO");
    
    // Calculate poster dimensions with proper aspect ratio - making it much larger
    CGFloat posterHeightPercent = 0.6; // Increase the poster height percentage significantly
    CGFloat posterHeight = MIN(MAX(270, availableHeight * posterHeightPercent), availableHeight * 0.8); // Make much taller
    CGFloat posterWidth = posterHeight * 0.75; // Standard movie poster aspect ratio
    
    // Add extra height to match user request
    CGFloat extraHeight = 40.0; // 40px taller as requested
    posterHeight += extraHeight;
    
    // Update width to maintain aspect ratio with the taller height
    posterWidth = posterHeight * 0.75; // Maintain proper movie poster aspect ratio
    
    // Calculate total content height needed to ensure proper spacing - with reduced space for other elements
    CGFloat metadataHeight = MIN(45, availableHeight * 0.1); // Reduced slightly for better fit
    CGFloat descriptionMinHeight = 80; // Reduced minimum height for description to accommodate larger poster
    
    // Calculate the vertical space needed for all elements except poster
    CGFloat nonPosterVerticalSpace = titleHeight + metadataHeight + descriptionMinHeight + (padding * 3);
    
    // Calculate space available for poster with equal top/bottom margins
    CGFloat posterAvailableSpace = availableHeight - nonPosterVerticalSpace;
    
    // Position poster higher on the screen
    CGFloat topMargin = MAX(padding, 15); // Use a smaller top margin to position poster higher
    
    // Position poster higher up after the title with reduced margin
    CGFloat posterY = panelRect.size.height - titleHeight - topMargin - posterHeight;
    
    // Center the poster horizontally with even left/right margins
    CGFloat horizontalMargin = (availableWidth - posterWidth) / 2;
    NSRect posterRect = NSMakeRect(
        panelRect.origin.x + padding + horizontalMargin,
        posterY,
        posterWidth,
        posterHeight
    );
    
    // Draw poster area with border - ensure it stays within actual visible bounds
    NSRect safeRect = NSIntersectionRect(posterRect, panelRect);
    [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:0.8] set];
    NSRectFill(safeRect);
    [[NSColor lightGrayColor] set];
    NSFrameRect(safeRect);
    
    // Draw movie poster if available, or a placeholder
    if (hasLogo) {
        // Try to load image from URL
        NSString *logoUrl = channel.logo;
        // Sometimes logos have spaces or special characters - encode the URL properly
        if (logoUrl && ![logoUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
            // First try to use the URL encoding API available in newer macOS versions
            if ([logoUrl respondsToSelector:@selector(stringByAddingPercentEncodingWithAllowedCharacters:)]) {
                // Create a character set specifically for URLs
                NSCharacterSet *urlAllowedSet = [NSCharacterSet URLQueryAllowedCharacterSet];
                logoUrl = [logoUrl stringByAddingPercentEncodingWithAllowedCharacters:urlAllowedSet];
            } else {
                // Fallback to older encoding method for backward compatibility
                logoUrl = [logoUrl stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            }
            NSLog(@"Encoded URL: %@", logoUrl);
        }
        
        NSLog(@"Attempting to load image from: %@", logoUrl);
        
        // Try to load the image from the URL
        if (logoUrl && [logoUrl length] > 0) {
            NSLog(@"Loading from web URL: %@", logoUrl);
            
            // Create a URL object
            NSURL *imageUrl = [NSURL URLWithString:logoUrl];
            if (!imageUrl) {
                NSLog(@"Invalid URL format: %@", logoUrl);
            } else {
                // If we already have a cached image from a previous load, use it
                if (channel.cachedPosterImage) {
                    posterImage = channel.cachedPosterImage;
                } 
                // If no cached image, start an asynchronous download
                else {
                    // Draw a placeholder indicating image is loading
                    NSString *loadingPlaceholder = @"Loading image...";
                    NSDictionary *placeholderAttrs = @{
                        NSFontAttributeName: [NSFont systemFontOfSize:12],
                        NSForegroundColorAttributeName: [NSColor lightGrayColor],
                        NSParagraphStyleAttributeName: titleStyle
                    };
                    
                    [loadingPlaceholder drawInRect:NSInsetRect(posterRect, 5, 5) withAttributes:placeholderAttrs];
                    
                    // Use our new asynchronous method to load the image
                    [self loadImageAsynchronously:logoUrl forChannel:channel];
                }
            }
        }
    }
    
    // If we have a posterImage (from cache), draw it
        if (posterImage) {
            // Calculate the image size to maintain aspect ratio
            NSSize imageSize = [posterImage size];
            CGFloat aspectRatio = imageSize.width / imageSize.height;
            
            // Create a slightly smaller rectangle inside the poster rect with reduced padding for larger image
            CGFloat imagePadding = 6.0; // Reduce padding to allow image to fill more of the frame
            NSRect innerRect = NSInsetRect(posterRect, imagePadding, imagePadding);
            
            NSRect drawRect;
            if (aspectRatio > (innerRect.size.width / innerRect.size.height)) {
                // Image is wider than the target area
                CGFloat scaledHeight = innerRect.size.width / aspectRatio;
                CGFloat yOffset = (innerRect.size.height - scaledHeight) / 2;
                drawRect = NSMakeRect(innerRect.origin.x, innerRect.origin.y + yOffset, innerRect.size.width, scaledHeight);
            } else {
                // Image is taller than the target area
                CGFloat scaledWidth = innerRect.size.height * aspectRatio;
                CGFloat xOffset = (innerRect.size.width - scaledWidth) / 2;
                drawRect = NSMakeRect(innerRect.origin.x + xOffset, innerRect.origin.y, scaledWidth, innerRect.size.height);
            }
            
            // Ensure image is drawn only within panelRect boundaries
            NSRect safeDrawRect = NSIntersectionRect(drawRect, panelRect);
            
            // Apply rounded corners to the movie poster - larger radius for the bigger poster
            [NSGraphicsContext saveGraphicsState];
            NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:innerRect xRadius:5 yRadius:5];
            [clipPath setClip];
            
            NSLog(@"Drawing image in rect: %@", NSStringFromRect(safeDrawRect));
            [posterImage drawInRect:safeDrawRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
            
            [NSGraphicsContext restoreGraphicsState];
    } else if (!channel.hasStartedFetchingMovieInfo || !hasLogo) {
        // Only draw background when there's no logo - using exact poster rect which is visible
        NSRect safeRect = posterRect;
        [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0] set];
        NSRectFill(safeRect);
        NSLog(@"Drawing placeholder background - no logo available");
    } else if (channel.hasStartedFetchingMovieInfo && !channel.hasLoadedMovieInfo) {
        // Show loading indicator when fetching image - using exact poster rect
        NSRect safeRect = posterRect;
        [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0] set];
        NSRectFill(safeRect);
        
        NSString *loadingText = @"Loading...";
        NSDictionary *loadingAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor lightGrayColor],
            NSParagraphStyleAttributeName: titleStyle
        };
        
        [loadingText drawInRect:NSInsetRect(safeRect, 5, 5) withAttributes:loadingAttrs];
    }
    
    // Calculate metadata position relative to poster bottom with reduced spacing
    CGFloat metadataY = posterRect.origin.y - metadataHeight - (padding * 0.7); // Use 70% of normal padding to fit everything
    
    // Calculate metadata area below poster with dynamic sizing
    NSRect metadataRect = NSMakeRect(
        panelRect.origin.x + padding,
        metadataY,
        availableWidth,
        metadataHeight
    );
    
    // Draw metadata if available - in a horizontal row below the poster
    if (channel.hasLoadedMovieInfo && 
        (channel.movieGenre || channel.movieYear || channel.movieRating || channel.movieDuration)) {
        
        // Draw a subtle background for metadata section - extend to full panel width
        NSRect fullMetadataRect = NSMakeRect(
            panelRect.origin.x,  // Start from panel edge, not with padding
            metadataRect.origin.y,
            panelRect.size.width,  // Use full panel width
            metadataRect.size.height
        );
        [[NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.15 alpha:0.7] set];
        NSRectFill(fullMetadataRect);
        
        // Create a horizontal layout for metadata
        CGFloat metadataItemWidth = availableWidth / 4; // 4 items: genre, year, rating, duration
        CGFloat metadataItemHeight = metadataRect.size.height;
        CGFloat yPos = metadataRect.origin.y + (metadataItemHeight / 2) - 10; // Center vertically
        
        NSMutableParagraphStyle *metadataHeaderStyle = [[NSMutableParagraphStyle alloc] init];
        [metadataHeaderStyle setAlignment:NSTextAlignmentCenter];
        
        NSMutableParagraphStyle *metadataValueStyle = [[NSMutableParagraphStyle alloc] init];
        [metadataValueStyle setAlignment:NSTextAlignmentCenter];
        
        NSDictionary *metadataHeaderAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: metadataHeaderStyle
        };
        
        NSDictionary *metadataValueAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor lightGrayColor],
            NSParagraphStyleAttributeName: metadataValueStyle
        };
        
        // Position for drawing metadata items
        CGFloat itemX = metadataRect.origin.x;
        
        // Draw Genre
        if (channel.movieGenre) {
            NSRect genreHeaderRect = NSMakeRect(itemX, yPos, metadataItemWidth, 16);
            NSRect genreValueRect = NSMakeRect(itemX, yPos - 20, metadataItemWidth, 16);
            
            [@"Genre" drawInRect:genreHeaderRect withAttributes:metadataHeaderAttrs];
            [channel.movieGenre drawInRect:genreValueRect withAttributes:metadataValueAttrs];
            
            itemX += metadataItemWidth;
        }
        
        // Draw Year
        if (channel.movieYear) {
            NSRect yearHeaderRect = NSMakeRect(itemX, yPos, metadataItemWidth, 16);
            NSRect yearValueRect = NSMakeRect(itemX, yPos - 20, metadataItemWidth, 16);
            
            [@"Year" drawInRect:yearHeaderRect withAttributes:metadataHeaderAttrs];
            // Ensure we have a string before drawing
            NSString *yearString = [channel.movieYear isKindOfClass:[NSString class]] ? 
                                  channel.movieYear : 
                                  [NSString stringWithFormat:@"%@", channel.movieYear];
            [yearString drawInRect:yearValueRect withAttributes:metadataValueAttrs];
            
            itemX += metadataItemWidth;
        }
        
        // Draw Rating
        if (channel.movieRating) {
            NSRect ratingHeaderRect = NSMakeRect(itemX, yPos, metadataItemWidth, 16);
            NSRect ratingValueRect = NSMakeRect(itemX, yPos - 20, metadataItemWidth, 16);
            
            [@"Rating" drawInRect:ratingHeaderRect withAttributes:metadataHeaderAttrs];
            // Ensure we have a string before drawing
            NSString *ratingString = [channel.movieRating isKindOfClass:[NSString class]] ? 
                                    channel.movieRating : 
                                    [NSString stringWithFormat:@"%@", channel.movieRating];
            [ratingString drawInRect:ratingValueRect withAttributes:metadataValueAttrs];
            
            itemX += metadataItemWidth;
        }
        
        // Draw Duration
        if (channel.movieDuration) {
            NSRect durationHeaderRect = NSMakeRect(itemX, yPos, metadataItemWidth, 16);
            NSRect durationValueRect = NSMakeRect(itemX, yPos - 20, metadataItemWidth, 16);
            
            // Format the duration nicely if it's in seconds
            NSString *formattedDuration = nil;
            
            // Handle case where movieDuration might be an NSNumber instead of NSString
            if ([channel.movieDuration isKindOfClass:[NSNumber class]]) {
                NSInteger seconds = [(NSNumber *)channel.movieDuration integerValue];
                NSInteger hours = seconds / 3600;
                NSInteger minutes = (seconds % 3600) / 60;
                
                if (hours > 0) {
                    formattedDuration = [NSString stringWithFormat:@"%ldh %ldm", (long)hours, (long)minutes];
                } else {
                    formattedDuration = [NSString stringWithFormat:@"%ldm", (long)minutes];
                }
            } else if ([channel.movieDuration isKindOfClass:[NSString class]]) {
                NSString *durationString = (NSString *)channel.movieDuration;
                if ([self isNumeric:durationString]) {
                    NSInteger seconds = [durationString integerValue];
                    NSInteger hours = seconds / 3600;
                    NSInteger minutes = (seconds % 3600) / 60;
                    
                    if (hours > 0) {
                        formattedDuration = [NSString stringWithFormat:@"%ldh %ldm", (long)hours, (long)minutes];
                    } else {
                        formattedDuration = [NSString stringWithFormat:@"%ldm", (long)minutes];
                    }
                } else {
                    formattedDuration = durationString;
                }
            } else {
                // Fallback for any other type
                formattedDuration = [NSString stringWithFormat:@"%@", channel.movieDuration];
            }
            
            [@"Duration" drawInRect:durationHeaderRect withAttributes:metadataHeaderAttrs];
            [formattedDuration drawInRect:durationValueRect withAttributes:metadataValueAttrs];
        }
        
        [metadataHeaderStyle release];
        [metadataValueStyle release];
    }
    
    // Calculate description area to fit in remaining space
    CGFloat descriptionY = metadataRect.origin.y - padding;
    CGFloat descriptionHeight = descriptionY - panelRect.origin.y - (2 * padding);
    
    // Ensure description has at least minimal height
    if (descriptionHeight < 50) {
        descriptionHeight = MIN(50, panelRect.origin.y + padding);
        descriptionY = panelRect.origin.y + descriptionHeight + padding;
    }
    
    NSRect descriptionRect = NSMakeRect(
        panelRect.origin.x + padding,
        panelRect.origin.y + padding,
        availableWidth,
        descriptionHeight
    );
    
    // Draw description in remaining space
    if (descriptionHeight >= 50) {
        // Draw description header
        NSDictionary *descHeaderAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:14],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: titleStyle
        };
        
        NSRect descHeaderRect = NSMakeRect(
            descriptionRect.origin.x,
            descriptionRect.origin.y + descriptionRect.size.height - 20,
            descriptionRect.size.width,
            20
        );
        
        [@"Description:" drawInRect:descHeaderRect withAttributes:descHeaderAttrs];
        
        // Draw movie description content
        NSMutableParagraphStyle *descContentStyle = [[NSMutableParagraphStyle alloc] init];
        [descContentStyle setAlignment:NSTextAlignmentLeft];
        
        NSDictionary *descContentAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor lightGrayColor],
            NSParagraphStyleAttributeName: descContentStyle
        };
        
        NSRect descContentRect = NSMakeRect(
            descriptionRect.origin.x,
            descriptionRect.origin.y,
            descriptionRect.size.width,
            descriptionRect.size.height - 25
        );
        
        // Get description text from API data if available, or fallback
        NSString *description = nil;
        
        // Try to get description from API data first
        if (channel.movieDescription) {
            // Make sure it's a string
            if ([channel.movieDescription isKindOfClass:[NSString class]]) {
                NSString *descStr = (NSString *)channel.movieDescription;
                if (descStr.length > 0) {
                    description = descStr;
                }
            } else {
                // If it's some other type, convert it to string
                description = [NSString stringWithFormat:@"%@", channel.movieDescription];
            }
        }
        // Then try to get from program data
        else if (channel.programs && channel.programs.count > 0) {
            VLCProgram *program = [channel.programs objectAtIndex:0];
            if (program.programDescription && program.programDescription.length > 0) {
                description = program.programDescription;
            }
        }
        
        // If no description was found, create a placeholder based on fetch status
        if (!description || description.length == 0) {
            if (isFetchingInfo) {
                description = @"Loading movie information...\n\nPlease wait while we fetch movie details.";
            } else if (channel.hasLoadedMovieInfo) {
                description = @"No description available for this movie.\n\nClick to play this movie.";
            } else {
                description = @"Hover for a moment to load movie information...\n\nClick to play this movie.";
            }
        }
        
        // Final safety check - ensure description is actually a string
        if (![description isKindOfClass:[NSString class]]) {
            description = [NSString stringWithFormat:@"%@", description];
        }
        
        // Ensure we don't try to draw in a negative space
        if (descContentRect.size.height > 0) {
            [description drawInRect:descContentRect withAttributes:descContentAttrs];
        }
        
        [descContentStyle release];
    }
    
    // Only draw file info if there's enough space
    if (panelRect.size.height > 300) {
        // Small footnote with file info
        NSMutableParagraphStyle *fileInfoStyle = [[NSMutableParagraphStyle alloc] init];
        [fileInfoStyle setAlignment:NSTextAlignmentLeft];
        
        NSDictionary *fileInfoAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:9],
            NSForegroundColorAttributeName: [NSColor darkGrayColor],
            NSParagraphStyleAttributeName: fileInfoStyle
        };
        
        NSString *fileExtension = [self fileExtensionFromUrl:channel.url];
        NSString *fileInfo = [NSString stringWithFormat:@"File Type: %@ | Movie ID: %@", 
                            fileExtension ? fileExtension : @"Unknown",
                            channel.movieId ? channel.movieId : @"Unknown"];
        
        NSRect fileInfoRect = NSMakeRect(
            panelRect.origin.x + padding,
            panelRect.origin.y + 2,
            availableWidth,
            12
        );
        
        [fileInfo drawInRect:fileInfoRect withAttributes:fileInfoAttrs];
        [fileInfoStyle release];
    }
    
    [titleStyle release];
    [descStyle release];
    [metadataStyle release];
    
    // Restore the graphics state to undo clipping and scrolling transform
    [context restoreGraphicsState];
    
    // Draw scroll indicator if hovering over movie info panel
    if (self.isHoveringMovieInfoPanel) {
        // Calculate content height based on description length
        // Using the same highly aggressive calculation as our scroll handler
        CGFloat contentHeight = 5000; // Significantly increased default
        if (channel.movieDescription) {
            NSInteger descriptionLength = [channel.movieDescription length];
            // Using a much higher scaling factor to ensure scrolling works
            contentHeight = MAX(contentHeight, 1000 + (descriptionLength * 5.0)); // Very aggressive approximation
            
            NSLog(@"Scroll indicator: content height = %.1f, scroll pos = %.1f", 
                  contentHeight, self.movieInfoScrollPosition);
        }
        
        CGFloat visibleHeight = panelRect.size.height;
        CGFloat maxScroll = MAX(0, contentHeight - visibleHeight);
        
        // Only draw scroll indicator if content is scrollable
        if (maxScroll > 0) {
            // Draw scroll indicator track
            NSRect scrollTrackRect = NSMakeRect(
                panelRect.origin.x + panelRect.size.width - 8,
                panelRect.origin.y,
                6,
                panelRect.size.height
            );
            
            [[NSColor colorWithWhite:0.3 alpha:0.3] set];
            NSRectFill(scrollTrackRect);
            
            // Calculate scroll thumb position and size
            CGFloat thumbRatio = visibleHeight / contentHeight;
            CGFloat thumbHeight = MAX(40, visibleHeight * thumbRatio);
            CGFloat scrollRatio = scrollOffset / maxScroll;
            CGFloat thumbY = panelRect.origin.y + (visibleHeight - thumbHeight) * (1.0 - scrollRatio);
            
            NSRect scrollThumbRect = NSMakeRect(
                panelRect.origin.x + panelRect.size.width - 8,
                thumbY,
                6,
                thumbHeight
            );
            
            [[NSColor colorWithWhite:0.7 alpha:0.7] set];
            NSBezierPath *thumbPath = [NSBezierPath bezierPathWithRoundedRect:scrollThumbRect xRadius:3 yRadius:3];
            [thumbPath fill];
        }
    }
}

// Helper to check if a string is numeric (for duration formatting)
- (BOOL)isNumeric:(NSString *)string {
    if (!string) return NO;
    NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
}

- (void)mouseEntered:(NSEvent *)event {
    // Get the current mouse position
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // Calculate 10% of the window width
    CGFloat activationZone = self.bounds.size.width * 0.1;
    
    // Only mark user interaction when in the activation zone
    if (point.x <= activationZone) {
        [self markUserInteraction];
    } else {
        // When outside the activation zone, we don't want to show the menu
        // Do nothing, which will keep the menu hidden if it's already hidden
    }
}

// Helper method to get file extensions in the UI category
- (NSString *)fileExtensionFromUrl:(NSString *)urlString {
    if (!urlString || [urlString length] == 0) {
        return nil;
    }
    
    // Remove query parameters
    NSRange queryRange = [urlString rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        urlString = [urlString substringToIndex:queryRange.location];
    }
    
    // Check for file extension in the path
    NSString *extension = nil;
    NSRange lastDotRange = [urlString rangeOfString:@"." options:NSBackwardsSearch];
    
    if (lastDotRange.location != NSNotFound) {
        // Get everything after the last dot
        extension = [urlString substringFromIndex:lastDotRange.location];
        
        // Only consider it an extension if it's short and contains only valid chars
        // (This helps avoid false positives like domain names)
        if ([extension length] <= 5) {
            NSCharacterSet *validExtChars = [NSCharacterSet alphanumericCharacterSet];
            NSString *extensionChars = [extension substringFromIndex:1]; // Skip the dot
            
            // Check if all characters are valid for a file extension
            BOOL isValid = YES;
            for (NSUInteger i = 0; i < [extensionChars length]; i++) {
                unichar c = [extensionChars characterAtIndex:i];
                if (![validExtChars characterIsMember:c]) {
                    isValid = NO;
                    break;
                }
            }
            
            if (isValid) {
                return [extension uppercaseString];
            }
        }
    }
    
    return nil;
}

// Modify the markUserInteraction method to check if media is playing
- (void)markUserInteraction {
    // Call the new method with showMenu = NO by default
    [self markUserInteractionWithMenuShow:NO];
}

// New method that controls whether to show the menu
- (void)markUserInteractionWithMenuShow:(BOOL)shouldShowMenu {
    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    lastInteractionTime = currentTime;
    
    // Set the user interaction flag
    isUserInteracting = YES;
    
    // If not already scheduled, schedule the interaction check
    if (!autoHideTimer) {
        [self scheduleInteractionCheck];
    }
    
    // Check if fade-out is in progress - if so, cancel it
    extern BOOL isFadingOut;
    extern NSTimeInterval lastFadeOutTime;
    if (isFadingOut) {
        // Don't try to show menu during fade-out
        return;
    }
    
    // Check if we're within the fade-out cooldown period to prevent immediate fade-in after fade-out
    CGFloat fadeOutCooldown = 0.5; // Half-second cooldown to prevent immediate fade-in
    BOOL isInFadeOutCooldown = (currentTime - lastFadeOutTime < fadeOutCooldown);
    if (isInFadeOutCooldown) {
        // Don't show menu if we just faded out
        return;
    }
    
    // Only show menu if explicitly requested (like from activation zone)
    if (shouldShowMenu) {
        // Only show UI if we're not in the middle of playing a newly selected channel
        // We need a small delay after a channel is clicked before showing the UI again
        static NSTimeInterval lastChannelClickTime = 0;
        NSTimeInterval timeSinceLastChannelClick = currentTime - lastChannelClickTime;
        
        // If channel was clicked very recently (within 1 second), don't show UI yet
        BOOL wasRecentlyClicked = (timeSinceLastChannelClick < 1.0);
        
        // Add smooth but quick fade-in animation when showing the menu
        if (!self.isChannelListVisible && !wasRecentlyClicked) {
            // Start with zero alpha for fade-in
            [self setAlphaValue:0.0];
            
            // Mark as visible first so it will be drawn
            self.isChannelListVisible = YES;
            [self setNeedsDisplay:YES];
            
            // Perform quick fade-in animation
            [NSAnimationContext beginGrouping];
            [[NSAnimationContext currentContext] setDuration:0.3]; // Faster 0.3 second fade-in
            [[self animator] setAlphaValue:1.0];
            [NSAnimationContext endGrouping];
        }
        //self.player.cu
        // Update the last channel click time when we play a channel
        if (self.player && [self.player isPlaying] && !self.isChannelListVisible) {
            lastChannelClickTime = currentTime;
        }
    }
}


// Fade out the UI after 2 seconds of inactivity with a short fade
- (void)checkUserInteraction:(NSTimer*)timer {
    // Check if we're already in the process of fading out
    extern BOOL isFadingOut;
    extern NSTimeInterval lastFadeOutTime;
    
    if (isFadingOut) {
        // Don't interrupt an ongoing fade-out
        return;
    }
    
    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    CGFloat inactivityDuration = currentTime - lastInteractionTime;
    
    // Start fading out after 2 seconds of inactivity
    if (inactivityDuration > 2.0) {
        // Only proceed if the UI is visible
        if (self.isChannelListVisible) {
            // Hide all controls before hiding the menu
            [self hideControls];
            // Mark as not visible immediately to prevent race conditions
            self.isChannelListVisible = NO;
            
            // Set flag to prevent mouse movement from interrupting
            isFadingOut = YES;
            
            // Record when we started the fade-out
            lastFadeOutTime = currentTime;
            
            // Use a shorter fade time
            [NSAnimationContext beginGrouping];
            [[NSAnimationContext currentContext] setDuration:0.5]; // Quicker 0.5 second fade
            [[self animator] setAlphaValue:0.0];
            [NSAnimationContext endGrouping];
            
            // After animation completes, reset everything cleanly
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Reset the view alpha
                [self setAlphaValue:1.0];
                
                // Reset interaction flags to allow menu to be shown again
                isFadingOut = NO;
                isUserInteracting = NO;
                
                // Force redraw
                [self setNeedsDisplay:YES];
            });
        }
    }
}

// Improved simpleChannelIndexAtPoint method with exact boundary calculations
- (NSInteger)simpleChannelIndexAtPoint:(NSPoint)point {
    // Define exact boundaries for the channel list area
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat rowHeight = 40;
    
    // Calculate channelListWidth dynamically to match the UI layout
    CGFloat programGuideWidth = 350; // Width reserved for program guide
    CGFloat channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
    
    // Calculate the exact start and end points of channel list
    CGFloat channelListStartX = catWidth + groupWidth;
    CGFloat channelListEndX = channelListStartX + channelListWidth;
    
    // Add debug logging to see point coordinates
   // NSLog(@"Mouse point: (%.1f, %.1f) - Channel list bounds: X from %.1f to %.1f", 
   //       point.x, point.y, channelListStartX, channelListEndX);
    
    // Check if point is precisely within channel list area horizontally
    if (point.x < channelListStartX || point.x >= channelListEndX) {
        //NSLog(@"Mouse outside channel list horizontal bounds");
        return -1;
    }
    
    // Calculate index from Y position, accounting for scroll
    NSInteger index = (NSInteger)((self.bounds.size.height - point.y) / rowHeight + channelScrollPosition / rowHeight);
    
    // Validate index against available channels
    if (index >= 0 && index < [self.simpleChannelNames count]) {
       //NSLog(@"Valid channel index found: %ld", (long)index);
        return index;
    }
    
    //NSLog(@"No valid channel index at current point");
    return -1;
}

// Add back the helper method to get the channel at the hovered index
- (VLCChannel *)getChannelAtHoveredIndex {
    if (self.hoveredChannelIndex < 0 || self.selectedCategoryIndex < 0 || self.selectedGroupIndex < 0) {
        return nil;
    }
    
    // Get the appropriate groups based on category
    NSArray *groups = nil;
    NSString *currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
    
    if ([currentCategory isEqualToString:@"FAVORITES"]) {
        groups = [self safeGroupsForCategory:@"FAVORITES"];
    } else if ([currentCategory isEqualToString:@"TV"]) {
        groups = [self safeTVGroups];
    } else if ([currentCategory isEqualToString:@"MOVIES"]) {
        groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
    } else if ([currentCategory isEqualToString:@"SERIES"]) {
        groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
    } else if ([currentCategory isEqualToString:@"SETTINGS"]) {
        groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
    }
    
    // Get the current group
    if (groups && self.selectedGroupIndex < groups.count) {
        NSString *currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
        
        // Get channels for this group
        NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
        if (channelsInGroup && self.hoveredChannelIndex < channelsInGroup.count) {
            return [channelsInGroup objectAtIndex:self.hoveredChannelIndex];
        }
    }
    
    return nil;
}

// Add a new method for asynchronous image loading
- (void)loadImageAsynchronously:(NSString *)imageUrl forChannel:(VLCChannel *)channel {
    // Thorough validation to prevent empty URL errors
    if (!imageUrl || !channel || [imageUrl length] == 0 || 
        [imageUrl isEqualToString:@"(null)"] || [imageUrl isEqualToString:@"null"]) {
        //NSLog(@"Cannot load image: Invalid or empty URL or channel");
        // Clear loading flag to prevent hanging state
        if (channel) {
            objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    
    // Don't reload if we already have a cached image
    if (channel.cachedPosterImage) {
        NSLog(@"Image already cached for channel: %@", channel.name);
        return;
    }
    
    // We use a separate property to track image loading
    if (objc_getAssociatedObject(channel, "imageLoadingInProgress")) {
        NSLog(@"Image loading already in progress for channel: %@", channel.name);
        return;
    }
    
    // Mark that we're starting image loading using associated objects
    objc_setAssociatedObject(channel, "imageLoadingInProgress", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Try to load from disk cache first
    [self loadCachedPosterImageForChannel:channel];
    
    // If successfully loaded from disk cache, return early
    if (channel.cachedPosterImage) {
        //NSLog(@"Using image from disk cache for channel: %@", channel.name);
        
        // Trigger redraw
        [self setNeedsDisplay:YES];
        return;
    }
    
    // Additional validation for URL string format
    if (![imageUrl hasPrefix:@"http://"] && ![imageUrl hasPrefix:@"https://"]) {
        NSLog(@"URL doesn't have http/https prefix, adding http://: %@", imageUrl);
        imageUrl = [@"http://" stringByAppendingString:imageUrl];
    }
    
    NSLog(@"Starting image download for channel: %@ from URL: %@", channel.name, imageUrl);
    
    // Create URL object with validation
    NSURL *url = [NSURL URLWithString:imageUrl];
    if (!url) {
        NSLog(@"Invalid image URL format: %@", imageUrl);
        // Clear loading state
        objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    
    // Final URL validation to prevent empty host issues
    if (!url.host || [url.host length] == 0) {
        NSLog(@"URL has no valid host: %@", imageUrl);
        // Clear loading state
        objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    
    // Create and start asynchronous download task with extra error handling
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLRequest *request = [NSURLRequest requestWithURL:url 
                                           cachePolicy:NSURLRequestUseProtocolCachePolicy 
                                       timeoutInterval:15.0];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request 
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // Handle errors
        if (error) {
            NSLog(@"Error loading image data for channel %@: %@", channel.name, [error localizedDescription]);
            
            // Clear the loading flag on error
        dispatch_async(dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
            return;
        }
        
        // Check HTTP status
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            NSLog(@"HTTP error loading image for channel %@: %ld", channel.name, (long)httpResponse.statusCode);
            
            // Clear the loading flag on HTTP error
            dispatch_async(dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
            return;
        }
        
        // Process the image on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Create image from data
            NSImage *downloadedImage = [[NSImage alloc] initWithData:data];
            if (!downloadedImage) {
                NSLog(@"Failed to create image from downloaded data for channel: %@", channel.name);
                
                // Clear loading flag even on failure
                objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return;
            }
            
            // Cache the image in the channel
            channel.cachedPosterImage = downloadedImage;
            
            // Also save to disk cache for persistence across app restarts
            [self savePosterImageToDiskCache:downloadedImage forURL:imageUrl];
            
            [downloadedImage release]; // release local reference, channel will retain it
            
            // Clear the loading flag
            objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            
            // Trigger a redraw
            [self setNeedsDisplay:YES];
            
            NSLog(@"Successfully downloaded and cached image for channel: %@", channel.name);
        });
    }];
    
    [task resume];
}

int cnt=0;
// Now modify the drawRect method to conditionally use grid view
- (void)drawRect:(NSRect)dirtyRect {
    // Original existing implementation...
    // This is where the view is drawn
   // NSLog(@"drawRect called %d- playerControlsVisible: %@, menu: %@",cnt++,
   //      playerControlsVisible ? @"YES" : @"NO",
   //        self.isChannelListVisible ? @"visible" : @"hidden");
    // Clear the background
    [self.backgroundColor set];
    //NSRectFill(dirtyRect);
    
    // Draw the channel list if it's visible
    if (self.isChannelListVisible) {
        // Draw the components
        [self drawCategories:dirtyRect];
        [self drawGroups:dirtyRect];
        
        // Adjust based on selected category
        if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
            [self drawSettingsPanel:dirtyRect];
        } else if (self.showEpgPanel) {
            [self drawEpgPanel:dirtyRect];
        } else {
            // For content categories, either draw grid or channel list
            if (isGridViewActive) {
                [self drawGridView:dirtyRect];
            } else {
                [self drawChannelList:dirtyRect];
                
                // Don't draw movie info panel for selected channel when in regular browse mode
                // This allows program guides to show normally when hovering over channels
                
                // Proactively load movie info and images for all visible channels in list mode
                NSArray *channelsInCurrentGroup = [self getChannelsForCurrentGroup];
                if (channelsInCurrentGroup) {
                    // Calculate which channels are currently visible
                    CGFloat rowHeight = 40;
                    NSInteger start = (NSInteger)floor(channelScrollPosition / rowHeight);
                    NSInteger visible = (NSInteger)(self.bounds.size.height / rowHeight) + 2;
                    NSInteger end = start + visible;
                    end = MIN(end, channelsInCurrentGroup.count);
                    
                    // Pre-fetch information for all visible channels and the selected channel
                    for (NSInteger i = start; i < end; i++) {
                        if (i >= 0 && i < channelsInCurrentGroup.count) {
                            VLCChannel *channel = [channelsInCurrentGroup objectAtIndex:i];
                            
                            // Priority for the selected channel
                            BOOL isSelected = (i == self.selectedChannelIndex);
                            
                            // Fetch movie info for movie channels
                            if ([channel.category isEqualToString:@"MOVIES"] && !channel.hasLoadedMovieInfo) {
                                // Check if movie info is already cached
                                BOOL loadedFromCache = [self loadMovieInfoFromCacheForChannel:channel];
                                
                                // If not in cache and not already fetching, start fetch
                                if (!loadedFromCache && !channel.hasStartedFetchingMovieInfo) {
                                    channel.hasStartedFetchingMovieInfo = YES;
                                    
                                    // Use higher priority dispatch for selected channel
                                    dispatch_queue_priority_t priority = isSelected ? 
                                        DISPATCH_QUEUE_PRIORITY_HIGH : DISPATCH_QUEUE_PRIORITY_DEFAULT;
                                    
                                    // Fetch movie info asynchronously
                                    dispatch_async(dispatch_get_global_queue(priority, 0), ^{
                                        NSLog(@"Fetching movie info for channel %@ (index %ld)", channel.name, (long)i);
                                        [self fetchMovieInfoForChannel:channel];
                                        
                                        // Trigger UI update on main thread
                                        dispatch_async(dispatch_get_main_queue(), ^{
                                            [self setNeedsDisplay:YES];
                                        });
                                    });
                                }
                            }
                            
                            // Load image if needed
                            if (channel.logo && !channel.cachedPosterImage) {
                                //NSLog(@"Loading image for channel %@ (index %ld)", channel.name, (long)i);
                                [self loadImageAsynchronously:channel.logo forChannel:channel];
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Draw loading indicator if needed
    if (self.isLoading) {
        [self drawLoadingIndicator:dirtyRect];
    }
    
    // Draw URL input field if active
    if (self.isTextFieldActive) {
        [self drawURLInputField:dirtyRect];
    }
    
    // Draw the player controls if player exists and is playing
    if (/*self.player &&*/ playerControlsVisible) {
        [self drawPlayerControls:dirtyRect];
    }
    [self drawDropdowns:dirtyRect];
}

// Add method to show/hide player controls
- (void)togglePlayerControls {
    playerControlsVisible = !playerControlsVisible;
    [self setNeedsDisplay:YES];
    
    // Reset timer when toggling
    if (playerControlsTimer) {
        [playerControlsTimer invalidate];
        playerControlsTimer = nil;
    }
    
    // Set a timer to auto-hide the controls
    if (playerControlsVisible) {
        playerControlsTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                            target:self
                                                         selector:@selector(hidePlayerControls:)
                                                          userInfo:nil
                                                          repeats:NO];
    }
}
/*
- (void)hidePlayerControls:(NSTimer *)timer {
    playerControlsVisible = NO;
    [self setNeedsDisplay:YES];
    playerControlsTimer = nil;
}
*/
// Add a helper method to get the channel at a specific index
- (VLCChannel *)getChannelAtIndex:(NSInteger)index {
    if (index < 0 || self.selectedCategoryIndex < 0 || self.selectedGroupIndex < 0) {
        return nil;
    }
    
    // Get the appropriate groups based on category
    NSArray *groups = nil;
    NSString *currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
    
    if ([currentCategory isEqualToString:@"FAVORITES"]) {
        groups = [self safeGroupsForCategory:@"FAVORITES"];
    } else if ([currentCategory isEqualToString:@"TV"]) {
        groups = [self safeTVGroups];
    } else if ([currentCategory isEqualToString:@"MOVIES"]) {
        groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
    } else if ([currentCategory isEqualToString:@"SERIES"]) {
        groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
    }
    
    // Get the current group
    if (groups && self.selectedGroupIndex < groups.count) {
        NSString *currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
        
        // Get channels for this group
        NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
        if (channelsInGroup && index < channelsInGroup.count) {
            return [channelsInGroup objectAtIndex:index];
        }
    }
    
    return nil;
}

// Add a new method to draw the grid view
- (void)drawGridView:(NSRect)dirtyRect {
    // Calculate dimensions for grid area (only in the channel/info space)
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat gridX = catWidth + groupWidth; // Start after categories and groups
    CGFloat gridWidth = self.bounds.size.width - gridX;
    
    // Draw background for grid area
    NSRect gridBackground = NSMakeRect(gridX, 0, gridWidth, self.bounds.size.height);
    [self.backgroundColor set];
    NSRectFill(gridBackground);
    
    // Define the content area (accounts for header space)
    NSRect contentRect = NSMakeRect(gridX, 0, gridWidth, self.bounds.size.height - 40);
    
    // Get the current group's channels
    NSArray *channelsToShow = [self getChannelsForCurrentGroup];
    
    if (!channelsToShow || channelsToShow.count == 0) {
        // If no channels, draw a message
        NSString *message = @"No channels to display in grid view";
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentCenter];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:16],
            NSForegroundColorAttributeName: self.textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSRect messageRect = NSMakeRect(gridX, self.bounds.size.height/2 - 10, gridWidth, 20);
        [message drawInRect:messageRect withAttributes:attrs];
        [style release];
        return;
    }
    
    // Calculate grid metrics - adapted for the narrower space
    CGFloat itemPadding = 10;
    CGFloat itemWidth = MIN(180, (gridWidth / 2) - (itemPadding * 2)); // Adjust size to fit at least 2 columns
    CGFloat itemHeight = itemWidth * 1.5; // Keep reasonable aspect ratio
    
    // Calculate how many columns fit in the available width
    NSInteger maxColumns = (NSInteger)((gridWidth - itemPadding) / (itemWidth + itemPadding));
    maxColumns = MAX(1, maxColumns); // At least 1 column
    
    // Calculate row spacing based on available height
    NSInteger numRows = (NSInteger)ceilf((float)channelsToShow.count / (float)maxColumns);
    CGFloat totalGridHeight = numRows * (itemHeight + itemPadding) + itemPadding;
    
    // Add extra space at the bottom to ensure last row is fully visible when scrolled to the end
    totalGridHeight += itemHeight;
    
    // Calculate vertical offset for scrolling with improved limits
    CGFloat maxScroll = MAX(0, totalGridHeight - contentRect.size.height);
    CGFloat scrollOffset = MAX(0, MIN(channelScrollPosition, maxScroll));
    
    // Draw a header showing the current category and group
    NSString *headerText = @"Grid View";
    NSString *currentGroup = [self getCurrentGroupName];
    if (currentGroup) {
        headerText = [NSString stringWithFormat:@"Grid View: %@", currentGroup];
    }
    
    NSMutableParagraphStyle *headerStyle = [[NSMutableParagraphStyle alloc] init];
    [headerStyle setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *headerAttrs = @{
        NSFontAttributeName: [NSFont fontWithName:@"HelveticaNeue-Light" size:16] ?: [NSFont systemFontOfSize:16],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: headerStyle
    };
    
    NSRect headerRect = NSMakeRect(gridX, self.bounds.size.height - 40, gridWidth, 40);
    [headerText drawInRect:headerRect withAttributes:headerAttrs];
    [headerStyle release];
    
    // Draw info text
    NSMutableParagraphStyle *infoStyle = [[NSMutableParagraphStyle alloc] init];
    [infoStyle setAlignment:NSTextAlignmentRight];
    
    NSDictionary *infoAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor lightGrayColor],
        NSParagraphStyleAttributeName: infoStyle
    };
    
    NSString *infoText = @"Press 'L' to return to list view";
    NSRect infoRect = NSMakeRect(self.bounds.size.width - 250, self.bounds.size.height - 20, 240, 20);
    [infoText drawInRect:infoRect withAttributes:infoAttrs];
    [infoStyle release];
    
    // Draw each channel as a grid item
    for (NSInteger i = 0; i < channelsToShow.count; i++) {
        NSInteger row = i / maxColumns;
        NSInteger col = i % maxColumns;
        
        // Calculate position (centered in available width)
        CGFloat totalGridWidth = maxColumns * (itemWidth + itemPadding) + itemPadding;
        CGFloat leftMargin = gridX + (gridWidth - totalGridWidth) / 2;
        
        CGFloat x = leftMargin + itemPadding + col * (itemWidth + itemPadding);
        CGFloat y = self.bounds.size.height - 60 - itemHeight - (row * (itemHeight + itemPadding)) + scrollOffset;
        
        // Skip if not visible
        if (y + itemHeight < 0 || y > self.bounds.size.height) {
            continue;
        }
        
        // Get the channel and draw its grid item
        VLCChannel *channel = [channelsToShow objectAtIndex:i];
        [self drawGridItem:channel atRect:NSMakeRect(x, y, itemWidth, itemHeight) highlight:(i == self.hoveredChannelIndex)];
        
        // Initiate asynchronous loading of channel data and images if needed
        [self queueAsyncLoadForGridChannel:channel atIndex:i];
    }
    
    // Draw the scroll bar
    [self drawScrollBar:contentRect contentHeight:totalGridHeight scrollPosition:scrollOffset];
}

// Helper method to draw a single grid item
- (void)drawGridItem:(VLCChannel *)channel atRect:(NSRect)itemRect highlight:(BOOL)highlight {
    // Draw background
    NSRect bgRect = NSInsetRect(itemRect, 1, 1);
    if (highlight) {
        [self.hoverColor set];
    } else {
        [[NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.15 alpha:1.0] set];
    }
    
    // Use rounded rect for better appearance
    NSBezierPath *bgPath = [NSBezierPath bezierPathWithRoundedRect:bgRect xRadius:5 yRadius:5];
    [bgPath fill];
    
    // Draw border
    [[NSColor colorWithCalibratedWhite:0.4 alpha:1.0] set];
    [bgPath setLineWidth:1.0];
    [bgPath stroke];
    
    // Calculate poster area (top part of the item)
    CGFloat posterHeight = itemRect.size.height * 0.8;
    NSRect posterRect = NSMakeRect(
        itemRect.origin.x + 5,
        itemRect.origin.y + (itemRect.size.height - posterHeight - 5),
        itemRect.size.width - 10,
        posterHeight - 5
    );
    
    // For TV channels, use a white background with rounded corners to make logos look better
    if ([channel.category isEqualToString:@"TV"]) {
        // Create a rounded rect path for the white background
        NSBezierPath *bgPath = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:5 yRadius:5];
        [[NSColor whiteColor] set];
        [bgPath fill];
        
        // Add a subtle border
        [[NSColor colorWithWhite:0.9 alpha:1.0] set];
        [bgPath setLineWidth:1.0];
        [bgPath stroke];
    }
    
    // Draw poster if available
    NSImage *posterImage = channel.cachedPosterImage;
    
    if (posterImage) {
        // Calculate the image size to maintain aspect ratio
        NSSize imageSize = [posterImage size];
        
        // Use square aspect ratio for TV channel logos
        if ([channel.category isEqualToString:@"TV"]) {
            // For TV logos, we use a completely different approach for best results
            // Create a square area in the center of the poster with plenty of padding
            CGFloat maxDimension = MIN(posterRect.size.width, posterRect.size.height);
            CGFloat squareSize = maxDimension * 0.70; // Reduced from 75% to 70% for more padding
            
            // Center the square in the poster area
            CGFloat xOffset = (posterRect.size.width - squareSize) / 2;
            CGFloat yOffset = (posterRect.size.height - squareSize) / 2;
            
            NSRect logoRect = NSMakeRect(
                posterRect.origin.x + xOffset,
                posterRect.origin.y + yOffset,
                squareSize,
                squareSize
            );
            
            // Scale the logo to fit in the square while preserving aspect ratio
            CGFloat aspectRatio = imageSize.width / MAX(1.0, imageSize.height);
            NSRect drawRect;
            
            if (aspectRatio > 1.0) {
                // Wider logo - constrain to width
                CGFloat scaledHeight = squareSize / aspectRatio;
                CGFloat innerYOffset = (squareSize - scaledHeight) / 2;
                drawRect = NSMakeRect(
                    logoRect.origin.x,
                    logoRect.origin.y + innerYOffset,
                    squareSize,
                    scaledHeight
                );
            } else {
                // Taller logo - constrain to height
                CGFloat scaledWidth = squareSize * aspectRatio;
                CGFloat innerXOffset = (squareSize - scaledWidth) / 2;
                drawRect = NSMakeRect(
                    logoRect.origin.x + innerXOffset,
                    logoRect.origin.y,
                    scaledWidth,
                    squareSize
                );
            }
            
            // Use NSBezierPath for rounded corners in grid view - TV logos
            // Save graphics state before clipping
            [NSGraphicsContext saveGraphicsState];
            NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:5 yRadius:5];
            [clipPath setClip];
            [posterImage drawInRect:drawRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
            // Restore graphics state instead of resetting clip on the path
            [NSGraphicsContext restoreGraphicsState];
        } else {
            // For movies and other content, use standard movie poster ratio
            CGFloat aspectRatio = imageSize.width / MAX(1.0, imageSize.height);
            
            // Create a slightly smaller rectangle with padding
            CGFloat padding = 6.0;
            NSRect innerRect = NSInsetRect(posterRect, padding, padding);
            
            NSRect drawRect;
            if (aspectRatio > (innerRect.size.width / innerRect.size.height)) {
                // Image is wider than the target area
                CGFloat scaledHeight = innerRect.size.width / aspectRatio;
                CGFloat yOffset = (innerRect.size.height - scaledHeight) / 2;
                drawRect = NSMakeRect(innerRect.origin.x, innerRect.origin.y + yOffset, innerRect.size.width, scaledHeight);
            } else {
                // Image is taller than the target area
                CGFloat scaledWidth = innerRect.size.height * aspectRatio;
                CGFloat xOffset = (innerRect.size.width - scaledWidth) / 2;
                drawRect = NSMakeRect(innerRect.origin.x + xOffset, innerRect.origin.y, scaledWidth, innerRect.size.height);
            }
            
            // Use NSBezierPath for rounded corners in grid view - movie posters
            // Save graphics state before clipping
            [NSGraphicsContext saveGraphicsState];
            NSBezierPath *clipPath = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:5 yRadius:5];
            [clipPath setClip];
            [posterImage drawInRect:drawRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
            // Restore graphics state instead of resetting clip on the path
            [NSGraphicsContext restoreGraphicsState];
        }
    } else {
        // Draw placeholder if no image - with rounded corners to match the grid item style
        NSBezierPath *placeholderPath = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:5 yRadius:5];
        [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0] set];
        [placeholderPath fill];
        
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentCenter];
        
        if (channel.hasStartedFetchingMovieInfo && !channel.hasLoadedMovieInfo) {
            // If loading, show a loading message
            NSDictionary *loadingAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:12],
                NSForegroundColorAttributeName: [NSColor lightGrayColor],
                NSParagraphStyleAttributeName: style
            };
            
            NSString *loadingText = @"Loading...";
            [loadingText drawInRect:NSInsetRect(posterRect, 10, posterRect.size.height/2 - 10) withAttributes:loadingAttrs];
        } else {
            // Show empty background with no text
        }
        
        [style release];
    }
    
    // Draw title at the bottom
    NSRect titleRect = NSMakeRect(
        itemRect.origin.x + 5,
        itemRect.origin.y + 5,
        itemRect.size.width - 10,
        itemRect.size.height * 0.2 - 10
    );
    
    NSMutableParagraphStyle *titleStyle = [[NSMutableParagraphStyle alloc] init];
    [titleStyle setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: titleStyle
    };
    
    // Truncate title if needed
    NSString *title = channel.name;
    if (title.length > 40) {
        title = [[title substringToIndex:37] stringByAppendingString:@"..."];
    }
    
    [title drawInRect:titleRect withAttributes:titleAttrs];
    [titleStyle release];
    
    // If movie has metadata, draw a small info badge
    if (channel.hasLoadedMovieInfo && (channel.movieYear || channel.movieRating)) {
        NSString *infoText = @"";
        if (channel.movieYear) {
            infoText = channel.movieYear;
        }
        if (channel.movieRating && [channel.movieRating floatValue] > 0) {
            if (infoText.length > 0) {
                infoText = [infoText stringByAppendingFormat:@" • %@★", channel.movieRating];
            } else {
                infoText = [NSString stringWithFormat:@"%@★", channel.movieRating];
            }
        }
        
        if (infoText.length > 0) {
            NSRect infoRect = NSMakeRect(
                itemRect.origin.x + 10,
                itemRect.origin.y + itemRect.size.height - 20,
                itemRect.size.width - 20,
                15
            );
            
            NSDictionary *infoAttrs = @{
                NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
                NSForegroundColorAttributeName: [NSColor yellowColor],
                NSParagraphStyleAttributeName: titleStyle
            };
            
            [infoText drawInRect:infoRect withAttributes:infoAttrs];
        }
    }
}

// Helper method to get all channels for the current group
- (NSArray *)getChannelsForCurrentGroup {
    // Get current category and group
    NSString *currentCategory = nil;
    NSString *currentGroup = nil;
    NSArray *groups = nil;
    
    if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
        currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
        
        // Get the appropriate groups based on category
        if ([currentCategory isEqualToString:@"FAVORITES"]) {
            groups = [self safeGroupsForCategory:@"FAVORITES"];
        } else if ([currentCategory isEqualToString:@"TV"]) {
            groups = [self safeTVGroups];
        } else if ([currentCategory isEqualToString:@"MOVIES"]) {
            groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
        } else if ([currentCategory isEqualToString:@"SERIES"]) {
            groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
        }
        
        // Get the current group
        if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
            currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
            
            // Get channels for this group
            return [self.channelsByGroup objectForKey:currentGroup];
        }
    }
    
    return nil;
}

// Helper method to get current group name
- (NSString *)getCurrentGroupName {
    // Get current category and group
    NSString *currentCategory = nil;
    NSArray *groups = nil;
    
    if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
        currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
        
        // Get the appropriate groups based on category
        if ([currentCategory isEqualToString:@"FAVORITES"]) {
            groups = [self safeGroupsForCategory:@"FAVORITES"];
        } else if ([currentCategory isEqualToString:@"TV"]) {
            groups = [self safeTVGroups];
        } else if ([currentCategory isEqualToString:@"MOVIES"]) {
            groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
        } else if ([currentCategory isEqualToString:@"SERIES"]) {
            groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
        }
        
        // Get the current group
        if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
            return [groups objectAtIndex:self.selectedGroupIndex];
        }
    }
    
    return nil;
}

// Helper method to check if a group has channels with catch-up functionality
- (BOOL)groupHasCatchupChannels:(NSString *)groupName {
    if (!groupName) return NO;
    
    NSArray *channelsInGroup = [self.channelsByGroup objectForKey:groupName];
    if (!channelsInGroup) return NO;
    
    for (VLCChannel *channel in channelsInGroup) {
        // Check both EPG-based catch-up and channel-level catch-up
        if (channel.supportsCatchup) {
            return YES; // Channel-level catch-up support
        }
        
        if (channel.programs && channel.programs.count > 0) {
            for (VLCProgram *program in channel.programs) {
                if (program.hasArchive) {
                    return YES; // EPG-based catch-up support
                }
            }
        }
    }
    
    return NO;
}

// Queue async loading of channel info and images
- (void)queueAsyncLoadForGridChannel:(VLCChannel *)channel atIndex:(NSInteger)index {
    if (!channel || !channel.name) return;
    
    // Skip if we've already queued this channel
    NSString *channelKey = [NSString stringWithFormat:@"%ld", (long)index];
    if ([gridLoadingQueue objectForKey:channelKey]) {
        return;
    }
    
    // Mark as queued to avoid duplicate requests
    [gridLoadingQueue setObject:@YES forKey:channelKey];
    
    // Process movie info if this is a movie channel
    if ([channel.category isEqualToString:@"MOVIES"] && !channel.hasLoadedMovieInfo) {
        // First check if movie info is in cache
        BOOL loadedFromCache = [self loadMovieInfoFromCacheForChannel:channel];
        
        // If not in cache, fetch asynchronously
        if (!loadedFromCache) {
            // Queue the work on a background thread
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // Set flag to indicate fetching has started
                channel.hasStartedFetchingMovieInfo = YES;
                
                // Fetch the movie info
                [self fetchMovieInfoForChannel:channel];
                
                // Save to cache
                [self saveMovieInfoToCache:channel];
                
                // Trigger redraw on main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setNeedsDisplay:YES];
                });
            });
        }
    }
    
    // Check if we need to load the poster image
    if (channel.logo && !channel.cachedPosterImage) {
        // Try to load from disk cache first
        [self loadCachedPosterImageForChannel:channel];
        
        // If not in disk cache, load from network
        if (!channel.cachedPosterImage && channel.logo) {
            // Validate logo URL first
            if ([channel.logo length] == 0 || 
                [channel.logo isEqualToString:@"(null)"] || 
                [channel.logo isEqualToString:@"null"]) {
                NSLog(@"Skipping image loading - invalid logo URL: %@", channel.logo);
                return;
            }
            
            // Create an operation for downloading the image
            NSBlockOperation *downloadOperation = [NSBlockOperation blockOperationWithBlock:^{
                // Create a correctly encoded URL
                NSString *logoUrl = channel.logo;
                
                // Basic URL validation
                if (!logoUrl || [logoUrl length] == 0) {
                    NSLog(@"Empty logo URL, skipping download");
                    return;
                }
                
                // Add http:// prefix if missing
                if (![logoUrl hasPrefix:@"http://"] && ![logoUrl hasPrefix:@"https://"]) {
                    logoUrl = [@"http://" stringByAppendingString:logoUrl];
                }
                
                // URL encode the string properly
                if (logoUrl && ![logoUrl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
                    if ([logoUrl respondsToSelector:@selector(stringByAddingPercentEncodingWithAllowedCharacters:)]) {
                        NSCharacterSet *urlAllowedSet = [NSCharacterSet URLQueryAllowedCharacterSet];
                        logoUrl = [logoUrl stringByAddingPercentEncodingWithAllowedCharacters:urlAllowedSet];
                    } else {
                        logoUrl = [logoUrl stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                    }
                }
                
                // Try to download the image with proper validation
                NSURL *url = [NSURL URLWithString:logoUrl];
                if (!url || !url.host || [url.host length] == 0) {
                    NSLog(@"Invalid URL or missing host: %@", logoUrl);
                    return;
                }
                
                // Use modern asynchronous URLSession API
                NSURLSessionDataTask *downloadTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    if (error) {
                        NSLog(@"Image download error: %@", error.localizedDescription);
                        return;
                    }
                    
                    if (data) {
                        NSImage *downloadedImage = [[NSImage alloc] initWithData:data];
                        if (downloadedImage) {
                            // Update on main thread
                            dispatch_async(dispatch_get_main_queue(), ^{
                                channel.cachedPosterImage = downloadedImage;
                                [downloadedImage release];
                                
                                // Save to disk cache
                                [self savePosterImageToDiskCache:channel.cachedPosterImage forURL:channel.logo];
                                
                                // Trigger redraw
                                [self setNeedsDisplay:YES];
                            });
                        }
                    }
                }];
                
                [downloadTask resume];
            }];
            
            // Add the operation to the queue for parallel processing
            [coverDownloadQueue addOperation:downloadOperation];
        }
    }
}

// Helper method to determine which grid item is at a given point
- (NSInteger)gridItemIndexAtPoint:(NSPoint)point {
    // Calculate grid area dimensions
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat gridX = catWidth + groupWidth;
    CGFloat gridWidth = self.bounds.size.width - gridX;
    
    // If point is outside grid area, return -1
    if (point.x < gridX) {
        return -1;
    }
    
    // Calculate grid metrics
    CGFloat itemPadding = 10;
    CGFloat itemWidth = MIN(180, (gridWidth / 2) - (itemPadding * 2));
    CGFloat itemHeight = itemWidth * 1.5;
    
    // Calculate columns
    NSInteger maxColumns = (NSInteger)((gridWidth - itemPadding) / (itemWidth + itemPadding));
    maxColumns = MAX(1, maxColumns);
    
    // Get channels
    NSArray *channels = [self getChannelsForCurrentGroup];
    if (!channels || channels.count == 0) {
        return -1;
    }
    
    // Calculate number of rows and total height
    NSInteger numRows = (NSInteger)ceilf((float)channels.count / (float)maxColumns);
    CGFloat totalGridHeight = numRows * (itemHeight + itemPadding) + itemPadding;
    
    // Calculate scroll offset
    CGFloat scrollOffset = MAX(0, MIN(channelScrollPosition, totalGridHeight - self.bounds.size.height));
    
    // Calculate grid item positions and check if point is inside any of them
    for (NSInteger i = 0; i < channels.count; i++) {
        NSInteger row = i / maxColumns;
        NSInteger col = i % maxColumns;
        
        // Calculate position with centering
        CGFloat totalGridWidth = maxColumns * (itemWidth + itemPadding) + itemPadding;
        CGFloat leftMargin = gridX + (gridWidth - totalGridWidth) / 2;
        
        CGFloat x = leftMargin + itemPadding + col * (itemWidth + itemPadding);
        CGFloat y = self.bounds.size.height - 60 - itemHeight - (row * (itemHeight + itemPadding)) + scrollOffset;
        
        // Create rect for this grid item
        NSRect itemRect = NSMakeRect(x, y, itemWidth, itemHeight);
        
        // Check if point is inside this rect
        if (NSPointInRect(point, itemRect)) {
            return i;
        }
    }
    
    return -1;
}

// Timer to control scroll bar visibility
NSTimer *scrollBarFadeTimer = nil;
float scrollBarAlpha = 0.0; // Used to control scroll bar opacity

// Add a new method to draw a scroll bar
- (void)drawScrollBar:(NSRect)contentRect contentHeight:(CGFloat)contentHeight scrollPosition:(CGFloat)scrollPosition {
    // Only draw if content is taller than the visible area
    if (contentHeight <= contentRect.size.height) {
        return;
    }
    
    // Only show scroll bar when scrolling or briefly after
    if (scrollBarAlpha <= 0.01) {
        return;
    }
    
    // Calculate scroll bar metrics - make slightly wider for better visibility
    CGFloat scrollBarWidth = 6.0; 
    CGFloat scrollBarMargin = 2.0;
    CGFloat scrollBarHeight = contentRect.size.height;
    
    // Position the scroll bar on the right side of the content area
    NSRect scrollBarRect = NSMakeRect(
        contentRect.origin.x + contentRect.size.width - scrollBarWidth - scrollBarMargin,
        contentRect.origin.y,
        scrollBarWidth,
        scrollBarHeight
    );
    
    // Skip drawing background - only draw the thumb with no background
    
    // Calculate thumb size and position
    CGFloat visibleRatio = contentRect.size.height / contentHeight;
    CGFloat thumbHeight = MAX(20, scrollBarHeight * visibleRatio); // Minimum thumb size
    
    // Calculate scroll position as a ratio of the total scrollable distance
    CGFloat maxScroll = contentHeight - contentRect.size.height;
    CGFloat scrollRatio = (maxScroll > 0) ? scrollPosition / maxScroll : 0;
    
    // Calculate thumb position - invert for correct direction
    CGFloat thumbY = scrollBarRect.origin.y + (scrollBarHeight - thumbHeight) * (1.0 - scrollRatio);
    
    // Draw the thumb without background
    NSRect thumbRect = NSMakeRect(
        scrollBarRect.origin.x,
        thumbY,
        scrollBarWidth,
        thumbHeight
    );
    
    // Use a more visible thumb with slightly darker color
    [[NSColor colorWithCalibratedWhite:0.6 alpha:scrollBarAlpha * 0.9] set];
    NSBezierPath *thumbPath = [NSBezierPath bezierPathWithRoundedRect:thumbRect xRadius:3 yRadius:3];
    [thumbPath fill];
}

// Add a new method to fade out scroll bars
- (void)fadeScrollBars:(NSTimer *)timer {
    // Reduce alpha gradually
    scrollBarAlpha -= 0.1;
    
    // If fully transparent, stop the timer
    if (scrollBarAlpha <= 0) {
        scrollBarAlpha = 0;
        [scrollBarFadeTimer invalidate];
        scrollBarFadeTimer = nil;
    }
    
    // Trigger redraw to update scroll bar appearance
    [self setNeedsDisplay:YES];
}

// Add a new method to draw Movie Info settings
- (void)drawMovieInfoSettings:(NSRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 20;
    CGFloat startY = self.bounds.size.height - 100;
    CGFloat buttonHeight = 40;
    CGFloat buttonWidth = 260;
    
    // Draw a section title
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect titleRect = NSMakeRect(x + padding, startY, width - (padding * 2), 20);
    [@"Movie Information Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    // Draw descriptive text
    NSRect descRect = NSMakeRect(x + padding, startY - 30, width - (padding * 2), 20);
    NSDictionary *descAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    [@"Manage movie information and poster images" drawInRect:descRect withAttributes:descAttrs];
    
    // Get the current cache directory info
    NSString *cacheDir = [self getCacheDirectoryPath];
    NSString *movieInfoCacheDir = [cacheDir stringByAppendingPathComponent:@"MovieInfo"];
    NSString *posterCacheDir = [cacheDir stringByAppendingPathComponent:@"Posters"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Count files in cache directories
    NSInteger movieInfoCount = 0;
    NSInteger posterCount = 0;
    NSError *error = nil;
    
    if ([fileManager fileExistsAtPath:movieInfoCacheDir]) {
        NSArray *files = [fileManager contentsOfDirectoryAtPath:movieInfoCacheDir error:&error];
        if (!error) {
            movieInfoCount = files.count;
        }
    }
    
    if ([fileManager fileExistsAtPath:posterCacheDir]) {
        NSArray *files = [fileManager contentsOfDirectoryAtPath:posterCacheDir error:&error];
        if (!error) {
            posterCount = files.count;
        }
    }
    
    // Draw cache stats
    NSRect statsRect = NSMakeRect(x + padding, startY - 60, width - (padding * 2), 20);
    NSString *statsText = [NSString stringWithFormat:@"Cache: %ld movie descriptions, %ld poster images", 
                          (long)movieInfoCount, (long)posterCount];
    [statsText drawInRect:statsRect withAttributes:descAttrs];
    
    // Draw refresh button or progress bar
    NSRect refreshButtonRect = NSMakeRect(
        x + padding, 
        startY - 110, 
        buttonWidth, 
        buttonHeight
    );
    
    if (self.isRefreshingMovieInfo) {
        // Draw progress bar instead of button
        NSRect progressBarRect = refreshButtonRect;
        
        // Draw progress bar background
        [[NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:1.0] set];
        NSBezierPath *progressBgPath = [NSBezierPath bezierPathWithRoundedRect:progressBarRect xRadius:5 yRadius:5];
        [progressBgPath fill];
        
        // Calculate progress percentage
        CGFloat progressPercent = 0.0;
        if (self.movieRefreshTotal > 0) {
            progressPercent = (CGFloat)self.movieRefreshCompleted / (CGFloat)self.movieRefreshTotal;
        }
        progressPercent = MIN(1.0, MAX(0.0, progressPercent)); // Clamp between 0 and 1
        
        // Draw progress fill
        if (progressPercent > 0) {
            NSRect progressFillRect = NSMakeRect(
                progressBarRect.origin.x,
                progressBarRect.origin.y,
                progressBarRect.size.width * progressPercent,
                progressBarRect.size.height
            );
            
            [[NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.2 alpha:1.0] set];
            NSBezierPath *progressFillPath = [NSBezierPath bezierPathWithRoundedRect:progressFillRect xRadius:5 yRadius:5];
            [progressFillPath fill];
        }
        
        // Draw progress text
        NSMutableParagraphStyle *progressStyle = [[NSMutableParagraphStyle alloc] init];
        [progressStyle setAlignment:NSTextAlignmentCenter];
        
        NSDictionary *progressAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor whiteColor],
            NSParagraphStyleAttributeName: progressStyle
        };
        
        NSString *progressText = [NSString stringWithFormat:@"Refreshing... %ld/%ld (%.0f%%)", 
                                 (long)self.movieRefreshCompleted, 
                                 (long)self.movieRefreshTotal, 
                                 progressPercent * 100];
        
        NSRect progressTextRect = NSMakeRect(
            progressBarRect.origin.x, 
            progressBarRect.origin.y + (progressBarRect.size.height - 16) / 2, 
            progressBarRect.size.width, 
            16
        );
        
        [progressText drawInRect:progressTextRect withAttributes:progressAttrs];
        
        // Store the progress bar rect for reference
        self.movieInfoProgressBarRect = progressBarRect;
        
        [progressStyle release];
    } else {
        // Draw normal button
        [[NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.6 alpha:1.0] set];
        NSBezierPath *buttonPath = [NSBezierPath bezierPathWithRoundedRect:refreshButtonRect xRadius:5 yRadius:5];
        [buttonPath fill];
        
        // Draw button text
        NSMutableParagraphStyle *buttonStyle = [[NSMutableParagraphStyle alloc] init];
        [buttonStyle setAlignment:NSTextAlignmentCenter];
        
        NSDictionary *buttonAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor whiteColor],
            NSParagraphStyleAttributeName: buttonStyle
        };
        
        NSRect buttonTextRect = NSMakeRect(
            refreshButtonRect.origin.x, 
            refreshButtonRect.origin.y + (refreshButtonRect.size.height - 20) / 2, 
            refreshButtonRect.size.width, 
            20
        );
        
        [@"Refresh All Movie Info & Covers" drawInRect:buttonTextRect withAttributes:buttonAttrs];
        
        // Store the button rect for click handling
        self.movieInfoRefreshButtonRect = refreshButtonRect;
        
        [buttonStyle release];
    }
    
    [style release];
}

// Add a debug method to visualize channel list boundaries
- (void)drawChannelListBoundaries:(NSRect)rect {
    // Define exact boundaries for the channel list area
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    
    // Calculate channelListWidth dynamically to match the UI layout
    CGFloat programGuideWidth = 350; // Width reserved for program guide
    CGFloat channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
    
    // Calculate the exact start and end points of channel list
    CGFloat channelListStartX = catWidth + groupWidth;
    CGFloat channelListEndX = channelListStartX + channelListWidth;
    
    // Draw vertical lines at the boundaries
    NSBezierPath *leftBoundary = [NSBezierPath bezierPath];
    [leftBoundary moveToPoint:NSMakePoint(channelListStartX, 0)];
    [leftBoundary lineToPoint:NSMakePoint(channelListStartX, self.bounds.size.height)];
    [[NSColor greenColor] set];
    [leftBoundary setLineWidth:2.0];
    [leftBoundary stroke];
    
    NSBezierPath *rightBoundary = [NSBezierPath bezierPath];
    [rightBoundary moveToPoint:NSMakePoint(channelListEndX, 0)];
    [rightBoundary lineToPoint:NSMakePoint(channelListEndX, self.bounds.size.height)];
    [[NSColor redColor] set];
    [rightBoundary setLineWidth:2.0];
    [rightBoundary stroke];
    
    // Draw labels
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: style
    };
    
    NSString *leftLabel = @"Channel List Start";
    NSString *rightLabel = @"Channel List End";
    
    [leftLabel drawInRect:NSMakeRect(channelListStartX - 80, self.bounds.size.height - 30, 160, 20) 
          withAttributes:attrs];
    [rightLabel drawInRect:NSMakeRect(channelListEndX - 80, self.bounds.size.height - 30, 160, 20) 
          withAttributes:attrs];
    
    [style release];
}

#pragma mark - Player Controls
/*
// Method to handle clicks on the player controls
- (BOOL)handlePlayerControlsClickAtPoint:(NSPoint)point {
    // First check if the click is within the overall player controls area
    if (!NSPointInRect(point, self.playerControlsRect)) {
        return NO;
    }
    
    // Check if click is on the progress bar
    if (NSPointInRect(point, self.progressBarRect)) {
        // Calculate the position relative to the progress bar
        CGFloat relativeX = point.x - self.progressBarRect.origin.x;
        CGFloat relativePosition = relativeX / self.progressBarRect.size.width;
        relativePosition = MIN(1.0, MAX(0.0, relativePosition)); // Clamp between 0 and 1
        
        // Get total duration
        VLCTime *totalTime = [self.player.media length];
        if (totalTime && [totalTime intValue] > 0) {
            // Calculate new position in milliseconds
            int newPositionMs = (int)([totalTime intValue] * relativePosition);
            
            // Create a VLCTime object with the new position
            VLCTime *newTime = [VLCTime timeWithInt:newPositionMs];
            
            // Set the player to the new position
            [self.player setTime:newTime];
            
            // Force an immediate redraw of the controls
            [self setNeedsDisplay:YES];
            
            // Reset the auto-hide timer when user interacts with controls
            if (playerControlsTimer) {
                [playerControlsTimer invalidate];
            }
            playerControlsTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                            target:self
                                                          selector:@selector(hidePlayerControls:)
                                                          userInfo:nil
                                                           repeats:NO];
        }
        
        return YES; // Indicate we handled the click
    }
    
    // If click was on controls but not on progress bar, just show/hide controls
    //[self togglePlayerControls];
    return YES;
}
*/
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
      //  NSLog(@"Dropdown '%@': isOpen=%@, items=%ld", identifier, dropdown.isOpen ? @"YES" : @"NO", [dropdown.items count]);
    }
    
    // Use the new dropdown manager to draw all dropdowns
    [self.dropdownManager drawAllDropdowns:rect];
    //NSLog(@"Finished drawing dropdowns");
}

// Handle dropdown hover states
- (void)handleDropdownHover:(NSPoint)point {
    NSInteger prevHoveredIndex = self.epgTimeOffsetDropdownHoveredIndex;
    
    // Check EPG Time Offset dropdown hover
    if (self.epgTimeOffsetDropdownActive) {
        NSInteger hoveredIndex = [self getDropdownOptionIndexAtPoint:point 
                                                        dropdownRect:self.epgTimeOffsetDropdownRect 
                                                         optionCount:25]; // -12 to +12 = 25 options
        
        // Convert from 0-based index to -12..+12 range
        if (hoveredIndex >= 0 && hoveredIndex < 25) {
            self.epgTimeOffsetDropdownHoveredIndex = hoveredIndex - 12; // Convert to -12..+12 range
        } else {
            self.epgTimeOffsetDropdownHoveredIndex = -1; // No hover
        }
    } else {
        self.epgTimeOffsetDropdownHoveredIndex = -1; // No hover when dropdown not active
    }
    
    // Redraw if hover state changed
    if (prevHoveredIndex != self.epgTimeOffsetDropdownHoveredIndex) {
        [self setNeedsDisplay:YES];
    }
}

#pragma mark - Reusable Dropdown Helper Methods

// Reusable dropdown rendering method
- (void)drawDropdownWithRect:(NSRect)dropdownRect 
                 optionValues:(NSArray *)values 
               selectedIndex:(NSInteger)selectedIndex 
                hoveredIndex:(NSInteger)hoveredIndex
                formatBlock:(NSString *(^)(id value))formatBlock {
    if (!values || [values count] == 0) return;
    
    CGFloat optionHeight = 25;
    CGFloat dropdownOptionsHeight = [values count] * optionHeight;
    NSRect dropdownOptionsRect = NSMakeRect(dropdownRect.origin.x,
                                           dropdownRect.origin.y - dropdownOptionsHeight,
                                           dropdownRect.size.width,
                                           dropdownOptionsHeight);
    
    // Add shadow effect first
    NSRect shadowRect = NSOffsetRect(dropdownOptionsRect, 2, -2);
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.3] set];
    NSRectFill(shadowRect);
    
    // Semi-transparent background for options with high alpha for visibility
    [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:0.98] set];
    NSRectFill(dropdownOptionsRect);
    
    // Strong border for options
    [[NSColor colorWithCalibratedRed:0.5 green:0.5 blue:0.5 alpha:1.0] set];
    NSFrameRect(dropdownOptionsRect);
    
    // Text style
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    // Draw each option
    for (NSInteger i = 0; i < [values count]; i++) {
        NSRect optionRect = NSMakeRect(dropdownOptionsRect.origin.x,
                                      dropdownOptionsRect.origin.y + (([values count] - 1 - i) * optionHeight),
                                      dropdownOptionsRect.size.width,
                                      optionHeight);
        
        // Determine colors based on state
        NSColor *bgColor = nil;
        NSColor *textColor = [NSColor lightGrayColor];
        
        if (i == selectedIndex && i == hoveredIndex) {
            // Both selected and hovered
            bgColor = [NSColor colorWithCalibratedRed:0.4 green:0.6 blue:0.9 alpha:0.9];
            textColor = [NSColor whiteColor];
        } else if (i == selectedIndex) {
            // Selected but not hovered
            bgColor = [NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.7 alpha:0.8];
            textColor = [NSColor whiteColor];
        } else if (i == hoveredIndex) {
            // Hovered but not selected
            bgColor = [NSColor colorWithCalibratedRed:0.25 green:0.25 blue:0.25 alpha:0.8];
            textColor = [NSColor whiteColor];
        }
        
        // Fill background if needed
        if (bgColor) {
            [bgColor set];
            NSRectFill(optionRect);
        }
        
        // Option text
        id value = [values objectAtIndex:i];
        NSString *optionText = formatBlock ? formatBlock(value) : [value description];
        
        NSDictionary *optionAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName: textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSRect optionTextRect = NSMakeRect(optionRect.origin.x + 10,
                                          optionRect.origin.y + (optionHeight - 16) / 2,
                                          optionRect.size.width - 20,
                                          16);
        [optionText drawInRect:optionTextRect withAttributes:optionAttrs];
    }
    
    [style release];
}

// Method to get dropdown options rect
- (NSRect)getDropdownOptionsRect:(NSRect)dropdownRect optionCount:(NSInteger)optionCount {
    CGFloat optionHeight = 25;
    CGFloat dropdownOptionsHeight = optionCount * optionHeight;
    return NSMakeRect(dropdownRect.origin.x,
                     dropdownRect.origin.y - dropdownOptionsHeight,
                     dropdownRect.size.width,
                     dropdownOptionsHeight);
}

// Method to find which dropdown option is at a given point
- (NSInteger)getDropdownOptionIndexAtPoint:(NSPoint)point dropdownRect:(NSRect)dropdownRect optionCount:(NSInteger)optionCount {
    NSRect dropdownOptionsRect = [self getDropdownOptionsRect:dropdownRect optionCount:optionCount];
    
    if (!NSPointInRect(point, dropdownOptionsRect)) {
        return -1; // Not in dropdown area
    }
    
    CGFloat optionHeight = 25;
    CGFloat relativeY = point.y - dropdownOptionsRect.origin.y;
    NSInteger optionIndex = (NSInteger)(relativeY / optionHeight);
    
    // Convert to proper index (reverse order since we draw from top to bottom)
    optionIndex = (optionCount - 1) - optionIndex;
    
    if (optionIndex >= 0 && optionIndex < optionCount) {
        return optionIndex;
    }
    
    return -1;
}




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

- (void)drawPlaylistSettingsWithComponents:(NSRect)rect x:(CGFloat)x width:(CGFloat)width {
    // Check if settings panel should be visible (both menu and settings category must be visible)
    BOOL settingsVisible = (self.isChannelListVisible && self.selectedCategoryIndex == CATEGORY_SETTINGS);
    
    // Update UI components visibility (this is also called from main drawRect, but ensure it's current)
    [self updateUIComponentsVisibility];
    
    // If settings are not visible, return early
    if (!settingsVisible) {
        return;
    }
    
    // Improved layout with better padding and spacing
    CGFloat padding = 30;
    CGFloat fieldHeight = 35;
    CGFloat labelHeight = 22;
    CGFloat verticalSpacing = 15;
    CGFloat sectionSpacing = 25;
    CGFloat startY = self.bounds.size.height - 80;
    CGFloat fieldWidth = width - (padding * 2);
    
    // Draw a section title with better styling
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:18],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect titleRect = NSMakeRect(x + padding, startY, fieldWidth, labelHeight + 5);
    [@"Playlist Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    CGFloat currentY = startY - (labelHeight + sectionSpacing);
    
    // M3U URL Label with better styling
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:15],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: style
    };
    
    NSRect m3uLabelRect = NSMakeRect(x + padding, currentY, fieldWidth, labelHeight);
    [@"M3U Playlist URL:" drawInRect:m3uLabelRect withAttributes:labelAttrs];
    currentY -= (labelHeight + verticalSpacing);
    
    // Create or update M3U text field
    NSRect m3uFieldRect = NSMakeRect(x + padding, currentY, fieldWidth, fieldHeight);
    if (!self.m3uTextField) {
        self.m3uTextField = [[VLCReusableTextField alloc] initWithFrame:m3uFieldRect identifier:@"m3u"];
        self.m3uTextField.textFieldDelegate = self;
        [self.m3uTextField setPlaceholderText:@"Enter M3U playlist URL..."];
        // Don't add to subview here - will be managed by updateUIComponentsVisibility
    } else {
        [self.m3uTextField setFrame:m3uFieldRect];
    }
    
    // Always set the current value from saved settings (fix for immediate display)
    NSString *currentM3uValue = @"";
    if (self.m3uFilePath && [self.m3uFilePath length] > 0) {
        // Use the saved M3U file path
        currentM3uValue = self.m3uFilePath;
    } else if (self.tempM3uUrl && [self.tempM3uUrl length] > 0) {
        // Fallback to temp URL if no saved path
        currentM3uValue = self.tempM3uUrl;
    }
    // Only set text value if the field is not currently being edited
    if (!self.m3uTextField.isActive) {
        [self.m3uTextField setTextValue:currentM3uValue];
    }
    
    // Auto-generate EPG URL if M3U URL exists but EPG URL is missing
    if (currentM3uValue && [currentM3uValue length] > 0 && (!self.epgUrl || [self.epgUrl length] == 0)) {
        NSString *generatedEpgUrl = [self generateEpgUrlFromM3uUrl:currentM3uValue];
        if (generatedEpgUrl && [generatedEpgUrl length] > 0) {
            self.epgUrl = generatedEpgUrl;
        }
    }
    
    currentY -= (fieldHeight + sectionSpacing);
    
    // EPG URL Label
    NSRect epgLabelRect = NSMakeRect(x + padding, currentY, fieldWidth, labelHeight);
    [@"EPG URL (auto-generated, click to copy):" drawInRect:epgLabelRect withAttributes:labelAttrs];
    currentY -= (labelHeight + verticalSpacing);
    
    // Create or update EPG clickable label (without visible frame)
    NSRect epgFieldRect = NSMakeRect(x + padding, currentY, fieldWidth, fieldHeight);
    if (!self.epgLabel) {
        self.epgLabel = [[VLCClickableLabel alloc] initWithFrame:epgFieldRect identifier:@"epg"];
        self.epgLabel.delegate = self;
        [self.epgLabel setPlaceholderText:@"EPG URL will be auto-generated from M3U URL"];
        // Don't add to subview here - will be managed by updateUIComponentsVisibility
    } else {
        [self.epgLabel setFrame:epgFieldRect];
    }
    
    // Set the current EPG URL
    NSString *currentEpgValue = self.epgUrl ? self.epgUrl : @"";
    [self.epgLabel setText:currentEpgValue];
    
    currentY -= (fieldHeight + sectionSpacing);
    
    // EPG Time Offset Label and Dropdown
    NSRect epgOffsetLabelRect = NSMakeRect(x + padding, currentY, fieldWidth, labelHeight);
    [@"EPG Time Offset:" drawInRect:epgOffsetLabelRect withAttributes:labelAttrs];
    currentY -= (labelHeight + verticalSpacing);
    
    // EPG Time Offset Dropdown with better width
    CGFloat dropdownWidth = 150;
    NSRect epgTimeOffsetDropdownRect = NSMakeRect(x + padding, currentY, dropdownWidth, fieldHeight);
    self.epgTimeOffsetDropdownRect = epgTimeOffsetDropdownRect;
    
    // Update dropdown frame in dropdown manager
    VLCDropdown *offsetDropdown = [self.dropdownManager dropdownWithIdentifier:@"EPGTimeOffset"];
    if (offsetDropdown) {
        offsetDropdown.frame = epgTimeOffsetDropdownRect;
    }
    
    // Draw dropdown background
    NSColor *dropdownBgColor = [NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0];
    [dropdownBgColor set];
    NSBezierPath *dropdownBgPath = [NSBezierPath bezierPathWithRoundedRect:epgTimeOffsetDropdownRect xRadius:3 yRadius:3];
    [dropdownBgPath fill];
    
    // Draw dropdown border
    NSColor *dropdownBorderColor = [NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:1.0];
    [dropdownBorderColor set];
    NSBezierPath *dropdownBorderPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(epgTimeOffsetDropdownRect, 0.5, 0.5) xRadius:3 yRadius:3];
    [dropdownBorderPath setLineWidth:1.0];
    [dropdownBorderPath stroke];
    
    // Draw dropdown text
    NSString *offsetText = [NSString stringWithFormat:@"%+d hours", (int)self.epgTimeOffsetHours];
    NSRect dropdownTextRect = NSMakeRect(epgTimeOffsetDropdownRect.origin.x + 5, 
                                        epgTimeOffsetDropdownRect.origin.y + 7, 
                                        epgTimeOffsetDropdownRect.size.width - 20, 
                                        epgTimeOffsetDropdownRect.size.height - 14);
    [offsetText drawInRect:dropdownTextRect withAttributes:labelAttrs];
    
    // Draw dropdown arrow
    NSRect arrowRect = NSMakeRect(epgTimeOffsetDropdownRect.origin.x + epgTimeOffsetDropdownRect.size.width - 15,
                                 epgTimeOffsetDropdownRect.origin.y + 10,
                                 10, 10);
    NSBezierPath *arrowPath = [NSBezierPath bezierPath];
    [arrowPath moveToPoint:NSMakePoint(arrowRect.origin.x, arrowRect.origin.y + 3)];
    [arrowPath lineToPoint:NSMakePoint(arrowRect.origin.x + 5, arrowRect.origin.y + 8)];
    [arrowPath lineToPoint:NSMakePoint(arrowRect.origin.x + 10, arrowRect.origin.y + 3)];
    [[NSColor lightGrayColor] set];
    [arrowPath setLineWidth:1.5];
    [arrowPath stroke];
    
    currentY -= (fieldHeight + sectionSpacing);
    
    // Buttons row with improved spacing
    CGFloat buttonWidth = 130;
    CGFloat buttonHeight = 40;
    CGFloat buttonSpacing = 20;
    
    // Load button
    NSRect loadButtonRect = NSMakeRect(x + padding, currentY, buttonWidth, buttonHeight);
    self.loadButtonRect = loadButtonRect;
    
    // Draw load button background
    NSColor *loadButtonColor = [NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.7 alpha:1.0];
    [loadButtonColor set];
    NSBezierPath *loadButtonPath = [NSBezierPath bezierPathWithRoundedRect:loadButtonRect xRadius:5 yRadius:5];
    [loadButtonPath fill];
    
    // Draw load button text with centered alignment
    NSMutableParagraphStyle *buttonStyle = [[NSMutableParagraphStyle alloc] init];
    [buttonStyle setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *buttonTextAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:14],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: buttonStyle
    };
    
    NSRect loadButtonTextRect = NSMakeRect(loadButtonRect.origin.x, loadButtonRect.origin.y + 10, 
                                          loadButtonRect.size.width, loadButtonRect.size.height - 20);
    [@"Load Playlist" drawInRect:loadButtonTextRect withAttributes:buttonTextAttrs];
    
    // Update EPG button
    NSRect epgButtonRect = NSMakeRect(x + padding + buttonWidth + buttonSpacing, currentY, buttonWidth, buttonHeight);
    self.epgButtonRect = epgButtonRect;
    
    // Draw EPG button background
    NSColor *epgButtonColor = [NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.3 alpha:1.0];
    [epgButtonColor set];
    NSBezierPath *epgButtonPath = [NSBezierPath bezierPathWithRoundedRect:epgButtonRect xRadius:5 yRadius:5];
    [epgButtonPath fill];
    
    // Draw EPG button text
    NSRect epgButtonTextRect = NSMakeRect(epgButtonRect.origin.x, epgButtonRect.origin.y + 10, 
                                         epgButtonRect.size.width, epgButtonRect.size.height - 20);
    [@"Update EPG" drawInRect:epgButtonTextRect withAttributes:buttonTextAttrs];
    
    [buttonStyle release];
    [style release];
}

- (void)hideControls {
    // Remove all UI components from view hierarchy
    if (self.m3uTextField && [self.m3uTextField superview] != nil) {
        [self.m3uTextField removeFromSuperview];
    }
    if (self.epgLabel && [self.epgLabel superview] != nil) {
        [self.epgLabel removeFromSuperview];
    }
    
    // Also hide any other UI components that might be visible
    // This ensures a clean slate before showing the menu
}

- (void)updateUIComponentsVisibility {
    // Check if settings panel should be visible (both menu and settings category must be visible)
    BOOL settingsVisible = (self.isChannelListVisible && self.selectedCategoryIndex == CATEGORY_SETTINGS);
    
    if (settingsVisible) {
        // Add components to view if they're not already added
        if (self.m3uTextField && [self.m3uTextField superview] == nil) {
            [self addSubview:self.m3uTextField];
        }
        if (self.epgLabel && [self.epgLabel superview] == nil) {
            [self addSubview:self.epgLabel];
        }
    } else {
        // Remove components from view
        if (self.m3uTextField && [self.m3uTextField superview] != nil) {
            [self.m3uTextField removeFromSuperview];
        }
        if (self.epgLabel && [self.epgLabel superview] != nil) {
            [self.epgLabel removeFromSuperview];
        }
    }
}

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
            
            NSLog(@"EPG time offset changed to: %ld hours", (long)self.epgTimeOffsetHours);
            
            // Save settings
            if ([self respondsToSelector:@selector(saveSettings)]) {
                [self saveSettings];
            }
            
            // Refresh display
            [self setNeedsDisplay:YES];
        }
    };
}

#pragma mark - VLCReusableTextFieldDelegate

- (void)textFieldDidChange:(NSString *)newValue forIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:@"m3u"]) {
        // Check if the value actually changed from the previous temp value
        BOOL valueChanged = ![newValue isEqualToString:self.tempM3uUrl];
        
        // Update the M3U file path as user types
        self.tempM3uUrl = newValue;
        
        // Always auto-generate EPG URL when M3U URL actually changes (real-time updates while typing)
        // Only when the text field is actually active (being edited by user)
        if (valueChanged && self.m3uTextField.isActive) {
            NSString *generatedEpgUrl = [self generateEpgUrlFromM3uUrl:newValue];
            if (generatedEpgUrl && [generatedEpgUrl length] > 0) {
                self.epgUrl = generatedEpgUrl;
                [self.epgLabel setText:generatedEpgUrl];
                
                // Trigger a redraw to update the display
                [self setNeedsDisplay:YES];
            } else if (!newValue || [newValue length] == 0) {
                // Clear EPG URL if M3U URL is empty
                self.epgUrl = @"";
                [self.epgLabel setText:@""];
                [self setNeedsDisplay:YES];
            }
        }
    }
}

- (void)textFieldDidEndEditing:(NSString *)finalValue forIdentifier:(NSString *)identifier {
    NSLog(@"textFieldDidEndEditing called with finalValue: '%@' for identifier: '%@'", finalValue, identifier);
    if ([identifier isEqualToString:@"m3u"]) {
        // Update the M3U file path
        if (finalValue && [finalValue length] > 0) {
            // Ensure URL has proper prefix
            NSString *urlToSave = finalValue;
            if (![urlToSave hasPrefix:@"http://"] && ![urlToSave hasPrefix:@"https://"]) {
                urlToSave = [@"http://" stringByAppendingString:urlToSave];
            }
            
            self.m3uFilePath = urlToSave;
            self.tempM3uUrl = urlToSave;
            
            // Always auto-generate EPG URL when M3U URL is finalized (regardless of current EPG URL)
            NSString *generatedEpgUrl = [self generateEpgUrlFromM3uUrl:urlToSave];
            if (generatedEpgUrl && [generatedEpgUrl length] > 0) {
                self.epgUrl = generatedEpgUrl;
                [self.epgLabel setText:generatedEpgUrl];
                NSLog(@"EPG URL auto-generated on M3U edit completion: %@", generatedEpgUrl);
            } else {
                self.epgUrl = @"";
                [self.epgLabel setText:@""];
                NSLog(@"EPG URL cleared - could not generate from M3U URL");
            }
            
            // Save settings
            if ([self respondsToSelector:@selector(saveSettings)]) {
                [self saveSettings];
            }
        } else {
            // Clear both M3U and EPG URLs if M3U is empty
            self.m3uFilePath = @"";
            self.tempM3uUrl = @"";
            self.epgUrl = @"";
            [self.epgLabel setText:@""];
            NSLog(@"M3U URL cleared - EPG URL also cleared");
        }
        
        // Force a redraw to update the EPG label display
        [self setNeedsDisplay:YES];
    }
}

- (void)textFieldDidBeginEditing:(NSString *)identifier {
    if ([identifier isEqualToString:@"m3u"]) {
        // Store original value for potential restoration and set temp value
        NSString *currentValue = self.m3uFilePath ? self.m3uFilePath : @"";
        self.tempM3uUrl = currentValue;
        
        // The text field should already have the correct value from when it was created/updated
        // Don't call setTextValue here as it can trigger unwanted delegate calls
    }
}

#pragma mark - VLCClickableLabelDelegate

- (void)clickableLabelWasClicked:(NSString *)identifier withText:(NSString *)text {
    if ([identifier isEqualToString:@"epg"]) {
        // Text is already copied to clipboard by the clickable label
        // Show a brief confirmation message
        [self setLoadingStatusText:@"EPG URL copied to clipboard"];
        
        // Clear the message after a short delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            if (gProgressMessageLock) {
                [gProgressMessageLock lock];
                [gProgressMessage release];
                gProgressMessage = nil;
                [gProgressMessageLock unlock];
            }
            [self setNeedsDisplay:YES];
        });
        
        [self setNeedsDisplay:YES];
    }
}

// Handle right-click on EPG programs
- (BOOL)handleEpgProgramRightClick:(NSPoint)point withEvent:(NSEvent *)event {
    // Only handle if we're hovering on a channel and EPG is visible
    if (self.hoveredChannelIndex < 0) {
        return NO;
    }
    
    // Calculate EPG panel boundaries (same as in drawProgramGuideForHoveredChannel)
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat channelListX = catWidth + groupWidth;
    CGFloat programGuideWidth = 400;
    CGFloat channelListWidth = self.bounds.size.width - channelListX - programGuideWidth;
    CGFloat guidePanelX = channelListX + channelListWidth;
    CGFloat guidePanelWidth = programGuideWidth;
    CGFloat guidePanelHeight = self.bounds.size.height;
    
    // Check if click is within EPG panel
    if (point.x < guidePanelX || point.x > guidePanelX + guidePanelWidth) {
        return NO;
    }
    
    // Get the hovered channel
    VLCChannel *channel = [self getChannelAtHoveredIndex];
    if (!channel || !channel.programs || [channel.programs count] == 0) {
        return NO;
    }
    
    NSLog(@"EPG Right-click detected on channel: %@ (hoveredChannelIndex: %ld)", 
          channel.name, (long)self.hoveredChannelIndex);
    
    // Sort programs by start time (same as in drawing code)
    NSArray *sortedPrograms = [channel.programs sortedArrayUsingComparator:^NSComparisonResult(VLCProgram *a, VLCProgram *b) {
        return [a.startTime compare:b.startTime];
    }];
    
    // Calculate which program was clicked
    CGFloat entryHeight = 65;
    CGFloat entrySpacing = 8;
    
    for (NSInteger i = 0; i < [sortedPrograms count]; i++) {
        VLCProgram *program = [sortedPrograms objectAtIndex:i];
        
        // Calculate Y position for this item (same calculation as in drawing code)
        CGFloat itemY = guidePanelHeight - ((i + 1) * (entryHeight + entrySpacing)) + self.epgScrollPosition;
        
        // Skip items that are completely outside the visible area
        if (itemY + entryHeight < 0 || itemY > guidePanelHeight) {
            continue;
        }
        
        // Create the program entry rect
        NSRect entryRect = NSMakeRect(
            guidePanelX + 10,
            itemY,
            guidePanelWidth - 20,
            entryHeight
        );
        
        // Check if click is within this program's rect
        if (NSPointInRect(point, entryRect)) {
            // Store the clicked program and channel for the context menu
            rightClickedProgram = program;
            rightClickedProgramChannel = channel;
            
            // Show context menu for this program
            [self showContextMenuForProgram:program channel:channel atPoint:point withEvent:event];
            return YES;
        }
    }
    
    return NO;
}

// Show context menu for EPG program
- (void)showContextMenuForProgram:(VLCProgram *)program channel:(VLCChannel *)channel atPoint:(NSPoint)point withEvent:(NSEvent *)event {
    NSLog(@"Creating EPG context menu for program: %@ on channel: %@", program.title, channel.name);
    
    NSMenu *menu = [[NSMenu alloc] init];
    
    // Add program title as header (disabled)
    NSString *programTitle = program.title ? program.title : @"Unknown Program";
    if ([programTitle length] > 40) {
        programTitle = [[programTitle substringToIndex:37] stringByAppendingString:@"..."];
    }
    
    NSMenuItem *titleItem = [[NSMenuItem alloc] initWithTitle:programTitle 
                                                      action:nil 
                                               keyEquivalent:@""];
    [titleItem setEnabled:NO]; // Disabled, just for display
    [menu addItem:titleItem];
    [titleItem release];
    
    // Add separator
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Check if catch-up is available for this program
    if (program.hasArchive) {
        // Add "Play CatchUp" option
        NSMenuItem *catchupItem = [[NSMenuItem alloc] initWithTitle:@"Play CatchUp" 
                                                            action:@selector(playCatchUpFromMenu:) 
                                                     keyEquivalent:@""];
        [catchupItem setTarget:self];
        [catchupItem setRepresentedObject:program];
        [menu addItem:catchupItem];
        [catchupItem release];
    } else {
        // Add disabled "No CatchUp" option
        NSMenuItem *noCatchupItem = [[NSMenuItem alloc] initWithTitle:@"No CatchUp" 
                                                              action:nil 
                                                       keyEquivalent:@""];
        [noCatchupItem setEnabled:NO];
        [menu addItem:noCatchupItem];
        [noCatchupItem release];
    }
    
    // Add separator
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Add "Play Channel" option
    NSMenuItem *playChannelItem = [[NSMenuItem alloc] initWithTitle:@"Play Channel" 
                                                            action:@selector(playChannelFromEpgMenu:) 
                                                     keyEquivalent:@""];
    [playChannelItem setTarget:self];
    [playChannelItem setRepresentedObject:channel];
    [menu addItem:playChannelItem];
    [playChannelItem release];
    
    // Show the menu
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    [menu release];
}

// Handle "Play CatchUp" menu action
- (void)playCatchUpFromMenu:(NSMenuItem *)sender {
    VLCProgram *program = [sender representedObject];
    if (program && rightClickedProgramChannel) {
        NSLog(@"Playing catch-up for program: %@ on channel: %@", program.title, rightClickedProgramChannel.name);
        
        // Generate timeshift URL for the program
        NSString *timeshiftUrl = [self generateTimeshiftUrlForProgram:program channel:rightClickedProgramChannel];
        
        if (timeshiftUrl) {
            NSLog(@"Generated timeshift URL: %@", timeshiftUrl);
            
            // Stop current playback
            if (self.player) {
                [self saveCurrentPlaybackPosition];
                [self.player stop];
            }
            
            // Brief pause to allow VLC to reset
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Create media object with timeshift URL
                NSURL *url = [NSURL URLWithString:timeshiftUrl];
                VLCMedia *media = [VLCMedia mediaWithURL:url];
                
                // Set the media to the player
                [self.player setMedia:media];
                
                // Apply subtitle settings
                if ([VLCSubtitleSettings respondsToSelector:@selector(applyCurrentSettingsToPlayer:)]) {
                    [VLCSubtitleSettings applyCurrentSettingsToPlayer:self.player];
                }
                
                // Start playing
                [self.player play];
                
                NSLog(@"Started timeshift playback for program: %@", program.title);
                
                // Force UI update
                [self setNeedsDisplay:YES];
            });
            
            // Save the timeshift URL as last played for resume functionality
            [self saveLastPlayedChannelUrl:timeshiftUrl];
            
            // Create a temporary channel object for timeshift content
            VLCChannel *timeshiftChannel = [[VLCChannel alloc] init];
            timeshiftChannel.name = [NSString stringWithFormat:@"%@ (Timeshift: %@)", rightClickedProgramChannel.name, program.title];
            timeshiftChannel.url = timeshiftUrl;
            timeshiftChannel.channelId = rightClickedProgramChannel.channelId;
            timeshiftChannel.group = rightClickedProgramChannel.group;
            timeshiftChannel.category = rightClickedProgramChannel.category;
            timeshiftChannel.logo = rightClickedProgramChannel.logo;
            
            // Add program info to the timeshift channel
            timeshiftChannel.programs = [NSMutableArray arrayWithObject:program];
            
            [self saveLastPlayedContentInfo:timeshiftChannel];
            [timeshiftChannel release];
            
            // Hide the channel list after starting playback
            [self hideChannelListWithFade];
        } else {
            NSLog(@"Failed to generate timeshift URL for program: %@", program.title);
            
            // Show a brief error message
            [self setLoadingStatusText:@"Error: Could not generate timeshift URL"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    [gProgressMessage release];
                    gProgressMessage = nil;
                    [gProgressMessageLock unlock];
                }
                [self setNeedsDisplay:YES];
            });
        }
        
        // Clear the stored references
        rightClickedProgram = nil;
        rightClickedProgramChannel = nil;
    }
}

// Handle "Play Channel" menu action from EPG context menu
- (void)playChannelFromEpgMenu:(NSMenuItem *)sender {
    VLCChannel *channel = [sender representedObject];
    if (channel) {
        NSLog(@"EPG Context Menu - Playing channel: %@ (URL: %@)", channel.name, channel.url);
        NSLog(@"EPG Context Menu - rightClickedProgramChannel: %@ (URL: %@)", 
              rightClickedProgramChannel ? rightClickedProgramChannel.name : @"nil",
              rightClickedProgramChannel ? rightClickedProgramChannel.url : @"nil");
        
        // Use the stored rightClickedProgramChannel to ensure we play the correct channel
        // This is more reliable than the representedObject
        VLCChannel *channelToPlay = rightClickedProgramChannel ? rightClickedProgramChannel : channel;
        
        if (channelToPlay) {
            // Play the channel
            [self playChannelWithUrl:channelToPlay.url];
            
            // Find the index of this channel in the current group to update selectedChannelIndex
            NSInteger channelIndex = [self findChannelIndexForChannel:channelToPlay];
            if (channelIndex >= 0) {
                self.selectedChannelIndex = channelIndex;
                NSLog(@"Updated selectedChannelIndex to: %ld for channel: %@", (long)channelIndex, channelToPlay.name);
            } else {
                NSLog(@"Warning: Could not find channel index for: %@", channelToPlay.name);
            }
            
            // Refresh the EPG information and update the display
            [self refreshCurrentEPGInfo];
            
            // Force redraw to update the program control panel
            [self setNeedsDisplay:YES];
        }
        
        // Clear the stored references
        rightClickedProgram = nil;
        rightClickedProgramChannel = nil;
    }
}

// Helper method to find the index of a channel in the current group
- (NSInteger)findChannelIndexForChannel:(VLCChannel *)targetChannel {
    if (!targetChannel) {
        return -1;
    }
    
    // Get the current group's channels
    NSArray *groups = nil;
    NSString *currentCategory = nil;
    
    if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
        currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
        
        if ([currentCategory isEqualToString:@"FAVORITES"]) {
            groups = [self safeGroupsForCategory:@"FAVORITES"];
        } else if ([currentCategory isEqualToString:@"TV"]) {
            groups = [self safeTVGroups];
        } else if ([currentCategory isEqualToString:@"MOVIES"]) {
            groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
        } else if ([currentCategory isEqualToString:@"SERIES"]) {
            groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
        }
    }
    
    // Get the current group
    if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
        NSString *currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
        
        // Get channels for this group
        NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
        if (channelsInGroup) {
            // Find the target channel in this group
            for (NSInteger i = 0; i < channelsInGroup.count; i++) {
                VLCChannel *channel = [channelsInGroup objectAtIndex:i];
                if ([channel.url isEqualToString:targetChannel.url] || 
                    [channel.name isEqualToString:targetChannel.name]) {
                    return i;
                }
            }
        }
    }
    
    return -1;
}

@end
