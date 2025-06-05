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
        //NSLog(@"Exception in safeGroupsForCategory: %@", exception);
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
        //NSLog(@"Exception getting value for key %@: %@", key, exception);
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

        // Add Themes settings group
        if (![settingsGroups containsObject:@"Themes"]) {
            [settingsGroups addObject:@"Themes"];
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
            
            self.categories = @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
            
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
            
            //NSLog(@"Initialized data structures while preserving Settings");
            
        } @catch (NSException *exception) {
            //NSLog(@"Exception in ensureDataStructuresInitialized: %@", exception);
            
            // Last resort recovery - don't try to access old objects at all
            self.channels = [NSMutableArray array];
            self.groups = [NSMutableArray array];
            self.channelsByGroup = [NSMutableDictionary dictionary];
            self.groupsByCategory = [NSMutableDictionary dictionary];
            self.categories = @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
            self.selectedCategoryIndex = CATEGORY_FAVORITES;
            self.selectedGroupIndex = -1;
            self.simpleChannelNames = [NSArray array];
            self.simpleChannelUrls = [NSArray array];
            
            // Even in emergency, ensure Settings exists
            [self ensureSettingsGroups];
            
            //NSLog(@"Emergency recreation of data structures");
        }
    }
}

// File paths
- (NSString *)applicationSupportDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *basePath = [paths firstObject];
    NSString *appName = @"BasicIPTV";
    NSString *appSupportDir = [basePath stringByAppendingPathComponent:appName];
    
    // Create directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:appSupportDir]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:appSupportDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            //NSLog(@"Error creating application support directory: %@", error);
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
        //NSLog(@"Exception in markUserInteraction: %@", exception);
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
        //NSLog(@"Exception in scheduleInteractionCheck: %@", exception);
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
            
            // Restore last selected indices on first run (when channels are initially loaded)
            static BOOL hasRestoredSelection = NO;
            if (!hasRestoredSelection && self.channels && self.channels.count > 0) {
                // Add a small delay to ensure all data structures are properly initialized
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // Double-check that we still have valid data
                    if (self.categories && self.categories.count > 0 && self.channels && self.channels.count > 0) {
                        [self loadAndRestoreLastSelectedIndices];
                        //NSLog(@"Restored last selected indices after channel loading with delay");
                    } else {
                        //NSLog(@"Skipped selection restoration - data not ready yet");
                    }
                });
                hasRestoredSelection = YES;
            }
            
            // Make sure favorites weren't lost
            if (savedFavorites.count > 0) {
                NSArray *currentFavGroups = [self safeGroupsForCategory:@"FAVORITES"];
                
                // If favorites were lost, restore them
                if (!currentFavGroups || currentFavGroups.count == 0) {
                    //NSLog(@"Favorites were lost during prepareSimpleChannelLists - restoring them");
                    
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
            //NSLog(@"Exception in prepareSimpleChannelLists: %@", exception);
        }
    }
}

