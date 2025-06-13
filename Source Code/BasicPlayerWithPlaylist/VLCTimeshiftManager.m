//
//  VLCTimeshiftManager.m
//  BasicPlayerWithPlaylist
//
//  Universal Timeshift Manager - Platform Independent
//  Handles timeshift/catchup detection, API fetching, and URL generation
//

#import "VLCTimeshiftManager.h"
#import "VLCChannel.h"
#import "VLCProgram.h"

@interface VLCTimeshiftManager ()

// State tracking
@property (nonatomic, assign) NSInteger internalTimeshiftChannelCount;
@property (nonatomic, assign) BOOL internalIsDetecting;
@property (nonatomic, assign) BOOL internalHasAPISupport;

// API operation tracking
@property (nonatomic, strong) NSURLSessionDataTask *currentAPITask;

@end

@implementation VLCTimeshiftManager

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupDefaultConfiguration];
    }
    return self;
}

- (void)setupDefaultConfiguration {
    self.minimumCatchupPercentage = 0.1; // 10%
    self.apiTimeout = 30.0; // 30 seconds
    
    self.internalTimeshiftChannelCount = 0;
    self.internalIsDetecting = NO;
    self.internalHasAPISupport = NO;
    
    //NSLog(@"⏱ [TIMESHIFT] Initialized with defaults");
}

#pragma mark - Public Property Accessors

- (NSInteger)timeshiftChannelCount { return self.internalTimeshiftChannelCount; }
- (BOOL)isDetecting { return self.internalIsDetecting; }
- (BOOL)hasAPISupport { return self.internalHasAPISupport; }

#pragma mark - Main Operations

- (void)detectTimeshiftSupport:(NSArray<VLCChannel *> *)channels
                        m3uURL:(NSString *)m3uURL
                    completion:(VLCTimeshiftDetectionCompletion)completion {
    
    if (self.internalIsDetecting) {
        //NSLog(@"⚠️ [TIMESHIFT] Detection already in progress");
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"VLCTimeshiftManager" 
                                               code:2001 
                                           userInfo:@{NSLocalizedDescriptionKey: @"Detection already in progress"}];
            completion(0, error);
        }
        return;
    }
    
   // NSLog(@"⏱ [TIMESHIFT] Starting timeshift detection for %lu channels", (unsigned long)channels.count);
    
    self.internalIsDetecting = YES;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performTimeshiftDetection:channels m3uURL:m3uURL completion:completion];
    });
}

