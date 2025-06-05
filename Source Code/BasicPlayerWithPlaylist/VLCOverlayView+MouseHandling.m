#import "VLCOverlayView+MouseHandling.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+PlayerControls.h"
#import "VLCSubtitleSettings.h"
#import <objc/runtime.h>
#import "VLCOverlayView+Utilities.h"
#import <math.h>
#import "VLCSliderControl.h"
#import "VLCOverlayView+Globals.h"
#import "VLCOverlayView+ContextMenu.h"

// File-level static variable for scroll state tracking
static BOOL isScrolling = NO;

@implementation VLCOverlayView (MouseHandling)
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
            //NSLog(@"Click outside controls - keeping controls visible");
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
        self.selectedChannelIndex = -1; // Reset channel selection
        
        // FIXED: Clear previous channel lists and prepare new ones for the selected category
        [self prepareSimpleChannelLists];
        
        // FIXED: Reset all scroll positions when switching categories
        channelScrollPosition = 0;
        groupScrollPosition = 0;
        self.searchChannelScrollPosition = 0;
        self.searchMovieScrollPosition = 0;
        self.movieInfoScrollPosition = 0;
        self.epgScrollPosition = 0;
        
        // Reset grid loading queue to force reloading for the new category
        if (isGridViewActive) {
            if (gridLoadingQueue) {
                [gridLoadingQueue removeAllObjects];
            }
        }
        
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
        
        // NEW: When a movie group is selected, immediately scan and load cached info/covers
        if ([categoryName isEqualToString:@"MOVIES"] || 
            ([categoryName isEqualToString:@"FAVORITES"] && [self currentGroupContainsMovieChannels])) {
            [self immediatelyLoadCachedMovieDataForCurrentGroup];
        }
        
        // REMOVED: Don't bulk download entire group - only process visible movies on demand
        // [self checkAndRefreshMovieDataForCurrentGroup];
        
        // Reset scroll positions
        channelScrollPosition = 0;
        
        // Reset grid loading queue to force reloading images for the new group
        if (isGridViewActive) {
            if (gridLoadingQueue) {
                [gridLoadingQueue removeAllObjects];
            }
        }
        
        // Log that a group was selected for debugging
        //NSLog(@"Group selected: %@, with %lu channels", 
              //[groups objectAtIndex:index],
              //(unsigned long)[[self.channelsByGroup objectForKey:[groups objectAtIndex:index]] count]);
        
        [self setNeedsDisplay:YES];
    }
}

- (BOOL)handleClickAtPoint:(NSPoint)point {
    // Define exact boundaries for the channel list area
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    
    // Calculate channelListWidth dynamically based on content type
    CGFloat programGuideWidth = 400; // Match the width used in drawProgramGuideForHoveredChannel immediately
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
    
    // Calculate the exact start and end points of channel list
    CGFloat channelListStartX = catWidth + groupWidth;
    CGFloat channelListEndX = channelListStartX + channelListWidth;
    
    // Log click coordinates for debugging
    //NSLog(@"Click at point: (%.1f, %.1f) - Channel list bounds: X from %.1f to %.1f", 
          //point.x, point.y, channelListStartX, channelListEndX);
    
    // Check if we're in the settings panel FIRST (before movie info panel check)
    // because settings uses the same area as movie info panel
    if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
        NSLog(@"Click in settings panel - handling with settings handler");
        return [self handleSettingsClickAtPoint:point];
    }
    
    // Handle search results clicks when in search mode
    if (self.selectedCategoryIndex == CATEGORY_SEARCH) {
        return [self handleSearchResultsClickAtPoint:point];
    }
    
    // Don't process clicks in the movie info panel area (only if NOT in settings or search)
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
    //NSLog(@"Channel index at click point: %ld", (long)channelIndex);
    
    if (channelIndex >= 0) {
        //NSLog(@"Valid channel clicked - playing channel %ld", (long)channelIndex);
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
    
    if ([selectedGroup isEqualToString:@"Playlist"]) {
        // Don't handle button clicks if we're already loading
        if (self.isLoading) {
            NSLog(@"Ignoring button click - operation in progress");
            return YES; // Return YES to indicate we handled the click (even though we ignored it)
        }
        
        // Handle Load From URL button click
        if (NSPointInRect(point, self.loadButtonRect)) {
            NSLog(@"Load From URL button clicked");
            [self loadFromUrlButtonClicked];
            return YES;
        }
        
        // Handle Update EPG button click
        if (NSPointInRect(point, self.epgButtonRect)) {
            NSLog(@"Update EPG button clicked");
            [self updateEpgButtonClicked];
            return YES;
        }
        
        // Handle EPG Time Offset dropdown click - REMOVED: Now handled by VLCDropdownManager
        // The EPG Time Offset dropdown is now managed by the dropdown manager to prevent click-through issues
        
        // Handle EPG Time Offset dropdown using VLCDropdownManager
        if (NSPointInRect(point, self.epgTimeOffsetDropdownRect)) {
            VLCDropdown *dropdown = [self.dropdownManager dropdownWithIdentifier:@"EPGTimeOffset"];
            if (dropdown) {
                if (dropdown.isOpen) {
                    [self.dropdownManager hideDropdown:@"EPGTimeOffset"];
                } else {
                    // Update dropdown frame and show it
                    dropdown.frame = self.epgTimeOffsetDropdownRect;
                    [self.dropdownManager showDropdown:@"EPGTimeOffset"];
                }
            } else {
                // Setup dropdown if it doesn't exist
                [self setupEpgTimeOffsetDropdown];
                [self.dropdownManager showDropdown:@"EPGTimeOffset"];
            }
            return YES;
        }
        
        // Handle EPG Time Offset dropdown options (when dropdown is open) - REMOVED: Now handled by VLCDropdownManager
        // The EPG Time Offset dropdown options are now managed by the dropdown manager to prevent click-through issues
        
        // Handle other playlist-related UI elements here as needed
        
    } else if ([selectedGroup isEqualToString:@"Themes"]) {
        // Handle theme dropdown click
        if (NSPointInRect(point, self.themeDropdownRect)) {
            VLCDropdown *dropdown = [self.dropdownManager dropdownWithIdentifier:@"theme"];
            if (dropdown) {
                if (dropdown.isOpen) {
                    [self.dropdownManager hideDropdown:@"theme"];
                } else {
                    dropdown.frame = self.themeDropdownRect;
                    [self.dropdownManager showDropdown:@"theme"];
                }
            } else {
                [self setupThemeDropdowns];
                [self.dropdownManager showDropdown:@"theme"];
            }
            return YES;
        }
        
        // Handle transparency slider interaction
        if ([VLCSliderControl isPoint:point inSliderRect:self.transparencySliderRect]) {
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
            return YES;
        }
        
        // Handle RGB sliders interactions (only when Custom theme is selected)
        if (self.currentTheme == VLC_THEME_CUSTOM) {
            // Red slider interaction
            if ([VLCSliderControl isPoint:point inSliderRect:self.redSliderRect]) {
                CGFloat value = [VLCSliderControl valueForPoint:point
                                                   sliderRect:self.redSliderRect
                                                    minValue:0.0
                                                    maxValue:1.0];
                
                if (self.customThemeRed != value) {
                    self.customThemeRed = value;
                    [self updateThemeColors];
                    [self saveThemeSettings];
                    [self setNeedsDisplay:YES];
                }
                return YES;
            }
            
            // Green slider interaction
            if ([VLCSliderControl isPoint:point inSliderRect:self.greenSliderRect]) {
                CGFloat value = [VLCSliderControl valueForPoint:point
                                                   sliderRect:self.greenSliderRect
                                                    minValue:0.0
                                                    maxValue:1.0];
                
                if (self.customThemeGreen != value) {
                    self.customThemeGreen = value;
                    [self updateThemeColors];
                    [self saveThemeSettings];
                    [self setNeedsDisplay:YES];
                }
                return YES;
            }
            
            // Blue slider interaction
            if ([VLCSliderControl isPoint:point inSliderRect:self.blueSliderRect]) {
                CGFloat value = [VLCSliderControl valueForPoint:point
                                                   sliderRect:self.blueSliderRect
                                                    minValue:0.0
                                                    maxValue:1.0];
                
                if (self.customThemeBlue != value) {
                    self.customThemeBlue = value;
                    [self updateThemeColors];
                    [self saveThemeSettings];
                    [self setNeedsDisplay:YES];
                }
                return YES;
            }
        }
    }
    
    // Handle Selection Color RGB sliders dragging (always available)
    // Selection Red slider dragging
    NSRect expandedSelectionRedRect = NSMakeRect(self.selectionRedSliderRect.origin.x - 20, 
                                                 self.selectionRedSliderRect.origin.y - 20, 
                                                 self.selectionRedSliderRect.size.width + 40, 
                                                 self.selectionRedSliderRect.size.height + 40);
    
    if (NSPointInRect(point, expandedSelectionRedRect)) {
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
        return YES;
    }
    
    // Selection Green slider dragging
    NSRect expandedSelectionGreenRect = NSMakeRect(self.selectionGreenSliderRect.origin.x - 20, 
                                                   self.selectionGreenSliderRect.origin.y - 20, 
                                                   self.selectionGreenSliderRect.size.width + 40, 
                                                   self.selectionGreenSliderRect.size.height + 40);
    
    if (NSPointInRect(point, expandedSelectionGreenRect)) {
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
        return YES;
    }
    
    // Selection Blue slider dragging
    NSRect expandedSelectionBlueRect = NSMakeRect(self.selectionBlueSliderRect.origin.x - 20, 
                                                  self.selectionBlueSliderRect.origin.y - 20, 
                                                  self.selectionBlueSliderRect.size.width + 40, 
                                                  self.selectionBlueSliderRect.size.height + 40);
    
    if (NSPointInRect(point, expandedSelectionBlueRect)) {
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
        return YES;
    }
    
    return NO;
}