- (NSInteger)simpleChannelIndexAtPoint:(NSPoint)point {
    @try {
        // This updated method will consider our three-panel layout
        CGFloat mainMenuWidth = 200;
        CGFloat submenuWidth = 250;
        CGFloat rowHeight = 40;
        
        // FIXED: Handle search mode differently
        if (self.selectedCategoryIndex == CATEGORY_SEARCH) {
            // For search mode, check if we have search results and if point is in channel list area
            if (point.x < mainMenuWidth + submenuWidth) {
                return -1;
            }
            
            // Use search channel results count instead of regular channel list
            NSUInteger count = 0;
            if (self.searchChannelResults && [self.searchChannelResults count] > 0) {
                count = [self.searchChannelResults count];
            } else {
                // No search results - return -1
                return -1;
            }
            
            // Calculate which search result was hovered
            CGFloat effectiveY = self.bounds.size.height - point.y;
            NSInteger itemsScrolled = (NSInteger)floor(self.searchChannelScrollPosition / rowHeight);
            NSInteger visibleIndex = (NSInteger)floor(effectiveY / rowHeight);
            NSInteger index = visibleIndex + itemsScrolled;
            
            // Check the index bounds
            if (index < 0 || index >= (NSInteger)count) {
                return -1;
            }
            
            return index;
        }
        
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
            //NSLog(@"Exception getting channel names count: %@", exception);
            return -1;
        }
        
        // Check the index
        if (index < 0 || index >= (NSInteger)count) {
            return -1;
        }
        
        return index;
    } @catch (NSException *exception) {
        //NSLog(@"Exception in simpleChannelIndexAtPoint: %@", exception);
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
        
        // AUTO-NAVIGATION: If menu has been hidden for more than 15 seconds, auto-navigate to playing channel
        static NSTimeInterval lastMenuHideTime = 0;
        static BOOL hasAutoNavigated = NO;
        
        if (!self.isChannelListVisible) {
            // Menu is hidden - track how long it's been hidden
            if (lastMenuHideTime == 0) {
                lastMenuHideTime = currentTime; // Start tracking
                hasAutoNavigated = NO; // Reset flag when menu becomes hidden
            }
            
            NSTimeInterval timeSinceMenuHidden = currentTime - lastMenuHideTime;
            if (timeSinceMenuHidden >= 15.0 && !hasAutoNavigated) {
                // 15 seconds have passed, auto-navigate to currently playing channel
                [self autoNavigateToCurrentlyPlayingChannel];
                hasAutoNavigated = YES; // Only do this once per hide session
            }
        } else {
            // Menu is visible - reset the hide timer
            lastMenuHideTime = 0;
            hasAutoNavigated = NO;
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
        //NSLog(@"Exception in checkUserInteraction: %@", exception);
        
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
        //NSLog(@"Exception in hideChannelList: %@", exception);
    }
}

// Ensure cursor is visible (useful when exiting fullscreen or app becomes active)
- (void)ensureCursorVisible {
    if (isCursorHidden) {
        [NSCursor unhide];
        isCursorHidden = NO;
        //NSLog(@"Cursor shown via ensureCursorVisible");
    }
}

// Auto-navigate to currently playing channel after 15 seconds of menu being hidden
- (void)autoNavigateToCurrentlyPlayingChannel {
    @try {
        //NSLog(@"Auto-navigating to currently playing channel...");
        
        // Get the currently playing channel URL
        NSString *currentChannelUrl = [self getLastPlayedChannelUrl];
        if (!currentChannelUrl || [currentChannelUrl length] == 0) {
            //NSLog(@"No currently playing channel found");
            return;
        }
        
        // Find the channel in our data structures
        VLCChannel *foundChannel = nil;
        NSInteger foundCategoryIndex = -1;
        NSInteger foundGroupIndex = -1;
        NSInteger foundChannelIndex = -1;
        
        // Search through all categories and groups
        for (NSInteger catIndex = 0; catIndex < self.categories.count; catIndex++) {
            NSString *category = [self.categories objectAtIndex:catIndex];
            
            // Skip SEARCH category
            if ([category isEqualToString:@"SEARCH"]) continue;
            
            NSArray *groups = [self getGroupsForCategoryIndex:catIndex];
            if (!groups) continue;
            
            for (NSInteger groupIndex = 0; groupIndex < groups.count; groupIndex++) {
                NSString *group = [groups objectAtIndex:groupIndex];
                NSArray *channelsInGroup = [self.channelsByGroup objectForKey:group];
                
                if (channelsInGroup) {
                    for (NSInteger channelIndex = 0; channelIndex < channelsInGroup.count; channelIndex++) {
                        VLCChannel *channel = [channelsInGroup objectAtIndex:channelIndex];
                        
                        // Match by URL
                        if ([channel.url isEqualToString:currentChannelUrl]) {
                            foundChannel = channel;
                            foundCategoryIndex = catIndex;
                            foundGroupIndex = groupIndex;
                            foundChannelIndex = channelIndex;
                            
                            //NSLog(@"Found currently playing channel '%@' at Cat=%ld, Group=%ld, Channel=%ld", 
                            //      channel.name, (long)catIndex, (long)groupIndex, (long)channelIndex);
                            break;
                        }
                    }
                    if (foundChannel) break;
                }
            }
            if (foundChannel) break;
        }
        
        // If we found the channel, set the selection and center the view
        if (foundChannel) {
            // Update selection indices
            self.selectedCategoryIndex = foundCategoryIndex;
            self.selectedGroupIndex = foundGroupIndex;
            
            // Prepare channel lists for the selected group
            [self prepareSimpleChannelLists];
            
            // Set the channel index (this might have changed after prepareSimpleChannelLists)
            if (foundChannelIndex < self.simpleChannelNames.count) {
                self.selectedChannelIndex = foundChannelIndex;
            } else {
                self.selectedChannelIndex = 0; // Fallback
            }
            
            // Center the selection in the view and set hover indices
            [self centerSelectionInMenuAndSetHoverIndices];
            
            //NSLog(@"Auto-navigation completed: Cat=%ld, Group=%ld, Channel=%ld", 
            //      (long)self.selectedCategoryIndex, (long)self.selectedGroupIndex, (long)self.selectedChannelIndex);
        } else {
            //NSLog(@"Currently playing channel not found in menu structure");
        }
        
    } @catch (NSException *exception) {
        //NSLog(@"Exception in autoNavigateToCurrentlyPlayingChannel: %@", exception);
    }
}

