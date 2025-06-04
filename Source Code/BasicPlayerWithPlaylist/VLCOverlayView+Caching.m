#import "VLCOverlayView+Caching.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+Utilities.h"
#import <CommonCrypto/CommonDigest.h> // For MD5 hashing

@implementation VLCOverlayView (Caching)

#pragma mark - Channel caching methods

- (NSString *)md5HashForString:(NSString *)string {
    // Create a hash of the string for filename use
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char result[16]; // MD5 result size is 16 bytes
    CC_MD5(data.bytes, (CC_LONG)data.length, result);
    
    // Convert the MD5 hash to a hex string
    NSMutableString *hash = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) {
        [hash appendFormat:@"%02x", result[i]];
    }
    
    return hash;
}

- (NSString *)channelCacheFilePath:(NSString *)sourcePath {
    // Create a unique cache path based on the source path
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *cacheFileName;
    
    // For URLs (especially with query parameters), create a sanitized filename
    if ([sourcePath hasPrefix:@"http://"] || [sourcePath hasPrefix:@"https://"]) {
        // Create a hash of the URL to use as the filename
        NSString *hash = [self md5HashForString:sourcePath];
        cacheFileName = [NSString stringWithFormat:@"channels_%@.plist", hash];
        
        // Log the URL and its hash for debugging
        NSLog(@"Creating cache path for URL: %@", sourcePath);
        NSLog(@"URL hash: %@", hash);
    } else {
        // For local files, use a sanitized version of the filename
        NSString *lastComponent = [sourcePath lastPathComponent];
        if ([lastComponent length] == 0) {
            cacheFileName = @"default_channels_cache.plist";
        } else {
            // Replace any invalid filename characters
            NSCharacterSet *invalidChars = [NSCharacterSet characterSetWithCharactersInString:@":/\\?%*|\"<>"];
            NSString *sanitized = [[lastComponent componentsSeparatedByCharactersInSet:invalidChars] componentsJoinedByString:@"_"];
            cacheFileName = [NSString stringWithFormat:@"%@_cache.plist", sanitized];
        }
    }
    
    NSString *cachePath = [appSupportDir stringByAppendingPathComponent:cacheFileName];
    
    // Check if the cache file exists and log it
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:cachePath];
    NSLog(@"Cache path: %@, Exists: %@", cachePath, exists ? @"YES" : @"NO");
    
    return cachePath;
}

