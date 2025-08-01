#import "VLCOverlayView+ChannelManagement.h"

#if TARGET_OS_OSX
#import "VLCOverlayView_Private.h"
#import "VLCOverlayView+Utilities.h"
#import "DownloadManager.h"
#import "VLCSubtitleSettings.h"
#import "VLCDataManager.h"
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

// Global variable to track channel loading retry count
static NSInteger gChannelLoadRetryCount = 0;

// Add variable for tracking when the last fade-out occurred
extern NSTimeInterval lastFadeOutTime;

// Key for temporary early playback channel object
static char tempEarlyPlaybackChannelKey;

@implementation VLCOverlayView (ChannelManagement)

#pragma mark - Cache Loading Method (Compatibility)

- (BOOL)loadChannelsFromCache:(NSString *)sourcePath {
    NSLog(@"📺 macOS loadChannelsFromCache for: %@ - delegating to universal VLCDataManager", sourcePath);
    
    // UNIVERSAL APPROACH: Delegate entirely to VLCDataManager instead of duplicating logic
    VLCDataManager *dataManager = [VLCDataManager sharedManager];
    if (!dataManager.delegate) {
        dataManager.delegate = self;
    }
    
    // Use the universal channel loading method which handles caching internally
    [dataManager loadChannelsFromURL:sourcePath];
    
    return YES; // Loading initiated via universal manager
}

- (NSString *)md5HashForString:(NSString *)string {
    // Create a hash of the string for filename use
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char result[16]; // MD5 result size is 16 bytes
    CC_MD5(data.bytes, (CC_LONG)data.length, result);
    
    // Convert the MD5 hash to a hex string
    NSMutableString *hash = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) {
        [hash appendFormat:@"%02x", result[i]];
    }
    
    return hash;
}

- (NSString *)channelCacheFilePath:(NSString *)sourcePath {
    // Create a unique cache path based on the source path
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *cacheFileName;
    
    // For URLs (especially with query parameters), create a sanitized filename
    if ([sourcePath hasPrefix:@"http://"] || [sourcePath hasPrefix:@"https://"]) {
        // Create a hash of the URL to use as the filename
        NSString *hash = [self md5HashForString:sourcePath];
        cacheFileName = [NSString stringWithFormat:@"channels_%@.plist", hash];
    } else {
        // For local files, use a sanitized version of the filename
        NSString *lastComponent = [sourcePath lastPathComponent];
        if ([lastComponent length] == 0) {
            cacheFileName = @"default_channels_cache.plist";
        } else {
            // Replace any invalid filename characters
            NSCharacterSet *invalidChars = [NSCharacterSet characterSetWithCharactersInString:@":/\\?%*|\"<>"];
            NSString *sanitized = [[lastComponent componentsSeparatedByCharactersInSet:invalidChars] componentsJoinedByString:@"_"];
            cacheFileName = [NSString stringWithFormat:@"%@_cache.plist", sanitized];
        }
    }
    
    NSString *cachePath = [appSupportDir stringByAppendingPathComponent:cacheFileName];
    return cachePath;
}

- (NSString *)applicationSupportDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *appSupportDir = [paths firstObject];
    
    // Create app-specific subdirectory
    NSString *appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"];
    if (!appName) appName = @"BasicIPTV";
    
    NSString *appSpecificDir = [appSupportDir stringByAppendingPathComponent:appName];
    
    // Ensure the directory exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:appSpecificDir]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:appSpecificDir 
               withIntermediateDirectories:YES 
                                attributes:nil 
                                     error:&error];
        if (error) {
            NSLog(@"Error creating Application Support directory: %@", error);
        }
    }
    
    return appSpecificDir;
}

#pragma mark - Channel Loading

- (void)loadChannelsFile {
    // Show startup progress window
    dispatch_async(dispatch_get_main_queue(), ^{
        [self showStartupProgressWindow];
        [self updateStartupProgress:0.05 step:@"Initializing" details:@"Starting BasicIPTV..."];
        
        self.isLoading = YES;
        [self setNeedsDisplay:YES];
        
        // Start the progress redraw timer to ensure UI updates
        [self startProgressRedrawTimer];
    });
    
    // First load any saved settings
    [self updateStartupProgress:0.10 step:@"Loading Settings" details:@"Reading saved preferences..."];
    [self loadSettings];
    
    // Check if m3uFilePath is already set
    if (!self.m3uFilePath) {
        // First check if channels.m3u exists in the application directory
        NSString *appDirPath = [[NSBundle mainBundle] resourcePath];
        NSString *localChannelsPath = [appDirPath stringByAppendingPathComponent:@"channels.m3u"];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:localChannelsPath]) {
            // Use the channels.m3u in the application directory
            self.m3uFilePath = localChannelsPath;
            //NSLog(@"Using channels file from app directory: %@", self.m3uFilePath);
        } else {
            // Default to Application Support, but don't create a file
            self.m3uFilePath = [self localM3uFilePath];
            //NSLog(@"Setting m3uFilePath to Application Support: %@", self.m3uFilePath);
        }
    }
    
    //NSLog(@"Loading channels from: %@", self.m3uFilePath);
    
    // Check if the m3uFilePath is a URL
    BOOL isLoadingFromCache = NO;
    
    // First try to load from cache to get immediate content
    if (![self.m3uFilePath hasPrefix:@"http://"] && ![self.m3uFilePath hasPrefix:@"https://"] &&
        ![self.m3uFilePath hasPrefix:@"HTTP://"] && ![self.m3uFilePath hasPrefix:@"HTTPS://"]) {
        // Try to load from file path directly
        [self loadChannelsFromM3uFile:self.m3uFilePath];
    } else {
        // For URLs, check if we should download new content or use cache
        NSString *cacheFilePath = [self channelCacheFilePath:self.m3uFilePath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:cacheFilePath]) {
            // Cache exists, try to load it
            if ([self loadChannelsFromCache:self.m3uFilePath]) {
                //NSLog(@"Successfully loaded channels from cache: %@", cacheFilePath);
                isLoadingFromCache = YES;
                
                // Show message but don't keep loading indicator if we're only using cache
                dispatch_async(dispatch_get_main_queue(), ^{
                    // Check last download time from Application Support settings file instead of UserDefaults
                    NSString *settingsPath = [self settingsFilePath];
                    NSDictionary *settingsDict = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
                    NSDate *lastDownload = [settingsDict objectForKey:@"LastM3UDownloadDate"];
                    if (lastDownload) {
                        NSTimeInterval timeSince = [[NSDate date] timeIntervalSinceDate:lastDownload];
                        int hoursAgo = (int)(timeSince / 3600);
                        [self setLoadingStatusText:[NSString stringWithFormat:@"Using cached channels (last downloaded %d hours ago)", hoursAgo]];
                    } else {
                        [self setLoadingStatusText:@"Using cached channels"];
                    }
                    
                    // Hide loading indicator after showing message briefly
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        self.isLoading = NO;
                        [self setNeedsDisplay:YES];
                    });
                });
            }
        }
        
        // Check if we need to refresh the M3U based on age
        BOOL shouldDownloadM3U = [self shouldUpdateM3UAtStartup];
        
        // If we loaded from cache but still need to refresh, do it in the background
        if (isLoadingFromCache && shouldDownloadM3U) {
            //NSLog(@"Refreshing M3U data in background (cache is older than 1 day)");
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // Download the fresh content
                NSURL *url = [NSURL URLWithString:self.m3uFilePath];
                [self loadChannelsFromM3uURL:url];
            });
        } 
        // If we didn't load from cache or need refresh, download directly
        else if (!isLoadingFromCache || shouldDownloadM3U) {
            //NSLog(@"Downloading M3U data (no cache or forced refresh)");
            // Load from URL
            NSURL *url = [NSURL URLWithString:self.m3uFilePath];
            [self loadChannelsFromM3uURL:url];
        } else {
            // Cache was loaded and refresh not needed
            //NSLog(@"Using cached M3U data (updated within the last day)");
            self.isLoading = NO;
            [self setNeedsDisplay:YES];
        }
    }
    
    // Load EPG data if available - but only after a delay to ensure channels are loaded first
    if (self.epgUrl && [self.epgUrl length] > 0) {
        // Check if we need to update the EPG data
        BOOL shouldDownloadEPG = [self shouldUpdateEPGAtStartup];
        
        if (shouldDownloadEPG) {
            //NSLog(@"Loading EPG data (older than 6 hours or doesn't exist)");
            // Load EPG data with a slight delay to avoid overwhelming network
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [[VLCDataManager sharedManager] loadEPGFromURL:self.epgUrl];
            });
        } else {
            //NSLog(@"Using cached EPG data (updated within the last 6 hours)");
            // Try to load existing EPG data from cache
            // Load EPG via VLCDataManager if available, otherwise skip cache-only loading
        }
    }
}

- (void)loadChannelsFromM3uFile:(NSString *)path {
    // Prepare the file path
    NSString *filePath = path;
    if (!filePath) {
        //NSLog(@"No m3u file path specified");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            [self setNeedsDisplay:YES];
        });
        return;
    }
    
    // Log which file we're loading from
    //NSLog(@"Attempting to load channels from: %@", filePath);
    [self updateStartupProgress:0.15 step:@"Checking Cache" details:@"Looking for cached channel data..."];
    [self setLoadingStatusText:@"Checking for cached channels..."];
    
    // First, check if this is a URL path and if there's a cache file for it
    BOOL hasCache = NO;
    BOOL isUrl = [filePath hasPrefix:@"http://"] || [filePath hasPrefix:@"https://"];
    
    if (isUrl) {
        NSString *cachePath = [self channelCacheFilePath:filePath];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        hasCache = [fileManager fileExistsAtPath:cachePath];
        
        if (hasCache) {
            //NSLog(@"Cache file exists for URL: %@", cachePath);
        } else {
            //NSLog(@"No cache file exists for URL: %@", cachePath);
        }
    }
    
    // Try to load from cache if it's a URL (preferred) or move on to other methods
    if (isUrl && hasCache) {
        if ([self loadChannelsFromCache:filePath]) {
            //NSLog(@"Successfully loaded channels from cache");
            // Loading completes in the loadChannelsFromCache method
            return;
        }
    }
    
    // If we got here, it means:
    // 1. It's not a URL
    // 2. It's a URL but no cache exists
    // 3. It's a URL with cache, but cache loading failed
    
    [self setLoadingStatusText:@"Loading channel list..."];
    
    // Try to load the file - might be a URL or local file
    if (isUrl) {
        [self setLoadingStatusText:@"Downloading channel list from server..."];
        [self loadChannelsFromUrl:filePath];
    } else {
        [self setLoadingStatusText:@"Reading local channel list file..."];
        [self loadChannelsFromLocalFile:filePath];
    }
}

- (void)loadChannelsFromM3uURL:(NSURL *)url {
    if (!url) {
        //NSLog(@"Invalid URL passed to loadChannelsFromM3uURL:");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            [self setLoadingStatusText:@"Error: Invalid URL"];
            [self setNeedsDisplay:YES];
        });
        return;
    }
    
    //NSLog(@"Loading channels from URL: %@", url);
    [self loadChannelsFromUrl:[url absoluteString]];
}

- (void)loadChannelsFromUrl:(NSString *)urlStr {
    [self loadChannelsFromUrl:urlStr retryCount:0];
}

- (void)loadChannelsFromUrl:(NSString *)urlStr retryCount:(NSInteger)retryCount {
    NSLog(@"🔄 [MAC] loadChannelsFromUrl called - delegating to VLCDataManager: %@", urlStr);
    
    // Validate URL first
    if (!urlStr || [urlStr length] == 0) {
        NSLog(@"❌ [MAC] Invalid URL string passed to loadChannelsFromUrl");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLoadingStatusText:@"Error: Invalid URL"];
            self.isLoading = NO;
            [self setNeedsDisplay:YES];
        });
        return;
    }
    
    // Use VLCDataManager to load channels (delegate callbacks will handle results)
    [self.dataManager loadChannelsFromURL:urlStr];
    NSLog(@"✅ [MAC] Channel loading initiated via VLCDataManager - results will come via delegate");
    
    return; // Skip the old implementation completely

    /* OLD IMPLEMENTATION COMMENTED OUT - NOW USING VLCDataManager
    // Set up temporary file
    NSString *tempFileName = [NSString stringWithFormat:@"temp_channels_%@.m3u", [[NSUUID UUID] UUIDString]];
    NSString *tempFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempFileName];
    
    // Remove any existing file
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ([fileManager fileExistsAtPath:tempFilePath]) {
        [fileManager removeItemAtPath:tempFilePath error:nil];
    }
    
    // Update UI to show we're starting a download
    if (retryCount > 0) {
        [self setLoadingStatusText:[NSString stringWithFormat:@"Retry %d of %d: Connecting to %@...", 
                                    (int)retryCount, (int)MAX_RETRIES, [url host]]];
    } else {
        [self setLoadingStatusText:[NSString stringWithFormat:@"Connecting to %@ to download channel list...", [url host]]];
    }
    
    // Add more detailed download information
    //NSLog(@"Starting M3U download from: %@", urlStr);
    
    // Update progress corner message
    if (!gProgressMessageLock) {
        gProgressMessageLock = [[NSLock alloc] init];
    }
    
    [gProgressMessageLock lock];
    if (gProgressMessage) {
        [gProgressMessage release];
    }
    gProgressMessage = [[NSString stringWithFormat:@"m3u: connecting to %@...", [url host]] retain];
    [gProgressMessageLock unlock];
    
    // Update the UI to show we're in a loading state
    dispatch_async(dispatch_get_main_queue(), ^{
        self.epgLoadingProgress = 0.0;
        [self setNeedsDisplay:YES];
    });
    
    // Set up download manager
    DownloadManager *manager = [[DownloadManager alloc] init];
    //NSLog(@"Starting channel list download from URL: %@ (retry: %ld)", urlStr, (long)retryCount);
    
    [manager startDownloadFromURL:urlStr
                  progressHandler:^(int64_t received, int64_t total) {
                      // Calculate progress percentage
                      float progress = (total > 0) ? ((float)received / (float)total) : 0.0f;
                      
                      // Log variables
                      static int64_t lastLoggedBytes = 0;
                      const int64_t LOG_THRESHOLD = 256 * 1024; // Log every 256KB for more frequent updates
                      
                      // Calculate download speed first
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
                      
                      // Now log the progress with the calculated speed
                      if (received - lastLoggedBytes > LOG_THRESHOLD) {
                          //NSLog(@"Channel list download progress: %.1f%% (%.1f/%.1f MB) - Speed: %.2f MB/s", 
                                //progress * 100.0,
                                //(float)received / 1048576.0,
                                //(float)total / 1048576.0,
                                //speedMBps);
                          lastLoggedBytes = received;
                          
                          // Also print more detailed info to console
                          //NSLog(@"Download details: Received: %lld bytes, Total: %lld bytes, Progress: %.2f%%", 
                           //     received, total, progress * 100.0);
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
                          
                          // Format speed for display
                          NSString *speedDisplay = @"";
                          if (speedMBps > 0) {
                              speedDisplay = [NSString stringWithFormat:@"%.1f MB/s", speedMBps];
                          }
                          
                          // Create a more detailed status for the corner display
                          gProgressMessage = [[NSString stringWithFormat:@"Downloading: %.1f%% %@", 
                                              progress * 100.0, sizeInfo] retain];
                          [gProgressMessageLock unlock];
                          
                          // Make sure we're regularly updating the display
                          [self startProgressRedrawTimer];
                          [self setNeedsDisplay:YES];
                      });
                  }
                completionHandler:^(NSString *filePath, NSError *error) {
                      // Check for error
                      if (error) {
                          //NSLog(@"Channel list download failed: %@", error);
                          
                          // If we haven't exceeded retry count, try again
                          if (retryCount < MAX_RETRIES) {
                              //NSLog(@"Channel list download failed, retrying (attempt %ld of %d)...", 
                              //      (long)retryCount + 1, (int)MAX_RETRIES);
                              
                              // Wait 3 seconds before retrying
                              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), 
                                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                  [self loadChannelsFromUrl:urlStr retryCount:retryCount + 1];
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
                                      errorMsg = @"Cannot find host. Check the URL and network connection.";
                                      break;
                                  case NSURLErrorCannotConnectToHost:
                                      errorMsg = @"Cannot connect to host. Server may be down.";
                                      break;
                                  case NSURLErrorNetworkConnectionLost:
                                      errorMsg = @"Network connection lost. Check your internet connection.";
                                      break;
                                  case NSURLErrorNotConnectedToInternet:
                                      errorMsg = @"Not connected to the internet.";
                                      break;
                                  default:
                                      errorMsg = [NSString stringWithFormat:@"Download error: %@", [error localizedDescription]];
                                      break;
                              }
                          } else {
                              errorMsg = [NSString stringWithFormat:@"Error: %@", [error localizedDescription]];
                          }
                          
                          [self setLoadingStatusText:errorMsg];
                          
                          // Update UI
                          dispatch_async(dispatch_get_main_queue(), ^{
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
                      
                      // Download succeeded
                      //NSLog(@"Channel list download complete, saved to: %@", filePath);
                      
                      // Get file size for reporting
                      NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
                      unsigned long long fileSize = [fileAttributes fileSize];
                      
                      // Log detailed completion info
                      //NSLog(@"Channel list download summary:");
                      //NSLog(@"- File size: %.2f MB", (float)fileSize / 1048576.0);
                      //NSLog(@"- Saved to: %@", filePath);
                      
                      // Show completion message with file size
                      [self setLoadingStatusText:[NSString stringWithFormat:@"Download complete: %.2f MB", 
                                               (float)fileSize / 1048576.0]];
                                               
                      // Update the corner progress display
                      if (gProgressMessageLock) {
                          [gProgressMessageLock lock];
                          if (gProgressMessage) {
                              [gProgressMessage release];
                          }
                          gProgressMessage = [[NSString stringWithFormat:@"Download complete: %.2f MB", 
                                           (float)fileSize / 1048576.0] retain];
                          [gProgressMessageLock unlock];
                      }
                      
                      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                          // Make sure the loading indicator is still showing with progress
                          dispatch_async(dispatch_get_main_queue(), ^{
                              self.isLoading = YES;
                              [self startProgressRedrawTimer];
                              [self setLoadingStatusText:@"Processing downloaded channel list..."];
                              [self setNeedsDisplay:YES];
                          });
                          
                          // Now load from the local temp file, keeping the original URL for proper caching
                          [self loadChannelsFromLocalFile:filePath];
                          
                          // Also copy to Application Support directory for future use
                          NSString *localPath = [self localM3uFilePath];
                          
                          // Make sure the directory exists
                          NSString *directory = [localPath stringByDeletingLastPathComponent];
                          NSFileManager *fileManager = [NSFileManager defaultManager];
                          if (![fileManager fileExistsAtPath:directory]) {
                              NSError *dirError = nil;
                              [fileManager createDirectoryAtPath:directory 
                                      withIntermediateDirectories:YES 
                                                       attributes:nil 
                                                            error:&dirError];
                              if (dirError) {
                                  //NSLog(@"Error creating Application Support directory: %@", dirError);
                              }
                          }
                          
                          // Copy the downloaded file
                          NSError *copyError = nil;
                          if ([fileManager fileExistsAtPath:localPath]) {
                              [fileManager removeItemAtPath:localPath error:nil];
                          }
                          [fileManager copyItemAtPath:filePath toPath:localPath error:&copyError];
                          
                          if (copyError) {
                              //NSLog(@"Error saving channel file to Application Support: %@", copyError);
                          } else {
                              //NSLog(@"Successfully saved channel file to Application Support: %@", localPath);
                          }
                      });
                      
                      // Clean up the download manager
                      [manager release];
                  }
                  destinationPath:tempFilePath];
    */ // END OLD IMPLEMENTATION COMMENT
}

