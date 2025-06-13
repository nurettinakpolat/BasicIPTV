//git push -u -f origin main

#include <stdio.h>
#import "PlatformBridge.h"
#import <VLCKit/VLCKit.h>  // Import VLCKit to use VLCMedia, VLCMediaPlayer, etc.
#import <objc/runtime.h>    // For associated objects
#import "VLCDataManager.h"  // For EPG management

#if TARGET_OS_OSX
    #import <Cocoa/Cocoa.h>
    #import "VLCGLVideoView.h"
    #import "VLCOverlayView.h"
#elif TARGET_OS_IOS || TARGET_OS_TV
    #import <UIKit/UIKit.h>
    #import "VLCUIVideoView.h"
    #import "VLCUIOverlayView.h"
#endif

// Key for temporary early playback channel object
static char tempEarlyPlaybackChannelKey;

#if TARGET_OS_OSX
// macOS function declarations
void createSampleChannelsForOverlay(VLCOverlayView *overlayView);
void createInMemoryChannels(VLCOverlayView *overlayView);
void createMinimalChannels(VLCOverlayView *overlayView);

// Window delegate implementation to handle window closing
@interface AppDelegate : NSObject <NSWindowDelegate>
@property (nonatomic, assign) VLCOverlayView *overlayView; // Add reference to overlay view

// Method declarations
- (void)startOptimizedCacheLoading:(id)overlayView;
- (void)startBackgroundRefreshIfNeeded:(id)overlayView channelsLoaded:(BOOL)channelsLoaded epgLoaded:(BOOL)epgLoaded;
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

- (void)windowDidResize:(NSNotification *)notification {
    // Handle window resize
    if (self.overlayView && [self.overlayView respondsToSelector:@selector(updateLayout)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.overlayView updateLayout];
        });
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    // Ensure overlay view updates its layout for fullscreen
    if (self.overlayView && [self.overlayView respondsToSelector:@selector(updateLayout)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.overlayView updateLayout];
            [self.overlayView setNeedsDisplay:YES];
        });
    }
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    // Ensure overlay view updates its layout when exiting fullscreen
    if (self.overlayView && [self.overlayView respondsToSelector:@selector(updateLayout)]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.overlayView updateLayout];
            [self.overlayView setNeedsDisplay:YES];
        });
    }
}

- (void)startOptimizedCacheLoading:(id)overlayView {
    NSLog(@"🚀 [OPTIMIZE] Starting universal cache loading via VLCDataManager...");
    
    // CRITICAL: Set delegate BEFORE starting operations (on main queue)
    VLCDataManager *dataManager = [VLCDataManager sharedManager];
    dataManager.delegate = overlayView;
    
    // CRITICAL: Set the overlay view's dataManager reference
    if ([overlayView respondsToSelector:@selector(setDataManager:)]) {
        [overlayView setDataManager:dataManager];
    }
    
    // Set URLs first, then start universal loading sequence
    if ([overlayView respondsToSelector:@selector(m3uFilePath)] && [overlayView m3uFilePath]) {
        dataManager.m3uURL = [overlayView m3uFilePath];
    }
    
    if ([overlayView respondsToSelector:@selector(epgUrl)] && [overlayView epgUrl]) {
        dataManager.epgURL = [overlayView epgUrl];
    }
    
    // Start universal sequential loading (Channels → EPG)
    [dataManager startUniversalDataLoading];
    
    NSLog(@"✅ [UNIVERSAL] Cache loading operations initiated via VLCDataManager");
}

- (void)startBackgroundRefreshIfNeeded:(id)overlayView channelsLoaded:(BOOL)channelsLoaded epgLoaded:(BOOL)epgLoaded {
    NSLog(@"🔄 [REFRESH] Universal VLCDataManager handles refresh internally - no additional refresh needed");
    
    // VLCDataManager automatically handles cache validity and refresh
    // No need for manual background refresh coordination
}

@end

#else

