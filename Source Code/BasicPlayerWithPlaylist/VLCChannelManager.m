//
//  VLCChannelManager.m
//  BasicPlayerWithPlaylist
//
//  Universal Channel Manager - Platform Independent
//  Handles M3U parsing, channel organization, and timeshift detection
//

#import "VLCChannelManager.h"
#import "VLCCacheManager.h"
#import "VLCChannel.h"
#import "VLCTimeshiftManager.h"
#import "DownloadManager.h"
#import <mach/mach.h>

@interface VLCChannelManager ()

// Internal data state
@property (nonatomic, strong) NSMutableArray<VLCChannel *> *internalChannels;
@property (nonatomic, strong) NSMutableArray<NSString *> *internalGroups;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<VLCChannel *> *> *internalChannelsByGroup;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *internalGroupsByCategory;
@property (nonatomic, strong) NSArray<NSString *> *internalCategories;

// Loading state
@property (nonatomic, assign) BOOL internalIsLoading;
@property (nonatomic, assign) float internalProgress;
@property (nonatomic, strong) NSString *internalCurrentStatus;

// Timeshift integration
@property (nonatomic, strong) VLCTimeshiftManager *timeshiftManager;

// Memory optimization
@property (nonatomic, strong) NSMutableDictionary *stringInternTable;
@property (nonatomic, assign) NSUInteger processedChannelCount;

@end

@implementation VLCChannelManager

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupDefaultConfiguration];
        [self initializeDataStructures];
    }
    return self;
}

- (void)setupDefaultConfiguration {
    self.maxChannelsPerGroup = NSUIntegerMax;
    self.maxTotalChannels = NSUIntegerMax;
    self.enableMemoryOptimization = YES;
    
    self.internalIsLoading = NO;
    self.internalProgress = 0.0;
    self.internalCurrentStatus = @"";
    
    // Create timeshift manager for integration
    self.timeshiftManager = [[VLCTimeshiftManager alloc] init];
}

- (void)initializeDataStructures {
    self.internalChannels = [[NSMutableArray alloc] init];
    self.internalGroups = [[NSMutableArray alloc] init];
    self.internalChannelsByGroup = [[NSMutableDictionary alloc] init];
    self.internalGroupsByCategory = [[NSMutableDictionary alloc] init];
    
    // Initialize categories
    self.internalCategories = @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
    
    // Initialize category structure
    for (NSString *category in self.internalCategories) {
        if (![category isEqualToString:@"SETTINGS"]) {
            [self.internalGroupsByCategory setObject:[[NSMutableArray alloc] init] forKey:category];
        }
    }
    
    // Initialize string intern table for memory optimization
    self.stringInternTable = [[NSMutableDictionary alloc] init];
    
    NSLog(@"📊 [CHANNEL] Initialized data structures");
}

#pragma mark - Public Property Accessors

- (NSArray<VLCChannel *> *)channels {
    return [self.internalChannels copy];
}

- (NSArray<NSString *> *)groups {
    return [self.internalGroups copy];
}

- (NSDictionary<NSString *, NSArray<VLCChannel *> *> *)channelsByGroup {
    NSMutableDictionary *result = [[NSMutableDictionary alloc] init];
    for (NSString *group in self.internalChannelsByGroup) {
        [result setObject:[self.internalChannelsByGroup[group] copy] forKey:group];
    }
    return [result copy];
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)groupsByCategory {
    NSMutableDictionary *result = [[NSMutableDictionary alloc] init];
    for (NSString *category in self.internalGroupsByCategory) {
        [result setObject:[self.internalGroupsByCategory[category] copy] forKey:category];
    }
    return [result copy];
}

- (NSArray<NSString *> *)categories {
    return [self.internalCategories copy];
}

- (BOOL)isLoading { return self.internalIsLoading; }
- (float)progress { return self.internalProgress; }
- (NSString *)currentStatus { return self.internalCurrentStatus ?: @""; }

#pragma mark - Main Operations

- (void)loadChannelsFromURL:(NSString *)m3uURL
                 completion:(VLCChannelLoadCompletion)completion
                   progress:(VLCChannelProgressBlock)progressBlock {
    
    if (self.internalIsLoading) {
        NSLog(@"⚠️ [CHANNEL] Already loading channels, ignoring request");
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"VLCChannelManager" 
                                               code:1001 
                                           userInfo:@{NSLocalizedDescriptionKey: @"Channel loading already in progress"}];
            completion(nil, error);
        }
        return;
    }
    
    NSLog(@"📊 [CHANNEL] Starting channel loading from URL: %@", m3uURL);
    
    self.internalIsLoading = YES;
    self.internalProgress = 0.0;
    self.internalCurrentStatus = @"Downloading M3U file...";
    
    if (progressBlock) {
        progressBlock(0.0, self.internalCurrentStatus);
    }
    
    // Try loading from cache first
    __weak __typeof__(self) weakSelf = self;
    [self loadChannelsFromCacheWithProgress:m3uURL completion:^(NSArray<VLCChannel *> *cachedChannels, NSError *cacheError) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (cachedChannels && !cacheError) {
            NSLog(@"✅ [CHANNEL] Loaded %lu channels from cache", (unsigned long)cachedChannels.count);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.internalIsLoading = NO;
                strongSelf.internalProgress = 1.0;
                if (completion) {
                    completion(cachedChannels, nil);
                }
            });
            return;
        }
        
        // Cache miss or invalid - download from URL
        NSLog(@"📊 [CHANNEL] Cache miss - downloading from URL");
        [strongSelf downloadAndParseM3U:m3uURL completion:completion progress:progressBlock];
    } progress:progressBlock];
}

