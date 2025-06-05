#import "VLCOverlayView+EPG.h"
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+Utilities.h"
#import "VLCOverlayView+Caching.h"
#import "DownloadManager.h"

// Global variable to track retry count
static NSInteger gEpgRetryCount = 0;

// Global variables to track progress - made accessible to UI module
int totalProgramCount = 0;
int totalChannelCount = 0;

// File handle for saving downloaded data
static NSFileHandle *gDownloadFileHandle = nil;
static NSString *gDownloadFilePath = nil;

// Flag to track if matching process is already running
static BOOL gEpgMatchingInProgress = NO;
static NSLock *gEpgMatchingLock = nil;

@implementation VLCOverlayView (EPG) 

#pragma mark - EPG Loading

- (void)loadEpgData {
    // Check if we have a valid EPG URL
    if (!self.epgUrl || [self.epgUrl isEqualToString:@""]) {
        //NSLog(@"No EPG URL specified");
        return;
    }
    
    // First verify that we have channel data - don't load EPG without channels
    if (!self.channels || [self.channels count] == 0) {
        //NSLog(@"Cannot load EPG data - no channels loaded yet. Load channel list first.");
        return;
    }
    
    //NSLog(@"Loading EPG data from URL: %@", self.epgUrl);
    //NSLog(@"Note: Loading EPG data preserves existing channel list");
    
    // Cancel any previous timeout
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleEpgLoadingTimeout) object:nil];
    
    // Set a timeout for the entire operation (5 minutes max)
    [self performSelector:@selector(handleEpgLoadingTimeout) withObject:nil afterDelay:300.0];
    
    // First try to load from cache - but continue to load from URL regardless
    if ([self loadEpgDataFromCache]) {
        //NSLog(@"Successfully loaded EPG data from cache, now updating from URL...");
    } else {
        //NSLog(@"No valid EPG cache found, downloading from URL...");
    }
    
    // Make sure loading indicator is showing with clear initial status
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = YES;
        self.isLoadingEpg = YES;
        [self startProgressRedrawTimer];
        [self setLoadingStatusText:@"Preparing to download EPG data..."];
        [self setNeedsDisplay:YES];
    });
    
    // Start with retry count 0
    [self loadEpgDataWithRetryCount:0];
}

- (void)loadEpgDataWithRetryCount:(NSInteger)retryCount {
    // Maximum retry attempts
    const NSInteger MAX_RETRIES = 3;
    
    // Store the retry count in the global variable
    gEpgRetryCount = retryCount;
    
    // Store download timestamp in Application Support settings file instead of UserDefaults
    NSString *settingsPath = [self settingsFilePath];
    NSMutableDictionary *settingsDict = [NSMutableDictionary dictionaryWithContentsOfFile:settingsPath];
    if (!settingsDict) settingsDict = [NSMutableDictionary dictionary];
    [settingsDict setObject:[NSDate date] forKey:@"LastEPGDownloadDate"];
    [settingsDict writeToFile:settingsPath atomically:YES];
    
    // Load the latest data from the network regardless of cache status
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Set loading flags
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoadingEpg = YES;
            self.epgLoadingProgress = 0.0f;
            [self setNeedsDisplay:YES];
        });
        
        // Update status message based on retry count
        if (retryCount > 0) {
            [self setLoadingStatusText:[NSString stringWithFormat:@"Retry %d of %d: Updating EPG data from server...", 
                                        (int)retryCount, (int)MAX_RETRIES]];
        } else {
            [self setLoadingStatusText:@"Updating EPG data from server..."];
        }
        
        // Set up temp file path for download
        NSString *tempFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"temp_epg.xml"];
        //NSLog(@"Will download EPG to temp file: %@", tempFilePath);
        
        // Remove any existing file
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:tempFilePath]) {
            [fileManager removeItemAtPath:tempFilePath error:nil];
        }
        
        // Initialize receivedData for download
        if (receivedData) {
            [receivedData release];
            receivedData = nil;
        }
        receivedData = [[NSMutableData alloc] init];
        
        // Set up download manager
        DownloadManager *manager = [[DownloadManager alloc] init];
        
        // Start download
        //NSLog(@"Starting EPG download from URL: %@ (retry: %ld)", self.epgUrl, (long)retryCount);
        
        // Cancel any previous timeout
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleEpgLoadingTimeout) object:nil];
        
        // Set a timeout
        [self performSelector:@selector(handleEpgLoadingTimeout) withObject:nil afterDelay:300.0];
        
        [manager startDownloadFromURL:self.epgUrl
                      progressHandler:^(int64_t received, int64_t total) {
                          // Calculate progress percentage
                          float progress = (total > 0) ? ((float)received / (float)total) : 0.0f;
                          
                          // Log detailed progress at regular intervals
                          static int64_t lastLoggedBytes = 0;
                          const int64_t LOG_THRESHOLD = 1 * 1024 * 1024; // Log every 1MB
                          
                          if (received - lastLoggedBytes > LOG_THRESHOLD) {
                              //NSLog(@"EPG download progress: %.1f%% (%.1f/%.1f MB)", 
                              //      progress * 100.0,
                              //      (float)received / 1048576.0,
                              //      (float)total / 1048576.0);
                              lastLoggedBytes = received;
                          }
                          
                          // Calculate download speed
                          static NSTimeInterval lastUpdateTime = 0;
                          static int64_t lastBytes = 0;
                          NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                          NSTimeInterval elapsed = now - lastUpdateTime;
                          float speedMBps = 0;
                          
                          if (elapsed > 0.5 && lastUpdateTime > 0) { // Only update every half second
                              int64_t bytesInInterval = received - lastBytes;
                              speedMBps = (bytesInInterval / 1048576.0) / elapsed;
                              lastBytes = received;
                              lastUpdateTime = now;
                          } else if (lastUpdateTime == 0) {
                              // First update
                              lastBytes = received;
                              lastUpdateTime = now;
                          }
                          
                          // Calculate ETA (estimated time of arrival) if we have a download speed
                          NSString *etaString = @"";
                          if (speedMBps > 0 && total > received) {
                              int64_t remainingBytes = total - received;
                              float remainingTime = (remainingBytes / 1048576.0) / speedMBps; // in seconds
                              
                              // Format time remaining
                              if (remainingTime < 60) {
                                  etaString = [NSString stringWithFormat:@"(%.0fs left)", remainingTime];
                              } else if (remainingTime < 3600) {
                                  etaString = [NSString stringWithFormat:@"(%.1fm left)", remainingTime / 60.0];
                              } else {
                                  etaString = [NSString stringWithFormat:@"(%.1fh left)", remainingTime / 3600.0];
                              }
                          }
                          
                          // Format size in appropriate units
                          NSString *sizeInfo;
                          if (received < 1024 * 1024) { // Less than 1MB
                              sizeInfo = [NSString stringWithFormat:@"%.1f KB / %.1f MB", 
                                         (float)received / 1024.0, 
                                         (float)total / 1048576.0];
                          } else {
                              sizeInfo = [NSString stringWithFormat:@"%.2f / %.2f MB", 
                                         (float)received / 1048576.0, 
                                         (float)total / 1048576.0];
                          }
                          
                          // Format speed string
                          NSString *speedInfo = (speedMBps > 0) ? 
                              [NSString stringWithFormat:@"%.1f MB/s %@", speedMBps, etaString] : @"";
                          
                          // Update UI on main thread
                          dispatch_async(dispatch_get_main_queue(), ^{
                              self.epgLoadingProgress = progress;
                              
                                                        // Create detailed status text with percentage and size information
                          NSString *statusText = [NSString stringWithFormat:@"Downloading: %.1f%% %@", 
                                                 progress * 100.0, sizeInfo];
                          
                          // Set both the regular status text and progress-specific text
                          [self setLoadingStatusText:statusText];
                          
                          // Update custom progress display in the right bottom corner
                          if (!gProgressMessageLock) {
                              gProgressMessageLock = [[NSLock alloc] init];
                          }
                          
                          [gProgressMessageLock lock];
                          // Release existing message if any
                          if (gProgressMessage) {
                              [gProgressMessage release];
                              gProgressMessage = nil;
                          }
                          
                          // Create status display matching M3U downloads
                          gProgressMessage = [[NSString stringWithFormat:@"Downloading: %.1f%% %@", 
                                              progress * 100.0, sizeInfo] retain];
                              [gProgressMessageLock unlock];
                              
                              // Make sure we're regularly updating the display
                              [self startProgressRedrawTimer];
                              [self setNeedsDisplay:YES];
                          });
                      }
                    completionHandler:^(NSString *filePath, NSError *error) {
                          // Cancel the timeout since download completed (either success or failure)
                          [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleEpgLoadingTimeout) object:nil];
                          
                          // Check for error
                          if (error) {
                              //NSLog(@"EPG download failed: %@", error);
                              
                              // If we haven't exceeded retry count, try again
                              if (retryCount < MAX_RETRIES) {
                                  //NSLog(@"EPG download failed, retrying (attempt %ld of %d)...", (long)retryCount + 1, (int)MAX_RETRIES);
                                  
                                  // Wait 3 seconds before retrying
                                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), 
                                                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                      [self loadEpgDataWithRetryCount:retryCount + 1];
                                  });
                                  return;
                              }
                              
                              // Show appropriate error message based on error type
                              NSString *errorMsg;
                              if ([error.domain isEqualToString:NSURLErrorDomain]) {
                                  switch (error.code) {
                                      case NSURLErrorTimedOut:
                                          errorMsg = @"Connection timed out. The server is not responding.";
                                          break;
                                      case NSURLErrorCannotFindHost:
                                          errorMsg = @"Cannot find EPG host. Check the URL and network connection.";
                                          break;
                                      case NSURLErrorCannotConnectToHost:
                                          errorMsg = @"Cannot connect to EPG host. Server may be down.";
                                          break;
                                      case NSURLErrorNetworkConnectionLost:
                                          errorMsg = @"Network connection lost. Check your internet connection.";
                                          break;
                                      case NSURLErrorNotConnectedToInternet:
                                          errorMsg = @"Not connected to the internet.";
                                          break;
                                      default:
                                          errorMsg = [NSString stringWithFormat:@"EPG download error: %@", [error localizedDescription]];
                                          break;
                                  }
                              } else {
                                  errorMsg = [NSString stringWithFormat:@"EPG download error: %@", [error localizedDescription]];
                              }
                              
                              // Show error message
                              [self setLoadingStatusText:errorMsg];
                              
                              // Update UI
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  self.isLoadingEpg = NO;
                                  self.isLoading = NO;
                                  [self setNeedsDisplay:YES];
                                  
                                  // Clear error message after a delay
                                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                      if (gProgressMessageLock) {
                                          [gProgressMessageLock lock];
                                          [gProgressMessage release];
                                          gProgressMessage = nil;
                                          [gProgressMessageLock unlock];
                                      }
                                      [self setNeedsDisplay:YES];
                                  });
                              });
                              return;
                          }
                          
                          // Download succeeded - handle the file
                          //NSLog(@"EPG download complete, saved to: %@", filePath);
                          [self setLoadingStatusText:@"Download complete, processing data..."];
                          
                          // Read file into memory for processing
                          NSError *readError = nil;
                          NSData *downloadedData = [NSData dataWithContentsOfFile:filePath options:NSDataReadingMappedIfSafe error:&readError];
                          
                          if (readError || !downloadedData) {
                              //NSLog(@"Error reading downloaded EPG file: %@", readError ? [readError localizedDescription] : @"No data");
                              
                              // Show error
                              [self setLoadingStatusText:@"Error reading downloaded EPG data"];
                              
                              // Update UI
                              dispatch_async(dispatch_get_main_queue(), ^{
                                  self.isLoadingEpg = NO;
                                  self.isLoading = NO;
                                  [self setNeedsDisplay:YES];
                              });
                              return;
                          }
                          
                          // Store data for processing
                          if (receivedData) {
                              [receivedData release];
                              receivedData = nil;
                          }
                          receivedData = [[NSMutableData alloc] initWithData:downloadedData];
                          
                          // Success - update progress
                          dispatch_async(dispatch_get_main_queue(), ^{
                              self.isLoading = YES;
                              self.isLoadingEpg = YES;
                              self.epgLoadingProgress = 1.0;  // 100% for download phase
                              [self startProgressRedrawTimer];
                              [self setLoadingStatusText:[NSString stringWithFormat:@"Download complete: %0.1f MB",
                                                         (float)downloadedData.length / 1048576.0]];
                              [self setNeedsDisplay:YES];
                          });
                          
                          // Process the data
                          [self handleDownloadComplete];
                          
                          // Clean up the download manager
                          [manager release];
                      }
                      destinationPath:tempFilePath];
    });
}

