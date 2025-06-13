//
//  VLCEPGManager.m
//  BasicPlayerWithPlaylist
//
//  Universal EPG Manager - Platform Independent
//  Handles EPG fetching, parsing, caching, and program matching
//

#import "VLCEPGManager.h"
#import "VLCCacheManager.h"
#import "VLCChannel.h"
#import "VLCProgram.h"
#import "DownloadManager.h"
#import <mach/mach.h>

@interface VLCEPGManager () <NSXMLParserDelegate>

// Internal state
@property (nonatomic, strong) NSMutableDictionary *internalEpgData;
@property (nonatomic, assign) BOOL internalIsLoaded;
@property (nonatomic, assign) BOOL internalIsLoading;
@property (nonatomic, assign) float internalProgress;
@property (nonatomic, strong) NSString *internalCurrentStatus;
@property (nonatomic, strong) NSString *currentEPGURL; // Track current EPG URL for cache saving

// XML parsing state
@property (nonatomic, strong) NSMutableString *currentElementContent;
@property (nonatomic, strong) VLCProgram *currentProgram;
@property (nonatomic, strong) NSString *currentChannelId;
@property (nonatomic, strong) NSMutableArray *currentChannelPrograms;
@property (nonatomic, assign) NSUInteger totalProgramsParsed;
@property (nonatomic, assign) NSUInteger totalChannelsParsed;

// Temporary parsing properties to avoid premature NSDate parsing
@property (nonatomic, strong) NSString *currentStartTimeStr;
@property (nonatomic, strong) NSString *currentStopTimeStr;

// Progress tracking
@property (nonatomic, strong) NSTimer *progressTimer;
@property (nonatomic, assign) NSUInteger lastReportedProgress;

@end

@implementation VLCEPGManager

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
    self.timeOffsetHours = 0.0;
    self.cacheValidityHours = 6.0; // 6 hours
    
    self.internalIsLoaded = NO;
    self.internalIsLoading = NO;
    self.internalProgress = 0.0;
    self.internalCurrentStatus = @"";
    
    NSLog(@"📅 [EPG] Initialized with defaults");
}

- (void)initializeDataStructures {
    self.internalEpgData = [[NSMutableDictionary alloc] init];
    self.currentElementContent = [[NSMutableString alloc] init];
    
    NSLog(@"📅 [EPG] Initialized data structures");
}

#pragma mark - Public Property Accessors

- (NSDictionary *)epgData { 
    @synchronized(self.internalEpgData) {
        return [self.internalEpgData copy]; 
    }
}
- (BOOL)isLoaded { return self.internalIsLoaded; }
- (BOOL)isLoading { return self.internalIsLoading; }
- (float)progress { return self.internalProgress; }
- (NSString *)currentStatus { return self.internalCurrentStatus ?: @""; }

#pragma mark - Main Operations

- (void)loadEPGFromURL:(NSString *)epgURL
            completion:(VLCEPGLoadCompletion)completion
              progress:(VLCEPGProgressBlock)progressBlock {
    
    if (self.internalIsLoading) {
        NSLog(@"⚠️ [EPG] Already loading EPG, ignoring request");
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"VLCEPGManager" 
                                               code:4001 
                                           userInfo:@{NSLocalizedDescriptionKey: @"EPG loading already in progress"}];
            completion(nil, error);
        }
        return;
    }
    
    NSLog(@"📅 [EPG] Starting EPG loading from URL: %@", epgURL);
    
    self.internalIsLoading = YES;
    self.internalProgress = 0.0;
    self.internalCurrentStatus = @"Checking EPG cache...";
    
    if (progressBlock) {
        progressBlock(0.0, self.internalCurrentStatus);
    }
    
    // Try loading from cache first
    __weak __typeof__(self) weakSelf = self;
    [self loadEPGFromCache:epgURL completion:^(NSDictionary *cachedEpgData, NSError *cacheError) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (cachedEpgData && !cacheError) {
            // Count total programs for logging
            NSUInteger totalPrograms = 0;
            for (NSString *channelId in cachedEpgData) {
                NSArray *programs = [cachedEpgData objectForKey:channelId];
                if ([programs isKindOfClass:[NSArray class]]) {
                    totalPrograms += programs.count;
                }
            }
            NSLog(@"✅ [CACHE] Found cached EPG: %lu channels with %lu programs total", (unsigned long)cachedEpgData.count, (unsigned long)totalPrograms);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // CRITICAL FIX: Properly store the cached EPG data internally
                @synchronized(strongSelf.internalEpgData) {
                    strongSelf.internalEpgData = [cachedEpgData mutableCopy];
                }
                strongSelf.internalIsLoaded = YES;
                strongSelf.internalIsLoading = NO;
                strongSelf.internalProgress = 1.0;
                strongSelf.internalCurrentStatus = [NSString stringWithFormat:@"EPG loaded from cache (%lu channels, %lu programs)", (unsigned long)cachedEpgData.count, (unsigned long)totalPrograms];
                
                if (progressBlock) {
                    progressBlock(1.0, strongSelf.internalCurrentStatus);
                }
                
                if (completion) {
                    completion(cachedEpgData, nil);
                }
                
                // CRITICAL: Explicitly log the cache load success for debugging
                NSLog(@"📅 [EPG-CACHE] EPG data loaded from cache and stored internally - isLoaded: %@, dataCount: %lu", 
                      strongSelf.internalIsLoaded ? @"YES" : @"NO", (unsigned long)strongSelf.internalEpgData.count);
            });
            return;
        }
        
        // Cache miss or invalid - download from URL
        NSLog(@"📅 [EPG] 🌐 Cache miss - downloading fresh EPG from server");
        [strongSelf downloadAndParseEPG:epgURL completion:completion progress:progressBlock];
    }];
}

