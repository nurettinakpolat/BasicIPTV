#import <Foundation/Foundation.h>

@class VLCProgram;

@interface VLCChannel : NSObject

@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *url;
@property (nonatomic, retain) NSString *group;
@property (nonatomic, retain) NSString *logo;
@property (nonatomic, retain) NSString *channelId;
@property (nonatomic, retain) NSMutableArray *programs;
@property (nonatomic, retain) NSString *logoUrl;
@property (nonatomic, retain) NSString *category;

// Catch-up/Time-shift properties (channel-level)
@property (nonatomic, assign) BOOL supportsCatchup;        // Channel supports time-shifting
@property (nonatomic, assign) NSInteger catchupDays;       // How many days back this channel supports
@property (nonatomic, retain) NSString *catchupSource;     // Catch-up source type (e.g., "default", "append", "shift")
@property (nonatomic, retain) NSString *catchupTemplate;   // URL template for catch-up streams

// Movie metadata properties
@property (nonatomic, retain) NSString *movieId;
@property (nonatomic, retain) NSString *movieDescription;
@property (nonatomic, retain) NSString *movieGenre;
@property (nonatomic, retain) NSString *movieDuration;
@property (nonatomic, retain) NSString *movieYear;
@property (nonatomic, retain) NSString *movieRating;
@property (nonatomic, retain) NSString *movieDirector;
@property (nonatomic, retain) NSString *movieCast;
@property (nonatomic, assign) BOOL hasLoadedMovieInfo;
@property (nonatomic, assign) BOOL hasStartedFetchingMovieInfo;
@property (nonatomic, retain) NSImage *cachedPosterImage;

/**
 * Returns the program that's currently airing on this channel
 */
- (VLCProgram *)currentProgram;

/**
 * Returns the current program with time offset applied (for EPG display)
 */
- (VLCProgram *)currentProgramWithTimeOffset:(NSInteger)offsetHours;

/**
 * Returns the next program that will air on this channel
 */
- (VLCProgram *)nextProgram;

@end 