- (BOOL)handleSearchResultsClickAtPoint:(NSPoint)point {
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat programGuideWidth = 350;
    CGFloat channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
    CGFloat channelListStartX = catWidth + groupWidth;
    CGFloat channelListEndX = channelListStartX + channelListWidth;
    
    // Check if click is in channel list area (for channel search results)
    if (point.x >= channelListStartX && point.x < channelListEndX) {
        return [self handleSearchChannelClickAtPoint:point];
    }
    
    // Check if click is in program guide area (for movie search results)
    if (point.x >= channelListEndX) {
        return [self handleSearchMovieClickAtPoint:point];
    }
    
    return NO;
}

- (BOOL)handleSearchChannelClickAtPoint:(NSPoint)point {
    if (!self.searchChannelResults || [self.searchChannelResults count] == 0) {
        return NO;
    }
    
    // Calculate which channel was clicked using the same logic as channel list
    CGFloat rowHeight = 40;
    CGFloat totalY = self.bounds.size.height - point.y + self.searchChannelScrollPosition;
    NSInteger channelIndex = (NSInteger)(totalY / rowHeight);
    
    if (channelIndex >= 0 && channelIndex < [self.searchChannelResults count]) {
        VLCChannel *selectedChannel = [self.searchChannelResults objectAtIndex:channelIndex];
        NSLog(@"Search channel clicked: %@", selectedChannel.name);
        
        // SMART SELECTION: Switch to SEARCH and remember original location
        [self selectSearchAndRememberOriginalLocation:selectedChannel];
        
        // Hide the search interface/controls before playing
        [self hideControls];
        
        // FIXED: Also hide the entire menu interface when playing search result
        self.isChannelListVisible = NO;
        
        
        // Update the current channel reference for player controls
        self.tmpCurrentChannel = selectedChannel;
        
        // Update selected channel index if we can find it in the main channels list
        // This helps with UI consistency
        if (self.channels) {
            for (NSInteger i = 0; i < [self.channels count]; i++) {
                VLCChannel *channel = [self.channels objectAtIndex:i];
                if ([channel.url isEqualToString:selectedChannel.url]) {
                    self.selectedChannelIndex = i;
                    break;
                }
            }
        }
        
        // Play the channel directly using the VLCChannel object
        [self playChannel:selectedChannel];
        
        // Force immediate UI update to reflect the new channel info
        [self setNeedsDisplay:YES];
        
        // Show player controls with channel information
        // This ensures the player controls display the correct channel info
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // After a short delay (to let playback start), refresh the display
            // to ensure channel info is properly shown in player controls
            [self setNeedsDisplay:YES];
        });
        
        return YES;
    }
    
    return NO;
}

