#import "VLCOverlayView+Favorites.h"
#import "VLCChannel.h"

#if TARGET_OS_OSX
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+Utilities.h"

@implementation VLCOverlayView (Favorites)
#else

// iOS/tvOS Category constants (matching VLCUIOverlayView.m)
typedef enum {
    CATEGORY_SEARCH = 0,
    CATEGORY_FAVORITES = 1,
    CATEGORY_TV = 2,
    CATEGORY_MOVIES = 3,
    CATEGORY_SERIES = 4,
    CATEGORY_SETTINGS = 5
} CategoryIndex;

@implementation VLCUIOverlayView (Favorites)
#endif

#pragma mark - Favorites Management

#if TARGET_OS_OSX || TARGET_OS_IOS || TARGET_OS_TV

- (void)addChannelToFavorites:(VLCChannel *)channel {
    if (!channel) {
        //NSLog(@"⚠️ [FAVORITES] Invalid channel passed to addChannelToFavorites");
        return;
    }
    
    // Thread-safe operation with proper data structure handling
    @synchronized(self) {
        @try {
            // Ensure favorites category is initialized
            [self ensureFavoritesCategory];
    
    // Create the favorites group if it doesn't exist
            NSString *groupName = @"Favorites";
            
            // Safe access to groupsByCategory property
            if (!self.groupsByCategory) {
                //NSLog(@"❌ [FAVORITES] groupsByCategory is nil during addChannelToFavorites");
                return;
            }
            
    NSMutableArray *favoritesGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
    if (!favoritesGroups) {
        favoritesGroups = [NSMutableArray array];
        [self.groupsByCategory setObject:favoritesGroups forKey:@"FAVORITES"];
    }
    
    // Add the group if it doesn't exist
    if (![favoritesGroups containsObject:groupName]) {
        [favoritesGroups addObject:groupName];
    }
            
            // Safe access to channelsByGroup property
            if (!self.channelsByGroup) {
                //NSLog(@"❌ [FAVORITES] channelsByGroup is nil during addChannelToFavorites");
                return;
    }
    
    // Create or get the group's channel array
    NSMutableArray *groupChannels = [self.channelsByGroup objectForKey:groupName];
    if (!groupChannels) {
        groupChannels = [NSMutableArray array];
        [self.channelsByGroup setObject:groupChannels forKey:groupName];
    }
    
    // Check if channel is already in favorites
    BOOL alreadyInFavorites = NO;
    for (VLCChannel *favChannel in groupChannels) {
        if ([favChannel.url isEqualToString:channel.url]) {
            alreadyInFavorites = YES;
            break;
        }
    }
    
    // Add the channel if not already in favorites
    if (!alreadyInFavorites) {
        // Create a copy of the channel before adding
        VLCChannel *favoriteChannel = [[VLCChannel alloc] init];
        favoriteChannel.name = channel.name;
        favoriteChannel.url = channel.url;
        favoriteChannel.group = groupName;  // Set to favorites group
        favoriteChannel.logo = channel.logo;
        favoriteChannel.channelId = channel.channelId;
        // CRITICAL: Preserve original category (MOVIES, SERIES, TV) to maintain display format
        favoriteChannel.category = channel.category;
        
        // CRITICAL FIX: Copy ALL timeshift/catchup properties
        favoriteChannel.supportsCatchup = channel.supportsCatchup;
        favoriteChannel.catchupDays = channel.catchupDays;
        favoriteChannel.catchupSource = channel.catchupSource;
        favoriteChannel.catchupTemplate = channel.catchupTemplate;
        
        // Debug: Log timeshift property copying
        if (channel.supportsCatchup) {
            NSLog(@"📺 [FAVORITES-TIMESHIFT] Copied timeshift properties for '%@': supportsCatchup=%@, catchupDays=%ld", 
                  channel.name, channel.supportsCatchup ? @"YES" : @"NO", (long)channel.catchupDays);
        }
        
        // CRITICAL FIX: Copy movie metadata properties
        favoriteChannel.movieId = channel.movieId;
        favoriteChannel.movieDescription = channel.movieDescription;
        favoriteChannel.movieGenre = channel.movieGenre;
        favoriteChannel.movieDuration = channel.movieDuration;
        favoriteChannel.movieYear = channel.movieYear;
        favoriteChannel.movieRating = channel.movieRating;
        favoriteChannel.movieDirector = channel.movieDirector;
        favoriteChannel.movieCast = channel.movieCast;
        favoriteChannel.hasLoadedMovieInfo = channel.hasLoadedMovieInfo;
        favoriteChannel.hasStartedFetchingMovieInfo = channel.hasStartedFetchingMovieInfo;
        favoriteChannel.cachedPosterImage = channel.cachedPosterImage;
                
                // CRITICAL FIX: Copy EPG programs from original channel
                if (channel.programs && channel.programs.count > 0) {
                    favoriteChannel.programs = [channel.programs mutableCopy];
                    //NSLog(@"📅 [FAVORITES] Copied %lu EPG programs to favorite channel: %@", 
                          //(unsigned long)channel.programs.count, channel.name);
                } else {
        favoriteChannel.programs = [NSMutableArray array];
                    //NSLog(@"⚠️ [FAVORITES] No EPG programs to copy for channel: %@", channel.name);
                }
        
        // Add to favorites group
        [groupChannels addObject:favoriteChannel];
        
                // Safe access to groups property
                if (self.groups && ![self.groups containsObject:groupName]) {
            [self.groups addObject:groupName];
        }
        
        [favoriteChannel release];
        
        // Save settings to persist favorites
        [self saveSettingsState];
        
        // Rebuild the simple channel lists if in favorites mode
        if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
            [self prepareSimpleChannelLists];
        }
        
        [self setNeedsDisplay:YES];
                //NSLog(@"✅ [FAVORITES] Successfully added channel to favorites: %@", channel.name);
            } else {
                //NSLog(@"ℹ️ [FAVORITES] Channel already in favorites: %@", channel.name);
            }
            
        } @catch (NSException *exception) {
            //NSLog(@"❌ [FAVORITES] Exception in addChannelToFavorites: %@", exception);
        }
    }
}

