#import "VLCOverlayView+PlayerControls.h"
#import "VLCOverlayView_Private.h"
#import "VLCSubtitleSettings.h"
#import <objc/runtime.h>

// Keys for associated objects
static char playerControlsRectKey;
static char progressBarRectKey;
static char playerControlsTimerKey;  // New key for the timer
static char timerTargetKey;          // Key for the timer target
static char refreshTimerKey;         // Key for refresh timer
static char refreshTimerTargetKey;   // Key for refresh timer target
static char subtitlesButtonRectKey;  // Key for subtitles dropdown button rect
static char audioButtonRectKey;      // Key for audio dropdown button rect
static char timeshiftSeekingKey;      // Key for timeshift seeking state
static char frozenTimeValuesKey;     // Key for frozen time values during seeking
static char lastHoverTextKey;        // Key for last hover text
static char timeshiftChannelKey;     // Key for cached timeshift channel object
static char tempEarlyPlaybackChannelKey;  // Key for temporary early playback channel

// Static variables - use extern to reference the global variable from UI file
extern BOOL playerControlsVisible; // Reference the global variable from UI file
static NSTimeInterval lastMouseMoveTime = 0;

// Helper class to break potential retain cycles with timers
@interface VLCTimerTarget : NSObject
@property (assign, nonatomic) VLCOverlayView *overlayView;
- (void)timerFired:(NSTimer *)timer;
@end

// Helper class for refresh timer
@interface VLCRefreshTimerTarget : NSObject
@property (assign, nonatomic) VLCOverlayView *overlayView;
- (void)refreshTimerFired:(NSTimer *)timer;
@end

@implementation VLCTimerTarget
- (void)timerFired:(NSTimer *)timer {
    //NSLog(@"VLCTimerTarget received timer fire event: %@", timer);

    // Call the overlay view's hide method
    [self.overlayView hidePlayerControls:timer];
    
    // NSLog(@"VLCTimerTarget directly updating visibility state");
    // Don't access playerControlsVisible directly here since it's in UI file
    // Just rely on the hidePlayerControls method to handle this properly
    
    // Force a redraw to ensure the controls disappear
    [self.overlayView setNeedsDisplay:YES];
    
    if (!self.overlayView) {
        //NSLog(@"ERROR: Timer target has no reference to overlay view!");
    }
}

- (void)dealloc {
    //NSLog(@"VLCTimerTarget being deallocated: %@", self);
    [super dealloc];
}
@end

@implementation VLCRefreshTimerTarget
- (void)refreshTimerFired:(NSTimer *)timer {
    // Only refresh if controls are visible
    if (self.overlayView && playerControlsVisible) {
        // Use a counter to reduce frequency of expensive operations
        static NSInteger timerCount = 0;
        timerCount++;
        
        // Refresh EPG information less frequently for timeshift content to reduce overhead
        BOOL isTimeshift = [self.overlayView isCurrentlyPlayingTimeshift];
        BOOL shouldRefreshEPG = NO;
        
        if (isTimeshift) {
            // For timeshift: only refresh every 5 seconds unless hovering
            if (self.overlayView.isHoveringProgressBar) {
                shouldRefreshEPG = YES; // Always refresh when hovering for responsive hover display
            } else {
                shouldRefreshEPG = (timerCount % 5 == 0); // Every 5 seconds when not hovering
            }
        } else {
            // For non-timeshift: refresh every 10 seconds (less critical)
            shouldRefreshEPG = (timerCount % 10 == 0);
        }
        
        if (shouldRefreshEPG) {
            // Refresh EPG information to ensure current program is up-to-date
            [self.overlayView refreshCurrentEPGInfo];
        }
        
        // Force a redraw of just the controls area (this is lightweight)
        CGFloat controlHeight = 140;
        CGFloat controlsY = 30;
        NSRect controlsRect = NSMakeRect(
            self.overlayView.bounds.size.width * 0.1,
            controlsY,
            self.overlayView.bounds.size.width * 0.8,
            controlHeight
        );
        
        [self.overlayView setNeedsDisplayInRect:controlsRect];
        [self.overlayView setNeedsDisplay:YES];
        [[self.overlayView window] display];
    }
    
    static NSInteger timerCount = 0;
    timerCount++;
    if (timerCount % 5 == 0) { // Every 5 seconds (timer fires every 1 second)
        if (self.overlayView && [self.overlayView respondsToSelector:@selector(saveCurrentPlaybackPosition)]) {
            [self.overlayView saveCurrentPlaybackPosition];
        }
    }
    
    // GLOBAL CATCH-UP MONITORING: Check all channels every 30 seconds
    if (timerCount % 30 == 0) { // Every 30 seconds
        if (self.overlayView && [self.overlayView respondsToSelector:@selector(updateGlobalCatchupStatus)]) {
            [self.overlayView updateGlobalCatchupStatus];
        }
    }
}

- (void)dealloc {
    [super dealloc];
}
@end

@implementation VLCOverlayView (PlayerControls)

#pragma mark - Property methods using associated objects