- (BOOL)handleSearchMovieClickAtPoint:(NSPoint)point {
    if (!self.searchMovieResults || [self.searchMovieResults count] == 0) {
        return NO;
    }
    
    // Calculate movie index based on the drawing logic from drawSearchMovieResults
    CGFloat rowHeight = 120; // Match the row height from drawSearchMovieResults
    CGFloat contentAreaY = 30; // Account for header height
    CGFloat totalY = (self.bounds.size.height - contentAreaY - point.y) + self.searchMovieScrollPosition;
    NSInteger movieIndex = (NSInteger)(totalY / rowHeight);
    
    if (movieIndex >= 0 && movieIndex < [self.searchMovieResults count]) {
        VLCChannel *selectedMovie = [self.searchMovieResults objectAtIndex:movieIndex];
        NSLog(@"Search movie clicked: %@", selectedMovie.name);
        
        // SMART SELECTION: Switch to SEARCH and remember original location
        [self selectSearchAndRememberOriginalLocation:selectedMovie];
        
        // Hide the search interface/controls before playing
        [self hideControls];
        
        // FIXED: Also hide the entire menu interface when playing search result
        self.isChannelListVisible = NO;
        
        
        // Update the current channel reference for player controls
        self.tmpCurrentChannel = selectedMovie;
        
        // Update selected channel index if we can find it in the main channels list
        // This helps with UI consistency
        if (self.channels) {
            for (NSInteger i = 0; i < [self.channels count]; i++) {
                VLCChannel *channel = [self.channels objectAtIndex:i];
                if ([channel.url isEqualToString:selectedMovie.url]) {
                    self.selectedChannelIndex = i;
                    break;
                }
            }
        }
        
        // Play the movie directly using the VLCChannel object
        [self playChannel:selectedMovie];
        
        // Force immediate UI update to reflect the new movie info
        [self setNeedsDisplay:YES];
        
        // Show player controls with movie information
        // This ensures the player controls display the correct movie info
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // After a short delay (to let playback start), refresh the display
            // to ensure movie info is properly shown in player controls
            [self setNeedsDisplay:YES];
        });
        
        return YES;
    }
    
    return NO;
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
    NSLog(@"loadFromUrlButtonClicked method called");
    
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
                //NSLog(@"Auto-generated EPG URL: %@", self.epgUrl);
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
            //NSLog(@"Force reloading channels and EPG data from settings menu");
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