- (BOOL)saveChannelsToCache:(NSString *)sourcePath {
    NSString *cachePath = [self channelCacheFilePath:sourcePath];
    
    @try {
        // Create a dictionary to store the cache
        NSMutableDictionary *cacheDict = [NSMutableDictionary dictionary];
        
        // Store metadata
        [cacheDict setObject:@"1.1" forKey:@"cacheVersion"];
        [cacheDict setObject:[NSDate date] forKey:@"cacheDate"];
        [cacheDict setObject:sourcePath forKey:@"sourcePath"];
        
        // Get arrays to serialize
        NSArray *channels = self.channels;
        NSArray *groups = self.groups;
        NSDictionary *channelsByGroup = self.channelsByGroup;
        NSDictionary *groupsByCategory = self.groupsByCategory;
        
        // Store total counts for progress reporting
        NSUInteger totalChannels = [channels count];
        
        // Single progress update - start serializing
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoadingStatusText:@"Serializing channel data..."];
            self.epgLoadingProgress = 0.0;
            [self setNeedsDisplay:YES];
        });
        
        // Prepare all the data structures in a single pass
        NSMutableArray *serializedChannels = [NSMutableArray array];
        NSMutableDictionary *serializedChannelsByGroup = [NSMutableDictionary dictionary];
        NSMutableDictionary *channelIndexMap = [NSMutableDictionary dictionary];
        
        // First, pre-initialize the serializedChannelsByGroup with empty arrays for each group
        for (NSString *group in [channelsByGroup allKeys]) {
            [serializedChannelsByGroup setObject:[NSMutableArray array] forKey:group];
        }
        
        // Now process all channels in a single pass
        for (NSUInteger i = 0; i < totalChannels; i++) {
            VLCChannel *channel = [channels objectAtIndex:i];
            
            // Serialize channel for main array
            NSMutableDictionary *serializedChannel = [NSMutableDictionary dictionary];
            [serializedChannel setObject:(channel.name ? channel.name : @"") forKey:@"name"];
            [serializedChannel setObject:(channel.url ? channel.url : @"") forKey:@"url"];
            [serializedChannel setObject:(channel.group ? channel.group : @"") forKey:@"group"];
            if (channel.logo) [serializedChannel setObject:channel.logo forKey:@"logo"];
            if (channel.channelId) [serializedChannel setObject:channel.channelId forKey:@"channelId"];
            if (channel.category) [serializedChannel setObject:channel.category forKey:@"category"];
            
            // Save catch-up properties
            [serializedChannel setObject:@(channel.supportsCatchup) forKey:@"supportsCatchup"];
            if (channel.catchupDays > 0) [serializedChannel setObject:@(channel.catchupDays) forKey:@"catchupDays"];
            if (channel.catchupSource) [serializedChannel setObject:channel.catchupSource forKey:@"catchupSource"];
            if (channel.catchupTemplate) [serializedChannel setObject:channel.catchupTemplate forKey:@"catchupTemplate"];
            
            // Add to serialized channels array
            [serializedChannels addObject:serializedChannel];
            
            // Store the index for this channel
            [channelIndexMap setObject:@(i) forKey:[NSValue valueWithPointer:(__bridge const void *)(channel)]];
            
            // Add channel index to its group's array in serializedChannelsByGroup
            NSString *groupName = channel.group;
            if (groupName) {
                NSMutableArray *groupIndices = [serializedChannelsByGroup objectForKey:groupName];
                if (groupIndices) {
                    [groupIndices addObject:@(i)];
                }
            }
            
            // Update progress periodically
            if (i % 1000 == 0 || i == totalChannels - 1) {
                float progress = (float)i / (float)totalChannels;
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.epgLoadingProgress = progress;
                    [self setLoadingStatusText:[NSString stringWithFormat:@"Serializing channel %lu of %lu...", 
                                              (unsigned long)(i + 1), (unsigned long)totalChannels]];
                    [self setNeedsDisplay:YES];
                });
            }
        }
        
        // Store all the serialized data
        [cacheDict setObject:serializedChannels forKey:@"channels"];
        [cacheDict setObject:groups forKey:@"groups"];
        [cacheDict setObject:serializedChannelsByGroup forKey:@"channelsByGroup"];
        [cacheDict setObject:groupsByCategory forKey:@"groupsByCategory"];
        
        // Update progress - final step
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoadingStatusText:@"Writing cache file..."];
            self.epgLoadingProgress = 0.9;
            [self setNeedsDisplay:YES];
        });
        
        // Write to file
        BOOL success = [cacheDict writeToFile:cachePath atomically:YES];
        
        // Final progress update
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [self setLoadingStatusText:[NSString stringWithFormat:@"Saved %lu channels to cache", 
                                          (unsigned long)totalChannels]];
                NSLog(@"Successfully saved channels cache to %@", cachePath);
            } else {
                [self setLoadingStatusText:@"Failed to write cache file"];
                NSLog(@"Failed to write channels cache to %@", cachePath);
            }
            self.epgLoadingProgress = 1.0;
            [self setNeedsDisplay:YES];
        });
        
        return success;
    } @catch (NSException *exception) {
        NSLog(@"Exception while saving channels cache: %@", exception);
        
        // Update progress on error
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoadingStatusText:[NSString stringWithFormat:@"Error saving cache: %@", [exception reason]]];
            self.epgLoadingProgress = 0.0;
            [self setNeedsDisplay:YES];
        });
        
        return NO;
    }
}