- (void)downloadAndParseEPG:(NSString *)epgURL
                 completion:(VLCEPGLoadCompletion)completion
                   progress:(VLCEPGProgressBlock)progressBlock {
    
    // Store current EPG URL for cache saving
    self.currentEPGURL = epgURL;
    
    self.internalCurrentStatus = @"🌐 Downloading fresh EPG from server...";
    if (progressBlock) {
        dispatch_async(dispatch_get_main_queue(), ^{
            progressBlock(0.05, self.internalCurrentStatus);
        });
    }
    
    // Use DownloadManager for async download with progress
    DownloadManager *downloadManager = [[DownloadManager alloc] init];
    
    // Create temporary file path for download
    NSString *tempFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"temp_epg.xml"];
    
    [downloadManager startDownloadFromURL:epgURL
                         progressHandler:^(int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite) {
        // CRITICAL FIX: Handle division by zero when server doesn't provide Content-Length
        float downloadProgress;
        if (totalBytesExpectedToWrite > 0) {
            // Normal progress calculation when we know the total size
            downloadProgress = 0.05 + (0.25 * ((float)totalBytesWritten / (float)totalBytesExpectedToWrite));
        } else {
            // Fallback: estimate progress based on downloaded bytes (assume reasonable EPG size)
            float estimatedTotalMB = MAX(50.0, totalBytesWritten / 1024.0 / 1024.0 * 2.0); // Estimate total as 2x current download
            float currentMB = totalBytesWritten / 1024.0 / 1024.0;
            float estimatedProgress = MIN(0.25, currentMB / estimatedTotalMB * 0.25);
            downloadProgress = 0.05 + estimatedProgress;
        }
        
        // Ensure progress stays within reasonable bounds
        downloadProgress = MAX(0.05, MIN(0.3, downloadProgress));
        
        NSString *progressStatus;
        if (totalBytesExpectedToWrite > 0) {
            progressStatus = [NSString stringWithFormat:@"🌐 Downloading EPG: %.1f MB / %.1f MB", 
                            totalBytesWritten / 1024.0 / 1024.0, 
                            totalBytesExpectedToWrite / 1024.0 / 1024.0];
        } else {
            progressStatus = [NSString stringWithFormat:@"🌐 Downloading EPG: %.1f MB", 
                            totalBytesWritten / 1024.0 / 1024.0];
        }
        
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
            NSLog(@"❌ [EPG] Download failed: %@", error.localizedDescription);
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
        NSData *epgData = [NSData dataWithContentsOfFile:filePath];
        if (!epgData) {
            NSError *readError = [NSError errorWithDomain:@"VLCEPGManager" 
                                                     code:4005 
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read downloaded EPG file"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.internalIsLoading = NO;
                if (completion) {
                    completion(nil, readError);
                }
            });
            [downloadManager release];
            return;
        }
        
        NSLog(@"✅ [EPG] 🌐 Successfully downloaded fresh EPG: %lu bytes", (unsigned long)epgData.length);
        
        // Clean up temp file
        [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        
        // Parse the downloaded content (0.3 to 1.0 = remaining 70% for parsing)
        [self parseEPGXMLData:epgData completion:completion progress:progressBlock];
        
        [downloadManager release];
    }
                         destinationPath:tempFilePath];
}

- (NSData *)downloadDataFromURL:(NSString *)urlString error:(NSError **)error {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"VLCEPGManager" 
                                        code:4002 
                                    userInfo:@{NSLocalizedDescriptionKey: @"Invalid EPG URL"}];
        }
        return nil;
    }
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url 
                                             cachePolicy:NSURLRequestReloadIgnoringCacheData 
                                         timeoutInterval:180.0]; // 3 minutes for EPG
    
    // Synchronous download for simplicity (already on background queue)
    NSURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request 
                                        returningResponse:&response 
                                                    error:error];
    
    return data;
}