- (void)downloadAndParseM3U:(NSString *)m3uURL
                 completion:(VLCChannelLoadCompletion)completion
                   progress:(VLCChannelProgressBlock)progressBlock {
    
    self.internalCurrentStatus = @"🌐 Downloading M3U playlist from server...";
    if (progressBlock) {
        progressBlock(0.05, self.internalCurrentStatus);
    }
    
    // Use DownloadManager for async download with progress
    DownloadManager *downloadManager = [[DownloadManager alloc] init];
    
    // Create temporary file path for download
    NSString *tempFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"temp_playlist.m3u"];
    
    [downloadManager startDownloadFromURL:m3uURL
                         progressHandler:^(int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite) {
        // Update progress during download (0.05 to 0.1 = 5% of total progress)
        float downloadProgress = 0.05 + (0.05 * ((float)totalBytesWritten / (float)totalBytesExpectedToWrite));
        NSString *progressStatus = [NSString stringWithFormat:@"🌐 Downloading M3U: %.1f MB / %.1f MB", 
                                  totalBytesWritten / 1024.0 / 1024.0, 
                                  totalBytesExpectedToWrite / 1024.0 / 1024.0];
        
        // Log progress to console so user can see it
        NSLog(@"%@", progressStatus);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (progressBlock) {
                progressBlock(downloadProgress, progressStatus);
            }
        });
    }
                       completionHandler:^(NSString *filePath, NSError *error) {
        if (error || !filePath) {
            NSLog(@"❌ [CHANNEL] Download failed: %@", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.internalIsLoading = NO;
                if (completion) {
                    completion(nil, error);
                }
            });
            [downloadManager release];
            return;
        }
        
        // Read downloaded data
        NSData *m3uData = [NSData dataWithContentsOfFile:filePath];
        if (!m3uData) {
            NSError *readError = [NSError errorWithDomain:@"VLCChannelManager" 
                                                     code:1002 
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read downloaded M3U file"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.internalIsLoading = NO;
                if (completion) {
                    completion(nil, readError);
                }
            });
            [downloadManager release];
            return;
        }
        
        NSLog(@"✅ [CHANNEL] 🌐 Successfully downloaded M3U playlist: %lu bytes", (unsigned long)m3uData.length);
        
        // Parse the downloaded content
        NSString *m3uContent = [[NSString alloc] initWithData:m3uData encoding:NSUTF8StringEncoding];
        if (!m3uContent) {
            NSLog(@"❌ [CHANNEL] Failed to decode M3U content");
            NSError *decodeError = [NSError errorWithDomain:@"VLCChannelManager" 
                                                       code:1003 
                                                   userInfo:@{NSLocalizedDescriptionKey: @"Failed to decode M3U content"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.internalIsLoading = NO;
                if (completion) {
                    completion(nil, decodeError);
                }
            });
            [downloadManager release];
            return;
        }
        
        // Clean up temp file
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        
        // Parse the content (0.1 to 1.0 = remaining 90% for parsing)
        [self parseM3UContent:m3uContent completion:completion progress:progressBlock];
        
        [downloadManager release];
    }
                         destinationPath:tempFilePath];
}

- (NSData *)downloadDataFromURL:(NSString *)urlString error:(NSError **)error {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"VLCChannelManager" 
                                        code:1003 
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}];
        }
        return nil;
    }
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url 
                                             cachePolicy:NSURLRequestReloadIgnoringCacheData 
                                         timeoutInterval:120.0];
    
    // Synchronous download for simplicity (already on background queue)
    NSURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request 
                                        returningResponse:&response 
                                                    error:error];
    
    return data;
}

- (void)parseM3UContent:(NSString *)content
             completion:(VLCChannelLoadCompletion)completion
               progress:(VLCChannelProgressBlock)progressBlock {
    
    if (!content || content.length == 0) {
        NSLog(@"❌ [CHANNEL] Empty M3U content");
        NSError *error = [NSError errorWithDomain:@"VLCChannelManager" 
                                           code:1004 
                                       userInfo:@{NSLocalizedDescriptionKey: @"Empty M3U content"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.internalIsLoading = NO;
            if (completion) {
                completion(nil, error);
            }
        });
        return;
    }
    
    NSLog(@"📊 [CHANNEL] Starting M3U parsing - %lu characters", (unsigned long)content.length);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performM3UParsingWithContent:content completion:completion progress:progressBlock];
    });
}

- (void)performM3UParsingWithContent:(NSString *)content
                          completion:(VLCChannelLoadCompletion)completion
                            progress:(VLCChannelProgressBlock)progressBlock {
    
    NSLog(@"📊 [CHANNEL] 🚀 Starting NON-BLOCKING M3U parsing - %lu characters", (unsigned long)content.length);
    
    // IMMEDIATE Settings delivery for instant UI responsiveness
            dispatch_async(dispatch_get_main_queue(), ^{
        self.internalCurrentStatus = @"🚀 Preparing channel processing...";
                if (progressBlock) {
                    progressBlock(0.1, self.internalCurrentStatus);
                }
        
        // Create minimal Settings structure immediately for UI
        VLCChannel *settingsChannel = [[VLCChannel alloc] init];
        settingsChannel.name = @"Settings";
        settingsChannel.group = @"Settings";
        settingsChannel.category = @"SETTINGS";
        settingsChannel.url = @"settings://menu";
        settingsChannel.channelId = @"settings_menu";
        
        NSArray *immediateChannels = @[settingsChannel];
        NSArray *immediateGroups = @[@"Settings"];
        NSDictionary *immediateChannelsByGroup = @{@"Settings": immediateChannels};
        NSDictionary *immediateGroupsByCategory = @{@"SETTINGS": immediateGroups};
        
        // Update internal data immediately
        [self updateInternalDataWithChannels:immediateChannels 
                                      groups:immediateGroups 
                             channelsByGroup:immediateChannelsByGroup 
                            groupsByCategory:immediateGroupsByCategory];
        
        NSLog(@"🚀 [CHANNEL] IMMEDIATE: Settings channel available for navigation");
        
        // DO NOT call completion immediately - wait for chunked parsing to complete
        
        // Now start async chunk-based parsing for full channel list
        [self startChunkedParsing:content completion:completion progress:progressBlock];
    });
}
            
