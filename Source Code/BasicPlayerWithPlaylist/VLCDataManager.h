//
//  VLCDataManager.h
//  BasicPlayerWithPlaylist
//
//  Universal Data Manager - Platform Independent
//  Coordinates all data operations across macOS, iOS, and tvOS
//

#import <Foundation/Foundation.h>

@class VLCChannelManager;
@class VLCEPGManager;
@class VLCTimeshiftManager;
@class VLCCacheManager;
@class VLCChannel;
@class VLCProgram;

NS_ASSUME_NONNULL_BEGIN

// Delegate protocol for data updates
@protocol VLCDataManagerDelegate <NSObject>
@optional
- (void)dataManagerDidStartLoading:(NSString *)operation;
- (void)dataManagerDidUpdateProgress:(float)progress operation:(NSString *)operation;
- (void)dataManagerDidFinishLoading:(NSString *)operation success:(BOOL)success;
- (void)dataManagerDidUpdateChannels:(NSArray<VLCChannel *> *)channels;
- (void)dataManagerDidUpdateEPG:(NSDictionary *)epgData;
- (void)dataManagerDidDetectTimeshift:(NSInteger)timeshiftChannelCount;
- (void)dataManagerDidEncounterError:(NSError *)error operation:(NSString *)operation;
@end

@interface VLCDataManager : NSObject

// Singleton instance
+ (instancetype)sharedManager;

// Delegate for UI updates
@property (nonatomic, weak) id<VLCDataManagerDelegate> delegate;

// Sub-managers (memory efficient - lazy loaded)
@property (nonatomic, readonly) VLCChannelManager *channelManager;
@property (nonatomic, readonly) VLCEPGManager *epgManager;
@property (nonatomic, readonly) VLCTimeshiftManager *timeshiftManager;
@property (nonatomic, readonly) VLCCacheManager *cacheManager;

// Current data state (readonly for external access)
@property (nonatomic, readonly) NSArray<VLCChannel *> *channels;
@property (nonatomic, readonly) NSArray<NSString *> *groups;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<VLCChannel *> *> *channelsByGroup;
@property (nonatomic, readonly) NSDictionary<NSString *, NSArray<NSString *> *> *groupsByCategory;
@property (nonatomic, readonly) NSArray<NSString *> *categories;
@property (nonatomic, readonly) NSDictionary *epgData;

// Loading states
@property (nonatomic, readonly) BOOL isLoadingChannels;
@property (nonatomic, readonly) BOOL isLoadingEPG;
@property (nonatomic, readonly) BOOL isEPGLoaded;
@property (nonatomic, readonly) float channelLoadingProgress;
@property (nonatomic, readonly) float epgLoadingProgress;

// Configuration
@property (nonatomic, strong) NSString *m3uURL;
@property (nonatomic, strong) NSString *epgURL;
@property (nonatomic, assign) NSTimeInterval epgTimeOffsetHours;

// High-level operations
- (void)loadChannelsFromURL:(NSString *)m3uURL;
- (void)loadEPGFromURL:(NSString *)epgURL;
- (void)forceReloadChannels;
- (void)forceReloadEPG;
- (void)detectTimeshiftSupport;

// Cache operations
- (void)updateDataStructuresWithChannels:(NSArray<VLCChannel *> *)channels;

// Data access helpers
- (VLCChannel * _Nullable)channelAtIndex:(NSInteger)index;
- (NSArray<VLCChannel *> * _Nullable)channelsInGroup:(NSString *)groupName;
- (NSArray<NSString *> * _Nullable)groupsInCategory:(NSString *)categoryName;
- (VLCProgram * _Nullable)currentProgramForChannel:(VLCChannel *)channel;
- (NSArray<VLCProgram *> * _Nullable)programsForChannel:(VLCChannel *)channel;

// Memory management
- (void)clearAllData;
- (void)clearChannelData;
- (void)clearEPGData;
- (NSUInteger)memoryUsageInBytes;

@end

NS_ASSUME_NONNULL_END 