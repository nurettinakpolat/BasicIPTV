#import <Foundation/Foundation.h>

@interface VLCProgram : NSObject

@property (nonatomic, retain) NSString *title;
@property (nonatomic, retain) NSString *programDescription;
@property (nonatomic, retain) NSDate *startTime;
@property (nonatomic, retain) NSDate *endTime;
@property (nonatomic, retain) NSString *channelId;
@property (nonatomic, assign) BOOL hasArchive;  // Indicates if catch-up is available
@property (nonatomic, retain) NSString *archiveUrl;  // Optional: specific archive URL
@property (nonatomic, assign) NSInteger archiveDays;  // How many days back this program is available

/**
 * Returns a formatted string of the program's time range (e.g., "20:00 - 21:00")
 */
- (NSString *)formattedTimeRange;

/**
 * Returns a formatted string of the program's time range with time offset applied (e.g., "20:00 - 21:00")
 * @param offsetHours The number of hours to offset the time (can be negative)
 */
- (NSString *)formattedTimeRangeWithOffset:(NSInteger)offsetHours;

@end 