- (void)loadChannelsFromLocalFile:(NSString *)filePath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:filePath]) {
        //NSLog(@"M3U file not found at path: %@", filePath);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            [self setNeedsDisplay:YES];
        });
        return;
    }
    
    // Read the file
    NSError *error = nil;
    NSString *fileContents = [NSString stringWithContentsOfFile:filePath 
                                                      encoding:NSUTF8StringEncoding 
                                                         error:&error];
    
    if (error || !fileContents) {
        //NSLog(@"Error reading M3U file: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            [self setNeedsDisplay:YES];
        });
        return;
    }
    
    // Process the M3U content - now handled by VLCDataManager
    NSLog(@"📺 macOS: Delegating M3U content processing to VLCDataManager");
    [self.dataManager loadChannelsFromURL:filePath];
}

- (void)processM3uContent:(NSString *)content sourcePath:(NSString *)sourcePath {
    NSLog(@"📺 macOS processM3uContent - now handled by VLCDataManager/VLCChannelManager");
    // VLCDataManager/VLCChannelManager now handles all M3U processing universally
    return;
    
    /* OLD IMPLEMENTATION - NOW HANDLED BY VLCDataManager/VLCChannelManager
    // Split content into lines and validate
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    NSUInteger lineCount = [lines count];
    
    // Only proceed if we have content to process
    if (lineCount == 0) {
        //NSLog(@"M3U content is empty or invalid");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            [self setNeedsDisplay:YES];
            
            // Show an error message
            [self setLoadingStatusText:@"Error: Empty or invalid M3U file"];
            
            // Clear error message after a delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self setLoadingStatusText:@""];
            });
        });
        return;
    }
    
    // Save favorites before processing new content
    NSMutableDictionary *savedFavorites = [NSMutableDictionary dictionary];
    NSArray *favoriteGroups = [self safeGroupsForCategory:@"FAVORITES"];
    if (favoriteGroups && favoriteGroups.count > 0) {
        [savedFavorites setObject:favoriteGroups forKey:@"groups"];
        
        NSMutableArray *favoriteChannels = [NSMutableArray array];
        for (NSString *group in favoriteGroups) {
            NSArray *groupChannels = [self.channelsByGroup objectForKey:group];
            if (groupChannels) {
                for (VLCChannel *channel in groupChannels) {
                    NSMutableDictionary *channelDict = [NSMutableDictionary dictionary];
                    [channelDict setObject:(channel.name ? channel.name : @"") forKey:@"name"];
                    [channelDict setObject:(channel.url ? channel.url : @"") forKey:@"url"];
                    [channelDict setObject:(channel.group ? channel.group : @"") forKey:@"group"];
                    if (channel.logo) [channelDict setObject:channel.logo forKey:@"logo"];
                    if (channel.channelId) [channelDict setObject:channel.channelId forKey:@"channelId"];
                    [channelDict setObject:@"FAVORITES" forKey:@"category"];
                    
                    [favoriteChannels addObject:channelDict];
                }
            }
        }
        if (favoriteChannels.count > 0) {
            [savedFavorites setObject:favoriteChannels forKey:@"channels"];
        }
        //NSLog(@"Saved %lu favorite groups with %lu channels before M3U processing", 
        //     (unsigned long)favoriteGroups.count, (unsigned long)favoriteChannels.count);
    }
    
    // Initialize tracking variables
    NSUInteger totalChannelsFound = 0;
    BOOL isReadingExtInf = NO;
    NSMutableDictionary *currentExtInfo = [NSMutableDictionary dictionary];
    NSString *currentTitle = nil;
    NSString *currentTvgId = nil;
    
    // Initialize data structures - now handled by VLCDataManager
    NSLog(@"🔧 Data structures initialized by VLCDataManager automatically");
    
    // Progress update
    [self setLoadingStatusText:@"Processing channels..."];
    
    // Process lines
    for (NSUInteger lineIndex = 0; lineIndex < lineCount; lineIndex++) {
        // Update progress periodically (every 100 lines for more detailed updates)
        if (lineIndex % 100 == 0) {
            NSUInteger percentage = (lineIndex * 100) / lineCount;
            [self setLoadingStatusText:[NSString stringWithFormat:@"Processing: %lu%% (%lu/%lu) - %lu channels found", 
                                       (unsigned long)percentage, 
                                       (unsigned long)lineIndex, 
                                       (unsigned long)lineCount,
                                       (unsigned long)totalChannelsFound]];
        }
        
        NSString *line = [lines objectAtIndex:lineIndex];
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // Skip empty lines and comments
        if ([line length] == 0 || ([line hasPrefix:@"#"] && ![line hasPrefix:@"#EXTINF"])) {
            continue;
        }
        
        // Handle EXTINF line
        if ([line hasPrefix:@"#EXTINF"]) {
            isReadingExtInf = YES;
            
            // Reset current info
            [currentExtInfo removeAllObjects];
            currentTitle = nil;
            currentTvgId = nil;
            
            // Extract TV-G ID attribute if present - now handled by VLCChannelManager
            // currentTvgId = [self extractTvgIdFromExtInfLine:line]; // DISABLED - VLCChannelManager handles this
            currentTvgId = nil; // VLCChannelManager will handle tvg-id extraction
            
            // Extract attributes from line
            NSString *attributePart = nil;
            NSString *titlePart = nil;
            
            // Find the first comma which separates attributes from the title
            NSRange commaRange = [line rangeOfString:@","];
            if (commaRange.location != NSNotFound) {
                attributePart = [line substringToIndex:commaRange.location];
                titlePart = [line substringFromIndex:commaRange.location + 1];
                
                // Store the title
                currentTitle = [titlePart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                
                // Parse other attributes like group-title, tvg-logo, etc.
                // Example: #EXTINF:-1 tvg-id="abc" tvg-logo="logo.png" group-title="News",Channel Name
                
                // Extract group attribute
                NSRange groupRange = [line rangeOfString:@"group-title=\""];
                if (groupRange.location != NSNotFound) {
                    NSUInteger startPos = groupRange.location + groupRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, [line length] - startPos)];
                    
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *groupName = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        [currentExtInfo setObject:groupName forKey:@"group"];
                        
                        // Debug: Log unique groups as we find them
                        static NSMutableSet *seenGroups = nil;
                        if (!seenGroups) seenGroups = [[NSMutableSet alloc] init];
                        if (![seenGroups containsObject:groupName]) {
                            [seenGroups addObject:groupName];
                            //NSLog(@"🔧 Found new group: '%@' (total unique groups so far: %lu)", groupName, (unsigned long)[seenGroups count]);
                        }
                    }
                }
                
                // Extract logo URL
                NSRange logoRange = [line rangeOfString:@"tvg-logo=\""];
                if (logoRange.location != NSNotFound) {
                    NSUInteger startPos = logoRange.location + logoRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, [line length] - startPos)];
                    
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *logoUrl = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        [currentExtInfo setObject:logoUrl forKey:@"logo"];
                        
                        // Debug logging for logo extraction
                       // NSLog(@"Found tvg-logo in M3U: '%@' for channel: '%@'", 
                       //       logoUrl, titlePart ? titlePart : @"Unknown");
                    }
                }
                
                // Extract catch-up attributes
                // catchup="1" or catchup="default" indicates channel supports time-shifting
                NSRange catchupRange = [line rangeOfString:@"catchup=\""];
                if (catchupRange.location != NSNotFound) {
                    NSUInteger startPos = catchupRange.location + catchupRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, [line length] - startPos)];
                    
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *catchupValue = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        [currentExtInfo setObject:catchupValue forKey:@"catchup"];
                    }
                }
                
                // Extract catch-up days (how many days back the channel supports)
                NSRange catchupDaysRange = [line rangeOfString:@"catchup-days=\""];
                if (catchupDaysRange.location != NSNotFound) {
                    NSUInteger startPos = catchupDaysRange.location + catchupDaysRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, [line length] - startPos)];
                    
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *catchupDays = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        [currentExtInfo setObject:catchupDays forKey:@"catchup-days"];
                    }
                }
                
                // Extract catch-up source type
                NSRange catchupSourceRange = [line rangeOfString:@"catchup-source=\""];
                if (catchupSourceRange.location != NSNotFound) {
                    NSUInteger startPos = catchupSourceRange.location + catchupSourceRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, [line length] - startPos)];
                    
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *catchupSource = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        [currentExtInfo setObject:catchupSource forKey:@"catchup-source"];
                    }
                }
                
                // Extract catch-up template (URL template for time-shifting)
                NSRange catchupTemplateRange = [line rangeOfString:@"catchup-template=\""];
                if (catchupTemplateRange.location != NSNotFound) {
                    NSUInteger startPos = catchupTemplateRange.location + catchupTemplateRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, [line length] - startPos)];
                    
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *catchupTemplate = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        [currentExtInfo setObject:catchupTemplate forKey:@"catchup-template"];
                    }
                }
            }
            
            continue;
        }
        
        // Handle channel URL line (after EXTINF)
        if (isReadingExtInf) {
            isReadingExtInf = NO;
            
            // Create channel object
            VLCChannel *channel = [[VLCChannel alloc] init];
            channel.name = currentTitle ? currentTitle : @"Unknown";
            channel.url = line;
            channel.programs = [NSMutableArray array];
            
            // Set channel ID
            if (currentTvgId && [currentTvgId length] > 0) {
                // Use tvg-id if found
                channel.channelId = [currentTvgId lowercaseString]; // Ensure lowercase for matching
            } else {
                // Generate a channel ID
                NSString *generatedId = [NSString stringWithFormat:@"channel-%d", (int)totalChannelsFound];
                channel.channelId = generatedId;
            }
            
            // Set group
            NSString *groupName = [currentExtInfo objectForKey:@"group"];
            if (!groupName) {
                // Default group if none specified
                groupName = @"Ungrouped";
            }
            channel.group = groupName;
            
            // Set logo URL
            channel.logo = [currentExtInfo objectForKey:@"logo"];
            if (channel.logo) {
                //NSLog(@"Assigned logo URL '%@' to channel '%@'", channel.logo, channel.name);
            }
            
            // Set catch-up properties
            NSString *catchupValue = [currentExtInfo objectForKey:@"catchup"];
            if (catchupValue) {
                // FIXED: Only consider specific valid catchup values as supporting timeshift
                // Remove the overly permissive "[catchupValue length] > 0" condition that was causing false positives
                channel.supportsCatchup = ([catchupValue isEqualToString:@"1"] || 
                                         [catchupValue isEqualToString:@"default"] || 
                                         [catchupValue isEqualToString:@"append"] ||
                                         [catchupValue isEqualToString:@"timeshift"] ||
                                         [catchupValue isEqualToString:@"shift"]);
                channel.catchupSource = catchupValue;
                
                //NSLog(@"Channel '%@' supports catch-up: %@ (source: %@)", 
                //      channel.name, channel.supportsCatchup ? @"YES" : @"NO", catchupValue);
            }
            
            NSString *catchupDaysStr = [currentExtInfo objectForKey:@"catchup-days"];
            if (catchupDaysStr) {
                channel.catchupDays = [catchupDaysStr integerValue];
                //NSLog(@"Channel '%@' catch-up days: %ld", channel.name, (long)channel.catchupDays);
            } else if (channel.supportsCatchup) {
                // Default to 7 days if catch-up is supported but no days specified
                channel.catchupDays = 7;
            }
            
            channel.catchupTemplate = [currentExtInfo objectForKey:@"catchup-template"];
            
            // IMPROVED CATEGORIZATION LOGIC
            
            // Default category
            NSString *category = @"TV";
            NSString *upperCaseGroup = [groupName uppercaseString];
            NSString *upperCaseTitle = [channel.name uppercaseString];
            
            // 1. Check for movie file extensions in URL
            BOOL isMovieFile = NO;
            NSArray *movieExtensions = @[@".MP4", @".MKV", @".AVI", @".MOV", @".WEBM", @".FLV", @".MPG", @".MPEG", @".WMV", @".VOB", @".3GP", @".M4V"];
            
            // Get the file extension using our helper method
            NSString *fileExtension = [self fileExtensionFromUrl:channel.url];
            if (fileExtension) {
                for (NSString *extension in movieExtensions) {
                    if ([fileExtension isEqualToString:extension]) {
                        isMovieFile = YES;
                        break;
                    }
                }
            }
            
            // 2. Check for episode markers in title
            BOOL hasEpisodeMarkers = ([upperCaseTitle rangeOfString:@"S0"].location != NSNotFound || 
                                     [upperCaseTitle rangeOfString:@"S1"].location != NSNotFound ||
                                     [upperCaseTitle rangeOfString:@"S2"].location != NSNotFound || 
                                     [upperCaseTitle rangeOfString:@"E0"].location != NSNotFound ||
                                     [upperCaseTitle rangeOfString:@"E1"].location != NSNotFound ||
                                     [upperCaseTitle rangeOfString:@"E2"].location != NSNotFound);
            
            // 3. Check for series keywords in group name
            BOOL isSeriesGroup = ([upperCaseGroup rangeOfString:@"SERIES"].location != NSNotFound ||
                                 [upperCaseGroup rangeOfString:@"SHOW"].location != NSNotFound ||
                                 [upperCaseGroup rangeOfString:@"EPISOD"].location != NSNotFound);
            
            // Categorization decision - SIMPLIFIED
            if (isMovieFile) {
                // If it's a movie file with episode markers, it's a series
                if (hasEpisodeMarkers) {
                    category = @"SERIES";
                } else {
                    category = @"MOVIES";
                    //NSLog(@"Categorized as MOVIE: '%@' (has logo: %@)", channel.name, channel.logo ? @"YES" : @"NO");
                }
            } else {
                // If not a movie file, always categorize as TV regardless of other factors
                category = @"TV";
            }
            
            // Set the final category
            channel.category = category;
            
            // Add to master list
            [self.channels addObject:channel];
            
            // Add to groups list if needed
            if (![self.groups containsObject:groupName]) {
                [self.groups addObject:groupName];
                NSLog(@"🔧 Added group to groups: '%@' (total groups: %lu)", groupName, (unsigned long)[self.groups count]);
            }
            
            // Add to category groups
            NSMutableArray *categoryGroups = [self.groupsByCategory objectForKey:category];
            if (!categoryGroups) {
                categoryGroups = [NSMutableArray array];
                [self.groupsByCategory setObject:categoryGroups forKey:category];
            }
            
            if (![categoryGroups containsObject:groupName]) {
                [categoryGroups addObject:groupName];
            }
            
            // Add to channels-by-group
            NSMutableArray *channelsInGroup = [self.channelsByGroup objectForKey:groupName];
            if (!channelsInGroup) {
                channelsInGroup = [NSMutableArray array];
                [self.channelsByGroup setObject:channelsInGroup forKey:groupName];
            }
            
            [channelsInGroup addObject:channel];
            
            // Release channel after adding it to collections
            [channel release];
            
            // Reset for next entry
            currentTitle = nil;
            currentTvgId = nil; // Important: reset tvg-id for next channel
            totalChannelsFound++;
        }
    }
    
    // Final progress update and debug logging
    NSLog(@"🔧 CHANNEL PROCESSING COMPLETE: Found %lu channels in %lu groups", 
          (unsigned long)totalChannelsFound, (unsigned long)self.groups.count);
    NSLog(@"🔧 Data structure sizes: channels=%lu, groups=%lu, channelsByGroup=%lu, groupsByCategory=%lu", 
          (unsigned long)[self.channels count], (unsigned long)[self.groups count], 
          (unsigned long)[self.channelsByGroup count], (unsigned long)[self.groupsByCategory count]);
    
    [self setLoadingStatusText:[NSString stringWithFormat:@"Loaded %lu channels in %lu groups", 
                                (unsigned long)totalChannelsFound, (unsigned long)self.groups.count]];
    
    // Prepare our simple display arrays
    [self prepareSimpleChannelLists];
    
    // Save the channel data to cache for faster loading
    [self setLoadingStatusText:@"Saving channels to cache..."];
    // Make sure we're using the original URL as the source path for the cache
    // instead of the temporary file path
    NSString *cacheSourcePath = self.m3uFilePath;
    // Cache saving is now handled automatically by VLCDataManager/VLCCacheManager
    NSLog(@"📺 Cache saving delegated to VLCDataManager - no manual caching needed");
    
    // Ensure favorites category
    [self ensureFavoritesCategory];
    
    // Restore saved favorites after processing
    if (savedFavorites.count > 0) {
        // Restore favorite groups
        NSArray *favoriteGroups = [savedFavorites objectForKey:@"groups"];
        if (favoriteGroups && [favoriteGroups isKindOfClass:[NSArray class]]) {
            NSMutableArray *favoritesArray = [self.groupsByCategory objectForKey:@"FAVORITES"];
            if (!favoritesArray) {
                favoritesArray = [NSMutableArray array];
                [self.groupsByCategory setObject:favoritesArray forKey:@"FAVORITES"];
            }
            
            // Add favorite groups
            for (NSString *group in favoriteGroups) {
                if (![favoritesArray containsObject:group]) {
                    [favoritesArray addObject:group];
                    // Initialize empty array for this group if it doesn't exist
                    if (![self.channelsByGroup objectForKey:group]) {
                        [self.channelsByGroup setObject:[NSMutableArray array] forKey:group];
                    }
                }
            }
        }
        
        // Restore favorite channels
        NSArray *favoriteChannels = [savedFavorites objectForKey:@"channels"];
        if (favoriteChannels && [favoriteChannels isKindOfClass:[NSArray class]]) {
            for (NSDictionary *channelDict in favoriteChannels) {
                if (![channelDict isKindOfClass:[NSDictionary class]]) continue;
                
                // Create a new channel object
                VLCChannel *channel = [[VLCChannel alloc] init];
                channel.name = [channelDict objectForKey:@"name"];
                channel.url = [channelDict objectForKey:@"url"];
                channel.group = [channelDict objectForKey:@"group"];
                channel.logo = [channelDict objectForKey:@"logo"];
                channel.channelId = [channelDict objectForKey:@"channelId"];
                // CRITICAL: Preserve original category (MOVIES, SERIES, TV) to maintain display format
                channel.category = [channelDict objectForKey:@"category"] ?: @"TV";
                channel.programs = [NSMutableArray array];
                
                // Add to appropriate group
                NSMutableArray *groupChannels = [self.channelsByGroup objectForKey:channel.group];
                if (!groupChannels) {
                    groupChannels = [NSMutableArray array];
                    [self.channelsByGroup setObject:groupChannels forKey:channel.group];
                }
                
                // Check for duplicates
                BOOL alreadyInGroup = NO;
                for (VLCChannel *existingChannel in groupChannels) {
                    if ([existingChannel.url isEqualToString:channel.url]) {
                        alreadyInGroup = YES;
                        break;
                    }
                }
                
                if (!alreadyInGroup) {
                    [groupChannels addObject:channel];
                }
                
                [channel release];
            }
        }
        
        //NSLog(@"Restored %lu favorite groups after M3U processing", 
        //   (unsigned long)[[savedFavorites objectForKey:@"groups"] count]);
    }
    
    // Ensure Settings options
    [self ensureSettingsGroups];
    
    // Update UI on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = NO;
        [self setNeedsDisplay:YES];
        
        // Load movie info from cache for all movie channels immediately after loading
        [self loadAllMovieInfoFromCache];
        
        // Auto-fetch catch-up information from API after M3U loading completes
        [self autoFetchCatchupInfo];
        
        // NOW start EPG loading if we have a URL (AFTER M3U processing is complete)
        if (self.epgUrl && [self.epgUrl length] > 0) {
            //NSLog(@"M3U processing complete - starting EPG download from: %@", self.epgUrl);
            [self setLoadingStatusText:@"Channels loaded - starting EPG download..."];
            
            // Start EPG loading in background after a short delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // Update status to show EPG download starting
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setLoadingStatusText:@"Downloading EPG data..."];
                    self.isLoading = YES; // Re-enable loading state for EPG
                    [self setNeedsDisplay:YES];
                });
                
                // Force reload EPG data (bypass cache)
                [[VLCDataManager sharedManager] loadEPGFromURL:self.epgUrl];
            });
        } else {
            //NSLog(@"M3U processing complete - no EPG URL configured");
        }
        
        // Start preloading all movie info and covers in the background
        // with a short delay to let the UI update first
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), 
                      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // DISABLED: Don't preload all movie info - only load for visible items
            // [self preloadAllMovieInfoAndCovers];
            //NSLog(@"📱 Movie info loading optimized: Will load only for visible items on demand");
        });
    });
    */
}