- (void)startChunkedParsing:(NSString *)content
                 completion:(VLCChannelLoadCompletion)completion
                   progress:(VLCChannelProgressBlock)progressBlock {
    
    NSLog(@"🚀 [CHANNEL] Starting chunked async parsing - %lu characters", (unsigned long)content.length);
    
    // Split content into manageable lines array ONCE
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
        NSLog(@"🚀 [CHANNEL] Split into %lu lines for chunked processing", (unsigned long)lines.count);
        
        // Initialize parsing state
        NSMutableArray<VLCChannel *> *allChannels = [[NSMutableArray alloc] init];
        NSMutableArray<NSString *> *allGroups = [[NSMutableArray alloc] init];
        NSMutableDictionary<NSString *, NSMutableArray<VLCChannel *> *> *allChannelsByGroup = [[NSMutableDictionary alloc] init];
        NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *allGroupsByCategory = [[NSMutableDictionary alloc] init];
        
        // Initialize categories
        for (NSString *category in self.internalCategories) {
            if (![category isEqualToString:@"SETTINGS"]) {
                [allGroupsByCategory setObject:[[NSMutableArray alloc] init] forKey:category];
            }
        }
        
        // Start chunked processing
        [self processLinesChunk:lines
                     startIndex:0
                    allChannels:allChannels
                      allGroups:allGroups
           allChannelsByGroup:allChannelsByGroup
          allGroupsByCategory:allGroupsByCategory
                   completion:completion
                     progress:progressBlock];
    });
}

- (void)processLinesChunk:(NSArray<NSString *> *)lines
               startIndex:(NSUInteger)startIndex
              allChannels:(NSMutableArray<VLCChannel *> *)allChannels
                allGroups:(NSMutableArray<NSString *> *)allGroups
     allChannelsByGroup:(NSMutableDictionary<NSString *, NSMutableArray<VLCChannel *> *> *)allChannelsByGroup
    allGroupsByCategory:(NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *)allGroupsByCategory
               completion:(VLCChannelLoadCompletion)completion
                 progress:(VLCChannelProgressBlock)progressBlock {
    
    const NSUInteger CHUNK_SIZE = 200; // Process only 200 lines at a time
    NSUInteger endIndex = MIN(startIndex + CHUNK_SIZE, lines.count);
    
    // Process this small chunk synchronously
    VLCChannel *currentChannel = nil;
    NSUInteger processedChannels = 0;
    
    for (NSUInteger i = startIndex; i < endIndex; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        if ([line hasPrefix:@"#EXTINF:"]) {
                            // Parse channel info line
            currentChannel = [self parseExtinfLineSimple:line];
                            
        } else if (currentChannel && [line hasPrefix:@"http"]) {
                            // Channel URL line
            currentChannel.url = line;
            
            // Finalize channel
            if (!currentChannel.channelId || currentChannel.channelId.length == 0) {
                currentChannel.channelId = [NSString stringWithFormat:@"ch_%lu", (unsigned long)allChannels.count];
            }
            
            // Use new URL-based category determination
            currentChannel.category = [self determineCategoryForChannel:currentChannel];
            
            // Add to collections
            [allChannels addObject:currentChannel];
            processedChannels++;
            
            if (currentChannel.group && ![allGroups containsObject:currentChannel.group]) {
                [allGroups addObject:currentChannel.group];
            }
            
            // Add to group collection
            NSMutableArray<VLCChannel *> *groupChannels = [allChannelsByGroup objectForKey:currentChannel.group];
            if (!groupChannels) {
                groupChannels = [[NSMutableArray alloc] init];
                [allChannelsByGroup setObject:groupChannels forKey:currentChannel.group];
            }
            [groupChannels addObject:currentChannel];
            
            // Add to category collection
            NSMutableArray<NSString *> *categoryGroups = [allGroupsByCategory objectForKey:currentChannel.category];
            if (categoryGroups && ![categoryGroups containsObject:currentChannel.group]) {
                [categoryGroups addObject:currentChannel.group];
            }
            
            currentChannel = nil;
        }
    }
    
    // Update progress with detailed processing info
    float progress = 0.1 + (0.9 * (float)endIndex / (float)lines.count);
    NSString *status = [NSString stringWithFormat:@"📊 Processing M3U: %lu/%lu lines • %lu channels • %lu groups", 
                       (unsigned long)endIndex, (unsigned long)lines.count, (unsigned long)allChannels.count, (unsigned long)allGroups.count];
    
            dispatch_async(dispatch_get_main_queue(), ^{
        self.internalProgress = progress;
        self.internalCurrentStatus = status;
                if (progressBlock) {
            progressBlock(progress, status);
        }
        
        NSLog(@"%@", status);
        
        // Continue with next chunk or complete
        if (endIndex < lines.count) {
            // Schedule next chunk with delay to prevent blocking
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_MSEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                [self processLinesChunk:lines
                             startIndex:endIndex
                            allChannels:allChannels
                              allGroups:allGroups
                   allChannelsByGroup:allChannelsByGroup
                  allGroupsByCategory:allGroupsByCategory
                           completion:completion
                             progress:progressBlock];
            });
        } else {
            // Parsing complete - Add Settings channel to final result
            NSLog(@"🚀 [CHANNEL] Chunked parsing completed: %lu channels", (unsigned long)allChannels.count);
            
            // Create Settings channel for final result
            VLCChannel *settingsChannel = [[VLCChannel alloc] init];
            settingsChannel.name = @"Settings";
            settingsChannel.group = @"Settings";
            settingsChannel.category = @"SETTINGS";
            settingsChannel.url = @"settings://menu";
            settingsChannel.channelId = @"settings_menu";
            
            // Add Settings to final collections
            [allChannels insertObject:settingsChannel atIndex:0]; // Add at beginning
            if (![allGroups containsObject:@"Settings"]) {
                [allGroups addObject:@"Settings"];
            }
            
            // Add Settings to group collection
            NSMutableArray<VLCChannel *> *settingsGroupChannels = [[NSMutableArray alloc] init];
            [settingsGroupChannels addObject:settingsChannel];
            [allChannelsByGroup setObject:settingsGroupChannels forKey:@"Settings"];
            
            // Add Settings to category collection
            NSMutableArray<NSString *> *settingsCategoryGroups = [allGroupsByCategory objectForKey:@"SETTINGS"];
            if (!settingsCategoryGroups) {
                settingsCategoryGroups = [[NSMutableArray alloc] init];
                [allGroupsByCategory setObject:settingsCategoryGroups forKey:@"SETTINGS"];
            }
            if (![settingsCategoryGroups containsObject:@"Settings"]) {
                [settingsCategoryGroups addObject:@"Settings"];
            }
            
            // Debug: Log category distribution
            NSLog(@"📊 [CATEGORY-DEBUG] Category distribution:");
            for (NSString *category in allGroupsByCategory) {
                NSArray *groupsInCategory = [allGroupsByCategory objectForKey:category];
                NSUInteger channelCount = 0;
                for (NSString *group in groupsInCategory) {
                    NSArray *channelsInGroup = [allChannelsByGroup objectForKey:group];
                    channelCount += channelsInGroup.count;
                }
                NSLog(@"📊 [CATEGORY-DEBUG] %@: %lu groups, %lu channels", category, (unsigned long)groupsInCategory.count, (unsigned long)channelCount);
            }
            
            // Update internal data structures
            [self updateInternalDataWithChannels:allChannels 
                                          groups:allGroups 
                                 channelsByGroup:allChannelsByGroup 
                                groupsByCategory:allGroupsByCategory];
            
            // Save to cache
            if (self.cacheManager) {
                [self.cacheManager saveChannelsToCache:allChannels 
                                              sourceURL:@"" 
                                             completion:nil];
            }
            
            // Complete
                self.internalIsLoading = NO;
                self.internalProgress = 1.0;
            self.internalCurrentStatus = [NSString stringWithFormat:@"✅ Complete: %lu channels", (unsigned long)allChannels.count];
                
                if (completion) {
                completion([allChannels copy], nil);
                }
        }
    });
}