- (void)loadEPGFromCache:(NSString *)sourceURL
              completion:(VLCEPGLoadCompletion)completion {
    
    // Rate limiting for cache loading to prevent duplicate loads
    static NSTimeInterval lastCacheLoadTime = 0;
    static NSString *lastCacheURL = nil;
    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    
    // FIXED: Reduce rate limiting during startup - allow cache reloading after 0.5 seconds
    // and completely skip rate limiting if we have different URLs
    BOOL isDifferentURL = !lastCacheURL || ![lastCacheURL isEqualToString:sourceURL];
    NSTimeInterval rateLimitWindow = isDifferentURL ? 0.0 : 0.5; // 0.5 seconds for same URL, none for different URL
    
    if (currentTime - lastCacheLoadTime < rateLimitWindow) {
        NSLog(@"⚠️ [EPG-CACHE] Cache loading rate limited - wait %.1f seconds", rateLimitWindow - (currentTime - lastCacheLoadTime));
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"VLCEPGManager" 
                                               code:4005 
                                           userInfo:@{NSLocalizedDescriptionKey: @"Cache loading rate limited"}]);
        }
        return;
    }
    
    NSLog(@"📅 [EPG-CACHE] Loading EPG from cache (rate limit: %.1fs passed)", currentTime - lastCacheLoadTime);
    
    lastCacheLoadTime = currentTime;
    [lastCacheURL release];
    lastCacheURL = [sourceURL copy];
    
    if (!self.cacheManager) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"VLCEPGManager" 
                                               code:4003 
                                           userInfo:@{NSLocalizedDescriptionKey: @"No cache manager available"}]);
        }
        return;
    }
    
    [self.cacheManager loadEPGFromCache:sourceURL completion:^(id data, BOOL success, NSError *error) {
        if (success && [data isKindOfClass:[NSDictionary class]]) {
            // CRITICAL FIX: Convert cached dictionary data to VLCProgram objects
            NSDictionary *cachedEpgDict = (NSDictionary *)data;
            NSMutableDictionary *convertedEpgData = [[NSMutableDictionary alloc] init];
            
            for (NSString *channelId in cachedEpgDict) {
                NSArray *programDicts = [cachedEpgDict objectForKey:channelId];
                NSMutableArray *programs = [[NSMutableArray alloc] init];
                
                for (NSDictionary *programDict in programDicts) {
                    if ([programDict isKindOfClass:[NSDictionary class]]) {
                        // Convert dictionary to VLCProgram object
                        VLCProgram *program = [[VLCProgram alloc] init];
                        program.title = [programDict objectForKey:@"title"];
                        program.programDescription = [programDict objectForKey:@"description"];
                        program.startTime = [programDict objectForKey:@"startTime"];
                        program.endTime = [programDict objectForKey:@"endTime"];
                        program.channelId = [programDict objectForKey:@"channelId"];
                        
                        // TIMESHIFT: Restore timeshift properties from cache
                        program.hasArchive = [[programDict objectForKey:@"hasArchive"] boolValue];
                        program.archiveDays = [[programDict objectForKey:@"archiveDays"] integerValue];
                        
                        [programs addObject:program];
                        [program release];
                    } else if ([programDict isKindOfClass:[VLCProgram class]]) {
                        // Already a VLCProgram object
                        [programs addObject:programDict];
                    }
                }
                
                [convertedEpgData setObject:programs forKey:channelId];
                [programs release];
            }
            
            // CRITICAL FIX: Store the converted EPG data internally and mark as loaded
            NSUInteger totalPrograms = 0;
            for (NSString *channelId in convertedEpgData) {
                NSArray *programs = [convertedEpgData objectForKey:channelId];
                totalPrograms += programs.count;
            }
            
            NSLog(@"📅 [EPG-CACHE] Storing %lu channels with %lu programs internally", (unsigned long)convertedEpgData.count, (unsigned long)totalPrograms);
            
            // CRITICAL DEBUG: Log the first few channel IDs to see what's being loaded
            NSArray *channelIds = [convertedEpgData allKeys];
            NSLog(@"📅 [EPG-CACHE] First 10 EPG channel IDs loaded from cache:");
            for (NSInteger i = 0; i < MIN(10, channelIds.count); i++) {
                NSString *channelId = channelIds[i];
                NSArray *programs = [convertedEpgData objectForKey:channelId];
                NSLog(@"📅 [EPG-CACHE]   %ld: '%@' (%lu programs)", (long)i, channelId, (unsigned long)programs.count);
            }
            
            @synchronized(self.internalEpgData) {
                [self.internalEpgData removeAllObjects];
                [self.internalEpgData addEntriesFromDictionary:convertedEpgData];
            }
            self.internalIsLoaded = YES;
            
            NSLog(@"📅 [EPG-CACHE] Internal EPG data now contains %lu channels", (unsigned long)self.internalEpgData.count);
            
            if (completion) {
                completion(convertedEpgData, nil);
            }
            [convertedEpgData release];
        } else {
            if (completion) {
                completion(nil, error);
            }
        }
    }];
}

- (void)forceReloadEPGFromURL:(NSString *)epgURL
                   completion:(VLCEPGLoadCompletion)completion
                     progress:(VLCEPGProgressBlock)progressBlock {
    
    NSLog(@"🔄 🚀 [EPG] FORCE reloading EPG from URL (bypassing cache): %@", epgURL);
    NSLog(@"🌐 [EPG] Fresh download initiated - will show real download progress");
    
    // Store current EPG URL for cache saving
    self.currentEPGURL = epgURL;
    
    // Clear existing data
    [self clearEPGData];
    
    // Download and parse directly (bypass cache)
    self.internalIsLoading = YES;
    [self downloadAndParseEPG:epgURL completion:completion progress:progressBlock];
}

#pragma mark - EPG Processing

- (void)parseEPGXMLData:(NSData *)xmlData
             completion:(VLCEPGLoadCompletion)completion
               progress:(VLCEPGProgressBlock)progressBlock {
    
    if (!xmlData || xmlData.length == 0) {
        NSLog(@"❌ [EPG] Empty XML data");
        NSError *error = [NSError errorWithDomain:@"VLCEPGManager" 
                                           code:4004 
                                       userInfo:@{NSLocalizedDescriptionKey: @"Empty EPG XML data"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.internalIsLoading = NO;
            if (completion) {
                completion(nil, error);
            }
        });
        return;
    }
    
    NSLog(@"📅 [EPG] Starting XML parsing - %lu bytes", (unsigned long)xmlData.length);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performEPGXMLParsing:xmlData completion:completion progress:progressBlock];
    });
}