- (NSString *)extractTitleFromExtInfLine:(NSString *)line {
    NSLog(@"📺 macOS extractTitleFromExtInfLine - now handled by VLCChannelManager");
    // VLCChannelManager now handles all M3U parsing universally
    return @"Unknown Channel";
    
    /* OLD IMPLEMENTATION - NOW HANDLED BY VLCChannelManager
    // Look for the last comma in the line - after that is the title
    NSRange commaRange = [line rangeOfString:@"," options:NSBackwardsSearch];
    if (commaRange.location != NSNotFound) {
        NSUInteger titleStart = commaRange.location + 1;
        NSString *title = [line substringFromIndex:titleStart];
        return title;
    }
    
    // If no comma found, return everything after the colon
    NSRange colonRange = [line rangeOfString:@":"];
    if (colonRange.location != NSNotFound) {
        NSUInteger titleStart = colonRange.location + 1;
        NSString *title = [line substringFromIndex:titleStart];
        return title;
    }
    
    return @"Unknown Channel";
    */
}

- (NSString *)extractGroupFromExtInfLine:(NSString *)line {
    NSLog(@"📺 macOS extractGroupFromExtInfLine - now handled by VLCChannelManager");
    // VLCChannelManager now handles all M3U parsing universally
    return nil;
    
    /* OLD IMPLEMENTATION - NOW HANDLED BY VLCChannelManager
    NSString *group = nil;
    
    // Look for group-title attribute
    NSRange groupRange = [line rangeOfString:@"group-title=\""];
    if (groupRange.location != NSNotFound) {
        NSUInteger startIdx = groupRange.location + groupRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" 
                                           options:0 
                                             range:NSMakeRange(startIdx, line.length - startIdx)];
        
        if (endQuoteRange.location != NSNotFound) {
            group = [line substringWithRange:NSMakeRange(startIdx, endQuoteRange.location - startIdx)];
        }
    }
    
    // If not found, try tvg-group
    if (!group) {
        groupRange = [line rangeOfString:@"tvg-group=\""];
        if (groupRange.location != NSNotFound) {
            NSUInteger startIdx = groupRange.location + groupRange.length;
            NSRange endQuoteRange = [line rangeOfString:@"\"" 
                                               options:0 
                                                 range:NSMakeRange(startIdx, line.length - startIdx)];
            
            if (endQuoteRange.location != NSNotFound) {
                group = [line substringWithRange:NSMakeRange(startIdx, endQuoteRange.location - startIdx)];
            }
        }
    }
    
    return group;
    */
}

- (NSString *)extractTvgIdFromExtInfLine:(NSString *)line {
    NSLog(@"📺 macOS extractTvgIdFromExtInfLine - now handled by VLCChannelManager");
    // VLCChannelManager now handles all M3U parsing universally
    return nil;
    
    /* OLD IMPLEMENTATION - NOW HANDLED BY VLCChannelManager
    NSString *tvgId = nil;
    
    // Look for tvg-id attribute
    NSRange tvgIdRange = [line rangeOfString:@"tvg-id=\""];
    if (tvgIdRange.location != NSNotFound) {
        NSUInteger startIdx = tvgIdRange.location + tvgIdRange.length;
        NSRange endQuoteRange = [line rangeOfString:@"\"" 
                                          options:0 
                                            range:NSMakeRange(startIdx, line.length - startIdx)];
        
        if (endQuoteRange.location != NSNotFound) {
            tvgId = [line substringWithRange:NSMakeRange(startIdx, endQuoteRange.location - startIdx)];
        }
    }
    
    return tvgId;
    */
}

- (BOOL)safeAddGroupToCategory:(NSString *)group category:(NSString *)category {
    if (!group || !category) return NO;
    
    @try {
        NSMutableArray *groups = [self.groupsByCategory objectForKey:category];
        if (!groups) {
            groups = [NSMutableArray array];
            [self.groupsByCategory setObject:groups forKey:category];
        }
        
        if (![groups containsObject:group]) {
            [groups addObject:group];
            return YES;
        }
    } @catch (NSException *exception) {
        //NSLog(@"Exception adding group %@ to category %@: %@", group, category, exception);
    }
    
    return NO;
}

#pragma mark - Channel playback

// New method to handle channel playback by index
- (void)playChannelAtIndex:(NSInteger)index {
    [self hideControls];
    if (index < 0 || index >= [self.simpleChannelNames count]) {
        //NSLog(@"Invalid channel index: %ld", (long)index);
        return;
    }
    
    NSString *url = [self.simpleChannelUrls objectAtIndex:index];
    if (!url || ![url isKindOfClass:[NSString class]] || [url length] == 0) {
        //NSLog(@"Invalid URL for channel at index %ld", (long)index);
        return;
    }
    
    // Save the current selection as the last played selection
    [self saveLastSelectedIndices];
    
    [self playChannelWithUrl:url];
}

- (void)playChannel:(VLCChannel *)channel {
    [self hideControls];
    if (channel == nil) {
        NSLog(@"Invalid channel");
        return;
    }
    
    // Add better checks for URL validity
    if (channel.url == nil || ![channel.url isKindOfClass:[NSString class]] || [channel.url length] == 0) {
        //NSLog(@"Invalid or empty URL for channel: %@", channel.name);
        return;
    }
    
    // Get the URL object
    NSURL *url = [NSURL URLWithString:channel.url];
    if (!url) {
        //NSLog(@"Error: Invalid URL format: %@", channel.url);
        return;
    }
    
    // Stop current playback and clear time state to prevent stale time info
    if (self.player) {
        // Save current playback position before stopping (for resume functionality)
        [self saveCurrentPlaybackPosition];
        
        [self.player stop];
        
        // Force a brief pause to allow VLC to properly reset time state
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            //NSLog(@"Time state cleared, starting new media playback for channel: %@", channel.name);
            
            // Create a media object
            VLCMedia *media = [VLCMedia mediaWithURL:url];
            
            // Set the media to the player
            [self.player setMedia:media];
            
            // Clear cached timeshift channel since we're playing normal content
            if ([self respondsToSelector:@selector(clearCachedTimeshiftChannel)]) {
                [self clearCachedTimeshiftChannel];
            }
            
            // Apply subtitle settings before starting playback
            [VLCSubtitleSettings applyCurrentSettingsToPlayer:self.player];
            
            // Start playing
            [self.player play];
            
            // Check for saved resume position for this content (with delay to let media load)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Use the actual media URL for consistency with saving
                NSString *actualMediaURL = [self.player.media.url absoluteString];
                if (actualMediaURL) {
                    //NSLog(@"=== RESUME: Using actual media URL: %@ ===", actualMediaURL);
                    [self resumePlaybackPositionForURL:actualMediaURL];
                } else {
                    // Fallback to original URL
                    //NSLog(@"=== RESUME: Fallback to channel URL: %@ ===", channel.url);
                    [self resumePlaybackPositionForURL:channel.url];
                }
            });
            
            // Force UI update to reflect new time state
            [self setNeedsDisplay:YES];
        });
    }
    
    // Save the last played channel URL (for backwards compatibility)
    [self saveLastPlayedChannelUrl:channel.url];
    
    // Save detailed content info for early startup
    [self saveLastPlayedContentInfo:channel];
    
    // Clear any temporary early playback channel since we're now playing new content
    objc_setAssociatedObject(self, &tempEarlyPlaybackChannelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Cancel any ongoing fade animations
    extern BOOL isFadingOut;
    extern NSTimeInterval lastFadeOutTime;
    
    if (isFadingOut) {
        // If we're in the middle of a fade, stop it
        [[self animator] setAlphaValue:1.0];
        [[NSAnimationContext currentContext] setDuration:0.0];
    }
    
    // First, we need to make sure the menu is visible
    self.isChannelListVisible = YES;
    [self setAlphaValue:1.0];
    
    // Set fading out flag to prevent mouse movements from showing menu during fade
    isFadingOut = YES;
    
    // Use shorter delay and animation time
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Start a quicker fade out animation
        [NSAnimationContext beginGrouping];
        [[NSAnimationContext currentContext] setDuration:0.5]; // Shorter fade
        [[self animator] setAlphaValue:0.0];
        [NSAnimationContext endGrouping];
        
        // After the fade completes, reset everything cleanly
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Ensure menu is hidden
            self.isChannelListVisible = NO;
            [self setAlphaValue:1.0]; // Reset alpha for next time
            
            // Set the last fade-out time to record when we hid the menu
            NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
            lastFadeOutTime = currentTime;
            
            // Reset the interaction flags
            isFadingOut = NO;
            isUserInteracting = NO;
            
            // Set interaction time to current time
            lastInteractionTime = currentTime;
            
            // Refresh tracking area
            [self setupTrackingArea];
            [self setNeedsDisplay:YES];
        });
    });
}