- (VLCChannel *)parseExtinfLineSimple:(NSString *)line {
    VLCChannel *channel = [[VLCChannel alloc] init];
    
    // Extract channel name (after last comma)
    NSRange lastCommaRange = [line rangeOfString:@"," options:NSBackwardsSearch];
    if (lastCommaRange.location != NSNotFound) {
        channel.name = [[line substringFromIndex:lastCommaRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    
    // Extract group name (simplified)
    NSRange groupRange = [line rangeOfString:@"group-title=\""];
    if (groupRange.location != NSNotFound) {
        NSUInteger startPos = groupRange.location + groupRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            channel.group = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
        }
    }
    
    // Extract channel ID (simplified)
    NSRange idRange = [line rangeOfString:@"tvg-id=\""];
    if (idRange.location != NSNotFound) {
        NSUInteger startPos = idRange.location + idRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            channel.channelId = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
        }
    }
    
    // Extract logo URL (simplified) - THIS WAS MISSING!
    NSRange logoRange = [line rangeOfString:@"tvg-logo=\""];
    if (logoRange.location != NSNotFound) {
        NSUInteger startPos = logoRange.location + logoRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            NSString *logoURL = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
            if (logoURL.length > 0) {
                channel.logo = logoURL;
            }
        }
    }
    
    return channel;
}

