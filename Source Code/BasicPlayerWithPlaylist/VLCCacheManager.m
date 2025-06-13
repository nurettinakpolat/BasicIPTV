//
//  VLCCacheManager.m
//  BasicPlayerWithPlaylist
//
//  Universal Cache Manager - Platform Independent
//  Handles caching for channels, EPG, and settings across all platforms
//

#import "VLCCacheManager.h"
#import "VLCChannel.h"

#if TARGET_OS_IOS || TARGET_OS_TV
#import <CommonCrypto/CommonDigest.h>
#else
#import <CommonCrypto/CommonDigest.h>
#endif

@interface VLCCacheManager ()

// Cache directories
@property (nonatomic, strong) NSString *cacheDirectory;
@property (nonatomic, strong) NSString *channelCacheDirectory;
@property (nonatomic, strong) NSString *epgCacheDirectory;

// Cache size tracking
@property (nonatomic, assign) NSUInteger internalTotalCacheSizeBytes;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *internalCacheSizesByType;

@end

@implementation VLCCacheManager

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupDefaultConfiguration];
        [self initializeCacheDirectories];
    }
    return self;
}

- (void)setupDefaultConfiguration {
    self.channelCacheValidityHours = 24.0; // 24 hours
            self.epgCacheValidityHours = 24.0; // 24 hours - EPG data doesn't change frequently enough to need 6-hour expiration
    self.maxCacheSizeMB = 500; // 500MB
    self.enableMemoryOptimization = YES;
    
    self.internalTotalCacheSizeBytes = 0;
    self.internalCacheSizesByType = [[NSMutableDictionary alloc] init];
    
    NSLog(@"💾 [CACHE] Initialized with defaults");
}

- (void)initializeCacheDirectories {
    NSLog(@"💾 [CACHE] Starting directory initialization");
    
    // PERFORMANCE FIX: Move ALL directory path setup to background queue to prevent main thread blocking
    // NSSearchPathForDirectoriesInDomains can be slow on main thread, especially first call
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Platform-specific cache directory setup (on background thread)
        NSString *baseDirectory = nil;
        
#if TARGET_OS_IOS || TARGET_OS_TV
        // iOS/tvOS: Use Documents directory for EPG, Caches for channels
        baseDirectory = [self documentsDirectory];
        self.epgCacheDirectory = [baseDirectory stringByAppendingPathComponent:@"EPGCache"];
        
        // Use system caches directory for channels (can be cleared by system)
        NSString *systemCaches = [self cachesDirectory];
        self.channelCacheDirectory = [systemCaches stringByAppendingPathComponent:@"ChannelCache"];
#else
        // macOS: Use Application Support directory
        baseDirectory = [self applicationSupportDirectory];
        self.cacheDirectory = [baseDirectory stringByAppendingPathComponent:@"BasicIPTV"];
        self.channelCacheDirectory = [self.cacheDirectory stringByAppendingPathComponent:@"Channels"];
        self.epgCacheDirectory = [self.cacheDirectory stringByAppendingPathComponent:@"EPG"];
#endif
        
        NSLog(@"💾 [CACHE] ✅ Directory paths initialized - Channels: %@, EPG: %@", 
              self.channelCacheDirectory, self.epgCacheDirectory);
        
        // Create directories if needed (on background thread)
        [self createDirectoryIfNeeded:self.channelCacheDirectory];
        [self createDirectoryIfNeeded:self.epgCacheDirectory];
        
        NSLog(@"💾 [CACHE] ✅ Directory creation completed on background thread");
        
        // Calculate initial cache sizes (already async internally)
        [self updateCacheSizes];
    });
}

#pragma mark - Public Property Accessors

- (NSUInteger)totalCacheSizeBytes { return self.internalTotalCacheSizeBytes; }
- (NSDictionary<NSNumber *, NSNumber *> *)cacheSizesByType { return [self.internalCacheSizesByType copy]; }

#pragma mark - Main Cache Operations