- (void)performEPGXMLParsing:(NSData *)xmlData
                  completion:(VLCEPGLoadCompletion)completion
                    progress:(VLCEPGProgressBlock)progressBlock {
    
    // ✅ EPG parsing re-enabled with memory optimizations
    
    @autoreleasepool {
        // Initialize parsing state
        self.internalCurrentStatus = @"Parsing EPG XML...";
        self.totalProgramsParsed = 0;
        self.totalChannelsParsed = 0;
        self.lastReportedProgress = 0;
        
        // Clear existing EPG data
        [self.internalEpgData removeAllObjects];
        
        // Start progress timer
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary *userInfo = [[NSMutableDictionary alloc] init];
            if (progressBlock) {
                [userInfo setObject:progressBlock forKey:@"progressBlock"];
            }
            
            self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 
                                                                 target:self 
                                                               selector:@selector(reportParsingProgress:) 
                                                               userInfo:userInfo
                                                                repeats:YES];
        });
        
        // Create XML parser
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:xmlData];
        parser.delegate = self;
        
        // Parse XML
        BOOL success = [parser parse];
        
        // Stop progress timer
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressTimer invalidate];
            self.progressTimer = nil;
        });
        
        if (success) {
            NSLog(@"✅ [EPG] XML parsing completed successfully - %lu programs from %lu channels", 
                  (unsigned long)self.totalProgramsParsed, (unsigned long)self.totalChannelsParsed);
            
            // Save to cache with proper URL
            if (self.cacheManager && self.currentEPGURL) {
                @synchronized(self.internalEpgData) {
                    NSLog(@"💾 [EPG] Saving parsed EPG to cache with URL: %@", self.currentEPGURL);
                    [self.cacheManager saveEPGToCache:[self.internalEpgData copy] 
                                            sourceURL:self.currentEPGURL
                                           completion:^(BOOL success, NSError *error) {
                        if (success) {
                            NSLog(@"✅ [EPG] EPG successfully cached");
                        } else {
                            NSLog(@"❌ [EPG] Failed to cache EPG: %@", error.localizedDescription);
                        }
                    }];
                }
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.internalIsLoaded = YES;
                self.internalIsLoading = NO;
                self.internalProgress = 1.0;
                self.internalCurrentStatus = [NSString stringWithFormat:@"EPG: Complete (%lu programs from %lu channels)", 
                                              (unsigned long)self.totalProgramsParsed, (unsigned long)self.totalChannelsParsed];
                
                if (completion) {
                    @synchronized(self.internalEpgData) {
                        completion([self.internalEpgData copy], nil);
                    }
                }
            });
            
        } else {
            NSError *parseError = parser.parserError;
            NSLog(@"❌ [EPG] XML parsing failed: %@", parseError.localizedDescription);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.internalIsLoading = NO;
                self.internalProgress = 0.0;
                
                if (completion) {
                    completion(nil, parseError);
                }
            });
        }
    }
}