- (void)performTimeshiftDetection:(NSArray<VLCChannel *> *)channels
                           m3uURL:(NSString *)m3uURL
                       completion:(VLCTimeshiftDetectionCompletion)completion {
    
    NSInteger detectedChannels = 0;
    
    // Count channels with existing timeshift support (from M3U attributes)
    for (VLCChannel *channel in channels) {
        if ([self channelSupportsTimeshift:channel]) {
            detectedChannels++;
        }
    }
    
    //NSLog(@"⏱ [TIMESHIFT] M3U-based detection found %ld channels with timeshift", (long)detectedChannels);
    
    self.internalTimeshiftChannelCount = detectedChannels;
    
    // Calculate percentage of channels with timeshift support
    float timeshiftPercentage = (float)detectedChannels / (float)channels.count;
    
    //NSLog(@"⏱ [TIMESHIFT] %.1f%% of channels have timeshift support", timeshiftPercentage * 100);
    
    // If less than minimum percentage, try API fetch
    if (timeshiftPercentage < self.minimumCatchupPercentage) {
        //NSLog(@"⏱ [TIMESHIFT] Insufficient timeshift channels (%.1f%%) - performing API fetch", timeshiftPercentage * 100);
        self.internalHasAPISupport = YES;
        
        // CRITICAL FIX: Use provided M3U URL for API fetch instead of trying to construct from channel URLs
        if (m3uURL && m3uURL.length > 0) {
            //NSLog(@"⏱ [TIMESHIFT] Attempting API fetch with provided M3U URL: %@", m3uURL);
            [self fetchTimeshiftInfoFromAPI:m3uURL 
                                   channels:channels 
                                 completion:^(NSInteger apiDetectedChannels, NSError *error) {
                if (error) {
                    //NSLog(@"❌ [TIMESHIFT] API fetch failed: %@", error.localizedDescription);
                    // Fall back to M3U-only results
                    self.internalIsDetecting = NO;
                    if (completion) {
                        completion(detectedChannels, nil);
                    }
                } else {
                    //NSLog(@"✅ [TIMESHIFT] API fetch completed: %ld additional channels", (long)apiDetectedChannels);
                    
                    // Recount total timeshift channels after API update
                    NSInteger totalTimeshiftChannels = 0;
                    for (VLCChannel *channel in channels) {
                        if ([self channelSupportsTimeshift:channel]) {
                            totalTimeshiftChannels++;
                        }
                    }
                    
                    self.internalTimeshiftChannelCount = totalTimeshiftChannels;
                    self.internalIsDetecting = NO;
                    
                    if (completion) {
                        completion(totalTimeshiftChannels, nil);
                    }
                }
            }];
            return; // Exit early - completion will be called by API fetch
        } else {
            //NSLog(@"⚠️ [TIMESHIFT] No M3U URL provided for API fetch - using M3U-only results");
        }
    } else {
        //NSLog(@"⏱ [TIMESHIFT] Sufficient timeshift channels found - no API fetch needed");
        self.internalHasAPISupport = NO;
    }
    
    // Complete with M3U-only results
    dispatch_async(dispatch_get_main_queue(), ^{
        self.internalIsDetecting = NO;
        
        if (completion) {
            completion(detectedChannels, nil);
        }
    });
}

- (void)fetchTimeshiftInfoFromAPI:(NSString *)m3uURL
                         channels:(NSArray<VLCChannel *> *)channels
                       completion:(VLCTimeshiftAPICompletion)completion {
    
    if (self.currentAPITask) {
        //NSLog(@"⚠️ [TIMESHIFT] API fetch already in progress");
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"VLCTimeshiftManager" 
                                               code:2002 
                                           userInfo:@{NSLocalizedDescriptionKey: @"API fetch already in progress"}];
            completion(0, error);
        }
        return;
    }
    
    NSString *apiURL = [self constructLiveStreamsAPIURL:m3uURL];
    if (!apiURL) {
        //NSLog(@"❌ [TIMESHIFT] Failed to construct API URL from M3U URL: %@", m3uURL);
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"VLCTimeshiftManager" 
                                               code:2003 
                                           userInfo:@{NSLocalizedDescriptionKey: @"Failed to construct API URL"}];
            completion(0, error);
        }
        return;
    }
    
    //NSLog(@"⏱ [TIMESHIFT] Fetching timeshift info from API: %@", apiURL);
    //NSLog(@"⏱ [TIMESHIFT] Processing %lu channels for timeshift detection", (unsigned long)channels.count);
    
    NSURL *url = [NSURL URLWithString:apiURL];
    NSURLRequest *request = [NSURLRequest requestWithURL:url 
                                             cachePolicy:NSURLRequestUseProtocolCachePolicy 
                                         timeoutInterval:self.apiTimeout];
    
    NSURLSession *session = [NSURLSession sharedSession];
    
    __weak __typeof__(self) weakSelf = self;
    self.currentAPITask = [session dataTaskWithRequest:request 
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        strongSelf.currentAPITask = nil;
        
        if (error || !data) {
            //NSLog(@"❌ [TIMESHIFT] API fetch failed: %@", error ? error.localizedDescription : @"No data received");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(0, error);
                }
            });
            return;
        }
        
        // Check HTTP response status
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            //NSLog(@"⏱ [TIMESHIFT] API response status: %ld", (long)httpResponse.statusCode);
            if (httpResponse.statusCode != 200) {
                NSError *httpError = [NSError errorWithDomain:@"VLCTimeshiftManager" 
                                                         code:httpResponse.statusCode 
                                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]}];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) {
                        completion(0, httpError);
                    }
                });
                return;
            }
        }
        
        //NSLog(@"✅ [TIMESHIFT] Received API data (%lu bytes)", (unsigned long)data.length);
        
        // Parse JSON response
        NSError *jsonError = nil;
        NSArray *apiChannels = [NSJSONSerialization JSONObjectWithData:data 
                                                              options:0 
                                                                error:&jsonError];
        
        if (jsonError || !apiChannels || ![apiChannels isKindOfClass:[NSArray class]]) {
            //NSLog(@"❌ [TIMESHIFT] Failed to parse API JSON: %@", jsonError ? jsonError.localizedDescription : @"Invalid JSON format");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(0, jsonError);
                }
            });
            return;
        }
        
        //NSLog(@"✅ [TIMESHIFT] Parsed %lu channels from API", (unsigned long)apiChannels.count);
        
        // Process API response
        [strongSelf processAPIResponse:apiChannels withChannels:channels completion:completion];
    }];
    
    [self.currentAPITask resume];
}

