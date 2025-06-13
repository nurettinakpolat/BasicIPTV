#import "VLCChannel.h"
#import "VLCProgram.h"

@implementation VLCChannel

@synthesize name = _name;
@synthesize url = _url;
@synthesize group = _group;
@synthesize logo = _logo;
@synthesize channelId = _channelId;
@synthesize programs = _programs;
@synthesize logoUrl = _logoUrl;
@synthesize category = _category;
@synthesize supportsCatchup = _supportsCatchup;
@synthesize catchupDays = _catchupDays;
@synthesize catchupSource = _catchupSource;
@synthesize catchupTemplate = _catchupTemplate;
@synthesize movieId = _movieId;
@synthesize movieDescription = _movieDescription;
@synthesize movieGenre = _movieGenre;
@synthesize movieDuration = _movieDuration;
@synthesize movieYear = _movieYear;
@synthesize movieRating = _movieRating;
@synthesize movieDirector = _movieDirector;
@synthesize movieCast = _movieCast;
@synthesize hasLoadedMovieInfo = _hasLoadedMovieInfo;
@synthesize hasStartedFetchingMovieInfo = _hasStartedFetchingMovieInfo;
@synthesize cachedPosterImage = _cachedPosterImage;

- (instancetype)init {
    self = [super init];
    if (self) {
        _name = @"";
        _url = @"";
        _group = @"";
        _logo = @"";
        _channelId = @"";
        _programs = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_name release];
    [_url release];
    [_group release];
    [_logo release];
    [_channelId release];
    [_programs release];
    [_logoUrl release];
    [_category release];
    [_catchupSource release];
    [_catchupTemplate release];
    [_movieId release];
    [_movieDescription release];
    [_movieGenre release];
    [_movieDuration release];
    [_movieYear release];
    [_movieRating release];
    [_movieDirector release];
    [_movieCast release];
    [_cachedPosterImage release];
    [super dealloc];
}

// Add current program method
- (VLCProgram *)currentProgram {
    if (!self.programs || self.programs.count == 0) {
        return nil;
    }
    
    NSDate *now = [NSDate date];
    
    for (id program in self.programs) {
        NSDate *startTime = nil;
        NSDate *endTime = nil;
        
        if ([program isKindOfClass:[VLCProgram class]]) {
            VLCProgram *vlcProgram = (VLCProgram *)program;
            startTime = vlcProgram.startTime;
            endTime = vlcProgram.endTime;
        } else if ([program isKindOfClass:[NSDictionary class]]) {
            NSDictionary *programDict = (NSDictionary *)program;
            startTime = [programDict objectForKey:@"startTime"];
            endTime = [programDict objectForKey:@"endTime"];
        }
        
        if (startTime && endTime && [now compare:startTime] != NSOrderedAscending && 
            [now compare:endTime] == NSOrderedAscending) {
            return program;
        }
    }
    
    // If no current program, return the next upcoming one
    NSArray *sortedPrograms = [self.programs sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSDate *startTimeA = nil;
        NSDate *startTimeB = nil;
        
        if ([a isKindOfClass:[VLCProgram class]]) {
            startTimeA = [(VLCProgram *)a startTime];
        } else if ([a isKindOfClass:[NSDictionary class]]) {
            startTimeA = [(NSDictionary *)a objectForKey:@"startTime"];
        }
        
        if ([b isKindOfClass:[VLCProgram class]]) {
            startTimeB = [(VLCProgram *)b startTime];
        } else if ([b isKindOfClass:[NSDictionary class]]) {
            startTimeB = [(NSDictionary *)b objectForKey:@"startTime"];
        }
        
        if (!startTimeA || !startTimeB) return NSOrderedSame;
        return [startTimeA compare:startTimeB];
    }];
    
    for (id program in sortedPrograms) {
        NSDate *startTime = nil;
        if ([program isKindOfClass:[VLCProgram class]]) {
            startTime = [(VLCProgram *)program startTime];
        } else if ([program isKindOfClass:[NSDictionary class]]) {
            startTime = [(NSDictionary *)program objectForKey:@"startTime"];
        }
        
        if (startTime && [now compare:startTime] == NSOrderedAscending) {
            return program;
        }
    }
    
    // If no upcoming program, return the most recent one
    return [sortedPrograms lastObject];
}