- (void)updateEpgButtonClicked {
    NSLog(@"updateEpgButtonClicked method called");
    
    // Set loading state and start the progress timer immediately
    self.isLoading = YES;
    [self startProgressRedrawTimer];
    [self setLoadingStatusText:@"Updating EPG data..."];
    [self setNeedsDisplay:YES];
    
    // Check if there's a valid EPG URL
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
    
    // Only proceed if we have a valid EPG URL
    if (epgUrlToLoad && [epgUrlToLoad length] > 0) {
        // Make sure it has http:// prefix
        if (![epgUrlToLoad hasPrefix:@"http://"] && ![epgUrlToLoad hasPrefix:@"https://"]) {
            epgUrlToLoad = [@"http://" stringByAppendingString:epgUrlToLoad];
            self.tempEpgUrl = epgUrlToLoad;
        }
        
        // Basic URL validation - use a less strict pattern to allow query params
        NSString *urlPattern = @"^https?://[-A-Za-z0-9+&@#/%?=~_|!:,.;]*[-A-Za-z0-9+&@#/%=~_|]";
        NSPredicate *urlTest = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", urlPattern];
        BOOL isValid = [urlTest evaluateWithObject:epgUrlToLoad];
        
        if (!isValid) {
            // Show an error message
            [self setLoadingStatusText:@"Error: Invalid EPG URL format"];
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
        
        // Save the EPG URL
        self.epgUrl = epgUrlToLoad;
        [self saveSettings];
        
        // Force reload EPG data
        if ([self respondsToSelector:@selector(forceReloadEpgData)]) {
            [self forceReloadEpgData];
        } else {
            // Fallback to regular load if the force method isn't available
            [self loadEpgData];
        }
        
        // Deactivate text fields but keep the values
        self.epgFieldActive = NO;
    } else {
        // Show error for empty EPG URL
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

- (void)mouseMoved:(NSEvent *)event {
    extern BOOL isPersistingHoverState;
    extern NSInteger lastValidHoveredChannelIndex;
    
    // Get the current mouse position immediately
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    // FIXED: Handle progress bar hover detection FIRST, before any other mouse processing
    // This ensures progress bar hover works everywhere, regardless of channel list, EPG, etc.
    [self handleMouseMovedForPlayerControls];
    
    // Handle dropdown manager mouse events
    if ([self.dropdownManager handleMouseMoved:event]) {
        // Dropdown manager handled the event, redraw and return
        [self setNeedsDisplay:YES];
        return;
    }
    
    
    // Get basic dimensions
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat programGuideWidth = 400; // Updated to match the drawing code
    
    // Calculate channelListWidth dynamically based on content type FIRST
    // This ensures all boundary checks use the same calculation
    BOOL isMovieViewMode = (isGridViewActive || isStackedViewActive) && 
                          ((self.selectedCategoryIndex == CATEGORY_MOVIES) ||
                           (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]));
    
    CGFloat channelListWidth;
    CGFloat movieInfoX;
    
    if (isMovieViewMode) {
        // Movies in grid/stacked view take the full available space
        channelListWidth = self.bounds.size.width - catWidth - groupWidth;
        movieInfoX = self.bounds.size.width; // No movie info panel when in movie view modes
    } else {
        // Regular layout with program guide
        channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
        movieInfoX = catWidth + groupWidth + channelListWidth;
    }
    
    // FIRST PRIORITY: Handle hover state preservation - this must work even during scrolling
    // Set preservation state if mouse is in EPG area
    // Use the calculated channelListWidth to ensure consistency
    CGFloat channelListEndX = catWidth + groupWidth + channelListWidth;
    
    // DEBUG: Log the boundary calculations to verify correctness
    //NSLog(@"🔍 BOUNDARY DEBUG: catWidth=%.1f, groupWidth=%.1f, channelListWidth=%.1f, channelListEndX=%.1f, mouseX=%.1f, isMovieMode=%@", 
    //      catWidth, groupWidth, channelListWidth, channelListEndX, point.x, isMovieViewMode ? @"YES" : @"NO");
    
    if (point.x >= channelListEndX) {
        // Mouse is in EPG area - activate preservation immediately
        if (!isPersistingHoverState) {
            isPersistingHoverState = YES;
            // CRITICAL: Immediately restore the stored valid hover index
            if (lastValidHoveredChannelIndex >= 0) {
                //NSLog(@"PRESERVATION ACTIVATED: Mouse in EPG area, preserving STORED hover index %ld", (long)lastValidHoveredChannelIndex);
                // Force restore the stored valid index immediately
                self.hoveredChannelIndex = lastValidHoveredChannelIndex;
                //NSLog(@"✅ RESTORED: Hover index set back to %ld for EPG display", (long)lastValidHoveredChannelIndex);
            } else {
                //NSLog(@"PRESERVATION ACTIVATED: Mouse in EPG area, but no valid stored hover index");
            }
        }
        //NSLog(@"Early return - in EPG area, skipping all processing");
        return;
    } else {
        // Mouse is back in menu area, turn off preservation
        if (isPersistingHoverState) {
            isPersistingHoverState = NO;
            //NSLog(@"PRESERVATION DEACTIVATED: Mouse back in menu area");
        }
    }
    
    // Check if we're currently scrolling (set in scrollWheel method)
    
    // If scrolling, don't process hover/fetching (but preservation already handled above)
    if (isScrolling) {
        return;
    }
    
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
    
    // FIXED: Always handle player controls mouse movement, regardless of channel list visibility
    // This ensures progress bar hover detection works even when menu is visible
    [self handleMouseMovedForPlayerControls];
    
    // Handle player controls visibility - call the new method from PlayerControls category
    // Only trigger showing player controls if menu is not visible
    if (!self.isChannelListVisible) {
        return; // Skip ALL menu processing when menu is hidden
    }
    
    // Everything below this point is ONLY for when the menu is visible
    
    // Check if we're hovering over the movie info panel or the EPG panel
    BOOL wasHoveringMovieInfo = self.isHoveringMovieInfoPanel;
    BOOL isInMovieInfoArea = (self.selectedChannelIndex >= 0 && point.x >= movieInfoX);
    // EPG panel starts after the channel list
    CGFloat epgPanelStartX = catWidth + groupWidth + channelListWidth;
    BOOL isInEpgPanelArea = self.showEpgPanel && (point.x >= epgPanelStartX);
    

    
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
    // FIXED: Check EPG panel area first, before checking persistence flag
    BOOL shouldPreserveHoverState = self.isHoveringMovieInfoPanel || 
                                   (self.showEpgPanel && isInEpgPanelArea) ||
                                   (self.showEpgPanel && isPersistingHoverState);
    
    if (shouldPreserveHoverState) {
        // When in any detail panel, we're intentionally keeping the hover state
        isPersistingHoverState = YES;
        
        // If we just entered the EPG panel area, restore the last valid hover state
        if (isInEpgPanelArea && lastValidHoveredChannelIndex >= 0) {
            // Restore the preserved hover state
            self.hoveredChannelIndex = lastValidHoveredChannelIndex;
        }
        // If we're entering EPG area with a current hover state, preserve it
        else if (isInEpgPanelArea && self.hoveredChannelIndex >= 0 && lastValidHoveredChannelIndex < 0) {
            lastValidHoveredChannelIndex = self.hoveredChannelIndex;
        }
        
        return;
    }
    
    // We're back in the main UI, so we can reset the persistence flag
    isPersistingHoverState = NO;
    
    // Store previous hover states
    NSInteger prevHoveredCategoryIndex = self.hoveredCategoryIndex;
    NSInteger prevHoveredGroupIndex = self.hoveredGroupIndex;
    NSInteger prevHoveredChannelIndex = self.hoveredChannelIndex;
    
    // PROTECTION: If we're in EPG area and have a preserved hover state, don't allow reset
    if (isInEpgPanelArea && self.showEpgPanel && lastValidHoveredChannelIndex >= 0) {
        self.hoveredChannelIndex = lastValidHoveredChannelIndex;
        isPersistingHoverState = YES;
        return;
    }
    
    // Reset hover states
    self.hoveredCategoryIndex = -1;
    self.hoveredGroupIndex = -1;
    
    // Check if mouse is in categories area (left panel)
    if (point.x >= 0 && point.x < catWidth) {
        // Calculate category index
        CGFloat effectiveY = self.bounds.size.height - point.y;
        NSInteger itemsScrolled = (NSInteger)floor(categoryScrollPosition / 40);
        NSInteger visibleIndex = (NSInteger)floor(effectiveY / 40);
        NSInteger categoryIndex = visibleIndex + itemsScrolled;
        
        if (categoryIndex >= 0 && categoryIndex < [self.categories count]) {
            self.hoveredCategoryIndex = categoryIndex;
        }
    }
    
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
    // channelListEndX already calculated above with correct width
    
    // CRITICAL FIX: If mouse is to the right of the channel list (in EPG area), 
    // completely skip all channel hover processing to prevent hover index corruption
    // BUT preserve the current hover state so EPG continues to show the correct channel
    if (point.x >= channelListEndX) {
        // Preserve current hover state - don't let it get reset
        // The EPG panel should continue showing the guide for the currently hovered channel
        return;
    }
    
    // Check if we're in the channel list area
    BOOL isInChannelListArea = (point.x >= channelListStartX && point.x < channelListEndX);
   // NSLog(@"Mouse is %s channel list area", isInChannelListArea ? "in" : "outside");
    
    // IMPORTANT: Don't process any channel hover changes if we're in EPG area
    // This prevents the hover state from being reset when moving to EPG area
    if (isInEpgPanelArea && self.showEpgPanel) {
        // Store current hover state if we haven't already
        if (self.hoveredChannelIndex >= 0 && lastValidHoveredChannelIndex != self.hoveredChannelIndex) {
            lastValidHoveredChannelIndex = self.hoveredChannelIndex;
            isPersistingHoverState = YES;
        }
        // Ensure we maintain the current hover state
        if (lastValidHoveredChannelIndex >= 0 && self.hoveredChannelIndex != lastValidHoveredChannelIndex) {
            self.hoveredChannelIndex = lastValidHoveredChannelIndex;
        }
        // Don't process any channel hover logic when in EPG area
        return;
    }
    
    // If we're in grid view, handle channel hovering differently
    if (isGridViewActive && isInChannelListArea) {
        // CRITICAL FIX: Only run grid logic if we're actually in a movie category
        // This prevents grid logic from interfering when we're in other categories
        BOOL isInMovieCategory = (self.selectedCategoryIndex == CATEGORY_MOVIES) || 
                                (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]);
        
        if (!isInMovieCategory) {
            NSLog(@"BLOCKED: Grid view active but not in movie category (category: %ld) - skipping grid logic", (long)self.selectedCategoryIndex);
            // Don't run grid logic if we're not in a movie category
            // Fall through to regular list logic instead
        } else {
            // FIXED: Clear persistence state when back in channel list to resume normal hover behavior
            if (isPersistingHoverState) {
                isPersistingHoverState = NO;
                lastValidHoveredChannelIndex = -1;
            }
            
            // CRITICAL FIX: Only call gridItemIndexAtPoint if we're NOT in EPG preservation mode
            // If we're supposed to be preserving hover state for EPG, don't call gridItemIndexAtPoint
            // as it might return 0 and overwrite our preserved hover state
            NSInteger gridIndex = -1;
            if (!isPersistingHoverState) {
                gridIndex = [self gridItemIndexAtPoint:point];
            } else {
                // When preserving state, keep the current hover index
                gridIndex = self.hoveredChannelIndex;
            }
            
            if (gridIndex != self.hoveredChannelIndex) {
                self.hoveredChannelIndex = gridIndex;
                [self setNeedsDisplay:YES];
                
                // If valid grid item is hovered, initiate movie info loading
                if (gridIndex >= 0) {
                    NSArray *channels = [self getChannelsForCurrentGroup];
                    if (channels && gridIndex < channels.count) {
                        VLCChannel *channel = [channels objectAtIndex:gridIndex];
                        // REMOVED: Don't auto-download on hover - handled by validateMovieInfoForVisibleItems
                        // [self queueAsyncLoadForGridChannel:channel atIndex:gridIndex];
                    }
                }
            }
            return; // Early return to prevent fall-through to list logic
        }
    }
    
    // Regular list view logic (or fallback from grid view when not in movie category)  
    if (isInChannelListArea) {
        // In list view, use the regular channel hover logic - only when actually in the channel list area
        // FIXED: Clear persistence state when back in channel list to resume normal hover behavior
        if (isPersistingHoverState) {
            isPersistingHoverState = NO;
            lastValidHoveredChannelIndex = -1;
        }
        
        // CRITICAL FIX: Only call simpleChannelIndexAtPoint if we're NOT in EPG preservation mode
        // If we're supposed to be preserving hover state for EPG, don't call simpleChannelIndexAtPoint
        // as it will return -1 and overwrite our preserved hover state
        NSInteger channelIndex = -1;
        if (!isPersistingHoverState) {
            channelIndex = [self simpleChannelIndexAtPoint:point];
            // Safety check: if the returned index is garbage (too large or negative except -1), ignore it
            if (channelIndex != -1 && (channelIndex < 0 || channelIndex > 100000)) {
                channelIndex = -1;
            }
        } else {
            // When preserving state, keep the current hover index
            channelIndex = self.hoveredChannelIndex;
        }
        
        
    if (channelIndex != self.hoveredChannelIndex) {
        // Cancel any pending movie info timer if the user moved to a different channel
        if (movieInfoHoverTimer) {
            [movieInfoHoverTimer invalidate];
            movieInfoHoverTimer = nil;
            self.isPendingMovieInfoFetch = NO;
        }
        
        // CRITICAL FIX: Store the last valid hover index BEFORE setting the new one
        // This ensures we preserve the last meaningful channel when moving to EPG area
        if (self.hoveredChannelIndex >= 0 && channelIndex == -1) {
            // We're moving from a valid channel to "no channel" - store the valid one
            lastValidHoveredChannelIndex = self.hoveredChannelIndex;
            //NSLog(@"📝 STORING last valid hover index: %ld (moving from valid to -1)", (long)lastValidHoveredChannelIndex);
        } else if (channelIndex >= 0) {
            // We're moving to a valid channel - update the stored value
            lastValidHoveredChannelIndex = channelIndex;
            //NSLog(@"📝 UPDATING last valid hover index: %ld (moving to valid channel)", (long)lastValidHoveredChannelIndex);
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
    if (prevHoveredCategoryIndex != self.hoveredCategoryIndex || 
        prevHoveredGroupIndex != self.hoveredGroupIndex || 
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
    
    // CRITICAL FIX: Only save to cache if we have useful data
    // Check if we have at least a meaningful description OR sufficient metadata
    BOOL hasUsefulDescription = (channel.movieDescription && [channel.movieDescription length] > 10); // At least 10 chars
    BOOL hasUsefulMetadata = ((channel.movieYear && [channel.movieYear length] > 0) || 
                             (channel.movieGenre && [channel.movieGenre length] > 0) || 
                             (channel.movieDirector && [channel.movieDirector length] > 0) || 
                             (channel.movieRating && [channel.movieRating length] > 0));
    
    if (!hasUsefulDescription && !hasUsefulMetadata) {
        NSLog(@"🚫 NOT saving incomplete movie info to cache for '%@' (desc: %ld chars, has metadata: %@)", 
              channel.name, (long)[channel.movieDescription length], hasUsefulMetadata ? @"YES" : @"NO");
        return;
    }
    
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
            //NSLog(@"Error creating movie info cache directory: %@", dirError);
            return;
        } else {
            //NSLog(@"Created movie info cache directory: %@", movieInfoCacheDir);
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
    if (channel.movieDirector) [movieInfo setObject:channel.movieDirector forKey:@"director"];
    if (channel.movieCast) [movieInfo setObject:channel.movieCast forKey:@"cast"];
    if (channel.logo) [movieInfo setObject:channel.logo forKey:@"logo"];
    
    // Only save if we have some data (this check should now always pass due to validation above)
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
                NSLog(@"💾 Saved USEFUL movie info for '%@' to cache - desc: %ld chars, metadata: %@", 
                      channel.name, (long)[channel.movieDescription length], hasUsefulMetadata ? @"YES" : @"NO");
            } else {
                //NSLog(@"Failed to move temp file to cache path: %@, error: %@", cacheFilePath, moveError);
            }
        } else {
            //NSLog(@"Failed to write movie info to temp file: %@", tempPath);
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
        NSLog(@"No cache file found for channel: %@ at path: %@", channel.name, cacheFilePath);
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
                
                // CRITICAL FIX: Validate that cached data is actually useful before loading it
                NSString *cachedDescription = [movieInfo objectForKey:@"description"];
                NSString *cachedYear = [movieInfo objectForKey:@"year"];
                NSString *cachedGenre = [movieInfo objectForKey:@"genre"];
                NSString *cachedDirector = [movieInfo objectForKey:@"director"];
                NSString *cachedRating = [movieInfo objectForKey:@"rating"];
                
                // Check if we have at least a meaningful description OR sufficient metadata
                BOOL hasUsefulDescription = (cachedDescription && [cachedDescription length] > 10); // At least 10 chars
                BOOL hasUsefulMetadata = ((cachedYear && [cachedYear length] > 0) || 
                                         (cachedGenre && [cachedGenre length] > 0) || 
                                         (cachedDirector && [cachedDirector length] > 0) || 
                                         (cachedRating && [cachedRating length] > 0));
                
                if (!hasUsefulDescription && !hasUsefulMetadata) {
                    NSLog(@"❌ Cached data for '%@' is incomplete (desc: %ld chars, has metadata: %@) - removing cache and allowing fresh fetch", 
                          channel.name, (long)[cachedDescription length], hasUsefulMetadata ? @"YES" : @"NO");
                    
                    // Remove the incomplete cache file
                    [fileManager removeItemAtPath:cacheFilePath error:nil];
                    return NO;
                }
                
                // Load data from cache only if it passes validation
                channel.movieId = [movieInfo objectForKey:@"movieId"];
                channel.movieDescription = cachedDescription;
                channel.movieGenre = cachedGenre;
                channel.movieYear = cachedYear;
                channel.movieRating = cachedRating;
                channel.movieDuration = [movieInfo objectForKey:@"duration"];
                channel.movieDirector = [movieInfo objectForKey:@"director"];
                channel.movieCast = [movieInfo objectForKey:@"cast"];
                
                // Mark as loaded
                channel.hasStartedFetchingMovieInfo = YES;
                channel.hasLoadedMovieInfo = YES;
                
                // Also try to load cached poster image from disk
                [self loadCachedPosterImageForChannel:channel];
                
                NSLog(@"✅ Successfully loaded USEFUL movie info from cache for '%@': %ld chars description, metadata: %@", 
                      channel.name, (long)[channel.movieDescription length], hasUsefulMetadata ? @"YES" : @"NO");
                return YES;
            } else {
                NSLog(@"Cache file too old for channel: %@ (%.1f days old)", channel.name, cacheAge / (24 * 60 * 60));
                // Remove old cache file
                [fileManager removeItemAtPath:cacheFilePath error:nil];
            }
        } else {
            NSLog(@"No timestamp in cache file for channel: %@", channel.name);
        }
    } else {
        NSLog(@"Failed to load plist data from cache file for channel: %@", channel.name);
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
            //NSLog(@"Error creating cache directory: %@", [error localizedDescription]);
        } else {
            //NSLog(@"Created cache directory: %@", cacheDir);
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
            //NSLog(@"Error creating posters cache directory: %@", [error localizedDescription]);
        } else {
            //NSLog(@"Created posters cache directory: %@", postersDir);
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
                //NSLog(@"Error creating movie poster cache directory: %@", dirError);
                return;
            }
        }
        
        // Convert NSImage to data using TIFF representation
        NSData *imageData = [image TIFFRepresentation];
        if (!imageData) {
            //NSLog(@"Failed to get TIFF representation for image");
            return;
        }
        
        NSBitmapImageRep *imageRep = [NSBitmapImageRep imageRepWithData:imageData];
        if (!imageRep) {
            //NSLog(@"Failed to create bitmap rep from image data");
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
                    //NSLog(@"Successfully saved image to disk cache: %@", cachePath);
                } else {
                    //NSLog(@"Failed to move temp file to cache path: %@, error: %@", cacheFilePath, moveError);
                }
            } else {
                //NSLog(@"Failed to write image to temp path: %@", tempPath);
            }
        } else {
            //NSLog(@"Failed to create PNG data from image representation");
        }
    } else {
        //NSLog(@"Invalid cache path for URL: %@", url);
    }
}

