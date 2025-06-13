//
//  VLCEPGManager.h
//  BasicPlayerWithPlaylist
//
//  Universal EPG Manager - Platform Independent
//  Handles EPG fetching, parsing, caching, and program matching
//

#import <Foundation/Foundation.h>

@class VLCChannel;
@class VLCProgram;
@class VLCCacheManager;

NS_ASSUME_NONNULL_BEGIN

// EPG loading completion blocks
typedef void (^VLCEPGLoadCompletion)(NSDictionary * _Nullable epgData, NSError * _Nullable error);
typedef void (^VLCEPGProgressBlock)(float progress, NSString *status);

@interface VLCEPGManager : NSObject

// Dependencies
@property (nonatomic, weak) VLCCacheManager *cacheManager;

// Current state
@property (nonatomic, readonly) NSDictionary *epgData;
@property (nonatomic, readonly) BOOL isLoaded;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) float progress;
@property (nonatomic, readonly) NSString *currentStatus;

// Configuration
@property (nonatomic, assign) NSTimeInterval timeOffsetHours;
@property (nonatomic, assign) NSTimeInterval cacheValidityHours; // Default: 6 hours

// Main operations
- (void)loadEPGFromURL:(NSString *)epgURL
            completion:(VLCEPGLoadCompletion)completion
              progress:(VLCEPGProgressBlock _Nullable)progressBlock;

- (void)loadEPGFromCache:(NSString *)sourceURL
              completion:(VLCEPGLoadCompletion)completion;

- (void)forceReloadEPGFromURL:(NSString *)epgURL
                   completion:(VLCEPGLoadCompletion)completion
                     progress:(VLCEPGProgressBlock _Nullable)progressBlock;

// EPG processing
- (void)parseEPGXMLData:(NSData *)xmlData
             completion:(VLCEPGLoadCompletion)completion
               progress:(VLCEPGProgressBlock _Nullable)progressBlock;

- (void)matchEPGWithChannels:(NSArray<VLCChannel *> *)channels;

// Program access
- (VLCProgram * _Nullable)currentProgramForChannel:(VLCChannel *)channel;
- (NSArray<VLCProgram *> * _Nullable)programsForChannel:(VLCChannel *)channel;
- (NSArray<VLCProgram *> * _Nullable)programsForChannelID:(NSString *)channelID;

// Program queries
- (VLCProgram * _Nullable)programAtTime:(NSDate *)time forChannel:(VLCChannel *)channel;
- (NSArray<VLCProgram *> *)programsInTimeRange:(NSDate *)startTime 
                                       endTime:(NSDate *)endTime 
                                    forChannel:(VLCChannel *)channel;

// Time utilities (with offset support)
- (NSDate *)adjustedCurrentTime;
- (NSDate *)adjustTimeForDisplay:(NSDate *)time;
- (NSDate *)adjustTimeForServer:(NSDate *)time;

// Data management
- (void)clearEPGData;
- (void)updateEPGData:(NSDictionary *)epgData;

// Memory management
- (NSUInteger)estimatedMemoryUsage;
- (void)performMemoryOptimization;

// Cache management
- (BOOL)isCacheValid:(NSString *)sourceURL;
- (void)saveCacheTimestamp;

// Utility methods
- (NSString *)sanitizeProgramTitle:(NSString *)title;
- (NSString *)formatTimeRange:(VLCProgram *)program;
- (NSTimeInterval)programDuration:(VLCProgram *)program;

@end

NS_ASSUME_NONNULL_END 