- (BOOL)loadChannelsFromCache:(NSString *)sourcePath {
    NSString *cachePath = [self channelCacheFilePath:sourcePath];
    
    NSLog(@"Attempting to load channels from cache: %@", cachePath);
    
    // Check if the cache file exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cachePath]) {
        NSLog(@"Cache file does not exist: %@", cachePath);
        return NO;
    }
    
    // Load from the cache file
    NSDictionary *cacheDict = [NSDictionary dictionaryWithContentsOfFile:cachePath];
    if (!cacheDict) {
        NSLog(@"Failed to load channels cache from %@", cachePath);
        return NO;
    }
    
    // Check cache version
    NSString *cacheVersion = [cacheDict objectForKey:@"cacheVersion"];
    if (!cacheVersion || (![cacheVersion isEqualToString:@"1.0"] && ![cacheVersion isEqualToString:@"1.1"])) {
        NSLog(@"Unsupported cache version: %@", cacheVersion);
        return NO;
    }
    
    // Check timestamp (1 week max)
    NSDate *cacheDate = [cacheDict objectForKey:@"cacheDate"];
    if (!cacheDate) {
        NSLog(@"Invalid cache date");
        return NO;
    }
    
    NSTimeInterval timeSinceCache = [[NSDate date] timeIntervalSinceDate:cacheDate];
    if (timeSinceCache > 7 * 24 * 60 * 60) { // 7 days
        NSLog(@"Cache too old (%f days), refreshing", timeSinceCache / (24 * 60 * 60));
        return NO;
    }
    
    // Use a local pool for autoreleased objects during loading
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    @try {
        // Get favorites from current model to preserve
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
                        
                        // Save catch-up properties for favorites
                        [channelDict setObject:@(channel.supportsCatchup) forKey:@"supportsCatchup"];
                        if (channel.catchupDays > 0) [channelDict setObject:@(channel.catchupDays) forKey:@"catchupDays"];
                        if (channel.catchupSource) [channelDict setObject:channel.catchupSource forKey:@"catchupSource"];
                        if (channel.catchupTemplate) [channelDict setObject:channel.catchupTemplate forKey:@"catchupTemplate"];
                        
                        [favoriteChannels addObject:channelDict];
                    }
                }
            }
            if (favoriteChannels.count > 0) {
                [savedFavorites setObject:favoriteChannels forKey:@"channels"];
            }
        }
        
        // Save existing Settings groups before initialization
        NSMutableArray *savedSettingsGroups = nil;
        if (self.groupsByCategory && [self.groupsByCategory objectForKey:@"SETTINGS"]) {
            savedSettingsGroups = [[self.groupsByCategory objectForKey:@"SETTINGS"] mutableCopy];
        }
        
        // Initialize required structures but preserve Settings
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
            // Preserve Settings entries
            if (savedSettingsGroups) {
                for (NSString *group in self.channelsByGroup) {
                    if ([savedSettingsGroups containsObject:group]) {
                        [tempDict setObject:[self.channelsByGroup objectForKey:group] forKey:group];
                    }
                }
            }
            self.channelsByGroup = tempDict;
        }
        
        if (!self.groupsByCategory) {
            self.groupsByCategory = [NSMutableDictionary dictionary];
        } else {
            NSMutableDictionary *tempDict = [NSMutableDictionary dictionary];
            if (savedSettingsGroups) {
                [tempDict setObject:savedSettingsGroups forKey:@"SETTINGS"];
                [savedSettingsGroups release]; // Release our copy
            }
            self.groupsByCategory = tempDict;
        }
        
        // Make sure we have the categories array
        if (!self.categories || [self.categories count] == 0) {
            self.categories = @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
        }
        
        // Initialize empty arrays for all categories except SETTINGS (which is preserved)
        for (NSString *category in self.categories) {
            if (![category isEqualToString:@"SETTINGS"] && ![self.groupsByCategory objectForKey:category]) {
                [self.groupsByCategory setObject:[NSMutableArray array] forKey:category];
            }
        }
        
        // Load channels data
        NSArray *serializedChannels = [cacheDict objectForKey:@"channels"];
        NSArray *groupKeys = [cacheDict objectForKey:@"groups"];
        NSDictionary *serializedChannelsByGroup = [cacheDict objectForKey:@"channelsByGroup"];
        NSDictionary *groupsByCategoryDict = [cacheDict objectForKey:@"groupsByCategory"];
        NSArray *categoriesArray = [cacheDict objectForKey:@"categories"];
        
        // Load channels
        for (NSDictionary *channelDict in serializedChannels) {
            VLCChannel *channel = [[VLCChannel alloc] init];
            channel.name = [channelDict objectForKey:@"name"];
            channel.url = [channelDict objectForKey:@"url"];
            channel.group = [channelDict objectForKey:@"group"];
            channel.logo = [channelDict objectForKey:@"logo"];
            channel.channelId = [channelDict objectForKey:@"channelId"];
            channel.programs = [NSMutableArray array];
            
            // Restore catch-up properties
            NSNumber *supportsCatchup = [channelDict objectForKey:@"supportsCatchup"];
            if (supportsCatchup) {
                channel.supportsCatchup = [supportsCatchup boolValue];
            }
            NSNumber *catchupDays = [channelDict objectForKey:@"catchupDays"];
            if (catchupDays) {
                channel.catchupDays = [catchupDays integerValue];
            }
            NSString *catchupSource = [channelDict objectForKey:@"catchupSource"];
            if (catchupSource) {
                channel.catchupSource = catchupSource;
            }
            NSString *catchupTemplate = [channelDict objectForKey:@"catchupTemplate"];
            if (catchupTemplate) {
                channel.catchupTemplate = catchupTemplate;
            }
            
            // Ensure the channel category is set correctly
            NSString *category = [channelDict objectForKey:@"category"];
            if (category) {
                // Use the saved category if available
                channel.category = category;
                //NSLog(@"Using saved category from cache: %@ for channel: %@", category, channel.name);
            } else {
                // No category in cache, determine based on file properties
                NSString *fileExtension = [self fileExtensionFromUrl:channel.url];
                NSArray *movieExtensions = @[@".MP4", @".MKV", @".AVI", @".MOV", @".WEBM", @".FLV", @".MPG", @".MPEG", @".WMV", @".VOB", @".3GP", @".M4V"];
                
                if (fileExtension) {
                    BOOL isMovieFile = NO;
                    for (NSString *ext in movieExtensions) {
                        if ([fileExtension isEqualToString:ext]) {
                            isMovieFile = YES;
                            break;
                        }
                    }
                    
                    if (isMovieFile) {
                        NSString *upperCaseTitle = [channel.name uppercaseString];
                        // Check for episode markers in title
                        BOOL hasEpisodeMarkers = ([upperCaseTitle rangeOfString:@"S0"].location != NSNotFound || 
                                                 [upperCaseTitle rangeOfString:@"S1"].location != NSNotFound ||
                                                 [upperCaseTitle rangeOfString:@"S2"].location != NSNotFound || 
                                                 [upperCaseTitle rangeOfString:@"E0"].location != NSNotFound ||
                                                 [upperCaseTitle rangeOfString:@"E1"].location != NSNotFound ||
                                                 [upperCaseTitle rangeOfString:@"E2"].location != NSNotFound);
                        
                        if (hasEpisodeMarkers) {
                            channel.category = @"SERIES";
                        } else {
                            channel.category = @"MOVIES";
                            //NSLog(@"Set cached channel as MOVIE: %@ (has logo: %@)", channel.name, channel.logo ? @"YES" : @"NO");
                        }
                    } else {
                        channel.category = @"TV";
                    }
                } else {
                    channel.category = @"TV"; // Default to TV if no extension
                }
            }
            
            [self.channels addObject:channel];
            [channel release];
        }
        
        // Load groups
        for (NSString *group in groupKeys) {
            if (![self.groups containsObject:group]) {
                [self.groups addObject:group];
            }
        }
        
        // Load channelsByGroup
        for (NSString *group in serializedChannelsByGroup) {
            NSArray *indices = [serializedChannelsByGroup objectForKey:group];
            NSMutableArray *groupChannels = [NSMutableArray array];
            
            for (NSNumber *index in indices) {
                NSInteger idx = [index integerValue];
                if (idx >= 0 && idx < [self.channels count]) {
                    [groupChannels addObject:[self.channels objectAtIndex:idx]];
                }
            }
            
            [self.channelsByGroup setObject:groupChannels forKey:group];
        }
        
        // Restore categories if provided in cache
        if (categoriesArray && [categoriesArray isKindOfClass:[NSArray class]]) {
            self.categories = categoriesArray;
        }
        
        // Load groupsByCategory
        for (NSString *category in groupsByCategoryDict) {
            NSArray *groups = [groupsByCategoryDict objectForKey:category];
            
            // Make sure we're storing mutable arrays
            NSMutableArray *mutableGroups = [NSMutableArray arrayWithArray:groups];
            [self.groupsByCategory setObject:mutableGroups forKey:category];
        }
        
        // Ensure we have all required categories
        [self ensureFavoritesCategory];
        [self ensureSettingsGroups];
        
        // Restore favorites if we had any
        if (savedFavorites.count > 0) {
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
        
        // Prepare simple channel lists
        [self prepareSimpleChannelLists];
        
        NSLog(@"Successfully loaded %lu channels from cache", (unsigned long)[self.channels count]);
        
        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            self.hoveredChannelIndex = -1;
            self.selectedCategoryIndex = CATEGORY_FAVORITES;
            self.selectedGroupIndex = -1;
            
            [self setNeedsDisplay:YES];
        });
        
        // Success
        [pool drain];
        return YES;
    }
    @catch (NSException *exception) {
        NSLog(@"Exception loading channels from cache: %@", exception);
        [pool drain];
        return NO;
    }
}

