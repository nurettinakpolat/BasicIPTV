#import "VLCOverlayView+Utilities.h"
#import "VLCOverlayView_Private.h"

@implementation VLCOverlayView (Utilities)

// Safe accessor methods
- (NSArray *)safeGroupsForCategory:(NSString *)category {
    // Return empty array if any issue
    NSMutableArray *emptyGroups = [NSMutableArray array];
    
    @try {
        if (category == nil) {
            return emptyGroups;
        }
        
        // First very basic check - if pointer is NULL or invalid
        if (self.groupsByCategory == nil) {
            return emptyGroups;
        }
        
        // Check if it's a dictionary using respondsToSelector
        if ([self.groupsByCategory respondsToSelector:@selector(objectForKey:)]) {
            id groups = [self.groupsByCategory objectForKey:category];
            
            // Check if we got a valid array
            if (groups && [groups respondsToSelector:@selector(count)]) {
                return groups;
            }
        }
        
        return emptyGroups;
    } @catch (NSException *exception) {
        NSLog(@"Exception in safeGroupsForCategory: %@", exception);
        return emptyGroups;
    }
}

- (NSArray *)safeTVGroups {
    return [self safeGroupsForCategory:@"TV"];
}

- (id)safeValueForKey:(NSString *)key fromDictionary:(NSDictionary *)dict {
    if (!dict || !key) {
        return nil;
    }
    
    @try {
        if ([dict respondsToSelector:@selector(objectForKey:)]) {
            return [dict objectForKey:key];
        }
    } @catch (NSException *exception) {
        NSLog(@"Exception getting value for key %@: %@", key, exception);
    }
    
    return nil;
}

// Data structure initialization
- (void)ensureFavoritesCategory {
    @synchronized(self) {
        // Make sure FAVORITES category exists
        NSMutableArray *favoritesGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
        if (!favoritesGroups || ![favoritesGroups isKindOfClass:[NSMutableArray class]]) {
            favoritesGroups = [NSMutableArray array];
            [self.groupsByCategory setObject:favoritesGroups forKey:@"FAVORITES"];
        }
        
        // Don't add default groups to Favorites anymore - let it be empty if no favorites added
        // Previously we were adding "My Favorites" by default
    }
}

- (void)ensureSettingsGroups {
    @synchronized(self) {
        NSMutableArray *settingsGroups = [self.groupsByCategory objectForKey:@"SETTINGS"];
        if (!settingsGroups || ![settingsGroups isKindOfClass:[NSMutableArray class]]) {
            settingsGroups = [NSMutableArray array];
            [self.groupsByCategory setObject:settingsGroups forKey:@"SETTINGS"];
        }
        
        // Clear any corrupted entries (specifically "SETTINGS Channels")
        [settingsGroups removeObject:@"SETTINGS Channels"];
        
        // Ensure General and Playlist options exist
        if (![settingsGroups containsObject:@"General"]) {
            [settingsGroups addObject:@"General"];
        }
        if (![settingsGroups containsObject:@"Playlist"]) {
            [settingsGroups addObject:@"Playlist"];
        }
        
        // Add Subtitles settings group
        if (![settingsGroups containsObject:@"Subtitles"]) {
            [settingsGroups addObject:@"Subtitles"];
        }
        
        // Add Movie Info options
        if (![settingsGroups containsObject:@"Movie Info"]) {
            [settingsGroups addObject:@"Movie Info"];
            
            // Set up the Movie Info settings channel options
            NSMutableArray *movieInfoOptions = [NSMutableArray array];
            
            // Create channel for refreshing movie info and covers
            VLCChannel *refreshChannel = [[VLCChannel alloc] init];
            refreshChannel.name = @"Refresh All Movie Info & Covers";
            refreshChannel.url = @"action:refreshMovieInfoCovers";
            refreshChannel.category = @"SETTINGS";
            refreshChannel.group = @"Movie Info";
            [movieInfoOptions addObject:refreshChannel];
            [refreshChannel release];
            
            // Add the options to the channelsByGroup
            [self.channelsByGroup setObject:movieInfoOptions forKey:@"Movie Info"];
        }
    }
}

