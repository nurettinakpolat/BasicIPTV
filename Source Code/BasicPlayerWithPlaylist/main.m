//git push -u -f origin main

#include <stdio.h>
#import "VLCGLVideoView.h"
#import "VLCOverlayView.h"
#import <VLCKit/VLCKit.h>  // Import VLCKit to use VLCMedia, VLCMediaPlayer, etc.
#import <objc/runtime.h>    // For associated objects

// Key for temporary early playback channel object
static char tempEarlyPlaybackChannelKey;

// Define our helper functions as C functions
void createSampleChannelsForOverlay(VLCOverlayView *overlayView);
void createInMemoryChannels(VLCOverlayView *overlayView);
void createMinimalChannels(VLCOverlayView *overlayView);

// Window delegate implementation to handle window closing
@interface AppDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, assign) VLCOverlayView *overlayView; // Add reference to overlay view
@end

@implementation AppDelegate
- (BOOL)windowShouldClose:(NSWindow *)sender {
    //NSLog(@"=== WINDOW CLOSE: windowShouldClose called ===");
    
    // Save current playback position before closing
    if (self.overlayView && [self.overlayView respondsToSelector:@selector(saveCurrentPlaybackPosition)]) {
        //NSLog(@"=== WINDOW CLOSE: Calling saveCurrentPlaybackPosition ===");
        [self.overlayView saveCurrentPlaybackPosition];
        //NSLog(@"=== WINDOW CLOSE: saveCurrentPlaybackPosition completed ===");
    } else {
        //NSLog(@"=== WINDOW CLOSE: overlayView not available or doesn't respond to saveCurrentPlaybackPosition ===");
    }
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    //NSLog(@"=== WINDOW CLOSE: windowWillClose called ===");
    [NSApp terminate:nil];
}
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        @try {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            
            // Create app delegate
            AppDelegate *appDelegate = [[AppDelegate alloc] init];
            
            NSWindow *window = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(100, 100, 1280, 720)
                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskResizable | NSWindowStyleMaskClosable)
                            backing:NSBackingStoreBuffered
                              defer:NO];
            [window setTitle:@"IPTV Player"];
            [window setDelegate:appDelegate]; // Set the window delegate
            [window makeKeyAndOrderFront:nil];
            
            NSView *contentView = [window contentView];
            NSRect bounds = [contentView bounds];
            
            // Configure VLC logging BEFORE creating any VLC objects
            VLCLibrary *vlcLibrary = [VLCLibrary sharedLibrary];
            
            // Try to completely disable VLC logging by setting an empty loggers array
            vlcLibrary.loggers = @[];
            
            //NSLog(@"VLC logging disabled by setting empty loggers array");
            
            // Create the video view for VLC
            VLCGLVideoView *videoView = [[VLCGLVideoView alloc] initWithFrame:bounds];
            videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [contentView addSubview:videoView];
            
            // Set up VLCKit
            VLCMediaPlayer *player = [[VLCMediaPlayer alloc] init];
            videoView.player = player;
            [player setDrawable:videoView];
            
            // Add a simple overlay after a delay to ensure VLC is initialized
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Create and configure the overlay view
                VLCOverlayView *overlayView = [[VLCOverlayView alloc] initWithFrame:bounds];
                overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
                overlayView.player = player;
                [contentView addSubview:overlayView];
                
                // Set the overlay view reference in app delegate for position saving
                appDelegate.overlayView = overlayView;
                
                // Make sure overlay is in front
                [contentView addSubview:overlayView positioned:NSWindowAbove relativeTo:nil];
                
                // Initialize player controls if available
                if ([overlayView respondsToSelector:@selector(manuallyShowControls)]) {
                    //NSLog(@"Setting up player controls");
                    [overlayView performSelector:@selector(manuallyShowControls)];
                    
                    // Add a gesture recognizer to detect mouse movement and show controls
                    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *event) {
                        NSPoint point = [overlayView convertPoint:[event locationInWindow] fromView:nil];
                        if (point.y < 120) { // Show when mouse is at bottom
                            [overlayView performSelector:@selector(showPlayerControls)];
                        }
                        return event;
                    }];
                } else {
                    //NSLog(@"Player controls not available");
                }
                
                // Set visibility
                overlayView.isChannelListVisible = NO; // Don't show channel list
                [overlayView setNeedsDisplay:YES];
                //NSLog(@"Added simple overlay view");
                
                // Load channels and settings (including EPG) FIRST - before early playback
                //NSLog(@"Starting loading of channels and EPG...");
                [overlayView loadChannelsFile];
                [overlayView startEarlyPlaybackIfAvailable];
                // START EARLY PLAYBACK AFTER CHANNELS ARE LOADED
                /*dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSLog(@"Starting early playback check after channels loaded...");
                    if ([overlayView respondsToSelector:@selector(startEarlyPlaybackIfAvailable)]) {
                        [overlayView startEarlyPlaybackIfAvailable];
                    } else {
                        NSLog(@"Early playback method not available");
                    }
                });*/
                 
                
                // After more time, try to sync the selection with what's currently playing
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // Try to sync the selection with what's currently playing
                    NSString *lastChannelUrl = [overlayView getLastPlayedChannelUrl];
                    if (lastChannelUrl && [lastChannelUrl length] > 0) {
                        //NSLog(@"Syncing selection with currently playing content: %@", lastChannelUrl);
                        
                        // Try to find and select the currently playing channel in the UI
                        if (overlayView.simpleChannelUrls) {
                            NSInteger urlIndex = [overlayView.simpleChannelUrls indexOfObject:lastChannelUrl];
                            if (urlIndex != NSNotFound) {
                                overlayView.selectedChannelIndex = urlIndex;
                                //NSLog(@"Synced selection to channel index: %ld", (long)urlIndex);
                                [overlayView setNeedsDisplay:YES];
                                
                                // Clear the temporary cached channel since we now have real data
                                objc_setAssociatedObject(overlayView, &tempEarlyPlaybackChannelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            }
                        }
                    } else {
                        //NSLog(@"No previously played channel found for syncing");
                    }
                });
            });

            [NSApp run];
        } @catch (NSException *exception) {
            //NSLog(@"Fatal exception in main: %@", exception);
        }
    }
    return 0;
}

// Extract channel creation to a separate function for cleaner organization
void createSampleChannelsForOverlay(VLCOverlayView *overlayView) {
    if (!overlayView) return;
    
    // Create a sample M3U file in the temporary directory (which we should have write access to)
    NSString *tempDir = NSTemporaryDirectory();
    NSString *m3uPath = [tempDir stringByAppendingPathComponent:@"channels.m3u"];
    
  
        // Load the M3U file
    [overlayView loadChannelsFromM3uFile:m3uPath];
    
}