- (void)reportParsingProgress:(NSTimer *)timer {
    NSDictionary *userInfo = timer.userInfo;
    id progressBlockObj = [userInfo objectForKey:@"progressBlock"];
    
    if ([progressBlockObj isKindOfClass:[NSNull class]]) return;
    
    VLCEPGProgressBlock progressBlock = (VLCEPGProgressBlock)progressBlockObj;
    
    // More accurate progress estimation: download (0.05-0.3) + parsing (0.3-1.0)
    float parsingProgress = MIN(1.0, (float)self.totalProgramsParsed / 80000.0);
    float estimatedProgress = 0.3 + (0.7 * parsingProgress);
    self.internalProgress = estimatedProgress;
    
    // Estimate total programs based on current progress
    NSUInteger estimatedTotalPrograms = 0;
    if (parsingProgress > 0.01) { // Avoid division by very small numbers
        estimatedTotalPrograms = (NSUInteger)(self.totalProgramsParsed / parsingProgress);
    }
    
    if (estimatedTotalPrograms > 0 && estimatedTotalPrograms < 1000000) { // Sanity check
        self.internalCurrentStatus = [NSString stringWithFormat:@"EPG: Parsing (%lu of %lu)", 
                                      (unsigned long)self.totalProgramsParsed, (unsigned long)estimatedTotalPrograms];
    } else {
        self.internalCurrentStatus = [NSString stringWithFormat:@"EPG: Parsing (%lu programs)", 
                                      (unsigned long)self.totalProgramsParsed];
    }
    
    // Log memory usage along with progress (less frequently to avoid spam)
    if (self.totalProgramsParsed % 5000 == 0) {
        [VLCEPGManager logMemoryUsage:self.internalCurrentStatus];
    }
    
    if (progressBlock) {
        progressBlock(estimatedProgress, self.internalCurrentStatus);
    }
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName 
  namespaceURI:(NSString *)namespaceURI 
 qualifiedName:(NSString *)qName 
    attributes:(NSDictionary<NSString *, NSString *> *)attributeDict {
    
    [self.currentElementContent setString:@""];
    
    if ([elementName isEqualToString:@"programme"]) {
        // Start new program - use minimal VLCProgram with delayed property assignment
        self.currentProgram = [[VLCProgram alloc] init];
        
        // Extract and store only the channel ID immediately
        self.currentChannelId = [attributeDict objectForKey:@"channel"];
        if (self.currentChannelId) {
            self.currentProgram.channelId = self.currentChannelId;
        }
        
        // Store raw time strings in temporary properties to avoid NSDate parsing overhead
        self.currentStartTimeStr = [attributeDict objectForKey:@"start"];
        self.currentStopTimeStr = [attributeDict objectForKey:@"stop"];
        
    } else if ([elementName isEqualToString:@"channel"]) {
        // Start new channel
        self.currentChannelId = [attributeDict objectForKey:@"id"];
        
        // Initialize program array for this channel if needed
        if (self.currentChannelId) {
            @synchronized(self.internalEpgData) {
                if (![self.internalEpgData objectForKey:self.currentChannelId]) {
                    [self.internalEpgData setObject:[[NSMutableArray alloc] init] forKey:self.currentChannelId];
                }
            }
        }
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.currentElementContent appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName 
  namespaceURI:(NSString *)namespaceURI 
 qualifiedName:(NSString *)qName {
    
    NSString *content = [self.currentElementContent stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    if ([elementName isEqualToString:@"title"] && self.currentProgram) {
        // Store directly in VLCProgram object
        if (content && content.length > 0) {
            self.currentProgram.title = content;
        }
        
    } else if ([elementName isEqualToString:@"desc"] && self.currentProgram) {
        // Store directly in VLCProgram object
        if (content && content.length > 0) {
            self.currentProgram.programDescription = content;
        }
        
    } else if ([elementName isEqualToString:@"programme"] && self.currentProgram) {
        // Finalize current program - parse dates only when completing the program
        if (self.currentChannelId && self.currentProgram.title && self.currentProgram.title.length > 0) {
            @autoreleasepool {
                // Parse dates only when finalizing
                if (self.currentStartTimeStr) {
                    self.currentProgram.startTime = [self parseXMLTVTime:self.currentStartTimeStr];
                }
                
                if (self.currentStopTimeStr) {
                    self.currentProgram.endTime = [self parseXMLTVTime:self.currentStopTimeStr];
                }
                
                // Ensure description is not nil
                if (!self.currentProgram.programDescription) {
                    self.currentProgram.programDescription = @"";
                }
                
                @synchronized(self.internalEpgData) {
                    NSMutableArray *channelPrograms = [self.internalEpgData objectForKey:self.currentChannelId];
                    if (!channelPrograms) {
                        channelPrograms = [[NSMutableArray alloc] init];
                        [self.internalEpgData setObject:channelPrograms forKey:self.currentChannelId];
                        // Only count channel once when first program is added
                        self.totalChannelsParsed++;
                    }
                    
                    [channelPrograms addObject:self.currentProgram];
                    self.totalProgramsParsed++;
                }
            }
        }
        
        // Clean up temporary properties and release current program
        [self.currentProgram release];
        self.currentProgram = nil;
        self.currentStartTimeStr = nil;
        self.currentStopTimeStr = nil;
        
    } else if ([elementName isEqualToString:@"channel"]) {
        // End of channel - don't log individual channels
        self.currentChannelId = nil;
    }
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    NSLog(@"❌ [EPG] XML parse error: %@", parseError.localizedDescription);
}

#pragma mark - Program Matching

- (void)matchEPGWithChannels:(NSArray<VLCChannel *> *)channels {
    if (!channels || channels.count == 0) {
        NSLog(@"⚠️ [EPG] No channels to match EPG with");
        return;
    }
    
    NSLog(@"📅 [EPG] Matching EPG with %lu channels", (unsigned long)channels.count);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performEPGMatching:channels];
        
        // CRITICAL FIX: Notify that EPG matching is complete so UI can update
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"📅 [EPG-MATCH] EPG matching completed - notifying observers");
            
            // Post notification that EPG matching is complete
            [[NSNotificationCenter defaultCenter] postNotificationName:@"VLCEPGMatchingCompleted" 
                                                                object:self 
                                                              userInfo:@{@"channels": channels}];
        });
    });
}