// Center the current selection in the menu panels and set hover indices to match
- (void)centerSelectionInMenuAndSetHoverIndices {
    @try {
        // Access the global view mode variables from UI.m
        extern BOOL isStackedViewActive;
        extern BOOL isGridViewActive;
        
        // Center category scroll position
        if (self.selectedCategoryIndex >= 0 && self.categories.count > 0) {
            CGFloat categoryRowHeight = 40;
            CGFloat categoryPanelHeight = self.bounds.size.height;
            CGFloat totalCategoryHeight = self.categories.count * categoryRowHeight;
            
            // Calculate position to center the selected category
            CGFloat targetCategoryY = self.selectedCategoryIndex * categoryRowHeight;
            CGFloat centerOffset = (categoryPanelHeight / 2) - (categoryRowHeight / 2);
            categoryScrollPosition = MAX(0, MIN(targetCategoryY - centerOffset, totalCategoryHeight - categoryPanelHeight));
            
            // Set hover index to match selection
            self.hoveredCategoryIndex = self.selectedCategoryIndex;
        }
        
        // Center group scroll position
        NSArray *groups = [self getGroupsForCategoryIndex:self.selectedCategoryIndex];
        if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
            CGFloat groupRowHeight = 40;
            CGFloat groupPanelHeight = self.bounds.size.height;
            CGFloat totalGroupHeight = groups.count * groupRowHeight;
            
            // Calculate position to center the selected group
            CGFloat targetGroupY = self.selectedGroupIndex * groupRowHeight;
            CGFloat centerOffset = (groupPanelHeight / 2) - (groupRowHeight / 2);
            groupScrollPosition = MAX(0, MIN(targetGroupY - centerOffset, totalGroupHeight - groupPanelHeight));
            
            // Set hover index to match selection
            self.hoveredGroupIndex = self.selectedGroupIndex;
        }
        
        // Center channel scroll position - handle different view modes
        if (self.selectedChannelIndex >= 0 && self.simpleChannelNames.count > 0) {
            CGFloat channelRowHeight = 40; // Default for list view
            CGFloat channelPanelHeight = self.bounds.size.height;
            CGFloat totalChannelHeight = 0;
            CGFloat maxScroll = 0;
            
            // Determine current view mode and calculate appropriate scroll position
            BOOL isMovieCategory = (self.selectedCategoryIndex == CATEGORY_MOVIES) || 
                                  (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]);
            
            if (isMovieCategory && isStackedViewActive) {
                // STACKED VIEW - use the exact same calculations as drawStackedView
                channelRowHeight = 400; // Default stacked view row height
                
                // Calculate stacked view dimensions (match drawStackedView)
                CGFloat catWidth = 200;
                CGFloat groupWidth = 250;
                CGFloat stackedViewX = catWidth + groupWidth;
                CGFloat stackedViewWidth = self.bounds.size.width - stackedViewX;
                NSRect stackedRect = NSMakeRect(stackedViewX, 0, stackedViewWidth, self.bounds.size.height);
                
                // Apply minimum rows logic (match drawStackedView)
                NSInteger minVisibleRows = 4;
                CGFloat requiredHeight = minVisibleRows * channelRowHeight;
                if (stackedRect.size.height < requiredHeight) {
                    channelRowHeight = MAX(80, stackedRect.size.height / minVisibleRows);
                }
                
                totalChannelHeight = self.simpleChannelNames.count * channelRowHeight;
                channelPanelHeight = stackedRect.size.height;
                maxScroll = MAX(0, totalChannelHeight - channelPanelHeight);
                
            } else if (isMovieCategory && isGridViewActive) {
                // GRID VIEW - use the exact same calculations as grid scrolling
                CGFloat catWidth = 200;
                CGFloat groupWidth = 250;
                CGFloat gridX = catWidth + groupWidth;
                CGFloat gridWidth = self.bounds.size.width - gridX;
                CGFloat itemPadding = 10;
                CGFloat itemWidth = MIN(180, (gridWidth / 2) - (itemPadding * 2));
                CGFloat itemHeight = itemWidth * 1.5;
                
                // Calculate grid layout
                NSInteger maxColumns = MAX(1, (NSInteger)((gridWidth - itemPadding) / (itemWidth + itemPadding)));
                NSInteger numRows = (NSInteger)ceilf((float)self.simpleChannelNames.count / (float)maxColumns);
                CGFloat totalGridHeight = numRows * (itemHeight + itemPadding) + itemPadding;
                totalGridHeight += itemHeight; // Extra padding
                
                // For grid view, calculate which row the selected item is in
                NSInteger selectedRow = self.selectedChannelIndex / maxColumns;
                CGFloat targetRowY = selectedRow * (itemHeight + itemPadding);
                
                channelPanelHeight = self.bounds.size.height - 40; // Account for header
                maxScroll = MAX(0, totalGridHeight - channelPanelHeight);
                
                // Center the selected row
                CGFloat centerOffset = (channelPanelHeight / 2) - (itemHeight / 2);
                channelScrollPosition = MAX(0, MIN(targetRowY - centerOffset, maxScroll));
                
                //NSLog(@"Grid view centering: selectedIndex=%ld, row=%ld, targetY=%.1f, scrollPos=%.1f", 
                //      (long)self.selectedChannelIndex, (long)selectedRow, targetRowY, channelScrollPosition);
                
            } else {
                // LIST VIEW - standard 40px row height
                channelRowHeight = 40;
                totalChannelHeight = self.simpleChannelNames.count * channelRowHeight;
                maxScroll = MAX(0, totalChannelHeight - channelPanelHeight);
            }
            
            // For list and stacked view, center the selected item
            if (!isGridViewActive) {
                CGFloat targetChannelY = self.selectedChannelIndex * channelRowHeight;
                CGFloat centerOffset = (channelPanelHeight / 2) - (channelRowHeight / 2);
                channelScrollPosition = MAX(0, MIN(targetChannelY - centerOffset, maxScroll));
                
                //NSLog(@"Centering view mode: rowHeight=%.1f, targetY=%.1f, scrollPos=%.1f", 
                //      channelRowHeight, targetChannelY, channelScrollPosition);
            }
            
            // Set hover index to match selection
            self.hoveredChannelIndex = self.selectedChannelIndex;
        }
        
        //NSLog(@"Centered selection and set hover indices: Cat=%ld, Group=%ld, Channel=%ld (ViewMode: Stacked=%@, Grid=%@)", 
        //      (long)self.hoveredCategoryIndex, (long)self.hoveredGroupIndex, (long)self.hoveredChannelIndex,
        //      isStackedViewActive ? @"YES" : @"NO", isGridViewActive ? @"YES" : @"NO");
              
    } @catch (NSException *exception) {
        //NSLog(@"Exception in centerSelectionInMenuAndSetHoverIndices: %@", exception);
    }
}