- (void)ensureDataStructuresInitialized {
    @synchronized(self) {
        @try {
            // Save existing Settings groups if available
            NSMutableArray *existingSettingsGroups = nil;
            if (self.groupsByCategory && [self.groupsByCategory objectForKey:@"SETTINGS"]) {
                existingSettingsGroups = [[self.groupsByCategory objectForKey:@"SETTINGS"] mutableCopy];
            }
            
            // Initialize channels and groups but preserve Settings
            if (!self.channels) {
                self.channels = [NSMutableArray array];
            } else {
                [self.channels removeAllObjects];
            }
            
            if (!self.groups) {
                self.groups = [NSMutableArray array];
            } else {
                [self.groups removeAllObjects];
            }
            
            if (!self.channelsByGroup) {
                self.channelsByGroup = [NSMutableDictionary dictionary];
            } else {
                NSMutableDictionary *tempDict = [NSMutableDictionary dictionary];
                // Preserve Settings entries in channelsByGroup
                for (NSString *group in self.channelsByGroup) {
                    if (existingSettingsGroups && [existingSettingsGroups containsObject:group]) {
                        [tempDict setObject:[self.channelsByGroup objectForKey:group] forKey:group];
                    }
                }
                self.channelsByGroup = tempDict;
            }
            
            if (!self.groupsByCategory) {
                self.groupsByCategory = [NSMutableDictionary dictionary];
            } else {
                // Keep the existing Settings entry if it exists
                NSMutableDictionary *tempDict = [NSMutableDictionary dictionary];
                if (existingSettingsGroups) {
                    [tempDict setObject:existingSettingsGroups forKey:@"SETTINGS"];
                }
                self.groupsByCategory = tempDict;
                [existingSettingsGroups release]; // Release our copy
            }
            
            self.categories = @[@"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
            
            // Initialize empty arrays for categories (only if not already set)
            for (NSString *category in self.categories) {
                if (![self.groupsByCategory objectForKey:category]) {
                    [self.groupsByCategory setObject:[NSMutableArray array] forKey:category];
                }
            }
            
            // Add default TV groups if empty
            NSMutableArray *tvGroups = [self.groupsByCategory objectForKey:@"TV"];
            if (tvGroups && [tvGroups count] == 0) {
                [tvGroups addObject:@"Favorites"];
            }
            
            // Initialize default values for selection
            self.selectedCategoryIndex = CATEGORY_FAVORITES;  // Default to FAVORITES category
            self.selectedGroupIndex = -1;
            
            // Initialize empty arrays for channel lists
            self.simpleChannelNames = [NSArray array];
            self.simpleChannelUrls = [NSArray array];
            
            // Always ensure the Settings category structure
            [self ensureSettingsGroups];
            
            NSLog(@"Initialized data structures while preserving Settings");
            
        } @catch (NSException *exception) {
            NSLog(@"Exception in ensureDataStructuresInitialized: %@", exception);
            
            // Last resort recovery - don't try to access old objects at all
            self.channels = [NSMutableArray array];
            self.groups = [NSMutableArray array];
            self.channelsByGroup = [NSMutableDictionary dictionary];
            self.groupsByCategory = [NSMutableDictionary dictionary];
            self.categories = @[@"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
            self.selectedCategoryIndex = 0;
            self.selectedGroupIndex = -1;
            self.simpleChannelNames = [NSArray array];
            self.simpleChannelUrls = [NSArray array];
            
            // Even in emergency, ensure Settings exists
            [self ensureSettingsGroups];
            
            NSLog(@"Emergency recreation of data structures");
        }
    }
}

// File paths
- (NSString *)applicationSupportDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *basePath = [paths firstObject];
    NSString *appName = @"BasicPlayerWithPlaylist";
    NSString *appSupportDir = [basePath stringByAppendingPathComponent:appName];
    
    // Create directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:appSupportDir]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:appSupportDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Error creating application support directory: %@", error);
        }
    }
    
    return appSupportDir;
}

- (NSString *)localM3uFilePath {
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *channelsPath = [appSupportDir stringByAppendingPathComponent:@"channels.m3u"];
    return channelsPath;
}