- (void)saveChannelsToCache:(NSArray<VLCChannel *> *)channels
                  sourceURL:(NSString *)sourceURL
                 completion:(VLCCacheCompletion)completion {
    
    if (!channels || channels.count == 0) {
        NSLog(@"⚠️ [CACHE] No channels to save");
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                               code:3001 
                                           userInfo:@{NSLocalizedDescriptionKey: @"No channels to save"}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performChannelCacheSave:channels sourceURL:sourceURL completion:completion];
    });
}

- (void)performChannelCacheSave:(NSArray<VLCChannel *> *)channels
                      sourceURL:(NSString *)sourceURL
                     completion:(VLCCacheCompletion)completion {
    
    @autoreleasepool {
        NSLog(@"💾 [CACHE] Saving %lu channels to cache", (unsigned long)channels.count);
        
        // Create cache dictionary
        NSMutableDictionary *cacheDict = [[NSMutableDictionary alloc] init];
        [cacheDict setObject:@"1.2" forKey:@"cacheVersion"];
        [cacheDict setObject:[NSDate date] forKey:@"cacheDate"];
        [cacheDict setObject:(sourceURL ?: @"") forKey:@"sourceURL"];
        
        // Serialize channels efficiently
        NSMutableArray *serializedChannels = [[NSMutableArray alloc] initWithCapacity:channels.count];
        
        for (VLCChannel *channel in channels) {
            @autoreleasepool {
                NSDictionary *serializedChannel = [self serializeChannel:channel];
                [serializedChannels addObject:serializedChannel];
            }
        }
        
        [cacheDict setObject:serializedChannels forKey:@"channels"];
        
        // Write to cache file
        NSString *cacheFilePath = [self cacheFilePathForType:VLCCacheTypeChannels sourceURL:sourceURL];
        
        // SAFETY: Ensure directory exists before writing (in case background creation hasn't completed)
        [self createDirectoryIfNeeded:self.channelCacheDirectory];
        
        BOOL success = [cacheDict writeToFile:cacheFilePath atomically:YES];
        
        if (success) {
            NSLog(@"✅ [CACHE] Successfully saved channels cache to %@", cacheFilePath);
            [self updateCacheSizes];
        } else {
            NSLog(@"❌ [CACHE] Failed to save channels cache");
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success, success ? nil : [NSError errorWithDomain:@"VLCCacheManager" 
                                                                        code:3002 
                                                                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to write cache file"}]);
            }
        });
    }
}

- (void)loadChannelsFromCache:(NSString *)sourceURL
                   completion:(VLCCacheLoadCompletion)completion {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performChannelCacheLoad:sourceURL completion:completion];
    });
}

