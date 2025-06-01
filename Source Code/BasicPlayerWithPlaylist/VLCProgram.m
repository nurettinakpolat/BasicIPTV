#import "VLCProgram.h"

@implementation VLCProgram

- (instancetype)init {
    self = [super init];
    if (self) {
        _title = @"";
        _programDescription = @"";
        _startTime = [NSDate date];
        _endTime = [NSDate dateWithTimeIntervalSinceNow:3600]; // Default 1 hour
        _channelId = @"";
    }
    return self;
}

- (NSString *)formattedTimeRange {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm"];
    
    NSString *timeRange;
    
    if (_endTime) {
        // Normal case with both start and end times
        timeRange = [NSString stringWithFormat:@"%@ - %@", 
                     [formatter stringFromDate:_startTime],
                     [formatter stringFromDate:_endTime]];
    } else {
        // Handle missing end time - estimate 1 hour duration
        NSLog(@"Warning: Missing end time for program '%@' starting at %@", _title, _startTime);
        
        NSDate *estimatedEndTime = [_startTime dateByAddingTimeInterval:3600]; // 1 hour
        timeRange = [NSString stringWithFormat:@"%@ - %@", 
                     [formatter stringFromDate:_startTime],
                     [formatter stringFromDate:estimatedEndTime]];
    }
    
    [formatter release];
    return timeRange;
}

- (NSString *)formattedTimeRangeWithOffset:(NSInteger)offsetHours {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"HH:mm"];
    
    // Apply offset in seconds (hours * 3600)
    NSTimeInterval offsetSeconds = offsetHours * 3600;
    
    NSDate *adjustedStartTime = [_startTime dateByAddingTimeInterval:offsetSeconds];
    
    NSString *timeRange;
    
    if (_endTime) {
        // Normal case with both start and end times
        NSDate *adjustedEndTime = [_endTime dateByAddingTimeInterval:offsetSeconds];
        timeRange = [NSString stringWithFormat:@"%@ - %@", 
                     [formatter stringFromDate:adjustedStartTime],
                     [formatter stringFromDate:adjustedEndTime]];
    } else {
        // Handle missing end time - show only start time or estimate end time
        NSLog(@"Warning: Missing end time for program '%@' starting at %@", _title, _startTime);
        
        // Try to estimate end time as 1 hour after start time if no end time available
        NSDate *estimatedEndTime = [adjustedStartTime dateByAddingTimeInterval:3600]; // 1 hour
        timeRange = [NSString stringWithFormat:@"%@ - %@", 
                     [formatter stringFromDate:adjustedStartTime],
                     [formatter stringFromDate:estimatedEndTime]];
    }
    
    [formatter release];
    return timeRange;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@: %@ (%@)", 
           [self formattedTimeRange], _title, _programDescription];
}

- (void)dealloc {
    [_title release];
    [_programDescription release];
    [_startTime release];
    [_endTime release];
    [_channelId release];
    [super dealloc];
}

@end 