#pragma mark - Settings Persistence

- (void)saveSettingsState {
    // Store all settings in a single plist file in Application Support instead of UserDefaults
    NSString *settingsPath = [self settingsFilePath];
    NSMutableDictionary *settingsDict = [NSMutableDictionary dictionary];
    
    // Store playlist and EPG URLs
    if (self.m3uFilePath) [settingsDict setObject:self.m3uFilePath forKey:@"PlaylistURL"];
    if (self.epgUrl) [settingsDict setObject:self.epgUrl forKey:@"EPGURL"];
    
    // Store EPG time offset
    [settingsDict setObject:@(self.epgTimeOffsetHours) forKey:@"EPGTimeOffsetHours"];
    
    // Store last download timestamps
    NSDate *now = [NSDate date];
    
    // If we're downloading or updating M3U, save timestamp
    if (self.isLoading && !self.isLoadingEpg) {
        [settingsDict setObject:now forKey:@"LastM3UDownloadDate"];
    } else {
        // Preserve existing timestamp
        NSDictionary *existingSettings = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
        NSDate *existingM3UDate = [existingSettings objectForKey:@"LastM3UDownloadDate"];
        if (existingM3UDate) [settingsDict setObject:existingM3UDate forKey:@"LastM3UDownloadDate"];
    }
    
    // If we're downloading or updating EPG, save timestamp
    if (self.isLoadingEpg) {
        [settingsDict setObject:now forKey:@"LastEPGDownloadDate"];
    } else {
        // Preserve existing timestamp
        NSDictionary *existingSettings = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
        NSDate *existingEPGDate = [existingSettings objectForKey:@"LastEPGDownloadDate"];
        if (existingEPGDate) [settingsDict setObject:existingEPGDate forKey:@"LastEPGDownloadDate"];
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
        
        // Store the favorites data
        [settingsDict setObject:favoritesData forKey:@"FavoritesData"];
        //NSLog(@"Saved %lu favorite groups with %lu channels", 
        //      (unsigned long)favoriteGroups.count, 
        //      (unsigned long)favoriteChannels.count);
    }
    
    // Write to file
    BOOL success = [settingsDict writeToFile:settingsPath atomically:YES];
    if (success) {
        //NSLog(@"Settings saved to Application Support: %@", settingsPath);
    } else {
        //NSLog(@"Failed to save settings to: %@", settingsPath);
    }
    
    //NSLog(@"Settings saved - M3U URL: %@, EPG URL: %@", self.m3uFilePath, self.epgUrl);
}