- (void)performChannelCacheLoad:(NSString *)sourceURL
                     completion:(VLCCacheLoadCompletion)completion {
    
    @autoreleasepool {
        NSString *cacheFilePath = [self cacheFilePathForType:VLCCacheTypeChannels sourceURL:sourceURL];
        
        if (![self fileExistsAtPath:cacheFilePath]) {
            NSLog(@"💾 [CACHE] No channel cache file found: %@", cacheFilePath);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                                            code:3003 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Cache file not found"}]);
                }
            });
            return;
        }
        
        // Check cache validity
        if (![self isChannelCacheValid:sourceURL]) {
            NSLog(@"💾 [CACHE] Channel cache is expired");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                                            code:3004 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Cache is expired"}]);
                }
            });
            return;
        }
        
        // Load cache file with performance timing
        NSTimeInterval fileLoadStart = [NSDate timeIntervalSinceReferenceDate];
        NSLog(@"🚀 [CACHE-PERF] Starting cache file load from: %@", cacheFilePath);
        
        NSDictionary *cacheDict = [NSDictionary dictionaryWithContentsOfFile:cacheFilePath];
        
        NSTimeInterval fileLoadEnd = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval fileLoadTime = fileLoadEnd - fileLoadStart;
        
        if (!cacheDict) {
            NSLog(@"❌ [CACHE] Failed to load channel cache from %@ (%.3f seconds)", cacheFilePath, fileLoadTime);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                                            code:3005 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Failed to read cache file"}]);
                }
            });
            return;
        }
        
        // Get file size for performance analysis
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:cacheFilePath error:nil];
        NSNumber *fileSize = [fileAttributes objectForKey:NSFileSize];
        CGFloat fileSizeMB = [fileSize floatValue] / (1024.0 * 1024.0);
        
        NSLog(@"🚀 [CACHE-PERF] Cache file loaded in %.3f seconds (%.1f MB, %.1f MB/sec)", 
              fileLoadTime, fileSizeMB, fileSizeMB / fileLoadTime);
        
        // Deserialize channels
        NSArray *serializedChannels = [cacheDict objectForKey:@"channels"];
        if (!serializedChannels) {
            NSLog(@"❌ [CACHE] No channels data in cache");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                                            code:3006 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"No channels data in cache"}]);
                }
            });
            return;
        }
        
        NSTimeInterval deserializeStart = [NSDate timeIntervalSinceReferenceDate];
        NSLog(@"🚀 [CACHE-PERF] Starting deserialization of %lu channels", (unsigned long)serializedChannels.count);
        
        NSMutableArray *channels = [[NSMutableArray alloc] initWithCapacity:serializedChannels.count];
        
        NSUInteger processedCount = 0;
        for (NSDictionary *serializedChannel in serializedChannels) {
            @autoreleasepool {
                VLCChannel *channel = [self deserializeChannel:serializedChannel];
                if (channel) {
                    [channels addObject:channel];
                }
                
                // Progress logging every 100k channels
                processedCount++;
                if (processedCount % 100000 == 0) {
                    NSLog(@"🚀 [CACHE-PERF] Deserialized %lu/%lu channels", (unsigned long)processedCount, (unsigned long)serializedChannels.count);
                }
            }
        }
        
        NSTimeInterval deserializeEnd = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval deserializeTime = deserializeEnd - deserializeStart;
        NSLog(@"🚀 [CACHE-PERF] Deserialization completed in %.3f seconds (%.1f channels/sec)", 
              deserializeTime, serializedChannels.count / deserializeTime);
        
        NSLog(@"✅ [CACHE] Successfully loaded %lu channels from cache", (unsigned long)channels.count);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion([channels copy], YES, nil);
            }
        });
    }
}

- (void)saveEPGToCache:(NSDictionary *)epgData
             sourceURL:(NSString *)sourceURL
            completion:(VLCCacheCompletion)completion {
    
    if (!epgData || epgData.count == 0) {
        NSLog(@"⚠️ [CACHE] No EPG data to save");
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                               code:3007 
                                           userInfo:@{NSLocalizedDescriptionKey: @"No EPG data to save"}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performEPGCacheSave:epgData sourceURL:sourceURL completion:completion];
    });
}