// Load poster image from disk cache - Improved lazy loading version with memory management
- (void)loadCachedPosterImageForChannel:(VLCChannel *)channel {
    if (!channel || !channel.logo || channel.logo.length == 0) return;
    
    // Don't load if already in memory - this prevents unnecessary disk I/O
    if (channel.cachedPosterImage) {
        return;
    }
    
    NSString *cachePath = [self cachePathForImageURL:channel.logo];
    if (cachePath) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:cachePath]) {
            // Check file age to ensure cache is still valid (e.g., not older than 30 days)
            NSError *error;
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:cachePath error:&error];
            if (attributes && !error) {
                NSDate *modificationDate = [attributes fileModificationDate];
                NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:modificationDate];
                
                // Cache expires after 30 days (2592000 seconds)
                if (age > 2592000) {
                    NSLog(@"Cache file expired for %@, removing", channel.name);
                    [fileManager removeItemAtPath:cachePath error:nil];
                    return;
                }
            }
            
            // Load the cached image data
            NSData *imageData = [NSData dataWithContentsOfFile:cachePath];
            if (imageData && imageData.length > 0) {
                NSImage *cachedImage = [[NSImage alloc] initWithData:imageData];
                if (cachedImage) {
                    channel.cachedPosterImage = cachedImage;
                    //NSLog(@"Loaded poster image from disk cache for channel: %@ (%.1f KB)", 
                    //      channel.name, (float)imageData.length / 1024.0);
                    [cachedImage release];
                } else {
                    //NSLog(@"Failed to create image from cached data for %@, removing corrupt cache", channel.name);
                    [fileManager removeItemAtPath:cachePath error:nil];
                }
            } else {
                //NSLog(@"Empty or corrupt cache file for %@, removing", channel.name);
                [fileManager removeItemAtPath:cachePath error:nil];
            }
        }
    }
}