- (void)loadSettings {
    // Load all settings from the Application Support file instead of UserDefaults
    NSString *settingsPath = [self settingsFilePath];
    NSDictionary *settingsDict = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
    
    if (!settingsDict) {
        // MIGRATION: Check if we have old UserDefaults data to migrate
        [self migrateUserDefaultsToApplicationSupport];
        // Try loading again after migration
        settingsDict = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
    }
    
    if (!settingsDict) {
        //NSLog(@"No settings file found, using defaults");
        return;
    }
    
    // Load playlist URL
    NSString *savedM3uPath = [settingsDict objectForKey:@"PlaylistURL"];
    if (savedM3uPath && [savedM3uPath length] > 0) {
        self.m3uFilePath = savedM3uPath;
        //NSLog(@"Loaded M3U URL from settings: %@", self.m3uFilePath);
    }
    
    // Load EPG URL
    NSString *savedEpgUrl = [settingsDict objectForKey:@"EPGURL"];
    if (savedEpgUrl && [savedEpgUrl length] > 0) {
        self.epgUrl = savedEpgUrl;
       //NSLog(@"Loaded EPG URL from settings: %@", self.epgUrl);
    }
    
    // Load EPG time offset
    NSNumber *epgOffset = [settingsDict objectForKey:@"EPGTimeOffsetHours"];
    if (epgOffset) {
        self.epgTimeOffsetHours = [epgOffset integerValue];
    }
    
    // Load favorites data
    NSDictionary *favoritesData = [settingsDict objectForKey:@"FavoritesData"];
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
            
            //NSLog(@"Loaded %lu favorite channels from settings", (unsigned long)favoriteChannels.count);
        }
    }
}

// Helper method to get the settings file path
- (NSString *)settingsFilePath {
    NSString *appSupportDir = [self applicationSupportDirectory];
    return [appSupportDir stringByAppendingPathComponent:@"settings.plist"];
}