// User interaction handling
- (void)markUserInteraction {
    @try {
        NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
        
        // Get the current mouse position
        NSPoint mouseLocation = [NSEvent mouseLocation];
        NSPoint localPoint = [self convertPoint:mouseLocation fromView:nil];
        
        // Update mouse movement time and show cursor if hidden
        lastMouseMoveTime = currentTime;
        if (isCursorHidden) {
            [NSCursor unhide];
            isCursorHidden = NO;
            //NSLog(@"Cursor shown due to mouse movement");
        }
        
        // Calculate 10% of the window width
        CGFloat activationZone = self.bounds.size.width * 0.1;
        
        // Handle two cases differently:
        // 1. If menu is not yet visible, only show it if mouse is in activation zone
        // 2. If menu is already visible, any interaction keeps it visible
        
        if (!self.isChannelListVisible) {
            // Case 1: Menu not visible - only show if mouse is in activation zone
            if (localPoint.x <= activationZone) {
                isUserInteracting = YES;
                lastInteractionTime = currentTime;
                
                // Make the channel list visible
                self.isChannelListVisible = YES;
                [self setNeedsDisplay:YES];
            }
        } else {
            // Case 2: Menu already visible - any interaction resets the timer
            isUserInteracting = YES;
            lastInteractionTime = currentTime;
        }
        
        // Cancel any pending hide timer and schedule a new one
        if (autoHideTimer) {
            if ([autoHideTimer respondsToSelector:@selector(invalidate)]) {
                [autoHideTimer invalidate];
            }
            autoHideTimer = nil;
        }
        
        // Always schedule a new check when interaction is registered
        [self scheduleInteractionCheck];
    } @catch (NSException *exception) {
        NSLog(@"Exception in markUserInteraction: %@", exception);
    }
}

- (void)scheduleInteractionCheck {
    @try {
        // Cancel existing timer
        if (autoHideTimer) {
            if ([autoHideTimer respondsToSelector:@selector(invalidate)]) {
                [autoHideTimer invalidate];
            }
            autoHideTimer = nil;
        }
        
        // Schedule a new check in 1 second (more frequent checks for reliability)
        dispatch_async(dispatch_get_main_queue(), ^{
            // Check if timer is already invalidated
            if (autoHideTimer) {
                [autoHideTimer invalidate];
            }
            
            // Create a new timer that repeats so we don't miss checks
            autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                            target:self
                                                          selector:@selector(checkUserInteraction)
                                                          userInfo:nil
                                                           repeats:YES];
            
            // Ensure timer runs even during tracking loops and other modal operations
            [[NSRunLoop currentRunLoop] addTimer:autoHideTimer forMode:NSRunLoopCommonModes];
        });
    } @catch (NSException *exception) {
        NSLog(@"Exception in scheduleInteractionCheck: %@", exception);
    }
}

// Loading progress
- (void)setLoadingStatusText:(NSString *)text {
    // Critical fix: Ensure all UI operations happen on the main thread
    if (![NSThread isMainThread]) {
        // If we're not on the main thread, dispatch to main thread and return
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoadingStatusText:text];
        });
        return;
    }
    
    // Create the lock if it doesn't exist yet
    if (gProgressMessageLock == nil) {
        gProgressMessageLock = [[NSLock alloc] init];
    }
    
    // Lock to ensure thread safety
    [gProgressMessageLock lock];
    
    // Safely update the shared global message
    @try {
        // Release old global message if it exists
        [gProgressMessage release];
        
        // Store a new copy of the actual message in the global
        if (text && [text length] > 0) {
            // Make a new copy of the text to isolate it from any memory issues
            gProgressMessage = [[NSString stringWithString:text] retain];
        } else {
            gProgressMessage = [@"Loading..." retain];
        }
        
        // If we're logging, also print the status message
        //NSLog(@"Progress status: %@", gProgressMessage);
    }
    @catch (NSException *exception) {
        //NSLog(@"Exception in setLoadingStatusText: %@", exception);
        gProgressMessage = [@"Loading..." retain]; // Fallback
    }
    @finally {
        [gProgressMessageLock unlock];
    }
    
    // Now that we're on the main thread, it's safe to update the UI
    [self setNeedsDisplay:YES];
}