- (void)removeChannelFromFavorites:(VLCChannel *)channel {
    if (!channel) {
        //NSLog(@"⚠️ [FAVORITES] Invalid channel passed to removeChannelFromFavorites");
        return;
    }
    
    // Thread-safe operation with proper data structure handling
    @synchronized(self) {
        @try {
    // Get the favorites group
    NSString *favoritesGroup = @"Favorites";
            
            // Safe access to channelsByGroup property
            if (!self.channelsByGroup) {
                //NSLog(@"❌ [FAVORITES] channelsByGroup is nil during removeChannelFromFavorites");
                return;
            }
    
    // Get channels in favorites
    NSMutableArray *favoriteChannels = [self.channelsByGroup objectForKey:favoritesGroup];
    if (!favoriteChannels) {
                //NSLog(@"ℹ️ [FAVORITES] No favorites group or no channels in it");
        return;
    }
    
    // Find and remove the channel
    VLCChannel *channelToRemove = nil;
    for (VLCChannel *favChannel in favoriteChannels) {
        if ([favChannel.url isEqualToString:channel.url]) {
            channelToRemove = favChannel;
            break;
        }
    }
    
    if (channelToRemove) {
        [favoriteChannels removeObject:channelToRemove];
                //NSLog(@"✅ [FAVORITES] Removed channel from favorites: %@", channel.name);
        
        // Save settings to persist the removal
        [self saveSettingsState];
        
        // If that was the last channel, could remove the group from FAVORITES category
        // but let's leave the empty group for user clarity
        
        // Rebuild the simple channel lists if in favorites mode
        if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
            [self prepareSimpleChannelLists];
        }
        
        [self setNeedsDisplay:YES];
            } else {
                //NSLog(@"ℹ️ [FAVORITES] Channel not found in favorites: %@", channel.name);
            }
            
        } @catch (NSException *exception) {
            //NSLog(@"❌ [FAVORITES] Exception in removeChannelFromFavorites: %@", exception);
        }
    }
}