- (BOOL)loadEpgDataFromCache {
    // Always run in background thread to avoid hanging the UI
    __block BOOL success = NO;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Show loading indicator
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = YES;
            self.isLoadingEpg = YES;
            [self startProgressRedrawTimer];
            
            // Display a message about loading from cache
            NSString *settingsPath = [self settingsFilePath];
            NSMutableDictionary *settingsDict = [NSMutableDictionary dictionaryWithContentsOfFile:settingsPath];
            NSDate *lastDownload = [settingsDict objectForKey:@"LastEPGDownloadDate"];
            if (lastDownload) {
                NSTimeInterval timeSince = [[NSDate date] timeIntervalSinceDate:lastDownload];
                int hoursAgo = (int)(timeSince / 3600);
                [self setLoadingStatusText:[NSString stringWithFormat:@"Loading EPG from cache (last updated %d hours ago)...", hoursAgo]];
            } else {
                [self setLoadingStatusText:@"Loading EPG from cache..."];
            }
            [self setNeedsDisplay:YES];
            
            // Update progress display
            if (gProgressMessageLock) {
                [gProgressMessageLock lock];
                if (gProgressMessage) {
                    [gProgressMessage release];
                }
                gProgressMessage = [[NSString stringWithFormat:@"epg: loading cache"] retain];
                [gProgressMessageLock unlock];
            }
        });
        
        success = [self loadEpgDataFromCacheWithoutChecks];
        
        // Update UI on main thread after completion
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [self setLoadingStatusText:@"EPG loaded from cache successfully"];
            } else {
                [self setLoadingStatusText:@"No valid EPG cache found, will download from URL"];
            }
            [self setNeedsDisplay:YES];
        });
    });
    
    // Always return YES because we're handling the loading asynchronously
    return YES;
}