- (void)setPlayerControlsRect:(NSRect)rect {
    NSValue *rectValue = [NSValue valueWithRect:rect];
    objc_setAssociatedObject(self, &playerControlsRectKey, rectValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSRect)playerControlsRect {
    NSValue *rectValue = objc_getAssociatedObject(self, &playerControlsRectKey);
    return rectValue ? [rectValue rectValue] : NSZeroRect;
}

- (void)setProgressBarRect:(NSRect)rect {
    NSValue *rectValue = [NSValue valueWithRect:rect];
    objc_setAssociatedObject(self, &progressBarRectKey, rectValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSRect)progressBarRect {
    NSValue *rectValue = objc_getAssociatedObject(self, &progressBarRectKey);
    return rectValue ? [rectValue rectValue] : NSZeroRect;
}

// Timer property for better memory management
- (void)setPlayerControlsTimer:(NSTimer *)timer {
    // Invalidate existing timer first
    NSTimer *existingTimer = objc_getAssociatedObject(self, &playerControlsTimerKey);
    if (existingTimer) {
        //NSLog(@"Invalidating existing timer: %@", existingTimer);
        [existingTimer invalidate];
    }
    
    // Store the new timer
    if (timer) {
        //NSLog(@"Setting new timer: %@", timer);
        // Make sure timer stays in run loop even if no other references
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    }
    
    objc_setAssociatedObject(self, &playerControlsTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSTimer *)playerControlsTimer {
    NSTimer *timer = objc_getAssociatedObject(self, &playerControlsTimerKey);
    return timer;
}

// Refresh timer property for better memory management
- (void)setPlayerControlsRefreshTimer:(NSTimer *)timer {
    // Invalidate existing refresh timer first
    NSTimer *existingTimer = objc_getAssociatedObject(self, &refreshTimerKey);
    if (existingTimer) {
        [existingTimer invalidate];
    }
    
    // Store the new refresh timer
    if (timer) {
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
    }
    
    objc_setAssociatedObject(self, &refreshTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSTimer *)playerControlsRefreshTimer {
    NSTimer *timer = objc_getAssociatedObject(self, &refreshTimerKey);
    return timer;
}

// Subtitle and audio button rectangle properties
- (void)setSubtitlesButtonRect:(NSRect)rect {
    NSValue *rectValue = [NSValue valueWithRect:rect];
    objc_setAssociatedObject(self, &subtitlesButtonRectKey, rectValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSRect)subtitlesButtonRect {
    NSValue *rectValue = objc_getAssociatedObject(self, &subtitlesButtonRectKey);
    return rectValue ? [rectValue rectValue] : NSZeroRect;
}

- (void)setAudioButtonRect:(NSRect)rect {
    NSValue *rectValue = [NSValue valueWithRect:rect];
    objc_setAssociatedObject(self, &audioButtonRectKey, rectValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSRect)audioButtonRect {
    NSValue *rectValue = objc_getAssociatedObject(self, &audioButtonRectKey);
    return rectValue ? [rectValue rectValue] : NSZeroRect;
}

#pragma mark - Player Controls Methods

// Method to handle mouse movement for player controls visibility
- (void)handleMouseMovedForPlayerControls {
    // Only show controls if we have a player
    if (!self.player) {
        //NSLog(@"Not showing controls - no player");
        return;
    }
    
    // Get current mouse position in view coordinates
    NSPoint mouseLocation = [[self window] mouseLocationOutsideOfEventStream];
    NSPoint mouseInView = [self convertPoint:mouseLocation fromView:nil];
    
    // Store mouse position for later use in drawing
    self.progressBarHoverPoint = mouseInView;
    
    // Check for hover over progress bar if controls are visible and progress bar rect is set
    if (playerControlsVisible && !NSEqualRects(self.progressBarRect, NSZeroRect)) {
        NSRect expandedProgressBarRect = NSInsetRect(self.progressBarRect, -5, -10);
        BOOL currentHoverState = NSPointInRect(mouseInView, expandedProgressBarRect);
        
        // Update hover state and trigger redraw if needed
        if (currentHoverState != self.isHoveringProgressBar) {
            self.isHoveringProgressBar = currentHoverState;
            
            //NSLog(@"Progress bar hover state changed: %@", currentHoverState ? @"HOVERING" : @"NOT HOVERING");
            
            // Force redraw to update status text and hover indicator
            [self setNeedsDisplay:YES];
        } else if (currentHoverState) {
            // Only redraw if actively hovering and mouse position changed significantly
            static NSPoint lastHoverPoint = {0, 0};
            CGFloat distanceMoved = sqrt(pow(mouseInView.x - lastHoverPoint.x, 2) + pow(mouseInView.y - lastHoverPoint.y, 2));
            
            // Only trigger redraw if mouse moved more than 5 pixels horizontally within progress bar
            if (distanceMoved > 5.0) {
                lastHoverPoint = mouseInView;
                
                // For non-timeshift content, use lighter redraw to improve performance
                BOOL isTimeshift = [self isCurrentlyPlayingTimeshift];
                if (isTimeshift) {
                    [self setNeedsDisplay:YES];
                } else {
                    // For video content, only redraw the controls area to improve performance
                    CGFloat controlHeight = 140;
                    CGFloat controlsY = 30;
                    NSRect controlsRect = NSMakeRect(
                        self.bounds.size.width * 0.1,
                        controlsY,
                        self.bounds.size.width * 0.8,
                        controlHeight
                    );
                    [self setNeedsDisplayInRect:controlsRect];
                }
            }
        }
    }
    
    // Don't show player controls if the menu is open
    //if (self.isChannelListVisible) {
    //    NSLog(@"Not showing controls - channel list visible");
    //    return;
    // }
    
    // Update last mouse move time and show cursor if hidden
    lastMouseMoveTime = [NSDate timeIntervalSinceReferenceDate];
    if (isCursorHidden) {
        [NSCursor unhide];
        isCursorHidden = NO;
        //NSLog(@"Cursor shown due to mouse movement in player controls");
    }
    
    // Calculate the area where controls will be displayed - match the new design
    CGFloat controlHeight = 140; // Updated to match new design
    CGFloat controlsY = 30; // Updated to match new design
    NSRect controlsRect = NSMakeRect(
        self.bounds.size.width * 0.1, // Updated to match new design
        controlsY,
        self.bounds.size.width * 0.8, // Updated to match new design
        controlHeight
    );
    
    // Show player controls
    BOOL visibilityChanged = !playerControlsVisible;
    if (visibilityChanged) {
        playerControlsVisible = YES;
        //NSLog(@"Showing player controls - playerControlsVisible = Yes");
        
        // Refresh EPG information when controls become visible to ensure current program is shown
        [self refreshCurrentEPGInfo];
        
        // Force redraw of ONLY the controls area
        [self setNeedsDisplayInRect:controlsRect];
        // Also redraw entire view to be safe
        [self setNeedsDisplay:YES];
        // Force immediate update
        [[self window] display];
    }
    
    // Always log current state
    //NSLog(@"Controls state: playerControlsVisible: %@, menu: %@",
    //     playerControlsVisible ? @"YES" : @"NO",
    //     self.isChannelListVisible ? @"visible" : @"hidden");
         
    // Reset auto-hide timer using our property
    [self resetPlayerControlsTimer];
}

- (void)drawPlayerControls:(NSRect)rect {
    // Log visibility state during drawing
    static NSInteger drawCount = 0;
    drawCount++;
    
    //if (drawCount % 10 == 0) {  // Only log every 10th draw to avoid spam
    //    NSLog(@"drawPlayerControls called - playerControlsVisible: %@, menu: %@", 
    //         playerControlsVisible ? @"YES" : @"NO",
    //         self.isChannelListVisible ? @"visible" : @"hidden");
    //}
    
    // Don't draw controls if we don't have a player
    if (!self.player) {
        //NSLog(@"Skipping drawPlayerControls - no player");
        return;
    }
    
    // Don't draw controls if not visible
    if (!playerControlsVisible) {
        //NSLog(@"Skipping drawPlayerControls - controls not visible");
        return;
    }
    
    // Don't draw controls if the menu is visible
    if (self.isChannelListVisible) {
        //NSLog(@"Skipping drawPlayerControls - channel list visible");
        return;
    }
    
    //NSLog(@"DRAWING player controls - Controls will be visible");
    
    // Much larger control height for better design
    CGFloat controlHeight = 140; // Increased from 80 to 140 for more space
    CGFloat controlsY = 30; // More space from bottom
    NSRect controlsRect = NSMakeRect(
        self.bounds.size.width * 0.1, // 10% from left edge (wider)
        controlsY,
        self.bounds.size.width * 0.8, // 80% of screen width (wider)
        controlHeight
    );
    
    // Skip drawing if outside our area
    if (!NSIntersectsRect(rect, controlsRect)) {
       // NSLog(@"Skipping drawPlayerControls - rect does not intersect controls area");
        return;
    }
    
    // Store the control bar rect for click handling
    self.playerControlsRect = controlsRect;
    
    // Create beautiful gradient background
    NSGradient *bgGradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:0.95]
                                                            endingColor:[NSColor colorWithCalibratedRed:0.0 green:0.0 blue:0.0 alpha:0.85]];
    
    NSBezierPath *bgPath = [NSBezierPath bezierPathWithRoundedRect:controlsRect xRadius:12 yRadius:12];
    [bgGradient drawInBezierPath:bgPath angle:90];
    [bgGradient release];
    
    // Add subtle border
    [[NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:0.6] set];
    [bgPath setLineWidth:1.0];
    [bgPath stroke];
    
    // Check if we're playing timeshift content
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    
    // Get current channel to access program information
    VLCChannel *currentChannel = nil;
    VLCProgram *currentProgram = nil;
    
    // FIXED: For timeshift content, use the saved program information instead of current time
    if (isTimeshiftPlaying) {
        // Get the saved timeshift content info which contains the specific program that was selected
        NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
        if (cachedInfo) {
            // Create a temporary channel object from cached info
            currentChannel = [[VLCChannel alloc] init];
            currentChannel.name = [cachedInfo objectForKey:@"channelName"];
            currentChannel.url = [cachedInfo objectForKey:@"url"];
            currentChannel.category = [cachedInfo objectForKey:@"category"];
            currentChannel.logo = [cachedInfo objectForKey:@"logoUrl"];
            
            // Get the specific program that was selected for timeshift playback
            NSDictionary *programInfo = [cachedInfo objectForKey:@"currentProgram"];
            if (programInfo) {
                currentProgram = [[VLCProgram alloc] init];
                currentProgram.title = [programInfo objectForKey:@"title"];
                currentProgram.programDescription = [programInfo objectForKey:@"description"];
                currentProgram.startTime = [programInfo objectForKey:@"startTime"];
                currentProgram.endTime = [programInfo objectForKey:@"endTime"];
                
                //NSLog(@"Player Controls - Using saved timeshift program: %@ (%@ - %@)", 
                //      currentProgram.title, currentProgram.startTime, currentProgram.endTime);
                
                [currentProgram autorelease];
            } else {
                //NSLog(@"Player Controls - No saved program info found for timeshift content");
            }
            
            [currentChannel autorelease];
        }
    } else {
       
        // This ensures startup cached data takes precedence over selection-based calculation
        [self refreshCurrentEPGInfo];
        currentChannel = objc_getAssociatedObject(self, "tempEarlyPlaybackChannelKey");
        currentProgram = [currentChannel currentProgramWithTimeOffset:self.epgTimeOffsetHours];;//currentChannel.programs[0];

        // Always use selection-based approach with direct EPG calculation
        if (self.selectedChannelIndex >= 0 && self.selectedChannelIndex < [self.simpleChannelNames count]) {
            // Try to get the channel from the current selection
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
                    if (channelsInGroup && self.selectedChannelIndex < channelsInGroup.count) {
                        currentChannel = [channelsInGroup objectAtIndex:self.selectedChannelIndex];
                        
                        // Get current program for this channel based on current time
                        if (currentChannel.programs && currentChannel.programs.count > 0) {
                            currentProgram = [currentChannel currentProgramWithTimeOffset:self.epgTimeOffsetHours];
                            /*
                            // Enhanced debug logging to understand program selection
                            if (currentProgram) {
                                NSLog(@"🎯 DIRECT EPG: Found current program: %@ (%@ - %@)", 
                                      currentProgram.title, currentProgram.startTime, currentProgram.endTime);
                                NSLog(@"🎯 DIRECT EPG: Channel: %@, Programs count: %ld", 
                                      currentChannel.name, (long)currentChannel.programs.count);
                                NSLog(@"🎯 DIRECT EPG: Using EPG offset: %ld hours", (long)self.epgTimeOffsetHours);
                            } else {
                                NSLog(@"🎯 DIRECT EPG: No current program found for channel: %@", currentChannel.name);
                                NSLog(@"🎯 DIRECT EPG: Channel has %ld programs, EPG offset: %ld hours", 
                                      (long)currentChannel.programs.count, (long)self.epgTimeOffsetHours);
                            }
                            */
                        } else {
                            //NSLog(@"🎯 DIRECT EPG: Channel %@ has no EPG programs loaded", 
                            //      currentChannel.name ? currentChannel.name : @"nil");
                        }
                    }
                }
            }
        }
        
        // Final fallback: If we still couldn't get from selection, try cached content info
        if (!currentChannel) {           
            NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
            if (cachedInfo) {
                // Create a temporary channel object from cached info
                currentChannel = [[VLCChannel alloc] init];
                currentChannel.name = [cachedInfo objectForKey:@"channelName"];
                currentChannel.url = [cachedInfo objectForKey:@"url"];
                currentChannel.category = [cachedInfo objectForKey:@"category"];
                currentChannel.logo = [cachedInfo objectForKey:@"logoUrl"];
                
                // Try to get current program from cached info
                NSDictionary *programInfo = [cachedInfo objectForKey:@"currentProgram"];
                if (programInfo) {
                    currentProgram = [[VLCProgram alloc] init];
                    currentProgram.title = [programInfo objectForKey:@"title"];
                    currentProgram.programDescription = [programInfo objectForKey:@"description"];
                    currentProgram.startTime = [programInfo objectForKey:@"startTime"];
                    currentProgram.endTime = [programInfo objectForKey:@"endTime"];
                    [currentProgram autorelease];
                }
                
                [currentChannel autorelease];
            }
        }
    }
    
    // Logo area on the left
    CGFloat logoSize = 80;
    CGFloat logoMargin = 20;
    NSRect logoRect = NSMakeRect(
        controlsRect.origin.x + logoMargin,
        controlsRect.origin.y + (controlHeight - logoSize) / 2,
        logoSize,
        logoSize
    );
    
    // Draw logo background
    NSBezierPath *logoBackground = [NSBezierPath bezierPathWithRoundedRect:logoRect xRadius:8 yRadius:8];
    [[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:0.8] set];
    [logoBackground fill];
    
    // Try to draw the channel logo
    NSImage *channelLogo = nil;
    BOOL shouldReleaseChannelLogo = NO; // Track if we need to release
    
    if (currentChannel && currentChannel.cachedPosterImage) {
        channelLogo = currentChannel.cachedPosterImage;
        shouldReleaseChannelLogo = NO; // Don't release - we don't own this
    } else if (currentChannel && currentChannel.logo && [currentChannel.logo length] > 0) {
        // Check if we're already loading this logo to avoid duplicate requests
        static NSMutableSet *loadingLogos = nil;
        if (!loadingLogos) {
            loadingLogos = [[NSMutableSet alloc] init];
        }
        
        if (![loadingLogos containsObject:currentChannel.logo]) {
            [loadingLogos addObject:currentChannel.logo];
            
            // Load logo asynchronously
            NSURL *logoURL = [NSURL URLWithString:currentChannel.logo];
            if (logoURL) {
                NSURLSessionDataTask *logoTask = [[NSURLSession sharedSession] dataTaskWithURL:logoURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [loadingLogos removeObject:currentChannel.logo];
                        
                        if (data && !error) {
                            NSImage *downloadedLogo = [[NSImage alloc] initWithData:data];
                            if (downloadedLogo) {
                                // Cache it for future use
                                currentChannel.cachedPosterImage = downloadedLogo;
                                [downloadedLogo release];
                                
                                // Trigger a redraw to show the newly loaded logo
                                [self setNeedsDisplay:YES];
                            }
                        }
                    });
                }];
                [logoTask resume];
            }
        }
    }
    
    if (channelLogo) {
        // Get the original image size
        NSSize imageSize = [channelLogo size];
        
        // Calculate the area available for the logo (with some padding)
        NSRect logoDrawRect = NSInsetRect(logoRect, 8, 8);
        CGFloat availableWidth = logoDrawRect.size.width;
        CGFloat availableHeight = logoDrawRect.size.height;
        
        // Calculate aspect ratios
        CGFloat imageAspectRatio = imageSize.width / imageSize.height;
        CGFloat availableAspectRatio = availableWidth / availableHeight;
        
        // Calculate the scaled size that fits within available area while maintaining aspect ratio
        NSSize scaledSize;
        if (imageAspectRatio > availableAspectRatio) {
            // Image is wider - fit to width
            scaledSize.width = availableWidth;
            scaledSize.height = availableWidth / imageAspectRatio;
        } else {
            // Image is taller - fit to height
            scaledSize.height = availableHeight;
            scaledSize.width = availableHeight * imageAspectRatio;
        }
        
        // Center the scaled image within the available area
        NSRect centeredRect = NSMakeRect(
            logoDrawRect.origin.x + (availableWidth - scaledSize.width) / 2,
            logoDrawRect.origin.y + (availableHeight - scaledSize.height) / 2,
            scaledSize.width,
            scaledSize.height
        );
        
        // Draw the logo with proper aspect ratio
        [channelLogo drawInRect:centeredRect
                       fromRect:NSZeroRect
                      operation:NSCompositingOperationSourceOver
                       fraction:1.0
                 respectFlipped:YES
                          hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        
        // Only release if we allocated it
        if (shouldReleaseChannelLogo) {
            [channelLogo release];
        }
    } else {
        // Draw placeholder with channel initial or icon
        NSString *placeholder = @"📺";
        if (currentChannel && currentChannel.name && [currentChannel.name length] > 0) {
            placeholder = [[currentChannel.name substringToIndex:1] uppercaseString];
        }
        
        NSDictionary *placeholderAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:32],
            NSForegroundColorAttributeName: [NSColor lightGrayColor]
        };
        
        NSSize textSize = [placeholder sizeWithAttributes:placeholderAttrs];
        NSRect placeholderRect = NSMakeRect(
            logoRect.origin.x + (logoSize - textSize.width) / 2,
            logoRect.origin.y + (logoSize - textSize.height) / 2,
            textSize.width,
            textSize.height
        );
        [placeholder drawInRect:placeholderRect withAttributes:placeholderAttrs];
    }
    
    // Video quality info below logo (works for both TV and movies)
    // Calculate quality inline since qualityInfo is declared later
    NSString *logoQualityInfo = nil;
    if (self.player && self.player.media && [self.player hasVideoOut]) {
        NSSize videoSize = [self.player videoSize];
        if (videoSize.width > 0 && videoSize.height > 0) {
            int h = (int)videoSize.height;
            int w = (int)videoSize.width;
            
            if (h >= 2160) {
                logoQualityInfo = @"4K UHD";
            } else if (h >= 1440) {
                logoQualityInfo = @"1440p QHD";
            } else if (h >= 1080) {
                logoQualityInfo = @"1080p HD";
            } else if (h >= 720) {
                logoQualityInfo = @"720p HD";
            } else if (h >= 480) {
                logoQualityInfo = @"480p SD";
            } else {
                logoQualityInfo = [NSString stringWithFormat:@"%dx%d", w, h];
            }
        }
    }
    
    if (logoQualityInfo && [logoQualityInfo length] > 0) {
        NSDictionary *qualityAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:11],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.8 green:0.8 blue:0.8 alpha:0.9]
        };
        
        NSSize qualityTextSize = [logoQualityInfo sizeWithAttributes:qualityAttrs];
        NSRect qualityRect = NSMakeRect(
            logoRect.origin.x + (logoSize - qualityTextSize.width) / 2, // Center horizontally under logo
            logoRect.origin.y - 20, // 20px below logo
            qualityTextSize.width,
            qualityTextSize.height
        );
        [logoQualityInfo drawInRect:qualityRect withAttributes:qualityAttrs];
    }
    
    // Content area (to the right of logo)
    CGFloat contentStartX = logoRect.origin.x + logoSize + logoMargin;
    CGFloat contentWidth = controlsRect.size.width - (contentStartX - controlsRect.origin.x) - logoMargin;
    
    // Calculate progress bar position and dimensions
    CGFloat progressBarY = controlsRect.origin.y + controlHeight * 0.5; // Center vertically
    CGFloat progressBarHeight = 8; // Thicker progress bar
    
    NSRect progressBgRect = NSMakeRect(contentStartX, progressBarY, contentWidth, progressBarHeight);
    
    // Store the progress bar rect for click handling
    self.progressBarRect = progressBgRect;
    
    // Calculate progress and time strings based on timeshift status
    float progress = 0.0;
    NSString *currentTimeStr = @"--:--";
    NSString *totalTimeStr = @"--:--";
    NSString *programStatusStr = @"";
    NSString *programTimeRange = @"";
    
    if (isTimeshiftPlaying) {
        // Special handling for timeshift playback
        [self calculateTimeshiftProgress:&progress 
                         currentTimeStr:&currentTimeStr 
                           totalTimeStr:&totalTimeStr 
                        programStatusStr:&programStatusStr 
                         programTimeRange:&programTimeRange 
                           currentChannel:currentChannel 
                           currentProgram:currentProgram];
        
        // IMPORTANT: Don't let any other code overwrite timeshift values after this point
        // The timeshift calculation sets the correct currentTimeStr with EPG offset applied
        
    } else if (!isTimeshiftPlaying && currentProgram && currentProgram.startTime && currentProgram.endTime) {
        // We have program information - show progress within the program
        NSTimeZone *localTimeZone = [NSTimeZone localTimeZone];
        NSDate *now = [NSDate date];
        
        // Apply the user-configured EPG time offset to current time for comparison
        NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600.0;
        NSDate *adjustedNow = [[NSDate date] dateByAddingTimeInterval:offsetSeconds];
        
       
        // Calculate program duration and elapsed time using ORIGINAL EPG times for display
        // but adjusted current time for status calculation
        NSTimeInterval programDuration = [currentProgram.endTime timeIntervalSinceDate:currentProgram.startTime];
        NSTimeInterval elapsed = [adjustedNow timeIntervalSinceDate:currentProgram.startTime];
        NSTimeInterval remaining = [currentProgram.endTime timeIntervalSinceDate:adjustedNow];
       
        // Calculate progress with proper bounds checking
        if (programDuration > 0) {
            if (elapsed < 0) {
                // Program hasn't started yet
                progress = 0.0;
                //NSLog(@"Program hasn't started yet - progress = 0.0");
            } else if (remaining < 0) {
                // Program has ended
                progress = 1.0;
                //NSLog(@"Program has ended - progress = 1.0");
            } else {
                // Program is currently running
                progress = elapsed / programDuration;
                progress = MIN(1.0, MAX(0.0, progress)); // Clamp between 0 and 1
                //NSLog(@"Program is running - progress = %.2f (%.1f%%)", progress, progress * 100.0);
            }
        } else {
            progress = 0.0;
            //NSLog(@"Invalid program duration - progress = 0.0");
        }
        
        // FIXED: For player controls, show LOCAL TIME without EPG offset
        // EPG offset should only be used for program status calculations and EPG display
        NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
        [timeFormatter setDateFormat:@"HH:mm:ss"];
        [timeFormatter setTimeZone:localTimeZone];
        
        // For program time range display, apply EPG offset to show user's preferred time
        NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
        NSDate *adjustedStartTime = [currentProgram.startTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSDate *adjustedEndTime = [currentProgram.endTime dateByAddingTimeInterval:displayOffsetSeconds];
        
        // FIXED: Show program times with EPG offset applied for player controls to match EPG display
        // The user expects to see the same times in player controls as they see in the EPG
        currentTimeStr = [timeFormatter stringFromDate:adjustedStartTime];
        totalTimeStr = [timeFormatter stringFromDate:adjustedEndTime];
        
        programTimeRange = [NSString stringWithFormat:@"%@ - %@", 
                           [timeFormatter stringFromDate:adjustedStartTime],
                           [timeFormatter stringFromDate:adjustedEndTime]];
        
        // Calculate status string using adjusted times
        if (elapsed < 0) {
            // Program hasn't started yet
            int minutesUntilStart = (int)(ABS(elapsed) / 60);
            if (minutesUntilStart > 60) {
                int hours = minutesUntilStart / 60;
                int mins = minutesUntilStart % 60;
                programStatusStr = [NSString stringWithFormat:@"Starts in %dh %dm", hours, mins];
            } else {
                programStatusStr = [NSString stringWithFormat:@"Starts in %d min", minutesUntilStart];
            }
        } else if (remaining > 0) {
            // Program is currently running
            int remainingMins = (int)(remaining / 60);
            if (remainingMins > 60) {
                int hours = remainingMins / 60;
                int mins = remainingMins % 60;
                programStatusStr = [NSString stringWithFormat:@"%dh %dm remaining", hours, mins];
            } else {
                programStatusStr = [NSString stringWithFormat:@"%d min remaining", remainingMins];
            }
        } else {
            // Program has ended
            int minutesSinceEnd = (int)(ABS(remaining) / 60);
            if (minutesSinceEnd > 60) {
                int hours = minutesSinceEnd / 60;
                int mins = minutesSinceEnd % 60;
                programStatusStr = [NSString stringWithFormat:@"Ended %dh %dm ago", hours, mins];
            } else {
                programStatusStr = [NSString stringWithFormat:@"Ended %d min ago", minutesSinceEnd];
            }
        }
        
        // Find EPG programs that fall within the timeshift window and display them
        NSString *epgProgramInfo = @"";
        if (currentChannel && currentChannel.programs && currentChannel.programs.count > 0) {
            NSMutableArray *programsInWindow = [NSMutableArray array];
            
            // For non-timeshift content, show current and upcoming programs
            NSDate *actualNow = [NSDate date];
            NSDate *windowStart = [actualNow dateByAddingTimeInterval:-3600]; // 1 hour ago
            NSDate *windowEnd = [actualNow dateByAddingTimeInterval:3600];    // 1 hour ahead
            
            // Find programs that overlap with our window
            for (VLCProgram *program in currentChannel.programs) {
                if (program.startTime && program.endTime) {
                    // Check if program overlaps with our window
                    BOOL programOverlaps = ([program.startTime compare:windowEnd] == NSOrderedAscending && 
                                          [program.endTime compare:windowStart] == NSOrderedDescending);
                    
                    if (programOverlaps) {
                        [programsInWindow addObject:program];
                    }
                }
            }
            
            // For non-timeshift content, simply show the current program
            if (currentProgram && currentProgram.title) {
                NSDateFormatter *shortFormatter = [[NSDateFormatter alloc] init];
                [shortFormatter setDateFormat:@"HH:mm"];
                [shortFormatter setTimeZone:[NSTimeZone localTimeZone]];
                
                NSString *currentStr = [self formatProgramString:currentProgram formatter:shortFormatter isDimmed:NO];
                epgProgramInfo = [NSString stringWithFormat:@"► %@", currentStr];
                
                [shortFormatter release];
            } else if (programsInWindow.count > 0) {
                // Fallback: if no currentProgram, use first program
                VLCProgram *program = [programsInWindow objectAtIndex:0];
                
                NSDateFormatter *shortFormatter = [[NSDateFormatter alloc] init];
                [shortFormatter setDateFormat:@"HH:mm"];
                [shortFormatter setTimeZone:[NSTimeZone localTimeZone]];
                
                NSString *programStr = [self formatProgramString:program formatter:shortFormatter isDimmed:NO];
                epgProgramInfo = programStr;
                
                [shortFormatter release];
            } else {
                epgProgramInfo = @"No EPG data for this time period";
            }
        } else {
            epgProgramInfo = @"No EPG data available";
        }
        
        programTimeRange = epgProgramInfo;
        
        [timeFormatter release];
    } else {
        // Fall back to video time if no program info AND not timeshift
        VLCTime *currentTime = [self.player time];
        VLCTime *totalTime = [self.player.media length];
        
        if (totalTime && [totalTime intValue] > 0 && currentTime) {
            float currentMs = (float)[currentTime intValue];
            float totalMs = (float)[totalTime intValue];
            
            progress = currentMs / totalMs;
            progress = MIN(1.0, MAX(0.0, progress)); // Clamp between 0 and 1
            
            //NSLog(@"Video progress calculation: current=%.0fms, total=%.0fms, progress=%.2f", 
            //      currentMs, totalMs, progress);
        } else {
            //NSLog(@"No valid time information available - currentTime=%@, totalTime=%@", 
           //       currentTime, totalTime);
        }
        
        if (currentTime) {
            int currentSecs = [currentTime intValue] / 1000;
            currentTimeStr = [NSString stringWithFormat:@"%d:%02d", 
                             currentSecs / 60, 
                             currentSecs % 60];
        }
        
        if (totalTime && [totalTime intValue] > 0) {
            int totalSecs = [totalTime intValue] / 1000;
            totalTimeStr = [NSString stringWithFormat:@"%d:%02d", 
                           totalSecs / 60, 
                           totalSecs % 60];
        }
        
        // Handle hover time display for video content
        if (self.isHoveringProgressBar && totalTime && [totalTime intValue] > 0) {
            // Cache hover calculation to improve performance
            static CGFloat lastRelativePosition = -1.0;
            static NSString *cachedHoverTimeStr = nil;
            static int lastTotalMs = 0;
            
            // Calculate current hover position
            CGFloat relativeX = self.progressBarHoverPoint.x - self.progressBarRect.origin.x;
            CGFloat relativePosition = relativeX / self.progressBarRect.size.width;
            relativePosition = MIN(1.0, MAX(0.0, relativePosition));
            
            int totalMs = [totalTime intValue];
            
            // Only recalculate if position changed significantly or video duration changed
            if (ABS(relativePosition - lastRelativePosition) > 0.01 || totalMs != lastTotalMs) {
                // Calculate hover position in video time
                int hoverMs = (int)(totalMs * relativePosition);
                int hoverSecs = hoverMs / 1000;
                int hoverMins = hoverSecs / 60;
                int remainingSecs = hoverSecs % 60;
                
                // Cache the result
                if (cachedHoverTimeStr) {
                    [cachedHoverTimeStr release];
                }
                cachedHoverTimeStr = [[NSString stringWithFormat:@"%d:%02d", hoverMins, remainingSecs] retain];
                lastRelativePosition = relativePosition;
                lastTotalMs = totalMs;
            }
            int totalSecs = [totalTime intValue] / 1000;
            NSString *totalTimeDisplay = [NSString stringWithFormat:@"%d:%02d", totalSecs / 60, totalSecs % 60];
            programStatusStr = [NSString stringWithFormat:@"%@ / %@", cachedHoverTimeStr ?: @"--:--", totalTimeDisplay];
        } else {
            // Show relevant movie/video information when not hovering
            NSMutableArray *statusParts = [NSMutableArray array];
            
            // Add current time / total time
            if (currentTime && totalTime && [totalTime intValue] > 0) {
                int currentSecs = [currentTime intValue] / 1000;
                int totalSecs = [totalTime intValue] / 1000;
                
                NSString *currentTimeDisplay = [NSString stringWithFormat:@"%d:%02d", currentSecs / 60, currentSecs % 60];
                NSString *totalTimeDisplay = [NSString stringWithFormat:@"%d:%02d", totalSecs / 60, totalSecs % 60];
                
                [statusParts addObject:[NSString stringWithFormat:@"%@ / %@", currentTimeDisplay, totalTimeDisplay]];
            }
            
            // Add movie metadata if available
            if (currentChannel && [currentChannel.category isEqualToString:@"MOVIES"]) {
                // Add movie year if available
                if (currentChannel.movieYear && [currentChannel.movieYear length] > 0) {
                    [statusParts addObject:currentChannel.movieYear];
                }
                
                // Add movie genre if available
                if (currentChannel.movieGenre && [currentChannel.movieGenre length] > 0) {
                    [statusParts addObject:currentChannel.movieGenre];
                }
                
                // Add movie rating if available
                if (currentChannel.movieRating && [currentChannel.movieRating length] > 0) {
                    float rating = [currentChannel.movieRating floatValue];
                    if (rating > 0) {
                        [statusParts addObject:[NSString stringWithFormat:@"★ %.1f", rating]];
                    }
                }
            }
           
            
            // Create status string
            if (statusParts.count > 0) {
                programStatusStr = [statusParts componentsJoinedByString:@" • "];
            } else {
                // Fallback to VLC media title if available
                if (self.player.media && self.player.media.metaData.title) {
                    programStatusStr = self.player.media.metaData.title;
                } else {
                    programStatusStr = @"Playing";
                }
            }
            
        }
        
    }
    
    // Beautiful progress bar with shadow
    // Shadow
    NSBezierPath *shadowPath = [NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(progressBgRect, 0, -1) xRadius:4 yRadius:4];
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.3] set];
    [shadowPath fill];
    
    // Progress bar background
    NSGradient *progressBgGradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.15 alpha:0.9]
                                                                   endingColor:[NSColor colorWithCalibratedRed:0.25 green:0.25 blue:0.25 alpha:0.9]];
    NSBezierPath *progressBgPath = [NSBezierPath bezierPathWithRoundedRect:progressBgRect xRadius:4 yRadius:4];
    [progressBgGradient drawInBezierPath:progressBgPath angle:90];
    [progressBgGradient release];
    
    // Progress fill with different color for timeshift
    NSRect progressFillRect = NSMakeRect(progressBgRect.origin.x, progressBgRect.origin.y, 
                                         progressBgRect.size.width * progress, progressBgRect.size.height);
    
    NSColor *progressColor;
    if (isTimeshiftPlaying) {
        // Orange/amber color for timeshift to indicate it's not live
        progressColor = [NSColor colorWithCalibratedRed:1.0 green:0.6 blue:0.2 alpha:0.9];
    } else {
        // Blue color for live/normal content
        progressColor = [NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.8 alpha:0.9];
    }
    
    NSGradient *progressGradient = [[NSGradient alloc] initWithStartingColor:progressColor
                                                                 endingColor:[progressColor colorWithAlphaComponent:0.7]];
        NSBezierPath *progressFillPath = [NSBezierPath bezierPathWithRoundedRect:progressFillRect xRadius:4 yRadius:4];
        [progressGradient drawInBezierPath:progressFillPath angle:90];
        [progressGradient release];
        
    // Draw hover indicator on progress bar
    if (self.isHoveringProgressBar) {
        // Calculate relative position within progress bar
        CGFloat relativeX = self.progressBarHoverPoint.x - progressBgRect.origin.x;
        CGFloat relativePosition = relativeX / progressBgRect.size.width;
        relativePosition = MIN(1.0, MAX(0.0, relativePosition));
        
        // Draw a bright green vertical line at hover position
        CGFloat hoverX = progressBgRect.origin.x + (relativePosition * progressBgRect.size.width);
        
        // Make the hover line extend slightly above and below the progress bar
        NSRect hoverLineRect = NSMakeRect(
            hoverX - 1, // 2px wide line
            progressBgRect.origin.y - 2,
            2,
            progressBgRect.size.height + 4
        );
        
        // Bright green color for hover indicator
        [[NSColor colorWithCalibratedRed:0.2 green:1.0 blue:0.2 alpha:0.9] set];
        NSBezierPath *hoverLine = [NSBezierPath bezierPathWithRoundedRect:hoverLineRect xRadius:1 yRadius:1];
        [hoverLine fill];
        
        // Add a small circle at the top of the hover line for better visibility
        NSRect hoverDotRect = NSMakeRect(
            hoverX - 3,
            progressBgRect.origin.y + progressBgRect.size.height + 1,
            6,
            6
        );
        
        NSBezierPath *hoverDot = [NSBezierPath bezierPathWithOvalInRect:hoverDotRect];
        [hoverDot fill];
    }
    
    // Show loading indicator for timeshift seeking
    if (isTimeshiftPlaying && [self isTimeshiftSeeking]) {
        // Semi-transparent overlay
        [[NSColor colorWithCalibratedRed:0.0 green:0.0 blue:0.0 alpha:0.5] set];
        NSBezierPath *loadingOverlay = [NSBezierPath bezierPathWithRoundedRect:progressBgRect xRadius:4 yRadius:4];
        [loadingOverlay fill];
        
        // Animated loading dots or spinner
        NSString *loadingText = @"⟳ Seeking...";
        NSDictionary *loadingAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:11],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        
        NSSize loadingTextSize = [loadingText sizeWithAttributes:loadingAttrs];
        NSRect loadingTextRect = NSMakeRect(
            progressBgRect.origin.x + (progressBgRect.size.width - loadingTextSize.width) / 2,
            progressBgRect.origin.y + (progressBgRect.size.height - loadingTextSize.height) / 2,
            loadingTextSize.width,
            loadingTextSize.height
        );
        [loadingText drawInRect:loadingTextRect withAttributes:loadingAttrs];
    }
    
    // Show hover time tooltip when mouse is over progress bar
    // REMOVED: Tooltip display - only using status display for hover time
    
    // Text styling with better fonts and spacing
    NSMutableParagraphStyle *leftStyle = [[NSMutableParagraphStyle alloc] init];
    [leftStyle setAlignment:NSTextAlignmentLeft];
    
    NSMutableParagraphStyle *rightStyle = [[NSMutableParagraphStyle alloc] init];
    [rightStyle setAlignment:NSTextAlignmentRight];
    
    NSMutableParagraphStyle *centerStyle = [[NSMutableParagraphStyle alloc] init];
    [centerStyle setAlignment:NSTextAlignmentCenter];

    // Check if we should show catch-up indicator (moved here after leftStyle is created)
    BOOL showCatchupIndicator = NO;
    NSString *catchupType = nil;
    
    // Check for EPG-based catch-up (past programs)
    if (currentProgram && currentProgram.hasArchive) {
        NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600.0;
        NSDate *adjustedNow = [[NSDate date] dateByAddingTimeInterval:offsetSeconds];
        NSTimeInterval remaining = [currentProgram.endTime timeIntervalSinceDate:adjustedNow];
        
        if (remaining < 0) {
            showCatchupIndicator = YES;
            catchupType = @"EPG";
        }
    }
    
    // Check for channel-level catch-up (time-shifting)
    if (!showCatchupIndicator && currentChannel && currentChannel.supportsCatchup) {
        showCatchupIndicator = YES;
        catchupType = @"Channel";
    }

    // Program/Channel title (large, top) - Enhanced with movie info
    NSString *mainTitle = @"Now Playing";
    NSString *subtitle = nil;
    NSString *qualityInfo = nil;
    
    // Get video quality information from VLC media player's videoSize property
    if (self.player && self.player.media && [self.player hasVideoOut]) {
        // Use VLCMediaPlayer's videoSize property - much more reliable than track descriptions
        NSSize videoSize = [self.player videoSize];
        
        if (videoSize.width > 0 && videoSize.height > 0) {
            int h = (int)videoSize.height;
            int w = (int)videoSize.width;
            
            // Determine quality based on height
            if (h >= 2160) {
                qualityInfo = @"4K UHD";
            } else if (h >= 1440) {
                qualityInfo = @"1440p QHD";
            } else if (h >= 1080) {
                qualityInfo = @"1080p HD";
            } else if (h >= 720) {
                qualityInfo = @"720p HD";
            } else if (h >= 480) {
                qualityInfo = @"480p SD";
            } else {
                qualityInfo = [NSString stringWithFormat:@"%dx%d", w, h];
            }
            
            //NSLog(@"Video resolution detected: %dx%d (%@)", w, h, qualityInfo);
        } else {
            //NSLog(@"Video size not available yet (size: %.0fx%.0f)", videoSize.width, videoSize.height);
        }
    }
    
    // Prioritize movie information for movies, program info for TV
    if (currentChannel && [currentChannel.category isEqualToString:@"MOVIES"] && currentChannel.hasLoadedMovieInfo) {
        // Use movie title and metadata for movies
        mainTitle = currentChannel.name;
        
        // Build subtitle with movie metadata (without quality info)
        NSMutableArray *subtitleParts = [NSMutableArray array];
        if (currentChannel.movieYear && [currentChannel.movieYear length] > 0) {
            [subtitleParts addObject:currentChannel.movieYear];
        }
        if (currentChannel.movieGenre && [currentChannel.movieGenre length] > 0) {
            [subtitleParts addObject:currentChannel.movieGenre];
        }
        if (currentChannel.movieDuration && [currentChannel.movieDuration length] > 0) {
            // Format duration nicely
            NSString *duration = currentChannel.movieDuration;
            if ([self isNumeric:duration]) {
                NSInteger seconds = [duration integerValue];
                NSInteger hours = seconds / 3600;
                NSInteger minutes = (seconds % 3600) / 60;
                if (hours > 0) {
                    duration = [NSString stringWithFormat:@"%ldh %ldm", (long)hours, (long)minutes];
                } else {
                    duration = [NSString stringWithFormat:@"%ldm", (long)minutes];
                }
            }
            [subtitleParts addObject:duration];
        }
        
        if (subtitleParts.count > 0) {
            subtitle = [subtitleParts componentsJoinedByString:@" • "];
        }
    } else if (isTimeshiftPlaying) {
        // For timeshift content, prioritize the timeshift playing program
        VLCProgram *timeshiftProgram = [self getCurrentTimeshiftPlayingProgram];
        if (timeshiftProgram && timeshiftProgram.title && [timeshiftProgram.title length] > 0) {
            mainTitle = timeshiftProgram.title;
            // Set currentProgram to the timeshift program for description display
            currentProgram = timeshiftProgram;
        } else if (currentChannel && currentChannel.name && [currentChannel.name length] > 0) {
            mainTitle = currentChannel.name;
        }
    } else if (currentProgram && currentProgram.title && [currentProgram.title length] > 0) {
        // Use program information for TV channels
        mainTitle = currentProgram.title;
    } else if (currentChannel && currentChannel.name && [currentChannel.name length] > 0) {
        // Use channel name
        mainTitle = currentChannel.name;
    } else if (self.player.media && self.player.media.metaData.title) {
        // Fallback to VLC metadata
        mainTitle = self.player.media.metaData.title;
    } else if (self.selectedChannelIndex >= 0 && self.selectedChannelIndex < [self.simpleChannelNames count]) {
        // Final fallback to simple channel name
        mainTitle = [self.simpleChannelNames objectAtIndex:self.selectedChannelIndex];
    }
    
    // Truncate title if too long
    if ([mainTitle length] > 60) {
        mainTitle = [[mainTitle substringToIndex:57] stringByAppendingString:@"..."];
    }
    
    // Main title with shadow effect
    NSDictionary *titleShadowAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:18],
        NSForegroundColorAttributeName: [NSColor blackColor]
    };
    
    NSRect titleShadowRect = NSMakeRect(
        contentStartX + 1,
        progressBarY + 35 + 1,
        contentWidth,
        24
    );
    [mainTitle drawInRect:titleShadowRect withAttributes:titleShadowAttrs];
    
    // Main title
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:18],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: leftStyle
    };
    
    NSRect titleRect = NSMakeRect(
        contentStartX,
        progressBarY + 35,
        contentWidth,
        24
    );
    [mainTitle drawInRect:titleRect withAttributes:titleAttrs];
    
    // Draw subtitle with movie/quality info (below main title)
    if (subtitle && [subtitle length] > 0) {
        NSDictionary *subtitleAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.8 green:0.8 blue:0.8 alpha:1.0],
            NSParagraphStyleAttributeName: leftStyle
        };
        
        NSRect subtitleRect = NSMakeRect(
            contentStartX,
            progressBarY + 15,
            contentWidth - 120, // Leave space for poster
            16
        );
        [subtitle drawInRect:subtitleRect withAttributes:subtitleAttrs];
    }
    
    // Draw small poster image for movies (top right corner)
    if (currentChannel && [currentChannel.category isEqualToString:@"MOVIES"] && currentChannel.cachedPosterImage) {
        CGFloat posterSize = 100;
        NSRect posterRect = NSMakeRect(
            contentStartX + contentWidth - posterSize - 10,
            progressBarY + 20,
            posterSize,
            posterSize * 1.5 // Movie poster aspect ratio
        );
        
        // Save graphics state for clipping
        NSGraphicsContext *context = [NSGraphicsContext currentContext];
        [context saveGraphicsState];
        
        // Draw poster with rounded corners
        NSBezierPath *posterPath = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:4 yRadius:4];
        [posterPath setClip];
        
        [currentChannel.cachedPosterImage drawInRect:posterRect 
                                            fromRect:NSZeroRect 
                                           operation:NSCompositeSourceOver 
                                            fraction:1.0];
        
        // Restore graphics state
        [context restoreGraphicsState];
        
        // Add subtle border
        [[NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:0.8] set];
        NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:posterRect xRadius:4 yRadius:4];
        [borderPath setLineWidth:1.0];
        [borderPath stroke];
    }
    
    // Program time range (below title/subtitle)
    if (programTimeRange && [programTimeRange length] > 0) {
        NSDictionary *timeRangeAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.8 green:0.8 blue:0.8 alpha:1.0],
            NSParagraphStyleAttributeName: leftStyle
        };
        
        NSRect timeRangeRect = NSMakeRect(
            contentStartX,
            progressBarY + 15,
            contentWidth,
            16
        );
        [programTimeRange drawInRect:timeRangeRect withAttributes:timeRangeAttrs];
    }
    
    // Current time and remaining time (below progress bar)
    NSDictionary *timeAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: leftStyle
    };
    
    NSRect currentTimeRect = NSMakeRect(
        contentStartX,
        progressBarY - 25,
        120,
        18
    );
    [currentTimeStr drawInRect:currentTimeRect withAttributes:timeAttrs];
    
    // Status text (center) - Enhanced with catch-up indicator
    NSColor *statusTextColor = [NSColor whiteColor];
    
    // Use green color when hovering over progress bar
    if (self.isHoveringProgressBar) {
        statusTextColor = [NSColor colorWithCalibratedRed:0.2 green:0.9 blue:0.2 alpha:1.0]; // Bright green
    }
    
    NSDictionary *statusAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: statusTextColor,
        NSParagraphStyleAttributeName: centerStyle
    };
    
    NSRect statusRect = NSMakeRect(
        contentStartX + 120,
        progressBarY - 25,
        contentWidth - 240,
        18
    );
    [programStatusStr drawInRect:statusRect withAttributes:statusAttrs];
    
    // End time (right)
    NSDictionary *rightTimeAttrs = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor whiteColor],
        NSParagraphStyleAttributeName: rightStyle
    };
    
    NSRect totalTimeRect = NSMakeRect(
        contentStartX + contentWidth - 120,
        progressBarY - 25,
        120,
        18
    );
    [totalTimeStr drawInRect:totalTimeRect withAttributes:rightTimeAttrs];
    
    // Video quality info (top right corner, separate from other text) - REMOVED: Now shown in center status
    /*
    if (qualityInfo && [qualityInfo length] > 0) {
        NSDictionary *qualityAttrs = @{
            NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor whiteColor], // Match other text color
            NSParagraphStyleAttributeName: rightStyle
        };
        
        NSRect qualityRect = NSMakeRect(
            contentStartX + contentWidth - 100,
            progressBarY + 40, // Moved 5px down from 45 to 40
            100,
            16
        );
        [qualityInfo drawInRect:qualityRect withAttributes:qualityAttrs];
    }
    */
    
    // Content description (bottom, spanning full width) - Enhanced for movies
    NSString *description = nil;
    
    // Prioritize movie description for movies, program description for TV
    if (currentChannel && [currentChannel.category isEqualToString:@"MOVIES"] && 
        currentChannel.movieDescription && [currentChannel.movieDescription length] > 0) {
        description = currentChannel.movieDescription;
    } else if (currentProgram && currentProgram.programDescription && [currentProgram.programDescription length] > 0) {
        description = currentProgram.programDescription;
    }
    
    if (description && [description length] > 0) {
        // Truncate description if too long
        if ([description length] > 120) {
            description = [[description substringToIndex:117] stringByAppendingString:@"..."];
        }
        
        NSDictionary *descAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.9 green:0.9 blue:0.9 alpha:0.8],
            NSParagraphStyleAttributeName: leftStyle
        };
        
        NSRect descRect = NSMakeRect(
            contentStartX,
            progressBarY - 45,
            contentWidth,
            16
        );
        [description drawInRect:descRect withAttributes:descAttrs];
    }
    
    // Additional movie metadata (rating, director) for movies
    if (currentChannel && [currentChannel.category isEqualToString:@"MOVIES"] && currentChannel.hasLoadedMovieInfo) {
        NSMutableArray *metadataParts = [NSMutableArray array];
        
        if (currentChannel.movieRating && [currentChannel.movieRating length] > 0) {
            float rating = [currentChannel.movieRating floatValue];
            if (rating > 0) {
                [metadataParts addObject:[NSString stringWithFormat:@"★ %.1f", rating]];
            }
        }
        
        if (currentChannel.movieDirector && [currentChannel.movieDirector length] > 0) {
            [metadataParts addObject:[NSString stringWithFormat:@"Dir: %@", currentChannel.movieDirector]];
        }
        
        if (metadataParts.count > 0) {
            NSString *metadata = [metadataParts componentsJoinedByString:@" • "];
            
            NSDictionary *metadataAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.7 green:0.7 blue:0.7 alpha:0.9],
                NSParagraphStyleAttributeName: leftStyle
            };
            
            NSRect metadataRect = NSMakeRect(
                contentStartX,
                progressBarY - 65,
                contentWidth,
                14
            );
            [metadata drawInRect:metadataRect withAttributes:metadataAttrs];
        }
    }
    
    // Add subtitle and audio dropdown buttons on the bottom right
    CGFloat buttonHeight = 32;
    CGFloat buttonSpacing = 8;
    CGFloat buttonPadding = 16; // Horizontal padding inside buttons
    CGFloat buttonY = controlsRect.origin.y + 10; // Position 10px from bottom of control panel
    
    // Get current subtitle and audio states and track names
    BOOL hasSubtitles = NO;
    BOOL hasAudio = NO;
    NSString *currentSubtitleName = nil;
    NSString *currentAudioName = nil;
    
    if (self.player) {
        // Get current subtitle track
        VLCMediaPlayerTrack *currentSubtitleTrack = nil;
        NSArray<VLCMediaPlayerTrack *> *textTracks = [self.player textTracks];
        for (VLCMediaPlayerTrack *track in textTracks) {
            if (track.selected) {
                currentSubtitleTrack = track;
                break;
            }
        }
        
        // Get current audio track
        VLCMediaPlayerTrack *currentAudioTrack = nil;
        NSArray<VLCMediaPlayerTrack *> *audioTracks = [self.player audioTracks];
        for (VLCMediaPlayerTrack *track in audioTracks) {
            if (track.selected) {
                currentAudioTrack = track;
                break;
            }
        }
        
        hasSubtitles = (currentSubtitleTrack != nil);
        hasAudio = (audioTracks.count > 0);
        
        // Get current subtitle track name
        if (hasSubtitles) {
            currentSubtitleName = currentSubtitleTrack.trackName;
            // Skip "Disable" entries
            if ([currentSubtitleName isEqualToString:@"Disable"]) {
                currentSubtitleName = nil;
                hasSubtitles = NO;
            }
        }
        
        // Get current audio track name
        if (hasAudio && currentAudioTrack) {
            currentAudioName = currentAudioTrack.trackName;
        }
    }
    
    // Calculate subtitle button content and size
    NSString *subtitleButtonText = hasSubtitles && currentSubtitleName ? currentSubtitleName : @"CC";
    if (hasSubtitles && currentSubtitleName && [currentSubtitleName length] > 20) {
        // Truncate long track names
        subtitleButtonText = [[currentSubtitleName substringToIndex:17] stringByAppendingString:@"..."];
    }
    
    NSDictionary *buttonTextAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    
    NSSize subtitleTextSize = [subtitleButtonText sizeWithAttributes:buttonTextAttrs];
    CGFloat subtitleButtonWidth = subtitleTextSize.width + buttonPadding;
    subtitleButtonWidth = MAX(subtitleButtonWidth, 32); // Minimum width
    
    // Calculate audio button content and size
    NSString *audioButtonText = hasAudio && currentAudioName ? currentAudioName : @"♪";
    if (hasAudio && currentAudioName && [currentAudioName length] > 20) {
        // Truncate long track names
        audioButtonText = [[currentAudioName substringToIndex:17] stringByAppendingString:@"..."];
    }
    
    NSSize audioTextSize = [audioButtonText sizeWithAttributes:buttonTextAttrs];
    CGFloat audioButtonWidth = audioTextSize.width + buttonPadding;
    audioButtonWidth = MAX(audioButtonWidth, 32); // Minimum width
    
    // Calculate button positions (right-aligned)
    CGFloat totalButtonsWidth = subtitleButtonWidth + audioButtonWidth + buttonSpacing;
    CGFloat buttonsStartX = contentStartX + contentWidth - totalButtonsWidth;
    
    // Subtitle button
    NSRect subtitleButtonRect = NSMakeRect(buttonsStartX, buttonY, subtitleButtonWidth, buttonHeight);
    self.subtitlesButtonRect = subtitleButtonRect;
    
    // Audio button  
    NSRect audioButtonRect = NSMakeRect(buttonsStartX + subtitleButtonWidth + buttonSpacing, buttonY, audioButtonWidth, buttonHeight);
    self.audioButtonRect = audioButtonRect;
    
    // Draw subtitle button with state-based colors
    NSBezierPath *subtitleBg = [NSBezierPath bezierPathWithRoundedRect:subtitleButtonRect xRadius:6 yRadius:6];
    if (hasSubtitles) {
        // Active state - blue background
        [[NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.8 alpha:0.9] set];
    } else {
        // Inactive state - dark background
        [[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:0.8] set];
    }
    [subtitleBg fill];
    
    // Subtitle icon (CC or track name)
    NSRect subtitleTextRect = NSMakeRect(
        subtitleButtonRect.origin.x + (subtitleButtonWidth - subtitleTextSize.width) / 2,
        subtitleButtonRect.origin.y + (buttonHeight - subtitleTextSize.height) / 2,
        subtitleTextSize.width,
        subtitleTextSize.height
    );
    [subtitleButtonText drawInRect:subtitleTextRect withAttributes:buttonTextAttrs];
    
    // Draw audio button with state-based colors
    NSBezierPath *audioBg = [NSBezierPath bezierPathWithRoundedRect:audioButtonRect xRadius:6 yRadius:6];
    if (hasAudio) {
        // Active state - blue background
        [[NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.8 alpha:0.9] set];
    } else {
        // Inactive state - dark background
        [[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:0.8] set];
    }
    [audioBg fill];
    
    // Audio icon (♪ or track name)
    NSRect audioTextRect = NSMakeRect(
        audioButtonRect.origin.x + (audioButtonWidth - audioTextSize.width) / 2,
        audioButtonRect.origin.y + (buttonHeight - audioTextSize.height) / 2,
        audioTextSize.width,
        audioTextSize.height
    );
    [audioButtonText drawInRect:audioTextRect withAttributes:buttonTextAttrs];
    
    // Draw catch-up indicator if needed - use subtle icon instead of text
    if (showCatchupIndicator) {
        // Draw a subtle timeshift icon in the top-right corner
        NSRect iconRect = NSMakeRect(
            controlsRect.origin.x + controlsRect.size.width - 40,
            controlsRect.origin.y + controlsRect.size.height - 30,
            20,
            20
        );
        
        // Draw subtle white transparent timeshift icon
        NSString *timeshiftIcon = @"⏪";
        NSDictionary *iconAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:16],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.6],
            NSParagraphStyleAttributeName: centerStyle
        };
        
        [timeshiftIcon drawInRect:iconRect withAttributes:iconAttrs];
    }
    
    [leftStyle release];
    [rightStyle release];
    [centerStyle release];
}