- (void)playChannelWithUrl:(NSString *)urlString {
    // Add stronger validation for URL string
    if (urlString == nil || ![urlString isKindOfClass:[NSString class]] || [urlString length] == 0) {
        //NSLog(@"Invalid or empty URL string");
        return;
    }
    
    // Get the URL object
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        //NSLog(@"Error: Invalid URL format: %@", urlString);
        return;
    }
    
    // Stop current playback and clear time state to prevent stale time info
    if (self.player) {
        // Save current playback position before stopping (for resume functionality)
        [self saveCurrentPlaybackPosition];
        
        [self.player stop];
        
        // Force a brief pause to allow VLC to properly reset time state
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            //NSLog(@"Time state cleared, starting new media playback for URL: %@", urlString);
            
            // Create a media object
            VLCMedia *media = [VLCMedia mediaWithURL:url];
            
            // Set the media to the player
            [self.player setMedia:media];
            
            // Clear cached timeshift channel since we're playing normal content
            if ([self respondsToSelector:@selector(clearCachedTimeshiftChannel)]) {
                [self clearCachedTimeshiftChannel];
            }
            
            // Apply subtitle settings before starting playback
            [VLCSubtitleSettings applyCurrentSettingsToPlayer:self.player];
            
            // Start playing
            [self.player play];
            
            // Check for saved resume position for this content (with delay to let media load)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Use the actual media URL for consistency with saving
                NSString *actualMediaURL = [self.player.media.url absoluteString];
                if (actualMediaURL) {
                    //NSLog(@"=== RESUME: Using actual media URL: %@ ===", actualMediaURL);
                    [self resumePlaybackPositionForURL:actualMediaURL];
                } else {
                    // Fallback to original URL
                    //NSLog(@"=== RESUME: Fallback to URL string: %@ ===", urlString);
                    [self resumePlaybackPositionForURL:urlString];
                }
            });
            
            // Force UI update to reflect new time state
            [self setNeedsDisplay:YES];
        });
    }
    
    // Save the last played channel URL (for backwards compatibility)
    [self saveLastPlayedChannelUrl:urlString];
    
    // Try to find the channel object to save detailed info
    VLCChannel *foundChannel = nil;
    if (self.channels) {
        for (VLCChannel *channel in self.channels) {
            if ([channel.url isEqualToString:urlString]) {
                foundChannel = channel;
                break;
            }
        }
    }
    
    if (foundChannel) {
        // Save detailed content info for early startup
        [self saveLastPlayedContentInfo:foundChannel];
        //NSLog(@"Saved detailed content info for channel: %@", foundChannel.name);
    } else {
        // Create a minimal channel object with just the URL and save it
        VLCChannel *minimalChannel = [[VLCChannel alloc] init];
        minimalChannel.url = urlString;
        
        // Try to extract channel name from simple channel lists if available
        if (self.simpleChannelUrls && self.simpleChannelNames) {
            NSInteger urlIndex = [self.simpleChannelUrls indexOfObject:urlString];
            if (urlIndex != NSNotFound && urlIndex < [self.simpleChannelNames count]) {
                minimalChannel.name = [self.simpleChannelNames objectAtIndex:urlIndex];
                //NSLog(@"Found channel name from simple lists: %@", minimalChannel.name);
            }
        }
        
        if (!minimalChannel.name) {
            minimalChannel.name = @"Unknown Channel";
        }
        
        [self saveLastPlayedContentInfo:minimalChannel];
        [minimalChannel release];
        //NSLog(@"Saved minimal content info for URL: %@", urlString);
    }
    
    // Clear any temporary early playback channel since we're now playing new content
    objc_setAssociatedObject(self, &tempEarlyPlaybackChannelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Skip fade-out animation if we're navigating with arrow keys
    if (!self.isArrowKeyNavigating) {
        // Cancel any ongoing fade animations
        extern BOOL isFadingOut;
        extern NSTimeInterval lastFadeOutTime;
        
        if (isFadingOut) {
            // If we're in the middle of a fade, stop it
            [[self animator] setAlphaValue:1.0];
            [[NSAnimationContext currentContext] setDuration:0.0];
        }
        
        // First, we need to make sure the menu is visible
        self.isChannelListVisible = YES;
        [self setAlphaValue:1.0];
        
        // Set fading out flag to prevent mouse movements from showing menu during fade
        isFadingOut = YES;
        
        // Use shorter delay and animation time
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Start a quicker fade out animation
            [NSAnimationContext beginGrouping];
            [[NSAnimationContext currentContext] setDuration:0.5]; // Shorter fade
            [[self animator] setAlphaValue:0.0];
            [NSAnimationContext endGrouping];
            
            // After the fade completes, reset everything cleanly
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Ensure menu is hidden
                self.isChannelListVisible = NO;
                [self setAlphaValue:1.0]; // Reset alpha for next time
                
                // Set the last fade-out time to record when we hid the menu
                NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
                lastFadeOutTime = currentTime;
                
                // Reset the interaction flags
                isFadingOut = NO;
                isUserInteracting = NO;
                
                // Set interaction time to current time
                lastInteractionTime = currentTime;
                
                // Refresh tracking area
                [self setupTrackingArea];
                [self setNeedsDisplay:YES];
            });
        });
    }
}

- (void)saveLastPlayedChannelUrl:(NSString *)urlString {
    if (!urlString || [urlString length] == 0) {
        return;
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:urlString forKey:@"LastPlayedChannelURL"];
    [defaults synchronize];
    
    //NSLog(@"Saved last played channel URL: %@", urlString);
}

- (NSString *)getLastPlayedChannelUrl {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *url = [defaults objectForKey:@"LastPlayedChannelURL"];
    return url;
}

// Add a new method to force reload from URL regardless of cache
- (void)forceReloadChannelsAndEpg {
    // Show loading indicator
    self.isLoading = YES;
    [self setNeedsDisplay:YES];
    
    // Start the progress redraw timer to ensure UI updates
    [self startProgressRedrawTimer];
    [self setLoadingStatusText:@"Force downloading fresh channel list from URL..."];
    
    // Check if m3uFilePath is a URL
    if ([self.m3uFilePath hasPrefix:@"http://"] || [self.m3uFilePath hasPrefix:@"https://"]) {
        NSLog(@"🚀 [FORCE-RELOAD] Force downloading fresh channels from URL (bypassing cache): %@", self.m3uFilePath);
        
        // CRITICAL FIX: Use VLCDataManager's force reload method to bypass cache
        [self.dataManager forceReloadChannelsFromURL:self.m3uFilePath];
        NSLog(@"✅ [FORCE-RELOAD] Force reload initiated via VLCDataManager - results will come via delegate");
        
        // DON'T load EPG here - it will be loaded after M3U processing is complete
        // The EPG loading will be triggered from processM3uContent when it completes
    } else {
        // Not a URL - just do regular load
        [self loadChannelsFile];
    }
}

// Helper method to extract file extension from a URL path
- (NSString *)fileExtensionFromUrl:(NSString *)urlString {
    if (!urlString || [urlString length] == 0) {
        return nil;
    }
    
    // Remove query parameters
    NSRange queryRange = [urlString rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        urlString = [urlString substringToIndex:queryRange.location];
    }
    
    // Check for file extension in the path
    NSString *extension = nil;
    NSRange lastDotRange = [urlString rangeOfString:@"." options:NSBackwardsSearch];
    
    if (lastDotRange.location != NSNotFound) {
        // Get everything after the last dot
        extension = [urlString substringFromIndex:lastDotRange.location];
        
        // Only consider it an extension if it's short and contains only valid chars
        // (This helps avoid false positives like domain names)
        if ([extension length] <= 5) {
            NSCharacterSet *validExtChars = [NSCharacterSet alphanumericCharacterSet];
            NSString *extensionChars = [extension substringFromIndex:1]; // Skip the dot
            
            // Check if all characters are valid for a file extension
            BOOL isValid = YES;
            for (NSUInteger i = 0; i < [extensionChars length]; i++) {
                unichar c = [extensionChars characterAtIndex:i];
                if (![validExtChars characterIsMember:c]) {
                    isValid = NO;
                    break;
                }
            }
            
            if (isValid) {
                return [extension uppercaseString];
            }
        }
    }
    
    return nil;
}

// Extract movie ID from URL 
- (NSString *)extractMovieIdFromUrl:(NSString *)url {
    if (!url) return nil;
    
    // For URLs ending with a filename like ../367233.mkv, extract the ID (367233)
    NSString *lastPathComponent = [url lastPathComponent];
    if (lastPathComponent.length > 0) {
        // Extract the numeric part before the extension
        NSRange dotRange = [lastPathComponent rangeOfString:@"." options:NSBackwardsSearch];
        NSString *filenameWithoutExtension = lastPathComponent;
        
        if (dotRange.location != NSNotFound) {
            filenameWithoutExtension = [lastPathComponent substringToIndex:dotRange.location];
        }
        
        // Now check if the filename is numeric
        if ([self isNumeric:filenameWithoutExtension]) {
            //NSLog(@"Extracted movie ID from filename: %@", filenameWithoutExtension);
            return filenameWithoutExtension;
        }
    }
    
    // Try to extract ID from query parameters
    NSRange idParamRange = [url rangeOfString:@"id="];
    if (idParamRange.location != NSNotFound) {
        NSString *restOfUrl = [url substringFromIndex:idParamRange.location + idParamRange.length];
        NSArray *components = [restOfUrl componentsSeparatedByString:@"&"];
        if (components.count > 0) {
            NSString *idValue = components[0];
            if ([idValue length] > 0 && [self isNumeric:idValue]) {
                //NSLog(@"Found movie ID in query parameter: %@", idValue);
                return idValue;
            }
        }
    }
    
    // Try to extract from path components
    // Look for numeric parts in the path that might be IDs
    NSString *pattern = @"/([0-9]+)(/|\\.|$)";
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
    
    if (!error) {
        NSArray *matches = [regex matchesInString:url options:0 range:NSMakeRange(0, [url length])];
        if (matches.count > 0) {
            NSTextCheckingResult *match = [matches lastObject]; // Use the last match, likely the most specific
            if (match.numberOfRanges > 1) { // Group 1 contains our ID
                NSRange idRange = [match rangeAtIndex:1];
                NSString *idValue = [url substringWithRange:idRange];
                if ([idValue length] > 0) {
                    //NSLog(@"Extracted movie ID from path: %@", idValue);
                    return idValue;
                }
            }
        }
    }
    
    // If we couldn't extract an ID, return nil
    return nil;
}

// Helper to check if a string is numeric
- (BOOL)isNumeric:(NSString *)string {
    NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
}

// Construct API URL for movie info
- (NSString *)constructMovieApiUrlForChannel:(VLCChannel *)channel {
    // We need: server, port, username, password, and movie ID
    if (!channel || !self.m3uFilePath) return nil;
    
    NSString *movieId = channel.movieId;
    if (!movieId) {
        movieId = [self extractMovieIdFromUrl:channel.url];
        if (!movieId) {
            //NSLog(@"Failed to extract movie ID from URL: %@", channel.url);
            return nil;
        }
        channel.movieId = movieId;
    }
    
    // Parse server information from M3U URL
    NSURL *m3uURL = [NSURL URLWithString:self.m3uFilePath];
    if (!m3uURL) return nil;
    
    NSString *scheme = [m3uURL scheme];
    NSString *host = [m3uURL host];
    NSNumber *port = [m3uURL port];
    NSString *portString = port ? [NSString stringWithFormat:@":%@", port] : @"";
    
    // Extract username and password
    NSString *username = @"";
    NSString *password = @"";
    
    // First try to get from query parameters
    NSString *query = [m3uURL query];
    if (query) {
        NSArray *queryItems = [query componentsSeparatedByString:@"&"];
        for (NSString *item in queryItems) {
            NSArray *keyValue = [item componentsSeparatedByString:@"="];
            if (keyValue.count == 2) {
                NSString *key = keyValue[0];
                NSString *value = keyValue[1];
                
                if ([key isEqualToString:@"username"]) {
                    username = value;
                } else if ([key isEqualToString:@"password"]) {
                    password = value;
                }
            }
        }
    }
    
    // If not found in query, try path components
    if (username.length == 0 || password.length == 0) {
        NSString *path = [m3uURL path];
        NSArray *pathComponents = [path pathComponents];
        
        // Look for typical username/password segments in the URL path
        for (NSInteger i = 0; i < pathComponents.count - 1; i++) {
            // Username is often after "get.php" or similar pattern
            if ([pathComponents[i] hasSuffix:@".php"] && i + 1 < pathComponents.count) {
                username = pathComponents[i + 1];
                
                // Password typically follows the username
                if (i + 2 < pathComponents.count) {
                    password = pathComponents[i + 2];
                    break;
                }
            }
        }
    }
    
    // Construct the API URL
    NSString *apiUrl = [NSString stringWithFormat:@"%@://%@%@/player_api.php?username=%@&password=%@&action=get_vod_info&vod_id=%@",
                        scheme, host, portString, username, password, movieId];
    
    //NSLog(@"Constructed movie API URL: %@", apiUrl);
    return apiUrl;
}

// Fetch movie information from the API
- (void)fetchMovieInfoForChannel:(VLCChannel *)channel {
    if (!channel || channel.hasLoadedMovieInfo) return;
    
    // Try to load from cache first before making network request
    if ([self loadMovieInfoFromCacheForChannel:channel]) {
        //NSLog(@"✅ Loaded movie info from cache for: %@", channel.name);
        return; // Successfully loaded from cache, no need to fetch from network
    }
    
    NSString *apiUrl = [self constructMovieApiUrlForChannel:channel];
    if (!apiUrl) {
        //NSLog(@"Failed to construct movie API URL for channel: %@", channel.name);
        return;
    }
    
    //NSLog(@"Fetching movie info from: %@", apiUrl);
    
    // Create the URL request with more robust timeout handling
    NSURL *url = [NSURL URLWithString:apiUrl];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url 
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData 
                                                       timeoutInterval:15.0]; // Increased timeout
    
    // Set user agent to avoid potential blocking
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36" forHTTPHeaderField:@"User-Agent"];
    
    // Create and begin an asynchronous data task
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request 
                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            // Categorize the error for better handling
            BOOL isNetworkError = NO;
            BOOL shouldRetry = NO;
            NSString *errorCategory = @"Unknown";
            
            if (error) {
                NSInteger errorCode = [error code];
                switch (errorCode) {
                    case NSURLErrorTimedOut:
                        errorCategory = @"Timeout";
                        shouldRetry = YES;
                        isNetworkError = YES;
                        break;
                    case NSURLErrorNetworkConnectionLost:
                    case NSURLErrorNotConnectedToInternet:
                        errorCategory = @"Network Connection Lost";
                        shouldRetry = YES;
                        isNetworkError = YES;
                        break;
                    case NSURLErrorCannotConnectToHost:
                    case NSURLErrorCannotFindHost:
                        errorCategory = @"Cannot Connect to Server";
                        shouldRetry = YES;
                        isNetworkError = YES;
                        break;
                    case NSURLErrorHTTPTooManyRedirects:
                        errorCategory = @"Too Many Redirects";
                        shouldRetry = NO;
                        break;
                    case NSURLErrorBadURL:
                        errorCategory = @"Invalid URL";
                        shouldRetry = NO;
                        break;
                    default:
                        errorCategory = [NSString stringWithFormat:@"Network Error %ld", (long)errorCode];
                        shouldRetry = (errorCode >= -1099 && errorCode <= -1000); // Most network errors
                        isNetworkError = YES;
                        break;
                }
            }
            
            //NSLog(@"🔴 Movie info fetch failed for '%@' - %@: %@", 
            //      channel.name, errorCategory, error.localizedDescription);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Always reset the fetching flag to allow retry
                channel.hasStartedFetchingMovieInfo = NO;
                
                // For network errors, we'll allow automatic retry later
                // For other errors (like bad URL), we won't retry automatically
                if (isNetworkError && shouldRetry) {
                    // Don't mark as loaded, allowing the system to retry later
                    //NSLog(@"📡 Network error for '%@' - will retry automatically later", channel.name);
                } else {
                    //NSLog(@"❌ Permanent error for '%@' - manual retry required", channel.name);
                }
                
                // Trigger UI update
                [self setNeedsDisplay:YES];
            });
            
            return;
        }
        
        //NSLog(@"📥 Received movie data for '%@' (%lu bytes)", channel.name, (unsigned long)[data length]);
        
        // Validate HTTP response code
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSInteger statusCode = [httpResponse statusCode];
            
            if (statusCode < 200 || statusCode >= 300) {
                //NSLog(@"🔴 HTTP error %ld for movie info fetch: %@", (long)statusCode, channel.name);
                dispatch_async(dispatch_get_main_queue(), ^{
                    channel.hasStartedFetchingMovieInfo = NO; // Reset for retry
                    [self setNeedsDisplay:YES];
                });
                return;
            }
        }
        
        // Parse the JSON response
        NSError *jsonError = nil;
        NSDictionary *jsonResponse = [NSJSONSerialization JSONObjectWithData:data 
                                                                    options:0 
                                                                      error:&jsonError];
        
        if (jsonError || !jsonResponse) {
            //NSLog(@"🔴 JSON parsing error for '%@': %@", channel.name, jsonError.localizedDescription);
            // Reset fetch status on JSON error
            dispatch_async(dispatch_get_main_queue(), ^{
                channel.hasStartedFetchingMovieInfo = NO; // Reset so we can try again later
                [self setNeedsDisplay:YES];
            });
            return;
        }
        
        // Extract info from response
        NSDictionary *info = [jsonResponse objectForKey:@"info"];
        if (!info || ![info isKindOfClass:[NSDictionary class]]) {
            //NSLog(@"🔴 Invalid movie info response format for '%@' - no 'info' object", channel.name);
            
            // Print the response for debugging (first 500 chars only to avoid spam)
            NSString *responseStr = [jsonResponse description];
            if (responseStr.length > 500) {
                responseStr = [[responseStr substringToIndex:500] stringByAppendingString:@"..."];
            }
            //NSLog(@"📋 Response received for '%@': %@", channel.name, responseStr);
            
            // Reset fetch status on format error
            dispatch_async(dispatch_get_main_queue(), ^{
                channel.hasStartedFetchingMovieInfo = NO; // Reset so we can try again later
                [self setNeedsDisplay:YES];
            });
            return;
        }
        
        // Set movie metadata properties on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Safely extract and convert values to strings if needed
            id plotObj = [info objectForKey:@"plot"];
            channel.movieDescription = [plotObj isKindOfClass:[NSString class]] ? 
                                       plotObj : [NSString stringWithFormat:@"%@", plotObj];
                                       
            id genreObj = [info objectForKey:@"genre"];
            channel.movieGenre = [genreObj isKindOfClass:[NSString class]] ? 
                                 genreObj : [NSString stringWithFormat:@"%@", genreObj];
                                 
            id durationObj = [info objectForKey:@"duration"];
            channel.movieDuration = [durationObj isKindOfClass:[NSString class]] ? 
                                    durationObj : [NSString stringWithFormat:@"%@", durationObj];
                                    
            id yearObj = [info objectForKey:@"releasedate"];
            channel.movieYear = [yearObj isKindOfClass:[NSString class]] ? 
                               yearObj : [NSString stringWithFormat:@"%@", yearObj];
                               
            id ratingObj = [info objectForKey:@"rating"];
            channel.movieRating = [ratingObj isKindOfClass:[NSString class]] ? 
                                 ratingObj : [NSString stringWithFormat:@"%@", ratingObj];
                                 
            id directorObj = [info objectForKey:@"director"];
            channel.movieDirector = [directorObj isKindOfClass:[NSString class]] ? 
                                   directorObj : [NSString stringWithFormat:@"%@", directorObj];
                                   
            id castObj = [info objectForKey:@"cast"];
            channel.movieCast = [castObj isKindOfClass:[NSString class]] ? 
                               castObj : [NSString stringWithFormat:@"%@", castObj];
            
            // Update movie logo if available and not already set
            NSString *coverUrl = [info objectForKey:@"movie_image"];
            if (coverUrl && (!channel.logo || [channel.logo length] == 0)) {
                channel.logo = coverUrl;
                //NSLog(@"Updated movie logo URL from API: %@", coverUrl);
            }
            
            channel.hasLoadedMovieInfo = YES;
            //NSLog(@"Successfully loaded movie info for: %@", channel.name);
            
            // Save the movie info to cache after successful fetching
            [self saveMovieInfoToCache:channel];
            
            // Trigger UI update if this channel is being displayed
            if (self.hoveredChannelIndex >= 0) {
                VLCChannel *hoveredChannel = [self getChannelAtHoveredIndex];
                if (hoveredChannel == channel) {
                    [self setNeedsDisplay:YES];
                }
            }
        });
    }];
    
    // Start the data task
    [dataTask resume];
}