- (BOOL)loadEpgDataFromCacheWithoutChecks {
    // First verify that we have channel data - don't load EPG without channels
    if (!self.channels || [self.channels count] == 0) {
        //NSLog(@"Cannot load EPG data from cache - no channels loaded yet");
        return NO;
    }
    
    NSString *cachePath = [self epgCacheFilePath];
    
    // Check if cache file exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cachePath]) {
        //NSLog(@"EPG cache file does not exist: %@", cachePath);
        return NO;
    }
    
    // Load cache data
    NSDictionary *cacheDict = [NSDictionary dictionaryWithContentsOfFile:cachePath];
    if (!cacheDict) {
        //NSLog(@"Failed to load EPG cache from %@", cachePath);
        return NO;
    }
    
    // Check cache version
    NSString *cacheVersion = [cacheDict objectForKey:@"epgCacheVersion"];
    if (!cacheVersion || ![cacheVersion isEqualToString:@"1.0"]) {
        //NSLog(@"Unsupported EPG cache version: %@", cacheVersion);
        return NO;
    }
    
    // Check cache date (not older than 24 hours)
    NSDate *cacheDate = [cacheDict objectForKey:@"epgCacheDate"];
    if (!cacheDate) {
        //NSLog(@"Invalid EPG cache date");
        return NO;
    }
    
    NSTimeInterval timeSinceCache = [[NSDate date] timeIntervalSinceDate:cacheDate];
    if (timeSinceCache > 24 * 60 * 60) { // 24 hours
        //NSLog(@"EPG cache is too old (%f hours), reloading", timeSinceCache / 3600.0);
        return NO;
    }
    
    // Process EPG data
    NSDictionary *epgData = [cacheDict objectForKey:@"epgData"];
    if (!epgData) {
        //NSLog(@"No EPG data in cache");
        return NO;
    }
    
    // Clear existing EPG data
    @synchronized(self.epgData) {
        [self.epgData removeAllObjects];
        
        // Process each channel
        for (NSString *channelId in epgData) {
            NSArray *programDicts = [epgData objectForKey:channelId];
            NSMutableArray *programs = [NSMutableArray array];
            
            for (NSDictionary *programDict in programDicts) {
                VLCProgram *program = [[VLCProgram alloc] init];
                program.title = [programDict objectForKey:@"title"];
                program.programDescription = [programDict objectForKey:@"description"];
                program.startTime = [programDict objectForKey:@"startTime"];
                program.endTime = [programDict objectForKey:@"endTime"];
                program.channelId = [programDict objectForKey:@"channelId"];
                
                // Check for catch-up attributes
                NSString *hasArchive = [programDict objectForKey:@"catchup"];
                if (hasArchive && [hasArchive isEqualToString:@"1"]) {
                    program.hasArchive = YES;
                }
                
                NSString *archiveDays = [programDict objectForKey:@"catchup-days"];
                if (archiveDays) {
                    program.archiveDays = [archiveDays integerValue];
                }
                
                [programs addObject:program];
                [program release];
            }
            
            [self.epgData setObject:programs forKey:channelId];
        }
    }
    
    // Match EPG data with channels
    [self matchEpgWithChannels];
    
    // Update UI
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isEpgLoaded = YES;
        self.isLoadingEpg = NO;
        [self setNeedsDisplay:YES];
    });
    
    return YES;
}

- (void)loadEpgFromCacheOnly {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self loadEpgDataFromCacheWithoutChecks];
    });
}

- (void)loadEpgDataAtStartup {
    // Check if we have a valid EPG URL
    if (!self.epgUrl || [self.epgUrl isEqualToString:@""]) {
        //NSLog(@"No EPG URL specified for startup EPG loading");
        return;
    }
    
    // First verify that we have channel data - don't load EPG without channels
    if (!self.channels || [self.channels count] == 0) {
        //NSLog(@"Cannot load EPG data at startup - no channels loaded yet. Load channel list first.");
        return;
    }
    
    //NSLog(@"Starting initial EPG load sequence at startup");
    
    // First try to load from cache without any age check
    BOOL cacheLoaded = [self loadEpgDataFromCacheWithoutAgeCheck];
    if (cacheLoaded) {
        //NSLog(@"Successfully loaded EPG data from cache at startup");
    }
    
    // Then always update from URL to get the latest data
    //NSLog(@"Now updating EPG from URL: %@", self.epgUrl);
    [self loadEpgData];
}

- (BOOL)loadEpgDataFromCacheWithoutAgeCheck {
    NSString *cachePath = [self epgCacheFilePath];
    
    // Check if cache file exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cachePath]) {
        //NSLog(@"EPG cache file does not exist: %@", cachePath);
        return NO;
    }
    
    // Load cache data
    NSDictionary *cacheDict = [NSDictionary dictionaryWithContentsOfFile:cachePath];
    if (!cacheDict) {
        //NSLog(@"Failed to load EPG cache from %@", cachePath);
        return NO;
    }
    
    // Check cache version
    NSString *cacheVersion = [cacheDict objectForKey:@"epgCacheVersion"];
    if (!cacheVersion || ![cacheVersion isEqualToString:@"1.0"]) {
        //NSLog(@"Unsupported EPG cache version: %@", cacheVersion);
        return NO;
    }
    
    // Process EPG data
    NSDictionary *epgData = [cacheDict objectForKey:@"epgData"];
    if (!epgData) {
        //NSLog(@"No EPG data in cache");
        return NO;
    }
    
    // Clear existing EPG data
    @synchronized(self.epgData) {
        [self.epgData removeAllObjects];
        
        // Process each channel
        for (NSString *channelId in epgData) {
            NSArray *programDicts = [epgData objectForKey:channelId];
            NSMutableArray *programs = [NSMutableArray array];
            
            for (NSDictionary *programDict in programDicts) {
                VLCProgram *program = [[VLCProgram alloc] init];
                program.title = [programDict objectForKey:@"title"];
                program.programDescription = [programDict objectForKey:@"description"];
                program.startTime = [programDict objectForKey:@"startTime"];
                program.endTime = [programDict objectForKey:@"endTime"];
                program.channelId = [programDict objectForKey:@"channelId"];
                
                // Check for catch-up attributes
                NSString *hasArchive = [programDict objectForKey:@"catchup"];
                if (hasArchive && [hasArchive isEqualToString:@"1"]) {
                    program.hasArchive = YES;
                }
                
                NSString *archiveDays = [programDict objectForKey:@"catchup-days"];
                if (archiveDays) {
                    program.archiveDays = [archiveDays integerValue];
                }
                
                [programs addObject:program];
                [program release];
            }
            
            [self.epgData setObject:programs forKey:channelId];
        }
    }
    
    // Match EPG data with channels
    [self matchEpgWithChannels];
    
    // Update UI
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isEpgLoaded = YES;
        self.isLoadingEpg = NO;
        [self setNeedsDisplay:YES];
    });
    
    return YES;
}

#pragma mark - EPG Data Processing