// iOS/tvOS function declarations
void createSampleChannelsForOverlay(VLCUIOverlayView *overlayView);
void createInMemoryChannels(VLCUIOverlayView *overlayView);
void createMinimalChannels(VLCUIOverlayView *overlayView);

// Custom View Controller with rotation support
@interface ResponsiveViewController : UIViewController
@end

@implementation ResponsiveViewController

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    // IPTV apps work best in landscape mode - only support landscape orientations
    return UIInterfaceOrientationMaskLandscape;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeLeft;
}

- (BOOL)prefersStatusBarHidden {
    return YES; // Hide status bar for full-screen IPTV experience
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Ensure full-screen layout
    if (@available(iOS 11.0, *)) {
        self.extendedLayoutIncludesOpaqueBars = YES;
        self.edgesForExtendedLayout = UIRectEdgeAll;
        self.automaticallyAdjustsScrollViewInsets = NO;
    }
}

@end

// iOS/tvOS App Delegate
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) VLCUIOverlayView *overlayView;
@property (strong, nonatomic) VLCMediaPlayer *player;

// Method declarations
- (void)startOptimizedCacheLoading:(id)overlayView;
- (void)startBackgroundRefreshIfNeeded:(id)overlayView channelsLoaded:(BOOL)channelsLoaded epgLoaded:(BOOL)epgLoaded;