- (void)processAPIResponse:(NSArray *)apiChannels
              withChannels:(NSArray<VLCChannel *> *)channels
                completion:(VLCTimeshiftAPICompletion)completion {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        //NSLog(@"⏱ [TIMESHIFT] Processing API response for %lu channels", (unsigned long)apiChannels.count);
        
        // Create stream_id to timeshift info mapping
        NSMutableDictionary *timeshiftLookup = [[NSMutableDictionary alloc] init];
        
        for (NSDictionary *apiChannel in apiChannels) {
            if (![apiChannel isKindOfClass:[NSDictionary class]]) continue;
            
            NSNumber *streamId = [apiChannel objectForKey:@"stream_id"];
            NSNumber *tvArchive = [apiChannel objectForKey:@"tv_archive"];
            NSString *tvArchiveDuration = [apiChannel objectForKey:@"tv_archive_duration"];
            NSString *channelName = [apiChannel objectForKey:@"name"];
            
            if (streamId) {
                NSDictionary *timeshiftInfo = @{
                    @"tv_archive": tvArchive ?: @(0),
                    @"tv_archive_duration": tvArchiveDuration ?: @"0",
                    @"name": channelName ?: @""
                };
                [timeshiftLookup setObject:timeshiftInfo forKey:[streamId stringValue]];
            }
        }
        
        //NSLog(@"⏱ [TIMESHIFT] Created lookup table with %lu entries", (unsigned long)timeshiftLookup.count);
        
        // Update channels with timeshift information
        NSInteger updatedChannels = 0;
        
        for (VLCChannel *channel in channels) {
            NSString *streamId = [self extractStreamIDFromChannelURL:channel.url];
            if (!streamId) continue;
            
            NSDictionary *timeshiftInfo = [timeshiftLookup objectForKey:streamId];
            if (timeshiftInfo) {
                NSNumber *tvArchive = [timeshiftInfo objectForKey:@"tv_archive"];
                NSString *tvArchiveDuration = [timeshiftInfo objectForKey:@"tv_archive_duration"];
                
                // Update channel timeshift properties
                BOOL supportsTimeshift = [tvArchive boolValue];
                NSInteger archiveDays = [tvArchiveDuration integerValue];
                
                if (supportsTimeshift && archiveDays > 0) {
                    channel.supportsCatchup = YES;
                    channel.catchupDays = archiveDays;
                    channel.catchupSource = @"default";
                    channel.catchupTemplate = @""; // Will be generated dynamically
                    
                    updatedChannels++;
                    //NSLog(@"✅ [TIMESHIFT] Updated channel '%@': %ld days", channel.name, (long)archiveDays);
                }
            }
        }
        
        // Update internal count
        NSInteger totalTimeshiftChannels = 0;
        for (VLCChannel *channel in channels) {
            if ([self channelSupportsTimeshift:channel]) {
                totalTimeshiftChannels++;
            }
        }
        
        self.internalTimeshiftChannelCount = totalTimeshiftChannels;
        
        //NSLog(@"⏱ [TIMESHIFT] API processing completed: %ld channels updated, %ld total timeshift channels", 
        //      (long)updatedChannels, (long)totalTimeshiftChannels);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(updatedChannels, nil);
            }
        });
    });
}

