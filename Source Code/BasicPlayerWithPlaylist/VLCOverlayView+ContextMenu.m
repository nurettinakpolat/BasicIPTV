#import "VLCOverlayView+ContextMenu.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+PlayerControls.h"
#import "VLCSubtitleSettings.h"
#import <objc/runtime.h>
#import "VLCOverlayView+Utilities.h"
#import <math.h>
#import "VLCSliderControl.h"
#import "VLCOverlayView+Globals.h"
#import "VLCOverlayView+ViewModes.h"

@implementation VLCOverlayView (ContextMenu)


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
            
            // CRITICAL FIX: Use preserved hover index when current hover index is -1
            // This ensures EPG continues to show when mouse moves to EPG area
            extern NSInteger lastValidHoveredChannelIndex;
            NSInteger effectiveHoverIndex = self.hoveredChannelIndex;
            
            if (effectiveHoverIndex < 0 && lastValidHoveredChannelIndex >= 0) {
                effectiveHoverIndex = lastValidHoveredChannelIndex;
            }
            
            if (channelsInGroup && effectiveHoverIndex >= 0 && effectiveHoverIndex < channelsInGroup.count) {
                channel = [channelsInGroup objectAtIndex:effectiveHoverIndex];
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
            //NSLog(@"Added 'Add to Favorites' menu item for group: %@", groupName);
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
        //NSLog(@"Playing timeshift for channel '%@' going back %@ hours", channel.name, hoursBack);
        
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
            
            //NSLog(@"Started timeshift playback for URL: %@", timeshiftUrl);
            
            // Force UI update
            [self setNeedsDisplay:YES];
        });
        
        // Save the timeshift URL as last played for resume functionality
        [self saveLastPlayedChannelUrl:timeshiftUrl];
        
        // Hide the channel list after starting playback
        [self hideChannelListWithFade];
    } else {
        //NSLog(@"Failed to generate timeshift URL for channel: %@", channel.name);
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
        //NSLog(@"Nothing to hide");
    }
    
    // Handle 'V' key to cycle through views
    if (key == 'v' || key == 'V') {
        // Cycle through view modes: Stacked, Grid, List
        currentViewMode = (currentViewMode + 1) % 3;
        
        // Update view mode based on currentViewMode
        switch (currentViewMode) {
            case 0: // Stacked
            isGridViewActive = NO;
                isStackedViewActive = YES;
                break;
            case 1: // Grid
                isGridViewActive = YES;
                isStackedViewActive = NO;
                break;
            case 2: // List
                isGridViewActive = NO;
                isStackedViewActive = NO;
                break;
            }
            
            // Reset hover state and scroll position
            // CRITICAL FIX: Don't reset hover index if we're preserving state for EPG
            extern BOOL isPersistingHoverState;
            if (!isPersistingHoverState) {
                //NSLog(@"ContextMenu: Resetting hover index from %ld to -1", (long)self.hoveredChannelIndex);
                self.hoveredChannelIndex = -1;
            } else {
                //NSLog(@"ContextMenu: Preserving hover index %ld (EPG persistence mode)", (long)self.hoveredChannelIndex);
            }
            channelScrollPosition = 0;
        
        // Save view mode preference
        [self saveViewModePreference];
        
            [self setNeedsDisplay:YES];
            return;
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
                    [self saveSettingsState];
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
                    [self saveSettingsState];
                    
                    // Load EPG data
                    [self loadEpgData];
                }
            }
            [self setNeedsDisplay:YES];
        } else if (key == 27) { // Escape
            // Cancel input
            self.m3uFieldActive = NO;
            self.epgFieldActive = NO;
            // EPG Time Offset dropdown is now handled by VLCDropdownManager
            [self.dropdownManager hideAllDropdowns];
            [self setNeedsDisplay:YES];
        } else if (key == 126 || key == 125) { // Up arrow (126) or Down arrow (125)
            // Arrow key navigation is now handled by VLCDropdownManager for dropdowns
            // No manual dropdown navigation needed
        } else if (key == 9) { // Tab - switch between fields
            if (self.m3uFieldActive) {
                self.m3uFieldActive = NO;
                self.epgFieldActive = YES;
                // Close any open dropdowns
                [self.dropdownManager hideAllDropdowns];
                self.epgCursorPosition = self.tempEpgUrl ? [self.tempEpgUrl length] : 0;
            } else if (self.epgFieldActive) {
                self.epgFieldActive = NO;
                self.m3uFieldActive = NO;
                // Show EPG Time Offset dropdown using dropdown manager
                VLCDropdown *dropdown = [self.dropdownManager dropdownWithIdentifier:@"EPGTimeOffset"];
                if (dropdown) {
                    dropdown.frame = self.epgTimeOffsetDropdownRect;
                    [self.dropdownManager showDropdown:@"EPGTimeOffset"];
                }
            } else {
                // Close dropdowns and go to M3U field
                [self.dropdownManager hideAllDropdowns];
                self.m3uFieldActive = YES;
                self.epgFieldActive = NO;
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
    
    // Check if we're in the settings panel
    if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
        NSString *selectedGroup = nil;
        NSArray *settingsGroups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
        
        if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < [settingsGroups count]) {
            selectedGroup = [settingsGroups objectAtIndex:self.selectedGroupIndex];
        }
        
        // Handle transparency slider dragging (only in Themes group)
        if (selectedGroup && [selectedGroup isEqualToString:@"Themes"]) {
            // Handle RGB sliders dragging (only when Custom theme is selected)
            if (self.currentTheme == VLC_THEME_CUSTOM) {
                // Red slider dragging
                if (!NSIsEmptyRect(self.redSliderRect) && [VLCSliderControl handleMouseDragged:point sliderRect:self.redSliderRect sliderHandle:@"red"]) {
                    CGFloat value = [VLCSliderControl valueForPoint:point
                                                       sliderRect:self.redSliderRect
                                                        minValue:0.0
                                                        maxValue:1.0];
                    
                    if (self.customThemeRed != value) {
                        self.customThemeRed = value;
                        [self updateThemeColors];
                        [self setNeedsDisplay:YES];
                    }
                    return;
                }
                
                // Green slider dragging
                if (!NSIsEmptyRect(self.greenSliderRect) && [VLCSliderControl handleMouseDragged:point sliderRect:self.greenSliderRect sliderHandle:@"green"]) {
                    CGFloat value = [VLCSliderControl valueForPoint:point
                                                       sliderRect:self.greenSliderRect
                                                        minValue:0.0
                                                        maxValue:1.0];
                    
                    if (self.customThemeGreen != value) {
                        self.customThemeGreen = value;
                        [self updateThemeColors];
                        [self setNeedsDisplay:YES];
                    }
                    return;
                }
                
                // Blue slider dragging
                if (!NSIsEmptyRect(self.blueSliderRect) && [VLCSliderControl handleMouseDragged:point sliderRect:self.blueSliderRect sliderHandle:@"blue"]) {
                    CGFloat value = [VLCSliderControl valueForPoint:point
                                                       sliderRect:self.blueSliderRect
                                                        minValue:0.0
                                                        maxValue:1.0];
                    
                    if (self.customThemeBlue != value) {
                        self.customThemeBlue = value;
                        [self updateThemeColors];
                        [self setNeedsDisplay:YES];
                    }
                    return;
                }
            }
            
            // Handle Selection Color RGB sliders (only when Custom theme is selected)
            if (self.currentTheme == VLC_THEME_CUSTOM) {
            // Selection Red slider dragging
                if ([VLCSliderControl handleMouseDragged:point sliderRect:self.selectionRedSliderRect sliderHandle:@"selectionRed"]) {
                CGFloat value = [VLCSliderControl valueForPoint:point
                                                   sliderRect:self.selectionRedSliderRect
                                                    minValue:0.0
                                                    maxValue:1.0];
                
                if (self.customSelectionRed != value) {
                    self.customSelectionRed = value;
                    [self updateSelectionColors];
                        [self saveThemeSettings];
                    [self setNeedsDisplay:YES];
                }
                return;
            }
            
            // Selection Green slider dragging
                if ([VLCSliderControl handleMouseDragged:point sliderRect:self.selectionGreenSliderRect sliderHandle:@"selectionGreen"]) {
                CGFloat value = [VLCSliderControl valueForPoint:point
                                                   sliderRect:self.selectionGreenSliderRect
                                                    minValue:0.0
                                                    maxValue:1.0];
                
                if (self.customSelectionGreen != value) {
                    self.customSelectionGreen = value;
                    [self updateSelectionColors];
                        [self saveThemeSettings];
                    [self setNeedsDisplay:YES];
                }
                return;
            }
            
            // Selection Blue slider dragging
                if ([VLCSliderControl handleMouseDragged:point sliderRect:self.selectionBlueSliderRect sliderHandle:@"selectionBlue"]) {
                CGFloat value = [VLCSliderControl valueForPoint:point
                                                   sliderRect:self.selectionBlueSliderRect
                                                    minValue:0.0
                                                    maxValue:1.0];
                
                if (self.customSelectionBlue != value) {
                    self.customSelectionBlue = value;
                    [self updateSelectionColors];
                        [self saveThemeSettings];
                    [self setNeedsDisplay:YES];
                }
                return;
                }
            }
            
            // Transparency slider dragging
            if ([VLCSliderControl handleMouseDragged:point sliderRect:self.transparencySliderRect sliderHandle:@"transparency"]) {
                CGFloat value = [VLCSliderControl valueForPoint:point
                                                   sliderRect:self.transparencySliderRect
                                                    minValue:0.0
                                                    maxValue:1.0];
                
                // Use the exact slider value instead of converting to discrete levels
                // This provides smooth transparency adjustment
                if (self.themeAlpha != value) {
                    self.themeAlpha = value;
                    [self updateThemeColors];
                    [self saveThemeSettings];
                    [self setNeedsDisplay:YES];
                }
                return;
            }
        }
        
        // Handle subtitle slider dragging (only in Subtitles group)
        if (selectedGroup && [selectedGroup isEqualToString:@"Subtitles"]) {
            NSValue *sliderRectValue = objc_getAssociatedObject(self, "subtitleFontSizeSliderRect");
            if (sliderRectValue) {
                NSRect sliderRect = [sliderRectValue rectValue];
                
                // Use VLCSliderControl activation system for consistency
                if ([VLCSliderControl handleMouseDragged:point sliderRect:sliderRect sliderHandle:@"subtitle"]) {
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
                        
                        //NSLog(@"Subtitle font scale dragged to: %ld (%.2fx)", (long)newFontSize, (float)newFontSize / 10.0f);
                        
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
    } else if (action == @selector(playCatchUpFromMenu:)) {
        // Validate catch-up menu item - check if program has archive
        VLCProgram *program = [menuItem representedObject];
        return (program != nil && program.hasArchive);
    } else if (action == @selector(playChannelFromEpgMenu:)) {
        // Always allow playing channel from EPG context menu
        return YES;
    } else if (action == @selector(playChannelFromMenu:)) {
        // Always allow playing channel from regular context menu
        return YES;
    } else if (action == @selector(showTimeshiftOptionsForChannel:)) {
        // Validate timeshift menu item - check if channel supports catchup
        VLCChannel *channel = [menuItem representedObject];
        return (channel != nil && channel.supportsCatchup);
    } else if (action == @selector(playTimeshiftFromMenu:)) {
        // Always allow timeshift playback if the menu item was created
        return YES;
    } else if (action == @selector(addChannelToFavoritesAction:)) {
        // Always allow adding channels to favorites
        return YES;
    } else if (action == @selector(removeChannelFromFavoritesAction:)) {
        // Always allow removing channels from favorites
        return YES;
    } else if (action == @selector(addGroupToFavoritesAction:)) {
        // Always allow adding groups to favorites
        return YES;
    } else if (action == @selector(removeGroupFromFavoritesAction:)) {
        // Always allow removing groups from favorites
        return YES;
    } else if (action == @selector(playFirstChannelInGroupAction:)) {
        // Always allow playing first channel in group
        return YES;
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
    
    if (!channel) {
        return;
    }
    
    // Calculate position for the panel
    CGFloat rowHeight = 400;
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
    
    // Use theme colors for program guide background
    NSColor *programGuideStartColor, *programGuideEndColor;
    if (self.themeChannelStartColor && self.themeChannelEndColor) {
        // Make the program guide slightly darker than channel list
        CGFloat darkAlpha = self.themeAlpha * 0.9; // Slightly more transparent
        programGuideStartColor = [self.themeChannelStartColor colorWithAlphaComponent:darkAlpha];
        programGuideEndColor = [self.themeChannelEndColor colorWithAlphaComponent:darkAlpha];
    } else {
        programGuideStartColor = [NSColor colorWithCalibratedRed:0.08 green:0.10 blue:0.14 alpha:0.65];
        programGuideEndColor = [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:0.65];
    }
    
    NSGradient *programGuideGradient = [[NSGradient alloc] initWithStartingColor:programGuideStartColor endingColor:programGuideEndColor];
    [programGuideGradient drawInRect:guidePanelRect angle:90];
    [programGuideGradient release];
    
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
            // Current live program gets theme-based highlight colors
            if (program.hasArchive) {
                // Current program with catch-up: use theme colors with green tint
                if (self.currentTheme == VLC_THEME_GREEN) {
                    cardBgColor = [NSColor colorWithCalibratedRed:0.08 green:0.25 blue:0.15 alpha:0.6];
                    cardBorderColor = [NSColor colorWithCalibratedRed:0.2 green:0.7 blue:0.4 alpha:0.8];
                } else if (self.currentTheme == VLC_THEME_BLUE) {
                    cardBgColor = [NSColor colorWithCalibratedRed:0.08 green:0.20 blue:0.32 alpha:0.6];
                    cardBorderColor = [NSColor colorWithCalibratedRed:0.2 green:0.6 blue:0.9 alpha:0.8];
                } else if (self.currentTheme == VLC_THEME_PURPLE) {
                    cardBgColor = [NSColor colorWithCalibratedRed:0.20 green:0.12 blue:0.25 alpha:0.6];
                    cardBorderColor = [NSColor colorWithCalibratedRed:0.6 green:0.3 blue:0.8 alpha:0.8];
                } else {
                    // Dark themes get blue-green tint
                    cardBgColor = [NSColor colorWithCalibratedRed:0.10 green:0.28 blue:0.35 alpha:0.6];
                    cardBorderColor = [NSColor colorWithCalibratedRed:0.3 green:0.8 blue:0.6 alpha:0.8];
                }
            } else {
                // Current program without catch-up: theme-based highlight
                if (self.currentTheme == VLC_THEME_BLUE) {
                    cardBgColor = [NSColor colorWithCalibratedRed:0.10 green:0.20 blue:0.35 alpha:0.5];
                    cardBorderColor = [NSColor colorWithCalibratedRed:0.3 green:0.6 blue:1.0 alpha:0.7];
                } else if (self.currentTheme == VLC_THEME_GREEN) {
                    cardBgColor = [NSColor colorWithCalibratedRed:0.08 green:0.25 blue:0.15 alpha:0.5];
                    cardBorderColor = [NSColor colorWithCalibratedRed:0.2 green:0.8 blue:0.4 alpha:0.7];
                } else if (self.currentTheme == VLC_THEME_PURPLE) {
                    cardBgColor = [NSColor colorWithCalibratedRed:0.20 green:0.12 blue:0.30 alpha:0.5];
                    cardBorderColor = [NSColor colorWithCalibratedRed:0.6 green:0.3 blue:0.9 alpha:0.7];
                } else {
                    // Dark themes get standard blue highlight
                    cardBgColor = [NSColor colorWithCalibratedRed:0.12 green:0.24 blue:0.4 alpha:0.5];
                    cardBorderColor = [NSColor colorWithCalibratedRed:0.4 green:0.7 blue:1.0 alpha:0.7];
                }
            }
            timeColor = [NSColor colorWithCalibratedRed:0.6 green:0.9 blue:1.0 alpha:1.0];
            titleColor = [NSColor whiteColor];
            descColor = [NSColor colorWithCalibratedWhite:0.85 alpha:1.0];
        } else if (program.hasArchive) {
            // Non-current program with catch-up: theme-based light tint
            if (self.currentTheme == VLC_THEME_GREEN) {
                cardBgColor = [NSColor colorWithCalibratedRed:0.08 green:0.18 blue:0.12 alpha:0.5];
                cardBorderColor = [NSColor colorWithCalibratedRed:0.15 green:0.4 blue:0.25 alpha:0.5];
                timeColor = [NSColor colorWithCalibratedRed:0.6 green:0.9 blue:0.7 alpha:1.0];
            } else if (self.currentTheme == VLC_THEME_BLUE) {
                cardBgColor = [NSColor colorWithCalibratedRed:0.08 green:0.15 blue:0.20 alpha:0.5];
                cardBorderColor = [NSColor colorWithCalibratedRed:0.15 green:0.35 blue:0.5 alpha:0.5];
                timeColor = [NSColor colorWithCalibratedRed:0.6 green:0.8 blue:0.9 alpha:1.0];
            } else if (self.currentTheme == VLC_THEME_PURPLE) {
                cardBgColor = [NSColor colorWithCalibratedRed:0.15 green:0.10 blue:0.18 alpha:0.5];
                cardBorderColor = [NSColor colorWithCalibratedRed:0.3 green:0.2 blue:0.4 alpha:0.5];
                timeColor = [NSColor colorWithCalibratedRed:0.8 green:0.7 blue:0.9 alpha:1.0];
            } else {
                // Dark themes get default green tint
                cardBgColor = [NSColor colorWithCalibratedRed:0.12 green:0.22 blue:0.15 alpha:0.5];
                cardBorderColor = [NSColor colorWithCalibratedRed:0.2 green:0.5 blue:0.3 alpha:0.5];
                timeColor = [NSColor colorWithCalibratedRed:0.7 green:0.9 blue:0.7 alpha:1.0];
            }
            titleColor = [NSColor colorWithCalibratedWhite:0.95 alpha:1.0];
            descColor = [NSColor colorWithCalibratedRed:0.8 green:0.9 blue:0.8 alpha:1.0];
        } else {
            // Other programs get theme-based standard card colors
            if (self.themeChannelStartColor && self.themeChannelEndColor) {
                // Use a slightly lighter version of the theme colors for cards
                CGFloat cardAlpha = self.themeAlpha * 0.7;
                cardBgColor = [self.themeChannelStartColor colorWithAlphaComponent:cardAlpha];
                cardBorderColor = [self.themeChannelEndColor colorWithAlphaComponent:cardAlpha * 0.8];
            } else {
                // Fallback to standard colors
                cardBgColor = [NSColor colorWithCalibratedRed:0.15 green:0.15 blue:0.15 alpha:0.5];
                cardBorderColor = [NSColor colorWithCalibratedRed:0.3 green:0.3 blue:0.3 alpha:0.4];
            }
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
    //NSLog(@"Drawing movie info for channel: %@", channel.name);
    //NSLog(@"Channel logo URL: %@", channel.logo);
    //NSLog(@"Channel category: %@", channel.category);
    
    // Define constant for the increased background height
    CGFloat backgroundHeightIncrease = 30.0;
    
    // Determine loading status based on channel properties
    BOOL isFetchingInfo = channel.hasStartedFetchingMovieInfo && !channel.hasLoadedMovieInfo;
    
    // Calculate base measurements based on available space
    CGFloat padding = MAX(10, panelRect.size.width * 0.02); // Responsive padding (min 10px)
    CGFloat rowHeight = 400;
    
    // Apply scroll position with debugging
    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];
    
    // Use the standard panel rect for clipping to avoid issues
    NSBezierPath *clipPath = [NSBezierPath bezierPathWithRect:panelRect];
    [clipPath setClip];
    
    // Apply the scroll offset to the content - this is critical for scrolling to work
    CGFloat scrollOffset = self.movieInfoScrollPosition;
    //NSLog(@"Applying scroll offset: %.1f to movie info panel", scrollOffset);
    
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
    //NSLog(@"Has logo: %@", hasLogo ? @"YES" : @"NO");
    
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
            //NSLog(@"Encoded URL: %@", logoUrl);
        }
        
        //NSLog(@"Attempting to load image from: %@", logoUrl);
        
        // Try to load the image from the URL
        if (logoUrl && [logoUrl length] > 0) {
            //NSLog(@"Loading from web URL: %@", logoUrl);
            
            // Create a URL object
            NSURL *imageUrl = [NSURL URLWithString:logoUrl];
            if (!imageUrl) {
                //NSLog(@"Invalid URL format: %@", logoUrl);
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
            
            //NSLog(@"Drawing image in rect: %@", NSStringFromRect(safeDrawRect));
            [posterImage drawInRect:safeDrawRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
            
            [NSGraphicsContext restoreGraphicsState];
    } else if (!channel.hasStartedFetchingMovieInfo || !hasLogo) {
        // Only draw background when there's no logo - using exact poster rect which is visible
        NSRect safeRect = posterRect;
        [[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0] set];
        NSRectFill(safeRect);
        //NSLog(@"Drawing placeholder background - no logo available");
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
            
            //NSLog(@"Scroll indicator: content height = %.1f, scroll pos = %.1f", 
            //      contentHeight, self.movieInfoScrollPosition);
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
    // Determine which region the mouse is in
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    
    // Calculate channelListWidth dynamically based on content type
    CGFloat programGuideWidth = 400; // Updated to match the drawing code
    CGFloat channelListWidth;
    CGFloat movieInfoX;
    
    // Check if we're displaying movies in grid or stacked view (which should take full width)
    BOOL isMovieViewMode = (isGridViewActive || isStackedViewActive) && 
                          ((self.selectedCategoryIndex == CATEGORY_MOVIES) ||
                           (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]));
    
    if (isMovieViewMode) {
        // Movies in grid/stacked view take the full available space
        channelListWidth = self.bounds.size.width - catWidth - groupWidth;
        movieInfoX = self.bounds.size.width; // No movie info panel when in movie view modes
    } else {
        // Regular layout with program guide
        channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
        movieInfoX = catWidth + groupWidth + channelListWidth;
    }
    
    // Define exact boundaries for the channel list area
    CGFloat channelListStartX = catWidth + groupWidth;
    CGFloat channelListEndX = channelListStartX + channelListWidth;
    
    //NSLog(@"🔍 simpleChannelIndexAtPoint: point=(%.1f,%.1f), startX=%.1f, endX=%.1f, width=%.1f", 
    //      point.x, point.y, channelListStartX, channelListEndX, channelListWidth);
    
    // Check if the mouse is actually within the channel list area
    if (point.x < channelListStartX || point.x >= channelListEndX) {
        //NSLog(@"🚫 Point outside channel list area - returning -1");
        return -1; // Mouse is outside channel list area
    }
    
    // Use the correct row height based on view mode
    CGFloat rowHeight = 40; // Default for regular list view
    
    // Check if we're in stacked view mode for movies
    if (isStackedViewActive && isMovieViewMode) {
        rowHeight = 400; // Default stacked view row height
        
        // Apply the same row height adjustment logic as in drawStackedView
        NSRect stackedRect = NSMakeRect(channelListStartX, 0, channelListWidth, self.bounds.size.height);
        NSInteger minVisibleRows = 4;
        CGFloat requiredHeight = minVisibleRows * rowHeight;
        if (stackedRect.size.height < requiredHeight) {
            rowHeight = MAX(80, stackedRect.size.height / minVisibleRows);
        }
    }
    
    if (isStackedViewActive) {
        // Use the exact positioning logic from drawStackedView for stacked view
        NSRect stackedRect = NSMakeRect(channelListStartX, 0, channelListWidth, self.bounds.size.height);
        
        // Get current movies count
        NSArray *moviesInCurrentGroup = [self getChannelsForCurrentGroup];
        if (!moviesInCurrentGroup || moviesInCurrentGroup.count == 0) {
            return -1;
        }
        
        // Apply the EXACT same scroll calculations as drawStackedView
        CGFloat totalContentHeight = moviesInCurrentGroup.count * rowHeight;
        totalContentHeight += rowHeight; // Add extra space at bottom
        
        CGFloat maxScroll = MAX(0, totalContentHeight - stackedRect.size.height);
        CGFloat scrollPosition = MIN(channelScrollPosition, maxScroll); // Apply same scroll limits
        
        // Check each movie position to find which one the mouse is over
        for (NSInteger i = 0; i < moviesInCurrentGroup.count; i++) {
            // Use the exact same calculation as drawStackedView
            CGFloat movieYPosition = stackedRect.size.height - ((i + 1) * rowHeight) + scrollPosition;
            
            NSRect itemRect = NSMakeRect(channelListStartX, 
                                         movieYPosition, 
                                         channelListWidth, 
                                         rowHeight);
            
            // Check if the mouse point is within this movie's rect
            if (NSPointInRect(point, itemRect)) {
                return i;
            }
        }
        
        return -1;
    } else {
        // Regular list view calculation - must match exactly how drawChannelList positions items
        
        // Get the appropriate scroll position (same logic as drawChannelList)
        CGFloat currentScrollPosition;
        if (self.selectedCategoryIndex == CATEGORY_SEARCH) {
            currentScrollPosition = self.searchChannelScrollPosition;
        } else {
            currentScrollPosition = channelScrollPosition;
        }
        
        // Get current channels
        NSArray *channels = [self getChannelsForCurrentGroup];
        if (!channels || channels.count == 0) {
            //NSLog(@"🚫 No channels available");
            return -1;
        }
        
        //NSLog(@"📋 Found %ld channels, using scroll position %.1f", (long)channels.count, currentScrollPosition);
        
        // Calculate which channel the mouse is over using simplified Y calculation
        // This matches exactly how channels are drawn in the drawChannelList method
        CGFloat totalY = self.bounds.size.height - point.y + currentScrollPosition;
        NSInteger channelIndex = (NSInteger)(totalY / rowHeight);
        
        //NSLog(@"🎯 Calculated channel index: %ld (totalY=%.1f, rowHeight=%.1f)", 
        //      (long)channelIndex, totalY, rowHeight);
        
        // Validate the calculated index
        if (channelIndex >= 0 && channelIndex < channels.count) {
            //NSLog(@"✅ Found valid channel at index %ld", (long)channelIndex);
            return channelIndex;
        } else {
            //NSLog(@"❌ Channel index %ld out of range (0-%ld)", (long)channelIndex, (long)(channels.count - 1));
            return -1;
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
    
    // Add extra space at the bottom to ensure last row is fully visible when scrolled to the end
    totalGridHeight += itemHeight;
    
    // CRITICAL FIX: Use same content height calculation as drawGridView (accounts for header space)
    CGFloat contentHeight = self.bounds.size.height - 40;
    CGFloat maxScroll = MAX(0, totalGridHeight - contentHeight);
    CGFloat scrollOffset = MAX(0, MIN(channelScrollPosition, maxScroll));
    
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
        //NSLog(@"Image already cached for channel: %@", channel.name);
        return;
    }
    
    // We use a separate property to track image loading
    if (objc_getAssociatedObject(channel, "imageLoadingInProgress")) {
        //NSLog(@"Image loading already in progress for channel: %@", channel.name);
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
        //NSLog(@"URL doesn't have http/https prefix, adding http://: %@", imageUrl);
        imageUrl = [@"http://" stringByAppendingString:imageUrl];
    }
    
    //NSLog(@"Starting image download for channel: %@ from URL: %@", channel.name, imageUrl);
    
    // Create URL object with validation
    NSURL *url = [NSURL URLWithString:imageUrl];
    if (!url) {
        //NSLog(@"Invalid image URL format: %@", imageUrl);
        // Clear loading state
        objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    
    // Final URL validation to prevent empty host issues
    if (!url.host || [url.host length] == 0) {
        //NSLog(@"URL has no valid host: %@", imageUrl);
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
            //NSLog(@"Error loading image data for channel %@: %@", channel.name, [error localizedDescription]);
            
            // Clear the loading flag on error
        dispatch_async(dispatch_get_main_queue(), ^{
                objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
            return;
        }
        
        // Check HTTP status
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            //NSLog(@"HTTP error loading image for channel %@: %ld", channel.name, (long)httpResponse.statusCode);
            
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
                //NSLog(@"Failed to create image from downloaded data for channel: %@", channel.name);
                
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
            
            //NSLog(@"Successfully downloaded and cached image for channel: %@", channel.name);
        });
    }];
    
    [task resume];
}
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
    
    //NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    //if (isFadingOut && currentTime - lastFadeOutTime < 0.1f) return;
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
            if (isGridViewActive && ((self.selectedCategoryIndex == CATEGORY_MOVIES) || 
                                   (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]))) {
                [self drawGridView:dirtyRect];
                
                // When movies become visible in grid view, check cache and fetch missing info
                [self validateMovieInfoForVisibleItems];
            } else if (isStackedViewActive && ((self.selectedCategoryIndex == CATEGORY_MOVIES) || 
                                             (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]))) {
                [self drawStackedView:dirtyRect];
                
                // When movies become visible in stacked view, check cache and fetch missing info
                [self validateMovieInfoForVisibleItems];
            } else {
                [self drawChannelList:dirtyRect];
                
                // Also check for visible movies in list view if current group contains movies
                if ((self.selectedCategoryIndex == CATEGORY_MOVIES) || 
                    (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels])) {
                    [self validateMovieInfoForVisibleItems];
                }
                
                // REMOVED: No longer bulk process ranges of channels - only visible movies handled above
                // All movie info fetching is now handled by validateMovieInfoForVisibleItems method
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
    
    // Draw background for grid area using theme colors
    NSRect gridBackground = NSMakeRect(gridX, 0, gridWidth, self.bounds.size.height);
    
    // Use theme colors for grid background (consistent with other panels)
    NSColor *gridStartColor, *gridEndColor;
    if (self.themeChannelStartColor && self.themeChannelEndColor) {
        // Use theme colors with proper alpha adjustment
        CGFloat gridAlpha = self.themeAlpha * 0.85;
        gridStartColor = [self.themeChannelStartColor colorWithAlphaComponent:gridAlpha];
        gridEndColor = [self.themeChannelEndColor colorWithAlphaComponent:gridAlpha];
    } else {
        // Fallback colors consistent with theme system defaults
        gridStartColor = [NSColor colorWithCalibratedRed:0.08 green:0.10 blue:0.14 alpha:0.7];
        gridEndColor = [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.16 alpha:0.7];
    }
    
    NSGradient *gridGradient = [[NSGradient alloc] initWithStartingColor:gridStartColor endingColor:gridEndColor];
    [gridGradient drawInRect:gridBackground angle:90];
    [gridGradient release];
    
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
    //NSString *headerText = @"Grid View";
    //NSString *currentGroup = [self getCurrentGroupName];
   // if (currentGroup) {
   //     headerText = [NSString stringWithFormat:@"Grid View: %@", currentGroup];
   // }
    /*
    NSMutableParagraphStyle *headerStyle = [[NSMutableParagraphStyle alloc] init];
    [headerStyle setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *headerAttrs = @{
        NSFontAttributeName: [NSFont fontWithName:@"HelveticaNeue-Light" size:16] ?: [NSFont systemFontOfSize:16],
        NSForegroundColorAttributeName: self.textColor,
        NSParagraphStyleAttributeName: headerStyle
    };
    
    //NSRect headerRect = NSMakeRect(gridX, self.bounds.size.height - 40, gridWidth, 40);
    //[headerText drawInRect:headerRect withAttributes:headerAttrs];
    //[headerStyle release];
    */
    // Draw info text
    NSMutableParagraphStyle *infoStyle = [[NSMutableParagraphStyle alloc] init];
    [infoStyle setAlignment:NSTextAlignmentRight];
    
    NSDictionary *infoAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor lightGrayColor],
        NSParagraphStyleAttributeName: infoStyle
    };
    
    NSString *infoText = @"Press 'V' to change view mode";
    NSRect infoRect = NSMakeRect(self.bounds.size.width/2 + 70, self.bounds.size.height - 20, 240, 20);
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
        
        // Get the channel and ensure cached image is loaded for immediate display
        VLCChannel *channel = [channelsToShow objectAtIndex:i];
        
        // For grid view, immediately try to load cached poster image if not already loaded
        // This ensures cached images display immediately when grid view is shown
        if ([channel.category isEqualToString:@"MOVIES"] && !channel.cachedPosterImage) {
            [self loadCachedPosterImageForChannel:channel];
        }
        
        [self drawGridItem:channel atRect:NSMakeRect(x, y, itemWidth, itemHeight) highlight:(i == self.hoveredChannelIndex)];
        
        // REMOVED: Don't automatically download for each grid item - handled by validateMovieInfoForVisibleItems
        // [self queueAsyncLoadForGridChannel:channel atIndex:i];
    }
    
    // Draw the scroll bar
    [self drawScrollBar:contentRect contentHeight:totalGridHeight scrollPosition:scrollOffset];
}