- (VLCChannel *)parseExtinfLine:(NSString *)line 
                      logoRegex:(NSRegularExpression *)logoRegex
                        idRegex:(NSRegularExpression *)idRegex {
    
    VLCChannel *channel = [[VLCChannel alloc] init];
    
    // Extract channel name (after last comma)
    NSRange lastCommaRange = [line rangeOfString:@"," options:NSBackwardsSearch];
    if (lastCommaRange.location != NSNotFound) {
        NSString *rawName = [line substringFromIndex:lastCommaRange.location + 1];
        channel.name = [self sanitizeChannelName:rawName];
    }
    
    // Extract group name
    NSRange groupRange = [line rangeOfString:@"group-title=\""];
    if (groupRange.location != NSNotFound) {
        NSUInteger startPos = groupRange.location + groupRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            NSString *groupName = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
            channel.group = [self internString:groupName];
        }
    }
    
    // Extract logo URL using regex
    if (logoRegex) {
        NSTextCheckingResult *logoMatch = [logoRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (logoMatch && logoMatch.numberOfRanges > 1) {
            NSString *logoURL = [line substringWithRange:[logoMatch rangeAtIndex:1]];
            if (logoURL.length > 0) {
                channel.logo = [self internString:logoURL];
            }
        }
    }
    
    // Extract channel ID using regex
    if (idRegex) {
        NSTextCheckingResult *idMatch = [idRegex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (idMatch && idMatch.numberOfRanges > 1) {
            NSString *channelId = [line substringWithRange:[idMatch rangeAtIndex:1]];
            if (channelId.length > 0 && channelId.length < 50) {
                channel.channelId = [self internString:channelId];
            }
        }
    }
    
    // Parse timeshift attributes
    if (self.timeshiftManager) {
        [self.timeshiftManager parseCatchupAttributesInLine:line forChannel:channel];
    }
    
    return channel;
}

- (void)finalizeChannel:(VLCChannel *)channel
                withURL:(NSString *)url
           tempChannels:(NSMutableArray<VLCChannel *> *)tempChannels
             tempGroups:(NSMutableArray<NSString *> *)tempGroups
    tempChannelsByGroup:(NSMutableDictionary<NSString *, NSMutableArray<VLCChannel *> *> *)tempChannelsByGroup
   tempGroupsByCategory:(NSMutableDictionary<NSString *, NSArray<NSString *> *> *)tempGroupsByCategory {
    
    // Set channel URL
    channel.url = [self internString:url];
    
    // CRITICAL: Ensure every channel has a valid ID for EPG matching
    if (!channel.channelId || [channel.channelId length] == 0) {
        // Create fallback ID from channel name
        if (channel.name && [channel.name length] > 0) {
            // Normalize channel name to create a consistent ID
            NSString *fallbackId = [channel.name lowercaseString];
            fallbackId = [fallbackId stringByReplacingOccurrencesOfString:@" " withString:@""];
            fallbackId = [fallbackId stringByReplacingOccurrencesOfString:@"-" withString:@""];
            fallbackId = [fallbackId stringByReplacingOccurrencesOfString:@"_" withString:@""];
            fallbackId = [fallbackId stringByReplacingOccurrencesOfString:@"." withString:@""];
            
            // Remove common prefixes/suffixes that might interfere with EPG matching
            fallbackId = [fallbackId stringByReplacingOccurrencesOfString:@"hd" withString:@""];
            fallbackId = [fallbackId stringByReplacingOccurrencesOfString:@"fhd" withString:@""];
            fallbackId = [fallbackId stringByReplacingOccurrencesOfString:@"4k" withString:@""];
            
            // Limit length to reasonable size
            if ([fallbackId length] > 30) {
                fallbackId = [fallbackId substringToIndex:30];
            }
            
            if ([fallbackId length] > 0) {
                channel.channelId = [self internString:fallbackId];
            }
        }
        
        // If still no ID, use index-based ID as last resort
        if (!channel.channelId || [channel.channelId length] == 0) {
            channel.channelId = [self internString:[NSString stringWithFormat:@"ch_%lu", (unsigned long)tempChannels.count]];
        }
    }
    
    // Determine category using URL-based logic
    channel.category = [self internString:[self determineCategoryForChannel:channel]];
    
    // Add to collections
    [tempChannels addObject:channel];
    
    if (channel.group && ![tempGroups containsObject:channel.group]) {
        [tempGroups addObject:channel.group];
    }
    
    // Add to group collection
    NSMutableArray<VLCChannel *> *groupChannels = [tempChannelsByGroup objectForKey:channel.group];
    if (!groupChannels) {
        groupChannels = [[NSMutableArray alloc] init];
        [tempChannelsByGroup setObject:groupChannels forKey:channel.group];
    }
    [groupChannels addObject:channel];
    
    // Add to category collection
    NSMutableArray<NSString *> *categoryGroups = [tempGroupsByCategory objectForKey:channel.category];
    if (categoryGroups && ![categoryGroups containsObject:channel.group]) {
        [categoryGroups addObject:channel.group];
    }
}

#pragma mark - Memory Optimization

- (NSString *)internString:(NSString *)string {
    if (!string || string.length == 0) return string;
    
    NSString *interned = [self.stringInternTable objectForKey:string];
    if (!interned) {
        interned = [string copy];
        [self.stringInternTable setObject:interned forKey:string];
    }
    return interned;
}

- (void)performMemoryOptimization {
    NSLog(@"🧹 [CHANNEL] Performing memory optimization");
    
    // Log memory before cleanup
    [VLCChannelManager logMemoryUsage:@"Before cleanup"];
    
    // Clear string intern table
    [self.stringInternTable removeAllObjects];
    
    // Force garbage collection of autoreleased objects
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    
    // Log memory after cleanup
    [VLCChannelManager logMemoryUsage:@"After cleanup"];
    
    NSLog(@"🧹 [CHANNEL] Memory optimization completed");
}

#pragma mark - Data Organization

- (NSString *)determineCategoryForGroup:(NSString *)groupName {
    if (!groupName) return @"TV";
    
    NSString *lowerGroup = [groupName lowercaseString];
    
    // Series indicators (check first to avoid conflicts with movies)
    //if ([lowerGroup containsString:@"series"] || 
    //    [lowerGroup containsString:@"show"] || 
    //    [lowerGroup containsString:@"episode"]) {
   //     return @"SERIES";
   // }
    
    // NOTE: Movie categorization now requires URL validation
    // This method only handles group-based categorization
    // Movie detection based on URL extensions happens in determineCategoryForChannel:
    
    // Default to TV
    return @"TV";
}

- (NSString *)determineCategoryForChannel:(VLCChannel *)channel {
    if (!channel) return @"TV";
    
    NSString *pattern = @"(?i)[\\s\\-\\.](S\\d+|E\\d+)[\\s\\-\\.]";
    
    NSString *lowerGroup = channel.group ? [channel.group lowercaseString] : @"";
    NSString *lowerURL = channel.url ? [channel.url lowercaseString] : @"";
    NSString *lowerTitle = channel.name ? [channel.name lowercaseString] : @"";
   
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:&error];
    
    if (error) {
        NSLog(@"❌ [SERIES-REGEX] Error creating regex: %@", error.localizedDescription);
        return @"TV";
    }

    // First check for series patterns in title (priority check)
    NSRange range = [regex rangeOfFirstMatchInString:lowerTitle options:0 range:NSMakeRange(0, lowerTitle.length)];
    BOOL isMatch = range.location != NSNotFound;
    if (isMatch) {
        //NSLog(@"📺 [CATEGORY] Channel '%@' → SERIES (series pattern found)", channel.name);
        return @"SERIES";
    }

    // Then check for movie file extensions in URL
    if ([lowerURL containsString:@"."] && [self isMovieURL:lowerURL]) {
        //NSLog(@"🎬 [CATEGORY] Channel '%@' → MOVIES (URL has movie extension)", channel.name);
        return @"MOVIES";
    }
    
    // Default to TV
    //NSLog(@"📺 [CATEGORY] Channel '%@' → TV (default)", channel.name);
    return @"TV";
}

