#import "VLCOverlayView.h"

#if TARGET_OS_OSX

@interface VLCOverlayView (PlayerControls)

// Properties for player controls
@property (nonatomic, assign) NSRect playerControlsRect;
@property (nonatomic, assign) NSRect progressBarRect;
@property (nonatomic, assign) NSRect subtitlesButtonRect;
@property (nonatomic, assign) NSRect audioButtonRect;

// Properties for progress bar hover functionality
@property (nonatomic, assign) BOOL isHoveringProgressBar;
@property (nonatomic, assign) NSPoint progressBarHoverPoint;


// Methods for player controls
- (void)drawPlayerControls:(NSRect)rect;
- (BOOL)handlePlayerControlsClickAtPoint:(NSPoint)point;
- (void)togglePlayerControls;
- (void)hidePlayerControls:(NSTimer *)timer;

// Methods for subtitle and audio track selection
- (void)showSubtitleDropdown;
- (void)showAudioDropdown;

// Methods for catch-up functionality
- (NSString *)generateCatchupUrlForProgram:(VLCProgram *)program channel:(VLCChannel *)channel;
- (NSString *)generateChannelCatchupUrlForChannel:(VLCChannel *)channel timeOffset:(NSTimeInterval)timeOffset;
- (void)playCatchupUrl:(NSString *)catchupUrl seekToTime:(NSTimeInterval)seekTime;
- (void)playCatchupUrl:(NSString *)catchupUrl seekToTime:(NSTimeInterval)seekTime channel:(VLCChannel *)channel;

// Methods for timeshift detection and seeking
- (BOOL)isCurrentlyPlayingTimeshift;
- (void)calculateTimeshiftProgress:(float *)progress 
                   currentTimeStr:(NSString **)currentTimeStr 
                     totalTimeStr:(NSString **)totalTimeStr 
                  programStatusStr:(NSString **)programStatusStr 
                   programTimeRange:(NSString **)programTimeRange 
                     currentChannel:(VLCChannel *)currentChannel 
                     currentProgram:(VLCProgram *)currentProgram;
- (NSDate *)extractTimeshiftStartTimeFromUrl:(NSString *)urlString;
- (void)handleTimeshiftSeek:(CGFloat)relativePosition;
- (void)handleNormalSeek:(CGFloat)relativePosition currentChannel:(VLCChannel *)currentChannel currentProgram:(VLCProgram *)currentProgram;
- (NSString *)generateNewTimeshiftUrlFromCurrentUrl:(NSString *)currentUrl newStartTime:(NSDate *)newStartTime;
- (void)setTimeshiftSeekingState:(BOOL)seeking;
- (BOOL)isTimeshiftSeeking;

// Method to get current timeshift playing program
- (VLCProgram *)getCurrentTimeshiftPlayingProgram;

// Methods for timeshift channel caching
- (void)cacheTimeshiftChannel:(VLCChannel *)channel;
- (VLCChannel *)getCachedTimeshiftChannel;
- (void)clearCachedTimeshiftChannel;

@end 

#endif // TARGET_OS_OSX 