// Improve fetchMovieInfoForChannelAsync to properly mark hasLoadedMovieInfo and save to cache
- (void)fetchMovieInfoForChannelAsync:(VLCChannel *)channel {
    if (!channel) return;
    
    NSLog(@"Starting async movie info fetch for: %@", channel.name);
    
    // Fetch movie info synchronously on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Call the actual movie info fetching logic from ChannelManagement category
        [self fetchMovieInfoForChannel:channel];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Always clear the fetching flag when done (success or failure)
            channel.hasStartedFetchingMovieInfo = NO;
            
            // Check if we actually got useful movie info
            BOOL hasUsefulInfo = NO;
            if (channel.movieDescription && [channel.movieDescription length] > 0) {
                hasUsefulInfo = YES;
            } else if (channel.movieYear && [channel.movieYear length] > 0) {
                hasUsefulInfo = YES;
            } else if (channel.movieGenre && [channel.movieGenre length] > 0) {
                hasUsefulInfo = YES;
            } else if (channel.movieDirector && [channel.movieDirector length] > 0) {
                hasUsefulInfo = YES;
            } else if (channel.movieRating && [channel.movieRating length] > 0) {
                hasUsefulInfo = YES;
            }
            
            // Handle the result
            if (hasUsefulInfo) {
                channel.hasLoadedMovieInfo = YES;
                
                // Save the info to cache after successful fetching
                [self saveMovieInfoToCache:channel];
                
                NSLog(@"✅ Successfully fetched movie info for '%@' - Description: %ld chars, Year: %@, Genre: %@", 
                      channel.name, (long)[channel.movieDescription length], channel.movieYear, channel.movieGenre);
            } else {
                // No useful info found - reset flags to allow retry later
                channel.hasLoadedMovieInfo = NO;
                channel.hasStartedFetchingMovieInfo = NO;
                
                NSLog(@"❌ No useful movie info found for '%@' - flags reset for retry", channel.name);
            }
            
            // Trigger UI update to show the new information
            [self setNeedsDisplay:YES];
        });
    });
}