- (BOOL)isMovieURL:(NSString *)urlString {
    if (!urlString || urlString.length == 0) return NO;
    
    // Common movie file extensions
    NSArray *movieExtensions = @[@".mp4", @".mkv", @".avi", @".mov", @".m4v", @".wmv", @".flv", 
                                @".webm", @".ogv", @".3gp", @".m2ts", @".ts", @".vob", @".divx", 
                                @".xvid", @".rmvb", @".asf", @".mpg", @".mpeg", @".m2v", @".mts"];
    
    // Check if URL ends with any movie extension (case insensitive)
    for (NSString *extension in movieExtensions) {
        if ([urlString hasSuffix:extension]) {
            //NSLog(@"✅ [MOVIE-CHECK] URL '%@' ends with movie extension '%@'", urlString, extension);
            return YES;
        }
    }
    
    // Log when URL is not a movie file
    if ([urlString containsString:@"http"]) {
        //NSLog(@"❌ [MOVIE-CHECK] URL '%@' is streaming URL, not a movie file", urlString);
    }
    
    return NO;
}

#pragma mark - Cache Integration

- (void)loadChannelsFromCache:(NSString *)sourceURL
                   completion:(VLCChannelLoadCompletion)completion {
    
    if (!self.cacheManager) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"VLCChannelManager" 
                                               code:1005 
                                           userInfo:@{NSLocalizedDescriptionKey: @"No cache manager available"}]);
        }
        return;
    }
    
    [self.cacheManager loadChannelsFromCache:sourceURL completion:^(id data, BOOL success, NSError *error) {
        if (success && [data isKindOfClass:[NSArray class]]) {
            NSArray<VLCChannel *> *channels = (NSArray<VLCChannel *> *)data;
            
            // Update internal data structures
            [self updateInternalDataFromCachedChannels:channels];
            
            if (completion) {
                completion(channels, nil);
            }
        } else {
            if (completion) {
                completion(nil, error);
            }
        }
    }];
}

- (void)loadChannelsFromCacheWithProgress:(NSString *)sourceURL
                               completion:(VLCChannelLoadCompletion)completion
                                 progress:(VLCChannelProgressBlock)progressBlock {
    
    if (!self.cacheManager) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"VLCChannelManager" 
                                               code:1005 
                                           userInfo:@{NSLocalizedDescriptionKey: @"No cache manager available"}]);
        }
        return;
    }
    
    // Start cache loading with progress updates
    if (progressBlock) {
        progressBlock(0.05, @"📁 Loading channels from cache...");
    }
    
    [self.cacheManager loadChannelsFromCache:sourceURL completion:^(id data, BOOL success, NSError *error) {
        if (success && [data isKindOfClass:[NSArray class]]) {
            NSArray<VLCChannel *> *channels = (NSArray<VLCChannel *> *)data;
            
            // Fast cache loading without artificial delays
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                NSUInteger totalChannels = channels.count;
                
                // Show initial progress
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (progressBlock) {
                        progressBlock(0.1, @"📁 Processing cached channels...");
                    }
                });
                
                // Update internal data structures (this is the actual work)
                [self updateInternalDataFromCachedChannels:channels];
                
                // Show completion
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (progressBlock) {
                        progressBlock(1.0, [NSString stringWithFormat:@"✅ Loaded %lu channels from cache", (unsigned long)totalChannels]);
                    }
                    if (completion) {
                        completion(channels, nil);
                    }
                });
            });
        } else {
            if (completion) {
                completion(nil, error);
            }
        }
    }];
}

#pragma mark - Utility Methods

- (NSString *)sanitizeChannelName:(NSString *)name {
    if (!name) return @"Unknown Channel";
    
    NSString *trimmed = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return @"Unknown Channel";
    
    return trimmed;
}