#pragma mark - Proactive Movie Info and Cover Loading

// Add a new method for preloading all movie info and covers
- (void)preloadAllMovieInfoAndCovers {
    // Get all movie channels
    NSMutableArray *movieChannels = [NSMutableArray array];
    
    // Iterate through all categories and groups to find all movie channels
    for (NSString *category in [self.groupsByCategory allKeys]) {
        NSArray *groups = [self.groupsByCategory objectForKey:category];
        for (NSString *group in groups) {
            NSArray *channels = [self.channelsByGroup objectForKey:group];
            for (VLCChannel *channel in channels) {
                if ([channel.category isEqualToString:@"MOVIES"] && 
                    !channel.hasLoadedMovieInfo) {
                    [movieChannels addObject:channel];
                }
            }
        }
    }
    
    //NSLog(@"Found %lu movie channels to preload", (unsigned long)movieChannels.count);
    
    // Process in batches to avoid overwhelming the system
    const NSInteger BATCH_SIZE = 5;
    const CGFloat DELAY_BETWEEN_BATCHES = 2.0; // seconds
    
    // Start batch processing
    [self processBatchOfMovieChannels:movieChannels batchSize:BATCH_SIZE delayBetweenBatches:DELAY_BETWEEN_BATCHES currentIndex:0];
}

// Process channels in batches
- (void)processBatchOfMovieChannels:(NSArray *)movieChannels 
                          batchSize:(NSInteger)batchSize 
                 delayBetweenBatches:(CGFloat)delay 
                        currentIndex:(NSInteger)currentIndex {
    
    // Check if we've finished processing all channels
    if (currentIndex >= movieChannels.count) {
        //NSLog(@"Completed preloading all movie info and covers");
        return;
    }
    
    // Calculate the end index for this batch
    NSInteger endIndex = MIN(currentIndex + batchSize, movieChannels.count);
    
    // Process this batch
    //NSLog(@"Processing movie info batch %ld to %ld of %lu", 
    //     (long)currentIndex, (long)endIndex - 1, (unsigned long)movieChannels.count);
         
    dispatch_group_t group = dispatch_group_create();
    
    for (NSInteger i = currentIndex; i < endIndex; i++) {
        VLCChannel *channel = [movieChannels objectAtIndex:i];
        dispatch_group_enter(group);
        
        // Check if movie info is already cached before fetching
        BOOL loadedFromCache = [self loadMovieInfoFromCacheForChannel:channel];
        
        if (!loadedFromCache && !channel.hasStartedFetchingMovieInfo) {
            channel.hasStartedFetchingMovieInfo = YES;
            
            // Load movie info
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                //NSLog(@"Preloading movie info for channel %@ (%ld of %lu)", 
                //     channel.name, (long)i, (unsigned long)movieChannels.count);
                     
                [self fetchMovieInfoForChannel:channel];
                
                // After fetching movie info, also load the image if needed
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (channel.logo && !channel.cachedPosterImage) {
                        //NSLog(@"Preloading cover image for channel %@", channel.name);
                        [self loadImageAsynchronously:channel.logo forChannel:channel];
                    }
                    dispatch_group_leave(group);
                });
            });
        } else {
            // Already loaded from cache or started fetching
            if (loadedFromCache) {
                //NSLog(@"Movie info for %@ already loaded from cache", channel.name);
                
                // Still load the image if needed
                if (channel.logo && !channel.cachedPosterImage) {
                    //NSLog(@"Preloading cover image for channel %@", channel.name);
                    [self loadImageAsynchronously:channel.logo forChannel:channel];
                }
            }
            dispatch_group_leave(group);
        }
    }
    
    // Schedule the next batch after current batch completes
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Clean up
        [group release];
        
        // Schedule next batch after delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), 
                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self processBatchOfMovieChannels:movieChannels 
                                    batchSize:batchSize 
                           delayBetweenBatches:delay 
                                  currentIndex:endIndex];
        });
    });
}

// Process channels in batches with progress tracking
- (void)processBatchOfMovieChannelsWithProgress:(NSArray *)movieChannels 
                                      batchSize:(NSInteger)batchSize 
                             delayBetweenBatches:(CGFloat)delay 
                                    currentIndex:(NSInteger)currentIndex {
    
    // Check if we've finished processing all channels
    if (currentIndex >= movieChannels.count) {
       // NSLog(@"Completed refreshing all movie info and covers");
        
        // Reset refresh state on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isRefreshingMovieInfo = NO;
            self.movieRefreshCompleted = self.movieRefreshTotal;
            [self setNeedsDisplay:YES];
        });
        return;
    }
    
    // Calculate the end index for this batch
    NSInteger endIndex = MIN(currentIndex + batchSize, movieChannels.count);
    
    // Process this batch
    //NSLog(@"Processing movie info batch %ld to %ld of %lu", 
    //       (long)currentIndex, (long)endIndex - 1, (unsigned long)movieChannels.count);
         
    dispatch_group_t group = dispatch_group_create();
    
    for (NSInteger i = currentIndex; i < endIndex; i++) {
        VLCChannel *channel = [movieChannels objectAtIndex:i];
        dispatch_group_enter(group);
        
        // Always fetch fresh data (no cache check since this is a forced refresh)
        channel.hasStartedFetchingMovieInfo = YES;
        
        // Load movie info
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            //NSLog(@"Refreshing movie info for channel %@ (%ld of %lu)", 
            //     channel.name, (long)i + 1, (unsigned long)movieChannels.count);
                 
            [self fetchMovieInfoForChannel:channel];
            
            // After fetching movie info, also load the image if needed
            dispatch_async(dispatch_get_main_queue(), ^{
                if (channel.logo && !channel.cachedPosterImage) {
                    //NSLog(@"Refreshing cover image for channel %@", channel.name);
                    [self loadImageAsynchronously:channel.logo forChannel:channel];
                }
                
                // Update progress
                self.movieRefreshCompleted++;
                [self setNeedsDisplay:YES];
                
                dispatch_group_leave(group);
            });
        });
    }
    
    // Schedule the next batch after current batch completes
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Clean up
        [group release];
        
        // Schedule next batch after delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), 
                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self processBatchOfMovieChannelsWithProgress:movieChannels 
                                                batchSize:batchSize 
                                       delayBetweenBatches:delay 
                                              currentIndex:endIndex];
        });
    });
}

// Add method to start movie info refresh with progress tracking
- (void)startMovieInfoRefresh {
    //NSLog(@"Starting movie info refresh with progress tracking");
    
    // Set refresh state
    self.isRefreshingMovieInfo = YES;
    self.movieRefreshCompleted = 0;
    self.movieRefreshTotal = 0;
    
    // Get all movie channels first to count them
    NSMutableArray *movieChannels = [NSMutableArray array];
    
    // Iterate through all categories and groups to find all movie channels
    for (NSString *category in [self.groupsByCategory allKeys]) {
        NSArray *groups = [self.groupsByCategory objectForKey:category];
        for (NSString *group in groups) {
            NSArray *channels = [self.channelsByGroup objectForKey:group];
            for (VLCChannel *channel in channels) {
                if ([channel.category isEqualToString:@"MOVIES"]) {
                    [movieChannels addObject:channel];
                }
            }
        }
    }
    
    self.movieRefreshTotal = movieChannels.count;
    //NSLog(@"Found %ld movie channels to refresh", (long)self.movieRefreshTotal);
    
    // Trigger initial UI update to show progress bar
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay:YES];
    });
    
    // Start the actual refresh process
    [self forceRefreshAllMovieInfoAndCoversWithProgress:movieChannels];
}

// Add method to force refresh all movie info and covers with progress tracking
- (void)forceRefreshAllMovieInfoAndCoversWithProgress:(NSMutableArray *)movieChannels {
    //NSLog(@"Starting forced refresh of all movie info and covers with progress tracking");
    
    // Reset all movie channels
    for (VLCChannel *channel in movieChannels) {
        // Reset the loading status to force refresh
        channel.hasLoadedMovieInfo = NO;
        channel.hasStartedFetchingMovieInfo = NO;
        
        // Clear the cached poster image
        if (channel.cachedPosterImage) {
            [channel.cachedPosterImage release];
            channel.cachedPosterImage = nil;
        }
        
        // Clear any associated object for image loading progress
        objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // Delete cached movie info files
    [self clearMovieInfoCache];
    
    // Process in batches to avoid overwhelming the system
    const NSInteger BATCH_SIZE = 5;
    const CGFloat DELAY_BETWEEN_BATCHES = 2.0; // seconds
    
    // Start batch processing with a short delay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), 
                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self processBatchOfMovieChannelsWithProgress:movieChannels batchSize:BATCH_SIZE delayBetweenBatches:DELAY_BETWEEN_BATCHES currentIndex:0];
    });
}

// Add method to force refresh all movie info and covers (legacy method)
- (void)forceRefreshAllMovieInfoAndCovers {
    //NSLog(@"Starting forced refresh of all movie info and covers");
    
    // Get all movie channels
    NSMutableArray *movieChannels = [NSMutableArray array];
    
    // Iterate through all categories and groups to find all movie channels
    for (NSString *category in [self.groupsByCategory allKeys]) {
        NSArray *groups = [self.groupsByCategory objectForKey:category];
        for (NSString *group in groups) {
            NSArray *channels = [self.channelsByGroup objectForKey:group];
            for (VLCChannel *channel in channels) {
                if ([channel.category isEqualToString:@"MOVIES"]) {
                    [movieChannels addObject:channel];
                }
            }
        }
    }
    
    //(@"Found %lu movie channels to refresh", (unsigned long)movieChannels.count);
    
    // Use the new progress-enabled method
    [self forceRefreshAllMovieInfoAndCoversWithProgress:movieChannels];
}