- (void)mouseExited:(NSEvent *)event {
    // Cancel any pending movie info timer
    if (movieInfoHoverTimer) {
        [movieInfoHoverTimer invalidate];
        movieInfoHoverTimer = nil;
        self.isPendingMovieInfoFetch = NO;
    }
    
    // Check if we're moving to the EPG area - if so, don't reset hover index
    NSPoint mouseLocation = [NSEvent mouseLocation];
    NSPoint windowPoint = [[self window] convertPointFromScreen:mouseLocation];
    NSPoint localPoint = [self convertPoint:windowPoint fromView:nil];
    
    // Calculate EPG area boundaries
    CGFloat catWidth = 200;
    CGFloat groupWidth = 250;
    CGFloat programGuideWidth = 350;
    CGFloat channelListWidth = self.bounds.size.width - catWidth - groupWidth - programGuideWidth;
    CGFloat channelListEndX = catWidth + groupWidth + channelListWidth;
    
    // If mouse is moving to EPG area, preserve hover state instead of resetting
    if (localPoint.x >= channelListEndX) {
        NSLog(@"mouseExited: Mouse moving to EPG area, preserving hover state");
        // Store the current hover state for EPG to use
        if (self.hoveredChannelIndex >= 0) {
            lastValidHoveredChannelIndex = self.hoveredChannelIndex;
            isPersistingHoverState = YES;
        }
        // Don't reset hover index - keep it for EPG
        return;
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
    
    // EPG time offset dropdown scrolling is now handled by VLCDropdownManager to prevent conflicts
    
    // If menu is not visible, don't process any menu-related scrolling
    if (!self.isChannelListVisible) {
        return;
    }
    
    // Set a flag to indicate we're scrolling (to disable movie info fetching)
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
    
    // Calculate channelListWidth dynamically based on content type
    CGFloat programGuideWidth = 400; // Width reserved for program guide
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
    
    // Check for EPG panel scrolling - using programGuideWidth value that matches drawProgramGuideForHoveredChannel
    CGFloat guidePanelX = catWidth + groupWidth + channelListWidth;
    CGFloat guideEndX = self.bounds.size.width; // EPG panel extends to the right edge
    
    // Check if mouse is in program guide area
    BOOL isInEpgPanelArea = (point.x >= guidePanelX);
    
    // Handle EPG panel scrolling or search movie results scrolling
    if (isInEpgPanelArea) {
        // Check if we're in search mode with movie results
        if (self.selectedCategoryIndex == CATEGORY_SEARCH && self.searchMovieResults && [self.searchMovieResults count] > 0) {
            // Calculate scroll amount for search movie results
            CGFloat scrollAmount = -[event deltaY] * 12;
            
            // Calculate max scroll for movie search results
            CGFloat rowHeight = 120; // Match the row height from drawSearchMovieResults
            CGFloat totalContentHeight = [self.searchMovieResults count] * rowHeight;
            CGFloat visibleHeight = self.bounds.size.height - 30; // Account for header
            CGFloat maxScroll = MAX(0, totalContentHeight - visibleHeight);
            
            // Update scroll position
            self.searchMovieScrollPosition += scrollAmount;
            self.searchMovieScrollPosition = MAX(0, self.searchMovieScrollPosition);
            self.searchMovieScrollPosition = MIN(maxScroll, self.searchMovieScrollPosition);
            
            // Redraw
            [self setNeedsDisplay:YES];
            
            // Return here to prevent other panels from scrolling
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                isScrolling = NO;
            });
            return;
        }
        // Handle regular EPG panel scrolling
        else if (self.hoveredChannelIndex >= 0 || self.selectedChannelIndex >= 0) {
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
    }
    
    // Check movie info area
    if (point.x >= movieInfoX) {
        // We're in the movie info panel area - only scroll this panel if it's active
        if (self.selectedChannelIndex >= 0) {
            //NSLog(@"Scrolling movie info panel");
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
                    
                    //NSLog(@"SCROLL EVENT: Movie description length: %ld, calculated content height: %.1f, current scroll pos: %.1f", 
                          //(long)descriptionLength, contentHeight, self.movieInfoScrollPosition);
                }
                
                // Calculate max scroll with extra buffer
                CGFloat maxScroll = MAX(0, contentHeight - self.bounds.size.height);
                CGFloat oldScrollPos = self.movieInfoScrollPosition;
                self.movieInfoScrollPosition = MIN(maxScroll, self.movieInfoScrollPosition);
                
                NSLog(@"Movie info scrolling: oldPos=%.1f, newPos=%.1f, delta=%.1f, maxScroll=%.1f", 
                      oldScrollPos, self.movieInfoScrollPosition, 
                      self.movieInfoScrollPosition - oldScrollPos, maxScroll);
                
                // Use throttled update instead of immediate redraw during scrolling
                [self throttledDisplayUpdate];
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
                    
                    // Immediately validate movie info for newly visible items in grid mode
                    // This ensures cover images load as they become visible during scrolling
                    if ((self.selectedCategoryIndex == CATEGORY_MOVIES) || 
                        (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels])) {
                        [self validateMovieInfoForVisibleItems];
                    }
                }
            } else {
                // Scroll channel list - need to calculate max scroll based on current view mode
                if (self.selectedCategoryIndex == CATEGORY_SEARCH) {
                    // Handle search mode scrolling
                    self.searchChannelScrollPosition += scrollAmount;
                    self.searchChannelScrollPosition = MAX(0, self.searchChannelScrollPosition);
                    
                    // Calculate max scroll for search results
                    CGFloat maxScroll = MAX(0, ([self.searchChannelResults count] * 40 + 40) - (self.bounds.size.height));
                    self.searchChannelScrollPosition = MIN(maxScroll, self.searchChannelScrollPosition);
                } else {
                    // Regular channel list scrolling
                    channelScrollPosition += scrollAmount;
                    
                    // Limit scrolling
                    channelScrollPosition = MAX(0, channelScrollPosition);
                    
                    // Calculate max scroll based on current view mode
                    CGFloat maxScroll = 0;
                    NSArray *channelsInCurrentGroup = [self getChannelsForCurrentGroup];
                    
                    if (isStackedViewActive && channelsInCurrentGroup && channelsInCurrentGroup.count > 0) {
                        // For stacked view - use EXACT same calculation as drawStackedView
                        CGFloat stackedRowHeight = 400; // Match drawStackedView row height
                        
                        // Calculate stacked view visible height - exactly as in drawStackedView
                        CGFloat catWidth = 200;
                        CGFloat groupWidth = 250;
                        CGFloat stackedViewX = catWidth + groupWidth;
                        CGFloat stackedViewWidth = self.bounds.size.width - stackedViewX;
                        NSRect stackedRect = NSMakeRect(stackedViewX, 0, stackedViewWidth, self.bounds.size.height);
                        
                        // Account for potential rowHeight adjustment (matches drawStackedView logic)
                        NSInteger minVisibleRows = 4;
                        CGFloat requiredHeight = minVisibleRows * stackedRowHeight;
                        if (stackedRect.size.height < requiredHeight) {
                            // Adjust row height if window is too small (matches drawStackedView)
                            stackedRowHeight = MAX(80, stackedRect.size.height / minVisibleRows);
                        }
                        
                        CGFloat totalContentHeight = channelsInCurrentGroup.count * stackedRowHeight;
                        // Add extra space at bottom to ensure last item is fully visible (matches drawStackedView)
                        totalContentHeight += stackedRowHeight;
                        
                        maxScroll = MAX(0, totalContentHeight - stackedRect.size.height);
                    } else {
                        // For regular list view - use the original calculation
                        maxScroll = MAX(0, ([self.simpleChannelNames count] * 40 + 40) - (self.bounds.size.height));
                    }
                    
                    channelScrollPosition = MIN(maxScroll, channelScrollPosition);
                }
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
                    
                    // Use throttled update instead of immediate redraw during scrolling
                    [self throttledDisplayUpdate];
                }
            }
            // If not in channel list or movie info area, ignore scroll event
        }
    }
    
    // Use throttled update instead of immediate redraw during scrolling
    [self throttledDisplayUpdate];
    
    // Reset scrolling flag after a short delay (to prevent fetching immediately after scroll)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        isScrolling = NO;
        
        // When scrolling stops, check if any new movies became visible and need info/cache checking
        if ((self.selectedCategoryIndex == CATEGORY_MOVIES) || 
            (self.selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels])) {
            [self validateMovieInfoForVisibleItems];
        }
        
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