- (NSString *)extractLogoURL:(NSString *)extinfLine {
    NSRange logoRange = [extinfLine rangeOfString:@"tvg-logo=\""];
    if (logoRange.location != NSNotFound) {
        NSUInteger startPos = logoRange.location + logoRange.length;
        NSRange endQuoteRange = [extinfLine rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, extinfLine.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            return [extinfLine substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
        }
    }
    return nil;
}

- (NSString *)extractChannelID:(NSString *)extinfLine {
    NSRange idRange = [extinfLine rangeOfString:@"tvg-id=\""];
    if (idRange.location != NSNotFound) {
        NSUInteger startPos = idRange.location + idRange.length;
        NSRange endQuoteRange = [extinfLine rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, extinfLine.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            return [extinfLine substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
        }
    }
    return nil;
}

#pragma mark - Internal Data Management

- (void)updateInternalDataWithChannels:(NSArray<VLCChannel *> *)channels
                                groups:(NSArray<NSString *> *)groups
                       channelsByGroup:(NSDictionary<NSString *, NSArray<VLCChannel *> *> *)channelsByGroup
                      groupsByCategory:(NSDictionary<NSString *, NSArray<NSString *> *> *)groupsByCategory {
    
    self.internalChannels = [channels mutableCopy];
    self.internalGroups = [groups mutableCopy];
    self.internalChannelsByGroup = [channelsByGroup mutableCopy];
    self.internalGroupsByCategory = [groupsByCategory mutableCopy];
    
    NSLog(@"📊 [CHANNEL] Updated internal data: %lu channels, %lu groups", 
          (unsigned long)channels.count, (unsigned long)groups.count);
}

- (void)updateInternalDataFromCachedChannels:(NSArray<VLCChannel *> *)channels {
    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];
    NSLog(@"🚀 [CACHE-PERF] Starting BACKGROUND cache processing for %lu channels", (unsigned long)channels.count);
    
    // CRITICAL: Ensure this runs on background thread
    if ([NSThread isMainThread]) {
        NSLog(@"⚠️ [CACHE-PERF] WARNING: Cache processing called on main thread - moving to background");
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            [self updateInternalDataFromCachedChannels:channels];
        });
        return;
    }
    
    // Rebuild data structures from cached channels
    [self clearAllChannels];
    
    NSMutableArray<NSString *> *tempGroups = [[NSMutableArray alloc] init];
    NSMutableDictionary<NSString *, NSMutableArray<VLCChannel *> *> *tempChannelsByGroup = [[NSMutableDictionary alloc] init];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *tempGroupsByCategory = [[NSMutableDictionary alloc] init];
    
    // Initialize temp category structure
    for (NSString *category in self.internalCategories) {
        if (![category isEqualToString:@"SETTINGS"]) {
            [tempGroupsByCategory setObject:[[NSMutableArray alloc] init] forKey:category];
        }
    }
    
    // CRITICAL FIX: Use ordered collections to preserve channel order
    // Use sets for fast lookups but also maintain ordered arrays for final result
    NSMutableSet<NSString *> *groupSet = [[NSMutableSet alloc] init];
    NSMutableArray<NSString *> *orderedGroups = [[NSMutableArray alloc] init]; // Preserve order
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *categoryGroupSets = [[NSMutableDictionary alloc] init];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *orderedCategoryGroups = [[NSMutableDictionary alloc] init]; // Preserve order
    
    // Initialize category sets and ordered arrays
    for (NSString *category in self.internalCategories) {
        if (![category isEqualToString:@"SETTINGS"]) {
            [categoryGroupSets setObject:[[NSMutableSet alloc] init] forKey:category];
            [orderedCategoryGroups setObject:[[NSMutableArray alloc] init] forKey:category];
        }
    }
    
    // Process cached channels with ULTRA-FAST batch processing
    NSUInteger processedCount = 0;
    NSUInteger totalChannels = channels.count;
    NSUInteger batchSize = MIN(10000, totalChannels / 4); // Process in batches of 10k or 1/4 of total
    if (batchSize < 1000) batchSize = 1000; // Minimum batch size
    
    NSLog(@"🚀 [CACHE-PERF] Processing %lu channels in batches of %lu", (unsigned long)totalChannels, (unsigned long)batchSize);
    
    // ULTRA-SAFE: Use simple string matching instead of regex to avoid crashes
    // This is still very fast and avoids all regex-related memory issues
    NSArray *movieExtensions = @[@".mp4", @".mkv", @".avi", @".mov", @".m4v", @".wmv", @".flv", @".webm", @".ts", @".m2ts"];
    
    NSLog(@"🚀 [CACHE-PERF] Using safe string matching for movie detection (%lu extensions)", (unsigned long)movieExtensions.count);
    
    for (NSUInteger i = 0; i < totalChannels; i += batchSize) {
        @autoreleasepool {
            NSUInteger endIndex = MIN(i + batchSize, totalChannels);
            NSArray *batch = [channels subarrayWithRange:NSMakeRange(i, endIndex - i)];
            
            // Process batch with safety checks
            for (VLCChannel *channel in batch) {
                // SAFETY: Skip nil or invalid channels
                if (!channel || ![channel isKindOfClass:[VLCChannel class]]) {
                    NSLog(@"⚠️ [CACHE-SAFETY] Skipping invalid channel object");
                    continue;
                }
                
                // Add group to set (faster than array containsObject) AND preserve order
                if (channel.group && [channel.group length] > 0) {
                    if (![groupSet containsObject:channel.group]) {
                        [groupSet addObject:channel.group];
                        [orderedGroups addObject:channel.group]; // Preserve first-seen order
                    }
                }
                
                // ULTRA-FAST category determination - only for channels that need it
                BOOL needsCategoryCheck = NO;
                if (!channel.category || [channel.category length] == 0) {
                    needsCategoryCheck = YES; // Missing category
                } else if ([channel.category isEqualToString:@"TV"] && channel.url && [channel.url length] > 0) {
                    // ULTRA-SAFE: Use simple string matching (fast and crash-free)
                    NSString *lowercaseURL = [channel.url lowercaseString];
                    for (NSString *extension in movieExtensions) {
                        if ([lowercaseURL containsString:extension]) {
                            needsCategoryCheck = YES;
                            break;
                        }
                    }
                }
                
                if (needsCategoryCheck) {
                    NSString *originalCategory = channel.category;
                    channel.category = [self determineCategoryForChannel:channel];
                    
                    // Minimal logging for performance
                    if (originalCategory && ![originalCategory isEqualToString:channel.category]) {
                        // Only log first few changes to avoid log spam
                        if (processedCount < 10) {
                            NSLog(@"📊 [CATEGORY-CACHE] Channel '%@' category: %@ → %@", 
                                  channel.name, originalCategory, channel.category);
                        }
                    }
                }
                
                // Add to group collection (with safety checks) - preserves original channel order
                if (channel.group && [channel.group length] > 0) {
                    NSMutableArray<VLCChannel *> *groupChannels = [tempChannelsByGroup objectForKey:channel.group];
                    if (!groupChannels) {
                        groupChannels = [[NSMutableArray alloc] init];
                        [tempChannelsByGroup setObject:groupChannels forKey:channel.group];
                        // Debug: Log when new group is created
                        //NSLog(@"📊 [ORDER-DEBUG] Created new group: '%@'", channel.group);
                    }
                    [groupChannels addObject:channel]; // Channels added in original order
                }
                
                // Add to category set (faster than array containsObject) AND preserve order
                if (channel.category && [channel.category length] > 0 && channel.group && [channel.group length] > 0) {
                    NSMutableSet<NSString *> *categoryGroupSet = [categoryGroupSets objectForKey:channel.category];
                    NSMutableArray<NSString *> *orderedCategoryGroupArray = [orderedCategoryGroups objectForKey:channel.category];
                    if (categoryGroupSet && orderedCategoryGroupArray) {
                        if (![categoryGroupSet containsObject:channel.group]) {
                            [categoryGroupSet addObject:channel.group];
                            [orderedCategoryGroupArray addObject:channel.group]; // Preserve first-seen order
                        }
                    }
                }
                
                processedCount++;
            }
            
            // Progress logging per batch
            NSLog(@"🚀 [CACHE-PROGRESS] Processed batch %lu/%lu (%lu channels)", 
                  (unsigned long)(i/batchSize + 1), (unsigned long)((totalChannels + batchSize - 1)/batchSize), (unsigned long)processedCount);
            
            // Yield to other threads periodically
            if (i % (batchSize * 4) == 0) {
                [NSThread sleepForTimeInterval:0.001]; // 1ms yield every 4 batches
            }
        }
    }
    
    // CRITICAL FIX: Use ordered arrays instead of converting from sets (preserves order)
    [tempGroups addObjectsFromArray:orderedGroups];
    for (NSString *category in orderedCategoryGroups) {
        NSMutableArray *orderedCategoryGroupArray = [orderedCategoryGroups objectForKey:category];
        NSMutableArray *categoryGroups = [tempGroupsByCategory objectForKey:category];
        [categoryGroups addObjectsFromArray:orderedCategoryGroupArray];
    }
    
    NSLog(@"📊 [ORDER-FIX] Preserved order: %lu groups, %lu categories", 
          (unsigned long)tempGroups.count, (unsigned long)tempGroupsByCategory.count);
    
    // Debug: Log first few groups to verify order preservation
    NSLog(@"📊 [ORDER-VERIFY] First 5 groups in order: %@", 
          [tempGroups subarrayWithRange:NSMakeRange(0, MIN(5, tempGroups.count))]);
    
    // Update internal data structures on main thread for thread safety
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateInternalDataWithChannels:channels 
                                      groups:tempGroups 
                             channelsByGroup:tempChannelsByGroup 
                            groupsByCategory:tempGroupsByCategory];
        
        NSTimeInterval endTime = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval processingTime = endTime - startTime;
        NSLog(@"🚀 [CACHE-PERF] ✅ Cache processing completed in %.3f seconds (%.1f channels/sec)", 
              processingTime, channels.count / processingTime);
        
        // Post notification that processing is complete
        [[NSNotificationCenter defaultCenter] postNotificationName:@"VLCChannelManagerDataUpdated" object:self];
    });
}