- (void)matchEpgWithChannels {
    // Create lock if it doesn't exist
    if (!gEpgMatchingLock) {
        gEpgMatchingLock = [[NSLock alloc] init];
    }
    
    // Check if matching is already in progress
    [gEpgMatchingLock lock];
    if (gEpgMatchingInProgress) {
        //NSLog(@"EPG matching already in progress. Skipping this request.");
        [gEpgMatchingLock unlock];
        return;
    }
    
    // Set flag to indicate matching has started
    gEpgMatchingInProgress = YES;
    [gEpgMatchingLock unlock];
    
    // First update UI to indicate we're starting the matching process
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = YES;
        [self setLoadingStatusText:@"Starting EPG matching..."];
        
        // Update progress display
        if (gProgressMessageLock) {
            [gProgressMessageLock lock];
            if (gProgressMessage) {
                [gProgressMessage release];
            }
            gProgressMessage = [[NSString stringWithFormat:@"Processing: matching channels..."] retain];
            [gProgressMessageLock unlock];
        }
        
        [self startProgressRedrawTimer];
        [self setNeedsDisplay:YES];
    });
    
    // Run the intensive matching process on a background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger totalMatches = 0;
        NSArray *channelsCopy = nil;
        NSInteger totalChannels = 0;
        
        @try {
            // Update UI with matching progress
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setLoadingStatusText:@"Matching EPG data with channels..."];
                [self setNeedsDisplay:YES];
            });
            
            // Create a case-insensitive lookup dictionary for EPG data for faster matching
            NSMutableDictionary *caseInsensitiveEpgData = [NSMutableDictionary dictionary];
            for (NSString *epgKey in [self.epgData allKeys]) {
                if (epgKey) {
                    NSString *lowercaseKey = [epgKey lowercaseString];
                    [caseInsensitiveEpgData setObject:[self.epgData objectForKey:epgKey] 
                                              forKey:lowercaseKey];
                }
            }
            
            // Make a copy of the channels array to avoid mutation during enumeration
            @synchronized(self.channels) {
                channelsCopy = [[NSArray arrayWithArray:self.channels] retain];
            }
            
            // Set up for progress reporting
            totalChannels = [channelsCopy count];
            NSInteger processedChannels = 0;
            NSTimeInterval lastUIUpdate = [NSDate timeIntervalSinceReferenceDate];
            const NSTimeInterval UPDATE_INTERVAL = 0.5; // Update UI at most 2 times per second
            const NSInteger BATCH_SIZE = 50; // Process in batches for better performance
            
            // Work with the copy instead of the original
            for (NSInteger i = 0; i < [channelsCopy count]; i += BATCH_SIZE) {
                // Process a batch of channels at once
                NSInteger endIndex = MIN(i + BATCH_SIZE, [channelsCopy count]);
                
                for (NSInteger j = i; j < endIndex; j++) {
                    VLCChannel *channel = [channelsCopy objectAtIndex:j];
                    @try {
                        // ONLY match by channel ID with lowercase comparison
                        NSMutableArray *programsForChannel = nil;
                        
                        if (channel.channelId) {
                            // Convert channel ID to lowercase for comparison
                            NSString *lowercaseChannelId = [channel.channelId lowercaseString];
                            
                            // Get programs for this channel ID
                            programsForChannel = [caseInsensitiveEpgData objectForKey:lowercaseChannelId];
                        }
                        
                        // If we found programs, assign them to the channel
                        if (programsForChannel && programsForChannel.count > 0) {
                            [channel.programs removeAllObjects];
                            [channel.programs addObjectsFromArray:programsForChannel];
                            
                            // FIXED: Check if any programs have archive support and update channel accordingly
                            BOOL foundArchivePrograms = NO;
                            for (VLCProgram *program in programsForChannel) {
                                if (program.hasArchive) {
                                    foundArchivePrograms = YES;
                                    break;
                                }
                            }
                            
                            // If EPG data indicates programs have archive but channel doesn't support catchup,
                            // automatically enable catchup for this channel to ensure consistency
                            if (foundArchivePrograms && !channel.supportsCatchup) {
                                channel.supportsCatchup = YES;
                                channel.catchupDays = 7; // Default to 7 days if not specified
                                channel.catchupSource = @"epg"; // Indicate this was set from EPG data
                                //NSLog(@"✅ FIXED: Enabled catchup for channel '%@' based on EPG archive data", channel.name);
                            }
                            
                            // If channel supports catchup, mark past programs as having archive
                            if (channel.supportsCatchup) {
                                // Apply EPG time offset to current time for proper comparison
                                // Use negative offset to adjust current time for comparison with EPG times
                                NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600.0;
                                NSDate *adjustedNow = [[NSDate date] dateByAddingTimeInterval:offsetSeconds];
                                NSTimeInterval catchupWindow = channel.catchupDays * 24 * 60 * 60; // Convert days to seconds
                                
                                //NSLog(@"Processing catchup for channel '%@': EPG offset = %.1f hours, adjusted time = %@", 
                                //      channel.name, self.epgTimeOffsetHours, adjustedNow);
                                
                                for (VLCProgram *program in channel.programs) {
                                    if (program.endTime && [adjustedNow timeIntervalSinceDate:program.endTime] > 0) {
                                        // This is a past program (using adjusted time)
                                        NSTimeInterval timeSinceEnd = [adjustedNow timeIntervalSinceDate:program.endTime];
                                        if (timeSinceEnd <= catchupWindow) {
                                            // Program is within catchup window
                                            program.hasArchive = YES;
                                            if (program.archiveDays == 0) {
                                                program.archiveDays = channel.catchupDays;
                                            }
                                            //NSLog(@"Marked program '%@' as having catchup (ended %.1f hours ago)", 
                                            //      program.title, timeSinceEnd / 3600.0);
                                        }
                                    }
                                }
                            }
                            
                            totalMatches++;
                        }
                        
                        // Update progress count
                        processedChannels++;
                    } @catch (NSException *exception) {
                        //NSLog(@"Exception matching EPG for channel %@: %@", channel.name, exception);
                    }
                }
                
                // Update UI less frequently for better performance
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                if (now - lastUIUpdate >= UPDATE_INTERVAL || processedChannels == totalChannels) {
                    lastUIUpdate = now;
                    float progressPercentage = (float)processedChannels / (float)totalChannels * 100.0f;
                    
                    // Update UI on main thread
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.epgLoadingProgress = (float)processedChannels / (float)totalChannels;
                        [self setLoadingStatusText:[NSString stringWithFormat:@"Matching EPG data: %ld of %ld channels (%.1f%%) - %ld matches",
                                                  (long)processedChannels, (long)totalChannels, 
                                                  progressPercentage, (long)totalMatches]];
                        
                        // Update progress display
                        if (gProgressMessageLock) {
                            [gProgressMessageLock lock];
                            if (gProgressMessage) {
                                [gProgressMessage release];
                            }
                            gProgressMessage = [[NSString stringWithFormat:@"Processing: %ld/%ld (%.1f%%)",
                                               (long)processedChannels, (long)totalChannels, 
                                               progressPercentage] retain];
                            [gProgressMessageLock unlock];
                        }
                        
                        [self setNeedsDisplay:YES];
                    });
                }
            }
            
            //NSLog(@"Matched EPG data with %ld out of %lu channels (%.1f%%)", 
            //      (long)totalMatches, (unsigned long)totalChannels, 
            //      (totalChannels > 0) ? ((float)totalMatches / totalChannels * 100.0) : 0.0);
        }
        @catch (NSException *exception) {
            //NSLog(@"Exception during EPG matching: %@", exception);
            // Report error to UI
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setLoadingStatusText:[NSString stringWithFormat:@"Error matching EPG: %@", [exception reason]]];
                [self setNeedsDisplay:YES];
            });
        }
        @finally {
            // Always clean up resources
            if (channelsCopy) {
                [channelsCopy release];
            }
            
            // Always reset the flag when done
            [gEpgMatchingLock lock];
            gEpgMatchingInProgress = NO;
            [gEpgMatchingLock unlock];
            
            // Final update to UI - always runs even if there was an exception
            dispatch_async(dispatch_get_main_queue(), ^{
                self.epgLoadingProgress = 1.0;
                
                // Only update completion text if we have a valid value for totalMatches
                if (totalChannels > 0) {
                    [self setLoadingStatusText:[NSString stringWithFormat:@"EPG matching complete: %ld of %ld channels matched",
                                              (long)totalMatches, (long)totalChannels]];
                } else {
                    [self setLoadingStatusText:@"EPG matching complete"];
                }
                
                // Update progress message for loading indicator
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    if (gProgressMessage) {
                        [gProgressMessage release];
                    }
                    if (totalChannels > 0) {
                        gProgressMessage = [[NSString stringWithFormat:@"epg: %ld/%ld matched (%.1f%%)",
                                           (long)totalMatches, (long)totalChannels, 
                                           ((float)totalMatches / totalChannels * 100.0)] retain];
                    } else {
                        gProgressMessage = [@"epg: matching complete" retain];
                    }
                    [gProgressMessageLock unlock];
                }
                
                // CRITICAL FIX: Refresh the channel list UI to show the newly loaded EPG data
                // This ensures the EPG programs become visible immediately without requiring a restart
                [self prepareSimpleChannelLists];
                
                [self setNeedsDisplay:YES];
                
                // Ensure EPG data is marked as loaded
                self.isEpgLoaded = YES;
                
                // Clear loading state after a short delay to show the completion message
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    self.isLoading = NO;
                    [self stopProgressRedrawTimer];
                    
                    // ADDITIONAL FIX: Force another UI refresh after clearing loading state
                    // to ensure all UI components reflect the updated EPG data
                    [self setNeedsDisplay:YES];
                    
                    // Now that we're completely done, initiate saving to cache
                    [self saveEpgDataToCache];
                });
            });
        }
    });
}