// Method to handle clicks on the player controls
- (BOOL)handlePlayerControlsClickAtPoint:(NSPoint)point {
    NSLog(@"handlePlayerControlsClickAtPoint called with point: (%.1f, %.1f)", point.x, point.y);
    
    // Only process clicks if player controls are visible
    if (!playerControlsVisible || !self.player) {
        NSLog(@"Controls not visible (%@) or no player (%@)", 
              playerControlsVisible ? @"YES" : @"NO", 
              self.player ? @"YES" : @"NO");
        return NO;
    }
    
    // First check if the click is within the overall player controls area
    if (!NSPointInRect(point, self.playerControlsRect)) {
        NSLog(@"Click outside player controls rect: %@", NSStringFromRect(self.playerControlsRect));
        return NO;
    }
    
    NSLog(@"Click is within player controls area");
    NSLog(@"Subtitle button rect: %@", NSStringFromRect(self.subtitlesButtonRect));
    NSLog(@"Audio button rect: %@", NSStringFromRect(self.audioButtonRect));
    
    // Check if click is on subtitle button FIRST (before other checks)
    if (NSPointInRect(point, self.subtitlesButtonRect)) {
        NSLog(@"SUBTITLE BUTTON CLICKED!");
        [self showSubtitleDropdown];
        [self resetPlayerControlsTimer]; // Keep controls visible
        return YES; // Don't toggle controls
    }
    
    // Check if click is on audio button FIRST (before other checks)
    if (NSPointInRect(point, self.audioButtonRect)) {
        NSLog(@"AUDIO BUTTON CLICKED!");
        [self showAudioDropdown];
        [self resetPlayerControlsTimer]; // Keep controls visible
        return YES; // Don't toggle controls
    }
    
    // Note: Control area dimensions are already defined in drawPlayerControls method
    
    // Check if click is on the progress bar
    if (NSPointInRect(point, self.progressBarRect)) {
        // Calculate the position relative to the progress bar
        CGFloat relativeX = point.x - self.progressBarRect.origin.x;
        CGFloat relativePosition = relativeX / self.progressBarRect.size.width;
        relativePosition = MIN(1.0, MAX(0.0, relativePosition)); // Clamp between 0 and 1
        
        // Check if we're playing timeshift content
        BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
        
        if (isTimeshiftPlaying) {
            // Handle timeshift seeking
            [self handleTimeshiftSeek:relativePosition];
        } else {
            // Get current channel and program information for normal seeking
        VLCChannel *currentChannel = nil;
        VLCProgram *currentProgram = nil;
        
        if (self.selectedChannelIndex >= 0 && self.selectedChannelIndex < [self.simpleChannelNames count]) {
            // Get the current channel
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
                    if (channelsInGroup && self.selectedChannelIndex < channelsInGroup.count) {
                        currentChannel = [channelsInGroup objectAtIndex:self.selectedChannelIndex];
                        
                        // Get current program for this channel based on current time
                        if (currentChannel.programs && currentChannel.programs.count > 0) {
                            currentProgram = [currentChannel currentProgramWithTimeOffset:self.epgTimeOffsetHours];
                            
                            // Debug logging to understand program selection
                            if (currentProgram) {
                                //NSLog(@"Player Controls - Selected current program: %@ (%@ - %@)", 
                                //      currentProgram.title, currentProgram.startTime, currentProgram.endTime);
                                //NSLog(@"Player Controls - EPG offset: %ld hours", (long)self.epgTimeOffsetHours);
                            } else {
                               // NSLog(@"Player Controls - No current program found for channel: %@", currentChannel.name);
                            }
                        }
                    }
                }
            }
        }
        
            // Handle normal seeking
            [self handleNormalSeek:relativePosition currentChannel:currentChannel currentProgram:currentProgram];
        }
            
            // Reset the auto-hide timer
            [self resetPlayerControlsTimer];
                    return YES;
    }
    
    // If click was on controls but not on specific elements, just reset timer (don't toggle)
    [self resetPlayerControlsTimer];
    return YES;
}

