//
//  VLCChannelManager.h
//  BasicPlayerWithPlaylist
//
//  Universal Channel Manager - Platform Independent
//  Handles M3U parsing, channel organization, and timeshift detection
//

#import <Foundation/Foundation.h>

@class VLCChannel;
@class VLCCacheManager;

NS_ASSUME_NONNULL_BEGIN

// Channel loading completion blocks
typedef void (^VLCChannelLoadCompletion)(NSArray<VLCChannel *> * _Nullable channels, NSError * _Nullable error);
typedef void (^VLCChannelProgressBlock)(float progress, NSString *status);

@interface VLCChannelManager : NSObject

// Dependencies (injected for testability)
@property (nonatomic, weak) VLCCacheManager *cacheManager;

// Current state
@property (nonatomic, readonly) NSArray<VLCChannel *> *channels;
@property (nonatomic, readonly) NSArray<NSString *> *groups;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<VLCChannel *> *> *channelsByGroup;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<NSString *> *> *groupsByCategory;
@property (nonatomic, readonly) NSArray<NSString *> *categories;

// Loading state
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) float progress;
@property (nonatomic, readonly) NSString *currentStatus;

// Memory optimization settings
@property (nonatomic, assign) NSUInteger maxChannelsPerGroup;
@property (nonatomic, assign) NSUInteger maxTotalChannels;
@property (nonatomic, assign) BOOL enableMemoryOptimization;

// Main operations
- (void)loadChannelsFromURL:(NSString *)m3uURL 
                 completion:(VLCChannelLoadCompletion)completion
                   progress:(VLCChannelProgressBlock _Nullable)progressBlock;

- (void)loadChannelsFromCache:(NSString *)sourceURL
                   completion:(VLCChannelLoadCompletion)completion;

- (void)loadChannelsFromCacheWithProgress:(NSString *)sourceURL
                               completion:(VLCChannelLoadCompletion)completion
                                 progress:(VLCChannelProgressBlock _Nullable)progressBlock;

- (void)parseM3UContent:(NSString *)content
             completion:(VLCChannelLoadCompletion)completion
               progress:(VLCChannelProgressBlock _Nullable)progressBlock;

// Data organization
- (void)organizeChannelsIntoCategories;
- (NSString *)determineCategoryForGroup:(NSString *)groupName;
- (NSString *)determineCategoryForChannel:(VLCChannel *)channel;
- (BOOL)isMovieURL:(NSString *)urlString;

// Channel access helpers  
- (VLCChannel * _Nullable)channelAtIndex:(NSInteger)index;
- (NSArray<VLCChannel *> * _Nullable)channelsInGroup:(NSString *)groupName;
- (NSArray<NSString *> * _Nullable)groupsInCategory:(NSString *)categoryName;
- (NSInteger)indexOfChannel:(VLCChannel *)channel;

// Search functionality
- (NSArray<VLCChannel *> *)searchChannels:(NSString *)query;
- (NSArray<VLCChannel *> *)favoriteChannels;

// Data management
- (void)clearAllChannels;
- (void)updateChannelsData:(NSArray<VLCChannel *> *)channels 
                    groups:(NSArray<NSString *> *)groups
           channelsByGroup:(NSDictionary<NSString *, NSArray<VLCChannel *> *> *)channelsByGroup
          groupsByCategory:(NSDictionary<NSString *, NSArray<NSString *> *> *)groupsByCategory;

// Memory management
- (NSUInteger)estimatedMemoryUsage;
- (void)performMemoryOptimization;

// Utility methods
- (NSString *)sanitizeChannelName:(NSString *)name;
- (NSString *)extractLogoURL:(NSString *)extinfLine;
- (NSString *)extractChannelID:(NSString *)extinfLine;

@end

NS_ASSUME_NONNULL_END 