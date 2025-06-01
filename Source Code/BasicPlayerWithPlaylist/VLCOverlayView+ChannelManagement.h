#import "VLCOverlayView.h"

@class VLCChannel;

@interface VLCOverlayView (ChannelManagement)

// Channel loading methods
- (void)loadChannelsFile;
- (void)loadChannelsFromM3uFile:(NSString *)path;
- (void)loadLargeM3uFileInChunks:(NSString *)path fileSize:(unsigned long long)fileSize;
- (void)loadChannelsFromM3uURL:(NSURL *)url;
- (void)loadMultipleURLs;

// Channel processing
- (void)processM3uLine:(NSMutableString *)line 
              isExtInf:(BOOL *)isReadingExtInf 
          currentExtInf:(NSMutableDictionary *)currentExtInfo
                 groups:(NSMutableArray *)groups 
              channels:(NSMutableArray *)channels 
       channelsByGroup:(NSMutableDictionary *)channelsByGroup 
      groupsByCategory:(NSMutableDictionary *)groupsByCategory;

// Channel playback
- (void)playChannel:(NSInteger)index;
- (void)playSimpleChannel:(NSInteger)index;
- (void)playChannelWithUrl:(NSString *)url;
- (void)saveLastPlayedChannelUrl:(NSString *)urlString;
- (NSString *)getLastPlayedChannelUrl;

// Early startup functionality
- (void)startEarlyPlaybackIfAvailable;
- (void)saveLastPlayedContentInfo:(VLCChannel *)channel;
- (NSDictionary *)getLastPlayedContentInfo;
- (void)populatePlayerControlsWithCachedInfo:(NSDictionary *)cachedInfo;

// Startup policy helper methods
- (NSString *)findOriginalChannelUrlFromTimeshiftUrl:(NSString *)timeshiftUrl;
- (void)updateCachedInfoToLiveChannel:(NSString *)originalChannelName liveUrl:(NSString *)liveUrl;

// Resume functionality
- (void)saveCurrentPlaybackPosition;
- (void)resumePlaybackPositionForURL:(NSString *)urlString;
- (void)savePlaybackPosition:(NSTimeInterval)position forURL:(NSString *)urlString;
- (NSTimeInterval)getSavedPlaybackPositionForURL:(NSString *)urlString;

// Settings
- (void)saveSettings;
- (void)loadSettings;
- (NSString *)generateEpgUrlFromPlaylistUrl:(NSString *)playlistUrl;

// Movie info methods
- (NSString *)extractMovieIdFromUrl:(NSString *)url;
- (void)fetchMovieInfoForChannel:(VLCChannel *)channel;
- (NSString *)constructMovieApiUrlForChannel:(VLCChannel *)channel;
- (void)preloadAllMovieInfoAndCovers;
- (void)forceRefreshAllMovieInfoAndCovers;
- (void)startMovieInfoRefresh;

@end 