// Reset the timer for auto-hiding controls
- (void)resetPlayerControlsTimer {
    // Update last interaction time
    lastMouseMoveTime = [NSDate timeIntervalSinceReferenceDate];
    
    // Clear any existing timer
    self.playerControlsTimer = nil;
    
    // Create a new 5-second auto-hide timer
    VLCTimerTarget *timerTarget = objc_getAssociatedObject(self, &timerTargetKey);
    if (!timerTarget) {
        timerTarget = [[VLCTimerTarget alloc] init];
        timerTarget.overlayView = self;
        objc_setAssociatedObject(self, &timerTargetKey, timerTarget, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // Create new timer for 5 seconds
    NSTimer *hideTimer = [NSTimer timerWithTimeInterval:5.0
                                                 target:timerTarget
                                               selector:@selector(timerFired:)
                                               userInfo:nil
                                                repeats:NO];
    
    // Store the timer
    self.playerControlsTimer = hideTimer;
    
    // Restart the refresh timer to keep updating the display
    if (playerControlsVisible) {
        // Refresh EPG information when timer is reset (on any interaction)
        [self refreshCurrentEPGInfo];
        [self startPlayerControlsRefreshTimer];
    }
}

- (void)hidePlayerControls:(NSTimer *)timer {
    // Log the call with timestamp
    //NSLog(@"[%@] hidePlayerControls called", [NSDate date]);
    
    // Check if this is the current timer
    //if (timer != self.playerControlsTimer) {
    //    NSLog(@"WARNING: Timer mismatch - current timer is: %@", self.playerControlsTimer);
    //}
    
    // Get current visibility state for logging
    BOOL wasVisible = playerControlsVisible;
    
    // Clear the reference first to avoid potential double-invalidation
    self.playerControlsTimer = nil;
    
    // Stop the refresh timer since controls are being hidden
    [self stopPlayerControlsRefreshTimer];
    
    // Force hide the controls regardless of current state
    playerControlsVisible = NO;
    
    // Calculate the area where controls were displayed
    CGFloat controlHeight = 140; // Updated to match new design
    CGFloat controlsY = 30; // Updated to match new design
    NSRect controlsRect = NSMakeRect(
        self.bounds.size.width * 0.1, // Updated to match new design
        controlsY,
        self.bounds.size.width * 0.8, // Updated to match new design
        controlHeight
    );
    
    // Force a redraw to hide the controls - use synchronous redraw to ensure it happens
   /// NSLog(@"FORCING redraw to hide controls (was visible: %@)", 
    //      wasVisible ? @"YES" : @"NO");
          
    // Force redraw of ONLY the controls area
    [self setNeedsDisplayInRect:controlsRect];
    // Also redraw entire view to be safe
    [self setNeedsDisplay:YES];
    // Also try forcing the window to update
    [[self window] display];
}

// Add method to show/hide player controls
- (void)togglePlayerControls {
    playerControlsVisible = !playerControlsVisible;
   //NSLog(@"Toggling player controls - now %@", playerControlsVisible ? @"visible" : @"hidden");
    
    if (playerControlsVisible) {
        // Refresh EPG information when controls are toggled on to ensure current program is shown
        [self refreshCurrentEPGInfo];
        [self resetPlayerControlsTimer];
        [self startPlayerControlsRefreshTimer];
    } else {
        // If hiding, invalidate both timers
        self.playerControlsTimer = nil; // Will automatically invalidate existing timer
        [self stopPlayerControlsRefreshTimer];
    }
    
    // Force a display update
    [self setNeedsDisplay:YES];
    [[self window] display];
}

#pragma mark - Setup Methods

- (void)setupPlayerControls {
    NSLog(@"Setting up player controls");
    
    // Initialize player controls visibility
    playerControlsVisible = NO;
    
    NSLog(@"Player controls setup complete");
}

// Start the refresh timer to update controls while visible
- (void)startPlayerControlsRefreshTimer {
    // Stop any existing refresh timer first
    [self stopPlayerControlsRefreshTimer];
    
    // Get or create refresh timer target (prevents retain cycles)
    VLCRefreshTimerTarget *refreshTarget = objc_getAssociatedObject(self, &refreshTimerTargetKey);
    if (!refreshTarget) {
        refreshTarget = [[VLCRefreshTimerTarget alloc] init];
        refreshTarget.overlayView = self;
        objc_setAssociatedObject(self, &refreshTimerTargetKey, refreshTarget, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // Create refresh timer that fires every second
    NSTimer *refreshTimer = [NSTimer timerWithTimeInterval:1.0
                                                    target:refreshTarget
                                                  selector:@selector(refreshTimerFired:)
                                                  userInfo:nil
                                                   repeats:YES];
    
    // Add to run loop
    [[NSRunLoop mainRunLoop] addTimer:refreshTimer forMode:NSRunLoopCommonModes];
    
    // Store the refresh timer
    self.playerControlsRefreshTimer = refreshTimer;
}

// Stop the refresh timer
- (void)stopPlayerControlsRefreshTimer {
    self.playerControlsRefreshTimer = nil; // Will automatically invalidate existing timer
}

// Refresh current EPG information to ensure we show the correct program
- (void)refreshCurrentEPGInfo {
    // Safety check: Clear frozen values if we're not actively seeking
    if (![self isTimeshiftSeeking] && [self getFrozenTimeValues]) {
        //NSLog(@"Safety cleanup: Clearing orphaned frozen time values");
        [self clearFrozenTimeValues];
    }
    
    // CRITICAL: Check if we're actually playing timeshift content vs live content
    BOOL isActuallyTimeshift = [self isCurrentlyPlayingTimeshift];
    
    // STARTUP TRANSITION DETECTION: If we have cached timeshift data but we're playing live content,
    // this means we just switched from timeshift to live (e.g., on startup), so clear the cached data
    VLCChannel *cachedTimeshiftChannel = [self getCachedTimeshiftChannel];
    if (!isActuallyTimeshift && cachedTimeshiftChannel) {
        NSLog(@"🔄 TRANSITION DETECTION: Playing live content but have cached timeshift data - clearing cache");
        [self clearCachedTimeshiftChannel];
        [self clearCachedTimeshiftProgramInfo];
        [self clearFrozenTimeValues];
        
        // Force UI update to reflect the transition
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsDisplay:YES];
        });
    }
    
    // DYNAMIC TIMESHIFT EPG TRACKING: If we're playing timeshift content,
    // continuously update the program information based on current playing time
    // BUT SKIP UPDATES WHEN HOVERING to prevent overriding hover display
    if (isActuallyTimeshift && !self.isHoveringProgressBar) {
        //NSLog(@"🔄 CALLING updateTimeshiftEPGFromCurrentPlayingTime for dynamic tracking");
        [self updateTimeshiftEPGFromCurrentPlayingTime];
    } else if (isActuallyTimeshift && self.isHoveringProgressBar) {
        //NSLog(@"⏸️ SKIPPING dynamic EPG update while hovering to preserve hover display");
    } else {
        //NSLog(@"Playing live content - using standard EPG refresh logic");
    }
    
    // This method ensures that the current program information is always up-to-date
    // when the player controls are visible. It's called every second by the refresh timer.
    
    // Get current channel to refresh its program information
    VLCChannel *currentChannel = nil;
    
    // First try to get from current selection if channels are loaded
    if (self.selectedChannelIndex >= 0 && self.selectedChannelIndex < [self.simpleChannelNames count]) {
        // Try to get the channel from the current selection
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
                if (channelsInGroup && self.selectedChannelIndex < channelsInGroup.count) {
                    currentChannel = [channelsInGroup objectAtIndex:self.selectedChannelIndex];
                }
            }
        }
    }
    
    // If we don't have a current channel from selection, try the cached early playback channel
    if (!currentChannel) {
        currentChannel = objc_getAssociatedObject(self, "tempEarlyPlaybackChannelKey");
    }
    
    // If we have a channel, refresh its current program information
    if (currentChannel) {
        VLCProgram *currentProgram = nil;
        
        // STARTUP PRIORITY: First check if we have cached program info from startup policy
        // This ensures we respect the startup policy's EPG calculation over real-time calculation
        NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
        NSDictionary *cachedProgramInfo = [cachedInfo objectForKey:@"currentProgram"];
        
        // FIXED: Prioritize startup cached data during initial startup
        // Check if we're in startup mode by seeing if we have early playback channel set
        VLCChannel *earlyPlaybackChannel = objc_getAssociatedObject(self, "tempEarlyPlaybackChannelKey");
        BOOL isInStartupMode = (earlyPlaybackChannel != nil);
        
        if (cachedProgramInfo && (!isActuallyTimeshift || isInStartupMode)) {
            // Use cached program info from startup policy for live content OR during startup
            currentProgram = [[VLCProgram alloc] init];
            currentProgram.title = [cachedProgramInfo objectForKey:@"title"];
            currentProgram.programDescription = [cachedProgramInfo objectForKey:@"description"];
            currentProgram.startTime = [cachedProgramInfo objectForKey:@"startTime"];
            currentProgram.endTime = [cachedProgramInfo objectForKey:@"endTime"];
            
            [currentProgram autorelease];
            
            // Log to verify we're using startup cached data
            if (isInStartupMode) {
                //NSLog(@"🎯 STARTUP: Using cached program from startup policy: %@", currentProgram.title);
            }
        } else {
            //NSLog(@"EPG Info: Using real-time calculation (cached: %@, timeshift: %@, startup: %@)", 
            //      cachedProgramInfo ? @"YES" : @"NO", isActuallyTimeshift ? @"YES" : @"NO", isInStartupMode ? @"YES" : @"NO");
            // Fallback to real-time calculation
            // The currentProgramWithTimeOffset method automatically calculates the current program
            // based on the current time, so calling it refreshes the information
            currentProgram = [currentChannel currentProgramWithTimeOffset:self.epgTimeOffsetHours];
        }
        
        // Log program changes for debugging
        static VLCProgram *lastProgram = nil;
        static NSString *lastProgramTitle = nil;
        
        if (currentProgram && currentProgram.title) {
            if (!lastProgramTitle || ![lastProgramTitle isEqualToString:currentProgram.title]) {
              //  NSLog(@"EPG Info: Program changed to '%@' on channel '%@' (Live: %@)", 
              //        currentProgram.title, currentChannel.name, isActuallyTimeshift ? @"NO" : @"YES");
                
                // Update our tracking
                [lastProgramTitle release];
                lastProgramTitle = [currentProgram.title retain];
                lastProgram = currentProgram;
            }
        } else if (lastProgramTitle) {
            //NSLog(@"EPG Info: No current program found for channel '%@' (Live: %@)", 
            //      currentChannel.name, isActuallyTimeshift ? @"NO" : @"YES");
            [lastProgramTitle release];
            lastProgramTitle = nil;
            lastProgram = nil;
        }
        objc_setAssociatedObject(self, "tempEarlyPlaybackChannelKey", currentChannel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        
        // RUNTIME CATCH-UP MONITORING: Check if any programs have become past and mark them for catch-up
        [self updateRuntimeCatchupStatus:currentChannel];
    }
}

// NEW METHOD: Runtime monitoring of program status changes for catch-up availability
- (void)updateRuntimeCatchupStatus:(VLCChannel *)channel {
    if (!channel || !channel.supportsCatchup || !channel.programs || channel.programs.count == 0) {
        return;
    }
    
    // Apply EPG time offset to current time for proper comparison
    NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600.0;
    NSDate *adjustedNow = [[NSDate date] dateByAddingTimeInterval:offsetSeconds];
    NSTimeInterval catchupWindow = channel.catchupDays * 24 * 60 * 60; // Convert days to seconds
    
    BOOL hasUpdates = NO;
    static NSMutableSet *notifiedPrograms = nil;
    if (!notifiedPrograms) {
        notifiedPrograms = [[NSMutableSet alloc] init];
    }
    
    for (VLCProgram *program in channel.programs) {
        if (!program.endTime) continue;
        
        // Check if program just ended (became past)
        NSTimeInterval timeSinceEnd = [adjustedNow timeIntervalSinceDate:program.endTime];
        
        if (timeSinceEnd > 0 && timeSinceEnd <= catchupWindow) {
            // Program is past and within catch-up window
            if (!program.hasArchive) {
                // Mark program as having catch-up available
                program.hasArchive = YES;
                if (program.archiveDays == 0) {
                    program.archiveDays = channel.catchupDays;
                }
                hasUpdates = YES;
                
                // Create unique identifier for this program
                NSString *programKey = [NSString stringWithFormat:@"%@_%@_%@", 
                                       channel.name, program.title, program.startTime];
                
                // Only log once per program to avoid spam
                if (![notifiedPrograms containsObject:programKey]) {
                    NSLog(@"RUNTIME CATCH-UP: Program '%@' on '%@' is now available for catch-up (ended %.1f minutes ago)", 
                          program.title, channel.name, timeSinceEnd / 60.0);
                    [notifiedPrograms addObject:programKey];
                }
            }
        } else if (timeSinceEnd > catchupWindow && program.hasArchive) {
            // Program is too old, remove catch-up availability
            program.hasArchive = NO;
            program.archiveDays = 0;
            hasUpdates = YES;
            
            NSString *programKey = [NSString stringWithFormat:@"%@_%@_%@", 
                                   channel.name, program.title, program.startTime];
            [notifiedPrograms removeObject:programKey];
            
            NSLog(@"RUNTIME CATCH-UP: Program '%@' on '%@' is no longer available for catch-up (too old)", 
                  program.title, channel.name);
        }
    }
    
    // If we made updates, trigger UI refresh and save to cache
    if (hasUpdates) {
        // Trigger UI update to show new catch-up indicators
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsDisplay:YES];
            
            // If EPG menu is currently visible, force a refresh
            if (self.isChannelListVisible) {
                [self setNeedsDisplay:YES];
            }
        });
        
        // Save updated EPG data to cache (async to avoid blocking)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [self saveEpgDataToCache];
        });
    }
}

#pragma mark - Subtitle and Audio Track Methods