- (void)addGroupToFavorites:(NSString *)groupName {
    if (!groupName) {
        //NSLog(@"⚠️ [FAVORITES] Invalid groupName passed to addGroupToFavorites");
        return;
    }
    
    // Thread-safe operation with proper data structure handling
    @synchronized(self) {
        @try {
    // Ensure favorites category exists
    [self ensureFavoritesCategory];
            
            // Safe access to groupsByCategory property
            if (!self.groupsByCategory) {
                //NSLog(@"❌ [FAVORITES] groupsByCategory is nil during addGroupToFavorites");
                return;
            }
    
    // Get the favorites groups array
    NSMutableArray *favoritesGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
            if (!favoritesGroups) {
                //NSLog(@"❌ [FAVORITES] FAVORITES category not initialized properly");
                return;
            }
    
    // Add the group to favorites if not already there
    if (![favoritesGroups containsObject:groupName]) {
        [favoritesGroups addObject:groupName];
                //NSLog(@"✅ [FAVORITES] Added group %@ to favorites", groupName);
                
                // Safe access to channelsByGroup property
                if (!self.channelsByGroup) {
                    //NSLog(@"❌ [FAVORITES] channelsByGroup is nil during addGroupToFavorites");
                    return;
                }
        
        // Get all channels from this group in the original category
        NSArray *channelsInGroup = [self.channelsByGroup objectForKey:groupName];
        
        // Create an empty array for the group if needed
        NSMutableArray *favoriteChannels = [NSMutableArray array];
        
        // Copy existing channels to favorites if they exist
        if (channelsInGroup && [channelsInGroup count] > 0) {
            for (VLCChannel *originalChannel in channelsInGroup) {
                // Create a copy of the channel
                VLCChannel *favoriteChannel = [[VLCChannel alloc] init];
                favoriteChannel.name = originalChannel.name;
                favoriteChannel.url = originalChannel.url;
                favoriteChannel.group = groupName;
                favoriteChannel.logo = originalChannel.logo;
                favoriteChannel.channelId = originalChannel.channelId;
                // CRITICAL: Preserve original category (MOVIES, SERIES, TV) to maintain display format
                favoriteChannel.category = originalChannel.category;
                
                // CRITICAL FIX: Copy ALL timeshift/catchup properties
                favoriteChannel.supportsCatchup = originalChannel.supportsCatchup;
                favoriteChannel.catchupDays = originalChannel.catchupDays;
                favoriteChannel.catchupSource = originalChannel.catchupSource;
                favoriteChannel.catchupTemplate = originalChannel.catchupTemplate;
                
                // Debug: Log timeshift property copying
                if (originalChannel.supportsCatchup) {
                    NSLog(@"📺 [FAVORITES-TIMESHIFT] Copied timeshift properties for '%@': supportsCatchup=%@, catchupDays=%ld", 
                          originalChannel.name, originalChannel.supportsCatchup ? @"YES" : @"NO", (long)originalChannel.catchupDays);
                }
                
                // CRITICAL FIX: Copy movie metadata properties
                favoriteChannel.movieId = originalChannel.movieId;
                favoriteChannel.movieDescription = originalChannel.movieDescription;
                favoriteChannel.movieGenre = originalChannel.movieGenre;
                favoriteChannel.movieDuration = originalChannel.movieDuration;
                favoriteChannel.movieYear = originalChannel.movieYear;
                favoriteChannel.movieRating = originalChannel.movieRating;
                favoriteChannel.movieDirector = originalChannel.movieDirector;
                favoriteChannel.movieCast = originalChannel.movieCast;
                favoriteChannel.hasLoadedMovieInfo = originalChannel.hasLoadedMovieInfo;
                favoriteChannel.hasStartedFetchingMovieInfo = originalChannel.hasStartedFetchingMovieInfo;
                favoriteChannel.cachedPosterImage = originalChannel.cachedPosterImage;
                        
                        // CRITICAL FIX: Copy EPG programs from original channel
                        if (originalChannel.programs && originalChannel.programs.count > 0) {
                            favoriteChannel.programs = [originalChannel.programs mutableCopy];
                            //NSLog(@"📅 [FAVORITES] Copied %lu EPG programs to favorite channel: %@", 
                                 // (unsigned long)originalChannel.programs.count, originalChannel.name);
                        } else {
                favoriteChannel.programs = [NSMutableArray array];
                            //NSLog(@"⚠️ [FAVORITES] No EPG programs to copy for channel: %@", originalChannel.name);
                        }
                
                [favoriteChannels addObject:favoriteChannel];
                [favoriteChannel release];
            }
        }
        
        // Update the channel list for this group in favorites
        [self.channelsByGroup setObject:favoriteChannels forKey:groupName];
        
                // Safe access to groups property
                if (self.groups && ![self.groups containsObject:groupName]) {
            [self.groups addObject:groupName];
        }
        
        // Save settings to persist favorites
        [self saveSettingsState];
        
        // Rebuild UI to show the updated favorites
        [self prepareSimpleChannelLists];
                
                //NSLog(@"✅ [FAVORITES] Successfully added group with %lu channels to favorites: %@", 
                      //(unsigned long)favoriteChannels.count, groupName);
            } else {
                //NSLog(@"ℹ️ [FAVORITES] Group already in favorites: %@", groupName);
    }
    
    // Refresh the display
    [self setNeedsDisplay:YES];
            
        } @catch (NSException *exception) {
           // NSLog(@"❌ [FAVORITES] Exception in addGroupToFavorites: %@", exception);
        }
    }
}