// Helper method to clear movie info cache
- (void)clearMovieInfoCache {
    NSString *cacheDir = [self getCacheDirectoryPath];
    NSString *movieInfoCacheDir = [cacheDir stringByAppendingPathComponent:@"MovieInfo"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    
    // Check if directory exists
    if ([fileManager fileExistsAtPath:movieInfoCacheDir]) {
        // Get all files in directory
        NSArray *cacheFiles = [fileManager contentsOfDirectoryAtPath:movieInfoCacheDir error:&error];
        
        if (error) {
            //NSLog(@"Error reading movie info cache directory: %@", error);
            return;
        }
        
        // Delete each cache file
        NSInteger deletedCount = 0;
        for (NSString *fileName in cacheFiles) {
            NSString *filePath = [movieInfoCacheDir stringByAppendingPathComponent:fileName];
            
            NSError *deleteError = nil;
            if ([fileManager removeItemAtPath:filePath error:&deleteError]) {
                deletedCount++;
            } else {
                //NSLog(@"Error deleting cache file %@: %@", fileName, deleteError);
            }
        }
        
        //NSLog(@"Deleted %ld movie info cache files", (long)deletedCount);
    } else {
        //NSLog(@"Movie info cache directory doesn't exist yet");
    }
}

// Helper method to get cache directory path
- (NSString *)getCacheDirectoryPath {
    return [self cacheDirectoryPath];
}

#pragma mark - Early Startup Functionality

- (void)startEarlyPlaybackIfAvailable {
    //NSLog(@"=== EARLY PLAYBACK: Starting early playback check... ===");
    
    // Get cached content info
    NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
    if (!cachedInfo) {
        //NSLog(@"=== EARLY PLAYBACK: No cached content info available for early playback ===");
        return;
    }
    
    NSString *lastUrl = [cachedInfo objectForKey:@"url"];
    if (!lastUrl || [lastUrl length] == 0) {
        //NSLog(@"No URL in cached content info");
        return;
    }
    
    NSString *channelName = [cachedInfo objectForKey:@"channelName"];
    //NSLog(@"=== EARLY PLAYBACK: Found cached content: %@ ===", channelName);
    //NSLog(@"=== EARLY PLAYBACK: Cached URL: %@ ===", lastUrl);
    //NSLog(@"=== EARLY PLAYBACK: Available channels count: %ld ===", (long)(self.channels ? self.channels.count : 0));
    
    // SIMPLIFIED STARTUP POLICY: Always switch to latest/current program, never play timeshift or catch-up
    NSString *playbackUrl = lastUrl;
    NSString *originalChannelName = channelName;
    BOOL isTimeshiftUrl = ([lastUrl rangeOfString:@"timeshift.php"].location != NSNotFound ||
                          [lastUrl rangeOfString:@"timeshift"].location != NSNotFound);
    
    //NSLog(@"=== EARLY PLAYBACK: Is timeshift URL: %@ ===", isTimeshiftUrl ? @"YES" : @"NO");
    
    if (isTimeshiftUrl) {
        //NSLog(@"=== STARTUP POLICY: Detected timeshift URL, finding live channel ===");
        
        // Extract the original channel name from timeshift channel name
        if (channelName && [channelName containsString:@" (Timeshift:"]) {
            NSRange timeshiftRange = [channelName rangeOfString:@" (Timeshift:"];
            if (timeshiftRange.location != NSNotFound) {
                originalChannelName = [channelName substringToIndex:timeshiftRange.location];
                //NSLog(@"=== STARTUP POLICY: Extracted original channel name: %@ ===", originalChannelName);
            }
        }
        
        // Search through loaded channels to find the original live channel
        VLCChannel *originalChannel = nil;
        if (self.channels && self.channels.count > 0) {
            //NSLog(@"=== STARTUP POLICY: Searching through %ld channels for: %@ ===", (long)self.channels.count, originalChannelName);
            for (VLCChannel *channel in self.channels) {
                if ([channel.name isEqualToString:originalChannelName]) {
                    originalChannel = channel;
                    //NSLog(@"=== STARTUP POLICY: Found original live channel: %@ with URL: %@ ===", channel.name, channel.url);
                    break;
                }
            }
        }
        
        if (originalChannel && originalChannel.url) {
            // Use the original channel's live URL
            playbackUrl = originalChannel.url;
            //NSLog(@"=== STARTUP POLICY: Using original channel live URL: %@ ===", playbackUrl);
        } else {
            // Fallback: Try to extract live URL from timeshift URL
            //NSLog(@"=== STARTUP POLICY: Original channel not found, trying URL parsing fallback ===");
            NSString *originalChannelUrl = [self findOriginalChannelUrlFromTimeshiftUrl:lastUrl];
            if (originalChannelUrl) {
                playbackUrl = originalChannelUrl;
                //NSLog(@"=== STARTUP POLICY: Converted to live channel URL via URL parsing: %@ ===", playbackUrl);
            } else {
                //NSLog(@"=== STARTUP POLICY: Could not find original channel or extract live URL, skipping startup playback ===");
                return; // Don't play timeshift content on startup
            }
        }
    } else {
        //NSLog(@"=== STARTUP POLICY: Using live channel URL: %@ ===", playbackUrl);
    }
    
    // SIMPLIFIED APPROACH: Find and select the channel properly like a normal click
    // This handles everything correctly - EPG refresh, player controls, etc.
    //NSLog(@"=== STARTUP POLICY: Forcing EPG refresh for live content ===");
    //NSLog(@"=== STARTUP POLICY: Finding and selecting channel for: %@ ===", playbackUrl);
    
    // Clear any cached timeshift data since we're switching to live
    if (isTimeshiftUrl) {
        [self clearCachedTimeshiftChannel];
        [self clearCachedTimeshiftProgramInfo]; 
        [self clearFrozenTimeValues];
    }
    
    // CRITICAL: Find the channel object and set proper selection indices
    // This is what happens when you click on a channel normally
    BOOL channelFound = NO;
    VLCChannel *targetChannel = nil;
    
    if (self.channels && self.channels.count > 0) {
        // Search through all channels to find the one with matching URL or name
        for (VLCChannel *channel in self.channels) {
            if ([channel.url isEqualToString:playbackUrl] || 
                [channel.name isEqualToString:originalChannelName]) {
                targetChannel = channel;
                channelFound = YES;
                objc_setAssociatedObject(self, &tempEarlyPlaybackChannelKey, targetChannel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                  
                //NSLog(@"=== STARTUP POLICY: Found target channel: %@ ===", channel.name);
                break;
            }
        }
    }
    
    if (channelFound && targetChannel) {
        // Find the channel in the organized structure and set selection indices
        BOOL selectionSet = NO;
        
        // Search through categories and groups to find this channel
        for (NSInteger catIndex = 0; catIndex < self.categories.count; catIndex++) {
            NSString *category = [self.categories objectAtIndex:catIndex];
            NSArray *groups = nil;
            
            if ([category isEqualToString:@"FAVORITES"]) {
                groups = [self safeGroupsForCategory:@"FAVORITES"];
            } else if ([category isEqualToString:@"TV"]) {
                groups = [self safeTVGroups];
            } else if ([category isEqualToString:@"MOVIES"]) {
                groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
            } else if ([category isEqualToString:@"SERIES"]) {
                groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
            }
            
            if (groups) {
                for (NSInteger groupIndex = 0; groupIndex < groups.count; groupIndex++) {
                    NSString *group = [groups objectAtIndex:groupIndex];
                    NSArray *channelsInGroup = [self.channelsByGroup objectForKey:group];
                    
                    if (channelsInGroup) {
                        for (NSInteger channelIndex = 0; channelIndex < channelsInGroup.count; channelIndex++) {
                            VLCChannel *channel = [channelsInGroup objectAtIndex:channelIndex];
                            if (channel == targetChannel) {
                                // Found it! Set the selection indices
                                self.selectedCategoryIndex = catIndex;
                                self.selectedGroupIndex = groupIndex;
                                self.selectedChannelIndex = channelIndex;
                                
                                //NSLog(@"=== STARTUP POLICY: Set selection indices - Category: %ld, Group: %ld, Channel: %ld ===", 
                                      //(long)catIndex, (long)groupIndex, (long)channelIndex);
                                
                                selectionSet = YES;
                                break;
                            }
                        }
                        if (selectionSet) break;
                    }
                }
                if (selectionSet) break;
            }
        }
        
        if (selectionSet) {
            //NSLog(@"=== STARTUP POLICY: Using playChannel method like normal click ===");
            
            // DIRECT APPROACH: Get current program immediately since we know the time and have EPG data
            VLCProgram *currentProgram = [targetChannel currentProgramWithTimeOffset:self.epgTimeOffsetHours];
            if (currentProgram) {
                //NSLog(@"=== STARTUP POLICY: Found current program: %@ (%@ - %@) ===", 
                      //currentProgram.title, currentProgram.startTime, currentProgram.endTime);
                
                // Create a temporary channel copy with just the current program
                // This ensures saveLastPlayedContentInfo saves the correct current program
                VLCChannel *tempChannel = [[VLCChannel alloc] init];
                tempChannel.name = targetChannel.name;
                tempChannel.url = targetChannel.url;
                tempChannel.channelId = targetChannel.channelId;
                tempChannel.group = targetChannel.group;
                tempChannel.category = targetChannel.category;
                tempChannel.logo = targetChannel.logo;
                tempChannel.supportsCatchup = targetChannel.supportsCatchup;
                tempChannel.catchupDays = targetChannel.catchupDays;
                tempChannel.catchupSource = targetChannel.catchupSource;
                tempChannel.catchupTemplate = targetChannel.catchupTemplate;
                
                // Set programs array to contain only the current program
                tempChannel.programs = [NSMutableArray arrayWithObject:currentProgram];
                
                // CRITICAL: Set flag to prevent overwrite BEFORE saving our correct data
                objc_setAssociatedObject(self, "preventCacheOverwrite", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, "tempEarlyPlaybackChannelKey", tempChannel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                // Update cached info with current live program immediately
                [self saveLastPlayedContentInfo:tempChannel];
                //[self updateCachedInfoToLiveChannel:targetChannel.name liveUrl:playbackUrl];
                [tempChannel release];
                //NSLog(@"=== STARTUP POLICY: Updated cached info with current live program ===");
                
                // NOTE: Don't refresh immediately - wait for media to load
                // The delayed refresh below will handle the UI update
    } else {
                //NSLog(@"=== STARTUP POLICY: No current program found for channel ===");
                // Save without current program info
                [self saveLastPlayedContentInfo:targetChannel];
                //[self updateCachedInfoToLiveChannel:targetChannel.name liveUrl:playbackUrl];
                objc_setAssociatedObject(self, "preventCacheOverwrite", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                // Set flag to prevent overwrite even without program info
                objc_setAssociatedObject(self, "tempEarlyPlaybackChannelKey", targetChannel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            
            // Use the normal channel playing method with the channel object - this handles everything correctly
            [self playChannel:targetChannel];
            //[self refreshCurrentEPGInfo];
            // CRITICAL: Force player controls refresh after startup to show correct program immediately
            // This ensures the cached program info is displayed right away instead of waiting for timer refresh
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                //NSLog(@"=== STARTUP POLICY: Forcing player controls refresh ===");
                
                // CRITICAL: Force player controls to become visible at startup
                // Without this, controls remain hidden and user won't see the correct program info
                extern BOOL playerControlsVisible;
                playerControlsVisible = YES;
                //NSLog(@"✅ STARTUP: Forced player controls visible");
                
                // Force refresh of EPG information to use cached program
                if ([self respondsToSelector:@selector(refreshCurrentEPGInfo)]) {
                    [self refreshCurrentEPGInfo];
                }
                
                // Start the refresh timer to keep controls updated
                if ([self respondsToSelector:@selector(startPlayerControlsRefreshTimer)]) {
                    [self startPlayerControlsRefreshTimer];
                }
                
                // Force redraw of player controls
                [self setNeedsDisplay:YES];
                [[self window] display];
                
                // CRITICAL: Clear flags AFTER refresh so refreshCurrentEPGInfo can detect startup mode
                objc_setAssociatedObject(self, "preventCacheOverwrite", @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, &tempEarlyPlaybackChannelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                //NSLog(@"✅ STARTUP COMPLETE: Cleared startup mode flags after refresh");
                
                //NSLog(@"=== STARTUP POLICY: Player controls refresh completed ===");
            });
        } else {
            //NSLog(@"=== STARTUP POLICY: Could not find channel in organized structure, using direct URL method ===");
            // Fallback to direct URL method
            [self playChannelWithUrl:playbackUrl];
        }
    } else {
        //NSLog(@"=== STARTUP POLICY: Channel not found in loaded channels, using direct URL method ===");
        // Fallback to direct URL method
        [self playChannelWithUrl:playbackUrl];
    }
    
    //NSLog(@"=== STARTUP POLICY: Channel selection and play method completed ===");
}

- (void)saveLastPlayedContentInfo:(VLCChannel *)channel {
    if (!channel) {
        //NSLog(@"Cannot save content info - no channel provided");
        return;
    }
    
    // Check if we should prevent cache overwrite (during startup policy)
    NSNumber *preventOverwrite = objc_getAssociatedObject(self, "preventCacheOverwrite");
    if (preventOverwrite && [preventOverwrite boolValue]) {
        //NSLog(@"=== SAVE BLOCKED: Preventing cache overwrite during startup policy ===");
        return;
    }
    
    NSMutableDictionary *contentInfo = [NSMutableDictionary dictionary];
    
    // Basic channel info
    if (channel.url) [contentInfo setObject:channel.url forKey:@"url"];
    if (channel.name) [contentInfo setObject:channel.name forKey:@"channelName"];
    if (channel.channelId) [contentInfo setObject:channel.channelId forKey:@"channelId"];
    if (channel.group) [contentInfo setObject:channel.group forKey:@"group"];
    if (channel.category) [contentInfo setObject:channel.category forKey:@"category"];
    if (channel.logo) [contentInfo setObject:channel.logo forKey:@"logoUrl"];
    
    // Current program info if available
    VLCProgram *currentProgram = nil;
    
    // FIXED: If the channel has programs array with content, use the first program
    // This respects the startup policy's calculated program with EPG offset
    if (channel.programs && channel.programs.count > 0) {
        currentProgram = [channel.programs objectAtIndex:0];
        //NSLog(@"Using first program from channel array: %@", currentProgram.title);
    } else {
        // Fallback to currentProgram method (no EPG offset)
        currentProgram = [channel currentProgram];
        //NSLog(@"Using currentProgram method as fallback: %@", currentProgram ? currentProgram.title : @"nil");
    }
    
    if (currentProgram) {
        NSMutableDictionary *programInfo = [NSMutableDictionary dictionary];
        
        if (currentProgram.title) [programInfo setObject:currentProgram.title forKey:@"title"];
        if (currentProgram.programDescription) [programInfo setObject:currentProgram.programDescription forKey:@"description"];
        if (currentProgram.startTime) [programInfo setObject:currentProgram.startTime forKey:@"startTime"];
        if (currentProgram.endTime) [programInfo setObject:currentProgram.endTime forKey:@"endTime"];
        
        [contentInfo setObject:programInfo forKey:@"currentProgram"];
        //NSLog(@"Saved program info: %@ (%@ - %@)", currentProgram.title, currentProgram.startTime, currentProgram.endTime);
    }
    
    // Movie info if available
    if (channel.name) [contentInfo setObject:channel.name forKey:@"movieTitle"];
    if (channel.movieDescription) [contentInfo setObject:channel.movieDescription forKey:@"movieDescription"];
    if (channel.movieGenre) [contentInfo setObject:channel.movieGenre forKey:@"movieGenre"];
    if (channel.movieDirector) [contentInfo setObject:channel.movieDirector forKey:@"movieDirector"];
    if (channel.movieCast) [contentInfo setObject:channel.movieCast forKey:@"movieCast"];
    if (channel.movieRating) [contentInfo setObject:channel.movieRating forKey:@"movieRating"];
    if (channel.movieYear) [contentInfo setObject:channel.movieYear forKey:@"movieReleaseDate"];
    if (channel.movieDuration) [contentInfo setObject:channel.movieDuration forKey:@"movieDuration"];
    
    // Save timestamp
    [contentInfo setObject:[NSDate date] forKey:@"lastPlayedTime"];
    
    // Save to UserDefaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:contentInfo forKey:@"LastPlayedContentInfo"];
    [defaults synchronize];
    
    //NSLog(@"Saved content info for: %@ (%@)", channel.name, channel.url);
}

- (NSDictionary *)getLastPlayedContentInfo {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *cachedInfo = [defaults objectForKey:@"LastPlayedContentInfo"];
    
    if (cachedInfo) {
        //NSLog(@"Retrieved cached content info for: %@", [cachedInfo objectForKey:@"channelName"]);
    } else {
        //NSLog(@"No cached content info found");
    }
    
    return cachedInfo;
}

- (void)populatePlayerControlsWithCachedInfo:(NSDictionary *)cachedInfo {
    if (!cachedInfo) {
        //NSLog(@"No cached info to populate player controls");
        return;
    }
    
    //NSLog(@"Populating player controls with cached info for: %@", [cachedInfo objectForKey:@"channelName"]);
    
    // Create a temporary channel object with cached data
    VLCChannel *tempChannel = [[VLCChannel alloc] init];
    
    // Use movie title if available, otherwise fall back to channel name
    NSString *displayName = [cachedInfo objectForKey:@"movieTitle"] ?: [cachedInfo objectForKey:@"channelName"];
    tempChannel.name = displayName;
    
    tempChannel.url = [cachedInfo objectForKey:@"url"];
    tempChannel.channelId = [cachedInfo objectForKey:@"channelId"];
    tempChannel.group = [cachedInfo objectForKey:@"group"];
    tempChannel.category = [cachedInfo objectForKey:@"category"];
    tempChannel.logo = [cachedInfo objectForKey:@"logoUrl"];
    
    // Movie info
    tempChannel.movieDescription = [cachedInfo objectForKey:@"movieDescription"];
    tempChannel.movieGenre = [cachedInfo objectForKey:@"movieGenre"];
    tempChannel.movieDirector = [cachedInfo objectForKey:@"movieDirector"];
    tempChannel.movieCast = [cachedInfo objectForKey:@"movieCast"];
    tempChannel.movieRating = [cachedInfo objectForKey:@"movieRating"];
    tempChannel.movieYear = [cachedInfo objectForKey:@"movieReleaseDate"];
    tempChannel.movieDuration = [cachedInfo objectForKey:@"movieDuration"];
    
    // Program info
    NSDictionary *programInfo = [cachedInfo objectForKey:@"currentProgram"];
    if (programInfo) {
        VLCProgram *tempProgram = [[VLCProgram alloc] init];
        tempProgram.title = [programInfo objectForKey:@"title"];
        tempProgram.programDescription = [programInfo objectForKey:@"description"];
        tempProgram.startTime = [programInfo objectForKey:@"startTime"];
        tempProgram.endTime = [programInfo objectForKey:@"endTime"];
        
        tempChannel.programs = [NSMutableArray arrayWithObject:tempProgram];
        [tempProgram release];
    }
    
    // Try to load cached logo if available
    if (tempChannel.logo && [tempChannel.logo length] > 0) {
        // Try to load from local cache first
        NSString *logoFileName = [NSString stringWithFormat:@"%@.jpg", 
                                 [[tempChannel.logo lastPathComponent] stringByDeletingPathExtension]];
        NSString *logoPath = [[[self postersCacheDirectory] stringByAppendingPathComponent:logoFileName] retain];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:logoPath]) {
            NSImage *cachedLogo = [[NSImage alloc] initWithContentsOfFile:logoPath];
            if (cachedLogo) {
                tempChannel.cachedPosterImage = cachedLogo;
                [cachedLogo release];
            }
        }
        [logoPath release];
    }
    
    // Store this temp channel in a way that player controls can access it
    // We'll use associated objects to temporarily store the channel info
    objc_setAssociatedObject(self, &tempEarlyPlaybackChannelKey, tempChannel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [tempChannel release];
    
    // Force a redraw of player controls
    if ([self respondsToSelector:@selector(setNeedsDisplay:)]) {
        [self setNeedsDisplay:YES];
    }
}

#pragma mark - Resume Functionality

- (void)saveCurrentPlaybackPosition {
    //NSLog(@"=== SAVE POSITION: saveCurrentPlaybackPosition called ===");
    
    if (!self.player || !self.player.media) {
        NSLog(@"=== SAVE POSITION: No player or media available ===");
        return;
    }
    
    VLCTime *currentTime = [self.player time];
    VLCTime *totalTime = [self.player.media length];
    
    //NSLog(@"=== SAVE POSITION: currentTime: %@, totalTime: %@ ===", currentTime, totalTime);
    
    // Only save position for content with substantial duration (more than 5 minutes)
    if (!currentTime || !totalTime || [totalTime intValue] < 300000) { // 5 minutes in milliseconds
        //NSLog(@"=== SAVE POSITION: Content too short or no time info - not saving ===");
        return;
    }
    
    NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
    NSTimeInterval totalSeconds = [totalTime intValue] / 1000.0;
    
    //NSLog(@"=== SAVE POSITION: Current: %.1f seconds, Total: %.1f seconds ===", currentSeconds, totalSeconds);
    
    // Only save if we're not at the very beginning (more than 30 seconds in)
    // and not at the very end (less than 30 seconds from end)
    if (currentSeconds > 30 && (totalSeconds - currentSeconds) > 30) {
        // Get the current media URL
        NSString *mediaURL = [self.player.media.url absoluteString];
        //NSLog(@"=== SAVE POSITION: Media URL: %@ ===", mediaURL);
        
        if (mediaURL) {
            [self savePlaybackPosition:currentSeconds forURL:mediaURL];
            //NSLog(@"=== SAVE POSITION: Successfully saved position %.1f seconds for URL: %@ ===", currentSeconds, mediaURL);
        } else {
            //NSLog(@"=== SAVE POSITION: No media URL available ===");
        }
    } else {
        //NSLog(@"=== SAVE POSITION: Position too close to beginning (%.1f) or end (%.1f remaining) - not saving ===", 
    }
}

- (void)resumePlaybackPositionForURL:(NSString *)urlString {
    if (!urlString || !self.player) {
        //NSLog(@"=== RESUME: Cannot resume - missing URL or player ===");
        return;
    }
    
    //NSLog(@"=== RESUME: Checking for saved position for URL: %@", urlString);
    NSTimeInterval savedPosition = [self getSavedPlaybackPositionForURL:urlString];
    
    if (savedPosition > 0) {
        //NSLog(@"=== RESUME: Found saved position: %.1f seconds ===", savedPosition);
        // Wait a bit for the media to load before seeking
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.player && self.player.media) {
                VLCTime *resumeTime = [VLCTime timeWithInt:(int)(savedPosition * 1000)];
                [self.player setTime:resumeTime];
                //NSLog(@"=== RESUME: Successfully resumed playback at %.1f seconds for URL: %@ ===", savedPosition, urlString);
            } else {
                //NSLog(@"=== RESUME: Cannot seek - player or media not available ===");
            }
        });
    } else {
        //NSLog(@"=== RESUME: No saved position found for URL: %@ ===", urlString);
    }
}

- (void)savePlaybackPosition:(NSTimeInterval)position forURL:(NSString *)urlString {
    if (!urlString || position <= 0) {
        return;
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *resumePositions = [[defaults objectForKey:@"ResumePositions"] mutableCopy];
    
    if (!resumePositions) {
        resumePositions = [NSMutableDictionary dictionary];
    }
    
    // Create a unique key from the URL
    NSString *urlKey = [self md5HashForString:urlString];
    
    // Save position and timestamp
    NSDictionary *positionData = @{
        @"position": @(position),
        @"timestamp": [NSDate date],
        @"url": urlString
    };
    
    [resumePositions setObject:positionData forKey:urlKey];
    
    // Keep only recent positions (last 50 entries)
    if (resumePositions.count > 50) {
        // Sort by timestamp and keep newest 50
        NSArray *sortedKeys = [resumePositions.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *key1, NSString *key2) {
            NSDate *date1 = [[resumePositions objectForKey:key1] objectForKey:@"timestamp"];
            NSDate *date2 = [[resumePositions objectForKey:key2] objectForKey:@"timestamp"];
            return [date2 compare:date1]; // Newest first
        }];
        
        NSMutableDictionary *trimmedPositions = [NSMutableDictionary dictionary];
        for (NSInteger i = 0; i < MIN(50, sortedKeys.count); i++) {
            NSString *key = [sortedKeys objectAtIndex:i];
            [trimmedPositions setObject:[resumePositions objectForKey:key] forKey:key];
        }
        resumePositions = trimmedPositions;
    }
    
    [defaults setObject:resumePositions forKey:@"ResumePositions"];
    [defaults synchronize];
    
    [resumePositions release];
}

- (NSTimeInterval)getSavedPlaybackPositionForURL:(NSString *)urlString {
    if (!urlString) {
        return 0;
    }
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *resumePositions = [defaults objectForKey:@"ResumePositions"];
    
    if (!resumePositions) {
        return 0;
    }
    
    NSString *urlKey = [self md5HashForString:urlString];
    NSDictionary *positionData = [resumePositions objectForKey:urlKey];
    
    if (!positionData) {
        return 0;
    }
    
    // Check if the position is not too old (30 days)
    NSDate *timestamp = [positionData objectForKey:@"timestamp"];
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:timestamp];
    
    if (age > 30 * 24 * 60 * 60) { // 30 days in seconds
        return 0; // Position too old, don't resume
    }
    
    NSNumber *position = [positionData objectForKey:@"position"];
    return position ? [position doubleValue] : 0;
}