- (void)saveEpgDataToCache {
    // Forward to the implementation in the Caching category 
    // which has the actual implementation
    [[self class] instancesRespondToSelector:@selector(saveEpgDataToCache_implementation)] ? 
        [self performSelector:@selector(saveEpgDataToCache_implementation)] : 
        NSLog(@"Error: saveEpgDataToCache_implementation not found in Caching category");
}

#pragma mark - XML Processing

- (void)processEpgXmlData:(NSData *)data {
    // Create lock if it doesn't exist
    if (!gEpgMatchingLock) {
        gEpgMatchingLock = [[NSLock alloc] init];
    }
    
    // Only proceed if no matching is already in progress
    [gEpgMatchingLock lock];
    if (gEpgMatchingInProgress) {
        //NSLog(@"EPG processing already in progress. Skipping this request.");
        [gEpgMatchingLock unlock];
        return;
    }
    
    // Set flag to indicate processing has started
    gEpgMatchingInProgress = YES;
    [gEpgMatchingLock unlock];
    
    if (!data) {
        //NSLog(@"No data to process for EPG");
        
        // Clear the flag since we're exiting early
        [gEpgMatchingLock lock];
        gEpgMatchingInProgress = NO;
        [gEpgMatchingLock unlock];
        
        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoadingEpg = NO;
            self.isLoading = NO;
            [self setNeedsDisplay:YES];
        });
        return;
    }
    
    // Log the data size
    //NSLog(@"Processing EPG XML data: %lu bytes", (unsigned long)[data length]);
    
    // Update UI to show we're starting XML processing - this runs on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = YES;
        self.isLoadingEpg = YES;
        [self startProgressRedrawTimer];
        [self setLoadingStatusText:@"Starting EPG XML parsing..."];
        
        // Update progress display
        if (gProgressMessageLock) {
            [gProgressMessageLock lock];
            if (gProgressMessage) {
                [gProgressMessage release];
            }
            gProgressMessage = [[NSString stringWithFormat:@"epg: preparing to parse XML..."] retain];
            [gProgressMessageLock unlock];
        }
        
        [self setNeedsDisplay:YES];
    });
    
    // Run the actual parsing in a background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Check if we have valid XML format - detect encoding
        NSString *xmlHeader = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(100, data.length))] encoding:NSUTF8StringEncoding];
        if (xmlHeader) {
            //NSLog(@"XML header: %@", xmlHeader);
            [xmlHeader release];
        } else {
            //NSLog(@"WARNING: Could not decode XML header - may not be valid UTF-8 text");
            // Try other encodings
            xmlHeader = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN(100, data.length))] encoding:NSISOLatin1StringEncoding];
            if (xmlHeader) {
                //NSLog(@"XML header with Latin1 encoding: %@", xmlHeader);
                [xmlHeader release];
            }
        }
        
        // Create new parser
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
        if (!parser) {
            //NSLog(@"Failed to create XML parser");
            // Update UI on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoadingEpg = NO;
                self.isLoading = NO;
                [self setNeedsDisplay:YES];
            });
            return;
        }
        
        // Configure parser
        [parser setDelegate:self];
        [parser setShouldResolveExternalEntities:NO];
        
        // Create temporary structures for parsing
        currentElement = nil;
        currentProgram = nil;
        currentChannel = nil;
        currentText = [[NSMutableString alloc] init];
        
        // Add counter for progress reporting
        totalProgramCount = 0;
        totalChannelCount = 0;
        lastProgressUpdate = [NSDate timeIntervalSinceReferenceDate];
        
        // Make sure epgData is initialized
        if (!self.epgData) {
            //NSLog(@"Creating new epgData dictionary");
            self.epgData = [NSMutableDictionary dictionary];
        }
        
        // Clear existing EPG data (synchronized to avoid race conditions)
        @synchronized(self.epgData) {
            [self.epgData removeAllObjects];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoadingStatusText:@"Parsing EPG XML data..."];
            
            // Update progress display
            if (gProgressMessageLock) {
                [gProgressMessageLock lock];
                if (gProgressMessage) {
                    [gProgressMessage release];
                }
                gProgressMessage = [[NSString stringWithFormat:@"epg: starting XML parsing..."] retain];
                [gProgressMessageLock unlock];
            }
            
            [self setNeedsDisplay:YES];
        });
        
        // Setup progress tracking with a GCD timer
        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        progressTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(progressTimer, dispatch_walltime(NULL, 0), 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(progressTimer, ^{
            // Update progress every half second
            NSString *statusText = [NSString stringWithFormat:@"Parsing EPG XML: %d programs, %d channels", 
                                   totalProgramCount, totalChannelCount];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isLoading = YES;
                self.isLoadingEpg = YES;
                self.epgLoadingProgress = 0.5; // Indeterminate progress during parsing
                [self setLoadingStatusText:statusText];
                
                // Update progress display
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    if (gProgressMessage) {
                        [gProgressMessage release];
                    }
                    gProgressMessage = [[NSString stringWithFormat:@"epg: parsing | %d channels, %d programs", 
                                        totalChannelCount, totalProgramCount] retain];
                    [gProgressMessageLock unlock];
                }
                
                [self startProgressRedrawTimer];
                [self setNeedsDisplay:YES];
            });
        });
        dispatch_resume(progressTimer);
        
        // Parse the XML - this is the intensive operation
        BOOL success = [parser parse];
        
        // Stop the progress timer
        if (progressTimer) {
            dispatch_source_cancel(progressTimer);
            progressTimer = NULL;
        }
        
        // Clean up
        [parser release];
        [currentText release];
        currentText = nil;
        
        if (success) {
            // Match EPG data with channels
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setLoadingStatusText:[NSString stringWithFormat:@"Matching EPG data with channels (%d programs)...", totalProgramCount]];
                self.epgLoadingProgress = 0.7; // 70% progress for matching phase
                [self setNeedsDisplay:YES];
            });
            
            // Clear the matching flag - matchEpgWithChannels will set it again
            [gEpgMatchingLock lock];
            gEpgMatchingInProgress = NO;
            [gEpgMatchingLock unlock];
            
            // Call the matching function - it now runs asynchronously and handles its own completion
            [self matchEpgWithChannels];
            
            // Cancel the timeout since we completed successfully
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleEpgLoadingTimeout) object:nil];
            
            // Note: We don't need to initiate saveEpgDataToCache here anymore, since matchEpgWithChannels will do that when it completes
        } else {
            //NSLog(@"XML parsing failed");
            
            // Clear the flag since we're done
            [gEpgMatchingLock lock];
            gEpgMatchingInProgress = NO;
            [gEpgMatchingLock unlock];
            
            // Update UI
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setLoadingStatusText:@"Error parsing EPG data"];
                self.isLoadingEpg = NO;
                self.isLoading = NO;
                [self setNeedsDisplay:YES];
                
                // Clear error message after a delay
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (gProgressMessageLock) {
                        [gProgressMessageLock lock];
                        [gProgressMessage release];
                        gProgressMessage = nil;
                        [gProgressMessageLock unlock];
                    }
                    [self setNeedsDisplay:YES];
                });
            });
        }
    });
}

- (NSDate *)parseXmltvDate:(NSString *)dateString {
    // XMLTV date format: YYYYMMDDHHMMSS +0000
    if ([dateString length] < 14) {
        return nil;
    }
    
    NSString *yearString = [dateString substringWithRange:NSMakeRange(0, 4)];
    NSString *monthString = [dateString substringWithRange:NSMakeRange(4, 2)];
    NSString *dayString = [dateString substringWithRange:NSMakeRange(6, 2)];
    NSString *hourString = [dateString substringWithRange:NSMakeRange(8, 2)];
    NSString *minuteString = [dateString substringWithRange:NSMakeRange(10, 2)];
    NSString *secondString = [dateString substringWithRange:NSMakeRange(12, 2)];
    
    NSDateComponents *components = [[NSDateComponents alloc] init];
    [components setYear:[yearString integerValue]];
    [components setMonth:[monthString integerValue]];
    [components setDay:[dayString integerValue]];
    [components setHour:[hourString integerValue]];
    [components setMinute:[minuteString integerValue]];
    [components setSecond:[secondString integerValue]];
    
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *date = [calendar dateFromComponents:components];
    
    [components release];
    
    return date;
}

