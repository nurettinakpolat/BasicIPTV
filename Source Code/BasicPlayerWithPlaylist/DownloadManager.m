//
//  DownloadManager.m
//
//  Created by Nurettin Akpolat on 20/05/2025.
//
#import "DownloadManager.h"

@implementation DownloadManager {
    NSURLSession *_session;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        
        // Configure even longer timeout (20 minutes instead of 10 minutes)
        config.timeoutIntervalForResource = 1200.0; // 20 minutes
        config.timeoutIntervalForRequest = 1200.0;  // 20 minutes
        
        // Improve network reliability settings
        config.HTTPMaximumConnectionsPerHost = 1; // Single connection to avoid overloading server
        config.HTTPShouldUsePipelining = YES;     // More efficient connection reuse
        config.waitsForConnectivity = YES;        // Wait for connectivity when network is down
        config.allowsCellularAccess = YES;        // Allow cellular data
        
        // Set additional TCP options for reliability
        config.connectionProxyDictionary = @{
            @"kCFStreamPropertySocketMaximumSocketIdleTime": @300, // 5 minutes idle time
            @"kCFStreamPropertySocketSecurityLevel": @"kCFStreamSocketSecurityLevelTLSv1", // Modern TLS only
        };
        
        // Create the session with our configuration
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        
        NSLog(@"DownloadManager initialized with resource timeout: %.1f seconds", config.timeoutIntervalForResource);
    }
    return self;
}

- (void)startDownloadFromURL:(NSString *)urlString
             progressHandler:(void (^)(int64_t, int64_t))progressHandler
           completionHandler:(void (^)(NSString *, NSError *))completionHandler
             destinationPath:(NSString *)destinationPath {

    self.progressCallback = progressHandler;
    self.completionCallback = completionHandler;
    self.destinationPath = destinationPath;
    self.originalURLString = urlString; // Save for retry attempts

    // Create URL with proper encoding
    NSString *escapedUrlString = [urlString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:escapedUrlString];
    
    if (!url) {
        NSError *error = [NSError errorWithDomain:@"DownloadManagerErrorDomain" 
                                            code:1001 
                                        userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL format"}];
        if (self.completionCallback) {
            self.completionCallback(nil, error);
        }
        return;
    }
    
    // Create request with custom headers for better compatibility
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    
    // Add headers to simulate a browser
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" 
      forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"text/plain,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" 
      forHTTPHeaderField:@"Accept"];
    [request setValue:@"gzip, deflate, br" 
      forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"keep-alive" 
      forHTTPHeaderField:@"Connection"];
    
    // Disable cache to ensure fresh content
    [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
    
    // Set timeout for this specific request (even longer than session config as a backup)
    [request setTimeoutInterval:1800.0]; // 30 minutes
    
    // Set up the network service type for a large download
    [request setNetworkServiceType:NSURLNetworkServiceTypeBackground];
    
    NSLog(@"Starting download with timeout: %.1f seconds", [request timeoutInterval]);
    NSLog(@"URL: %@", url.absoluteString);
    
    // Create download task with our custom request
    NSURLSessionDownloadTask *downloadTask = [_session downloadTaskWithRequest:request];
    
    // Set task description for debugging
    [downloadTask setTaskDescription:@"M3U Playlist Download"];
    
    // Set task priority to high
    [downloadTask setPriority:NSURLSessionTaskPriorityHigh];
    
    // Start the download
    [downloadTask resume];
}

// Progress callback
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {

    if (self.progressCallback) {
        self.progressCallback(totalBytesWritten, totalBytesExpectedToWrite);
    }
}

// Completion callback
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {

    NSURL *destinationURL = [NSURL fileURLWithPath:self.destinationPath];
    NSError *error = nil;

    [[NSFileManager defaultManager] removeItemAtURL:destinationURL error:nil];
    BOOL success = [[NSFileManager defaultManager] moveItemAtURL:location toURL:destinationURL error:&error];

    if (self.completionCallback) {
        self.completionCallback(success ? self.destinationPath : nil, error);
    }
}

// Handle task completion with possible error
- (void)URLSession:(NSURLSession *)session 
              task:(NSURLSessionTask *)task 
didCompleteWithError:(NSError *)error {
    
    if (error) {
        NSLog(@"Download task error: %@ (code: %ld, domain: %@)", 
             [error localizedDescription], (long)error.code, error.domain);
        
        // Define max retry attempts
        const NSInteger MAX_RETRY_COUNT = 5;
        
        // Check if we should retry based on error type
        BOOL shouldRetry = NO;
        
        if ([error.domain isEqualToString:NSURLErrorDomain]) {
            // Network errors that commonly benefit from retrying
            switch (error.code) {
                case NSURLErrorTimedOut:                  // Request timed out
                case NSURLErrorCannotConnectToHost:       // Server connection failed
                case NSURLErrorNetworkConnectionLost:     // Connection dropped
                case NSURLErrorNotConnectedToInternet:    // No internet
                case NSURLErrorDataNotAllowed:            // Data usage restrictions
                case NSURLErrorInternationalRoamingOff:   // Roaming issues
                case NSURLErrorCallIsActive:              // Call interrupted download
                case NSURLErrorDataLengthExceedsMaximum:  // Response too large
                case NSURLErrorResourceUnavailable:       // Resource unavailable temporarily 
                    shouldRetry = YES;
                    break;
                    
                default:
                    shouldRetry = NO;
                    break;
            }
        }
        
        // Also retry on certain CFNetwork errors
        if ([error.domain isEqualToString:(__bridge NSString *)kCFErrorDomainCFNetwork]) {
            // Socket errors, dropped connections, etc.
            shouldRetry = YES;
        }
        
        if (shouldRetry && self.retryCount < MAX_RETRY_COUNT && self.originalURLString) {
            // Calculate backoff time: 2^retry_count seconds (exponential backoff)
            // First retry: 2 seconds, second: 4 seconds, third: 8 seconds, fourth: 16 seconds, fifth: 32 seconds
            NSTimeInterval delay = pow(2.0, (double)self.retryCount);
            
            NSLog(@"Retrying download (attempt %ld of %ld) after %.1f second delay...", 
                 (long)self.retryCount + 1, (long)MAX_RETRY_COUNT, delay);
            
            // Increment retry count
            self.retryCount++;
            
            // Retry after delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), 
                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                // Create a new download task
                [self startDownloadFromURL:self.originalURLString
                          progressHandler:self.progressCallback
                        completionHandler:self.completionCallback
                          destinationPath:self.destinationPath];
            });
            
            // Don't call completion yet since we're retrying
            return;
        }
        
        // If we're not retrying or out of retries, call completion with error
        if (self.completionCallback) {
            // Only call completion with error if the completion wasn't already called in didFinishDownloadingToURL
            if ([task isKindOfClass:[NSURLSessionDownloadTask class]]) {
                NSURLSessionDownloadTask *downloadTask = (NSURLSessionDownloadTask *)task;
                if (downloadTask.countOfBytesReceived == 0) {
                    NSLog(@"Download failed with error: %@ (code: %ld) - Retries exhausted or error not recoverable", 
                         [error localizedDescription], (long)error.code);
                    self.completionCallback(nil, error);
                }
            } else {
                NSLog(@"Task failed with error: %@ (code: %ld) - Retries exhausted or error not recoverable", 
                     [error localizedDescription], (long)error.code);
                self.completionCallback(nil, error);
            }
        }
    }
}

// Clean up resources on dealloc
- (void)dealloc {
    [_session invalidateAndCancel];
    [super dealloc];
}

@end