- (NSString *)generateCatchupUrlForProgram:(VLCProgram *)program channel:(VLCChannel *)channel {
    if (!program.hasArchive || !program.startTime || !program.endTime) {
        return nil;
    }
    
    // Calculate program duration
    NSTimeInterval duration = [program.endTime timeIntervalSinceDate:program.startTime];
    NSTimeInterval startTimestamp = [program.startTime timeIntervalSince1970];
    
    // Extract server info from original channel URL
    NSURL *originalUrl = [NSURL URLWithString:channel.url];
    NSString *baseUrl = [NSString stringWithFormat:@"%@://%@", originalUrl.scheme, originalUrl.host];
    if (originalUrl.port) {
        baseUrl = [baseUrl stringByAppendingFormat:@":%@", originalUrl.port];
    }
    
    // Extract username/password from URL or use stored credentials
    NSString *username = @"your_username";  // Get from settings
    NSString *password = @"your_password";  // Get from settings
    
    // Generate time-shift URL
    NSString *catchupUrl = [NSString stringWithFormat:@"%@/timeshift/%@/%@/%.0f/%.0f/%@.m3u8",
                           baseUrl,
                           username,
                           password,
                           duration,
                           startTimestamp,
                           channel.channelId];
    
    return catchupUrl;
}

- (void)playCatchupUrl:(NSString *)catchupUrl seekToTime:(NSTimeInterval)seekTime {
    NSLog(@"Playing catch-up content: %@", catchupUrl);
    
    NSURL *url = [NSURL URLWithString:catchupUrl];
    if (url) {
        VLCMedia *media = [VLCMedia mediaWithURL:url];
        [self.player setMedia:media];
        
        // Apply subtitle settings
        [VLCSubtitleSettings applyCurrentSettingsToPlayer:self.player];
        
        // Start playing
        [self.player play];
        
        // Seek to the desired position after a short delay
        if (seekTime > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                VLCTime *seekVLCTime = [VLCTime timeWithInt:(int)(seekTime * 1000)];
                [self.player setTime:seekVLCTime];
            });
        }
    }
}

#pragma mark - Server-based Catch-up Detection

// Construct API URL for live streams catch-up info
- (NSString *)constructLiveStreamsApiUrl {
    if (!self.m3uFilePath) return nil;
    
    // Parse server information from M3U URL
    NSURL *m3uURL = [NSURL URLWithString:self.m3uFilePath];
    if (!m3uURL) return nil;
    
    NSString *scheme = [m3uURL scheme];
    NSString *host = [m3uURL host];
    NSNumber *port = [m3uURL port];
    NSString *portString = port ? [NSString stringWithFormat:@":%@", port] : @"";
    
    // Extract username and password (reuse existing logic)
    NSString *username = @"";
    NSString *password = @"";
    
    // First try to get from query parameters
    NSString *query = [m3uURL query];
    if (query) {
        NSArray *queryItems = [query componentsSeparatedByString:@"&"];
        for (NSString *item in queryItems) {
            NSArray *keyValue = [item componentsSeparatedByString:@"="];
            if (keyValue.count == 2) {
                NSString *key = keyValue[0];
                NSString *value = keyValue[1];
                
                if ([key isEqualToString:@"username"]) {
                    username = value;
                } else if ([key isEqualToString:@"password"]) {
                    password = value;
                }
            }
        }
    }
    
    // If not found in query, try path components
    if (username.length == 0 || password.length == 0) {
        NSString *path = [m3uURL path];
        NSArray *pathComponents = [path pathComponents];
        
        // Look for typical username/password segments in the URL path
        for (NSInteger i = 0; i < pathComponents.count - 1; i++) {
            // Username is often after "get.php" or similar pattern
            if ([pathComponents[i] hasSuffix:@".php"] && i + 1 < pathComponents.count) {
                username = pathComponents[i + 1];
                
                // Password typically follows the username
                if (i + 2 < pathComponents.count) {
                    password = pathComponents[i + 2];
                    break;
                }
            }
        }
    }
    
    // Construct the API URL for live streams
    NSString *apiUrl = [NSString stringWithFormat:@"%@://%@%@/player_api.php?username=%@&password=%@&action=get_live_streams",
                        scheme, host, portString, username, password];
    
    //NSLog(@"Constructed live streams API URL: %@", apiUrl);
    return apiUrl;
}

// Fetch catch-up information for all channels from the API
- (void)fetchCatchupInfoFromAPI {
    NSString *apiUrl = [self constructLiveStreamsApiUrl];
    if (!apiUrl) {
        NSLog(@"❌ Failed to construct live streams API URL");
        return;
    }
    
    NSLog(@"🔄 Fetching catch-up info from API: %@", apiUrl);
    
    // Create the URL request
    NSURL *url = [NSURL URLWithString:apiUrl];
    NSURLRequest *request = [NSURLRequest requestWithURL:url 
                                             cachePolicy:NSURLRequestUseProtocolCachePolicy 
                                         timeoutInterval:30.0];
    
    // Create and begin an asynchronous data task
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request 
                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            NSLog(@"❌ Error fetching catch-up info from API: %@", error);
            return;
        }
        
        NSLog(@"✅ Received catch-up data (%lu bytes)", (unsigned long)[data length]);
        
        // Parse the JSON response
        NSError *jsonError = nil;
        NSArray *channelsArray = [NSJSONSerialization JSONObjectWithData:data 
                                                                  options:0 
                                                                    error:&jsonError];
        
        if (jsonError || !channelsArray || ![channelsArray isKindOfClass:[NSArray class]]) {
            NSLog(@"❌ Error parsing catch-up info JSON: %@", jsonError);
            return;
        }
        
        NSLog(@"✅ Successfully parsed %lu channels from API", (unsigned long)[channelsArray count]);
        
        // Process the catch-up information on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self processCatchupInfoFromAPI:channelsArray];
        });
    }];
    
    // Start the data task
    [dataTask resume];
}

// Process catch-up information and update channel properties
- (void)processCatchupInfoFromAPI:(NSArray *)apiChannels {
    //NSLog(@"Processing catch-up info for %lu API channels", (unsigned long)[apiChannels count]);
    
    // Create a mapping of stream_id to catch-up info for fast lookup
    NSMutableDictionary *catchupInfo = [NSMutableDictionary dictionary];
    
    for (NSDictionary *apiChannel in apiChannels) {
        if (![apiChannel isKindOfClass:[NSDictionary class]]) continue;
        
        NSNumber *streamId = [apiChannel objectForKey:@"stream_id"];
        NSNumber *tvArchive = [apiChannel objectForKey:@"tv_archive"];
        NSString *tvArchiveDuration = [apiChannel objectForKey:@"tv_archive_duration"];
        NSString *channelName = [apiChannel objectForKey:@"name"];
        
        if (streamId) {
            NSDictionary *info = @{
                @"tv_archive": tvArchive ? tvArchive : @(0),
                @"tv_archive_duration": tvArchiveDuration ? tvArchiveDuration : @"0",
                @"name": channelName ? channelName : @""
            };
            [catchupInfo setObject:info forKey:[streamId stringValue]];
        }
    }
    
    //NSLog(@"Created catch-up lookup table with %lu entries", (unsigned long)[catchupInfo count]);
    
    // Update our channels with catch-up information
    NSInteger updatedChannels = 0;
    for (VLCChannel *channel in self.channels) {
        // Extract stream_id from channel URL
        NSString *streamId = [self extractStreamIdFromChannelUrl:channel.url];
        if (!streamId) continue;
        
        NSDictionary *info = [catchupInfo objectForKey:streamId];
        if (info) {
            NSNumber *tvArchive = [info objectForKey:@"tv_archive"];
            NSString *tvArchiveDuration = [info objectForKey:@"tv_archive_duration"];
            
            // Update channel catch-up properties
            channel.supportsCatchup = [tvArchive boolValue];
            channel.catchupDays = [tvArchiveDuration integerValue];
            
            if (channel.supportsCatchup) {
                channel.catchupSource = @"default";
                channel.catchupTemplate = @""; // Will be constructed dynamically
                updatedChannels++;
                NSLog(@"✅ Updated catch-up for channel '%@': %d days (API)", channel.name, (int)channel.catchupDays);
            }
        }
    }
    
    //NSLog(@"Updated catch-up info for %ld channels", (long)updatedChannels);
    
    // Save the updated channel information to cache (including catch-up properties)
    if (updatedChannels > 0 && self.m3uFilePath) {
        NSLog(@"📺 Catch-up info updated for %ld channels - cache will be updated automatically by VLCDataManager", (long)updatedChannels);
        // Cache saving is now handled automatically by VLCDataManager/VLCCacheManager
    }
    
    // Trigger UI update to show catch-up indicators
    [self setNeedsDisplay:YES];
}

// Extract stream_id from channel URL
- (NSString *)extractStreamIdFromChannelUrl:(NSString *)urlString {
    if (!urlString) return nil;
    
    // Pattern for Xtream Codes URLs: .../username/password/stream_id or .../stream_id.m3u8
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"/(\\d+)(?:\\.m3u8)?/?$" 
                                                                           options:0 
                                                                             error:&error];
    
    if (!error) {
        NSArray *matches = [regex matchesInString:urlString options:0 range:NSMakeRange(0, [urlString length])];
        if (matches.count > 0) {
            NSTextCheckingResult *match = [matches lastObject];
            if (match.numberOfRanges > 1) {
                NSRange idRange = [match rangeAtIndex:1];
                NSString *streamId = [urlString substringWithRange:idRange];
                //NSLog(@"Extracted stream ID '%@' from URL: %@", streamId, urlString);
                return streamId;
            }
        }
    }
    
    return nil;
}

