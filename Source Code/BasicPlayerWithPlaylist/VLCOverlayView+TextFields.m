#import "VLCOverlayView+TextFields.h"

#if TARGET_OS_OSX
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+PlayerControls.h"
#import "VLCSubtitleSettings.h"
#import <objc/runtime.h>
#import "VLCOverlayView+Utilities.h"
#import "VLCOverlayView+Glassmorphism.h"
#import <math.h>
#import "VLCSliderControl.h"
#import "VLCOverlayView+Globals.h"

@implementation VLCOverlayView (TextFields)


#pragma mark - VLCReusableTextFieldDelegate

- (void)textFieldDidChange:(NSString *)newValue forIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:@"search"]) {
        [self performSearch:newValue];
    } else if ([identifier isEqualToString:@"m3u"]) {
        // Update M3U file path
        self.m3uFilePath = newValue;
        
        // Auto-generate EPG URL from M3U URL
        NSString *generatedEpgUrl = [self generateEpgUrlFromM3uUrl:newValue];
        if (generatedEpgUrl && [generatedEpgUrl length] > 0) {
            self.epgUrl = generatedEpgUrl;
        }
        
        // Refresh the EPG label display
        [self setNeedsDisplay:YES];
    }
}

- (void)textFieldDidEndEditing:(NSString *)finalValue forIdentifier:(NSString *)identifier {
    if ([identifier isEqualToString:@"search"]) {
        [self performSearch:finalValue];
    } else if ([identifier isEqualToString:@"m3u"]) {
        // Update M3U file path
        self.m3uFilePath = finalValue;
        
        // Auto-generate EPG URL from M3U URL  
        NSString *generatedEpgUrl = [self generateEpgUrlFromM3uUrl:finalValue];
        if (generatedEpgUrl && [generatedEpgUrl length] > 0) {
            self.epgUrl = generatedEpgUrl;
        }
        
        // Save the M3U URL to preferences
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:finalValue forKey:@"M3UFilePath"];
        [defaults synchronize];
        
        // Refresh the EPG label display
        [self setNeedsDisplay:YES];
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
    
    // Draw glassmorphism panels for channel list and program guide
    NSRect menuRect = NSMakeRect(channelListX, 0, channelListWidth, self.bounds.size.height);
    [self drawGlassmorphismPanel:menuRect opacity:0.6 cornerRadius:0];
    
    // Draw program guide panel with glassmorphism
    CGFloat programGuideX = channelListX + channelListWidth;
    NSRect programGuideRect = NSMakeRect(programGuideX, 0, programGuideWidth, self.bounds.size.height);
    [self drawGlassmorphismPanel:programGuideRect opacity:0.5 cornerRadius:0];
    
    // Define the content rect for the channel list
    NSRect contentRect = NSMakeRect(channelListX, 0, channelListWidth, self.bounds.size.height);
    
    // Determine which channels to display
    NSArray *channelNames = nil;
    NSArray *channelUrls = nil;
    
    if (self.selectedCategoryIndex == CATEGORY_SEARCH && self.searchChannelResults && [self.searchChannelResults count] > 0) {
        // Use search channel results
        NSMutableArray *searchNames = [NSMutableArray array];
        NSMutableArray *searchUrls = [NSMutableArray array];
        
        for (VLCChannel *channel in self.searchChannelResults) {
            [searchNames addObject:channel.name ? channel.name : @""];
            [searchUrls addObject:channel.url ? channel.url : @""];
        }
        
        channelNames = searchNames;
        channelUrls = searchUrls;
    } else if (self.selectedCategoryIndex == CATEGORY_SEARCH) {
        // Search category but no results - show empty list
        channelNames = [NSArray array];
        channelUrls = [NSArray array];
    } else {
        // Use regular simple channel lists
        channelNames = self.simpleChannelNames;
        channelUrls = self.simpleChannelUrls;
    }
    
    // Calculate total content height
    CGFloat totalContentHeight = [channelNames count] * rowHeight;
    
    // Add extra space at bottom to ensure last item is fully visible when scrolled to the end
    totalContentHeight += rowHeight;
    
    // Update scroll limits to ensure last item is fully visible
    CGFloat maxScroll = MAX(0, totalContentHeight - contentRect.size.height);
    
    // Use appropriate scroll position based on search mode
    CGFloat currentScrollPosition;
    if (self.selectedCategoryIndex == CATEGORY_SEARCH) {
        currentScrollPosition = self.searchChannelScrollPosition;
    } else {
        currentScrollPosition = channelScrollPosition;
    }
    
    CGFloat scrollPosition = MIN(currentScrollPosition, maxScroll);
    
    // Draw each channel - removed header bar completely
    for (NSInteger i = 0; i < [channelNames count]; i++) {
        // Calculate the Y position for this item, accounting for scroll
        CGFloat itemY = contentRect.origin.y + contentRect.size.height - ((i + 1) * rowHeight) + scrollPosition;
        
        NSRect itemRect = NSMakeRect(channelListX, itemY, channelListWidth, rowHeight);
        
        // Skip drawing if not visible
        if (!NSIntersectsRect(itemRect, rect)) {
            continue;
        }
        
                // Highlight hovered or selected channel with glassmorphism effects
        if (i == self.hoveredChannelIndex || i == self.selectedChannelIndex) {
            NSRect buttonRect = NSInsetRect(itemRect, 4, 2);
            BOOL isHovered = (i == self.hoveredChannelIndex);
            BOOL isSelected = (i == self.selectedChannelIndex);
            
            //NSLog(@"🎨 DRAW DEBUG: Drawing highlight for item %ld - hovered: %@, selected: %@, hoveredChannelIndex: %ld", 
            //      (long)i, isHovered ? @"YES" : @"NO", isSelected ? @"YES" : @"NO", (long)self.hoveredChannelIndex);
            
            [self drawGlassmorphismButton:buttonRect 
                                     text:nil 
                                isHovered:isHovered 
                               isSelected:isSelected];
        }
        
        // Draw channel name
        NSString *channelName = [channelNames objectAtIndex:i];
        
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
        // CRITICAL FIX: Match iOS logic - check both supportsCatchup AND catchupDays > 0
        if (tempChannel && (tempChannel.supportsCatchup || tempChannel.catchupDays > 0)) {
            NSRect timeshiftIconRect = NSMakeRect(
                itemRect.origin.x + itemRect.size.width - 30, // Position on the right side
                itemRect.origin.y + (itemRect.size.height - 16) / 2 + 8, // Center vertically, slightly down
                16, 
                16
            );
            
            // Draw solid green background with full opacity (matching group style)
            [[NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.3 alpha:1.0] set];
            NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundedRect:timeshiftIconRect xRadius:3 yRadius:3];
            [backgroundPath fill];
            
            // Draw opaque white border for better visibility (matching group style)
            [[NSColor colorWithWhite:1.0 alpha:1.0] set];
            NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:timeshiftIconRect xRadius:3 yRadius:3];
            [borderPath setLineWidth:1.0];
            [borderPath stroke];
            
            // Draw the rewind symbol inside
            NSMutableParagraphStyle *iconStyle = [[NSMutableParagraphStyle alloc] init];
            [iconStyle setAlignment:NSTextAlignmentCenter];
            
            NSDictionary *iconAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:12], // Slightly smaller to fit in border
                NSForegroundColorAttributeName: [NSColor whiteColor],
                NSParagraphStyleAttributeName: iconStyle
            };
            
            // Use simple clock symbol to indicate catchup capability
            [@"⏱" drawInRect:timeshiftIconRect withAttributes:iconAttrs];
            [iconStyle release];
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
       // Draw search movie results in the program guide area if in search mode
    if (self.selectedCategoryIndex == CATEGORY_SEARCH && self.searchMovieResults && [self.searchMovieResults count] > 0) {
        [self drawSearchMovieResults:programGuideRect];
    }
    
    // Show program guide when hovering over a channel
    if (self.hoveredChannelIndex >= 0 && self.hoveredChannelIndex < [channelNames count]) {
        [self drawProgramGuideForHoveredChannel];
    }
    
    // Draw scroll bar
    [self drawScrollBar:contentRect contentHeight:totalContentHeight scrollPosition:scrollPosition];
}