- (void)performEPGCacheSave:(NSDictionary *)epgData
                  sourceURL:(NSString *)sourceURL
                 completion:(VLCCacheCompletion)completion {
    
    @autoreleasepool {
        NSLog(@"💾 [CACHE] Saving EPG data to cache (%lu channels)", (unsigned long)epgData.count);
        
        // Create cache dictionary
        NSMutableDictionary *cacheDict = [[NSMutableDictionary alloc] init];
        [cacheDict setObject:@"1.0" forKey:@"epgCacheVersion"];
        [cacheDict setObject:[NSDate date] forKey:@"epgCacheDate"];
        [cacheDict setObject:(sourceURL ?: @"") forKey:@"sourceURL"];
        
        // Serialize EPG data efficiently
        NSMutableDictionary *serializedEPGData = [[NSMutableDictionary alloc] init];
        NSUInteger totalPrograms = 0;
        
        for (NSString *channelId in epgData) {
            @autoreleasepool {
                NSArray *programs = [epgData objectForKey:channelId];
                if ([programs isKindOfClass:[NSArray class]]) {
                    NSMutableArray *serializedPrograms = [[NSMutableArray alloc] init];
                    
                    for (id program in programs) {
                        NSDictionary *serializedProgram = [self serializeProgram:program];
                        if (serializedProgram) {
                            [serializedPrograms addObject:serializedProgram];
                            totalPrograms++;
                        }
                    }
                    
                    [serializedEPGData setObject:serializedPrograms forKey:channelId];
                }
            }
        }
        
        [cacheDict setObject:serializedEPGData forKey:@"epgData"];
        
        // Write to cache file  
        NSString *cacheFilePath = [self cacheFilePathForType:VLCCacheTypeEPG sourceURL:sourceURL];
        
        // SAFETY: Ensure directory exists before writing (in case background creation hasn't completed)
        [self createDirectoryIfNeeded:self.epgCacheDirectory];
        
        BOOL success = [cacheDict writeToFile:cacheFilePath atomically:YES];
        
        if (success) {
            NSLog(@"✅ [CACHE] Successfully saved EPG cache with %lu programs to %@", 
                  (unsigned long)totalPrograms, cacheFilePath);
            [self updateCacheSizes];
        } else {
            NSLog(@"❌ [CACHE] Failed to save EPG cache");
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success, success ? nil : [NSError errorWithDomain:@"VLCCacheManager" 
                                                                        code:3008 
                                                                    userInfo:@{NSLocalizedDescriptionKey: @"Failed to write EPG cache file"}]);
            }
        });
    }
}

- (void)loadEPGFromCache:(NSString *)sourceURL
              completion:(VLCCacheLoadCompletion)completion {
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performEPGCacheLoad:sourceURL completion:completion];
    });
}

- (void)performEPGCacheLoad:(NSString *)sourceURL
                 completion:(VLCCacheLoadCompletion)completion {
    
    @autoreleasepool {
        NSString *cacheFilePath = [self cacheFilePathForType:VLCCacheTypeEPG sourceURL:sourceURL];
        
        if (![self fileExistsAtPath:cacheFilePath]) {
            NSLog(@"💾 [CACHE] No EPG cache file found: %@", cacheFilePath);
            NSLog(@"💾 [CACHE] Expected EPG cache path for URL '%@': %@", sourceURL, cacheFilePath);
            
            // List files in EPG cache directory to help debug
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSArray *epgFiles = [fileManager contentsOfDirectoryAtPath:self.epgCacheDirectory error:nil];
            NSLog(@"💾 [CACHE] Available EPG cache files: %@", epgFiles);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                                            code:3009 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"EPG cache file not found"}]);
                }
            });
            return;
        }
        
        // Check cache validity
        if (![self isEPGCacheValid:sourceURL]) {
            NSDate *cacheDate = [self cacheDate:VLCCacheTypeEPG sourceURL:sourceURL];
            NSTimeInterval timeSinceCache = cacheDate ? [[NSDate date] timeIntervalSinceDate:cacheDate] : -1;
            NSTimeInterval validityHours = self.epgCacheValidityHours;
            
            NSLog(@"💾 [CACHE] EPG cache is expired - Cache date: %@, Hours since cache: %.1f, Validity: %.1f hours", 
                  cacheDate, timeSinceCache / 3600.0, validityHours);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                                            code:3010 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"EPG cache is expired"}]);
                }
            });
            return;
        }
        
        // Load cache file
        NSDictionary *cacheDict = [NSDictionary dictionaryWithContentsOfFile:cacheFilePath];
        if (!cacheDict) {
            NSLog(@"❌ [CACHE] Failed to load EPG cache from %@", cacheFilePath);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                                            code:3011 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Failed to read EPG cache file"}]);
                }
            });
            return;
        }
        
        // Get EPG data
        NSDictionary *epgData = [cacheDict objectForKey:@"epgData"];
        if (!epgData) {
            NSLog(@"❌ [CACHE] No EPG data in cache");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(nil, NO, [NSError errorWithDomain:@"VLCCacheManager" 
                                                            code:3012 
                                                        userInfo:@{NSLocalizedDescriptionKey: @"No EPG data in cache"}]);
                }
            });
            return;
        }
        
        NSLog(@"✅ [CACHE] Successfully loaded EPG data from cache (%lu channels)", (unsigned long)epgData.count);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(epgData, YES, nil);
            }
        });
    }
}