- (void)showSubtitleDropdown {
    NSLog(@"showSubtitleDropdown called!");
    
    if (!self.player) {
        NSLog(@"No player - cannot show subtitle dropdown");
        return;
    }
    
    // Ensure dropdown manager exists
    if (!self.dropdownManager) {
        NSLog(@"No dropdown manager - cannot show subtitle dropdown");
        return;
    }
    
    NSLog(@"Creating subtitle dropdown...");
    
    // Get available subtitle tracks (refresh from player)
    NSArray<VLCMediaPlayerTrack *> *textTracks = [self.player textTracks];
    VLCMediaPlayerTrack *currentSubtitleTrack = nil;
    for (VLCMediaPlayerTrack *track in textTracks) {
        if (track.selected) {
            currentSubtitleTrack = track;
            break;
        }
    }
    
    NSLog(@"=== SUBTITLE TRACKS DEBUG ===");
    NSLog(@"Found %ld subtitle tracks:", (long)textTracks.count);
    for (NSInteger i = 0; i < textTracks.count; i++) {
        VLCMediaPlayerTrack *track = [textTracks objectAtIndex:i];
        NSLog(@"  Track %ld: [%@] '%@'%@", i, track.trackId, track.trackName, track.selected ? @" (CURRENT)" : @"");
    }
    NSLog(@"Current subtitle track: %@", currentSubtitleTrack ? currentSubtitleTrack.trackName : @"None");
    
    // Also check VLC's subtitle support
    NSLog(@"VLC subtitle support - hasVideoOut: %@", [self.player hasVideoOut] ? @"YES" : @"NO");
    NSLog(@"Media duration: %@", [self.player.media length]);
    NSLog(@"Player state: %ld", (long)[self.player state]);
    NSLog(@"==============================");
    
    // Create dropdown with identifier using a wider frame
    NSString *identifier = @"subtitles";
    
    // Create a wider frame for the dropdown (keeping it aligned to the button)
    CGFloat dropdownWidth = 250; // Much wider to show full track names
    CGFloat dropdownHeight = 32; // Same height as button
    
    // Calculate how many items we'll have to determine dropdown height
    NSInteger itemCount = 1; // At least the "OFF" option
    if (textTracks && textTracks.count > 0) {
        itemCount += textTracks.count;
    }
    
    // Calculate actual dropdown height based on items (max 8 visible)
    NSInteger visibleItems = MIN(itemCount, 8);
    CGFloat actualDropdownHeight = visibleItems * dropdownHeight;
    
    // Position dropdown ABOVE the button so it opens upward
    NSRect dropdownFrame = NSMakeRect(
        self.subtitlesButtonRect.origin.x - (dropdownWidth - self.subtitlesButtonRect.size.width), // Align right edge
        self.subtitlesButtonRect.origin.y + actualDropdownHeight + 5, // Position dropdown above button with 5px gap
        dropdownWidth,
        actualDropdownHeight
    );
    
    VLCDropdown *dropdown = [self.dropdownManager createDropdownWithIdentifier:identifier frame:dropdownFrame];
    
    // Configure dropdown
    dropdown.backgroundColor = [NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:0.95];
    dropdown.textColor = [NSColor whiteColor];
    dropdown.hoveredColor = [NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.8 alpha:1.0];
    dropdown.borderColor = [NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:0.8];
    dropdown.maxVisibleOptions = 8;
    
    // Add items
    if (!textTracks || textTracks.count == 0) {
        // No subtitle tracks available - add default "OFF" option
        VLCDropdownItem *offItem = [[VLCDropdownItem alloc] init];
        offItem.value = nil; // Use nil to represent OFF
        offItem.displayText = @"OFF";
        offItem.isSelected = YES; // Always selected when no tracks
        
        [dropdown addItem:offItem];
        [offItem release];
    } else {
        // Add "OFF" option first so users can disable subtitles
        VLCDropdownItem *offItem = [[VLCDropdownItem alloc] init];
        offItem.value = nil; // Use nil to represent OFF
        offItem.displayText = @"OFF";
        offItem.isSelected = (currentSubtitleTrack == nil);
        
        [dropdown addItem:offItem];
        [offItem release];
        
        // Add available subtitle tracks
        for (VLCMediaPlayerTrack *track in textTracks) {
            // Skip "Disable" entries - treat them as OFF
            if ([track.trackName isEqualToString:@"Disable"]) {
                continue;
            }
            
            VLCDropdownItem *item = [[VLCDropdownItem alloc] init];
            item.value = track; // Store the track object itself
            item.displayText = track.trackName;
            item.isSelected = track.selected;
            
            [dropdown addItem:item];
            [item release];
        }
    }
    
    // Set selection callback
    dropdown.onSelectionChanged = ^(VLCDropdown *sender, VLCDropdownItem *selectedItem, NSInteger selectedIndex) {
        NSLog(@"Subtitle track selected: %@", selectedItem.displayText);
        
        if (selectedItem.value && [selectedItem.value isKindOfClass:[VLCMediaPlayerTrack class]]) {
            // Enable subtitles and set the track
            VLCMediaPlayerTrack *selectedTrack = (VLCMediaPlayerTrack *)selectedItem.value;
            NSLog(@"Setting subtitle track to: %@ (ID: %@)", selectedTrack.trackName, selectedTrack.trackId);
            
            // First deselect all text tracks
            [self.player deselectAllTextTracks];
            
            // Then select the chosen track exclusively
            selectedTrack.selectedExclusively = YES;
            
            // Force a redraw to update button state
            [self setNeedsDisplay:YES];
            
            NSLog(@"Subtitle track set successfully");
        } else {
            // Disable subtitles (OFF selected)
            NSLog(@"Disabling subtitles (OFF selected)");
            
            // Deselect all text tracks
            [self.player deselectAllTextTracks];
            
            // Force a redraw to update button state
            [self setNeedsDisplay:YES];
        }
    };
    
    dropdown.onClosed = ^(VLCDropdown *sender) {
        // Dropdown closed
    };
    
    // Show dropdown using the dropdown manager
    NSLog(@"About to show subtitle dropdown with identifier: %@", identifier);
    [self.dropdownManager showDropdown:identifier];
    NSLog(@"Subtitle dropdown show command completed");
}

- (void)showAudioDropdown {
    NSLog(@"showAudioDropdown called!");
    
    if (!self.player) {
        NSLog(@"No player - cannot show audio dropdown");
        return;
    }
    
    // Ensure dropdown manager exists
    if (!self.dropdownManager) {
        NSLog(@"No dropdown manager - cannot show audio dropdown");
        return;
    }
    
    NSLog(@"Creating audio dropdown...");
    
    // Get available audio tracks (refresh from player)
    NSArray<VLCMediaPlayerTrack *> *audioTracks = [self.player audioTracks];
    VLCMediaPlayerTrack *currentAudioTrack = nil;
    for (VLCMediaPlayerTrack *track in audioTracks) {
        if (track.selected) {
            currentAudioTrack = track;
            break;
        }
    }
    
    NSLog(@"Found %ld audio tracks:", (long)audioTracks.count);
    for (NSInteger i = 0; i < audioTracks.count; i++) {
        VLCMediaPlayerTrack *track = [audioTracks objectAtIndex:i];
        NSLog(@"  Track %ld: [%@] %@%@", i, track.trackId, track.trackName, track.selected ? @" (CURRENT)" : @"");
    }
    NSLog(@"Current audio track: %@", currentAudioTrack ? currentAudioTrack.trackName : @"None");
    
    // Create dropdown with identifier using a wider frame
    NSString *identifier = @"audio";
    
    // Create a wider frame for the dropdown (keeping it aligned to the button)
    CGFloat dropdownWidth = 250; // Much wider to show full track names
    CGFloat dropdownHeight = 32; // Same height as button
    
    // Calculate how many items we'll have to determine dropdown height
    NSInteger itemCount = 0;
    if (!audioTracks || audioTracks.count == 0) {
        itemCount = 1; // "No Audio Tracks" message
    } else {
        itemCount = audioTracks.count;
    }
    
    // Calculate actual dropdown height based on items (max 8 visible)
    NSInteger visibleItems = MIN(itemCount, 8);
    CGFloat actualDropdownHeight = visibleItems * dropdownHeight;
    
    // Position dropdown ABOVE the button so it opens upward
    NSRect dropdownFrame = NSMakeRect(
        self.audioButtonRect.origin.x - (dropdownWidth - self.audioButtonRect.size.width), // Align right edge
        self.audioButtonRect.origin.y + actualDropdownHeight + 5, // Position dropdown above button with 5px gap
        dropdownWidth,
        actualDropdownHeight
    );
    
    VLCDropdown *dropdown = [self.dropdownManager createDropdownWithIdentifier:identifier frame:dropdownFrame];
    
    // Configure dropdown
    dropdown.backgroundColor = [NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:0.95];
    dropdown.textColor = [NSColor whiteColor];
    dropdown.hoveredColor = [NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.8 alpha:1.0];
    dropdown.borderColor = [NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:0.8];
    dropdown.maxVisibleOptions = 8;
    
    // Add items
    if (!audioTracks || audioTracks.count == 0) {
        // No audio tracks available - show message
        VLCDropdownItem *noTracksItem = [[VLCDropdownItem alloc] init];
        noTracksItem.value = nil;
        noTracksItem.displayText = @"No Audio Tracks";
        noTracksItem.isSelected = YES;
        
        [dropdown addItem:noTracksItem];
        [noTracksItem release];
    } else {
        // Add available audio tracks (no NONE/OFF option)
        // If no current track is selected, default to first track
        VLCMediaPlayerTrack *trackToSelect = currentAudioTrack;
        if (!currentAudioTrack && audioTracks.count > 0) {
            trackToSelect = [audioTracks objectAtIndex:0];
            // Set the player to use the first track
            trackToSelect.selectedExclusively = YES;
            NSLog(@"No audio track selected, defaulting to first track: %@", trackToSelect.trackName);
        }
        
        for (VLCMediaPlayerTrack *track in audioTracks) {
            VLCDropdownItem *item = [[VLCDropdownItem alloc] init];
            item.value = track; // Store the track object itself
            item.displayText = track.trackName;
            item.isSelected = track.selected;
            
            [dropdown addItem:item];
            [item release];
        }
    }
    
    // Set selection callback
    dropdown.onSelectionChanged = ^(VLCDropdown *sender, VLCDropdownItem *selectedItem, NSInteger selectedIndex) {
        NSLog(@"Audio track selected: %@", selectedItem.displayText);
        
        if (selectedItem.value && [selectedItem.value isKindOfClass:[VLCMediaPlayerTrack class]]) {
            // Set the audio track
            VLCMediaPlayerTrack *selectedTrack = (VLCMediaPlayerTrack *)selectedItem.value;
            NSLog(@"Setting audio track to: %@ (ID: %@)", selectedTrack.trackName, selectedTrack.trackId);
            
            // Select the chosen track exclusively
            selectedTrack.selectedExclusively = YES;
            
            // Force a redraw to update button state
            [self setNeedsDisplay:YES];
            
            NSLog(@"Audio track set successfully");
        } else {
            NSLog(@"Invalid audio track selection");
        }
    };
    
    dropdown.onClosed = ^(VLCDropdown *sender) {
        // Dropdown closed
    };
    
    // Show dropdown using the dropdown manager
    NSLog(@"About to show audio dropdown with identifier: %@", identifier);
    [self.dropdownManager showDropdown:identifier];
    NSLog(@"Audio dropdown show command completed");
}

#pragma mark - Catch-up Methods

- (NSString *)generateCatchupUrlForProgram:(VLCProgram *)program channel:(VLCChannel *)channel {
    if (!program.hasArchive || !program.startTime || !program.endTime) {
        return nil;
    }
    
    // Calculate program duration in minutes
    NSTimeInterval durationSeconds = [program.endTime timeIntervalSinceDate:program.startTime];
    NSInteger durationMinutes = (NSInteger)(durationSeconds / 60);
    
    // Extract server info from channel URL (not M3U URL)
    NSURL *channelURL = [NSURL URLWithString:channel.url];
    if (!channelURL) {
        NSLog(@"Cannot generate catchup URL: invalid channel URL: %@", channel.url);
        return nil;
    }
    
    NSString *scheme = [channelURL scheme];
    NSString *host = [channelURL host];
    NSNumber *port = [channelURL port];
    NSString *baseUrl = [NSString stringWithFormat:@"%@://%@", scheme, host];
    if (port) {
        baseUrl = [baseUrl stringByAppendingFormat:@":%@", port];
    }
    
    // Extract username and password from the channel URL path
    NSString *username = @"";
    NSString *password = @"";
    
    NSString *path = [channelURL path];
    if (path) {
        NSArray *pathComponents = [path pathComponents];
        
        // For Xtream Codes URLs, the format is typically:
        // /live/username/password/stream_id.m3u8
        for (NSInteger i = 0; i < pathComponents.count - 2; i++) {
            NSString *component = pathComponents[i];
            if ([component isEqualToString:@"live"] || [component isEqualToString:@"movie"] || [component isEqualToString:@"series"]) {
                if (i + 2 < pathComponents.count) {
                    username = pathComponents[i + 1];
                    password = pathComponents[i + 2];
                    break;
                }
            }
        }
        
        // If not found with service type, try to find username/password pattern
        if (username.length == 0 && pathComponents.count >= 3) {
            for (NSInteger i = 1; i < pathComponents.count - 1; i++) {
                NSString *potentialUsername = pathComponents[i];
                NSString *potentialPassword = pathComponents[i + 1];
                
                if (potentialUsername.length > 0 && potentialPassword.length > 0 &&
                    ![potentialUsername hasSuffix:@".m3u8"] && ![potentialPassword hasSuffix:@".m3u8"]) {
                    username = potentialUsername;
                    password = potentialPassword;
                    break;
                }
            }
        }
    }
    
    if (username.length == 0 || password.length == 0) {
        NSLog(@"Cannot generate catchup URL: failed to extract username/password from channel URL: %@", channel.url);
        return nil;
    }
    
    // Extract stream_id from channel URL
    NSString *streamId = [self extractStreamIdFromChannelUrl:channel.url];
    if (!streamId) {
        NSLog(@"Cannot generate catchup URL: failed to extract stream ID from channel URL: %@", channel.url);
        return nil;
    }
    
    // Format start time as YYYY-MM-DD:HH-MM
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd:HH-mm"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    
    // Use the original program start time without EPG offset for server request
    // EPG offset is only for display purposes, not for server communication
    NSString *startTimeString = [formatter stringFromDate:program.startTime];
    [formatter release];
    
    NSLog(@"Catchup URL generation: Using original program start time = %@", program.startTime);
    
    // Generate catchup URL using PHP-based format
    NSString *catchupUrl = [NSString stringWithFormat:@"%@/streaming/timeshift.php?username=%@&password=%@&stream=%@&start=%@&duration=%ld",
                           baseUrl, username, password, streamId, startTimeString, (long)durationMinutes];
    
    NSLog(@"Generated catchup URL for program '%@': %@", program.title, catchupUrl);
    return catchupUrl;
}

- (NSString *)generateChannelCatchupUrlForChannel:(VLCChannel *)channel timeOffset:(NSTimeInterval)timeOffset {
    if (!channel.supportsCatchup) {
        NSLog(@"Channel '%@' does not support catch-up", channel.name);
        return nil;
    }
    
    // Check if the time offset is within the supported range
    NSTimeInterval maxOffset = channel.catchupDays * 24 * 3600; // Convert days to seconds
    if (timeOffset > maxOffset) {
        NSLog(@"Time offset %.0f seconds exceeds maximum catch-up period of %ld days for channel '%@'", 
              timeOffset, (long)channel.catchupDays, channel.name);
        return nil;
    }
    
    NSString *catchupUrl = nil;
    
    if (channel.catchupTemplate && [channel.catchupTemplate length] > 0) {
        // Use custom catch-up template if provided
        // Replace placeholders in the template
        // Common placeholders: {utc}, {timestamp}, {duration}, {offset}
        NSString *template = channel.catchupTemplate;
        
        // Calculate timestamp for the desired time
        NSDate *targetTime = [[NSDate date] dateByAddingTimeInterval:-timeOffset];
        NSTimeInterval timestamp = [targetTime timeIntervalSince1970];
        
        // Replace common placeholders
        template = [template stringByReplacingOccurrencesOfString:@"{utc}" 
                                                       withString:[NSString stringWithFormat:@"%.0f", timestamp]];
        template = [template stringByReplacingOccurrencesOfString:@"{timestamp}" 
                                                       withString:[NSString stringWithFormat:@"%.0f", timestamp]];
        template = [template stringByReplacingOccurrencesOfString:@"{offset}" 
                                                       withString:[NSString stringWithFormat:@"%.0f", timeOffset]];
        
        catchupUrl = template;
    } else {
        // Generate standard catch-up URL based on the channel's catch-up source type
        NSURL *channelURL = [NSURL URLWithString:channel.url];
        if (!channelURL) {
            NSLog(@"Cannot generate catchup URL: invalid channel URL: %@", channel.url);
            return nil;
        }
        
        NSString *scheme = [channelURL scheme];
        NSString *host = [channelURL host];
        NSNumber *port = [channelURL port];
        NSString *baseUrl = [NSString stringWithFormat:@"%@://%@", scheme, host];
        if (port) {
            baseUrl = [baseUrl stringByAppendingFormat:@":%@", port];
        }
        
        // Extract username and password from the channel URL path
        NSString *username = @"";
        NSString *password = @"";
        
        NSString *path = [channelURL path];
        if (path) {
            NSArray *pathComponents = [path pathComponents];
            
            // For Xtream Codes URLs, the format is typically:
            // /live/username/password/stream_id.m3u8
            for (NSInteger i = 0; i < pathComponents.count - 2; i++) {
                NSString *component = pathComponents[i];
                if ([component isEqualToString:@"live"] || [component isEqualToString:@"movie"] || [component isEqualToString:@"series"]) {
                    if (i + 2 < pathComponents.count) {
                        username = pathComponents[i + 1];
                        password = pathComponents[i + 2];
                        break;
                    }
                }
            }
            
            // If not found with service type, try to find username/password pattern
            if (username.length == 0 && pathComponents.count >= 3) {
                for (NSInteger i = 1; i < pathComponents.count - 1; i++) {
                    NSString *potentialUsername = pathComponents[i];
                    NSString *potentialPassword = pathComponents[i + 1];
                    
                    if (potentialUsername.length > 0 && potentialPassword.length > 0 &&
                        ![potentialUsername hasSuffix:@".m3u8"] && ![potentialPassword hasSuffix:@".m3u8"]) {
                        username = potentialUsername;
                        password = potentialPassword;
                        break;
                    }
                }
            }
        }
        
        if (username.length == 0 || password.length == 0) {
            NSLog(@"Cannot generate catchup URL: failed to extract username/password from channel URL: %@", channel.url);
            return nil;
        }
        
        // Extract stream_id from channel URL
        NSString *streamId = [self extractStreamIdFromChannelUrl:channel.url];
        if (!streamId) {
            NSLog(@"Cannot generate catchup URL: failed to extract stream ID from channel URL: %@", channel.url);
            return nil;
        }
        
        // Calculate target time based on offset
        NSDate *targetTime = [NSDate dateWithTimeIntervalSinceNow:timeOffset];
        
        // Default duration of 2 hours for manual timeshift
        NSInteger durationMinutes = 120;
        
        // Format start time as YYYY-MM-DD:HH-MM
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd:HH-mm"];
        [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
        
        // IMPORTANT: Adjust the target time by the EPG time offset for timeshift URL generation
        // When user has EPG offset (e.g., -1 hour), we need to compensate by subtracting the offset
        // This converts from user's display time back to server time
        NSTimeInterval offsetCompensation = -self.epgTimeOffsetHours * 3600.0; // Convert hours to seconds and negate
        NSDate *adjustedTargetTime = [targetTime dateByAddingTimeInterval:offsetCompensation];
        
        NSString *startTimeString = [formatter stringFromDate:adjustedTargetTime];
        [formatter release];
        
        NSLog(@"Channel catchup URL generation: Original target time = %@", targetTime);
        NSLog(@"Channel catchup URL generation: EPG offset = %ld hours, compensation = %.0f seconds", 
              (long)self.epgTimeOffsetHours, offsetCompensation);
        NSLog(@"Channel catchup URL generation: Adjusted target time for server = %@", adjustedTargetTime);
        
        // Generate catchup URL using PHP-based format
        NSString *catchupUrl = [NSString stringWithFormat:@"%@/streaming/timeshift.php?username=%@&password=%@&stream=%@&start=%@&duration=%ld",
                               baseUrl, username, password, streamId, startTimeString, (long)durationMinutes];
        
        NSLog(@"Generated channel catchup URL: %@", catchupUrl);
        return catchupUrl;
    }
    
    NSLog(@"Generated channel catch-up URL for '%@' (offset: %.0fs): %@", 
          channel.name, timeOffset, catchupUrl);
    return catchupUrl;
}

- (void)playCatchupUrl:(NSString *)catchupUrl seekToTime:(NSTimeInterval)seekTime {
    [self playCatchupUrl:catchupUrl seekToTime:seekTime channel:nil];
}

- (void)playCatchupUrl:(NSString *)catchupUrl seekToTime:(NSTimeInterval)seekTime channel:(VLCChannel *)channel {
    NSLog(@"Playing catch-up content: %@", catchupUrl);
    
    // Cache the channel for timeshift EPG tracking
    if (channel) {
        [self cacheTimeshiftChannel:channel];
        NSLog(@"Cached channel for timeshift: %@ with %ld programs", channel.name, (long)channel.programs.count);
    } else {
        NSLog(@"⚠️ No channel provided for timeshift caching");
    }
    
    NSURL *url = [NSURL URLWithString:catchupUrl];
    if (url) {
        VLCMedia *media = [VLCMedia mediaWithURL:url];
        [self.player setMedia:media];
        
        // Apply subtitle settings if available
        if ([self respondsToSelector:@selector(applyCurrentSettingsToPlayer:)]) {
            // This would need to be implemented or imported
            // [VLCSubtitleSettings applyCurrentSettingsToPlayer:self.player];
        }
        
        // Start playing
        [self.player play];
        
        // Seek to the desired position after a short delay
        if (seekTime > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                VLCTime *seekVLCTime = [VLCTime timeWithInt:(int)(seekTime * 1000)];
                [self.player setTime:seekVLCTime];
            });
        }
    }
}

#pragma mark - Timeshift Detection and Progress

// Method to detect if we're currently playing timeshift content
- (BOOL)isCurrentlyPlayingTimeshift {
    if (!self.player || !self.player.media) {
        return NO;
    }
    
    NSString *currentUrl = [self.player.media.url absoluteString];
    if (!currentUrl) {
        return NO;
    }
    
    // Check if URL contains timeshift parameters
    return ([currentUrl rangeOfString:@"timeshift.php"].location != NSNotFound ||
            [currentUrl rangeOfString:@"timeshift"].location != NSNotFound);
}