- (void)removeGroupFromFavorites:(NSString *)groupName {
    if (!groupName) {
        //NSLog(@"⚠️ [FAVORITES] Invalid groupName passed to removeGroupFromFavorites");
        return;
    }
    
    // Thread-safe operation with proper data structure handling
    @synchronized(self) {
        @try {
            // Safe access to groupsByCategory property
            if (!self.groupsByCategory) {
                //NSLog(@"❌ [FAVORITES] groupsByCategory is nil during removeGroupFromFavorites");
                return;
            }
    
    // Get the favorites groups array
    NSMutableArray *favoritesGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
    if ([favoritesGroups containsObject:groupName]) {
        [favoritesGroups removeObject:groupName];
                //NSLog(@"✅ [FAVORITES] Removed group %@ from favorites", groupName);
        
        // Save settings to persist the removal
        [self saveSettingsState];
            } else {
                //NSLog(@"ℹ️ [FAVORITES] Group not found in favorites: %@", groupName);
    }
    
    // Refresh the display
    [self setNeedsDisplay:YES];
            
        } @catch (NSException *exception) {
            //NSLog(@"❌ [FAVORITES] Exception in removeGroupFromFavorites: %@", exception);
        }
    }
}

- (BOOL)isChannelInFavorites:(VLCChannel *)channel {
    if (!channel) {
        return NO;
    }
    
    // Check if channel is in any of the favorites groups
    NSArray *favoriteGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
    if (!favoriteGroups) {
        return NO;
    }
    
    for (NSString *group in favoriteGroups) {
        NSArray *channelsInGroup = [self.channelsByGroup objectForKey:group];
        if (!channelsInGroup) {
            continue;
        }
        
        for (VLCChannel *favChannel in channelsInGroup) {
            if ([favChannel.url isEqualToString:channel.url]) {
                return YES;
            }
        }
    }
    
    return NO;
}

- (BOOL)isGroupInFavorites:(NSString *)groupName {
    if (!groupName) return NO;
    
    @synchronized(self) {
        // Get the favorites groups array
        NSArray *favoritesGroups = [self safeGroupsForCategory:@"FAVORITES"];
        
        // Add debugging log
        //NSLog(@"Checking if group '%@' is in favorites. Favorites groups: %@", 
        //     groupName, 
       //      favoritesGroups);
        
        // Check if the group is in favorites
        BOOL result = [favoritesGroups containsObject:groupName];
        //NSLog(@"Group '%@' is %@ favorites", groupName, result ? @"in" : @"NOT in");
        return result;
    }
}