- (void)clearAllChannels {
    // FAST CLEAR: Create new empty collections instead of clearing existing ones
    self.internalChannels = [[NSMutableArray alloc] init];
    self.internalGroups = [[NSMutableArray alloc] init];
    self.internalChannelsByGroup = [[NSMutableDictionary alloc] init];
    self.internalGroupsByCategory = [[NSMutableDictionary alloc] init];
    [self initializeDataStructures];
}

#pragma mark - Memory Usage

- (NSUInteger)estimatedMemoryUsage {
    NSUInteger total = 0;
    
    // Estimate channel memory usage
    total += self.internalChannels.count * sizeof(VLCChannel *);
    
    // Estimate string storage
    total += self.stringInternTable.count * 50; // Average string size
    
    return total;
}

+ (NSUInteger)getCurrentMemoryUsage {
    struct task_basic_info info;
    mach_msg_type_number_t size = sizeof(info);
    kern_return_t kerr = task_info(mach_task_self(),
                                   TASK_BASIC_INFO,
                                   (task_info_t)&info,
                                   &size);
    if (kerr == KERN_SUCCESS) {
        return info.resident_size;
    }
    return 0;
}

+ (NSUInteger)getCurrentMemoryUsageMB {
    struct mach_task_basic_info info;
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &size);
    
    if (kerr == KERN_SUCCESS) {
        return info.resident_size / (1024 * 1024);
    }
    return 0;
}

+ (void)logMemoryUsage:(NSString *)context {
    NSUInteger memoryMB = [VLCChannelManager getCurrentMemoryUsageMB];
    NSLog(@"📊 [CHANNEL] Memory usage %@: %luMB", context, (unsigned long)memoryMB);
}

@end 