- (void)performEPGMatching:(NSArray<VLCChannel *> *)channels {
    NSUInteger matchedChannels = 0;
    NSUInteger totalPrograms = 0;
    NSUInteger channelsWithoutId = 0;
    NSUInteger channelsWithoutMatch = 0;
    
    NSLog(@"📅 [EPG-MATCH] Starting ULTRA-FAST EPG matching for %lu channels", (unsigned long)channels.count);
    
    // ULTRA-PERFORMANCE: Create a snapshot of EPG data once, outside the loop
    NSDictionary *epgDataSnapshot = nil;
    @synchronized(self.internalEpgData) {
        epgDataSnapshot = [self.internalEpgData copy];
        NSLog(@"📅 [EPG-MATCH] Created EPG snapshot with %lu entries", (unsigned long)epgDataSnapshot.count);
    }
    
    NSUInteger totalChannels = channels.count;
    NSUInteger batchSize = (totalChannels > 100000) ? 20000 : 5000; // Even larger batches for speed
    
    NSLog(@"📅 [EPG-MATCH] Using ULTRA-FAST batch size: %lu for %lu total channels", (unsigned long)batchSize, (unsigned long)totalChannels);
    
    for (NSUInteger batchStart = 0; batchStart < totalChannels; batchStart += batchSize) {
        @autoreleasepool {
            NSUInteger batchEnd = MIN(batchStart + batchSize, totalChannels);
            NSLog(@"📅 [EPG-MATCH] ULTRA-FAST batch %lu-%lu of %lu", 
                  (unsigned long)batchStart, (unsigned long)batchEnd-1, (unsigned long)totalChannels);
            
            // ULTRA-PERFORMANCE: Process entire batch with direct dictionary lookups
            for (NSUInteger i = batchStart; i < batchEnd; i++) {
                VLCChannel *channel = channels[i];
                
                // Quick skip for obvious non-EPG content
                if (channel.name && ([channel.name rangeOfString:@"2023"].location != NSNotFound || 
                                   [channel.name rangeOfString:@"2024"].location != NSNotFound ||
                                   [channel.name rangeOfString:@"Movie"].location != NSNotFound ||
                                   [channel.name rangeOfString:@"●"].location != NSNotFound)) {
                    channelsWithoutMatch++;
                    continue;
                }
                
                // Quick channel ID check
                if (!channel.channelId || [channel.channelId length] == 0) {
                    channelsWithoutId++;
                    continue; // Skip expensive ID generation for large datasets
                }
                
                // DIRECT EPG LOOKUP - no method calls, no synchronized access
                NSArray *programs = [epgDataSnapshot objectForKey:channel.channelId];
                if (programs && programs.count > 0) {
                    channel.programs = [programs mutableCopy];
                    matchedChannels++;
                    totalPrograms += programs.count;
                } else {
                    channelsWithoutMatch++;
                }
            }
            
            // Much less frequent progress updates for speed
            if (batchEnd >= totalChannels || (batchEnd % 100000 == 0)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"📅 [EPG-MATCH] ULTRA-FAST progress: %lu/%lu channels (%lu matched)", 
                          (unsigned long)batchEnd, (unsigned long)totalChannels, (unsigned long)matchedChannels);
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"VLCEPGMatchingProgress" 
                                                                        object:self 
                                                                      userInfo:@{
                        @"processed": @(batchEnd),
                        @"total": @(totalChannels),
                        @"matched": @(matchedChannels)
                    }];
                });
            }
            
            // No yielding for maximum speed
        }
    }
    
    // Only log summary, not individual channels
    NSLog(@"📊 [EPG-MATCH] Results: %lu/%lu channels matched (%lu programs total)", 
          (unsigned long)matchedChannels, (unsigned long)channels.count, (unsigned long)totalPrograms);
    if (channelsWithoutId > 0 || channelsWithoutMatch > 0) {
        //NSLog(@"📊 [EPG-MATCH] Issues: %lu channels without ID, %lu channels without EPG match", 
        //      (unsigned long)channelsWithoutId, (unsigned long)channelsWithoutMatch);
    }
    
    // CRITICAL: Log EPG data availability for troubleshooting
    NSUInteger totalEPGPrograms = 0;
    for (NSString *channelId in self.internalEpgData) {
        NSArray *programs = [self.internalEpgData objectForKey:channelId];
        if ([programs isKindOfClass:[NSArray class]]) {
            totalEPGPrograms += programs.count;
        }
    }
    //NSLog(@"📊 [EPG-MATCH] EPG data available: %lu channel entries, %lu total programs", 
    //      (unsigned long)self.internalEpgData.count, (unsigned long)totalEPGPrograms);
    
    // ENHANCED DEBUG: Always show detailed matching info when fewer than expected channels match
    if (matchedChannels < channels.count * 0.3 && channels.count > 50) { // Less than 30% match rate
        //NSLog(@"🔍 [EPG-MATCH] DEBUGGING: Poor match rate (%.1f%%) - investigating...", 
        //      (float)matchedChannels / channels.count * 100.0);
        
        // Sample first 10 channels to see what's happening
        for (NSInteger i = 0; i < MIN(10, channels.count); i++) {
            VLCChannel *channel = channels[i];
            NSArray *foundPrograms = [self findProgramsForChannel:channel];
            //NSLog(@"🔍 [EPG-MATCH] Channel %ld: name='%@' id='%@' -> %lu programs", 
            //      (long)i, channel.name ?: @"nil", channel.channelId ?: @"nil", (unsigned long)foundPrograms.count);
        }
        
        // Also log first few EPG entries
        NSArray *epgKeys = [self.internalEpgData allKeys];
        //NSLog(@"🔍 [EPG-MATCH] EPG entries available: %lu", (unsigned long)epgKeys.count);
        for (NSInteger i = 0; i < MIN(10, epgKeys.count); i++) {
            NSString *epgKey = epgKeys[i];
            NSArray *programs = [self.internalEpgData objectForKey:epgKey];
            //NSLog(@"🔍 [EPG-MATCH] EPG key %ld: '%@' (%lu programs)", 
            //      (long)i, epgKey, (unsigned long)programs.count);
        }
    }
}

- (NSArray<VLCProgram *> *)findProgramsForChannel:(VLCChannel *)channel {
    if (!channel.channelId || [channel.channelId length] == 0) return nil;
    
    // PERFORMANCE: Use direct access for large datasets to avoid copying overhead
    NSArray *programs = nil;
    @synchronized(self.internalEpgData) {
        // Try exact match first (most common case)
        programs = [self.internalEpgData objectForKey:channel.channelId];
        if (programs && programs.count > 0) {
            return programs;
        }
    }
    
    // PERFORMANCE: Skip fuzzy matching for large datasets to improve speed
    // For datasets over 100k channels, exact matching only
    @synchronized(self.internalEpgData) {
        if (self.internalEpgData.count > 100000) {
            return nil; // Skip fuzzy matching for very large datasets
        }
    }
    
    // Skip fuzzy matching for channels that clearly won't match (movies, shows, etc.)
    if (channel.name && ([channel.name containsString:@"(2023)"] || 
                        [channel.name containsString:@"(2024)"] ||
                        [channel.name containsString:@"(2022)"] ||
                        [channel.name containsString:@"Movie"] ||
                        [channel.name containsString:@"Film"] ||
                        [channel.name containsString:@"●"] ||
                        [channel.name hasPrefix:@"◦"] ||
                        [channel.name hasPrefix:@"▶"])) {
        return nil; // Don't waste time on fuzzy matching for movies/shows
    }
    
    // Optimized fuzzy matching with channel name (for smaller datasets only)
    if (channel.name && [channel.name length] > 3) { // Only try for reasonable names
        NSString *normalizedChannelName = [self normalizeChannelName:channel.name];
        
        // Use synchronized access for thread safety during enumeration
        @synchronized(self.internalEpgData) {
            // Limit fuzzy search to first 1000 EPG entries for performance
            NSArray *epgKeys = [self.internalEpgData allKeys];
            NSUInteger maxFuzzySearch = MIN(1000, epgKeys.count);
            
            for (NSUInteger j = 0; j < maxFuzzySearch; j++) {
                NSString *epgChannelId = epgKeys[j];
                
                // Skip empty or invalid EPG IDs
                if (!epgChannelId || [epgChannelId length] == 0 || [epgChannelId isEqualToString:@"0"]) {
                    continue;
                }
                
                NSArray *epgPrograms = [self.internalEpgData objectForKey:epgChannelId];
                if (!epgPrograms || epgPrograms.count == 0) {
                    continue; // Skip EPG entries with no programs
                }
                
                NSString *normalizedEpgId = [self normalizeChannelName:epgChannelId];
                
                // More selective fuzzy matching
                if ([normalizedChannelName isEqualToString:normalizedEpgId] ||
                    ([normalizedChannelName length] > 5 && [normalizedEpgId containsString:normalizedChannelName]) ||
                    ([normalizedEpgId length] > 5 && [normalizedChannelName containsString:normalizedEpgId])) {
                    
                    return epgPrograms;
                }
            }
        }
    }
    
    return nil;
}

