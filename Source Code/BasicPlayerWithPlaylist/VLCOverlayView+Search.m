#import "VLCOverlayView+Search.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+PlayerControls.h"
#import "VLCSubtitleSettings.h"
#import <objc/runtime.h>
#import "VLCOverlayView+Utilities.h"
#import <math.h>
#import "VLCSliderControl.h"
#import "VLCOverlayView+Globals.h"

@implementation VLCOverlayView (Search)


#pragma mark - Selection Persistence

- (void)saveLastSelectedIndices {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.selectedCategoryIndex forKey:@"VLCLastSelectedCategory"];
    [defaults setInteger:self.selectedGroupIndex forKey:@"VLCLastSelectedGroup"];
    [defaults setInteger:self.selectedChannelIndex forKey:@"VLCLastSelectedChannel"];
    [defaults synchronize];
    //NSLog(@"Saved last selected indices: Cat=%ld, Group=%ld, Channel=%ld", 
    //      (long)self.selectedCategoryIndex, (long)self.selectedGroupIndex, (long)self.selectedChannelIndex);
}

- (void)loadAndRestoreLastSelectedIndices {
    @try {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (!defaults) {
            //NSLog(@"ERROR: NSUserDefaults is nil, cannot load selection indices");
            return;
        }
        
        // Ensure we have valid data structures before proceeding
        if (!self.categories || [self.categories count] == 0) {
            //NSLog(@"Categories not yet loaded, skipping selection restoration");
            return;
        }
        
        // Load saved indices with error handling
        NSInteger savedCategory = 0;
        NSInteger savedGroup = 0;
        NSInteger savedChannel = 0;
        
        @try {
            savedCategory = [defaults integerForKey:@"VLCLastSelectedCategory"];
            savedGroup = [defaults integerForKey:@"VLCLastSelectedGroup"];
            savedChannel = [defaults integerForKey:@"VLCLastSelectedChannel"];
        } @catch (NSException *exception) {
            //NSLog(@"Exception while reading saved indices: %@", exception);
            savedCategory = CATEGORY_FAVORITES; // Default fallback
            savedGroup = 0;
            savedChannel = 0;
        }
        
        //NSLog(@"Loading saved indices: Cat=%ld, Group=%ld, Channel=%ld", 
        //      (long)savedCategory, (long)savedGroup, (long)savedChannel);
        
        // Validate category index
        if (savedCategory >= 0 && savedCategory < self.categories.count) {
            self.selectedCategoryIndex = savedCategory;
            
            // Validate group index for this category
            NSArray *groups = [self getGroupsForCategoryIndex:savedCategory];
            if (groups && savedGroup >= 0 && savedGroup < groups.count) {
                self.selectedGroupIndex = savedGroup;
                
                // Prepare channel lists for the selected group
                [self prepareSimpleChannelLists];
                
                // Validate channel index for this group
                if (savedChannel >= 0 && savedChannel < self.simpleChannelNames.count) {
                    self.selectedChannelIndex = savedChannel;
                } else {
                    self.selectedChannelIndex = 0; // Default to first channel
                }
            } else {
                self.selectedGroupIndex = 0; // Default to first group
                self.selectedChannelIndex = 0; // Default to first channel
            }
        } else {
            // Default selections
            self.selectedCategoryIndex = CATEGORY_FAVORITES;
            self.selectedGroupIndex = 0;
            self.selectedChannelIndex = 0;
        }
        
        //NSLog(@"Restored selection to: Cat=%ld, Group=%ld, Channel=%ld", 
        //      (long)self.selectedCategoryIndex, (long)self.selectedGroupIndex, (long)self.selectedChannelIndex);
              
          // Center the selection in the menu and set hover indices to match (like auto-navigation)
        [self centerSelectionInMenuAndSetHoverIndices];
    } @catch (NSException *exception) {
        //NSLog(@"CRITICAL ERROR in loadAndRestoreLastSelectedIndices: %@", exception);
        // Set safe defaults
        self.selectedCategoryIndex = CATEGORY_FAVORITES;
        self.selectedGroupIndex = 0;
        self.selectedChannelIndex = 0;
    }
}

- (NSArray *)getGroupsForCategoryIndex:(NSInteger)categoryIndex {
    if (categoryIndex < 0 || categoryIndex >= self.categories.count) {
        return nil;
    }
    
    NSString *category = [self.categories objectAtIndex:categoryIndex];
    
    if ([category isEqualToString:@"FAVORITES"]) {
        return [self safeGroupsForCategory:@"FAVORITES"];
    } else if ([category isEqualToString:@"TV"]) {
        return [self safeTVGroups];
    } else if ([category isEqualToString:@"MOVIES"]) {
        return [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
    } else if ([category isEqualToString:@"SERIES"]) {
        return [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
    } else if ([category isEqualToString:@"SETTINGS"]) {
        return [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
    }
    
    return nil;
}

#pragma mark - Smart Search Selection

- (void)saveOriginalLocationForSearchedChannel:(VLCChannel *)channel {
    if (!channel) return;
    
    // Find the original location of this channel
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
                    VLCChannel *existingChannel = [channelsInGroup objectAtIndex:channelIndex];
                    
                    // Match by URL or name
                    if ([existingChannel.url isEqualToString:channel.url] || 
                        [existingChannel.name isEqualToString:channel.name]) {
                        
                        // Save the original location
                        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
                        [defaults setInteger:catIndex forKey:@"VLCSearchedChannelOriginalCategory"];
                        [defaults setInteger:groupIndex forKey:@"VLCSearchedChannelOriginalGroup"];
                        [defaults setInteger:channelIndex forKey:@"VLCSearchedChannelOriginalChannel"];
                        [defaults setObject:channel.url forKey:@"VLCSearchedChannelURL"];
                        [defaults synchronize];
                        
                        //NSLog(@"Saved original location for searched channel '%@': Cat=%ld, Group=%ld, Channel=%ld", 
                        //      channel.name, (long)catIndex, (long)groupIndex, (long)channelIndex);
                        return;
                    }
                }
            }
        }
    }
}

- (void)selectSearchAndRememberOriginalLocation:(VLCChannel *)channel {
    // Save the original location of this channel
    [self saveOriginalLocationForSearchedChannel:channel];
    
    // Switch to SEARCH category
    self.selectedCategoryIndex = CATEGORY_SEARCH;
    self.selectedGroupIndex = -1; // No groups in search
    self.selectedChannelIndex = -1; // Will be set by search results
    
    //NSLog(@"Switched to SEARCH category for channel: %@", channel.name);
}

@end