#pragma mark - Cache Validation

- (BOOL)isChannelCacheValid:(NSString *)sourceURL {
    NSDate *cacheDate = [self cacheDate:VLCCacheTypeChannels sourceURL:sourceURL];
    if (!cacheDate) return NO;
    
    NSTimeInterval timeSinceCache = [[NSDate date] timeIntervalSinceDate:cacheDate];
    NSTimeInterval validitySeconds = self.channelCacheValidityHours * 3600.0;
    
    return timeSinceCache <= validitySeconds;
}

- (BOOL)isEPGCacheValid:(NSString *)sourceURL {
    NSDate *cacheDate = [self cacheDate:VLCCacheTypeEPG sourceURL:sourceURL];
    if (!cacheDate) return NO;
    
    NSTimeInterval timeSinceCache = [[NSDate date] timeIntervalSinceDate:cacheDate];
    NSTimeInterval validitySeconds = self.epgCacheValidityHours * 3600.0;
    
    return timeSinceCache <= validitySeconds;
}

- (NSDate *)cacheDate:(VLCCacheType)cacheType sourceURL:(NSString *)sourceURL {
    NSString *cacheFilePath = [self cacheFilePathForType:cacheType sourceURL:sourceURL];
    if (![self fileExistsAtPath:cacheFilePath]) return nil;
    
    NSDictionary *cacheDict = [NSDictionary dictionaryWithContentsOfFile:cacheFilePath];
    if (!cacheDict) return nil;
    
    NSString *dateKey = (cacheType == VLCCacheTypeEPG) ? @"epgCacheDate" : @"cacheDate";
    return [cacheDict objectForKey:dateKey];
}

#pragma mark - Cache File Management

- (NSString *)cacheFilePathForType:(VLCCacheType)cacheType sourceURL:(NSString *)sourceURL {
    NSString *baseDirectory = nil;
    NSString *filePrefix = nil;
    
    switch (cacheType) {
        case VLCCacheTypeChannels:
            baseDirectory = self.channelCacheDirectory;
            filePrefix = @"channels";
            break;
        case VLCCacheTypeEPG:
            baseDirectory = self.epgCacheDirectory;
            filePrefix = @"epg";
            break;
        case VLCCacheTypeSettings:
            baseDirectory = self.cacheDirectory ?: self.channelCacheDirectory;
            filePrefix = @"settings";
            break;
        case VLCCacheTypeTimeshift:
            baseDirectory = self.cacheDirectory ?: self.channelCacheDirectory;
            filePrefix = @"timeshift";
            break;
    }
    
    // SAFETY: Handle case where directories haven't been initialized yet
    if (!baseDirectory) {
        NSLog(@"⚠️ [CACHE] Directory not initialized yet for cache type %ld - using fallback", (long)cacheType);
        // Use a synchronous fallback for immediate operations
        if (cacheType == VLCCacheTypeChannels) {
            baseDirectory = [[self cachesDirectory] stringByAppendingPathComponent:@"ChannelCache"];
        } else {
            baseDirectory = [[self documentsDirectory] stringByAppendingPathComponent:@"EPGCache"];
        }
        [self createDirectoryIfNeeded:baseDirectory];
    }
    
    NSString *fileName = [self sanitizedCacheFileName:sourceURL];
    NSString *fullFileName = [NSString stringWithFormat:@"%@_%@.plist", filePrefix, fileName];
    
    return [baseDirectory stringByAppendingPathComponent:fullFileName];
}