// Helper method to draw a single grid item
- (void)drawGridItem:(VLCChannel *)channel atRect:(NSRect)itemRect highlight:(BOOL)highlight {
    // Draw background
    NSRect bgRect = NSInsetRect(itemRect, 1, 1);
    if (highlight) {
        [[NSColor colorWithCalibratedRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.3] set];
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
            
            // Try to load the image if available and not already loading (similar to stacked view)
            if (channel.logo && !objc_getAssociatedObject(channel, "imageLoadingInProgress")) {
                [self loadImageAsynchronously:channel.logo forChannel:channel];
            }
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
        } else if ([currentCategory isEqualToString:@"SETTINGS"]) {
            groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
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
        } else if ([currentCategory isEqualToString:@"SETTINGS"]) {
            groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
        }
        
        // Get the current group
        if (groups && self.selectedGroupIndex >= 0 && self.selectedGroupIndex < groups.count) {
            return [groups objectAtIndex:self.selectedGroupIndex];
        }
    }
    
    return nil;
}

// Helper method to check if the current group contains movie channels
- (BOOL)currentGroupContainsMovieChannels {
    NSArray *channelsInCurrentGroup = [self getChannelsForCurrentGroup];
    if (!channelsInCurrentGroup || channelsInCurrentGroup.count == 0) {
    return NO;
}

    // Check if any channel in the current group is a movie channel
    for (VLCChannel *channel in channelsInCurrentGroup) {
        if ([channel.category isEqualToString:@"MOVIES"]) {
            return YES;
        }
    }
    
        return NO;
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

// Optimized method to validate and refresh movie info for visible items with better performance
- (void)validateMovieInfoForVisibleItems {
    // Cancel any pending validation calls using NSObject's built-in delayed execution
    // This is much safer than managing timers manually and prevents crashes
    [NSObject cancelPreviousPerformRequestsWithTarget:self 
                                             selector:@selector(performValidateMovieInfoForVisibleItems) 
                                               object:nil];
    // Schedule new validation with 0.1 second delay to debounce rapid calls
    [self performSelector:@selector(performValidateMovieInfoForVisibleItems) 
               withObject:nil 
               afterDelay:0.1];
}

// Actual validation method that runs optimized in background
- (void)performValidateMovieInfoForVisibleItems {
    NSArray *channelsInCurrentGroup = [self getChannelsForCurrentGroup];
    if (!channelsInCurrentGroup || channelsInCurrentGroup.count == 0) {
        return;
    }
    
    // Calculate visible range based on current view mode (lightweight operation)
    NSRange visibleRange = [self calculateVisibleChannelRange];
    
    // Validate visible range
    if (visibleRange.location >= channelsInCurrentGroup.count || visibleRange.length == 0) {
        return;
    }
    
    // Create array of visible movie channels for background processing
    NSMutableArray *visibleMovieChannels = [NSMutableArray array];
    NSInteger visibleStart = (NSInteger)visibleRange.location;
    NSInteger visibleEnd = visibleStart + (NSInteger)visibleRange.length - 1;
    
    // Add buffer margin: load 3 items before they become visible for smoother scrolling
    NSInteger bufferSize = 3;
    NSInteger originalStart = visibleStart;
    NSInteger originalEnd = visibleEnd;
    
    // Expand range with buffer (with proper bounds checking)
    visibleStart = MAX(0, visibleStart - bufferSize);
    visibleEnd = MIN((NSInteger)channelsInCurrentGroup.count - 1, visibleEnd + bufferSize);
    
    //NSLog(@"🎯 Loading buffer: visible %ld-%ld expanded to %ld-%ld (+/-%ld buffer)", 
    //      (long)originalStart, (long)originalEnd, (long)visibleStart, (long)visibleEnd, (long)bufferSize);
    
    for (NSInteger i = visibleStart; i <= visibleEnd && i < channelsInCurrentGroup.count; i++) {
        VLCChannel *channel = [channelsInCurrentGroup objectAtIndex:i];
        if ([channel.category isEqualToString:@"MOVIES"]) {
            [visibleMovieChannels addObject:channel];
        }
    }
    
    if (visibleMovieChannels.count == 0) {
        return;
    }
    
    // Process all validation and cache loading in background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *channelsNeedingFetch = [NSMutableArray array];
        NSMutableArray *channelsLoadedFromCache = [NSMutableArray array];
        
        // Process each visible movie channel in background
        for (VLCChannel *channel in visibleMovieChannels) {
            @autoreleasepool {
                // Skip if already fetching
                if (channel.hasStartedFetchingMovieInfo) {
                    continue;
                }
                
                // Quick check for movie info completeness (in memory)
                BOOL needsRefresh = NO;
                
                if (!channel.hasLoadedMovieInfo) {
                    needsRefresh = YES;
                } else {
                    // Check if the loaded info is actually useful (all in memory - fast)
                    BOOL hasDescription = channel.movieDescription && [channel.movieDescription length] > 0;
                    BOOL hasYear = channel.movieYear && [channel.movieYear length] > 0;
                    BOOL hasGenre = channel.movieGenre && [channel.movieGenre length] > 0;
                    BOOL hasDirector = channel.movieDirector && [channel.movieDirector length] > 0;
                    BOOL hasRating = channel.movieRating && [channel.movieRating length] > 0;
                    BOOL hasDuration = channel.movieDuration && [channel.movieDuration length] > 0;
                    
                    // If we're missing critical info, refresh
                    if (!hasDescription || (!hasYear && !hasGenre && !hasDirector && !hasRating && !hasDuration)) {
                        needsRefresh = YES;
                        // Reset the flag so fetchMovieInfoForChannel won't skip it
                        channel.hasLoadedMovieInfo = NO;
                    }
                }
                
                if (needsRefresh) {
                    // Try to load from cache (disk I/O in background thread)
                    BOOL loadedFromCache = [self loadMovieInfoFromCacheForChannel:channel];
                    
                    if (loadedFromCache) {
                        [channelsLoadedFromCache addObject:channel];
                    } else {
                        [channelsNeedingFetch addObject:channel];
                    }
                }
            }
        }
        
        // Update UI and start fetches on main thread (batch updates for better performance)
        dispatch_async(dispatch_get_main_queue(), ^{
            // Limit to maximum 10 simultaneous downloads to prevent system overload
            NSInteger maxSimultaneousDownloads = 10;
            NSInteger downloadsStarted = 0;
            
            // Batch mark channels as fetching and start downloads (limited)
            for (VLCChannel *channel in channelsNeedingFetch) {
                if (!channel.hasStartedFetchingMovieInfo && downloadsStarted < maxSimultaneousDownloads) {
                    channel.hasStartedFetchingMovieInfo = YES;
                    downloadsStarted++;
                    
                    // Start async fetch in background
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                        [self fetchMovieInfoForChannelAsync:channel];
                    });
                }
            }
            
            // Log results if any work was done
            if (channelsLoadedFromCache.count > 0) {
                //NSLog(@"📋 Loaded %ld movies from cache", (long)channelsLoadedFromCache.count);
                // Use throttled update instead of immediate redraw for better performance
                [self throttledDisplayUpdate];
            }
            
            if (downloadsStarted > 0) {
                //NSLog(@"🔄 Started fetching %ld movies (limited to 10 max)", (long)downloadsStarted);
            }
        });
    });
}


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
    
    //NSLog(@"EPG Right-click detected on channel: %@ (hoveredChannelIndex: %ld)", 
    //      channel.name, (long)self.hoveredChannelIndex);
    
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
   // NSLog(@"Creating EPG context menu for program: %@ on channel: %@", program.title, channel.name);
    
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
        //NSLog(@"Playing catch-up for program: %@ on channel: %@", program.title, rightClickedProgramChannel.name);
        
        // Generate timeshift URL for the program
        NSString *timeshiftUrl = [self generateTimeshiftUrlForProgram:program channel:rightClickedProgramChannel];
        
        if (timeshiftUrl) {
            //NSLog(@"Generated timeshift URL: %@", timeshiftUrl);
            
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
                
                //NSLog(@"Started timeshift playback for program: %@", program.title);
                
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
            //NSLog(@"Failed to generate timeshift URL for program: %@", program.title);
            
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
        //NSLog(@"EPG Context Menu - Playing channel: %@ (URL: %@)", channel.name, channel.url);
        //NSLog(@"EPG Context Menu - rightClickedProgramChannel: %@ (URL: %@)", 
        //      rightClickedProgramChannel ? rightClickedProgramChannel.name : @"nil",
        //      rightClickedProgramChannel ? rightClickedProgramChannel.url : @"nil");
        
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
                //NSLog(@"Updated selectedChannelIndex to: %ld for channel: %@", (long)channelIndex, channelToPlay.name);
            } else {
                //NSLog(@"Warning: Could not find channel index for: %@", channelToPlay.name);
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