// Migration method to move UserDefaults data to Application Support
- (void)migrateUserDefaultsToApplicationSupport {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *settingsDict = [NSMutableDictionary dictionary];
    BOOL hasDataToMigrate = NO;
    
    // Migrate playlist URL
    NSString *playlistURL = [defaults objectForKey:@"PlaylistURL"];
    if (playlistURL) {
        [settingsDict setObject:playlistURL forKey:@"PlaylistURL"];
        hasDataToMigrate = YES;
    }
    
    // Migrate EPG URL
    NSString *epgURL = [defaults objectForKey:@"EPGURL"];
    if (epgURL) {
        [settingsDict setObject:epgURL forKey:@"EPGURL"];
        hasDataToMigrate = YES;
    }
    
    // Migrate EPG time offset
    if ([defaults objectForKey:@"EPGTimeOffsetHours"]) {
        [settingsDict setObject:@([defaults integerForKey:@"EPGTimeOffsetHours"]) forKey:@"EPGTimeOffsetHours"];
        hasDataToMigrate = YES;
    }
    
    // Migrate favorites data
    NSDictionary *favoritesData = [defaults objectForKey:@"FavoritesData"];
    if (favoritesData) {
        [settingsDict setObject:favoritesData forKey:@"FavoritesData"];
        hasDataToMigrate = YES;
    }
    
    // Migrate download timestamps
    NSDate *lastM3UDate = [defaults objectForKey:@"LastM3UDownloadDate"];
    if (lastM3UDate) {
        [settingsDict setObject:lastM3UDate forKey:@"LastM3UDownloadDate"];
        hasDataToMigrate = YES;
    }
    
    NSDate *lastEPGDate = [defaults objectForKey:@"LastEPGDownloadDate"];
    if (lastEPGDate) {
        [settingsDict setObject:lastEPGDate forKey:@"LastEPGDownloadDate"];
        hasDataToMigrate = YES;
    }
    
    if (hasDataToMigrate) {
        // Save migrated data to Application Support
        NSString *settingsPath = [self settingsFilePath];
        BOOL success = [settingsDict writeToFile:settingsPath atomically:YES];
        
        if (success) {
            //NSLog(@"Successfully migrated UserDefaults data to Application Support: %@", settingsPath);
            
            // Clear the old UserDefaults data after successful migration
            [defaults removeObjectForKey:@"PlaylistURL"];
            [defaults removeObjectForKey:@"EPGURL"];
            [defaults removeObjectForKey:@"EPGTimeOffsetHours"];
            [defaults removeObjectForKey:@"FavoritesData"];
            [defaults removeObjectForKey:@"LastM3UDownloadDate"];
            [defaults removeObjectForKey:@"LastEPGDownloadDate"];
            [defaults synchronize];
            
            //NSLog(@"Cleared old UserDefaults data after migration");
        } else {
            //NSLog(@"Failed to migrate UserDefaults data to Application Support");
        }
    }
}

- (BOOL)shouldUpdateM3UAtStartup {
    // Load from Application Support file instead of UserDefaults
    NSString *settingsPath = [self settingsFilePath];
    NSDictionary *settingsDict = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
    NSDate *lastDownload = [settingsDict objectForKey:@"LastM3UDownloadDate"];
    
    if (!lastDownload) {
        // No previous download, should update
        //NSLog(@"No previous M3U download date found, will update");
        return YES;
    }
    
    NSTimeInterval timeSinceDownload = [[NSDate date] timeIntervalSinceDate:lastDownload];
    NSTimeInterval oneDayInSeconds = 24 * 60 * 60; // 24 hours
    
    BOOL shouldUpdate = timeSinceDownload > oneDayInSeconds;
    //NSLog(@"Last M3U download was %.1f hours ago, %@", 
    //      timeSinceDownload / 3600.0, 
    //      shouldUpdate ? @"will update" : @"no update needed");
    
    return shouldUpdate;
}

- (BOOL)shouldUpdateEPGAtStartup {
    // Load from Application Support file instead of UserDefaults
    NSString *settingsPath = [self settingsFilePath];
    NSDictionary *settingsDict = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
    NSDate *lastDownload = [settingsDict objectForKey:@"LastEPGDownloadDate"];
    
    if (!lastDownload) {
        // No previous download, should update
        //NSLog(@"No previous EPG download date found, will update");
        return YES;
    }
    
    NSTimeInterval timeSinceDownload = [[NSDate date] timeIntervalSinceDate:lastDownload];
    NSTimeInterval sixHoursInSeconds = 6 * 60 * 60; // 6 hours
    
    BOOL shouldUpdate = timeSinceDownload > sixHoursInSeconds;
    //NSLog(@"Last EPG download was %.1f hours ago, %@", 
    //      timeSinceDownload / 3600.0, 
    //      shouldUpdate ? @"will update" : @"no update needed");
    
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