- (BOOL)cacheChannelsToFile:(NSString *)sourcePath {
    return [self saveChannelsToCache:sourcePath];
}

#pragma mark - EPG cache methods

- (NSString *)epgCacheFilePath {
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *cacheFileName;
    
    // If we have an EPG URL, use it to create a unique filename
    if (self.epgUrl && [self.epgUrl length] > 0) {
        // Create a hash of the URL to use as the filename
        NSString *hash = [self md5HashForString:self.epgUrl];
        cacheFileName = [NSString stringWithFormat:@"epg_%@.plist", hash];
    } else {
        // Default filename if no URL is available
        cacheFileName = @"epg_default_cache.plist";
    }
    
    NSString *epgCachePath = [appSupportDir stringByAppendingPathComponent:cacheFileName];
    return epgCachePath;
}

- (void)saveEpgDataToCache_implementation {
    if (!self.epgData || [self.epgData count] == 0) {
        NSLog(@"No EPG data to save to cache");
        return;
    }
    
    // Create a thread-safe copy of the EPG data on the main thread with better error handling
    __block NSDictionary *epgDataCopy = nil;
    
    // Always copy on the main thread to ensure thread safety
    if ([NSThread isMainThread]) {
        @try {
            // Use synchronized access to prevent corruption during copy
            @synchronized(self.epgData) {
                if (self.epgData && [self.epgData isKindOfClass:[NSDictionary class]]) {
                    epgDataCopy = [[NSDictionary alloc] initWithDictionary:self.epgData copyItems:YES];
                } else {
                    NSLog(@"ERROR: self.epgData is not a valid NSDictionary: %@", [self.epgData class]);
                    return;
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"ERROR: Exception while copying EPG data: %@", exception);
            return;
        }
    } else {
        // If we're on a background thread, dispatch to main thread to copy safely
        dispatch_sync(dispatch_get_main_queue(), ^{
            @try {
                @synchronized(self.epgData) {
                    if (self.epgData && [self.epgData isKindOfClass:[NSDictionary class]]) {
                        epgDataCopy = [[NSDictionary alloc] initWithDictionary:self.epgData copyItems:YES];
                    } else {
                        NSLog(@"ERROR: self.epgData is not a valid NSDictionary: %@", [self.epgData class]);
                    }
                }
            } @catch (NSException *exception) {
                NSLog(@"ERROR: Exception while copying EPG data: %@", exception);
            }
        });
    }
    
    // Validate the copy before proceeding
    if (!epgDataCopy || ![epgDataCopy isKindOfClass:[NSDictionary class]]) {
        NSLog(@"ERROR: Failed to create valid EPG data copy");
        return;
    }
    
    // Update UI to show we're saving
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = YES;
        [self setLoadingStatusText:@"Saving EPG data to cache..."];
        
        // Update progress display
        if (gProgressMessageLock) {
            [gProgressMessageLock lock];
            if (gProgressMessage) {
                [gProgressMessage release];
            }
            gProgressMessage = [[NSString stringWithFormat:@"epg: saving cache..."] retain];
            [gProgressMessageLock unlock];
        }
        
        [self startProgressRedrawTimer];
        [self setNeedsDisplay:YES];
    });
    
    // Run the actual save operation in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Create dictionary to save
        NSMutableDictionary *cacheDict = [NSMutableDictionary dictionary];
        
        // Add metadata
        [cacheDict setObject:@"1.0" forKey:@"epgCacheVersion"];
        [cacheDict setObject:[NSDate date] forKey:@"epgCacheDate"];
        
        // Count total programs for progress tracking using our safe copy
        NSInteger totalPrograms = 0;
        for (NSString *channelId in [epgDataCopy allKeys]) {
            id channelPrograms = [epgDataCopy objectForKey:channelId];
            // SAFETY CHECK: Ensure the object is actually an NSArray before calling count
            if ([channelPrograms isKindOfClass:[NSArray class]]) {
                totalPrograms += [(NSArray *)channelPrograms count];
            } else {
                NSLog(@"WARNING: Invalid object type for channel %@: %@", channelId, [channelPrograms class]);
            }
        }
        
        NSLog(@"Preparing EPG cache data with %ld programs across %lu channels", 
              (long)totalPrograms, (unsigned long)[epgDataCopy count]);
        
        // Process EPG data (convert VLCProgram objects to dictionaries) using our safe copy
        NSMutableDictionary *epgDataDict = [NSMutableDictionary dictionary];
        NSInteger processedPrograms = 0;
        NSTimeInterval lastUpdateTime = [NSDate timeIntervalSinceReferenceDate];
        
        for (NSString *channelId in [epgDataCopy allKeys]) {
            id programsObject = [epgDataCopy objectForKey:channelId];
            
            // SAFETY CHECK: Ensure the object is actually an NSArray before processing
            if (![programsObject isKindOfClass:[NSArray class]]) {
                NSLog(@"WARNING: Skipping invalid programs object for channel %@: %@", channelId, [programsObject class]);
                continue;
            }
            
            NSArray *programs = (NSArray *)programsObject;
            NSMutableArray *programDicts = [NSMutableArray array];
            
            for (id programObject in programs) {
                // SAFETY CHECK: Ensure each program is actually a VLCProgram before processing
                if (![programObject isKindOfClass:[VLCProgram class]]) {
                    NSLog(@"WARNING: Skipping invalid program object in channel %@: %@", channelId, [programObject class]);
                    continue;
                }
                
                VLCProgram *program = (VLCProgram *)programObject;
                NSMutableDictionary *programDict = [NSMutableDictionary dictionary];
                
                if (program.title) [programDict setObject:program.title forKey:@"title"];
                if (program.programDescription) [programDict setObject:program.programDescription forKey:@"description"];
                if (program.startTime) [programDict setObject:program.startTime forKey:@"startTime"];
                if (program.endTime) [programDict setObject:program.endTime forKey:@"endTime"];
                if (program.channelId) [programDict setObject:program.channelId forKey:@"channelId"];
                
                // Save catch-up/timeshift attributes
                if (program.hasArchive) {
                    [programDict setObject:@"1" forKey:@"catchup"];
                }
                if (program.archiveDays > 0) {
                    [programDict setObject:[NSString stringWithFormat:@"%ld", (long)program.archiveDays] forKey:@"catchup-days"];
                }
                
                [programDicts addObject:programDict];
                
                // Update progress periodically
                processedPrograms++;
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                if (now - lastUpdateTime > 0.25 || processedPrograms == totalPrograms) { // Update 4 times per second
                    lastUpdateTime = now;
                    float progressPercentage = (float)processedPrograms / (float)totalPrograms;
                    
                    // Update UI on main thread
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.epgLoadingProgress = progressPercentage;
                        [self setLoadingStatusText:[NSString stringWithFormat:@"Saving EPG cache: %ld of %ld programs (%.1f%%)",
                                                  (long)processedPrograms, (long)totalPrograms, progressPercentage * 100.0]];
                        
                        // Update progress display
                        if (gProgressMessageLock) {
                            [gProgressMessageLock lock];
                            if (gProgressMessage) {
                                [gProgressMessage release];
                            }
                            gProgressMessage = [[NSString stringWithFormat:@"epg: saving %ld/%ld progs (%.1f%%)",
                                               (long)processedPrograms, (long)totalPrograms, 
                                               progressPercentage * 100.0] retain];
                            [gProgressMessageLock unlock];
                        }
                        
                        [self setNeedsDisplay:YES];
                    });
                }
            }
            
            [epgDataDict setObject:programDicts forKey:channelId];
        }
        
        [cacheDict setObject:epgDataDict forKey:@"epgData"];
        
        // Get path for saving
        NSString *cachePath = [self epgCacheFilePath];
        
        // Make sure directory exists
        NSString *cacheDir = [cachePath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:nil];
        
        // Final UI update before writing
        dispatch_async(dispatch_get_main_queue(), ^{
            self.epgLoadingProgress = 0.95; // 95% progress (saving takes a bit more time)
            [self setLoadingStatusText:@"Writing EPG cache to disk..."];
            
            // Update progress display
            if (gProgressMessageLock) {
                [gProgressMessageLock lock];
                if (gProgressMessage) {
                    [gProgressMessage release];
                }
                gProgressMessage = [[NSString stringWithFormat:@"epg: writing to disk..."] retain];
                [gProgressMessageLock unlock];
            }
            
            [self setNeedsDisplay:YES];
        });
        
        // Write to file
        BOOL success = [cacheDict writeToFile:cachePath atomically:YES];
        
        if (success) {
            NSLog(@"Successfully saved EPG cache to %@", cachePath);
        } else {
            NSLog(@"Failed to save EPG cache to %@", cachePath);
        }
        
        // Update UI on completion
        dispatch_async(dispatch_get_main_queue(), ^{
            self.epgLoadingProgress = 1.0; // 100% done
            
            if (success) {
                [self setLoadingStatusText:[NSString stringWithFormat:@"EPG cache saved: %ld programs for %lu channels",
                                          (long)totalPrograms, (unsigned long)[epgDataCopy count]]];
            } else {
                [self setLoadingStatusText:@"Error saving EPG cache to disk"];
            }
            
            // Update progress display
            if (gProgressMessageLock) {
                [gProgressMessageLock lock];
                if (gProgressMessage) {
                    [gProgressMessage release];
                }
                if (success) {
                    gProgressMessage = [[NSString stringWithFormat:@"epg: cache saved successfully"] retain];
                } else {
                    gProgressMessage = [[NSString stringWithFormat:@"epg: cache save failed!"] retain];
                }
                [gProgressMessageLock unlock];
            }
            
            [self setNeedsDisplay:YES];
            
            // Clear display after a delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.isLoading = NO;
                [self stopProgressRedrawTimer];
                
                // Clear progress message
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    [gProgressMessage release];
                    gProgressMessage = nil;
                    [gProgressMessageLock unlock];
                }
                
                [self setNeedsDisplay:YES];
            });
        });
        
        // Clean up the copy
        [epgDataCopy release];
    });
}

// Helper method to extract file extension from a URL path
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

@end 