- (void)startProgressRedrawTimer {
    // Ensure this method runs on the main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startProgressRedrawTimer];
        });
        return;
    }
    
    // Stop any existing timer first
    [self stopProgressRedrawTimer];
    
    // Don't reset loading status text - preserve current progress message
    
    // Create a timer that fires every 0.1 seconds to update the UI
    redrawTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                target:self
                                              selector:@selector(progressRedrawTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:redrawTimer forMode:NSRunLoopCommonModes];
}

- (void)stopProgressRedrawTimer {
    // Ensure this method runs on the main thread
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopProgressRedrawTimer];
        });
        return;
    }
    
    if (redrawTimer) {
        [redrawTimer invalidate];
        redrawTimer = nil;
    }
    
    // Don't reset progress message when stopping timer - let it preserve current status
    // The progress message should only be cleared when loading is actually complete
}

// Timer callback - redraw the view if loading
- (void)progressRedrawTimerFired:(NSTimer *)timer {
    // This method should always be on the main thread since timers fire on the thread they're created on
    // But let's be defensive just in case
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self progressRedrawTimerFired:timer];
        });
        return;
    }
    
    // Much simpler implementation that avoids any access to potentially bad memory
    if (self.isLoading) {
        // Just force a redraw - we're now safely on the main thread
        [self setNeedsDisplay:YES];
    } else {
        [self stopProgressRedrawTimer];
    }
}