// Helper method to format program strings with dimming support
- (NSString *)formatProgramString:(VLCProgram *)program formatter:(NSDateFormatter *)formatter isDimmed:(BOOL)isDimmed {
    NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
    NSDate *displayProgramStartTime = [program.startTime dateByAddingTimeInterval:displayOffsetSeconds];
    NSDate *displayProgramEndTime = [program.endTime dateByAddingTimeInterval:displayOffsetSeconds];
    
    NSString *startStr = [formatter stringFromDate:displayProgramStartTime];
    NSString *endStr = [formatter stringFromDate:displayProgramEndTime];
    
    // Truncate long program titles
    NSString *title = program.title;
    NSInteger maxLength = isDimmed ? 20 : 25; // Shorter for dimmed programs
    if (title.length > maxLength) {
        title = [[title substringToIndex:(maxLength - 3)] stringByAppendingString:@"..."];
    }
    
    NSString *programStr = [NSString stringWithFormat:@"%@-%@ %@", startStr, endStr, title];
    
    // Add visual indicator for dimmed programs (lighter/smaller appearance)
    if (isDimmed) {
        programStr = [NSString stringWithFormat:@"◦ %@", programStr]; // Use lighter bullet
    }
    
    return programStr;
}

// Method to calculate timeshift progress within a 2-hour sliding window (needle always in middle)
- (void)calculateTimeshiftProgress:(float *)progress 
                   currentTimeStr:(NSString **)currentTimeStr 
                     totalTimeStr:(NSString **)totalTimeStr 
                  programStatusStr:(NSString **)programStatusStr 
                   programTimeRange:(NSString **)programTimeRange 
                     currentChannel:(VLCChannel *)currentChannel 
                     currentProgram:(VLCProgram *)currentProgram {
    
    // Check if we have frozen time values during seeking
    NSDictionary *frozenValues = [self getFrozenTimeValues];
    if (frozenValues && [self isTimeshiftSeeking]) {
        // Use frozen values during seeking to prevent flickering
        *currentTimeStr = [frozenValues objectForKey:@"currentTimeStr"];
        *totalTimeStr = [frozenValues objectForKey:@"totalTimeStr"];
        *programStatusStr = [frozenValues objectForKey:@"programStatusStr"];
        *programTimeRange = @"Seeking to new position...";
        *progress = 0.5; // Keep progress in middle during seeking
        NSLog(@"Using frozen time values during seeking: %@ - %@", *currentTimeStr, *totalTimeStr);
        return;
    }
    
    // Get current playback time
    VLCTime *currentTime = [self.player time];
    if (!currentTime) {
        *progress = 0.5; // Always middle when no time available
        *currentTimeStr = @"--:--";
        *totalTimeStr = @"2:00:00";
        *programStatusStr = @"Timeshift - Loading...";
        *programTimeRange = @"";
        return;
    }
    
    // IMPROVED: For timeshift content, ensure we have proper channel and EPG data
    // If the passed channel/program is nil or doesn't have EPG data, try to get it from cached timeshift channel
    if (!currentChannel || !currentChannel.programs || currentChannel.programs.count == 0) {
        // Try to get the cached timeshift channel
        VLCChannel *cachedChannel = [self getCachedTimeshiftChannel];
        if (cachedChannel && cachedChannel.programs && cachedChannel.programs.count > 0) {
            currentChannel = cachedChannel;
        } else {
            // Fallback: Try to find channel from cached content info
            NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
            NSString *channelName = [cachedInfo objectForKey:@"channelName"];
            
            // Extract original channel name from timeshift name
            NSString *originalChannelName = channelName;
            if (channelName && [channelName containsString:@" (Timeshift:"]) {
                NSRange timeshiftRange = [channelName rangeOfString:@" (Timeshift:"];
                if (timeshiftRange.location != NSNotFound) {
                    originalChannelName = [channelName substringToIndex:timeshiftRange.location];
                }
            }
            
            // Search through loaded channels
            if (originalChannelName && self.channels && self.channels.count > 0) {
                for (VLCChannel *channel in self.channels) {
                    if ([channel.name isEqualToString:originalChannelName]) {
                        currentChannel = channel;
                        
                        // Cache this channel for future use
                        [self cacheTimeshiftChannel:channel];
                        break;
                    }
                }
            }
        }
    }
    
    // Extract timeshift start time from URL
    NSString *currentUrl = [self.player.media.url absoluteString];
    NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
    NSDate *currentRealTime = [NSDate date];
    
    if (timeshiftStartTime) {
        // FIXED: Use sliding 2-hour window centered around current playback position
        
        // Calculate current playback position in seconds from timeshift start
        NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
        NSDate *actualPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
        actualPlayTime = [actualPlayTime dateByAddingTimeInterval:-7200];
       
        
        // Create a 2-hour sliding window centered around current playback position
        NSTimeInterval windowDuration = 7200; // 2 hours in seconds
        NSDate *windowStartTime = [actualPlayTime dateByAddingTimeInterval:-(windowDuration / 2)]; // 1 hour before current
        NSDate *windowEndTime = [actualPlayTime dateByAddingTimeInterval:(windowDuration / 2)];   // 1 hour after current
        
       
        // Adjust window if it goes beyond current real time (can't go into future)
        if ([windowEndTime compare:currentRealTime] == NSOrderedDescending) {
            // Window end is in the future, adjust to end at current real time
            windowEndTime = currentRealTime;
            windowStartTime = [windowEndTime dateByAddingTimeInterval:-windowDuration];
        }
        
        
        // Calculate progress within the sliding window
        NSTimeInterval actualWindowDuration = [windowEndTime timeIntervalSinceDate:windowStartTime];
        NSTimeInterval playTimeOffset = [actualPlayTime timeIntervalSinceDate:windowStartTime];
        
        if (actualWindowDuration > 0) {
            *progress = playTimeOffset / actualWindowDuration;
            *progress = MIN(1.0, MAX(0.0, *progress)); // Clamp between 0 and 1
        } else {
            *progress = 0.5; // Fallback to middle
        }
        
        // Format times for display (with EPG offset applied)
        NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
        [timeFormatter setDateFormat:@"HH:mm:ss"];
        [timeFormatter setTimeZone:[NSTimeZone localTimeZone]];
        
        // Apply EPG offset to window times for display
        // FIXED: EPG offset direction - if EPG offset is -1 hour, we need to ADD 1 hour to display times
        NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
        NSDate *displayWindowStartTime = [windowStartTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSDate *displayWindowEndTime = [windowEndTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSDate *displayCurrentPlayTime = [actualPlayTime dateByAddingTimeInterval:displayOffsetSeconds];
        //displayWindowStartTime = displayCurrentPlayTime;
        //displayWindowStartTime = [displayWindowStartTime dateByAddingTimeInterval: -3600];
        //displayWindowEndTime = displayCurrentPlayTime;
        //displayWindowEndTime = [displayWindowStartTime dateByAddingTimeInterval: 3600];
      
        // Show window start and end times (actual local time without EPG offset for player controls)
        *currentTimeStr = [timeFormatter stringFromDate:windowStartTime];
        *totalTimeStr = [timeFormatter stringFromDate:windowEndTime];
        
        // Calculate how far behind live we are
        NSTimeInterval timeBehindLive = [currentRealTime timeIntervalSinceDate:actualPlayTime];
        
        // Status shows current play position within the sliding window
        if (self.isHoveringProgressBar) {
            // Calculate hover time for display in status
            CGFloat relativeX = self.progressBarHoverPoint.x - self.progressBarRect.origin.x;
            CGFloat relativePosition = relativeX / self.progressBarRect.size.width;
            relativePosition = MIN(1.0, MAX(0.0, relativePosition));
            
          
            // Calculate hover target time within the sliding window (actual local time)
            NSTimeInterval hoverOffsetInWindow = relativePosition * actualWindowDuration;
            NSDate *hoverTargetTime = [windowStartTime dateByAddingTimeInterval:hoverOffsetInWindow];
            
            NSString *hoverTimeStr = [timeFormatter stringFromDate:hoverTargetTime];
            NSString *hoverText = [NSString stringWithFormat:@"Timeshift - Hover: %@ (click to seek)", hoverTimeStr];
            *programStatusStr = hoverText;
            
            // Store the current hover text for potential freezing during seek
            // Create a safe copy to prevent deallocation issues
            NSString *safeHoverTextCopy = [NSString stringWithString:hoverText];
            objc_setAssociatedObject(self, &lastHoverTextKey, safeHoverTextCopy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            // Show current play position within the sliding window (actual local time)
            //NSTimeInterval offset = self.epgTimeOffsetHours * 3600.0 * 2;
            //NSDate *actualPlayTimeTmp = actualPlayTime;
            //actualPlayTimeTmp = [actualPlayTimeTmp dateByAddingTimeInterval:offset];
            NSString *currentPlayTimeStr = [timeFormatter stringFromDate:actualPlayTime];
            
            int behindMins = (int)(timeBehindLive / 60);
            if (behindMins < 60) {
                *programStatusStr = [NSString stringWithFormat:@"Timeshift - Playing: %@ (%d min behind)", currentPlayTimeStr, behindMins];
            } else {
                int behindHours = behindMins / 60;
                int remainingMins = behindMins % 60;
                *programStatusStr = [NSString stringWithFormat:@"Timeshift - Playing: %@ (%dh %dm behind)", currentPlayTimeStr, behindHours, remainingMins];
            }
        }
        
        // Find EPG programs that fall within the timeshift window and display them
        NSString *epgProgramInfo = @"";
        if (currentChannel && currentChannel.programs && currentChannel.programs.count > 0) {
            NSMutableArray *programsInWindow = [NSMutableArray array];
            
            // Find programs that overlap with our window
            for (VLCProgram *program in currentChannel.programs) {
                if (program.startTime && program.endTime) {
                    // Check if program overlaps with our window
                    BOOL programOverlaps = ([program.startTime compare:windowEndTime] == NSOrderedAscending && 
                                          [program.endTime compare:windowStartTime] == NSOrderedDescending);
                    
                    if (programOverlaps) {
                        [programsInWindow addObject:program];
                    }
                }
            }
            
            // HOVER PROGRAM DETECTION FOR TIMESHIFT
            if (self.isHoveringProgressBar) {
                // When hovering over timeshift progress bar, show program at hover position
                CGFloat relativeX = self.progressBarHoverPoint.x - self.progressBarRect.origin.x;
                CGFloat relativePosition = relativeX / self.progressBarRect.size.width;
                relativePosition = MIN(1.0, MAX(0.0, relativePosition));
                
                // Calculate hover target time within the sliding window
                NSTimeInterval hoverOffsetInWindow = relativePosition * actualWindowDuration;
                NSDate *hoverTargetTime = [windowStartTime dateByAddingTimeInterval:hoverOffsetInWindow];
                
                // Apply EPG offset for program matching (FIXED: use negative offset like elsewhere)
                NSTimeInterval epgOffsetSeconds = -self.epgTimeOffsetHours * 3600.0;
                NSDate *adjustedHoverTime = [hoverTargetTime dateByAddingTimeInterval:epgOffsetSeconds];
                
                // Find program at hover position
                VLCProgram *hoverProgram = nil;
                for (VLCProgram *program in currentChannel.programs) {
                    if (program.startTime && program.endTime) {
                        if ([adjustedHoverTime compare:program.startTime] != NSOrderedAscending && 
                            [adjustedHoverTime compare:program.endTime] == NSOrderedAscending) {
                            hoverProgram = program;
                            break;
                        }
                    }
                }
                
                if (hoverProgram) {
                    NSDateFormatter *shortFormatter = [[NSDateFormatter alloc] init];
                    [shortFormatter setDateFormat:@"HH:mm"];
                    [shortFormatter setTimeZone:[NSTimeZone localTimeZone]];
                    
                    NSString *hoverStr = [self formatProgramString:hoverProgram formatter:shortFormatter isDimmed:NO];
                    epgProgramInfo = [NSString stringWithFormat:@"🎯 %@", hoverStr];
                    
                    [shortFormatter release];
                } else {
                    epgProgramInfo = @"🎯 No program at this time";
                }
            } else {
                // NOT HOVERING: Show current playing program
                VLCProgram *currentTimeshiftProgram = [self getCurrentTimeshiftPlayingProgram];
                if (currentTimeshiftProgram && currentTimeshiftProgram.title) {
                    NSDateFormatter *shortFormatter = [[NSDateFormatter alloc] init];
                    [shortFormatter setDateFormat:@"HH:mm"];
                    [shortFormatter setTimeZone:[NSTimeZone localTimeZone]];
                    
                    NSString *currentStr = [self formatProgramString:currentTimeshiftProgram formatter:shortFormatter isDimmed:NO];
                    epgProgramInfo = [NSString stringWithFormat:@"► %@", currentStr];
                    
                    [shortFormatter release];
                } else {
                    epgProgramInfo = @"No current program found";
                }
            }
        } else {
            epgProgramInfo = @"No EPG data available";
        }
        
        *programTimeRange = epgProgramInfo;
        
        [timeFormatter release];
    } else {
        // Fallback when we can't extract timeshift start time
        *progress = 0.5; // Always middle
        
        // Format current time
        NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
        int currentMins = (int)(currentSeconds / 60);
        int currentSecs = (int)(currentSeconds) % 60;
        *currentTimeStr = [NSString stringWithFormat:@"%d:%02d", currentMins, currentSecs];
        
        *totalTimeStr = @"2:00:00";
        *programStatusStr = @"Timeshift - 2 hour window";
        *programTimeRange = @"Timeshift content";
    }
}

// Extract timeshift start time from URL
- (NSDate *)extractTimeshiftStartTimeFromUrl:(NSString *)urlString {
    if (!urlString) return nil;
    
    // Look for start parameter in URL (format: start=2020-12-06:08-00)
    NSRange startRange = [urlString rangeOfString:@"start="];
    if (startRange.location == NSNotFound) {
        return nil;
    }
    
    // Extract the start time string
    NSString *remainingUrl = [urlString substringFromIndex:startRange.location + startRange.length];
    NSRange ampersandRange = [remainingUrl rangeOfString:@"&"];
    
    NSString *startTimeString;
    if (ampersandRange.location != NSNotFound) {
        startTimeString = [remainingUrl substringToIndex:ampersandRange.location];
    } else {
        startTimeString = remainingUrl;
    }
    
    // Parse the time string (format: 2020-12-06:08-00)
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd:HH-mm"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    
    NSDate *startTime = [formatter dateFromString:startTimeString];
    [formatter release];
    
    return startTime;
}

#pragma mark - Seeking Methods

// Handle timeshift seeking by generating new timeshift URL
- (void)handleTimeshiftSeek:(CGFloat)relativePosition {
    
    NSString *currentUrl = [self.player.media.url absoluteString];
    if (!currentUrl) {
        return;
    }
    
    // FREEZE CURRENT TIME VALUES BEFORE SEEKING
    // Get current time values to freeze them during the seeking process
    float currentProgress = 0.0;
    NSString *currentTimeStr = @"--:--";
    NSString *totalTimeStr = @"--:--";
    NSString *programStatusStr = @"";
    NSString *programTimeRange = @"";
    
    // Check if user was hovering when they clicked - if so, capture the hover text
    NSString *lastHoverText = [self getLastHoverText];
    BOOL wasHovering = (lastHoverText != nil && self.isHoveringProgressBar);
    
    // Get current channel and program for time calculation
    VLCChannel *currentChannel = nil;
    VLCProgram *currentProgram = nil;
    
    // IMPROVED: For timeshift seeking, prioritize getting channel from cached timeshift channel
    currentChannel = [self getCachedTimeshiftChannel];
    if (currentChannel && currentChannel.programs && currentChannel.programs.count > 0) {
        NSLog(@"Using cached timeshift channel for seeking: %@ with %ld programs", currentChannel.name, (long)currentChannel.programs.count);
        currentProgram = [self getCurrentTimeshiftPlayingProgram];
    } else {
        // Fallback: Try to get from current selection
        if (self.selectedChannelIndex >= 0 && self.selectedChannelIndex < [self.simpleChannelNames count]) {
            NSString *currentGroup = nil;
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
                
                if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
                    currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
                    
                    NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
                    if (channelsInGroup && self.selectedChannelIndex < channelsInGroup.count) {
                        currentChannel = [channelsInGroup objectAtIndex:self.selectedChannelIndex];
                        currentProgram = [self getCurrentTimeshiftPlayingProgram];
                        
                        // Cache this channel for future use
                        [self cacheTimeshiftChannel:currentChannel];
                        NSLog(@"Found channel from selection for seeking: %@ with %ld programs", currentChannel.name, (long)currentChannel.programs.count);
                    }
                }
            }
        }
        
        // Final fallback: Try to find channel from cached content info
        if (!currentChannel) {
            NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
            NSString *channelName = [cachedInfo objectForKey:@"channelName"];
            
            // Extract original channel name from timeshift name
            NSString *originalChannelName = channelName;
            if (channelName && [channelName containsString:@" (Timeshift:"]) {
                NSRange timeshiftRange = [channelName rangeOfString:@" (Timeshift:"];
                if (timeshiftRange.location != NSNotFound) {
                    originalChannelName = [channelName substringToIndex:timeshiftRange.location];
                }
            }
            
            // Search through loaded channels
            if (originalChannelName && self.channels && self.channels.count > 0) {
                for (VLCChannel *channel in self.channels) {
                    if ([channel.name isEqualToString:originalChannelName]) {
                        currentChannel = channel;
                        currentProgram = [self getCurrentTimeshiftPlayingProgram];
                        
                        // Cache this channel for future use
                        [self cacheTimeshiftChannel:channel];
                        NSLog(@"Found original channel from cached info for seeking: %@ with %ld programs", channel.name, (long)channel.programs.count);
                        break;
                    }
                }
            }
        }
    }
    
    // Calculate current time values to freeze
    [self calculateTimeshiftProgress:&currentProgress 
                     currentTimeStr:&currentTimeStr 
                       totalTimeStr:&totalTimeStr 
                    programStatusStr:&programStatusStr 
                     programTimeRange:&programTimeRange 
                       currentChannel:currentChannel 
                       currentProgram:currentProgram];
    
    // Freeze the time values - use hover text if user was hovering when they clicked
    if (wasHovering && lastHoverText) {
        [self freezeTimeValuesWithHover:currentTimeStr totalTimeStr:totalTimeStr programStatusStr:programStatusStr hoverText:lastHoverText];
    } else {
        [self freezeTimeValues:currentTimeStr totalTimeStr:totalTimeStr programStatusStr:programStatusStr];
    }
    
    // Extract timeshift start time from current URL
    NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
    if (!timeshiftStartTime) {
        [self clearFrozenTimeValues]; // Clear frozen values on error
        return;
    }
    
    // Get current playback position
    VLCTime *currentTime = [self.player time];
    if (!currentTime) {
        [self clearFrozenTimeValues]; // Clear frozen values on error
        return;
    }
    
    // Calculate current actual play time
    NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
    NSDate *currentPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
    //currentPlayTime = [currentPlayTime dateByAddingTimeInterval:self.epgTimeOffsetHours*-3600*2];
    NSDate *currentRealTime = [NSDate date];
    currentRealTime = [currentRealTime dateByAddingTimeInterval:self.epgTimeOffsetHours*-3600*2];
    // FIXED: Use the same sliding window logic as the progress display
    // Create a 2-hour sliding window centered around current playback position
    NSTimeInterval windowDuration = 7200; // 2 hours in seconds
    NSDate *windowStartTime = [currentPlayTime dateByAddingTimeInterval:-(windowDuration / 2)]; // 1 hour before current
    NSDate *windowEndTime = [currentPlayTime dateByAddingTimeInterval:(windowDuration / 2)];   // 1 hour after current
    
    // Adjust window if it goes beyond current real time (can't go into future)
    if ([windowEndTime compare:currentRealTime] == NSOrderedDescending) {
        // Window end is in the future, adjust to end at current real time
        windowEndTime = currentRealTime;
        windowStartTime = [windowEndTime dateByAddingTimeInterval:-windowDuration];
    }
    
    
    // Calculate the target time based on relative position within the sliding window
    NSTimeInterval actualWindowDuration = [windowEndTime timeIntervalSinceDate:windowStartTime];
    NSTimeInterval targetOffsetFromWindowStart = relativePosition * actualWindowDuration;
    NSDate *targetTime = [windowStartTime dateByAddingTimeInterval:targetOffsetFromWindowStart];
    
    // Make sure we don't try to seek into the future beyond real time
    if ([targetTime compare:currentRealTime] == NSOrderedDescending) {
        targetTime = currentRealTime;
    }
    
    // Don't seek if we're already very close to the target time (within 30 seconds)
    NSTimeInterval timeDifference = ABS([targetTime timeIntervalSinceDate:currentPlayTime]);
    
    if (timeDifference < 30) {
        [self clearFrozenTimeValues]; // Clear frozen values when not seeking
        return;
    }
    
    // Generate new timeshift URL for the target time
    NSString *newTimeshiftUrl = [self generateNewTimeshiftUrlFromCurrentUrl:currentUrl newStartTime:targetTime];
    
    if (newTimeshiftUrl) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"EEE HH:mm:ss"];
        [formatter setTimeZone:[NSTimeZone localTimeZone]];
        
        // Apply EPG offset for display
        NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
        NSDate *displayTargetTime = [targetTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSString *targetTimeStr = [formatter stringFromDate:displayTargetTime];
        [formatter release];
        
        
        // Show loading state in UI
        [self setTimeshiftSeekingState:YES];
        
        // Stop current playback
        [self.player stop];
        
        
        // Brief pause to allow VLC to reset
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Create media object with new timeshift URL
            NSURL *url = [NSURL URLWithString:newTimeshiftUrl];
            VLCMedia *media = [VLCMedia mediaWithURL:url];
            
            if (media) {
                // Set the media to the player
                [self.player setMedia:media];
                
                // Apply subtitle settings
                if ([VLCSubtitleSettings respondsToSelector:@selector(applyCurrentSettingsToPlayer:)]) {
                    [VLCSubtitleSettings applyCurrentSettingsToPlayer:self.player];
                }
                
                // Start playing
                [self.player play];
                
                
                // Clear loading state and frozen values after a delay to allow stream to stabilize
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self setTimeshiftSeekingState:NO];
                    [self clearFrozenTimeValues]; // Clear frozen values when playback stabilizes
                    
                    // UPDATE EPG AND PROGRAM INFORMATION FOR NEW TIMESHIFT POSITION
                    [self updateEPGForTimeshiftPosition:targetTime];
                    
                    [self setNeedsDisplay:YES];
                });
                
                // Save the new timeshift URL
                [self saveLastPlayedChannelUrl:newTimeshiftUrl];
            } else {
                [self setTimeshiftSeekingState:NO];
                [self clearFrozenTimeValues]; // Clear frozen values on error
            }
        });
    } else {
        [self clearFrozenTimeValues]; // Clear frozen values on error
    }
}