- (NSString *)sanitizedCacheFileName:(NSString *)sourceURL {
    // Always use "default" for consistency with existing cache files
    // This ensures cache files are found regardless of URL complexity
    return @"default";
}

- (NSString *)md5HashForString:(NSString *)string {
    const char *cStr = [string UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
    
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [result appendFormat:@"%02x", digest[i]];
    }
    
    return result;
}

#pragma mark - Cache Maintenance

- (void)clearCache:(VLCCacheType)cacheType completion:(VLCCacheCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *cacheDirectory = nil;
        
        switch (cacheType) {
            case VLCCacheTypeChannels:
                cacheDirectory = self.channelCacheDirectory;
                break;
            case VLCCacheTypeEPG:
                cacheDirectory = self.epgCacheDirectory;
                break;
            default:
                cacheDirectory = self.cacheDirectory ?: self.channelCacheDirectory;
                break;
        }
        
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSError *error = nil;
        NSArray *files = [fileManager contentsOfDirectoryAtPath:cacheDirectory error:&error];
        
        BOOL success = YES;
        NSInteger clearedFiles = 0;
        
        if (!error && files) {
            for (NSString *file in files) {
                NSString *filePath = [cacheDirectory stringByAppendingPathComponent:file];
                if ([fileManager removeItemAtPath:filePath error:nil]) {
                    clearedFiles++;
                } else {
                    success = NO;
                }
            }
        }
        
        NSLog(@"💾 [CACHE] Cleared %ld files from cache type %ld", (long)clearedFiles, (long)cacheType);
        
        [self updateCacheSizes];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(success, error);
            }
        });
    });
}

- (void)clearAllCaches:(VLCCacheCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Clear all cache types
        dispatch_group_t group = dispatch_group_create();
        __block BOOL overallSuccess = YES;
        __block NSError *overallError = nil;
        
        for (NSInteger cacheType = VLCCacheTypeChannels; cacheType <= VLCCacheTypeTimeshift; cacheType++) {
            dispatch_group_enter(group);
            [self clearCache:(VLCCacheType)cacheType completion:^(BOOL success, NSError *error) {
                if (!success) {
                    overallSuccess = NO;
                    overallError = error;
                }
                dispatch_group_leave(group);
            }];
        }
        
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSLog(@"💾 [CACHE] Cleared all caches - success: %d", overallSuccess);
            if (completion) {
                completion(overallSuccess, overallError);
            }
        });
    });
}

#pragma mark - Memory Management

- (void)performMemoryOptimization {
    NSLog(@"🧹 [CACHE] Performing memory optimization");
    
    // Clear expired caches
    [self clearExpiredCaches:nil];
    
    // Clear oversized caches if needed
    if (self.internalTotalCacheSizeBytes > (self.maxCacheSizeMB * 1024 * 1024)) {
        [self clearOversizedCaches];
    }
}

- (void)clearExpiredCaches:(VLCCacheCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSInteger clearedFiles = 0;
        
        // Check each cache directory
        NSArray *cacheDirectories = @[self.channelCacheDirectory, self.epgCacheDirectory];
        
        for (NSString *directory in cacheDirectories) {
            if (!directory) continue;
            
            NSError *error = nil;
            NSArray *files = [fileManager contentsOfDirectoryAtPath:directory error:&error];
            if (error || !files) continue;
            
            for (NSString *file in files) {
                NSString *filePath = [directory stringByAppendingPathComponent:file];
                
                // Check file age
                NSDictionary *attributes = [fileManager attributesOfItemAtPath:filePath error:nil];
                NSDate *modificationDate = [attributes fileModificationDate];
                
                if (modificationDate) {
                    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:modificationDate];
                    NSTimeInterval maxAge = 7 * 24 * 3600; // 7 days
                    
                    if (age > maxAge) {
                        if ([fileManager removeItemAtPath:filePath error:nil]) {
                            clearedFiles++;
                        }
                    }
                }
            }
        }
        
        NSLog(@"💾 [CACHE] Cleared %ld expired cache files", (long)clearedFiles);
        
        [self updateCacheSizes];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(YES, nil);
            }
        });
    });
}