// UI helpers
- (void)prepareSimpleChannelLists {
    @synchronized(self) {
        @try {
            // Save current favorites for preservation
            NSMutableDictionary *savedFavorites = [NSMutableDictionary dictionary];
            NSArray *favoriteGroups = [self safeGroupsForCategory:@"FAVORITES"];
            if (favoriteGroups && favoriteGroups.count > 0) {
                [savedFavorites setObject:favoriteGroups forKey:@"groups"];
                
                NSMutableArray *favoriteChannels = [NSMutableArray array];
                for (NSString *group in favoriteGroups) {
                    NSArray *groupChannels = [self.channelsByGroup objectForKey:group];
                    if (groupChannels) {
                        for (VLCChannel *channel in groupChannels) {
                            NSMutableDictionary *channelDict = [NSMutableDictionary dictionary];
                            [channelDict setObject:(channel.name ? channel.name : @"") forKey:@"name"];
                            [channelDict setObject:(channel.url ? channel.url : @"") forKey:@"url"];
                            [channelDict setObject:(channel.group ? channel.group : @"") forKey:@"group"];
                            if (channel.logo) [channelDict setObject:channel.logo forKey:@"logo"];
                            if (channel.channelId) [channelDict setObject:channel.channelId forKey:@"channelId"];
                            [channelDict setObject:@"FAVORITES" forKey:@"category"];
                            
                            [favoriteChannels addObject:channelDict];
                        }
                    }
                }
                if (favoriteChannels.count > 0) {
                    [savedFavorites setObject:favoriteChannels forKey:@"channels"];
                }
            }
            
            // Get current category and group
            NSString *currentCategory = nil;
            if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < self.categories.count) {
                currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
            }
            
            NSString *currentGroup = nil;
            NSArray *groups = nil;
            
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
            
            // Get channels for the current group
            NSArray *channelsInGroup = nil;
            if (currentGroup) {
                channelsInGroup = [self.channelsByGroup objectForKey:currentGroup];
            }
            
            // Create simple arrays for the UI
            NSMutableArray *names = [NSMutableArray array];
            NSMutableArray *urls = [NSMutableArray array];
            
            if (channelsInGroup && [channelsInGroup count] > 0) {
                for (VLCChannel *channel in channelsInGroup) {
                    if ([channel isKindOfClass:[VLCChannel class]]) {
                        [names addObject:channel.name ? channel.name : @"Unknown"];
                        [urls addObject:channel.url ? channel.url : @""];
                    }
                }
            }
            
            // Update the simple lists with the new data
            [self.simpleChannelNames release];
            [self.simpleChannelUrls release];
            self.simpleChannelNames = [names copy];
            self.simpleChannelUrls = [urls copy];
            
            // Make sure favorites weren't lost
            if (savedFavorites.count > 0) {
                NSArray *currentFavGroups = [self safeGroupsForCategory:@"FAVORITES"];
                
                // If favorites were lost, restore them
                if (!currentFavGroups || currentFavGroups.count == 0) {
                    NSLog(@"Favorites were lost during prepareSimpleChannelLists - restoring them");
                    
                    // Ensure favorites category is initialized
                    [self ensureFavoritesCategory];
                    
                    // Restore favorite groups
                    NSArray *favoriteGroups = [savedFavorites objectForKey:@"groups"];
                    if (favoriteGroups && [favoriteGroups isKindOfClass:[NSArray class]]) {
                        NSMutableArray *favoritesArray = [self.groupsByCategory objectForKey:@"FAVORITES"];
                        if (!favoritesArray) {
                            favoritesArray = [NSMutableArray array];
                            [self.groupsByCategory setObject:favoritesArray forKey:@"FAVORITES"];
                        }
                        
                        // Add favorite groups
                        for (NSString *group in favoriteGroups) {
                            if (![favoritesArray containsObject:group]) {
                                [favoritesArray addObject:group];
                                // Initialize empty array for this group if it doesn't exist
                                if (![self.channelsByGroup objectForKey:group]) {
                                    [self.channelsByGroup setObject:[NSMutableArray array] forKey:group];
                                }
                            }
                        }
                    }
                    
                    // Restore favorite channels
                    NSArray *favoriteChannels = [savedFavorites objectForKey:@"channels"];
                    if (favoriteChannels && [favoriteChannels isKindOfClass:[NSArray class]]) {
                        for (NSDictionary *channelDict in favoriteChannels) {
                            if (![channelDict isKindOfClass:[NSDictionary class]]) continue;
                            
                            // Create a new channel object
                            VLCChannel *channel = [[VLCChannel alloc] init];
                            channel.name = [channelDict objectForKey:@"name"];
                            channel.url = [channelDict objectForKey:@"url"];
                            channel.group = [channelDict objectForKey:@"group"];
                            channel.logo = [channelDict objectForKey:@"logo"];
                            channel.channelId = [channelDict objectForKey:@"channelId"];
                            channel.category = @"FAVORITES";
                            channel.programs = [NSMutableArray array];
                            
                            // Add to appropriate group
                            NSMutableArray *groupChannels = [self.channelsByGroup objectForKey:channel.group];
                            if (!groupChannels) {
                                groupChannels = [NSMutableArray array];
                                [self.channelsByGroup setObject:groupChannels forKey:channel.group];
                            }
                            
                            // Check for duplicates
                            BOOL alreadyInGroup = NO;
                            for (VLCChannel *existingChannel in groupChannels) {
                                if ([existingChannel.url isEqualToString:channel.url]) {
                                    alreadyInGroup = YES;
                                    break;
                                }
                            }
                            
                            if (!alreadyInGroup) {
                                [groupChannels addObject:channel];
                            }
                            
                            [channel release];
                        }
                    }
                }
            }
            
        } @catch (NSException *exception) {
            NSLog(@"Exception in prepareSimpleChannelLists: %@", exception);
        }
    }
}