#pragma mark - M3U Attribute Parsing

- (void)parseCatchupAttributesInLine:(NSString *)line forChannel:(VLCChannel *)channel {
    if (!line || !channel) return;
    
    // Parse catchup attribute
    NSRange catchupRange = [line rangeOfString:@"catchup=\""];
    if (catchupRange.location != NSNotFound) {
        NSUInteger startPos = catchupRange.location + catchupRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            NSString *catchupValue = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
            
            // Validate catchup value
            if ([self isValidCatchupValue:catchupValue]) {
                channel.supportsCatchup = YES;
                channel.catchupSource = catchupValue;
            }
        }
    }
    
    // Parse catchup-days attribute
    NSRange catchupDaysRange = [line rangeOfString:@"catchup-days=\""];
    if (catchupDaysRange.location != NSNotFound) {
        NSUInteger startPos = catchupDaysRange.location + catchupDaysRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            NSString *catchupDaysStr = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
            NSInteger days = [catchupDaysStr integerValue];
            if (days > 0) {
                channel.catchupDays = days;
            }
        }
    } else if (channel.supportsCatchup && channel.catchupDays == 0) {
        // Default to 7 days if catchup is supported but no days specified
        channel.catchupDays = 7;
    }
    
    // Parse catchup-template attribute
    NSRange catchupTemplateRange = [line rangeOfString:@"catchup-template=\""];
    if (catchupTemplateRange.location != NSNotFound) {
        NSUInteger startPos = catchupTemplateRange.location + catchupTemplateRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
        if (endQuoteRange.location != NSNotFound) {
            NSString *catchupTemplate = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
            channel.catchupTemplate = catchupTemplate;
        }
    }
}

#pragma mark - API Operations

- (NSString *)constructLiveStreamsAPIURL:(NSString *)m3uURL {
    if (!m3uURL) return nil;
    
    NSURL *url = [NSURL URLWithString:m3uURL];
    if (!url) return nil;
    
    NSString *scheme = [url scheme];
    NSString *host = [url host];
    NSNumber *port = [url port];
    NSString *portString = port ? [NSString stringWithFormat:@":%@", port] : @"";
    
    NSString *username = [self extractUsernameFromM3UURL:m3uURL];
    NSString *password = [self extractPasswordFromM3UURL:m3uURL];
    
    if (!username || !password || username.length == 0 || password.length == 0) {
        //NSLog(@"❌ [TIMESHIFT] Failed to extract username/password from M3U URL");
        return nil;
    }
    
    NSString *apiURL = [NSString stringWithFormat:@"%@://%@%@/player_api.php?username=%@&password=%@&action=get_live_streams",
                        scheme, host, portString, username, password];
    
    return apiURL;
}

- (NSString *)constructM3UURLFromChannel:(VLCChannel *)channel {
    if (!channel || !channel.url) return nil;
    
    // Extract server info from channel URL
    NSURL *channelURL = [NSURL URLWithString:channel.url];
    if (!channelURL) return nil;
    
    NSString *scheme = [channelURL scheme];
    NSString *host = [channelURL host];
    NSNumber *port = [channelURL port];
    NSString *portString = port ? [NSString stringWithFormat:@":%@", port] : @"";
    
    // Extract credentials from channel URL
    NSString *username = [self extractUsernameFromChannelURL:channel.url];
    NSString *password = [self extractPasswordFromChannelURL:channel.url];
    
    if (!username || !password || username.length == 0 || password.length == 0) {
        //NSLog(@"⚠️ [TIMESHIFT] Cannot extract credentials from channel URL for M3U construction");
        return nil;
    }
    
    // Construct M3U URL
    NSString *m3uURL = [NSString stringWithFormat:@"%@://%@%@/get.php?username=%@&password=%@&type=m3u_plus",
                        scheme, host, portString, username, password];
    
    //NSLog(@"🔗 [TIMESHIFT] Constructed M3U URL from channel for API access");
    return m3uURL;
}