- (void)clearOversizedCaches {
    NSLog(@"🧹 [CACHE] Clearing oversized caches");
    
    // Clear largest caches first
    [self clearCache:VLCCacheTypeChannels completion:nil];
}

- (BOOL)isCacheOversized:(NSString *)sourceURL {
    NSString *channelCachePath = [self cacheFilePathForType:VLCCacheTypeChannels sourceURL:sourceURL];
    NSUInteger fileSize = [self fileSizeAtPath:channelCachePath];
    
    // Consider cache oversized if single file > 100MB
    return fileSize > (100 * 1024 * 1024);
}

#pragma mark - Cache Statistics

- (void)updateCacheSizes {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSUInteger totalSize = 0;
        NSMutableDictionary *sizesByType = [[NSMutableDictionary alloc] init];
        
        // Calculate sizes for each cache type
        NSArray *cacheDirectories = @[
            @{@"directory": self.channelCacheDirectory ?: @"", @"type": @(VLCCacheTypeChannels)},
            @{@"directory": self.epgCacheDirectory ?: @"", @"type": @(VLCCacheTypeEPG)}
        ];
        
        for (NSDictionary *info in cacheDirectories) {
            NSString *directory = info[@"directory"];
            NSNumber *type = info[@"type"];
            
            if (directory.length == 0) continue;
            
            NSUInteger directorySize = [self calculateDirectorySize:directory];
            totalSize += directorySize;
            [sizesByType setObject:@(directorySize) forKey:type];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.internalTotalCacheSizeBytes = totalSize;
            self.internalCacheSizesByType = sizesByType;
        });
    });
}

- (NSUInteger)calculateDirectorySize:(NSString *)directoryPath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fileManager contentsOfDirectoryAtPath:directoryPath error:&error];
    if (error || !files) return 0;
    
    NSUInteger totalSize = 0;
    for (NSString *file in files) {
        NSString *filePath = [directoryPath stringByAppendingPathComponent:file];
        totalSize += [self fileSizeAtPath:filePath];
    }
    
    return totalSize;
}

#pragma mark - Serialization

- (NSDictionary *)serializeChannel:(VLCChannel *)channel {
    if (!channel) return nil;
    
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    
    if (channel.name) [dict setObject:channel.name forKey:@"name"];
    if (channel.url) [dict setObject:channel.url forKey:@"url"];
    if (channel.group) [dict setObject:channel.group forKey:@"group"];
    if (channel.logo) [dict setObject:channel.logo forKey:@"logo"];
    if (channel.channelId) [dict setObject:channel.channelId forKey:@"channelId"];
    if (channel.category) [dict setObject:channel.category forKey:@"category"];
    
    // Timeshift properties
    [dict setObject:@(channel.supportsCatchup) forKey:@"supportsCatchup"];
    if (channel.catchupDays > 0) [dict setObject:@(channel.catchupDays) forKey:@"catchupDays"];
    if (channel.catchupSource) [dict setObject:channel.catchupSource forKey:@"catchupSource"];
    if (channel.catchupTemplate) [dict setObject:channel.catchupTemplate forKey:@"catchupTemplate"];
    
    return dict;
}

- (VLCChannel *)deserializeChannel:(NSDictionary *)dict {
    if (!dict) return nil;
    
    VLCChannel *channel = [[VLCChannel alloc] init];
    
    channel.name = [dict objectForKey:@"name"];
    channel.url = [dict objectForKey:@"url"];
    channel.group = [dict objectForKey:@"group"];
    channel.logo = [dict objectForKey:@"logo"];
    channel.channelId = [dict objectForKey:@"channelId"];
    channel.category = [dict objectForKey:@"category"];
    
    // Timeshift properties
    channel.supportsCatchup = [[dict objectForKey:@"supportsCatchup"] boolValue];
    channel.catchupDays = [[dict objectForKey:@"catchupDays"] integerValue];
    channel.catchupSource = [dict objectForKey:@"catchupSource"];
    channel.catchupTemplate = [dict objectForKey:@"catchupTemplate"];
    
    // Initialize programs array
    channel.programs = [[NSMutableArray alloc] init];
    
    return channel;
}