@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSLog(@"📱 iOS App starting...");
    
    @try {
        // Create window with full screen bounds for modern iPhone support
        if (@available(iOS 13.0, *)) {
            // iOS 13+ scene-based approach would go here, but for simplicity using legacy window
            self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        } else {
            self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        }
        
        // Ensure window uses full screen
        self.window.backgroundColor = [UIColor blackColor];
        
        // Create the main view controller with rotation support and full-screen layout
        ResponsiveViewController *viewController = [[ResponsiveViewController alloc] init];
        viewController.view.backgroundColor = [UIColor blackColor];
        
        // Configure for full-screen edge-to-edge layout
        if (@available(iOS 11.0, *)) {
            viewController.extendedLayoutIncludesOpaqueBars = YES;
            viewController.edgesForExtendedLayout = UIRectEdgeAll;
        }
        
        // Set environment variables to suppress FFmpeg/VLC debug output
        setenv("VLC_VERBOSE", "-1", 1);
        setenv("AVUTIL_LOGLEVEL", "quiet", 1);
        setenv("AV_LOG_FORCE_NOCOLOR", "1", 1);
        
        NSLog(@"🎬 Initializing VLC for iOS...");
        // Create VLC instance with minimal safe arguments to suppress debug output
        NSArray *vlcArguments = @[
            @"--intf=dummy",           // Use dummy interface
            @"--verbose=-1",          // Minimum verbosity
            @"--quiet"                // Suppress output
        ];
        
        VLCLibrary *vlcLibrary = [[VLCLibrary alloc] initWithOptions:vlcArguments];
        vlcLibrary.loggers = @[];  // Remove all VLC loggers
        
        // Create VLC media player
        self.player = [[VLCMediaPlayer alloc] init];
        
        // CRITICAL: Create the video view first (this was missing!)
        NSLog(@"🎬 Creating iOS video view...");
        VLCUIVideoView *videoView = [[VLCUIVideoView alloc] initWithFrame:viewController.view.bounds];
        videoView.player = self.player;
        [self.player setDrawable:videoView];
        [viewController.view addSubview:videoView];
        
        // Setup auto layout for video view - use full screen edge-to-edge
        videoView.translatesAutoresizingMaskIntoConstraints = NO;
        if (@available(iOS 11.0, *)) {
            // Use full screen without safe area constraints for IPTV
            [NSLayoutConstraint activateConstraints:@[
                [videoView.topAnchor constraintEqualToAnchor:viewController.view.topAnchor],
                [videoView.leadingAnchor constraintEqualToAnchor:viewController.view.leadingAnchor],
                [videoView.trailingAnchor constraintEqualToAnchor:viewController.view.trailingAnchor],
                [videoView.bottomAnchor constraintEqualToAnchor:viewController.view.bottomAnchor]
            ]];
        } else {
            // Fallback for older iOS versions
            [NSLayoutConstraint activateConstraints:@[
                [videoView.topAnchor constraintEqualToAnchor:viewController.view.topAnchor],
                [videoView.leadingAnchor constraintEqualToAnchor:viewController.view.leadingAnchor],
                [videoView.trailingAnchor constraintEqualToAnchor:viewController.view.trailingAnchor],
                [videoView.bottomAnchor constraintEqualToAnchor:viewController.view.bottomAnchor]
            ]];
        }
        NSLog(@"🎬 iOS video view created and configured successfully");
        
        NSLog(@"🎬 VLC initialized successfully for iOS");
        
        // Create and setup the overlay view after a delay to ensure VLC is initialized
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"🎬 Creating iOS overlay view...");
            
            // Create the overlay view ON TOP of the video view
            NSLog(@"🎬 Creating VLCUIOverlayView...");
            self.overlayView = [[VLCUIOverlayView alloc] initWithFrame:viewController.view.bounds];
            self.overlayView.player = self.player;
            self.overlayView.backgroundColor = [UIColor clearColor]; // Transparent overlay
            NSLog(@"🎬 VLC player assigned successfully");
            [viewController.view addSubview:self.overlayView]; // Add on top of video view
            
            // Setup auto layout for overlay view - use full screen edge-to-edge
            self.overlayView.translatesAutoresizingMaskIntoConstraints = NO;
            if (@available(iOS 11.0, *)) {
                // Use full screen without safe area constraints for IPTV
                [NSLayoutConstraint activateConstraints:@[
                    [self.overlayView.topAnchor constraintEqualToAnchor:viewController.view.topAnchor],
                    [self.overlayView.leadingAnchor constraintEqualToAnchor:viewController.view.leadingAnchor],
                    [self.overlayView.trailingAnchor constraintEqualToAnchor:viewController.view.trailingAnchor],
                    [self.overlayView.bottomAnchor constraintEqualToAnchor:viewController.view.bottomAnchor]
                ]];
            } else {
                // Fallback for older iOS versions
                [NSLayoutConstraint activateConstraints:@[
                    [self.overlayView.topAnchor constraintEqualToAnchor:viewController.view.topAnchor],
                    [self.overlayView.leadingAnchor constraintEqualToAnchor:viewController.view.leadingAnchor],
                    [self.overlayView.trailingAnchor constraintEqualToAnchor:viewController.view.trailingAnchor],
                    [self.overlayView.bottomAnchor constraintEqualToAnchor:viewController.view.bottomAnchor]
                ]];
            }
            
            NSLog(@"🎬 iOS overlay view created successfully");
            
            // Load settings and themes first (fast, from local files) - MUST be synchronous
            NSLog(@"📋 Loading settings synchronously...");
            [self.overlayView loadSettings];
            NSLog(@"📋 Settings loaded - M3U path: %@", self.overlayView.m3uFilePath ? self.overlayView.m3uFilePath : @"(nil)");
            NSLog(@"📋 Settings loaded - EPG URL: %@", self.overlayView.epgUrl ? self.overlayView.epgUrl : @"(nil)");
            
            [self.overlayView loadThemeSettings];
            [self.overlayView loadViewModePreference];
            
            NSLog(@"📋 All settings loaded - Final M3U path: %@", self.overlayView.m3uFilePath ? self.overlayView.m3uFilePath : @"(nil)");
            
            // Ensure we have a valid M3U path before proceeding
            if (!self.overlayView.m3uFilePath || [self.overlayView.m3uFilePath length] == 0) {
                NSLog(@"⚠️ No M3U path found in settings, using default local path");
                self.overlayView.m3uFilePath = [self.overlayView localM3uFilePath];
                NSLog(@"📁 Default M3U path set to: %@", self.overlayView.m3uFilePath);
            }
            
            // OPTIMIZED: Start cache loading immediately on multiple background queues
            NSLog(@"🚀 [STARTUP] Starting parallel cache loading...");
            [self startOptimizedCacheLoading:self.overlayView];
            
            // Start UI immediately while cache loads in background
            [self.overlayView setNeedsDisplay:YES];
            [self.overlayView startEarlyPlaybackIfAvailable];
        });
        
        self.window.rootViewController = viewController;
        [self.window makeKeyAndVisible];
        
        NSLog(@"📱 iOS App launched successfully");
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in iOS didFinishLaunchingWithOptions: %@", exception);
        return NO;
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    NSLog(@"📱 iOS App terminating");
    // Save current playback position before terminating (like macOS version)
    if (self.overlayView && [self.overlayView respondsToSelector:@selector(saveCurrentPlaybackPosition)]) {
        NSLog(@"💾 Saving current playback position...");
        [self.overlayView saveCurrentPlaybackPosition];
    }
}