// Handle normal seeking for non-timeshift content
- (void)handleNormalSeek:(CGFloat)relativePosition currentChannel:(VLCChannel *)currentChannel currentProgram:(VLCProgram *)currentProgram {
    // Determine if this is a seekable content type
    BOOL isSeekable = YES;
    if (currentProgram && currentProgram.startTime && currentProgram.endTime) {
        // This is a live TV program - check if it's actually live
        // Use actual current time without EPG offset for server-side program status determination
        // EPG offset is only for display purposes, not for server communication
        NSDate *actualNow = [NSDate date];
        
        NSTimeInterval remaining = [currentProgram.endTime timeIntervalSinceDate:actualNow];
        
        // If the program is still running (hasn't ended), it's likely live and not seekable
        if (remaining > 0) {
            isSeekable = NO;
        }
    }
    
    // Check if the content category suggests it might be seekable
    if (currentChannel) {
        NSString *category = currentChannel.category;
        if ([category isEqualToString:@"MOVIES"] || [category isEqualToString:@"SERIES"]) {
            // Movies and series are usually VOD content and seekable
            isSeekable = YES;
        }
    }
    
    if (!isSeekable) {
        return;
    }
    
    // Get total duration and seek
    VLCTime *totalTime = [self.player.media length];
    if (totalTime && [totalTime intValue] > 0) {
        // Calculate new position in milliseconds
        int newPositionMs = (int)([totalTime intValue] * relativePosition);
        
        // Create a VLCTime object with the new position
        VLCTime *newTime = [VLCTime timeWithInt:newPositionMs];
        
        // Set the player to the new position
        [self.player setTime:newTime];
        
    }
    
    // Check if this is a past program with catch-up
    if (currentProgram && currentProgram.hasArchive) {
        // Use actual current time without EPG offset for server-side program status determination
        // EPG offset is only for display purposes, not for server communication
        NSDate *actualNow = [NSDate date];
        NSTimeInterval remaining = [currentProgram.endTime timeIntervalSinceDate:actualNow];
        
        if (remaining < 0) {
            // This is a past program - generate catch-up URL and play
            NSString *catchupUrl = [self generateCatchupUrlForProgram:currentProgram channel:currentChannel];
            if (catchupUrl) {
                // Calculate seek position within the program
                NSTimeInterval programDuration = [currentProgram.endTime timeIntervalSinceDate:currentProgram.startTime];
                NSTimeInterval seekTime = programDuration * relativePosition;
                
                // Play catch-up stream
                [self playCatchupUrl:catchupUrl seekToTime:seekTime channel:currentChannel];
                return;
            }
        }
    }
    
    // If EPG-based catch-up is not available, try channel-level catch-up
    if (currentChannel && currentChannel.supportsCatchup) {
        // Calculate time offset based on progress bar position
        // Assume the progress bar represents the last few hours of the channel
        NSTimeInterval maxTimeOffset = 4 * 3600; // 4 hours back
        NSTimeInterval timeOffset = maxTimeOffset * (1.0 - relativePosition); // Reverse: left = more time back
        
        NSString *catchupUrl = [self generateChannelCatchupUrlForChannel:currentChannel timeOffset:timeOffset];
        if (catchupUrl) {
            
            // Play catch-up stream
            [self playCatchupUrl:catchupUrl seekToTime:0 channel:currentChannel];
            return;
        }
    }
}

// Generate new timeshift URL from current URL with new start time
- (NSString *)generateNewTimeshiftUrlFromCurrentUrl:(NSString *)currentUrl newStartTime:(NSDate *)newStartTime {
    
    if (!currentUrl || !newStartTime) {
        return nil;
    }
    
    // Parse the current URL to extract components
    NSURL *url = [NSURL URLWithString:currentUrl];
    if (!url) {
        return nil;
    }
    
    // Extract base URL
    NSString *baseUrl = [NSString stringWithFormat:@"%@://%@", url.scheme, url.host];
    if (url.port) {
        baseUrl = [baseUrl stringByAppendingFormat:@":%@", url.port];
    }
    
    // Extract query parameters
    NSString *query = [url query];
    if (!query) {
        return nil;
    }
    
    NSMutableDictionary *queryParams = [NSMutableDictionary dictionary];
    NSArray *queryItems = [query componentsSeparatedByString:@"&"];
    for (NSString *item in queryItems) {
        NSArray *keyValue = [item componentsSeparatedByString:@"="];
        if (keyValue.count == 2) {
            [queryParams setObject:keyValue[1] forKey:keyValue[0]];
        }
    }
    
    
    // Format new start time
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd:HH-mm"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    NSString *newStartTimeString = [formatter stringFromDate:newStartTime];
    [formatter release];
    
    
    // Update the start parameter
    [queryParams setObject:newStartTimeString forKey:@"start"];
    
    // Rebuild the URL
    NSMutableArray *newQueryItems = [NSMutableArray array];
    for (NSString *key in queryParams) {
        NSString *value = [queryParams objectForKey:key];
        [newQueryItems addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    
    NSString *newQuery = [newQueryItems componentsJoinedByString:@"&"];
    NSString *newUrl = [NSString stringWithFormat:@"%@%@?%@", baseUrl, url.path, newQuery];
    
    return newUrl;
}

#pragma mark - Timeshift UI State Management

// Method to manage timeshift seeking state for UI feedback
- (void)setTimeshiftSeekingState:(BOOL)seeking {
    // Store seeking state using associated objects
    objc_setAssociatedObject(self, &timeshiftSeekingKey, @(seeking), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // If seeking is being set to NO, clear frozen values as a safety measure
    if (!seeking) {
        [self clearFrozenTimeValues];
    }
    
    // Force UI update to show/hide loading indicator
    [self setNeedsDisplay:YES];
}

- (BOOL)isTimeshiftSeeking {
    NSNumber *seekingState = objc_getAssociatedObject(self, &timeshiftSeekingKey);
    return seekingState ? [seekingState boolValue] : NO;
}

// Method to freeze time values during seeking
- (void)freezeTimeValues:(NSString *)currentTimeStr totalTimeStr:(NSString *)totalTimeStr programStatusStr:(NSString *)programStatusStr {
    // DEFENSIVE PROGRAMMING: Add null checks and validate parameters before accessing them
    // This prevents EXC_BAD_ACCESS crashes when parameters might be deallocated
    
    NSString *safeCurrentTimeStr = @"--:--";
    NSString *safeTotalTimeStr = @"--:--";
    NSString *safeProgramStatusStr = @"Seeking...";
    
    // Safely check and copy currentTimeStr
    @try {
        if (currentTimeStr != nil && [currentTimeStr respondsToSelector:@selector(isKindOfClass:)] && 
            [currentTimeStr isKindOfClass:[NSString class]] && [currentTimeStr length] > 0) {
            safeCurrentTimeStr = [NSString stringWithString:currentTimeStr];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception accessing currentTimeStr: %@", exception);
        safeCurrentTimeStr = @"--:--";
    }
    
    // Safely check and copy totalTimeStr
    @try {
        if (totalTimeStr != nil && [totalTimeStr respondsToSelector:@selector(isKindOfClass:)] && 
            [totalTimeStr isKindOfClass:[NSString class]] && [totalTimeStr length] > 0) {
            safeTotalTimeStr = [NSString stringWithString:totalTimeStr];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception accessing totalTimeStr: %@", exception);
        safeTotalTimeStr = @"--:--";
    }
    
    // Safely check and copy programStatusStr
    @try {
        if (programStatusStr != nil && [programStatusStr respondsToSelector:@selector(isKindOfClass:)] && 
            [programStatusStr isKindOfClass:[NSString class]] && [programStatusStr length] > 0) {
            safeProgramStatusStr = [NSString stringWithString:programStatusStr];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception accessing programStatusStr: %@", exception);
        safeProgramStatusStr = @"Seeking...";
    }
    
    NSDictionary *frozenValues = @{
        @"currentTimeStr": safeCurrentTimeStr,
        @"totalTimeStr": safeTotalTimeStr, 
        @"programStatusStr": safeProgramStatusStr
    };
    
    objc_setAssociatedObject(self, &frozenTimeValuesKey, frozenValues, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"Frozen time values: current=%@, total=%@, status=%@", safeCurrentTimeStr, safeTotalTimeStr, safeProgramStatusStr);
}

// Method to freeze time values with hover text during seeking
- (void)freezeTimeValuesWithHover:(NSString *)currentTimeStr totalTimeStr:(NSString *)totalTimeStr programStatusStr:(NSString *)programStatusStr hoverText:(NSString *)hoverText {
    // DEFENSIVE PROGRAMMING: Add null checks and validate parameters before accessing them
    // This prevents EXC_BAD_ACCESS crashes when parameters might be deallocated
    
    NSString *safeCurrentTimeStr = @"--:--";
    NSString *safeTotalTimeStr = @"--:--";
    NSString *safeProgramStatusStr = @"Seeking...";
    NSString *safeHoverText = nil;
    
    // Safely check and copy currentTimeStr
    @try {
        if (currentTimeStr != nil && [currentTimeStr respondsToSelector:@selector(isKindOfClass:)] && 
            [currentTimeStr isKindOfClass:[NSString class]] && [currentTimeStr length] > 0) {
            safeCurrentTimeStr = [NSString stringWithString:currentTimeStr];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception accessing currentTimeStr: %@", exception);
        safeCurrentTimeStr = @"--:--";
    }
    
    // Safely check and copy totalTimeStr
    @try {
        if (totalTimeStr != nil && [totalTimeStr respondsToSelector:@selector(isKindOfClass:)] && 
            [totalTimeStr isKindOfClass:[NSString class]] && [totalTimeStr length] > 0) {
            safeTotalTimeStr = [NSString stringWithString:totalTimeStr];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception accessing totalTimeStr: %@", exception);
        safeTotalTimeStr = @"--:--";
    }
    
    // Safely check and copy programStatusStr
    @try {
        if (programStatusStr != nil && [programStatusStr respondsToSelector:@selector(isKindOfClass:)] && 
            [programStatusStr isKindOfClass:[NSString class]] && [programStatusStr length] > 0) {
            safeProgramStatusStr = [NSString stringWithString:programStatusStr];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception accessing programStatusStr: %@", exception);
        safeProgramStatusStr = @"Seeking...";
    }
    
    // Safely check and copy hoverText - this is where the crash was occurring
    @try {
        if (hoverText != nil && [hoverText respondsToSelector:@selector(isKindOfClass:)] && 
            [hoverText isKindOfClass:[NSString class]] && [hoverText length] > 0) {
            safeHoverText = [NSString stringWithString:hoverText];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception accessing hoverText: %@", exception);
        safeHoverText = nil;
    }
    
    // Use hover text if available, otherwise fall back to program status
    NSString *statusToUse = safeHoverText ?: safeProgramStatusStr;
    
    NSDictionary *frozenValues = @{
        @"currentTimeStr": safeCurrentTimeStr,
        @"totalTimeStr": safeTotalTimeStr, 
        @"programStatusStr": statusToUse,
        @"useHoverText": @YES
    };
    
    objc_setAssociatedObject(self, &frozenTimeValuesKey, frozenValues, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"Frozen time values with hover: current=%@, total=%@, hover=%@", safeCurrentTimeStr, safeTotalTimeStr, safeHoverText);
}

// Method to get frozen time values
- (NSDictionary *)getFrozenTimeValues {
    return objc_getAssociatedObject(self, &frozenTimeValuesKey);
}

// Method to clear frozen time values
- (void)clearFrozenTimeValues {
    objc_setAssociatedObject(self, &frozenTimeValuesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Also clear the last hover text when clearing frozen values
    objc_setAssociatedObject(self, &lastHoverTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    //NSLog(@"Cleared frozen time values and last hover text");
}

// Method to get last hover text
- (NSString *)getLastHoverText {
    // DEFENSIVE PROGRAMMING: Safely retrieve and validate the hover text
    @try {
        NSString *hoverText = objc_getAssociatedObject(self, &lastHoverTextKey);
        
        // Validate the returned object
        if (hoverText != nil && [hoverText respondsToSelector:@selector(isKindOfClass:)] && 
            [hoverText isKindOfClass:[NSString class]] && [hoverText length] > 0) {
            // Return a safe copy to prevent deallocation issues
            return [NSString stringWithString:hoverText];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception accessing last hover text: %@", exception);
    }
    
    // Return nil if no valid hover text is available
    return nil;
}

#pragma mark - Property Implementations

bool progressBarishovering = false;
NSPoint progressBarishoveringPoint;
// Dynamic property implementations for hover functionality
- (BOOL)isHoveringProgressBar {
    //static char hoveringKey;
    //NSNumber *hovering = objc_getAssociatedObject(self, &hoveringKey);
    return progressBarishovering;//hovering ? [hovering boolValue] : NO;
}

- (void)setIsHoveringProgressBar:(BOOL)isHoveringProgressBar {
    //static char hoveringKey;
    //objc_setAssociatedObject(self, &hoveringKey, @(isHoveringProgressBar), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    progressBarishovering = isHoveringProgressBar;
}

- (NSPoint)progressBarHoverPoint {
    //static char hoverPointKey;
    //NSValue *pointValue = objc_getAssociatedObject(self, &hoverPointKey);
    //return pointValue ? [pointValue pointValue] : NSZeroPoint;
    return progressBarishoveringPoint;
}

- (void)setProgressBarHoverPoint:(NSPoint)progressBarHoverPoint {
    //static char hoverPointKey;
    //objc_setAssociatedObject(self, &hoverPointKey, [NSValue valueWithPoint:progressBarHoverPoint], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    progressBarishoveringPoint = progressBarHoverPoint;
}

#pragma mark - Timeshift Program Detection

// Method to get current timeshift playing program
- (VLCProgram *)getCurrentTimeshiftPlayingProgram {
    if (![self isCurrentlyPlayingTimeshift]) {
        return nil;
    }
    
    //NSLog(@"=== getCurrentTimeshiftPlayingProgram - REAL-TIME CALCULATION ===");
    
    // FORCE REAL-TIME CALCULATION: Always calculate based on current playing time
    // instead of relying on potentially outdated cached information
    
    // Get current channel - FIRST try from cached timeshift channel object
    VLCChannel *currentChannel = [self getCachedTimeshiftChannel];
    
    // Fallback: Try to get from cached content info and search in loaded channels
    if (!currentChannel) {
        //NSLog(@"No cached timeshift channel, trying fallback approaches...");
        
        // Get cached content info to find the channel
        NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
        NSString *channelName = [cachedInfo objectForKey:@"channelName"];
        NSString *channelUrl = [cachedInfo objectForKey:@"url"];
        
        //NSLog(@"Cached channel info: name='%@', url='%@'", channelName, channelUrl);
        
        // Extract original channel name from timeshift name (remove timeshift suffix)
        NSString *originalChannelName = channelName;
        if (channelName && [channelName containsString:@" (Timeshift:"]) {
            NSRange timeshiftRange = [channelName rangeOfString:@" (Timeshift:"];
            if (timeshiftRange.location != NSNotFound) {
                originalChannelName = [channelName substringToIndex:timeshiftRange.location];
                //NSLog(@"Extracted original channel name: '%@'", originalChannelName);
            }
        }
        
        if (originalChannelName && self.channels && self.channels.count > 0) {
            // Search for the original channel by name
            for (VLCChannel *channel in self.channels) {
                if ([channel.name isEqualToString:originalChannelName]) {
                    currentChannel = channel;
                    //NSLog(@"✅ Found original channel by name: %@ with %ld programs", 
                    //      channel.name, (long)channel.programs.count);
                    
                    // Cache this channel for future use
                    [self cacheTimeshiftChannel:channel];
                    break;
                }
            }
        }
        
        // Final fallback: Try selection-based approach
        if (!currentChannel && self.selectedChannelIndex >= 0 && self.selectedChannelIndex < [self.simpleChannelNames count]) {
            //NSLog(@"Trying final fallback selection-based approach...");
            // Try to get the channel from the current selection
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
                    if (channelsInGroup && self.selectedChannelIndex < channelsInGroup.count) {
                        currentChannel = [channelsInGroup objectAtIndex:self.selectedChannelIndex];
                        //NSLog(@"✅ Found channel from selection: %@ with %ld programs", 
                        //      currentChannel.name, (long)currentChannel.programs.count);
                        
                        // Cache this channel for future use
                        [self cacheTimeshiftChannel:currentChannel];
                    }
                }
            }
        }
    }
    
    if (!currentChannel || !currentChannel.programs) {
        //NSLog(@"❌ No current channel or programs available - channel: %@, programs count: %ld", 
        //      currentChannel ? currentChannel.name : @"nil", 
        //      currentChannel ? (long)currentChannel.programs.count : 0);
        return nil;
    }
    
    // Get timeshift start time and current playback position
    NSString *currentUrl = [self.player.media.url absoluteString];
    NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
    
    if (!timeshiftStartTime) {
        //NSLog(@"Could not extract timeshift start time from URL: %@", currentUrl);
        return nil;
    }
    
    VLCTime *currentTime = [self.player time];
    if (!currentTime) {
        //NSLog(@"No current player time available");
        return nil;
    }
    
    // Calculate the actual time being played
    NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
    NSDate *actualPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
    
    //NSLog(@"Timeshift start time: %@", timeshiftStartTime);
    //NSLog(@"Current player time: %.1f seconds", currentSeconds);
    //NSLog(@"Actual play time: %@", actualPlayTime);
    //NSLog(@"EPG offset: %ld hours", (long)self.epgTimeOffsetHours);
    
    // FIXED: Apply EPG offset to the actual play time for program matching
    // When EPG offset is -1 hour, we need to subtract 1 hour from actual play time
    // to match against the program times which are in the EPG's time zone
    NSTimeInterval epgOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
    NSDate *adjustedPlayTime = [actualPlayTime dateByAddingTimeInterval:epgOffsetSeconds];
    
    //NSLog(@"Adjusted play time for program matching: %@", adjustedPlayTime);
    
    // Find the program that was playing at this adjusted time
    VLCProgram *matchedProgram = nil;
    for (VLCProgram *program in currentChannel.programs) {
        if (program.startTime && program.endTime) {
            //NSLog(@"Checking program: %@ (%@ - %@)", program.title, program.startTime, program.endTime);
            
            if ([adjustedPlayTime compare:program.startTime] != NSOrderedAscending && 
                [adjustedPlayTime compare:program.endTime] == NSOrderedAscending) {
                matchedProgram = program;
                //NSLog(@"✅ MATCHED timeshift program: %@", program.title);
                break;
            }
        }
    }
    
    if (!matchedProgram) {
        //NSLog(@"❌ No matching timeshift program found for time: %@", adjustedPlayTime);
    }
    
    // Update the cached info with the real-time calculated program
    if (matchedProgram) {
        [self updateCachedTimeshiftProgramInfo:matchedProgram channel:currentChannel forceUIRefresh:NO];
        //NSLog(@"Updated cached info with real-time calculated program: %@", matchedProgram.title);
    }
    
    //NSLog(@"=== getCurrentTimeshiftPlayingProgram - RETURNING: %@ ===", matchedProgram ? matchedProgram.title : @"nil");
    
    return matchedProgram;
}

// NEW METHOD: Global monitoring of all channels for catch-up status changes
- (void)updateGlobalCatchupStatus {
    // This method is called every 30 seconds to check all channels for program status changes
    
    if (!self.channels || self.channels.count == 0) {
        return;
    }
    
    NSInteger totalUpdates = 0;
    NSDate *adjustedNow = [[NSDate date] dateByAddingTimeInterval:(-self.epgTimeOffsetHours * 3600.0)];
    
    // Check all channels that support catch-up
    for (VLCChannel *channel in self.channels) {
        if (!channel.supportsCatchup || !channel.programs || channel.programs.count == 0) {
            continue;
        }
        
        NSTimeInterval catchupWindow = channel.catchupDays * 24 * 60 * 60; // Convert days to seconds
        BOOL channelHasUpdates = NO;
        
        for (VLCProgram *program in channel.programs) {
            if (!program.endTime) continue;
            
            NSTimeInterval timeSinceEnd = [adjustedNow timeIntervalSinceDate:program.endTime];
            
            if (timeSinceEnd > 0 && timeSinceEnd <= catchupWindow) {
                // Program is past and within catch-up window
                if (!program.hasArchive) {
                    program.hasArchive = YES;
                    if (program.archiveDays == 0) {
                        program.archiveDays = channel.catchupDays;
                    }
                    channelHasUpdates = YES;
                    totalUpdates++;
                }
            } else if (timeSinceEnd > catchupWindow && program.hasArchive) {
                // Program is too old, remove catch-up availability
                program.hasArchive = NO;
                program.archiveDays = 0;
                channelHasUpdates = YES;
                totalUpdates++;
            }
        }
    }
    
    if (totalUpdates > 0) {
        //NSLog(@"GLOBAL CATCH-UP UPDATE: Updated %ld programs across all channels", (long)totalUpdates);
        
        // Trigger UI update if EPG is visible
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isChannelListVisible) {
                [self setNeedsDisplay:YES];
            }
        });
        
        // Save updated EPG data to cache (async)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [self saveEpgDataToCache];
        });
    }
}

// NEW METHOD: Update EPG and program information for new timeshift position
- (void)updateEPGForTimeshiftPosition:(NSDate *)newTimeshiftTime {
    //NSLog(@"Updating EPG for new timeshift position: %@", newTimeshiftTime);
    
    // Get current channel information
    VLCChannel *currentChannel = nil;
    
    // Try to get current channel from selection
    if (self.selectedChannelIndex >= 0 && self.selectedChannelIndex < [self.simpleChannelNames count]) {
        NSString *currentGroup = nil;
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
            
            if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
                currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
                
                NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
                if (channelsInGroup && self.selectedChannelIndex < channelsInGroup.count) {
                    currentChannel = [channelsInGroup objectAtIndex:self.selectedChannelIndex];
                }
            }
        }
    }
    
    if (!currentChannel || !currentChannel.programs || currentChannel.programs.count == 0) {
        //NSLog(@"No channel or EPG data available for timeshift position update");
        return;
    }
    
    // Apply EPG offset to the timeshift time for program matching
    // When EPG offset is -1 hour, we need to subtract 1 hour from timeshift time
    // to match against the program times which are in the EPG's time zone
    NSTimeInterval epgOffsetSeconds = -self.epgTimeOffsetHours * 3600.0;
    NSDate *adjustedTimeshiftTime = [newTimeshiftTime dateByAddingTimeInterval:epgOffsetSeconds];
    
    //NSLog(@"Original timeshift time: %@", newTimeshiftTime);
    //NSLog(@"EPG offset: %ld hours (%.0f seconds)", (long)self.epgTimeOffsetHours, epgOffsetSeconds);
    //NSLog(@"Adjusted timeshift time for program matching: %@", adjustedTimeshiftTime);
    
    // Find the program that was playing at the new timeshift time
    VLCProgram *newProgram = nil;
    for (VLCProgram *program in currentChannel.programs) {
        if (program.startTime && program.endTime) {
            if ([adjustedTimeshiftTime compare:program.startTime] != NSOrderedAscending && 
                [adjustedTimeshiftTime compare:program.endTime] == NSOrderedAscending) {
                newProgram = program;
                //NSLog(@"Found program for timeshift position: %@ (%@ - %@)", 
                //      program.title, program.startTime, program.endTime);
                break;
            }
        }
    }
    
    if (!newProgram) {
        //NSLog(@"No program found for timeshift time: %@", adjustedTimeshiftTime);
        // Clear cached program info if no program found
        [self clearCachedTimeshiftProgramInfo];
        return;
    }
    
    // Update the cached timeshift content info with the new program
    [self updateCachedTimeshiftProgramInfo:newProgram channel:currentChannel forceUIRefresh:YES];
    
    //NSLog(@"Updated timeshift program info to: %@", newProgram.title);
    
    // Force immediate UI refresh to show the new program information
    dispatch_async(dispatch_get_main_queue(), ^{
        // Refresh EPG information to pick up the new program
        [self refreshCurrentEPGInfo];
        
        // Force redraw of player controls
        [self setNeedsDisplay:YES];
        
        // If EPG/channel list is visible, force a refresh to show updated program info
        if (self.isChannelListVisible) {
            [self setNeedsDisplay:YES];
        }
        
        // Also force window display update
        [[self window] display];
        
        //NSLog(@"Forced UI refresh after timeshift program update");
    });
}

// Helper method to update cached timeshift program info
- (void)updateCachedTimeshiftProgramInfo:(VLCProgram *)program channel:(VLCChannel *)channel {
    [self updateCachedTimeshiftProgramInfo:program channel:channel forceUIRefresh:NO];
}

// Helper method to update cached timeshift program info with optional UI refresh
- (void)updateCachedTimeshiftProgramInfo:(VLCProgram *)program channel:(VLCChannel *)channel forceUIRefresh:(BOOL)forceRefresh {
    if (!program || !channel) {
        //NSLog(@"ERROR: Cannot update cached timeshift program info - missing program or channel");
        return;
    }
    
    //NSLog(@"=== UPDATING CACHED TIMESHIFT PROGRAM INFO ===");
    //NSLog(@"New program: %@", program.title);
    //NSLog(@"Program start: %@", program.startTime);
    //NSLog(@"Program end: %@", program.endTime);
    //NSLog(@"Channel: %@", channel.name);
    //NSLog(@"Force UI refresh: %@", forceRefresh ? @"YES" : @"NO");
    
    // Get existing cached info
    NSDictionary *existingInfo = [self getLastPlayedContentInfo];
    NSMutableDictionary *updatedInfo = existingInfo ? [existingInfo mutableCopy] : [NSMutableDictionary dictionary];
    
    //NSLog(@"Existing cached info: %@", existingInfo);
    
    // Update the program information
    NSDictionary *programInfo = @{
        @"title": program.title ?: @"",
        @"description": program.programDescription ?: @"",
        @"startTime": program.startTime ?: [NSDate date],
        @"endTime": program.endTime ?: [NSDate date]
    };
    
    [updatedInfo setObject:programInfo forKey:@"currentProgram"];
    
    // Also update channel info if needed
    [updatedInfo setObject:channel.name ?: @"" forKey:@"channelName"];
    [updatedInfo setObject:channel.url ?: @"" forKey:@"url"];
    [updatedInfo setObject:channel.category ?: @"" forKey:@"category"];
    if (channel.logo) {
        [updatedInfo setObject:channel.logo forKey:@"logoUrl"];
    }
    
    //NSLog(@"Updated info to save: %@", updatedInfo);
    
    // FIXED: Create a temporary channel object to avoid crash
    // The saveLastPlayedContentInfo method expects a VLCChannel object, not a dictionary
    VLCChannel *tempChannel = [[VLCChannel alloc] init];
    tempChannel.name = channel.name;
    tempChannel.url = channel.url;
    tempChannel.category = channel.category;
    tempChannel.logo = channel.logo;
    
    // Create a temporary program list with just the current program
    NSMutableArray *tempPrograms = [NSMutableArray array];
    [tempPrograms addObject:program];
    tempChannel.programs = tempPrograms;
    
    // Save the updated channel info (this will include the current program)
    [self saveLastPlayedContentInfo:tempChannel];
    
    [tempChannel release];
    
   // NSLog(@"Updated cached timeshift program info successfully");
    
    // Verify the save worked
    NSDictionary *verifyInfo = [self getLastPlayedContentInfo];
    //NSLog(@"Verified saved info: %@", verifyInfo);
    
    [updatedInfo release];
    
    // Only force UI refresh if requested (for immediate updates like seeking)
    if (forceRefresh) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshCurrentEPGInfo];
            [self setNeedsDisplay:YES];
            if (self.isChannelListVisible) {
                [self setNeedsDisplay:YES];
            }
            [[self window] display];
           // NSLog(@"Forced UI refresh after timeshift program update");
        });
    }
    
    //NSLog(@"=== CACHED TIMESHIFT PROGRAM INFO UPDATE COMPLETE ===");
}