#pragma mark - Timeshift URL Generation

- (NSString *)generateTimeshiftURLForProgram:(VLCProgram *)program
                                     channel:(VLCChannel *)channel
                                  timeOffset:(NSTimeInterval)timeOffset {
    
    if (![self programSupportsTimeshift:program channel:channel]) {
        return nil;
    }
    
    return [self generateTimeshiftURLForChannel:channel 
                                         atTime:program.startTime 
                                     timeOffset:timeOffset];
}

- (NSString *)generateTimeshiftURLForChannel:(VLCChannel *)channel
                                      atTime:(NSDate *)targetTime
                                  timeOffset:(NSTimeInterval)timeOffset {
    
    if (![self channelSupportsTimeshift:channel] || !targetTime) {
        return nil;
    }
    
    // Extract server info from channel URL
    NSURL *channelURL = [NSURL URLWithString:channel.url];
    if (!channelURL) return nil;
    
    NSString *scheme = [channelURL scheme];
    NSString *host = [channelURL host];
    NSNumber *port = [channelURL port];
    NSString *baseURL = [NSString stringWithFormat:@"%@://%@", scheme, host];
    if (port) {
        baseURL = [baseURL stringByAppendingFormat:@":%@", port];
    }
    
    // Extract credentials from channel URL or use fallback method
    NSString *username = [self extractUsernameFromChannelURL:channel.url];
    NSString *password = [self extractPasswordFromChannelURL:channel.url];
    NSString *streamId = [self extractStreamIDFromChannelURL:channel.url];
    
    //NSLog(@"🔍 [TIMESHIFT-EXTRACT] Channel URL: %@", channel.url);
    //NSLog(@"🔍 [TIMESHIFT-EXTRACT] Extracted username: '%@'", username ?: @"(nil)");
    //NSLog(@"🔍 [TIMESHIFT-EXTRACT] Extracted password: '%@'", password ?: @"(nil)");
    //NSLog(@"🔍 [TIMESHIFT-EXTRACT] Extracted stream ID: '%@'", streamId ?: @"(nil)");
    
    if (!username || !password || !streamId) {
        NSLog(@"❌ [TIMESHIFT] Failed to extract credentials/stream ID from channel URL");
        return nil;
    }
    
    // Format target time for server
    NSTimeInterval offsetCompensation = -timeOffset; // Compensate for display offset
    NSDate *adjustedTime = [targetTime dateByAddingTimeInterval:offsetCompensation];
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd:HH-mm"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    NSString *timeString = [formatter stringFromDate:adjustedTime];
    
    // Calculate duration (default to 2 hours)
    NSInteger durationMinutes = 120;
    
    // Generate timeshift URL
    NSString *timeshiftURL = [NSString stringWithFormat:@"%@/streaming/timeshift.php?username=%@&password=%@&stream=%@&start=%@&duration=%ld",
                             baseURL, username, password, streamId, timeString, (long)durationMinutes];
    
    return timeshiftURL;
}

#pragma mark - Channel Analysis

- (BOOL)channelSupportsTimeshift:(VLCChannel *)channel {
    return channel.supportsCatchup || channel.catchupDays > 0;
}

- (BOOL)programSupportsTimeshift:(VLCProgram *)program channel:(VLCChannel *)channel {
    return program.hasArchive || [self channelSupportsTimeshift:channel];
}

- (NSInteger)timeshiftDaysForChannel:(VLCChannel *)channel {
    return channel.catchupDays;
}