- (NSInteger)simpleChannelIndexAtPoint:(NSPoint)point {
    @try {
        // This updated method will consider our three-panel layout
        CGFloat mainMenuWidth = 200;
        CGFloat submenuWidth = 250;
        CGFloat rowHeight = 40;
        
        // If we don't have a selected group or not in the channel list area, return -1
        if ((self.selectedCategoryIndex != CATEGORY_FAVORITES && self.selectedCategoryIndex != CATEGORY_TV && self.selectedCategoryIndex != CATEGORY_MOVIES && self.selectedCategoryIndex != CATEGORY_SERIES) || 
            self.selectedGroupIndex < 0 || point.x < mainMenuWidth + submenuWidth) {
            return -1;
        }
        
        // Get appropriate groups based on category
        NSArray *groups;
        if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
            groups = [self safeGroupsForCategory:@"FAVORITES"]; // Favorites groups
        } else {
            groups = [self safeTVGroups]; // TV groups
        }
        
        // Validate the selected group index
        if (self.selectedGroupIndex >= (NSInteger)groups.count) {
            return -1;
        }
    
        // Skip title area
        if (point.y > self.bounds.size.height - rowHeight) {
            return -1;
        }
        
        // Calculate which channel was clicked - with proper scrolling adjustment
        // We need to be precise about our calculations to avoid floating point precision issues
        CGFloat effectiveY = self.bounds.size.height - point.y - rowHeight;
        NSInteger itemsScrolled = (NSInteger)floor(channelScrollPosition / rowHeight);
        NSInteger visibleIndex = (NSInteger)floor(effectiveY / rowHeight);
        NSInteger index = visibleIndex + itemsScrolled;
        
        // Make sure the array and index are valid - defensively
        if (self.simpleChannelNames == nil) {
            return -1;
        }
    
        if (![self.simpleChannelNames respondsToSelector:@selector(count)]) {
            return -1;
        }
        
        NSUInteger count = 0;
        @try {
            count = [self.simpleChannelNames count];
        } @catch (NSException *exception) {
            NSLog(@"Exception getting channel names count: %@", exception);
            return -1;
        }
        
        // Check the index
        if (index < 0 || index >= (NSInteger)count) {
            return -1;
        }
        
        return index;
    } @catch (NSException *exception) {
        NSLog(@"Exception in simpleChannelIndexAtPoint: %@", exception);
        return -1;
    }
}

- (CGFloat)totalChannelsHeight {
    CGFloat rowHeight = 40;
    if (!self.simpleChannelNames) return 0;
    
    // Return the total height of all items
    CGFloat height = (CGFloat)[self.simpleChannelNames count] * rowHeight;
    return height;
}

// Check if user interaction has timed out
- (void)checkUserInteraction {
    @try {
        NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval timeSinceLastInteraction = currentTime - lastInteractionTime;
        NSTimeInterval timeSinceLastMouseMove = currentTime - lastMouseMoveTime;
        
        // Log timer checks periodically
        static NSTimeInterval lastLogTime = 0;
        if (currentTime - lastLogTime > 2.0) {
            //NSLog(@"Checking user interaction: %.1f seconds since last activity", timeSinceLastInteraction);
            lastLogTime = currentTime;
        }
        
        // Check if we should hide the cursor after 5 seconds of no mouse movement
        // Only hide cursor when in fullscreen mode
        BOOL isFullscreen = NO;
        if (self.window) {
            isFullscreen = ([self.window styleMask] & NSWindowStyleMaskFullScreen) != 0;
        }
        
        if (isFullscreen && timeSinceLastMouseMove >= 5.0 && !isCursorHidden) {
            // Hide the cursor
            [NSCursor hide];
            isCursorHidden = YES;
            //NSLog(@"Cursor hidden after %.1f seconds of no mouse movement", timeSinceLastMouseMove);
        }
        
        // If more than 5 seconds have passed since last interaction, hide the menu
        if (timeSinceLastInteraction >= 5.0) {
            //NSLog(@"User interaction timed out after %.1f seconds - hiding menu", timeSinceLastInteraction);
            isUserInteracting = NO;
            [self hideChannelList];
            
            // Don't reschedule - the timer is now stopped
        }
        // Otherwise the repeating timer will continue checking
    } @catch (NSException *exception) {
        NSLog(@"Exception in checkUserInteraction: %@", exception);
        
        // Ensure we reschedule in case of error
        [self scheduleInteractionCheck];
    }
}

// Hide the channel list
- (void)hideChannelList {
    @try {
        // Only hide if user is not interacting
        if (!isUserInteracting) {
            // Update UI on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                // Hide all controls before hiding the menu
                [self hideControls];
                self.isChannelListVisible = NO;
                [self setNeedsDisplay:YES];
            });
        }
        
        // Clear timer reference
        autoHideTimer = nil;
    } @catch (NSException *exception) {
        NSLog(@"Exception in hideChannelList: %@", exception);
    }
}

// Ensure cursor is visible (useful when exiting fullscreen or app becomes active)
- (void)ensureCursorVisible {
    if (isCursorHidden) {
        [NSCursor unhide];
        isCursorHidden = NO;
        NSLog(@"Cursor shown via ensureCursorVisible");
    }
}