#pragma mark - Menu Actions

#if TARGET_OS_OSX

- (void)addChannelToFavoritesAction:(NSMenuItem *)sender {
    // Get the channel from the menu item's represented object
    VLCChannel *channel = [sender representedObject];
    if (channel) {
        [self addChannelToFavorites:channel];
    }
}

- (void)removeChannelFromFavoritesAction:(NSMenuItem *)sender {
    // Get the channel from the menu item's represented object
    VLCChannel *channel = [sender representedObject];
    if (channel) {
        [self removeChannelFromFavorites:channel];
    }
}

- (void)addGroupToFavoritesAction:(NSMenuItem *)sender {
    // Get the group name from the menu item's represented object
    NSString *groupName = [sender representedObject];
    if (groupName) {
        // Store current selection before adding to favorites
        NSInteger previousCategory = self.selectedCategoryIndex;
        NSInteger previousGroup = self.selectedGroupIndex;
        
        // Add group to favorites
        [self addGroupToFavorites:groupName];
        
        // Keep the user in the current category (don't jump to Favorites)
        // self.selectedCategoryIndex = CATEGORY_FAVORITES; (removed this line)
        
        // Instead, stay in the current category and selection
        self.selectedCategoryIndex = previousCategory;
        self.selectedGroupIndex = previousGroup;
        
        // Provide feedback in the UI without changing view
        dispatch_async(dispatch_get_main_queue(), ^{
            // Show a brief message that will disappear after 2 seconds
            [self setLoadingStatusText:[NSString stringWithFormat:@"Added '%@' to Favorites", groupName]];
            
            // Clear status text after 2 seconds
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self setLoadingStatusText:@""];
            });
        });
        
        // Update the UI immediately
        [self prepareSimpleChannelLists];
        [self setNeedsDisplay:YES];
    }
}

- (void)removeGroupFromFavoritesAction:(NSMenuItem *)sender {
    // Get the group name from the menu item's represented object
    NSString *groupName = [sender representedObject];
    if (groupName) {
        // Store current selection
        NSInteger previousCategory = self.selectedCategoryIndex;
        NSInteger previousGroup = self.selectedGroupIndex;
        
        [self removeGroupFromFavorites:groupName];
        
        // If we were in favorites category, reset group selection if needed
        if (previousCategory == CATEGORY_FAVORITES) {
            NSArray *favoritesGroups = [self safeGroupsForCategory:@"FAVORITES"];
            
            // If the removed group was selected, clear selection
            if (previousGroup >= 0 && previousGroup < [favoritesGroups count]) {
                if ([[favoritesGroups objectAtIndex:previousGroup] isEqualToString:groupName]) {
                    self.selectedGroupIndex = -1;
                }
            }
        }
        
        // Update the UI immediately
        [self prepareSimpleChannelLists];
        [self setNeedsDisplay:YES];
    }
}

#endif // TARGET_OS_OSX

- (void)updateFavoritesWithEPGData {
    //NSLog(@"📅 [FAVORITES] Updating existing favorites with EPG data...");
    
    // Get all favorites groups
    NSArray *favoriteGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
    if (!favoriteGroups || favoriteGroups.count == 0) {
        //NSLog(@"📅 [FAVORITES] No favorites groups to update");
        return;
    }
    
    NSUInteger updatedChannels = 0;
    NSUInteger totalPrograms = 0;
    
    // Update each favorites group
    for (NSString *groupName in favoriteGroups) {
        NSMutableArray *favoriteChannels = [self.channelsByGroup objectForKey:groupName];
        if (!favoriteChannels) continue;
        
        // Update each channel in the group
        for (VLCChannel *favChannel in favoriteChannels) {
            if (!favChannel.channelId || [favChannel.channelId length] == 0) continue;
            
            // Find the corresponding channel in the main channel list with EPG data
            VLCChannel *mainChannel = [self findMainChannelWithId:favChannel.channelId url:favChannel.url];
            if (mainChannel && mainChannel.programs && mainChannel.programs.count > 0) {
                // Update favorite channel with EPG data
                favChannel.programs = [mainChannel.programs mutableCopy];
                updatedChannels++;
                totalPrograms += mainChannel.programs.count;
                //NSLog(@"📅 [FAVORITES] Updated %@ with %lu EPG programs", 
                //      favChannel.name, (unsigned long)mainChannel.programs.count);
            }
        }
    }
    
    //NSLog(@"📅 [FAVORITES] EPG update complete: %lu channels updated with %lu total programs", 
    //      (unsigned long)updatedChannels, (unsigned long)totalPrograms);
    
    // Refresh display if we're currently showing favorites
    if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
        [self setNeedsDisplay:YES];
    }
}