- (BOOL)groupHasTimeshiftChannels:(NSArray<VLCChannel *> *)channels {
    for (VLCChannel *channel in channels) {
        if ([self channelSupportsTimeshift:channel]) {
            return YES;
        }
    }
    return NO;
}

- (NSInteger)timeshiftChannelCountInGroup:(NSArray<VLCChannel *> *)channels {
    NSInteger count = 0;
    for (VLCChannel *channel in channels) {
        if ([self channelSupportsTimeshift:channel]) {
            count++;
        }
    }
    return count;
}

#pragma mark - Utility Methods

- (NSString *)extractStreamIDFromChannelURL:(NSString *)channelURL {
    if (!channelURL) return nil;
    
    // Pattern for Xtream Codes URLs: .../username/password/stream_id or .../stream_id.m3u8
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"/(\\d+)(?:\\.m3u8)?/?$" 
                                                                           options:0 
                                                                             error:&error];
    
    if (!error) {
        NSArray *matches = [regex matchesInString:channelURL options:0 range:NSMakeRange(0, channelURL.length)];
        if (matches.count > 0) {
            NSTextCheckingResult *match = [matches lastObject];
            if (match.numberOfRanges > 1) {
                NSRange idRange = [match rangeAtIndex:1];
                return [channelURL substringWithRange:idRange];
            }
        }
    }
    
    return nil;
}

- (NSString *)extractUsernameFromM3UURL:(NSString *)m3uURL {
    NSURL *url = [NSURL URLWithString:m3uURL];
    if (!url) return nil;
    
    // Try query parameters first
    NSString *query = [url query];
    if (query) {
        NSArray *queryItems = [query componentsSeparatedByString:@"&"];
        for (NSString *item in queryItems) {
            NSArray *keyValue = [item componentsSeparatedByString:@"="];
            if (keyValue.count == 2) {
                NSString *key = keyValue[0];
                NSString *value = keyValue[1];
                if ([key isEqualToString:@"username"]) {
                    return value;
                }
            }
        }
    }
    
    // Try path components
    NSString *path = [url path];
    NSArray *pathComponents = [path pathComponents];
    for (NSInteger i = 0; i < pathComponents.count - 1; i++) {
        if ([pathComponents[i] hasSuffix:@".php"] && i + 1 < pathComponents.count) {
            return pathComponents[i + 1];
        }
    }
    
    return nil;
}

- (NSString *)extractPasswordFromM3UURL:(NSString *)m3uURL {
    NSURL *url = [NSURL URLWithString:m3uURL];
    if (!url) return nil;
    
    // Try query parameters first
    NSString *query = [url query];
    if (query) {
        NSArray *queryItems = [query componentsSeparatedByString:@"&"];
        for (NSString *item in queryItems) {
            NSArray *keyValue = [item componentsSeparatedByString:@"="];
            if (keyValue.count == 2) {
                NSString *key = keyValue[0];
                NSString *value = keyValue[1];
                if ([key isEqualToString:@"password"]) {
                    return value;
                }
            }
        }
    }
    
    // Try path components
    NSString *path = [url path];
    NSArray *pathComponents = [path pathComponents];
    for (NSInteger i = 0; i < pathComponents.count - 2; i++) {
        if ([pathComponents[i] hasSuffix:@".php"] && i + 2 < pathComponents.count) {
            return pathComponents[i + 2];
        }
    }
    
    return nil;
}

- (NSString *)extractUsernameFromChannelURL:(NSString *)channelURL {
    // Extract from channel URL path structure
    NSURL *url = [NSURL URLWithString:channelURL];
    if (!url) return nil;
    
    NSArray *pathComponents = [[url path] pathComponents];
    
    // Remove root "/" component if present
    NSMutableArray *cleanComponents = [NSMutableArray array];
    for (NSString *component in pathComponents) {
        if (![component isEqualToString:@"/"]) {
            [cleanComponents addObject:component];
        }
    }
    
    // Look for pattern: /live/username/password/stream_id or /username/password/stream_id
    for (NSInteger i = 0; i < cleanComponents.count - 2; i++) {
        NSString *component = cleanComponents[i];
        if ([component isEqualToString:@"live"] || [component isEqualToString:@"movie"] || [component isEqualToString:@"series"]) {
            if (i + 1 < cleanComponents.count) {
                return cleanComponents[i + 1];
            }
        }
    }
    
    // Direct pattern: /username/password/stream_id (no prefix)
    if (cleanComponents.count >= 3) {
        // First component should be username
        return cleanComponents[0];
    }
    
    return nil;
}

