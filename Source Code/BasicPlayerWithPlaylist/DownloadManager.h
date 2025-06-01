//
//  DownloadManager.h
//  BasicPlayerWithPlaylist
//
//  Created by Nurettin Akpolat on 20/05/2025.
//

#import <Foundation/Foundation.h>

@interface DownloadManager : NSObject <NSURLSessionDownloadDelegate>

@property (nonatomic, copy) void (^progressCallback)(int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite);
@property (nonatomic, copy) void (^completionCallback)(NSString *filePath, NSError *error);
@property (nonatomic, copy) NSString *destinationPath;
@property (nonatomic, assign) NSInteger retryCount;
@property (nonatomic, copy) NSString *originalURLString;

- (void)startDownloadFromURL:(NSString *)urlString
             progressHandler:(void (^)(int64_t, int64_t))progressHandler
           completionHandler:(void (^)(NSString *, NSError *))completionHandler
             destinationPath:(NSString *)destinationPath;

@end