- (void)handleEpgLoadingTimeout {
    //NSLog(@"EPG loading operation timed out after 5 minutes");
    
    // Cancel any ongoing connection or operation
    if (progressTimer) {
        dispatch_source_cancel(progressTimer);
        progressTimer = NULL;
    }
    
    // Cleanup file resources
    if (gDownloadFileHandle) {
        [gDownloadFileHandle closeFile];
        [gDownloadFileHandle release];
        gDownloadFileHandle = nil;
    }

    if (gDownloadFilePath) {
        [[NSFileManager defaultManager] removeItemAtPath:gDownloadFilePath error:nil];
        [gDownloadFilePath release];
        gDownloadFilePath = nil;
    }
    
    // Clear loading state and show error
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setLoadingStatusText:@"EPG update timed out! Please try again later."];
        
        // Add a short delay before hiding the indicator completely
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.isLoadingEpg = NO;
            self.isLoading = NO;
            [self stopProgressRedrawTimer];
            
            // Clear progress message
            if (gProgressMessageLock) {
                [gProgressMessageLock lock];
                [gProgressMessage release];
                gProgressMessage = nil;
                [gProgressMessageLock unlock];
            }
            
            [self setNeedsDisplay:YES];
        });
    });
}

- (void)handleDownloadComplete {
    // Process the received XML data
    //NSLog(@"EPG download complete, received %lu bytes of data", (unsigned long)[receivedData length]);
    
    // Show download complete message - UI updates on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setLoadingStatusText:[NSString stringWithFormat:@"EPG download complete: %0.1f MB", 
                                   (float)[receivedData length] / 1048576.0]];
                                   
        // Update UI to show completion
        self.isLoading = YES;
        self.isLoadingEpg = YES;
        self.epgLoadingProgress = 1.0; // Show 100% for download phase
        [self startProgressRedrawTimer];
        [self setNeedsDisplay:YES];
        
        // Update progress display
        if (gProgressMessageLock) {
            [gProgressMessageLock lock];
            if (gProgressMessage) {
                [gProgressMessage release];
            }
            gProgressMessage = [[NSString stringWithFormat:@"Download complete: %.1f MB", 
                                (float)[receivedData length] / 1048576.0] retain];
            [gProgressMessageLock unlock];
        }
    });
    
    // Run on background thread to avoid blocking UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Check if we have valid XML data
        NSString *xmlPreview = [[NSString alloc] initWithData:[receivedData subdataWithRange:NSMakeRange(0, MIN(200, receivedData.length))] encoding:NSUTF8StringEncoding];
        //NSLog(@"EPG XML data preview: %@", xmlPreview);
        [xmlPreview release];
        
        // Brief pause before processing to show the download complete message
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setLoadingStatusText:@"Processing EPG data..."];
                
                // Update progress display
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    if (gProgressMessage) {
                        [gProgressMessage release];
                    }
                    gProgressMessage = [[NSString stringWithFormat:@"epg: preparing to process data..."] retain];
                    [gProgressMessageLock unlock];
                }
                
                self.epgLoadingProgress = 0.0; // Reset progress for processing phase
                [self setNeedsDisplay:YES];
            });
            
            // Process EPG data - this function is now fully async
            [self processEpgXmlData:receivedData];
            
            // Clean up
            [receivedData release];
            receivedData = nil;
        });
    });
}

- (void)handleDownloadError:(NSError *)error retryCount:(NSInteger)retryCount {
    //NSLog(@"EPG download error: %@", error);
    
    // Cleanup any resources
    if (gDownloadFileHandle) {
        [gDownloadFileHandle closeFile];
        [gDownloadFileHandle release];
        gDownloadFileHandle = nil;
    }
    
    if (gDownloadFilePath) {
        [[NSFileManager defaultManager] removeItemAtPath:gDownloadFilePath error:nil];
        [gDownloadFilePath release];
        gDownloadFilePath = nil;
    }
    
    // See if we can retry
    const NSInteger MAX_RETRIES = 3;
    
    if (retryCount < MAX_RETRIES) {
        //NSLog(@"Will retry EPG download (attempt %ld of %d)...", (long)retryCount + 1, (int)MAX_RETRIES);
        
        // Wait for 3 seconds before retrying to allow temporary network issues to clear
        [self setLoadingStatusText:[NSString stringWithFormat:@"Download error: %@. Retrying in 3s...", 
                                  [error localizedDescription]]];
        
        // Set UI to show we're retrying
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoadingEpg = YES;
            [self setNeedsDisplay:YES];
        });
        
        // Delayed retry
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), 
                      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self loadEpgDataWithRetryCount:retryCount + 1];
        });
    } else {
        // No more retries left - show a friendly error message
        NSString *errorMessage;
        
        if ([error.domain isEqualToString:NSURLErrorDomain]) {
            switch (error.code) {
                case NSURLErrorTimedOut:
                    errorMessage = @"Connection timed out. The server is taking too long to respond.";
                    break;
                case NSURLErrorCannotFindHost:
                    errorMessage = @"Cannot find host. Check the EPG URL.";
                    break;
                case NSURLErrorCannotConnectToHost:
                    errorMessage = @"Cannot connect to host. Server may be down.";
                    break;
                case NSURLErrorNetworkConnectionLost:
                    errorMessage = @"Network connection lost. Check your internet connection.";
                    break;
                case NSURLErrorNotConnectedToInternet:
                    errorMessage = @"Not connected to the internet.";
                    break;
                default:
                    errorMessage = [NSString stringWithFormat:@"Download error: %@", [error localizedDescription]];
                    break;
            }
        } else {
            errorMessage = [NSString stringWithFormat:@"Error: %@", [error localizedDescription]];
        }
        
        // Update UI with error message
        [self setLoadingStatusText:errorMessage];
        
        // Update UI state
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoadingEpg = NO;
            self.isLoading = NO;
            [self setNeedsDisplay:YES];
            
            // Clear error message after a delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    [gProgressMessage release];
                    gProgressMessage = nil;
                    [gProgressMessageLock unlock];
                }
                [self setNeedsDisplay:YES];
            });
        });
    }
}