- (NSString *)extractPasswordFromChannelURL:(NSString *)channelURL {
    // Extract from channel URL path structure
    NSURL *url = [NSURL URLWithString:channelURL];
    if (!url) return nil;
    
    NSArray *pathComponents = [[url path] pathComponents];
    
    // Remove root "/" component if present
    NSMutableArray *cleanComponents = [NSMutableArray array];
    for (NSString *component in pathComponents) {
        if (![component isEqualToString:@"/"]) {
            [cleanComponents addObject:component];
        }
    }
    
    // Look for pattern: /live/username/password/stream_id or /username/password/stream_id
    for (NSInteger i = 0; i < cleanComponents.count - 2; i++) {
        NSString *component = cleanComponents[i];
        if ([component isEqualToString:@"live"] || [component isEqualToString:@"movie"] || [component isEqualToString:@"series"]) {
            if (i + 2 < cleanComponents.count) {
                return cleanComponents[i + 2];
            }
        }
    }
    
    // Direct pattern: /username/password/stream_id (no prefix)
    if (cleanComponents.count >= 3) {
        // Second component should be password
        return cleanComponents[1];
    }
    
    return nil;
}

#pragma mark - Validation

- (BOOL)isValidCatchupValue:(NSString *)catchupValue {
    if (!catchupValue) return NO;
    
    NSArray *validValues = @[@"1", @"default", @"append", @"timeshift", @"shift"];
    return [validValues containsObject:catchupValue];
}

- (BOOL)isTimeshiftURLValid:(NSString *)timeshiftURL {
    if (!timeshiftURL) return NO;
    
    NSURL *url = [NSURL URLWithString:timeshiftURL];
    return url != nil && [url.scheme hasPrefix:@"http"];
}

#pragma mark - Statistics

- (NSDictionary *)timeshiftStatistics:(NSArray<VLCChannel *> *)channels {
    NSInteger totalChannels = channels.count;
    NSInteger timeshiftChannels = 0;
    NSInteger epgTimeshiftChannels = 0;
    NSInteger m3uTimeshiftChannels = 0;
    
    NSMutableDictionary *daysCounts = [[NSMutableDictionary alloc] init];
    
    for (VLCChannel *channel in channels) {
        if ([self channelSupportsTimeshift:channel]) {
            timeshiftChannels++;
            
            if (channel.supportsCatchup) {
                m3uTimeshiftChannels++;
            }
            
            // Count by days
            NSString *daysKey = [NSString stringWithFormat:@"%ld", (long)channel.catchupDays];
            NSNumber *count = [daysCounts objectForKey:daysKey];
            [daysCounts setObject:@(count.integerValue + 1) forKey:daysKey];
        }
        
        // Check for EPG-based timeshift
        if (channel.programs) {
            for (VLCProgram *program in channel.programs) {
                if (program.hasArchive) {
                    epgTimeshiftChannels++;
                    break;
                }
            }
        }
    }
    
    return @{
        @"totalChannels": @(totalChannels),
        @"timeshiftChannels": @(timeshiftChannels),
        @"timeshiftPercentage": @((float)timeshiftChannels / (float)totalChannels * 100.0),
        @"m3uTimeshiftChannels": @(m3uTimeshiftChannels),
        @"epgTimeshiftChannels": @(epgTimeshiftChannels),
        @"timeshiftDaysCounts": daysCounts
    };
}

@end 