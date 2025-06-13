//
//  VLCTimeshiftManager.h
//  BasicPlayerWithPlaylist
//
//  Universal Timeshift Manager - Platform Independent
//  Handles timeshift/catchup detection, API fetching, and URL generation
//

#import <Foundation/Foundation.h>

@class VLCChannel;
@class VLCProgram;

NS_ASSUME_NONNULL_BEGIN

// Timeshift detection completion blocks
typedef void (^VLCTimeshiftDetectionCompletion)(NSInteger detectedChannels, NSError * _Nullable error);
typedef void (^VLCTimeshiftAPICompletion)(NSInteger updatedChannels, NSError * _Nullable error);

@interface VLCTimeshiftManager : NSObject

// Current state
@property (nonatomic, readonly) NSInteger timeshiftChannelCount;
@property (nonatomic, readonly) BOOL isDetecting;
@property (nonatomic, readonly) BOOL hasAPISupport;

// Configuration
@property (nonatomic, assign) float minimumCatchupPercentage; // Default: 0.1 (10%)
@property (nonatomic, assign) NSTimeInterval apiTimeout; // Default: 30 seconds

// Main operations
- (void)detectTimeshiftSupport:(NSArray<VLCChannel *> *)channels
                        m3uURL:(NSString * _Nullable)m3uURL
                    completion:(VLCTimeshiftDetectionCompletion)completion;

- (void)fetchTimeshiftInfoFromAPI:(NSString *)m3uURL
                         channels:(NSArray<VLCChannel *> *)channels
                       completion:(VLCTimeshiftAPICompletion)completion;

// M3U attribute parsing
- (void)parseCatchupAttributesInLine:(NSString *)line
                          forChannel:(VLCChannel *)channel;

// API operations
- (NSString * _Nullable)constructLiveStreamsAPIURL:(NSString *)m3uURL;
- (void)processAPIResponse:(NSArray *)apiChannels
               withChannels:(NSArray<VLCChannel *> *)channels
                 completion:(VLCTimeshiftAPICompletion)completion;

// Timeshift URL generation
- (NSString * _Nullable)generateTimeshiftURLForProgram:(VLCProgram *)program
                                               channel:(VLCChannel *)channel
                                            timeOffset:(NSTimeInterval)timeOffset;

- (NSString * _Nullable)generateTimeshiftURLForChannel:(VLCChannel *)channel
                                                atTime:(NSDate *)targetTime
                                            timeOffset:(NSTimeInterval)timeOffset;

// Channel analysis
- (BOOL)channelSupportsTimeshift:(VLCChannel *)channel;
- (BOOL)programSupportsTimeshift:(VLCProgram *)program channel:(VLCChannel *)channel;
- (NSInteger)timeshiftDaysForChannel:(VLCChannel *)channel;

// Group/category analysis
- (BOOL)groupHasTimeshiftChannels:(NSArray<VLCChannel *> *)channels;
- (NSInteger)timeshiftChannelCountInGroup:(NSArray<VLCChannel *> *)channels;

// Utility methods
- (NSString * _Nullable)extractStreamIDFromChannelURL:(NSString *)channelURL;
- (NSString * _Nullable)extractUsernameFromM3UURL:(NSString *)m3uURL;
- (NSString * _Nullable)extractPasswordFromM3UURL:(NSString *)m3uURL;

// Validation
- (BOOL)isValidCatchupValue:(NSString *)catchupValue;
- (BOOL)isTimeshiftURLValid:(NSString *)timeshiftURL;

// Statistics
- (NSDictionary *)timeshiftStatistics:(NSArray<VLCChannel *> *)channels;

@end

NS_ASSUME_NONNULL_END 