#pragma mark - NSURLSessionDelegate methods

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    // Get expected content length
    expectedBytes = [response expectedContentLength];
    //NSLog(@"Received response, expected content length: %lld", expectedBytes);
    
    // Get HTTP status code
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        //NSLog(@"HTTP status code: %ld", (long)httpResponse.statusCode);
        //NSLog(@"Response headers: %@", httpResponse.allHeaderFields);
        
        if (httpResponse.statusCode != 200) {
            NSError *httpError = [NSError errorWithDomain:NSURLErrorDomain 
                                                     code:httpResponse.statusCode 
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP Error: %ld", (long)httpResponse.statusCode]}];
            [self handleDownloadError:httpError retryCount:gEpgRetryCount];
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
    }
    
    // Make sure we have a valid download file path
    if (!gDownloadFilePath) {
        gDownloadFilePath = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"temp_epg.xml"] retain];
        //NSLog(@"Creating download file path: %@", gDownloadFilePath);
    }
    
    // Create a new file handle if needed
    if (!gDownloadFileHandle) {
        // Create a new file
        [[NSFileManager defaultManager] createFileAtPath:gDownloadFilePath contents:nil attributes:nil];
        
        // Open the file for writing
        gDownloadFileHandle = [[NSFileHandle fileHandleForWritingAtPath:gDownloadFilePath] retain];
        
        if (!gDownloadFileHandle) {
            //NSLog(@"ERROR: Could not create file handle for writing to %@", gDownloadFilePath);
            NSError *fileError = [NSError errorWithDomain:@"EPGDownloader" 
                                                     code:1003 
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create file handle for writing"}];
            [self handleDownloadError:fileError retryCount:gEpgRetryCount];
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
    }
    
    // Reset file handle to start of file
    [gDownloadFileHandle seekToFileOffset:0];
    [gDownloadFileHandle truncateFileAtOffset:0];
    
    // Continue with the download
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    // Write data directly to file
    @try {
        [gDownloadFileHandle writeData:data];
        
        // Calculate progress
        if (expectedBytes > 0) {
            // Get current file size
            unsigned long long fileSize = [gDownloadFileHandle offsetInFile];
            float progress = (float)fileSize / (float)expectedBytes;
            
            // Log detailed progress at regular intervals
            static int64_t lastLoggedBytes = 0;
            const int64_t LOG_THRESHOLD = 5 * 1024 * 1024; // Log every 5MB
            
            if (fileSize - lastLoggedBytes > LOG_THRESHOLD) {
                //NSLog(@"EPG download progress: %.1f%% (%.1f/%.1f MB)", 
                //       progress * 100.0,
                 //      (float)fileSize / 1048576.0,
                 //      (float)expectedBytes / 1048576.0);
                lastLoggedBytes = fileSize;
            }
            
            // Update UI on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                self.epgLoadingProgress = progress;
                
                NSString *statusText = [NSString stringWithFormat:@"Downloading EPG data: %.1f%% (%.1f MB / %.1f MB)", 
                                       progress * 100.0,
                                       (float)fileSize / 1048576.0,
                                       (float)expectedBytes / 1048576.0];
                [self setLoadingStatusText:statusText];
                [self startProgressRedrawTimer];
                [self setNeedsDisplay:YES];
            });
        } else {
            // No content length, show indeterminate progress
            static unsigned long long lastSize = 0;
            unsigned long long fileSize = [gDownloadFileHandle offsetInFile];
            
            if (fileSize - lastSize > 1024 * 1024) { // Update every MB
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *statusText = [NSString stringWithFormat:@"Downloading EPG data: %.1f MB downloaded", 
                                           (float)fileSize / 1048576.0];
                    [self setLoadingStatusText:statusText];
                    [self startProgressRedrawTimer];
                    [self setNeedsDisplay:YES];
                });
                lastSize = fileSize;
            }
        }
    } @catch (NSException *exception) {
        //NSLog(@"Error writing data to file: %@", exception);
        NSError *error = [NSError errorWithDomain:@"EPGDownloader" 
                                             code:1001 
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to write data: %@", [exception reason]]}];
        [self handleDownloadError:error retryCount:gEpgRetryCount];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        //NSLog(@"Session task error: %@", error);
        [self handleDownloadError:error retryCount:gEpgRetryCount];
        return;
    }
    
    // Success - close file handle
    [gDownloadFileHandle closeFile];
    [gDownloadFileHandle release];
    gDownloadFileHandle = nil;
    
    // Load the data from the file
    NSError *readError = nil;
    NSData *downloadedData = [NSData dataWithContentsOfFile:gDownloadFilePath options:NSDataReadingMappedIfSafe error:&readError];
    
    if (readError || !downloadedData) {
        //NSLog(@"Error reading downloaded file: %@", readError ? [readError localizedDescription] : @"No data");
        NSError *epgError = readError ? readError : [NSError errorWithDomain:@"EPGDownload" code:1002 userInfo:@{NSLocalizedDescriptionKey: @"Failed to read downloaded data"}];
        [self handleDownloadError:epgError retryCount:gEpgRetryCount];
        
        // Clean up
        [[NSFileManager defaultManager] removeItemAtPath:gDownloadFilePath error:nil];
        [gDownloadFilePath release];
        gDownloadFilePath = nil;
        return;
    }
    
    // Success - store data and process
    [receivedData setData:downloadedData];
    
    // Clean up temp file
    [[NSFileManager defaultManager] removeItemAtPath:gDownloadFilePath error:nil];
    [gDownloadFilePath release];
    gDownloadFilePath = nil;
    
    // Handle download completion
    [self handleDownloadComplete];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    //NSLog(@"Redirecting from %@ to %@", [task.originalRequest.URL absoluteString], [request.URL absoluteString]);
    
    // Create a mutable copy to add headers that might have been lost in redirect
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    
    // Ensure User-Agent is preserved
    if (![mutableRequest valueForHTTPHeaderField:@"User-Agent"]) {
        [mutableRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" 
             forHTTPHeaderField:@"User-Agent"];
    }
    
    // Ensure Accept header is preserved
    if (![mutableRequest valueForHTTPHeaderField:@"Accept"]) {
        [mutableRequest setValue:@"application/xml, text/xml, */*" forHTTPHeaderField:@"Accept"];
    }
    
    // Ensure Accept-Encoding header is preserved
    if (![mutableRequest valueForHTTPHeaderField:@"Accept-Encoding"]) {
        [mutableRequest setValue:@"gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];
    }
    
    // Keep timeout high
    [mutableRequest setTimeoutInterval:300.0];
    
    // Continue with the modified request
    completionHandler(mutableRequest);
    [mutableRequest release];
}

#pragma mark - NSXMLParserDelegate Methods

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName 
  namespaceURI:(NSString *)namespaceURI 
 qualifiedName:(NSString *)qName 
    attributes:(NSDictionary *)attributeDict {
    
    // Store the current element name
    currentElement = elementName;
    
    // Clear the accumulated text for new element
    [currentText setString:@""];
    
    // Handle XML TV elements
    if ([elementName isEqualToString:@"tv"]) {
        // Root element - initialize 
        if (!self.epgData) {
            self.epgData = [NSMutableDictionary dictionary];
        }
        // No specific handling needed for the tv element
    }
    else if ([elementName isEqualToString:@"channel"]) {
        // Channel information
        NSString *channelId = [attributeDict objectForKey:@"id"];
        if (channelId) {
            totalChannelCount++;
            // Store channelId for associating with display-name
            currentChannel = [[NSMutableDictionary alloc] init];
            [currentChannel setObject:channelId forKey:@"id"];
        }
    }
    else if ([elementName isEqualToString:@"programme"]) {
        // Program information
        NSString *channelId = [attributeDict objectForKey:@"channel"];
        NSString *startStr = [attributeDict objectForKey:@"start"];
        NSString *stopStr = [attributeDict objectForKey:@"stop"];
        
        if (channelId) {
            totalProgramCount++;
            
            // Create a new program object
            currentProgram = [[VLCProgram alloc] init];
            currentProgram.channelId = channelId;
            
            // Parse start and end times
            if (startStr) {
                currentProgram.startTime = [self parseXmltvDate:startStr];
            }
            
            if (stopStr) {
                currentProgram.endTime = [self parseXmltvDate:stopStr];
            }
            
            // Make sure this channel exists in the epgData dictionary
            if (![self.epgData objectForKey:channelId]) {
                [self.epgData setObject:[NSMutableArray array] forKey:channelId];
            }
        }
        
        // Check for catch-up attributes
        NSString *hasArchive = [attributeDict objectForKey:@"catchup"];
        if (hasArchive && [hasArchive isEqualToString:@"1"]) {
            currentProgram.hasArchive = YES;
        }
        
        NSString *archiveDays = [attributeDict objectForKey:@"catchup-days"];
        if (archiveDays) {
            currentProgram.archiveDays = [archiveDays integerValue];
        }
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    // Append text to the current element's content
    if (currentText) {
        [currentText appendString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName 
  namespaceURI:(NSString *)namespaceURI 
 qualifiedName:(NSString *)qName {
    
    // Trim whitespace from accumulated text
    NSString *trimmedText = [currentText stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    
    // Handle XML TV elements
    if ([elementName isEqualToString:@"display-name"] && currentChannel) {
        // Set channel name if it's not already set or is empty
        if (trimmedText && [trimmedText length] > 0) {
            [currentChannel setObject:trimmedText forKey:@"display-name"];
        }
    }
    else if ([elementName isEqualToString:@"channel"]) {
        // End of channel element - add any additional processing if needed
        if (currentChannel) {
            // No need to store the channel info in EPG data as we're using channelId as the key
            [currentChannel release];
            currentChannel = nil;
            
            // Update progress message periodically for channel count
            if (totalChannelCount % 10 == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Update progress message for loading indicator
                    if (gProgressMessageLock) {
                        [gProgressMessageLock lock];
                        if (gProgressMessage) {
                            [gProgressMessage release];
                        }
                        gProgressMessage = [[NSString stringWithFormat:@"epg: parsing | %d channels, %d programs",
                                            totalChannelCount, totalProgramCount] retain];
                        [gProgressMessageLock unlock];
                    }
                    [self setNeedsDisplay:YES];
                });
            }
        }
    }
    else if ([elementName isEqualToString:@"title"] && currentProgram) {
        // Set program title
        if (trimmedText && [trimmedText length] > 0) {
            currentProgram.title = trimmedText;
        }
    }
    else if ([elementName isEqualToString:@"desc"] && currentProgram) {
        // Set program description
        if (trimmedText && [trimmedText length] > 0) {
            currentProgram.programDescription = trimmedText;
        }
    }
    else if ([elementName isEqualToString:@"programme"]) {
        // End of program element - add to the appropriate channel in EPG data
        if (currentProgram && currentProgram.channelId) {
            // Add the program to its channel's array
            NSMutableArray *programs = [self.epgData objectForKey:currentProgram.channelId];
            if (!programs) {
                programs = [NSMutableArray array];
                [self.epgData setObject:programs forKey:currentProgram.channelId];
            }
            
            [programs addObject:currentProgram];
            [currentProgram release];
            currentProgram = nil;
            
            // Log progress periodically
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (now - lastProgressUpdate > 0.5) { // Update at most twice per second
                lastProgressUpdate = now;
                //NSLog(@"Parsing progress: %d programs, %d channels", totalProgramCount, totalChannelCount);
                
                // Update UI on main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setLoadingStatusText:[NSString stringWithFormat:@"Parsing EPG data: %d programs, %d channels", 
                                              totalProgramCount, totalChannelCount]];
                    
                    // Update progress message for loading indicator
                    if (gProgressMessageLock) {
                        [gProgressMessageLock lock];
                        if (gProgressMessage) {
                            [gProgressMessage release];
                        }
                        gProgressMessage = [[NSString stringWithFormat:@"epg: parsing | %d programs, %d channels",
                                            totalProgramCount, totalChannelCount] retain];
                        [gProgressMessageLock unlock];
                    }
                    [self setNeedsDisplay:YES];
                });
            }
        }
    }
    
    // Reset the current element name
    currentElement = nil;
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    //NSLog(@"XML parsing error: %@", parseError);
    
    // Clean up any in-progress parsing
    if (currentProgram) {
        [currentProgram release];
        currentProgram = nil;
    }
    
    if (currentChannel) {
        [currentChannel release];
        currentChannel = nil;
    }
    
    // Update the UI with the error
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setLoadingStatusText:[NSString stringWithFormat:@"Error parsing EPG XML: %@", [parseError localizedDescription]]];
        self.isLoadingEpg = NO;
        [self setNeedsDisplay:YES];
    });
}