- (void)drawLoadingIndicator:(NSRect)rect {
    // Debug: Log loading state for troubleshooting
    if (!self.isLoading) {
        return; // Don't draw anything if we're not in loading state
    }
    
    //NSLog(@"🎨 [MAC-PROGRESS] Drawing loading indicator - isLoading:%@ isLoadingEpg:%@ loadingProgress:%.2f epgProgress:%.2f", 
    //      self.isLoading ? @"YES" : @"NO", 
    //      self.isLoadingEpg ? @"YES" : @"NO", 
    //      self.loadingProgress, 
    //      self.epgLoadingProgress);
    
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
    
    // Draw title and loading text using new progress system
    NSString *titleText;
    
    // Determine if we're downloading or processing from the new status texts
    NSString *currentStatus = @"";
    if (self.isLoadingEpg && self.epgLoadingStatusText) {
        currentStatus = self.epgLoadingStatusText;
    } else if (self.loadingStatusText) {
        currentStatus = self.loadingStatusText;
    }
    
    if ([currentStatus containsString:@"Downloading"]) {
        titleText = @"Downloading...";
    } else if ([currentStatus containsString:@"Processing"]) {
        titleText = @"Processing...";
    } else if ([currentStatus containsString:@"Parsing"]) {
        titleText = @"Parsing...";
    } else if ([currentStatus containsString:@"completed"] || [currentStatus containsString:@"✅"]) {
        titleText = @"Complete";
    } else {
        titleText = @"Loading...";
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
    
    // Draw detail status text using new progress system
    NSString *statusText = @"";
    
    // Use the new structured progress texts instead of global variables
    if (self.isLoadingEpg && self.epgLoadingStatusText && [self.epgLoadingStatusText length] > 0) {
        statusText = self.epgLoadingStatusText;
    } else if (self.loadingStatusText && [self.loadingStatusText length] > 0) {
        statusText = self.loadingStatusText;
    } else {
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
            progressBarWidth * MIN(1.0, progressValue),
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
    
    // Draw percentage text on progress bar using new progress system
    NSString *percentText;
    
    // Get the current status text from the new system
    NSString *progressStatus = @"";
    if (self.isLoadingEpg && self.epgLoadingStatusText) {
        progressStatus = self.epgLoadingStatusText;
    } else if (self.loadingStatusText) {
        progressStatus = self.loadingStatusText;
    }
    
    if (progressValue > 0.0) {
        // Show detailed MB information if available
        if ([progressStatus containsString:@"MB"]) {
            percentText = progressStatus;  // Show the full MB details
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
    
    // Draw glassmorphism panel for EPG
    NSRect epgRect = NSMakeRect(epgPanelX, 0, epgPanelWidth, self.bounds.size.height);
    [self drawGlassmorphismPanel:epgRect opacity:0.6 cornerRadius:0];
    
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
    
    // Draw glassmorphism panel for settings
    NSRect settingsRect = NSMakeRect(settingsPanelX, 0, settingsPanelWidth, self.bounds.size.height);
    [self drawGlassmorphismPanel:settingsRect opacity:0.7 cornerRadius:0];
    
    // Only draw settings content if a settings group is selected
    NSArray *settingsGroups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
    
    if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < [settingsGroups count]) {
        NSString *selectedGroup = [settingsGroups objectAtIndex:self.selectedGroupIndex];
        
        if ([selectedGroup isEqualToString:@"Playlist"]) {
            // Draw Playlist settings
            [self drawPlaylistSettings:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"General"]) {
            // Draw General settings
            [self drawGeneralSettings:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"Subtitles"]) {
            // Draw Subtitle settings
            [self drawSubtitleSettings:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"Movie Info"]) {
            // Draw Movie Info settings
            [self drawMovieInfoSettings:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"Themes"]) {
            // Draw Theme settings
            [self drawThemeSettings:rect x:settingsPanelX width:settingsPanelWidth];
        }
    } else {
        // No group selected, show a helper message
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentCenter];
        
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
    [style release];
    }
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
        
        // Add to subview immediately since we're in the playlist settings
        if (![self.subviews containsObject:self.m3uTextField]) {
            [self addSubview:self.m3uTextField];
        }
        [self.m3uTextField setHidden:NO];
    } else {
        [self.m3uTextField setFrame:m3uFieldRect];
        
        // Ensure it's visible and added to subviews
        if (![self.subviews containsObject:self.m3uTextField]) {
            [self addSubview:self.m3uTextField];
        }
        [self.m3uTextField setHidden:NO];
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
        
        // Add to subview immediately since we're in the playlist settings
        if (![self.subviews containsObject:self.epgLabel]) {
            [self addSubview:self.epgLabel];
        }
        [self.epgLabel setHidden:NO];
    } else {
        [self.epgLabel setFrame:epgFieldRect];
        
        // Ensure it's visible and added to subviews
        if (![self.subviews containsObject:self.epgLabel]) {
            [self addSubview:self.epgLabel];
        }
        [self.epgLabel setHidden:NO];
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
    
    // Update dropdown frame in dropdown manager instead of manual drawing
    VLCDropdown *offsetDropdown = [self.dropdownManager dropdownWithIdentifier:@"EPGTimeOffset"];
    if (offsetDropdown) {
        offsetDropdown.frame = offsetDropdownRect;
    }
    
    // Render the closed dropdown state manually (VLCDropdownManager only handles open state)
    // Draw dropdown background
    [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0] set];
    NSRectFill(offsetDropdownRect);
    
    // Draw dropdown border
    [[NSColor grayColor] set];
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
    
    // Check if mouse is hovering over load button
    NSPoint mouseLocation = [[self window] mouseLocationOutsideOfEventStream];
    NSPoint localPoint = [self convertPoint:mouseLocation fromView:nil];
    BOOL isLoadButtonHovered = NSPointInRect(localPoint, loadButtonRect);
    
    // Draw load button background with hover and disabled states
    NSColor *loadButtonColor;
    if (self.isLoading) {
        loadButtonColor = [NSColor colorWithCalibratedRed:0.5 green:0.5 blue:0.5 alpha:0.6]; // Grayed out when disabled
    } else if (isLoadButtonHovered) {
        loadButtonColor = [NSColor colorWithCalibratedRed:0.25 green:0.45 blue:0.75 alpha:1.0]; // Lighter blue on hover
    } else {
        loadButtonColor = [NSColor colorWithCalibratedRed:0.2 green:0.4 blue:0.7 alpha:1.0]; // Normal blue
    }
    [loadButtonColor set];
    NSBezierPath *loadButtonPath = [NSBezierPath bezierPathWithRoundedRect:loadButtonRect xRadius:5 yRadius:5];
    [loadButtonPath fill];
    
    // Add subtle border on hover
    if (isLoadButtonHovered && !self.isLoading) {
        [[NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.8 alpha:0.8] set];
        [loadButtonPath setLineWidth:1.0];
        [loadButtonPath stroke];
    }
    
    // Draw load button text with centered alignment and proper font
    NSMutableParagraphStyle *buttonStyle = [[NSMutableParagraphStyle alloc] init];
    [buttonStyle setAlignment:NSTextAlignmentCenter];
    
    NSColor *buttonTextColor = self.isLoading ? [NSColor colorWithCalibratedWhite:0.8 alpha:0.6] : [NSColor whiteColor];
    NSDictionary *buttonTextAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13], // Removed bold and reduced size for better fit
        NSForegroundColorAttributeName: buttonTextColor,
        NSParagraphStyleAttributeName: buttonStyle
    };
    
    // Better text positioning to fit properly in button
    NSRect loadButtonTextRect = NSMakeRect(loadButtonRect.origin.x + 5, 
                                          loadButtonRect.origin.y + (loadButtonRect.size.height - 16) / 2, 
                                          loadButtonRect.size.width - 10, 
                                          16);
    [@"Load Playlist" drawInRect:loadButtonTextRect withAttributes:buttonTextAttrs];
    
    // Update EPG button
    NSRect epgButtonRect = NSMakeRect(x + padding + buttonWidth + buttonSpacing, buttonY, buttonWidth, buttonHeight);
    self.epgButtonRect = epgButtonRect;
    
    // Check if mouse is hovering over EPG button
    BOOL isEpgButtonHovered = NSPointInRect(localPoint, epgButtonRect);
    
    // Draw EPG button background with hover and disabled states
    NSColor *epgButtonColor;
    if (self.isLoading) {
        epgButtonColor = [NSColor colorWithCalibratedRed:0.5 green:0.5 blue:0.5 alpha:0.6]; // Grayed out when disabled
    } else if (isEpgButtonHovered) {
        epgButtonColor = [NSColor colorWithCalibratedRed:0.25 green:0.65 blue:0.35 alpha:1.0]; // Lighter green on hover
    } else {
        epgButtonColor = [NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.3 alpha:1.0]; // Normal green
    }
    [epgButtonColor set];
    NSBezierPath *epgButtonPath = [NSBezierPath bezierPathWithRoundedRect:epgButtonRect xRadius:5 yRadius:5];
    [epgButtonPath fill];
    
    // Add subtle border on hover
    if (isEpgButtonHovered && !self.isLoading) {
        [[NSColor colorWithCalibratedRed:0.3 green:0.7 blue:0.4 alpha:0.8] set];
        [epgButtonPath setLineWidth:1.0];
        [epgButtonPath stroke];
    }
    
    // Draw EPG button text with proper positioning
    NSRect epgButtonTextRect = NSMakeRect(epgButtonRect.origin.x + 5, 
                                         epgButtonRect.origin.y + (epgButtonRect.size.height - 16) / 2, 
                                         epgButtonRect.size.width - 10, 
                                         16);
    [@"Update EPG" drawInRect:epgButtonTextRect withAttributes:buttonTextAttrs];
    
    [style release];
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

@end 

#endif // TARGET_OS_OSX 