- (NSDictionary *)serializeProgram:(id)program {
    // Assume program has properties: title, description, startTime, endTime, channelId, hasArchive, archiveDays
    if (!program) return nil;
    
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    
    // Use KVC to access properties safely
    @try {
        id title = [program valueForKey:@"title"];
        if (title) [dict setObject:title forKey:@"title"];
        
        id description = [program valueForKey:@"programDescription"];
        if (description) [dict setObject:description forKey:@"description"];
        
        id startTime = [program valueForKey:@"startTime"];
        if (startTime) [dict setObject:startTime forKey:@"startTime"];
        
        id endTime = [program valueForKey:@"endTime"];
        if (endTime) [dict setObject:endTime forKey:@"endTime"];
        
        id channelId = [program valueForKey:@"channelId"];
        if (channelId) [dict setObject:channelId forKey:@"channelId"];
        
        // Check if program responds to hasArchive before accessing it
        if ([program respondsToSelector:@selector(hasArchive)]) {
            id hasArchive = [program valueForKey:@"hasArchive"];
            if (hasArchive) [dict setObject:hasArchive forKey:@"hasArchive"];
        } else if ([program isKindOfClass:[NSDictionary class]]) {
            // If program is a dictionary, access directly
            id hasArchive = [(NSDictionary *)program objectForKey:@"hasArchive"];
            if (hasArchive) [dict setObject:hasArchive forKey:@"hasArchive"];
        }
        
        id archiveDays = [program valueForKey:@"archiveDays"];
        if (archiveDays) [dict setObject:archiveDays forKey:@"archiveDays"];
    }
    @catch (NSException *exception) {
        NSLog(@"⚠️ [CACHE] Error serializing program: %@", exception.reason);
        return nil;
    }
    
    return dict;
}

#pragma mark - Platform-specific Paths

- (NSString *)applicationSupportDirectory {
#if TARGET_OS_IOS || TARGET_OS_TV
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *appSupportDir = [paths firstObject];
    
    if (!appSupportDir) {
        // Fallback to Documents directory
        return [self documentsDirectory];
    }
    
    // Create app-specific subdirectory
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"] ?: @"BasicIPTV";
    return [appSupportDir stringByAppendingPathComponent:appName];
#else
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    return [paths firstObject];
#endif
}

- (NSString *)cachesDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths firstObject];
}

- (NSString *)documentsDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [paths firstObject];
}

#pragma mark - Utility Methods

- (BOOL)createDirectoryIfNeeded:(NSString *)directoryPath {
    if (!directoryPath) return NO;
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    
    if ([fileManager fileExistsAtPath:directoryPath isDirectory:&isDirectory]) {
        return isDirectory;
    }
    
    NSError *error = nil;
    BOOL success = [fileManager createDirectoryAtPath:directoryPath 
                          withIntermediateDirectories:YES 
                                           attributes:nil 
                                                error:&error];
    
    if (!success) {
        NSLog(@"❌ [CACHE] Failed to create directory %@: %@", directoryPath, error.localizedDescription);
    }
    
    return success;
}

- (BOOL)fileExistsAtPath:(NSString *)path {
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (NSUInteger)fileSizeAtPath:(NSString *)path {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&error];
    
    if (error || !attributes) return 0;
    
    NSNumber *fileSize = [attributes objectForKey:NSFileSize];
    return [fileSize unsignedIntegerValue];
}

- (BOOL)removeFileAtPath:(NSString *)path {
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
    
    if (!success) {
        NSLog(@"❌ [CACHE] Failed to remove file %@: %@", path, error.localizedDescription);
    }
    
    return success;
}

@end 