- (NSString *)normalizeChannelName:(NSString *)name {
    if (!name) return @"";
    
    // Convert to lowercase and remove common prefixes/suffixes
    NSString *normalized = [name lowercaseString];
    normalized = [normalized stringByReplacingOccurrencesOfString:@" hd" withString:@""];
    normalized = [normalized stringByReplacingOccurrencesOfString:@" fhd" withString:@""];
    normalized = [normalized stringByReplacingOccurrencesOfString:@" 4k" withString:@""];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"." withString:@""];
    normalized = [normalized stringByReplacingOccurrencesOfString:@" " withString:@""];
    
    return normalized;
}

#pragma mark - Program Access

- (VLCProgram *)currentProgramForChannel:(VLCChannel *)channel {
    if (!channel || !channel.programs || channel.programs.count == 0) {
        return nil;
    }
    
    NSDate *now = [self adjustedCurrentTime];
    
    for (VLCProgram *program in channel.programs) {
        if (program.startTime && program.endTime) {
            if ([now timeIntervalSinceDate:program.startTime] >= 0 && 
                [now timeIntervalSinceDate:program.endTime] < 0) {
                return program;
            }
        }
    }
    
    return nil;
}

- (NSArray<VLCProgram *> *)programsForChannel:(VLCChannel *)channel {
    return channel.programs;
}

- (NSArray<VLCProgram *> *)programsForChannelID:(NSString *)channelID {
    @synchronized(self.internalEpgData) {
        return [self.internalEpgData objectForKey:channelID];
    }
}

- (VLCProgram *)programAtTime:(NSDate *)time forChannel:(VLCChannel *)channel {
    if (!time || !channel || !channel.programs) return nil;
    
    NSDate *adjustedTime = [self adjustTimeForServer:time];
    
    for (VLCProgram *program in channel.programs) {
        if (program.startTime && program.endTime) {
            if ([adjustedTime timeIntervalSinceDate:program.startTime] >= 0 && 
                [adjustedTime timeIntervalSinceDate:program.endTime] < 0) {
                return program;
            }
        }
    }
    
    return nil;
}

- (NSArray<VLCProgram *> *)programsInTimeRange:(NSDate *)startTime 
                                       endTime:(NSDate *)endTime 
                                    forChannel:(VLCChannel *)channel {
    
    if (!startTime || !endTime || !channel || !channel.programs) return @[];
    
    NSMutableArray *programs = [[NSMutableArray alloc] init];
    
    for (VLCProgram *program in channel.programs) {
        if (program.startTime && program.endTime) {
            // Check if program overlaps with time range
            BOOL programStartsInRange = ([program.startTime timeIntervalSinceDate:startTime] >= 0 && 
                                        [program.startTime timeIntervalSinceDate:endTime] < 0);
            BOOL programEndsInRange = ([program.endTime timeIntervalSinceDate:startTime] >= 0 && 
                                      [program.endTime timeIntervalSinceDate:endTime] < 0);
            BOOL programContainsRange = ([program.startTime timeIntervalSinceDate:startTime] < 0 && 
                                        [program.endTime timeIntervalSinceDate:endTime] > 0);
            
            if (programStartsInRange || programEndsInRange || programContainsRange) {
                [programs addObject:program];
            }
        }
    }
    
    return [programs copy];
}

#pragma mark - Time Utilities

- (NSDate *)adjustedCurrentTime {
    NSDate *now = [NSDate date];
    NSTimeInterval offsetSeconds = -self.timeOffsetHours * 3600.0;
    return [now dateByAddingTimeInterval:offsetSeconds];
}

- (NSDate *)adjustTimeForDisplay:(NSDate *)time {
    if (!time) return nil;
    
    NSTimeInterval offsetSeconds = self.timeOffsetHours * 3600.0;
    return [time dateByAddingTimeInterval:offsetSeconds];
}

- (NSDate *)adjustTimeForServer:(NSDate *)time {
    if (!time) return nil;
    
    NSTimeInterval offsetSeconds = -self.timeOffsetHours * 3600.0;
    return [time dateByAddingTimeInterval:offsetSeconds];
}