- (void)parserDidEndDocument:(NSXMLParser *)parser {
    //NSLog(@"XML parsing completed. Channels: %d, Programs: %d", totalChannelCount, totalProgramCount);
    
    // Post-process EPG data to fix missing end times
    [self postProcessEpgData];
    
    // Save to cache
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self saveEpgDataToCache];
        
        // Update status
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoadingStatusText:@"EPG data processing complete!"];
            
            // Update progress message
            if (gProgressMessageLock) {
                [gProgressMessageLock lock];
                if (gProgressMessage) {
                    [gProgressMessage release];
                }
                gProgressMessage = [[NSString stringWithFormat:@"EPG complete: %d channels, %d programs",
                                    totalChannelCount, totalProgramCount] retain];
                [gProgressMessageLock unlock];
            }
            
            // Clear loading state after a brief delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.isLoadingEpg = NO;
                self.isLoading = NO;
                
                // Clear progress message
                if (gProgressMessageLock) {
                    [gProgressMessageLock lock];
                    [gProgressMessage release];
                    gProgressMessage = nil;
                    [gProgressMessageLock unlock];
                }
                
                [self stopProgressRedrawTimer];
                [self setNeedsDisplay:YES];
                
                // Match EPG data with channels
                [self matchEpgWithChannels];
            });
        });
    });
}

// Add a new method to post-process EPG data and fix missing end times
- (void)postProcessEpgData {
    //NSLog(@"Post-processing EPG data to fix missing end times...");
    
    NSInteger fixedEndTimes = 0;
    
    // Iterate through all channels in EPG data
    for (NSString *channelId in [self.epgData allKeys]) {
        NSMutableArray *programs = [self.epgData objectForKey:channelId];
        
        if (!programs || [programs count] == 0) {
            continue;
        }
        
        // Sort programs by start time to ensure proper order
        [programs sortUsingComparator:^NSComparisonResult(VLCProgram *prog1, VLCProgram *prog2) {
            return [prog1.startTime compare:prog2.startTime];
        }];
        
        // Process each program
        for (NSInteger i = 0; i < [programs count]; i++) {
            VLCProgram *currentProgram = [programs objectAtIndex:i];
            
            // Check if this program is missing an end time
            if (!currentProgram.endTime) {
                NSDate *calculatedEndTime = nil;
                
                // Try to use the next program's start time as this program's end time
                if (i + 1 < [programs count]) {
                    VLCProgram *nextProgram = [programs objectAtIndex:i + 1];
                    if (nextProgram.startTime) {
                        calculatedEndTime = nextProgram.startTime;
                    }
                }
                
                // If no next program or next program also has no start time, estimate 1 hour
                if (!calculatedEndTime) {
                    calculatedEndTime = [currentProgram.startTime dateByAddingTimeInterval:3600]; // 1 hour
                }
                
                // Set the calculated end time
                currentProgram.endTime = calculatedEndTime;
                fixedEndTimes++;
                
                //NSLog(@"Fixed missing end time for program '%@' on channel %@", 
                //      currentProgram.title, channelId);
            }
        }
    }
    
    if (fixedEndTimes > 0) {
        //NSLog(@"Post-processing complete: Fixed %ld missing end times", (long)fixedEndTimes);
    } else {
        //NSLog(@"Post-processing complete: No missing end times found");
    }
}

// Force reload EPG data (bypass cache and always download from server)
- (void)forceReloadEpgData {
    //NSLog(@"Force reloading EPG data - bypassing cache");
    
    // Check if we have a valid EPG URL
    if (!self.epgUrl || [self.epgUrl isEqualToString:@""]) {
        //NSLog(@"No EPG URL specified for force reload");
        return;
    }
    
    // First verify that we have channel data - don't load EPG without channels
    if (!self.channels || [self.channels count] == 0) {
        //NSLog(@"Cannot force reload EPG data - no channels loaded yet. Load channel list first.");
        return;
    }
    
    //NSLog(@"Force reloading EPG data from URL: %@", self.epgUrl);
    
    // Cancel any previous timeout
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleEpgLoadingTimeout) object:nil];
    
    // Set a timeout for the entire operation (5 minutes max)
    [self performSelector:@selector(handleEpgLoadingTimeout) withObject:nil afterDelay:300.0];
    
    // Skip cache loading entirely for force reload - go straight to network download
    
    // Make sure loading indicator is showing with clear initial status
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = YES;
        self.isLoadingEpg = YES;
        [self startProgressRedrawTimer];
        [self setLoadingStatusText:@"Force updating EPG data from server..."];
        [self setNeedsDisplay:YES];
    });
    
    // Start with retry count 0
    [self loadEpgDataWithRetryCount:0];
}

@end