#pragma mark - Settings Persistence

- (void)saveSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Save playlist URL
    if (self.m3uFilePath) {
        [defaults setObject:self.m3uFilePath forKey:@"PlaylistURL"];
    }
    
    // Save EPG URL
    if (self.epgUrl) {
        [defaults setObject:self.epgUrl forKey:@"EPGURL"];
    }
    
    // Save EPG time offset
    [defaults setInteger:self.epgTimeOffsetHours forKey:@"EPGTimeOffsetHours"];
    
    // Save last download timestamps
    NSDate *now = [NSDate date];
    
    // If we're downloading or updating M3U, save timestamp
    if (self.isLoading && !self.isLoadingEpg) {
        [defaults setObject:now forKey:@"LastM3UDownloadDate"];
    }
    
    // If we're downloading or updating EPG, save timestamp
    if (self.isLoadingEpg) {
        [defaults setObject:now forKey:@"LastEPGDownloadDate"];
    }
    
    // Save favorites data
    NSMutableDictionary *favoritesData = [NSMutableDictionary dictionary];
    NSArray *favoriteGroups = [self safeGroupsForCategory:@"FAVORITES"];
    if (favoriteGroups && favoriteGroups.count > 0) {
        [favoritesData setObject:favoriteGroups forKey:@"groups"];
        
        NSMutableArray *favoriteChannels = [NSMutableArray array];
        for (NSString *group in favoriteGroups) {
            NSArray *groupChannels = [self.channelsByGroup objectForKey:group];
            if (groupChannels) {
                for (VLCChannel *channel in groupChannels) {
                    NSMutableDictionary *channelDict = [NSMutableDictionary dictionary];
                    [channelDict setObject:(channel.name ? channel.name : @"") forKey:@"name"];
                    [channelDict setObject:(channel.url ? channel.url : @"") forKey:@"url"];
                    [channelDict setObject:(channel.group ? channel.group : @"") forKey:@"group"];
                    if (channel.logo) [channelDict setObject:channel.logo forKey:@"logo"];
                    if (channel.channelId) [channelDict setObject:channel.channelId forKey:@"channelId"];
                    [channelDict setObject:@"FAVORITES" forKey:@"category"];
                    
                    [favoriteChannels addObject:channelDict];
                }
            }
        }
        if (favoriteChannels.count > 0) {
            [favoritesData setObject:favoriteChannels forKey:@"channels"];
        }
        
        // Save the favorites data
        [defaults setObject:favoritesData forKey:@"FavoritesData"];
        NSLog(@"Saved %lu favorite groups with %lu channels", 
             (unsigned long)favoriteGroups.count, 
             (unsigned long)favoriteChannels.count);
    }
    
    // Force the settings to be written to disk
    [defaults synchronize];
    
    NSLog(@"Settings saved - M3U URL: %@, EPG URL: %@", self.m3uFilePath, self.epgUrl);
}