- (VLCChannel *)findMainChannelWithId:(NSString *)channelId url:(NSString *)url {
    // Search through all main channels to find matching channel with EPG data
    for (VLCChannel *channel in self.channels) {
        // Try to match by channel ID first (most accurate)
        if (channelId && [channelId length] > 0 && 
            channel.channelId && [channelId isEqualToString:channel.channelId]) {
            return channel;
        }
        
        // Fallback to URL matching if channel ID doesn't match
        if (url && [url length] > 0 && 
            channel.url && [url isEqualToString:channel.url]) {
            return channel;
        }
    }
    
    return nil;
}

#endif // TARGET_OS_OSX || TARGET_OS_IOS || TARGET_OS_TV

#pragma mark - iOS/tvOS Context Menu Implementation

#if TARGET_OS_IOS || TARGET_OS_TV

- (void)showContextMenuForChannel:(VLCChannel *)channel atPoint:(CGPoint)point {
    if (!channel) return;
    
    NSLog(@"📱 [CONTEXT-MENU] Showing context menu for channel: %@", channel.name);
    
    BOOL isInFavorites = [self isChannelInFavorites:channel];
    NSString *title = isInFavorites ? @"Remove from Favorites" : @"Add to Favorites";
    NSString *message = [NSString stringWithFormat:@"Channel: %@", channel.name];
    
    #if TARGET_OS_IOS
    // iOS - Use UIAlertController
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction *favoritesAction = [UIAlertAction actionWithTitle:title
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *action) {
        if (isInFavorites) {
            [self removeChannelFromFavorites:channel];
            //NSLog(@"📱 [FAVORITES] Removed channel from favorites: %@", channel.name);
        } else {
            [self addChannelToFavorites:channel];
            //NSLog(@"📱 [FAVORITES] Added channel to favorites: %@", channel.name);
        }
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    
    [alert addAction:favoritesAction];
    [alert addAction:cancelAction];
    
    // Configure for iPad
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self;
        alert.popoverPresentationController.sourceRect = CGRectMake(point.x, point.y, 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    
    // Present the alert
    UIViewController *vc = [self firstViewController];
    if (vc) {
        [vc presentViewController:alert animated:YES completion:nil];
    }
    #endif
    
    #if TARGET_OS_TV
    // tvOS - Show simple alert
    [self showTVOSAlertWithTitle:title
                         message:message
                  primaryAction:title
                 primaryHandler:^{
        if (isInFavorites) {
            [self removeChannelFromFavorites:channel];
            //NSLog(@"📺 [FAVORITES] Removed channel from favorites: %@", channel.name);
        } else {
            [self addChannelToFavorites:channel];
            //NSLog(@"📺 [FAVORITES] Added channel to favorites: %@", channel.name);
        }
    }];
    #endif
}

- (void)showContextMenuForGroup:(NSString *)groupName atPoint:(CGPoint)point {
    if (!groupName) return;
    
    //NSLog(@"📱 [CONTEXT-MENU] Showing context menu for group: %@", groupName);
    
    BOOL isInFavorites = [self isGroupInFavorites:groupName];
    NSString *title = isInFavorites ? @"Remove Group from Favorites" : @"Add Group to Favorites";
    NSString *message = [NSString stringWithFormat:@"Group: %@", groupName];
    
    #if TARGET_OS_IOS
    // iOS - Use UIAlertController
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction *favoritesAction = [UIAlertAction actionWithTitle:title
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction *action) {
        if (isInFavorites) {
            [self removeGroupFromFavorites:groupName];
            //NSLog(@"📱 [FAVORITES] Removed group from favorites: %@", groupName);
        } else {
            [self addGroupToFavorites:groupName];
            //NSLog(@"📱 [FAVORITES] Added group to favorites: %@", groupName);
        }
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    
    [alert addAction:favoritesAction];
    [alert addAction:cancelAction];
    
    // Configure for iPad
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self;
        alert.popoverPresentationController.sourceRect = CGRectMake(point.x, point.y, 1, 1);
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    
    // Present the alert
    UIViewController *vc = [self firstViewController];
    if (vc) {
        [vc presentViewController:alert animated:YES completion:nil];
    }
    #endif
    
    #if TARGET_OS_TV
    // tvOS - Show simple alert
    [self showTVOSAlertWithTitle:title
                         message:message
                  primaryAction:title
                 primaryHandler:^{
        if (isInFavorites) {
            [self removeGroupFromFavorites:groupName];
            //NSLog(@"📺 [FAVORITES] Removed group from favorites: %@", groupName);
        } else {
            [self addGroupToFavorites:groupName];
            //NSLog(@"📺 [FAVORITES] Added group to favorites: %@", groupName);
        }
    }];
    #endif
}

#pragma mark - tvOS Context Menu Helpers

- (void)showTVOSContextMenuForChannel:(VLCChannel *)channel {
    if (!channel) return;
    
    BOOL isInFavorites = [self isChannelInFavorites:channel];
    NSString *title = isInFavorites ? @"Remove from Favorites" : @"Add to Favorites";
    NSString *message = [NSString stringWithFormat:@"Channel: %@", channel.name];
    
    [self showTVOSAlertWithTitle:title
                         message:message
                  primaryAction:title
                 primaryHandler:^{
        if (isInFavorites) {
            [self removeChannelFromFavorites:channel];
            //NSLog(@"📺 [FAVORITES] Removed channel from favorites: %@", channel.name);
        } else {
            [self addChannelToFavorites:channel];
            //NSLog(@"📺 [FAVORITES] Added channel to favorites: %@", channel.name);
        }
    }];
}

- (void)showTVOSContextMenuForGroup:(NSString *)groupName {
    if (!groupName) return;
    
    BOOL isInFavorites = [self isGroupInFavorites:groupName];
    NSString *title = isInFavorites ? @"Remove Group from Favorites" : @"Add Group to Favorites";
    NSString *message = [NSString stringWithFormat:@"Group: %@", groupName];
    
    [self showTVOSAlertWithTitle:title
                         message:message
                  primaryAction:title
                 primaryHandler:^{
        if (isInFavorites) {
            [self removeGroupFromFavorites:groupName];
            //NSLog(@"📺 [FAVORITES] Removed group from favorites: %@", groupName);
        } else {
            [self addGroupToFavorites:groupName];
            //NSLog(@"📺 [FAVORITES] Added group to favorites: %@", groupName);
        }
    }];
}

- (void)showTVOSAlertWithTitle:(NSString *)title
                       message:(NSString *)message
                primaryAction:(NSString *)primaryAction
               primaryHandler:(void (^)(void))primaryHandler {
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *action = [UIAlertAction actionWithTitle:primaryAction
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *alertAction) {
        if (primaryHandler) {
            primaryHandler();
        }
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    
    [alert addAction:action];
    [alert addAction:cancelAction];
    
    // Present the alert
    UIViewController *vc = [self firstViewController];
    if (vc) {
        [vc presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - iOS/tvOS Helper Methods

- (UIViewController *)firstViewController {
    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = [responder nextResponder];
    }
    return nil;
}

#endif // TARGET_OS_IOS || TARGET_OS_TV

@end 