// Helper method to clear cached timeshift program info
- (void)clearCachedTimeshiftProgramInfo {
    NSDictionary *existingInfo = [self getLastPlayedContentInfo];
    if (existingInfo) {
        // FIXED: Use cached channel approach instead of dictionary manipulation
        VLCChannel *cachedChannel = [self getCachedTimeshiftChannel];
        if (cachedChannel) {
            // Create a temporary channel object without the current program
            VLCChannel *tempChannel = [[VLCChannel alloc] init];
            tempChannel.name = cachedChannel.name;
            tempChannel.url = cachedChannel.url;
            tempChannel.category = cachedChannel.category;
            tempChannel.logo = cachedChannel.logo;
            tempChannel.programs = [NSMutableArray array]; // Empty programs list
            
            // Save the updated channel info (without current program)
            [self saveLastPlayedContentInfo:tempChannel];
            
            [tempChannel release];
            //NSLog(@"Cleared cached timeshift program info successfully");
        } else {
            //NSLog(@"No cached timeshift channel to clear program info from");
        }
    }
}

// NEW METHOD: Continuously update timeshift EPG based on current playing time
- (void)updateTimeshiftEPGFromCurrentPlayingTime {
    //NSLog(@"=== updateTimeshiftEPGFromCurrentPlayingTime START ===");
    
    // Get current channel information - FIRST try from cached timeshift channel object
    VLCChannel *currentChannel = [self getCachedTimeshiftChannel];
    
    // Fallback: Try to get from cached content info and search in loaded channels
    if (!currentChannel) {
        //NSLog(@"No cached timeshift channel, trying fallback approaches...");
        
        // Get cached content info to find the channel
        NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
        NSString *channelName = [cachedInfo objectForKey:@"channelName"];
        NSString *channelUrl = [cachedInfo objectForKey:@"url"];
        
        //NSLog(@"Cached channel info: name='%@', url='%@'", channelName, channelUrl);
        
        // Extract original channel name from timeshift name (remove timeshift suffix)
        NSString *originalChannelName = channelName;
        if (channelName && [channelName containsString:@" (Timeshift:"]) {
            NSRange timeshiftRange = [channelName rangeOfString:@" (Timeshift:"];
            if (timeshiftRange.location != NSNotFound) {
                originalChannelName = [channelName substringToIndex:timeshiftRange.location];
                //NSLog(@"Extracted original channel name: '%@'", originalChannelName);
            }
        }
        
        if (originalChannelName && self.channels && self.channels.count > 0) {
            // Search for the original channel by name
            for (VLCChannel *channel in self.channels) {
                if ([channel.name isEqualToString:originalChannelName]) {
                    currentChannel = channel;
                    //NSLog(@"✅ Found original channel by name: %@ with %ld programs", 
                    //      channel.name, (long)channel.programs.count);
                    
                    // Cache this channel for future use
                    [self cacheTimeshiftChannel:channel];
                    break;
                }
            }
        }
        
        // Final fallback: Try selection-based approach
        if (!currentChannel && self.selectedChannelIndex >= 0 && self.selectedChannelIndex < [self.simpleChannelNames count]) {
            //NSLog(@"Trying final fallback selection-based approach...");
            NSString *currentGroup = nil;
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
                
                if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
                    currentGroup = [groups objectAtIndex:self.selectedGroupIndex];
                    
                    NSArray *channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
                    if (channelsInGroup && self.selectedChannelIndex < channelsInGroup.count) {
                        currentChannel = [channelsInGroup objectAtIndex:self.selectedChannelIndex];
                        //NSLog(@"✅ Found channel from selection: %@ with %ld programs", 
                        //      currentChannel.name, (long)currentChannel.programs.count);
                        
                        // Cache this channel for future use
                        [self cacheTimeshiftChannel:currentChannel];
                    }
                }
            }
        }
    }
    
    if (!currentChannel || !currentChannel.programs || currentChannel.programs.count == 0) {
        //NSLog(@"❌ No current channel or programs available - channel: %@, programs count: %ld", 
        //      currentChannel ? currentChannel.name : @"nil", 
        //      currentChannel ? (long)currentChannel.programs.count : 0);
        return;
    }
    
    //NSLog(@"✅ Found channel: %@ with %ld programs", currentChannel.name, (long)currentChannel.programs.count);
    
    // Calculate the current actual playing time from timeshift URL and player position
    NSString *currentUrl = [self.player.media.url absoluteString];
    NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
    
    if (!timeshiftStartTime) {
        //NSLog(@"❌ Could not extract timeshift start time from URL: %@", currentUrl);
        return;
    }
    
    VLCTime *currentTime = [self.player time];
    if (!currentTime) {
        //NSLog(@"❌ No current player time available");
        return;
    }
    
    // Calculate the actual time being played right now
    NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
    NSDate *actualPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
    
    // Apply EPG offset for program matching
    NSTimeInterval epgOffsetSeconds = -self.epgTimeOffsetHours * 3600.0;
    NSDate *adjustedPlayTime = [actualPlayTime dateByAddingTimeInterval:epgOffsetSeconds];
    
    //NSLog(@"📊 Timeshift calculation:");
    //NSLog(@"   - Timeshift start: %@", timeshiftStartTime);
    //NSLog(@"   - Player time: %.1f seconds", currentSeconds);
    //NSLog(@"   - Actual play time: %@", actualPlayTime);
    //NSLog(@"   - EPG offset: %ld hours (%.0f seconds)", (long)self.epgTimeOffsetHours, epgOffsetSeconds);
    //NSLog(@"   - Adjusted play time: %@", adjustedPlayTime);
    
    // Find the program that should be playing at this exact moment
    VLCProgram *currentlyPlayingProgram = nil;
    //NSLog(@"🔍 Searching through %ld programs for match...", (long)currentChannel.programs.count);
    
    for (VLCProgram *program in currentChannel.programs) {
        if (program.startTime && program.endTime) {
            BOOL isMatch = ([adjustedPlayTime compare:program.startTime] != NSOrderedAscending && 
                           [adjustedPlayTime compare:program.endTime] == NSOrderedAscending);
            
            //NSLog(@"   Program: %@ (%@ - %@) %@", 
            //      program.title, program.startTime, program.endTime, 
            //      isMatch ? @"✅ MATCH" : @"❌");
            
            if (isMatch) {
                currentlyPlayingProgram = program;
                break;
            }
        } else {
            //NSLog(@"   Program: %@ (missing start/end times) ❌", program.title);
        }
    }
    
    // Check if the program has changed from what we have cached
    NSDictionary *existingCachedInfo = [self getLastPlayedContentInfo];
    NSDictionary *cachedProgramInfo = [existingCachedInfo objectForKey:@"currentProgram"];
    NSString *cachedProgramTitle = [cachedProgramInfo objectForKey:@"title"];
    
    NSString *newProgramTitle = currentlyPlayingProgram ? currentlyPlayingProgram.title : nil;
    
    //NSLog(@"📋 Program comparison:");
    //NSLog(@"   - Cached program: %@", cachedProgramTitle ?: @"(none)");
    //NSLog(@"   - New program: %@", newProgramTitle ?: @"(none)");
    //NSLog(@"   - Programs equal: %@", [cachedProgramTitle isEqualToString:newProgramTitle] ? @"YES" : @"NO");
    
    // Only update if the program has actually changed
    if (![cachedProgramTitle isEqualToString:newProgramTitle]) {
        if (currentlyPlayingProgram) {
            //NSLog(@"🔄 DYNAMIC EPG UPDATE: Program changed from '%@' to '%@' at time %@", 
            //      cachedProgramTitle ?: @"(none)", newProgramTitle, adjustedPlayTime);
            
            // Update the cached program information
            [self updateCachedTimeshiftProgramInfo:currentlyPlayingProgram channel:currentChannel];
            
            // Update the program guide selection if it's visible
            [self updateProgramGuideSelection:currentlyPlayingProgram];
            
            //NSLog(@"✅ Updated program information and UI");
            
        } else {
            //NSLog(@"🔄 DYNAMIC EPG UPDATE: No program found for current time %@", adjustedPlayTime);
            [self clearCachedTimeshiftProgramInfo];
        }
    } else {
       // NSLog(@"⏸️ No program change detected - keeping current program: %@", cachedProgramTitle);
    }
    
    //NSLog(@"=== updateTimeshiftEPGFromCurrentPlayingTime END ===");
}

// NEW METHOD: Update program guide selection to highlight the current program
- (void)updateProgramGuideSelection:(VLCProgram *)program {
    if (!program || !self.isChannelListVisible) {
        return;
    }
    
    // This method should update the program guide to highlight/select the current program
    // The exact implementation depends on how the program guide is structured
    
    //NSLog(@"Updating program guide selection to: %@", program.title);
    
    // Force a redraw of the channel list/EPG to show the updated selection
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay:YES];
        [[self window] display];
    });
}

#pragma mark - Timeshift Channel Caching

// Method to cache the original channel object when timeshift is initiated
- (void)cacheTimeshiftChannel:(VLCChannel *)channel {
    if (channel) {
        //NSLog(@"🔄 Caching timeshift channel: %@ with %ld programs", channel.name, (long)channel.programs.count);
        objc_setAssociatedObject(self, &timeshiftChannelKey, channel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        //NSLog(@"⚠️ Attempted to cache nil timeshift channel");
    }
}

// Method to retrieve the cached timeshift channel
- (VLCChannel *)getCachedTimeshiftChannel {
    VLCChannel *cachedChannel = objc_getAssociatedObject(self, &timeshiftChannelKey);
    if (cachedChannel) {
        //NSLog(@"✅ Retrieved cached timeshift channel: %@ with %ld programs", 
              //cachedChannel.name, (long)cachedChannel.programs.count);
    } else {
        //NSLog(@"❌ No cached timeshift channel found");
    }
    return cachedChannel;
}

// Method to clear the cached timeshift channel
- (void)clearCachedTimeshiftChannel {
    objc_setAssociatedObject(self, &timeshiftChannelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    //NSLog(@"🗑️ Cleared cached timeshift channel");
}

@end 