// Add current program method with time offset
- (VLCProgram *)currentProgramWithTimeOffset:(NSInteger)offsetHours {
    if (!self.programs || self.programs.count == 0) {
        return nil;
    }
    
    NSDate *now = [NSDate date];
    
    // Apply time offset in opposite direction to correctly find current program
    // When user has EPG offset (e.g., +1 hour), it means EPG times are 1 hour ahead of local time
    // So to find the current program, we need to subtract the offset from current time
    // to match against the EPG program times
    NSTimeInterval offsetSeconds = -offsetHours * 3600 ; // Convert hours to seconds and negate
    NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
    
    //NSLog(@"currentProgramWithTimeOffset: offsetHours=%ld, now=%@, adjustedNow=%@", 
    //      (long)offsetHours, now, adjustedNow);
    
    for (id program in self.programs) {
        // Safety check: handle both VLCProgram objects and dictionaries
        NSDate *startTime = nil;
        NSDate *endTime = nil;
        
        if ([program isKindOfClass:[VLCProgram class]]) {
            VLCProgram *vlcProgram = (VLCProgram *)program;
            startTime = vlcProgram.startTime;
            endTime = vlcProgram.endTime;
        } else if ([program isKindOfClass:[NSDictionary class]]) {
            NSDictionary *programDict = (NSDictionary *)program;
            startTime = [programDict objectForKey:@"startTime"];
            endTime = [programDict objectForKey:@"endTime"];
        }
        
        if (startTime && endTime) {
            // Check if the adjusted current time falls within this program's time range
            if ([adjustedNow compare:startTime] != NSOrderedAscending && 
                [adjustedNow compare:endTime] == NSOrderedAscending) {
                
                //NSLog(@"Found current program: %@ (%@ - %@)", 
                //      program.title, startTime, endTime);
                return program;
            }
        }
    }
    
    // If no current program, return the next upcoming one
    NSArray *sortedPrograms = [self.programs sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSDate *startTimeA = nil;
        NSDate *startTimeB = nil;
        
        if ([a isKindOfClass:[VLCProgram class]]) {
            startTimeA = [(VLCProgram *)a startTime];
        } else if ([a isKindOfClass:[NSDictionary class]]) {
            startTimeA = [(NSDictionary *)a objectForKey:@"startTime"];
        }
        
        if ([b isKindOfClass:[VLCProgram class]]) {
            startTimeB = [(VLCProgram *)b startTime];
        } else if ([b isKindOfClass:[NSDictionary class]]) {
            startTimeB = [(NSDictionary *)b objectForKey:@"startTime"];
        }
        
        if (!startTimeA || !startTimeB) return NSOrderedSame;
        return [startTimeA compare:startTimeB];
    }];
    
    for (id program in sortedPrograms) {
        NSDate *startTime = nil;
        if ([program isKindOfClass:[VLCProgram class]]) {
            startTime = [(VLCProgram *)program startTime];
        } else if ([program isKindOfClass:[NSDictionary class]]) {
            startTime = [(NSDictionary *)program objectForKey:@"startTime"];
        }
        
        if (startTime && [adjustedNow compare:startTime] == NSOrderedAscending) {
            //NSLog(@"Found next program: %@ (%@ - %@)", 
                  //program.title, startTime, endTime);
            return program;
        }
    }
    
    // If no upcoming program, return the most recent one
    VLCProgram *lastProgram = [sortedPrograms lastObject];
    if (lastProgram) {
        //NSLog(@"Returning last program: %@ (%@ - %@)", 
              //lastProgram.title, lastProgram.startTime, lastProgram.endTime);
    }
    return lastProgram;
}

// Add next program method
- (VLCProgram *)nextProgram {
    NSDate *now = [NSDate date];
    VLCProgram *nextProgram = nil;
    NSTimeInterval shortestDiff = DBL_MAX;
    
    for (id program in _programs) {
        NSDate *startTime = nil;
        if ([program isKindOfClass:[VLCProgram class]]) {
            startTime = [(VLCProgram *)program startTime];
        } else if ([program isKindOfClass:[NSDictionary class]]) {
            startTime = [(NSDictionary *)program objectForKey:@"startTime"];
        }
        
        if (startTime && [startTime compare:now] == NSOrderedDescending) {
            NSTimeInterval diff = [startTime timeIntervalSinceDate:now];
            if (diff < shortestDiff) {
                shortestDiff = diff;
                nextProgram = program;
            }
        }
    }
    
    return nextProgram;
}

@end 