- (NSDate *)parseXMLTVTime:(NSString *)xmltvTime {
    if (!xmltvTime || xmltvTime.length < 14) return nil;
    
    // XMLTV format: YYYYMMDDHHmmss +ZZZZ
    NSString *dateString = [xmltvTime substringToIndex:14];
    
    // Use static cached formatter to avoid creating thousands of formatters
    static NSDateFormatter *cachedFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedFormatter = [[NSDateFormatter alloc] init];
        [cachedFormatter setDateFormat:@"yyyyMMddHHmmss"];
        [cachedFormatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    });
    
    NSDate *date = [cachedFormatter dateFromString:dateString];
    
    // Handle timezone offset if present
    if (xmltvTime.length > 15) {
        NSString *timezoneString = [xmltvTime substringFromIndex:15];
        if (timezoneString.length >= 5) {
            NSString *sign = [timezoneString substringToIndex:1];
            NSString *hours = [timezoneString substringWithRange:NSMakeRange(1, 2)];
            NSString *minutes = [timezoneString substringWithRange:NSMakeRange(3, 2)];
            
            NSTimeInterval offsetSeconds = ([hours intValue] * 3600) + ([minutes intValue] * 60);
            if ([sign isEqualToString:@"-"]) {
                offsetSeconds = -offsetSeconds;
            }
            
            date = [date dateByAddingTimeInterval:-offsetSeconds]; // Convert to UTC
        }
    }
    
    return date;
}

#pragma mark - Data Management

- (void)clearEPGData {
    NSLog(@"🧹 [EPG] Clearing EPG data");
    @synchronized(self.internalEpgData) {
        [self.internalEpgData removeAllObjects];
    }
    self.internalIsLoaded = NO;
}

- (void)updateEPGData:(NSDictionary *)epgData {
    if (epgData) {
        @synchronized(self.internalEpgData) {
            self.internalEpgData = [epgData mutableCopy];
        }
        self.internalIsLoaded = YES;
        NSLog(@"📅 [EPG] Updated EPG data with %lu channels", (unsigned long)epgData.count);
    }
}

#pragma mark - Memory Management

- (NSUInteger)estimatedMemoryUsage {
    NSUInteger total = 0;
    
    // Estimate EPG data memory usage
    @synchronized(self.internalEpgData) {
        for (NSString *channelId in self.internalEpgData) {
            NSArray *programs = [self.internalEpgData objectForKey:channelId];
            total += programs.count * sizeof(VLCProgram *);
            total += channelId.length * sizeof(unichar);
        }
    }
    
    return total;
}

- (void)performMemoryOptimization {
    NSLog(@"🧹 [EPG] Performing memory optimization");
    
    // Remove old programs (older than 24 hours)
    NSDate *cutoffDate = [[NSDate date] dateByAddingTimeInterval:-24 * 3600];
    NSUInteger removedPrograms = 0;
    
    @synchronized(self.internalEpgData) {
        // Create a copy of the keys to avoid mutation during enumeration
        NSArray *channelIds = [self.internalEpgData allKeys];
        
        for (NSString *channelId in channelIds) {
            NSMutableArray *programs = [self.internalEpgData objectForKey:channelId];
            if ([programs isKindOfClass:[NSMutableArray class]]) {
                NSMutableArray *filteredPrograms = [[NSMutableArray alloc] init];
                
                for (VLCProgram *program in programs) {
                    if (program.endTime && [program.endTime timeIntervalSinceDate:cutoffDate] > 0) {
                        [filteredPrograms addObject:program];
                    } else {
                        removedPrograms++;
                    }
                }
                
                [self.internalEpgData setObject:filteredPrograms forKey:channelId];
            }
        }
    }
    
    NSLog(@"🧹 [EPG] Memory optimization completed - removed %lu old programs", (unsigned long)removedPrograms);
}

#pragma mark - Cache Management

- (BOOL)isCacheValid:(NSString *)sourceURL {
    if (!self.cacheManager) return NO;
    return [self.cacheManager isEPGCacheValid:sourceURL];
}

- (void)saveCacheTimestamp {
    // Implementation depends on cache manager
    NSLog(@"💾 [EPG] Cache timestamp saved");
}

#pragma mark - Utility Methods

- (NSString *)sanitizeProgramTitle:(NSString *)title {
    if (!title) return @"Unknown Program";
    
    NSString *sanitized = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (sanitized.length == 0) return @"Unknown Program";
    
    return sanitized;
}

- (NSString *)formatTimeRange:(VLCProgram *)program {
    if (!program || !program.startTime || !program.endTime) {
        return @"--:--";
    }
    
    // Use static cached formatter for time display
    static NSDateFormatter *timeFormatter = nil;
    static dispatch_once_t timeOnceToken;
    dispatch_once(&timeOnceToken, ^{
        timeFormatter = [[NSDateFormatter alloc] init];
        [timeFormatter setDateFormat:@"HH:mm"];
    });
    
    NSString *startTime = [timeFormatter stringFromDate:program.startTime];
    NSString *endTime = [timeFormatter stringFromDate:program.endTime];
    
    return [NSString stringWithFormat:@"%@ - %@", startTime, endTime];
}

- (NSTimeInterval)programDuration:(VLCProgram *)program {
    if (!program || !program.startTime || !program.endTime) {
        return 0.0;
    }
    
    return [program.endTime timeIntervalSinceDate:program.startTime];
}

#pragma mark - Memory Monitoring

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

+ (void)logMemoryUsage:(NSString *)context {
    NSUInteger memoryUsage = [self getCurrentMemoryUsage];
    NSUInteger memoryMB = memoryUsage / (1024 * 1024);
    NSLog(@"📱 [EPG-MEMORY] %@: Current memory usage: %lu MB (%lu bytes)", context, (unsigned long)memoryMB, (unsigned long)memoryUsage);
}

@end 
