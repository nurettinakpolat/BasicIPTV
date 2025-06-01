#import "VLCOverlayView+Favorites.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+Utilities.h"

@implementation VLCOverlayView (Favorites)

#pragma mark - Favorites Management

- (void)addChannelToFavorites:(VLCChannel *)channel {
    if (!channel) {
        NSLog(@"Invalid channel passed to addChannelToFavorites");
        return;
    }
    
    // Create the favorites group if it doesn't exist
    NSString *groupName = [NSString stringWithFormat:@"Favorites"];
    
    // Add the group to FAVORITES category
    NSMutableArray *favoritesGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
    if (!favoritesGroups) {
        favoritesGroups = [NSMutableArray array];
        [self.groupsByCategory setObject:favoritesGroups forKey:@"FAVORITES"];
    }
    
    // Add the group if it doesn't exist
    if (![favoritesGroups containsObject:groupName]) {
        [favoritesGroups addObject:groupName];
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
        favoriteChannel.category = @"FAVORITES";
        favoriteChannel.programs = [NSMutableArray array];
        
        // Add to favorites group
        [groupChannels addObject:favoriteChannel];
        
        // Add to list of all groups if not already there
        if (![self.groups containsObject:groupName]) {
            [self.groups addObject:groupName];
        }
        
        [favoriteChannel release];
        
        // Rebuild the simple channel lists if in favorites mode
        if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
            [self prepareSimpleChannelLists];
        }
        
        [self setNeedsDisplay:YES];
    }
}

- (void)removeChannelFromFavorites:(VLCChannel *)channel {
    if (!channel) {
        NSLog(@"Invalid channel passed to removeChannelFromFavorites");
        return;
    }
    
    // Get the favorites group
    NSString *favoritesGroup = @"Favorites";
    
    // Get channels in favorites
    NSMutableArray *favoriteChannels = [self.channelsByGroup objectForKey:favoritesGroup];
    if (!favoriteChannels) {
        // No favorites group or no channels in it
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
        
        // If that was the last channel, could remove the group from FAVORITES category
        // but let's leave the empty group for user clarity
        
        // Rebuild the simple channel lists if in favorites mode
        if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
            [self prepareSimpleChannelLists];
        }
        
        [self setNeedsDisplay:YES];
    }
}

- (void)addGroupToFavorites:(NSString *)groupName {
    if (!groupName) return;
    
    // Ensure favorites category exists
    [self ensureFavoritesCategory];
    
    // Get the favorites groups array
    NSMutableArray *favoritesGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
    
    // Add the group to favorites if not already there
    if (![favoritesGroups containsObject:groupName]) {
        [favoritesGroups addObject:groupName];
        
        NSLog(@"Added group %@ to favorites", groupName);
        
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
                favoriteChannel.category = @"FAVORITES";
                favoriteChannel.programs = [NSMutableArray array];
                
                [favoriteChannels addObject:favoriteChannel];
                [favoriteChannel release];
            }
        }
        
        // Update the channel list for this group in favorites
        [self.channelsByGroup setObject:favoriteChannels forKey:groupName];
        
        // Add to list of all groups if not already there
        if (![self.groups containsObject:groupName]) {
            [self.groups addObject:groupName];
        }
        
        // Save settings to persist favorites
        [self saveSettings];
        
        // Rebuild UI to show the updated favorites
        [self prepareSimpleChannelLists];
    }
    
    // Refresh the display
    [self setNeedsDisplay:YES];
}

- (void)removeGroupFromFavorites:(NSString *)groupName {
    if (!groupName) return;
    
    // Get the favorites groups array
    NSMutableArray *favoritesGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
    if ([favoritesGroups containsObject:groupName]) {
        [favoritesGroups removeObject:groupName];
        NSLog(@"Removed group %@ from favorites", groupName);
    }
    
    // Refresh the display
    [self setNeedsDisplay:YES];
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
        NSLog(@"Checking if group '%@' is in favorites. Favorites groups: %@", 
             groupName, 
             favoritesGroups);
        
        // Check if the group is in favorites
        BOOL result = [favoritesGroups containsObject:groupName];
        NSLog(@"Group '%@' is %@ favorites", groupName, result ? @"in" : @"NOT in");
        return result;
    }
}

#pragma mark - Menu Actions

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

@end 