- (void)startOptimizedCacheLoading:(id)overlayView {
    NSLog(@"🚀 [OPTIMIZE] Starting universal cache loading via VLCDataManager...");
    
    // Show startup progress window at the beginning of iOS startup
    if ([overlayView respondsToSelector:@selector(showStartupProgressWindow)]) {
        [overlayView showStartupProgressWindow];
        if ([overlayView respondsToSelector:@selector(updateStartupProgress:step:details:)]) {
            [overlayView updateStartupProgress:0.05 step:@"Initializing" details:@"Starting BasicIPTV..."];
        }
    }
    
    // CRITICAL: Set delegate BEFORE starting operations (on main queue)
    VLCDataManager *dataManager = [VLCDataManager sharedManager];
    dataManager.delegate = overlayView;
    
    // CRITICAL: Set the overlay view's dataManager reference
    if ([overlayView respondsToSelector:@selector(setDataManager:)]) {
        [overlayView setDataManager:dataManager];
    }
    
    // Set URLs first, then start universal loading sequence
    if ([overlayView respondsToSelector:@selector(m3uFilePath)] && [overlayView m3uFilePath]) {
        dataManager.m3uURL = [overlayView m3uFilePath];
    }
    
    if ([overlayView respondsToSelector:@selector(epgUrl)] && [overlayView epgUrl]) {
        dataManager.epgURL = [overlayView epgUrl];
    }
    
    // Start universal sequential loading (Channels → EPG)
    [dataManager startUniversalDataLoading];
    
    NSLog(@"✅ [UNIVERSAL] Cache loading operations initiated via VLCDataManager");
}

- (void)startBackgroundRefreshIfNeeded:(id)overlayView channelsLoaded:(BOOL)channelsLoaded epgLoaded:(BOOL)epgLoaded {
    NSLog(@"🔄 [REFRESH] Universal VLCDataManager handles refresh internally - no additional refresh needed");
    
    // VLCDataManager automatically handles cache validity and refresh
    // No need for manual background refresh coordination
}

@end

#endif // TARGET_OS_OSX