- (void)loadSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Load playlist URL
    NSString *savedM3uPath = [defaults objectForKey:@"PlaylistURL"];
    if (savedM3uPath && [savedM3uPath length] > 0) {
        self.m3uFilePath = savedM3uPath;
        NSLog(@"Loaded M3U URL from settings: %@", self.m3uFilePath);
    }
    
    // Load EPG URL
    NSString *savedEpgUrl = [defaults objectForKey:@"EPGURL"];
    if (savedEpgUrl && [savedEpgUrl length] > 0) {
        self.epgUrl = savedEpgUrl;
        NSLog(@"Loaded EPG URL from settings: %@", self.epgUrl);
    }
    
    // Load EPG time offset
    self.epgTimeOffsetHours = [defaults integerForKey:@"EPGTimeOffsetHours"];
    
    // Load favorites data
    NSDictionary *favoritesData = [defaults objectForKey:@"FavoritesData"];
    if (favoritesData) {
        // Ensure favorites category exists
        [self ensureFavoritesCategory];
        
        // Restore favorite groups
        NSArray *favoriteGroups = [favoritesData objectForKey:@"groups"];
        if (favoriteGroups && [favoriteGroups isKindOfClass:[NSArray class]]) {
            NSMutableArray *favoritesArray = [self.groupsByCategory objectForKey:@"FAVORITES"];
            if (!favoritesArray) {
                favoritesArray = [NSMutableArray array];
                [self.groupsByCategory setObject:favoritesArray forKey:@"FAVORITES"];
            }
            
            // Add favorite groups
            for (NSString *group in favoriteGroups) {
                if (![favoritesArray containsObject:group]) {
                    [favoritesArray addObject:group];
                    // Initialize empty array for this group if it doesn't exist
                    if (![self.channelsByGroup objectForKey:group]) {
                        [self.channelsByGroup setObject:[NSMutableArray array] forKey:group];
                    }
                }
            }
        }
        
        // Restore favorite channels
        NSArray *favoriteChannels = [favoritesData objectForKey:@"channels"];
        if (favoriteChannels && [favoriteChannels isKindOfClass:[NSArray class]]) {
            for (NSDictionary *channelDict in favoriteChannels) {
                if (![channelDict isKindOfClass:[NSDictionary class]]) continue;
                
                // Create a new channel object
                VLCChannel *channel = [[VLCChannel alloc] init];
                channel.name = [channelDict objectForKey:@"name"];
                channel.url = [channelDict objectForKey:@"url"];
                channel.group = [channelDict objectForKey:@"group"];
                channel.logo = [channelDict objectForKey:@"logo"];
                channel.channelId = [channelDict objectForKey:@"channelId"];
                channel.category = @"FAVORITES";
                channel.programs = [NSMutableArray array];
                
                // Add to appropriate group
                NSMutableArray *groupChannels = [self.channelsByGroup objectForKey:channel.group];
                if (!groupChannels) {
                    groupChannels = [NSMutableArray array];
                    [self.channelsByGroup setObject:groupChannels forKey:channel.group];
                }
                
                // Check for duplicates
                BOOL alreadyInGroup = NO;
                for (VLCChannel *existingChannel in groupChannels) {
                    if ([existingChannel.url isEqualToString:channel.url]) {
                        alreadyInGroup = YES;
                        break;
                    }
                }
                
                if (!alreadyInGroup) {
                    [groupChannels addObject:channel];
                }
                
                [channel release];
            }
            
            NSLog(@"Loaded %lu favorite channels from settings", (unsigned long)favoriteChannels.count);
        }
    }
}

- (BOOL)shouldUpdateM3UAtStartup {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *lastDownload = [defaults objectForKey:@"LastM3UDownloadDate"];
    
    if (!lastDownload) {
        // No previous download, should update
        NSLog(@"No previous M3U download date found, will update");
        return YES;
    }
    
    NSTimeInterval timeSinceDownload = [[NSDate date] timeIntervalSinceDate:lastDownload];
    NSTimeInterval oneDayInSeconds = 24 * 60 * 60; // 24 hours
    
    BOOL shouldUpdate = timeSinceDownload > oneDayInSeconds;
    NSLog(@"Last M3U download was %.1f hours ago, %@", 
          timeSinceDownload / 3600.0, 
          shouldUpdate ? @"will update" : @"no update needed");
    
    return shouldUpdate;
}

- (BOOL)shouldUpdateEPGAtStartup {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *lastDownload = [defaults objectForKey:@"LastEPGDownloadDate"];
    
    if (!lastDownload) {
        // No previous download, should update
        NSLog(@"No previous EPG download date found, will update");
        return YES;
    }
    
    NSTimeInterval timeSinceDownload = [[NSDate date] timeIntervalSinceDate:lastDownload];
    NSTimeInterval sixHoursInSeconds = 6 * 60 * 60; // 6 hours
    
    BOOL shouldUpdate = timeSinceDownload > sixHoursInSeconds;
    NSLog(@"Last EPG download was %.1f hours ago, %@", 
          timeSinceDownload / 3600.0, 
          shouldUpdate ? @"will update" : @"no update needed");
    
    return shouldUpdate;
}

// Helper method to check if a string is numeric
- (BOOL)isNumeric:(NSString *)string {
    if (!string || [string length] == 0) {
        return NO;
    }
    
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

@end 