// Throttled display update to prevent too many redraws during scrolling
- (void)throttledDisplayUpdate {
    // This properly cancels previous requests without accessing potentially corrupted references
    [NSObject cancelPreviousPerformRequestsWithTarget:self 
                                             selector:@selector(performDisplayUpdate) 
                                               object:nil];

    [self performDisplayUpdate];
    return;
    // This schedules a new request safely with higher refresh rate for smoother scrolling
    [self performSelector:@selector(performDisplayUpdate)
               withObject:nil
               afterDelay:0.008]; // ~120fps for smoother scrolling
}

// Actual display update method
- (void)performDisplayUpdate {
    [self setNeedsDisplay:YES];
}

// Handle dropdown hover states
- (void)handleDropdownHover:(NSPoint)point {
    // EPG Time Offset dropdown hover is now handled by VLCDropdownManager
    // No manual hover handling needed
}

// Method to find which dropdown option is at a given point
- (NSInteger)getDropdownOptionIndexAtPoint:(NSPoint)point dropdownRect:(NSRect)dropdownRect optionCount:(NSInteger)optionCount {
    // This method is no longer needed as VLCDropdownManager handles option index calculation
    return -1;
}

// Method to get dropdown options rect
- (NSRect)getDropdownOptionsRect:(NSRect)dropdownRect optionCount:(NSInteger)optionCount {
    // This method is no longer needed as VLCDropdownManager handles rect calculation
    return NSZeroRect;
}

@end 