#if TARGET_OS_OSX

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        @try {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            
            // Disable automatic window restoration to prevent restoration warnings
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"NSQuitAlwaysKeepsWindows"];
            
            // Set environment variables to suppress FFmpeg/VLC debug output
            setenv("VLC_VERBOSE", "-1", 1);
            setenv("AVUTIL_LOGLEVEL", "quiet", 1);
            setenv("AV_LOG_FORCE_NOCOLOR", "1", 1);
            
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
            // Create VLC instance with minimal safe arguments to suppress debug output
            NSArray *vlcArguments = @[
                @"--intf=dummy",           // Use dummy interface
                @"--verbose=-1",          // Minimum verbosity
                @"--quiet"                // Suppress output
            ];
            
            VLCLibrary *vlcLibrary = [[VLCLibrary alloc] initWithOptions:vlcArguments];
            
            // Disable VLC logging while preserving NSLog output
            vlcLibrary.loggers = @[];  // Remove all VLC loggers
            
            NSLog(@"VLC logging disabled with command line arguments - NSLog still works!");
            
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
                    NSLog(@"Setting up player controls");
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
                    NSLog(@"Player controls not available");
                }
                
                // Set visibility
                overlayView.isChannelListVisible = NO; // Don't show channel list
                [overlayView setNeedsDisplay:YES];
                
                // Load settings and themes first (fast, from local files) - MUST be synchronous
                NSLog(@"📋 Loading settings synchronously...");
                [overlayView loadSettings];
                NSLog(@"📋 Settings loaded - M3U path: %@", overlayView.m3uFilePath ? overlayView.m3uFilePath : @"(nil)");
                NSLog(@"📋 Settings loaded - EPG URL: %@", overlayView.epgUrl ? overlayView.epgUrl : @"(nil)");
                
                [overlayView loadThemeSettings];
                [overlayView loadViewModePreference];
                
                NSLog(@"📋 All settings loaded - Final M3U path: %@", overlayView.m3uFilePath ? overlayView.m3uFilePath : @"(nil)");
                
                // Ensure we have a valid M3U path before proceeding
                if (!overlayView.m3uFilePath || [overlayView.m3uFilePath length] == 0) {
                    NSLog(@"⚠️ No M3U path found in settings, using default local path");
                    overlayView.m3uFilePath = [overlayView localM3uFilePath];
                    NSLog(@"📁 Default M3U path set to: %@", overlayView.m3uFilePath);
                }
                
                // OPTIMIZED: Start cache loading immediately on multiple background queues
                NSLog(@"🚀 [STARTUP] Starting parallel cache loading...");
                [appDelegate startOptimizedCacheLoading:overlayView];
                
                // Start UI immediately while cache loads in background
                [overlayView setNeedsDisplay:YES];
                [overlayView startEarlyPlaybackIfAvailable];
            });

            [NSApp run];
        } @catch (NSException *exception) {
            NSLog(@"Fatal exception in main: %@", exception);
        }
    }
    return 0;
}

#else

int main(int argc, char * argv[]) {
    @autoreleasepool {
        @try {
            // Set environment variables to suppress FFmpeg/VLC debug output
            setenv("VLC_VERBOSE", "-1", 1);
            setenv("AVUTIL_LOGLEVEL", "quiet", 1);
            setenv("AV_LOG_FORCE_NOCOLOR", "1", 1);
            
            return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
        } @catch (NSException *exception) {
            NSLog(@"Fatal exception in iOS main: %@", exception);
            return 1;
        }
    }
}

#endif

#if TARGET_OS_OSX
// Extract channel creation to a separate function for cleaner organization
void createSampleChannelsForOverlay(VLCOverlayView *overlayView) {
    if (!overlayView) return;
    
    // Don't create temporary files here - let the cache system handle proper loading
    // The loadChannelsFile method will:
    // 1. First check for cached data (fast)
    // 2. Load from Application Support directory if available
    // 3. Create default data if nothing exists
    // This function is now mainly a placeholder for any additional setup needed
    
    NSLog(@"📺 Channel loading will be handled by cache system via loadChannelsFile");
}

#else

// iOS/tvOS implementation
void createSampleChannelsForOverlay(VLCUIOverlayView *overlayView) {
    NSLog(@"📺 iOS createSampleChannelsForOverlay called");
    if (!overlayView) {
        NSLog(@"❌ No overlay view provided");
        return;
    }
    
    // The actual channel loading will be handled by the cache-first loading sequence
    // in the AppDelegate, so this function is mainly for any additional setup
    NSLog(@"📺 Channel loading will be handled by cache system via AppDelegate");
}

void createInMemoryChannels(VLCUIOverlayView *overlayView) {
    NSLog(@"📺 iOS createInMemoryChannels called (simplified)");
    // iOS/tvOS implementation stub
}

void createMinimalChannels(VLCUIOverlayView *overlayView) {
    NSLog(@"📺 iOS createMinimalChannels called (simplified)");
    // iOS/tvOS implementation stub
}

#endif