// Generate time-shift URL for a specific time
- (NSString *)generateTimeshiftUrlForChannel:(VLCChannel *)channel atTime:(NSDate *)targetTime {
    if (!channel.supportsCatchup || !targetTime) {
        return nil;
    }
    
    // Extract server info from channel URL (not M3U URL)
    NSURL *channelURL = [NSURL URLWithString:channel.url];
    if (!channelURL) return nil;
    
    NSString *scheme = [channelURL scheme];
    NSString *host = [channelURL host];
    NSNumber *port = [channelURL port];
    NSString *baseUrl = [NSString stringWithFormat:@"%@://%@", scheme, host];
    if (port) {
        baseUrl = [baseUrl stringByAppendingFormat:@":%@", port];
    }
    
    // Extract username and password from the channel URL path
    NSString *username = @"";
    NSString *password = @"";
    
    NSString *path = [channelURL path];
    if (path) {
        NSArray *pathComponents = [path pathComponents];
        
        // For Xtream Codes URLs, the format is typically:
        // /live/username/password/stream_id.m3u8
        // or /username/password/stream_id
        for (NSInteger i = 0; i < pathComponents.count - 2; i++) {
            NSString *component = pathComponents[i];
            if ([component isEqualToString:@"live"] || [component isEqualToString:@"movie"] || [component isEqualToString:@"series"]) {
                // Found service type, next two should be username and password
                if (i + 2 < pathComponents.count) {
                    username = pathComponents[i + 1];
                    password = pathComponents[i + 2];
                    break;
                }
            }
        }
        
        // If not found with service type, try to find username/password pattern
        if (username.length == 0 && pathComponents.count >= 3) {
            // Look for two consecutive non-empty path components that could be username/password
            for (NSInteger i = 1; i < pathComponents.count - 1; i++) {
                NSString *potentialUsername = pathComponents[i];
                NSString *potentialPassword = pathComponents[i + 1];
                
                if (potentialUsername.length > 0 && potentialPassword.length > 0 &&
                    ![potentialUsername hasSuffix:@".m3u8"] && ![potentialPassword hasSuffix:@".m3u8"]) {
                    username = potentialUsername;
                    password = potentialPassword;
                    break;
                }
            }
        }
    }
    
    if (username.length == 0 || password.length == 0) {
        return nil;
    }
    
    // Extract stream_id from channel URL
    NSString *streamId = [self extractStreamIdFromChannelUrl:channel.url];
    if (!streamId) {
        return nil;
    }
    
    // Default duration of 2 hours for manual timeshift
    NSInteger durationMinutes = 120;
    
    // Format start time as YYYY-MM-DD:HH-MM
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd:HH-mm"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    
    // IMPORTANT: Adjust the target time by the EPG time offset for timeshift URL generation
    // When user has EPG offset (e.g., -1 hour), we need to compensate by subtracting the offset
    // This converts from user's display time back to server time
    NSTimeInterval offsetCompensation = -self.epgTimeOffsetHours * 3600.0; // Convert hours to seconds and negate
    NSDate *adjustedTargetTime = [targetTime dateByAddingTimeInterval:offsetCompensation];
    
    NSString *startTimeString = [formatter stringFromDate:adjustedTargetTime];
    [formatter release];
    
    //NSLog(@"Manual timeshift URL generation: Original target time = %@", targetTime);
    //NSLog(@"Manual timeshift URL generation: EPG offset = %ld hours, compensation = %.0f seconds", 
          //(long)self.epgTimeOffsetHours, offsetCompensation);
    //NSLog(@"Manual timeshift URL generation: Adjusted target time for server = %@", adjustedTargetTime);
    
    // Generate timeshift URL using PHP-based format
    NSString *timeshiftUrl = [NSString stringWithFormat:@"%@/streaming/timeshift.php?username=%@&password=%@&stream=%@&start=%@&duration=%ld",
                             baseUrl, username, password, streamId, startTimeString, (long)durationMinutes];
    
    return timeshiftUrl;
}

// Auto-fetch catch-up info when loading M3U (called from loadChannelsFromM3U)
- (void)autoFetchCatchupInfo {
    NSLog(@"🔄 autoFetchCatchupInfo called with %lu channels", (unsigned long)self.channels.count);
    
    // Only fetch if we have channels
    if (self.channels.count > 0) {
        // Check if any channel already has catch-up info
        BOOL hasCatchupInfo = NO;
        NSInteger catchupChannels = 0;
        
        for (VLCChannel *channel in self.channels) {
            if (channel.supportsCatchup && channel.catchupDays > 0) {
                hasCatchupInfo = YES;
                catchupChannels++;
            }
        }
        
        NSLog(@"🔄 Found %ld channels with existing catchup info (hasCatchupInfo=%d)", 
              (long)catchupChannels, hasCatchupInfo);
        
        // Calculate percentage of channels with catchup info
        float catchupPercentage = (float)catchupChannels / (float)self.channels.count;
        
        if (!hasCatchupInfo || catchupPercentage < 0.1) { // Less than 10% have catchup info
            NSLog(@"🔄 Insufficient catchup info (%.1f%% of channels) - calling fetchCatchupInfoFromAPI", 
                  catchupPercentage * 100);
            [self fetchCatchupInfoFromAPI];
        } else {
            NSLog(@"🔄 Sufficient catchup info found (%.1f%% of channels) - skipping API fetch", 
                  catchupPercentage * 100);
        }
    } else {
        NSLog(@"❌ No channels loaded - cannot fetch catchup info");
    }
}

#pragma mark - Timeshift URL Generation and Playback

// Generate timeshift URL for a specific program
- (NSString *)generateTimeshiftUrlForProgram:(VLCProgram *)program channel:(VLCChannel *)channel {
    if (!channel.supportsCatchup || !program.startTime || !program.endTime) {
        //NSLog(@"Cannot generate timeshift URL: channel doesn't support catchup or program missing time info");
        return nil;
    }
    
    // Extract server info from the channel URL (not M3U URL)
    NSURL *channelURL = [NSURL URLWithString:channel.url];
    if (!channelURL) {
        //NSLog(@"Cannot generate timeshift URL: invalid channel URL: %@", channel.url);
        return nil;
    }
    
    NSString *scheme = [channelURL scheme];
    NSString *host = [channelURL host];
    NSNumber *port = [channelURL port];
    NSString *baseUrl = [NSString stringWithFormat:@"%@://%@", scheme, host];
    if (port) {
        baseUrl = [baseUrl stringByAppendingFormat:@":%@", port];
    }
    
    // Extract username and password from the channel URL path
    NSString *username = @"";
    NSString *password = @"";
    
    NSString *path = [channelURL path];
    if (path) {
        NSArray *pathComponents = [path pathComponents];
        
        // For Xtream Codes URLs, the format is typically:
        // /live/username/password/stream_id.m3u8
        // or /username/password/stream_id
        for (NSInteger i = 0; i < pathComponents.count - 2; i++) {
            NSString *component = pathComponents[i];
            if ([component isEqualToString:@"live"] || [component isEqualToString:@"movie"] || [component isEqualToString:@"series"]) {
                // Found service type, next two should be username and password
                if (i + 2 < pathComponents.count) {
                    username = pathComponents[i + 1];
                    password = pathComponents[i + 2];
                    break;
                }
            }
        }
        
        // If not found with service type, try to find username/password pattern
        if (username.length == 0 && pathComponents.count >= 3) {
            // Look for two consecutive non-empty path components that could be username/password
            for (NSInteger i = 1; i < pathComponents.count - 1; i++) {
                NSString *potentialUsername = pathComponents[i];
                NSString *potentialPassword = pathComponents[i + 1];
                
                if (potentialUsername.length > 0 && potentialPassword.length > 0 &&
                    ![potentialUsername hasSuffix:@".m3u8"] && ![potentialPassword hasSuffix:@".m3u8"]) {
                    username = potentialUsername;
                    password = potentialPassword;
                    break;
                }
            }
        }
    }
    
    // If still no username/password, try to extract from M3U URL as fallback
    if (username.length == 0 || password.length == 0) {
        NSURL *m3uURL = [NSURL URLWithString:self.m3uFilePath];
        if (m3uURL) {
    NSString *query = [m3uURL query];
    if (query) {
        NSArray *queryItems = [query componentsSeparatedByString:@"&"];
        for (NSString *item in queryItems) {
            NSArray *keyValue = [item componentsSeparatedByString:@"="];
            if (keyValue.count == 2) {
                NSString *key = keyValue[0];
                NSString *value = keyValue[1];
                
                if ([key isEqualToString:@"username"]) {
                    username = value;
                } else if ([key isEqualToString:@"password"]) {
                    password = value;
                        }
                    }
                }
            }
        }
    }
    
    if (username.length == 0 || password.length == 0) {
        //NSLog(@"Cannot generate timeshift URL: failed to extract username/password from channel URL: %@", channel.url);
        return nil;
    }
    
    // Extract stream_id from channel URL
    NSString *streamId = [self extractStreamIdFromChannelUrl:channel.url];
    if (!streamId) {
        //NSLog(@"Cannot generate timeshift URL: failed to extract stream ID from channel URL: %@", channel.url);
        return nil;
    }
    
    // Calculate program duration in minutes
    NSTimeInterval durationSeconds = [program.endTime timeIntervalSinceDate:program.startTime];
    NSInteger durationMinutes = (NSInteger)(durationSeconds / 60);
    
    // Format start time as YYYY-MM-DD:HH-MM
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd:HH-mm"];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    
    // IMPORTANT: Adjust the program start time by the EPG time offset for timeshift URL generation
    // When user has EPG offset (e.g., -1 hour), we need to compensate by subtracting the offset
    // This converts from user's display time back to server time
    NSTimeInterval offsetCompensation = -self.epgTimeOffsetHours * 3600.0; // Convert hours to seconds and negate
    NSDate *adjustedStartTime = [program.startTime dateByAddingTimeInterval:offsetCompensation];
    
    NSString *startTimeString = [formatter stringFromDate:adjustedStartTime];
    [formatter release];
    
    //NSLog(@"Timeshift URL generation: Original program start time = %@", program.startTime);
    //NSLog(@"Timeshift URL generation: EPG offset = %ld hours, compensation = %.0f seconds", 
    //      (long)self.epgTimeOffsetHours, offsetCompensation);
    //NSLog(@"Timeshift URL generation: Adjusted start time for server = %@", adjustedStartTime);
    
    // Generate timeshift URL using PHP-based format with query parameters
    // Format: http://host:port/streaming/timeshift.php?username=User&password=Pass&stream=1234&start=2020-12-06:08-00&duration=120
    NSString *timeshiftUrl = [NSString stringWithFormat:@"%@/streaming/timeshift.php?username=%@&password=%@&stream=%@&start=%@&duration=%ld",
                             baseUrl, username, password, streamId, startTimeString, (long)durationMinutes];
    
    //NSLog(@"Generated timeshift URL for program '%@': %@", program.title, timeshiftUrl);
    //NSLog(@"Using server: %@, username: %@, password: %@, streamId: %@, start: %@, duration: %ld min", 
    //      baseUrl, username, password, streamId, startTimeString, (long)durationMinutes);
    return timeshiftUrl;
}

// Play timeshift content for a specific program
- (void)playTimeshiftForProgram:(VLCProgram *)program channel:(VLCChannel *)channel {
    //NSLog(@"Playing timeshift for program: %@ on channel: %@", program.title, channel.name);
    
    // Generate timeshift URL
    NSString *timeshiftUrl = [self generateTimeshiftUrlForProgram:program channel:channel];
    if (!timeshiftUrl) {
        //NSLog(@"Failed to generate timeshift URL for program: %@", program.title);
        
        // Show error alert
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Timeshift Error"];
        [alert setInformativeText:@"Unable to generate timeshift URL for this program."];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        return;
    }
    
    // Stop current playback
    if (self.player) {
        [self saveCurrentPlaybackPosition];
        [self.player stop];
        
        // Brief pause to allow VLC to reset
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            //NSLog(@"Starting timeshift playback for program: %@", program.title);
            
            // Create media object with timeshift URL
            NSURL *url = [NSURL URLWithString:timeshiftUrl];
            VLCMedia *media = [VLCMedia mediaWithURL:url];
            
            // Set the media to the player
            [self.player setMedia:media];
            
            // Apply subtitle settings
            [VLCSubtitleSettings applyCurrentSettingsToPlayer:self.player];
            
            // Start playing
            [self.player play];
            
            //NSLog(@"Started timeshift playback for URL: %@", timeshiftUrl);
            
            // Force UI update
            [self setNeedsDisplay:YES];
        });
    }
    
    // Save the timeshift URL as last played for resume functionality
    [self saveLastPlayedChannelUrl:timeshiftUrl];
    
    // Create a temporary channel object for timeshift content
    VLCChannel *timeshiftChannel = [[VLCChannel alloc] init];
    timeshiftChannel.name = [NSString stringWithFormat:@"%@ (Timeshift: %@)", channel.name, program.title];
    timeshiftChannel.url = timeshiftUrl;
    timeshiftChannel.channelId = channel.channelId;
    timeshiftChannel.group = channel.group;
    timeshiftChannel.category = channel.category;
    timeshiftChannel.logo = channel.logo;
    
    // Add program info to the timeshift channel
    timeshiftChannel.programs = [NSMutableArray arrayWithObject:program];
    
    [self saveLastPlayedContentInfo:timeshiftChannel];
    [timeshiftChannel release];
    
    // Hide the channel list after starting playback
    [self hideChannelListWithFade];
}

// Helper method to hide channel list with fade animation
- (void)hideChannelListWithFade {
    // Cancel any ongoing fade animations
    extern BOOL isFadingOut;
    extern NSTimeInterval lastFadeOutTime;
    
    if (isFadingOut) {
        [[self animator] setAlphaValue:1.0];
        [[NSAnimationContext currentContext] setDuration:0.0];
    }
    
    // Make sure the menu is visible first
    self.isChannelListVisible = YES;
    [self setAlphaValue:1.0];
    
    // Set fading out flag
    isFadingOut = YES;
    
    // Start fade out animation
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSAnimationContext beginGrouping];
        [[NSAnimationContext currentContext] setDuration:0.5];
        [[self animator] setAlphaValue:0.0];
        [NSAnimationContext endGrouping];
        
        // After fade completes, reset everything
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.isChannelListVisible = NO;
            [self setAlphaValue:1.0];
            
            NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
            lastFadeOutTime = currentTime;
            
            isFadingOut = NO;
            isUserInteracting = NO;
            lastInteractionTime = currentTime;
            
            [self setupTrackingArea];
            [self setNeedsDisplay:YES];
        });
    });
}

#pragma mark - Startup Policy Helper Methods

// Helper method to extract original channel URL from timeshift URL
- (NSString *)findOriginalChannelUrlFromTimeshiftUrl:(NSString *)timeshiftUrl {
    if (!timeshiftUrl || [timeshiftUrl length] == 0) {
        return nil;
    }
    
    // Parse the timeshift URL to extract server info and stream ID
    NSURL *url = [NSURL URLWithString:timeshiftUrl];
    if (!url) {
        return nil;
    }
    
    // Extract base URL
    NSString *baseUrl = [NSString stringWithFormat:@"%@://%@", url.scheme, url.host];
    if (url.port) {
        baseUrl = [baseUrl stringByAppendingFormat:@":%@", url.port];
    }
    
    // Extract query parameters to get username, password, and stream ID
    NSString *query = [url query];
    if (!query) {
        return nil;
    }
    
    NSMutableDictionary *queryParams = [NSMutableDictionary dictionary];
    NSArray *queryItems = [query componentsSeparatedByString:@"&"];
    for (NSString *item in queryItems) {
        NSArray *keyValue = [item componentsSeparatedByString:@"="];
        if (keyValue.count == 2) {
            [queryParams setObject:keyValue[1] forKey:keyValue[0]];
        }
    }
    
    NSString *username = [queryParams objectForKey:@"username"];
    NSString *password = [queryParams objectForKey:@"password"];
    NSString *streamId = [queryParams objectForKey:@"stream"];
    
    if (!username || !password || !streamId) {
        //NSLog(@"Could not extract username/password/stream from timeshift URL");
        return nil;
    }
    
    // Construct the original live channel URL
    NSString *originalUrl = [NSString stringWithFormat:@"%@/live/%@/%@/%@.m3u8", 
                            baseUrl, username, password, streamId];
    
    //NSLog(@"Converted timeshift URL to live URL: %@ -> %@", timeshiftUrl, originalUrl);
    return originalUrl;
}

// Helper method to update cached info to reflect live channel instead of timeshift
- (void)updateCachedInfoToLiveChannel:(NSString *)originalChannelName liveUrl:(NSString *)liveUrl {
    if (!originalChannelName || !liveUrl) {
        return;
    }
    
    // Get current cached info
    NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
    if (!cachedInfo) {
        return;
    }
    
    // Create updated info with live channel details
    NSMutableDictionary *updatedInfo = [cachedInfo mutableCopy];
    
    // Update to live channel
    [updatedInfo setObject:liveUrl forKey:@"url"];
    [updatedInfo setObject:originalChannelName forKey:@"channelName"];
    
    // Remove timeshift-specific program info since we're now live
    [updatedInfo removeObjectForKey:@"currentProgram"];
    
    // Update timestamp
    [updatedInfo setObject:[NSDate date] forKey:@"lastPlayedTime"];
    
    // Save updated info
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:updatedInfo forKey:@"LastPlayedContentInfo"];
    [defaults synchronize];
    
    [updatedInfo release];
    
    //NSLog(@"Updated cached info to live channel: %@ (%@)", originalChannelName, liveUrl);
}

@end 

#endif // TARGET_OS_OSX 
