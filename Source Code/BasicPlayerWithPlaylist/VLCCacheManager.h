//
//  VLCCacheManager.h
//  BasicPlayerWithPlaylist
//
//  Universal Cache Manager - Platform Independent
//  Handles caching for channels, EPG, and settings across all platforms
//

#import <Foundation/Foundation.h>

@class VLCChannel;

NS_ASSUME_NONNULL_BEGIN

// Cache types
typedef NS_ENUM(NSInteger, VLCCacheType) {
    VLCCacheTypeChannels,
    VLCCacheTypeEPG,
    VLCCacheTypeSettings,
    VLCCacheTypeTimeshift
};

// Cache completion blocks
typedef void (^VLCCacheCompletion)(BOOL success, NSError * _Nullable error);
typedef void (^VLCCacheLoadCompletion)(id _Nullable data, BOOL success, NSError * _Nullable error);

@interface VLCCacheManager : NSObject

// Configuration
@property (nonatomic, assign) NSTimeInterval channelCacheValidityHours; // Default: 24 hours
@property (nonatomic, assign) NSTimeInterval epgCacheValidityHours; // Default: 6 hours
@property (nonatomic, assign) NSUInteger maxCacheSizeMB; // Default: 500MB
@property (nonatomic, assign) BOOL enableMemoryOptimization; // Default: YES

// Cache status
@property (nonatomic, readonly) NSUInteger totalCacheSizeBytes;
@property (nonatomic, readonly) NSDictionary<NSNumber *, NSNumber *> *cacheSizesByType;

// Main cache operations
- (void)saveChannelsToCache:(NSArray<VLCChannel *> *)channels
                  sourceURL:(NSString *)sourceURL
                 completion:(VLCCacheCompletion _Nullable)completion;

- (void)loadChannelsFromCache:(NSString *)sourceURL
                   completion:(VLCCacheLoadCompletion)completion;

- (void)saveEPGToCache:(NSDictionary *)epgData
             sourceURL:(NSString *)sourceURL
            completion:(VLCCacheCompletion _Nullable)completion;

- (void)loadEPGFromCache:(NSString *)sourceURL
              completion:(VLCCacheLoadCompletion)completion;

// Cache validation
- (BOOL)isChannelCacheValid:(NSString *)sourceURL;
- (BOOL)isEPGCacheValid:(NSString *)sourceURL;
- (NSDate * _Nullable)cacheDate:(VLCCacheType)cacheType sourceURL:(NSString *)sourceURL;

// Cache file management
- (NSString *)cacheFilePathForType:(VLCCacheType)cacheType sourceURL:(NSString *)sourceURL;
- (NSString *)sanitizedCacheFileName:(NSString *)sourceURL;
- (NSString *)md5HashForString:(NSString *)string;

// Cache maintenance
- (void)clearCache:(VLCCacheType)cacheType completion:(VLCCacheCompletion _Nullable)completion;
- (void)clearAllCaches:(VLCCacheCompletion _Nullable)completion;
- (void)clearExpiredCaches:(VLCCacheCompletion _Nullable)completion;

// Memory management
- (void)performMemoryOptimization;
- (BOOL)isCacheOversized:(NSString *)sourceURL;
- (void)clearOversizedCaches;

// Cache statistics
- (NSDictionary *)cacheStatistics;
- (NSUInteger)cacheSizeForType:(VLCCacheType)cacheType;
- (NSArray<NSString *> *)allCacheFiles;

// Platform-specific paths
- (NSString *)applicationSupportDirectory;
- (NSString *)cachesDirectory;
- (NSString *)documentsDirectory;

// Utility methods
- (BOOL)createDirectoryIfNeeded:(NSString *)directoryPath;
- (BOOL)fileExistsAtPath:(NSString *)path;
- (NSUInteger)fileSizeAtPath:(NSString *)path;
- (BOOL)removeFileAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END 