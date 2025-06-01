#import "VLCOverlayView.h"

@interface VLCOverlayView (Caching)

// Channel cache methods
- (NSString *)channelCacheFilePath:(NSString *)sourcePath;
- (BOOL)saveChannelsToCache:(NSString *)sourcePath;
- (BOOL)saveChannelsToCache:(NSString *)sourcePath 
                   channels:(NSArray *)channels 
                     groups:(NSArray *)groups
            channelsByGroup:(NSDictionary *)channelsByGroup
           groupsByCategory:(NSDictionary *)groupsByCategory;
- (BOOL)loadChannelsFromCache:(NSString *)sourcePath;
- (BOOL)cacheChannelsToFile:(NSString *)sourcePath;

// EPG cache methods
- (NSString *)epgCacheFilePath;
- (void)saveEpgDataToCache;
- (void)saveEpgDataToCache_implementation;

@end 