//
//  VLCUIOverlayView.m
//  BasicIPTV - iOS/tvOS Overlay View
//
//  UIKit-based overlay view implementation for iOS and tvOS
//  Shares the same visual style and functionality as macOS VLCOverlayView
//

#import "VLCUIOverlayView.h"

#if TARGET_OS_IOS || TARGET_OS_TV

#import <mach/mach.h>
#import <objc/runtime.h>

#import "VLCChannel.h"
#import "VLCProgram.h"
#import "DownloadManager.h"
#import <CommonCrypto/CommonDigest.h>
// #import "VLCOverlayView+EPG.h" - REMOVED: Old EPG system eliminated
#import "VLCOverlayView+ChannelManagement.h"
#import "VLCDataManager.h"
#import "VLCCacheManager.h"

// EPG functionality is now shared between macOS and iOS via the EPG category

// Global variables for EPG progress messaging (shared with EPG module)
NSLock *gProgressMessageLock = nil;
NSString *gProgressMessage = nil;

// Progress timer for loading states
static NSTimer *gProgressRedrawTimer = nil;

// Responsive layout constants - calculated based on screen size and retina scale
#define GRID_ITEM_HEIGHT 300
#define STACKED_ROW_HEIGHT 400

// Category indices (matching macOS)
typedef enum {
    CATEGORY_SEARCH = 0,
    CATEGORY_FAVORITES = 1,
    CATEGORY_TV = 2,
    CATEGORY_MOVIES = 3,
    CATEGORY_SERIES = 4,
    CATEGORY_SETTINGS = 5
} CategoryIndex;

// View modes (matching macOS)
typedef enum {
    VIEW_MODE_STACKED = 0,
    VIEW_MODE_GRID = 1,
    VIEW_MODE_LIST = 2
} ViewMode;

@interface VLCUIOverlayView () <VLCDataManagerDelegate> {
    // Universal data manager
    VLCDataManager *_dataManager;
    
    // Data structures (shared with macOS)
    NSMutableArray *_channels;
    NSMutableArray *_groups;
    NSMutableDictionary *_channelsByGroup;
    NSArray *_categories;
    NSMutableDictionary *_groupsByCategory;
    NSArray *_simpleChannelNames;
    NSArray *_simpleChannelUrls;
    
    // Touch/gesture handling
    UITapGestureRecognizer *_singleTapGesture;
    UITapGestureRecognizer *_doubleTapGesture;
    UIPanGestureRecognizer *_panGesture;
    UILongPressGestureRecognizer *_longPressGesture;
    
    // UI state
    BOOL _isChannelListVisible;
    NSInteger _selectedCategoryIndex;
    NSInteger _selectedGroupIndex;
    NSInteger _hoveredChannelIndex;
    NSInteger _selectedChannelIndex;
    
    // Scroll positions
    CGFloat _categoryScrollPosition;
    CGFloat _groupScrollPosition;
    CGFloat _channelScrollPosition;
    CGFloat _programGuideScrollPosition;
    
    // View mode
    ViewMode _currentViewMode;
    BOOL _isGridViewActive;
    BOOL _isStackedViewActive;
    
    // Colors (matching macOS theme system)
    UIColor *_backgroundColor;
    UIColor *_hoverColor;
    UIColor *_textColor;
    UIColor *_groupColor;
    UIColor *_themeChannelStartColor;
    UIColor *_themeChannelEndColor;
    CGFloat _themeAlpha;
    
    // Cached fonts for memory efficiency
    UIFont *_cachedCategoryFont;
    UIFont *_cachedGroupFont;
    UIFont *_cachedChannelFont;
    UIFont *_cachedChannelNumberFont;
    CGFloat _cachedScreenWidth;
    CGFloat _cachedScreenScale;
    
    // Download synchronization to prevent memory leaks
    BOOL _isDownloadingChannels;
    BOOL _isDownloadingEPG;
    NSURLSessionDataTask *_currentChannelDownloadTask;
    NSURLSessionDataTask *_currentEPGDownloadTask;
    
    // Force fresh EPG download flag
    BOOL _shouldForceEPGDownloadAfterChannels;
    
    // Layout loop prevention
    BOOL _isInLayoutUpdate;
    
    // Drawing throttling to prevent memory crashes
    NSDate *_lastDrawTime;
    BOOL _needsRedraw;
    
    // Memory management for large channel sets
    NSUInteger _maxChannelsPerGroup;
    NSUInteger _maxTotalChannels;
    BOOL _isMemoryConstrained;
    
    // tvOS navigation state
    NSInteger _tvosNavigationArea; // 0=categories, 1=groups, 2=channels, 3=settings, 4=player controls
    BOOL _playerControlsNavigationMode; // YES when navigating within player controls
    NSInteger _selectedPlayerControl; // 0=progress, 1=CC button, 2=Audio button
NSInteger _tvosSelectedSettingsControl; // Index of currently selected settings control
    
    // Loading panel
    UIView *_loadingPaneliOS;
    UILabel *_m3uProgressLabeliOS;
    UIProgressView *_m3uProgressBariOS;
    UILabel *_epgProgressLabeliOS;
    UIProgressView *_epgProgressBariOS;
    
    // Program guide momentum scrolling
    CGFloat _programGuideMomentumVelocity;
    CGFloat _programGuideMomentumMaxScroll;
    CADisplayLink *_programGuideMomentumDisplayLink;
    
    // tvOS long press detection
    NSTimer *_selectLongPressTimer;
    
    // Auto-hide timer for iOS/tvOS
    NSTimer *_autoHideTimer;
    
    // Player controls for iOS/tvOS
    BOOL _playerControlsVisible;
    
    // Mac-style touch tracking for progress bar hover marker
    BOOL _progressBarBeingTouched;
    CGPoint _progressBarTouchPoint;
    
    // iOS Progress Bar Scrubbing Support
    UIPanGestureRecognizer *_progressBarPanGesture;
    BOOL _isScrubbingProgressBar;
    CGPoint _progressBarScrubStartPoint;
    CGFloat _progressBarScrubStartPosition;
    UIView *_timePreviewOverlay;
    UILabel *_timePreviewLabel;
}

// Drawing layers for different UI components
@property (nonatomic, strong) CALayer *categoriesLayer;
@property (nonatomic, strong) CALayer *groupsLayer;
@property (nonatomic, strong) CALayer *channelListLayer;
@property (nonatomic, strong) CALayer *programGuideLayer;

@end

@implementation VLCUIOverlayView

#pragma mark - Auto-Hide Timer (iOS/tvOS)

- (void)resetAutoHideTimer {
    #if TARGET_OS_IOS || TARGET_OS_TV
    [self stopAutoHideTimer];
    
    // Don't start auto-hide timer during startup to avoid hiding progress window
    if (self.isStartupInProgress) {
        NSLog(@"📱 [AUTO-HIDE] Startup in progress - delaying auto-hide timer");
        return;
    }
    
    // Only start timer if menu is visible
    if (_isChannelListVisible) {
        _autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                          target:self
                                                        selector:@selector(autoHideTimerFired:)
                                                        userInfo:nil
                                                         repeats:NO];
        NSLog(@"📱 [AUTO-HIDE] Timer started - menu will hide in 5 seconds");
    }
    #endif
}

- (void)stopAutoHideTimer {
    #if TARGET_OS_IOS || TARGET_OS_TV
    if (_autoHideTimer) {
        [_autoHideTimer invalidate];
        _autoHideTimer = nil;
        NSLog(@"📱 [AUTO-HIDE] Timer stopped");
    }
    #endif
}

- (void)restartTimerAfterNavigation {
    #if TARGET_OS_IOS || TARGET_OS_TV
    // Cancel any previous pending restart
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restartTimerAfterNavigation) object:nil];
    
    // Only restart timer if menu is still visible or player controls are visible
    if (_isChannelListVisible) {
        [self resetAutoHideTimer];
        NSLog(@"📱 [AUTO-HIDE] Timer restarted after navigation (menu visible)");
    } else if (_playerControlsVisible) {
        [self resetPlayerControlsTimer];
        NSLog(@"📱 [AUTO-HIDE] Timer restarted after navigation (player controls visible)");
    }
    #endif
}

- (void)autoHideTimerFired:(NSTimer *)timer {
    #if TARGET_OS_IOS || TARGET_OS_TV
    if (_isChannelListVisible) {
        NSLog(@"📱 [AUTO-HIDE] Timer fired - hiding menu and all controls");
        _isChannelListVisible = NO;
        
        // Check if startup is in progress - if so, don't hide startup progress window
        if (self.isStartupInProgress) {
            NSLog(@"📱 [AUTO-HIDE] Startup in progress - hiding controls but keeping progress window");
            [self hideAllControlsExceptStartupProgress];
        } else {
        [self hideAllControls];
        }
    } else if (_playerControlsVisible) {
        NSLog(@"📱 [AUTO-HIDE] Timer fired - hiding player controls");
        _playerControlsVisible = NO;
    }
    [self setNeedsDisplay];
    [self stopAutoHideTimer];
    #endif
}

#pragma mark - Player Controls (iOS/tvOS)

- (void)showPlayerControls {
    #if TARGET_OS_IOS || TARGET_OS_TV
    _playerControlsVisible = YES;
    [self resetPlayerControlsTimer]; // Use Mac-style timer
    [self setNeedsDisplay];
    //NSLog(@"📱 [TRUE-MAC-CONTROLS] Showing Mac-style player controls (auto-hide in 5 seconds)");
    
    // Schedule a track refresh to ensure tracks are populated
    // This fixes the issue where tracks don't show until hide/show
    [self scheduleTrackRefresh];
    #endif
}

- (void)hidePlayerControls {
    #if TARGET_OS_IOS || TARGET_OS_TV
    _playerControlsVisible = NO;
    // Reset navigation mode when hiding controls
    _playerControlsNavigationMode = NO;
    _selectedPlayerControl = -1;
    [self setNeedsDisplay];
    //NSLog(@"📱 [PLAYER-CONTROLS] Hiding player controls");
    #endif
}

- (void)hideAllControls {
    #if TARGET_OS_IOS || TARGET_OS_TV
    NSLog(@"📱 [HIDE-ALL] Hiding all visible controls");
    
    // Hide player controls
    [self hidePlayerControls];
    
    // Hide settings panel
    if (_settingsScrollViewiOS && !_settingsScrollViewiOS.hidden) {
        _settingsScrollViewiOS.hidden = YES;
        NSLog(@"📱 [HIDE-ALL] Hidden settings panel");
    }
    
    // Hide theme settings scroll view
    if (_themeSettingsScrollView && !_themeSettingsScrollView.hidden) {
        _themeSettingsScrollView.hidden = YES;
        NSLog(@"📱 [HIDE-ALL] Hidden theme settings panel");
    }
    
    // Hide subtitle settings scroll view
    if (_subtitleSettingsScrollView && !_subtitleSettingsScrollView.hidden) {
        _subtitleSettingsScrollView.hidden = YES;
        NSLog(@"📱 [HIDE-ALL] Hidden subtitle settings panel");
    }
    
    // Hide loading panel ONLY if manual loading is not in progress
    if (_loadingPaneliOS && !_loadingPaneliOS.hidden && !self.isManualLoadingInProgress) {
        _loadingPaneliOS.hidden = YES;
        NSLog(@"📱 [HIDE-ALL] Hidden loading panel");
    } else if (_loadingPaneliOS && !_loadingPaneliOS.hidden && self.isManualLoadingInProgress) {
        NSLog(@"📱 [HIDE-ALL] Keeping loading panel visible - manual loading in progress");
    }
    
    // Hide startup progress window ONLY if startup is not in progress
    if (_startupProgressWindow && !_startupProgressWindow.hidden && !self.isStartupInProgress) {
        [self hideStartupProgressWindow];
        NSLog(@"📱 [HIDE-ALL] Hidden startup progress window");
    } else if (_startupProgressWindow && !_startupProgressWindow.hidden && self.isStartupInProgress) {
        NSLog(@"📱 [HIDE-ALL] Keeping startup progress window visible - startup still in progress");
    }
    
    [self setNeedsDisplay];
    NSLog(@"📱 [HIDE-ALL] All controls hidden");
    #endif
}

- (void)hideAllControlsExceptStartupProgress {
    #if TARGET_OS_IOS || TARGET_OS_TV
    NSLog(@"📱 [HIDE-SELECTIVE] Hiding all controls except startup progress window");
    
    // Hide player controls
    [self hidePlayerControls];
    
    // Hide settings panel
    if (_settingsScrollViewiOS && !_settingsScrollViewiOS.hidden) {
        _settingsScrollViewiOS.hidden = YES;
        NSLog(@"📱 [HIDE-SELECTIVE] Hidden settings panel");
    }
    
    // Hide theme settings scroll view
    if (_themeSettingsScrollView && !_themeSettingsScrollView.hidden) {
        _themeSettingsScrollView.hidden = YES;
        NSLog(@"📱 [HIDE-SELECTIVE] Hidden theme settings panel");
    }
    
    // Hide subtitle settings scroll view
    if (_subtitleSettingsScrollView && !_subtitleSettingsScrollView.hidden) {
        _subtitleSettingsScrollView.hidden = YES;
        NSLog(@"📱 [HIDE-SELECTIVE] Hidden subtitle settings panel");
    }
    
    // Hide loading panel ONLY if manual loading is not in progress
    if (_loadingPaneliOS && !_loadingPaneliOS.hidden && !self.isManualLoadingInProgress) {
        _loadingPaneliOS.hidden = YES;
        NSLog(@"📱 [HIDE-SELECTIVE] Hidden loading panel");
    } else if (_loadingPaneliOS && !_loadingPaneliOS.hidden && self.isManualLoadingInProgress) {
        NSLog(@"📱 [HIDE-SELECTIVE] Keeping loading panel visible - manual loading in progress");
    }
    
    // Keep startup progress window visible - DO NOT HIDE IT
    if (_startupProgressWindow && !_startupProgressWindow.hidden) {
        NSLog(@"📱 [HIDE-SELECTIVE] Keeping startup progress window visible during startup");
    }
    
    [self setNeedsDisplay];
    NSLog(@"📱 [HIDE-SELECTIVE] All controls hidden except startup progress");
    #endif
}

- (void)togglePlayerControls {
    #if TARGET_OS_IOS || TARGET_OS_TV
    _playerControlsVisible = !_playerControlsVisible;
    [self setNeedsDisplay];
    NSLog(@"📱 [PLAYER-CONTROLS] Toggled to: %@", _playerControlsVisible ? @"visible" : @"hidden");
    #endif
}

- (void)drawPlayerControlsOnRect:(CGRect)rect {
    // UNIFIED PLAYER CONTROLS: Use the same logic as Mac but with platform-specific drawing
    
    // Don't draw controls if we don't have a player
    if (!self.player) {
        return;
    }
    
    // Don't draw controls if not visible
    if (!_playerControlsVisible) {
        return;
    }
    
    // Don't draw controls if the menu is visible (Mac mode consistency)
    if (_isChannelListVisible) {
        return;
    }
    
    #if TARGET_OS_IOS || TARGET_OS_TV
    [self drawUnifiedPlayerControlsiOS:rect];
    #else
    // This would be handled by the Mac implementation in VLCOverlayView+PlayerControls.m
    #endif
}

#pragma mark - Unified Player Controls Implementation (iOS/tvOS)

- (void)drawUnifiedPlayerControlsiOS:(CGRect)rect {
    // TRUE MAC LOGIC: Reuse the actual Mac player controls implementation
    
    // Calculate control area exactly like Mac (140px height)
    CGFloat controlHeight = 140; // Same as Mac
    CGFloat margin = 20;
    CGFloat controlsWidth = MIN(600, rect.size.width - 2 * margin); // Max width of 600pt or screen width
    CGFloat controlsX = (rect.size.width - controlsWidth) / 2; // Center horizontally
    CGRect controlsRect = CGRectMake(controlsX, rect.size.height - controlHeight - margin, 
                                   controlsWidth, controlHeight);
    
    // Store the control bar rect for click handling (exactly like Mac)
    objc_setAssociatedObject(self, @selector(playerControlsRect), [NSValue valueWithCGRect:controlsRect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Use the exact Mac glassmorphism drawing
    [self drawGlassmorphismPaneliOS:controlsRect opacity:0.9 cornerRadius:16];
    
    // Get current channel and program info (using exact Mac logic)
    VLCChannel *currentChannel = nil;
    VLCProgram *currentProgram = nil;
    [self getMacStyleChannelAndProgram:&currentChannel program:&currentProgram];
    
    // Check if we're playing timeshift content (Mac logic)
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    
    // Logo area exactly like Mac
    CGFloat logoSize = 80; // Same as Mac
    CGFloat logoMargin = 20; // Same as Mac
    CGRect logoRect = CGRectMake(
        controlsRect.origin.x + logoMargin,
        controlsRect.origin.y + (controlHeight - logoSize) / 2,
        logoSize,
        logoSize
    );
    
    [self drawMacStyleChannelLogoiOS:logoRect channel:currentChannel];
    
    // Content area exactly like Mac
    CGFloat contentStartX = logoRect.origin.x + logoSize + logoMargin;
    CGFloat contentWidth = controlsRect.size.width - (contentStartX - controlsRect.origin.x) - logoMargin;
    
    // Calculate progress using EXACT Mac logic
    float progress = 0.0;
    NSString *currentTimeStr = @"--:--";
    NSString *totalTimeStr = @"--:--";
    NSString *programStatusStr = @"";
    NSString *programTimeRange = @"";
    
    if (isTimeshiftPlaying) {
        // Use ACTUAL Mac timeshift calculation method
        [self calculateTimeshiftProgress:&progress 
                         currentTimeStr:&currentTimeStr 
                           totalTimeStr:&totalTimeStr 
                        programStatusStr:&programStatusStr 
                         programTimeRange:&programTimeRange 
                           currentChannel:currentChannel 
                           currentProgram:currentProgram];
    } else {
        // Use Mac standard progress logic (extracted from Mac method)
        [self calculateMacStandardProgress:&progress 
                           currentTimeStr:&currentTimeStr 
                             totalTimeStr:&totalTimeStr 
                          programStatusStr:&programStatusStr 
                           programTimeRange:&programTimeRange 
                             currentChannel:currentChannel 
                             currentProgram:currentProgram];
    }
    
    // Draw progress bar exactly like Mac - FIXED POSITIONING
    CGFloat progressBarY = controlsRect.origin.y + controlHeight * 0.55; // Adjusted to prevent overlap
    CGFloat progressBarHeight = 6; // Slightly thinner for mobile
    CGRect progressBgRect = CGRectMake(contentStartX, progressBarY, contentWidth, progressBarHeight);
    
    // Store progress bar rect exactly like Mac
    objc_setAssociatedObject(self, @selector(progressBarRect), [NSValue valueWithCGRect:progressBgRect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    [self drawMacStyleProgressBariOS:progressBgRect progress:progress];
    
    // Draw Mac-style subtitle and audio buttons
    [self drawMacStyleControlButtonsiOS:controlsRect 
                           contentStart:contentStartX 
                           contentWidth:contentWidth];
    
    // Draw channel/program info exactly like Mac
    [self drawMacStyleChannelInfoiOS:controlsRect 
                        contentStart:contentStartX 
                        contentWidth:contentWidth 
                      currentChannel:currentChannel 
                      currentProgram:currentProgram 
                        currentTimeStr:currentTimeStr 
                          totalTimeStr:totalTimeStr 
                      programStatusStr:programStatusStr 
                       programTimeRange:programTimeRange];
    
    //NSLog(@"📱 [TRUE-MAC-CONTROLS] Drew actual Mac-style player controls");
}

- (BOOL)handlePlayerControlsTap:(CGPoint)tapPoint {
    #if TARGET_OS_IOS || TARGET_OS_TV
    if (!self.player || !_playerControlsVisible) {
        return NO;
    }
    
    // Reset auto-hide timer on any player controls interaction
    [self resetAutoHideTimer];
    
    // Use unified control layout (same as drawing)
    CGFloat controlHeight = 120; // Increased like Mac
    CGFloat margin = 20;
    CGFloat controlsWidth = MIN(600, self.bounds.size.width - 2 * margin); // Max width of 600pt or screen width
    CGFloat controlsX = (self.bounds.size.width - controlsWidth) / 2; // Center horizontally
    CGRect controlsRect = CGRectMake(controlsX, self.bounds.size.height - controlHeight - margin, 
                                   controlsWidth, controlHeight);
    
    // Check if tap is within controls area
    if (!CGRectContainsPoint(controlsRect, tapPoint)) {
        return NO; // Tap not on controls
    }
    
    // Calculate play/pause button area (repositioned to right side like unified layout)
    CGFloat buttonSize = 40;
    CGRect playButtonRect = CGRectMake(controlsRect.origin.x + controlsRect.size.width - buttonSize - 15, 
                                     controlsRect.origin.y + (controlHeight - buttonSize) / 2,
                                     buttonSize, buttonSize);
    
    if (CGRectContainsPoint(playButtonRect, tapPoint)) {
        // Play/pause button tapped
        if (self.player.state == VLCMediaPlayerStatePlaying) {
            [self.player pause];
            NSLog(@"📱 [UNIFIED-CONTROLS] Paused playback");
        } else {
            [self.player play];
            NSLog(@"📱 [UNIFIED-CONTROLS] Started playback");
        }
        [self setNeedsDisplay];
        return YES;
    }
    
    // Calculate progress bar area for seeking (using unified layout positions)
    CGFloat logoSize = 60;
    CGFloat logoMargin = 15;
    CGFloat contentStartX = controlsRect.origin.x + logoMargin + logoSize + logoMargin;
    CGFloat contentWidth = controlsRect.size.width - (contentStartX - controlsRect.origin.x) - logoMargin;
    CGFloat progressBarY = controlsRect.origin.y + controlHeight * 0.4;
    CGFloat progressBarHeight = 6;
    CGRect progressRect = CGRectMake(contentStartX, progressBarY, contentWidth, progressBarHeight);
    
    // Expand touch area for progress bar
    CGRect expandedProgressRect = CGRectInset(progressRect, -10, -20);
    
    if (CGRectContainsPoint(expandedProgressRect, tapPoint)) {
        // Progress bar tapped - seek to position
        CGFloat relativePosition = (tapPoint.x - progressRect.origin.x) / contentWidth;
        relativePosition = MAX(0.0, MIN(1.0, relativePosition));
        
        BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
        
        if (isTimeshiftPlaying) {
            // For timeshift content, use Mac-style seeking logic
            NSLog(@"📱 [UNIFIED-CONTROLS] Timeshift seeking to position: %.2f", relativePosition);
            // This would need the full Mac timeshift seeking implementation
            // For now, just basic seeking
            if (self.player.media && self.player.media.length.intValue > 0) {
                self.player.position = relativePosition;
            }
        } else if (self.player.media && self.player.media.length.intValue > 0) {
            // Standard seeking for movies/media with known duration
            self.player.position = relativePosition;
            NSLog(@"📱 [UNIFIED-CONTROLS] Standard seeking to position: %.2f", relativePosition);
        }
        
        [self setNeedsDisplay];
        return YES;
    }
    
    return YES; // Tap was within controls area, even if not on specific control
    #else
    return NO;
    #endif
}

#pragma mark - Helper Methods for Unified Player Controls

- (void)drawGlassmorphismPaneliOS:(CGRect)rect opacity:(CGFloat)opacity cornerRadius:(CGFloat)cornerRadius {
    // EXACT Mac glassmorphism implementation for iOS/tvOS
    UIColor *bgColor = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:opacity];
    [bgColor setFill];
    UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:cornerRadius];
    [bgPath fill];
    
    // Add the exact same border as Mac
    UIColor *borderColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.3 alpha:0.6];
    [borderColor setStroke];
    bgPath.lineWidth = 1.0;
    [bgPath stroke];
}

- (void)getMacStyleChannelAndProgram:(VLCChannel **)currentChannel program:(VLCProgram **)currentProgram {
    // Use the same sophisticated logic as Mac to get current channel and program
    
    // PRIORITY 1: Check if we have a temporary current channel (e.g., from search results)
    if (self.tmpCurrentChannel) {
        *currentChannel = self.tmpCurrentChannel;
        // For movies from search results, try to get current program if available
        if ((*currentChannel).programs && (*currentChannel).programs.count > 0) {
            *currentProgram = [*currentChannel currentProgramWithTimeOffset:self.epgTimeOffsetHours];
        }
        return;
    }
    
    // PRIORITY 2: For timeshift content, get the REAL-TIME currently playing program
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    if (isTimeshiftPlaying) {
        NSLog(@"📱 [TIMESHIFT-CHANNEL] Getting real-time timeshift program info");
        
        // Get the actual program being played at current timeshift position
        *currentProgram = [self getCurrentTimeshiftPlayingProgram];
        
        // Get channel info from cached info or find the original channel
        NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
        NSString *channelName = [cachedInfo objectForKey:@"channelName"];
        
        if (channelName) {
            // Extract original channel name (remove timeshift suffix)
            NSString *originalChannelName = channelName;
            if ([channelName containsString:@" (Timeshift:"]) {
                NSRange timeshiftRange = [channelName rangeOfString:@" (Timeshift:"];
                if (timeshiftRange.location != NSNotFound) {
                    originalChannelName = [channelName substringToIndex:timeshiftRange.location];
                }
            }
            
            // Find the actual channel object by name
            if (_channels && _channels.count > 0) {
                for (VLCChannel *channel in _channels) {
                    if ([channel isKindOfClass:[VLCChannel class]] && 
                        [channel.name isEqualToString:originalChannelName]) {
                        *currentChannel = channel;
                        NSLog(@"📱 [TIMESHIFT-CHANNEL] Found original channel: %@", channel.name);
                        break;
                    }
                }
            }
            
            // If we didn't find the original channel, create a temporary one
            if (!*currentChannel && cachedInfo) {
                *currentChannel = [[VLCChannel alloc] init];
                (*currentChannel).name = originalChannelName;
                (*currentChannel).url = [cachedInfo objectForKey:@"url"];
                (*currentChannel).category = [cachedInfo objectForKey:@"category"];
                (*currentChannel).logo = [cachedInfo objectForKey:@"logoUrl"];
                NSLog(@"📱 [TIMESHIFT-CHANNEL] Created temporary channel: %@", originalChannelName);
            }
        }
        
        NSLog(@"📱 [TIMESHIFT-CHANNEL] Final result - Channel: %@, Program: %@", 
              (*currentChannel) ? (*currentChannel).name : @"nil", 
              (*currentProgram) ? (*currentProgram).title : @"nil");
        return;
    }
    
    // PRIORITY 3: Use selection-based approach with direct EPG calculation
    if (_selectedChannelIndex >= 0 && _selectedChannelIndex < [self getChannelsForCurrentGroup].count) {
        NSArray *channels = [self getChannelsForCurrentGroup];
        if (channels && _selectedChannelIndex < channels.count) {
            *currentChannel = [channels objectAtIndex:_selectedChannelIndex];
            
            // Get current program for this channel based on current time
            if ((*currentChannel).programs && (*currentChannel).programs.count > 0) {
                *currentProgram = [*currentChannel currentProgramWithTimeOffset:self.epgTimeOffsetHours];
            }
        }
    }
    
    // Final fallback: Try cached content info
    if (!*currentChannel) {
        NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
        if (cachedInfo) {
            *currentChannel = [[VLCChannel alloc] init];
            (*currentChannel).name = [cachedInfo objectForKey:@"channelName"];
            (*currentChannel).url = [cachedInfo objectForKey:@"url"];
            (*currentChannel).category = [cachedInfo objectForKey:@"category"];
            (*currentChannel).logo = [cachedInfo objectForKey:@"logoUrl"];
            
            NSDictionary *programInfo = [cachedInfo objectForKey:@"currentProgram"];
            if (programInfo) {
                *currentProgram = [[VLCProgram alloc] init];
                (*currentProgram).title = [programInfo objectForKey:@"title"];
                (*currentProgram).programDescription = [programInfo objectForKey:@"description"];
                (*currentProgram).startTime = [programInfo objectForKey:@"startTime"];
                (*currentProgram).endTime = [programInfo objectForKey:@"endTime"];
            }
        }
    }
}

- (void)drawMacStyleChannelLogoiOS:(CGRect)logoRect channel:(VLCChannel *)currentChannel {
    // Draw logo background
    UIColor *logoBgColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.8];
    [logoBgColor setFill];
    UIBezierPath *logoPath = [UIBezierPath bezierPathWithRoundedRect:logoRect cornerRadius:8];
    [logoPath fill];
    
    // Try to draw the channel logo (using same logic as Mac)
    UIImage *channelLogo = nil;
    
    if (currentChannel && currentChannel.cachedPosterImage) {
        channelLogo = currentChannel.cachedPosterImage;
    } else if (currentChannel && currentChannel.logo && [currentChannel.logo length] > 0) {
        // Load logo asynchronously (same as Mac)
        static NSMutableSet *loadingLogos = nil;
        if (!loadingLogos) {
            loadingLogos = [[NSMutableSet alloc] init];
        }
        
        if (![loadingLogos containsObject:currentChannel.logo]) {
            [loadingLogos addObject:currentChannel.logo];
            
            NSURL *logoURL = [NSURL URLWithString:currentChannel.logo];
            if (logoURL) {
                NSURLSessionDataTask *logoTask = [[NSURLSession sharedSession] dataTaskWithURL:logoURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [loadingLogos removeObject:currentChannel.logo];
                        
                        if (data && !error) {
                            UIImage *downloadedLogo = [[UIImage alloc] initWithData:data];
                            if (downloadedLogo) {
                                currentChannel.cachedPosterImage = downloadedLogo;
                                [self setNeedsDisplay];
                            }
                        }
                    });
                }];
                [logoTask resume];
            }
        }
    }
    
    if (channelLogo) {
        // Draw with proper aspect ratio
        CGSize imageSize = channelLogo.size;
        CGRect logoDrawRect = CGRectInset(logoRect, 4, 4);
        CGFloat availableWidth = logoDrawRect.size.width;
        CGFloat availableHeight = logoDrawRect.size.height;
        
        CGFloat imageAspectRatio = imageSize.width / imageSize.height;
        CGFloat availableAspectRatio = availableWidth / availableHeight;
        
        CGSize scaledSize;
        if (imageAspectRatio > availableAspectRatio) {
            scaledSize.width = availableWidth;
            scaledSize.height = availableWidth / imageAspectRatio;
        } else {
            scaledSize.height = availableHeight;
            scaledSize.width = availableHeight * imageAspectRatio;
        }
        
        CGRect centeredRect = CGRectMake(
            logoDrawRect.origin.x + (availableWidth - scaledSize.width) / 2,
            logoDrawRect.origin.y + (availableHeight - scaledSize.height) / 2,
            scaledSize.width,
            scaledSize.height
        );
        
        [channelLogo drawInRect:centeredRect];
    } else {
        // Draw placeholder
        NSString *placeholder = @"📺";
        if (currentChannel && currentChannel.name && [currentChannel.name length] > 0) {
            placeholder = [[currentChannel.name substringToIndex:1] uppercaseString];
        }
        
        NSDictionary *placeholderAttrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:24],
            NSForegroundColorAttributeName: [UIColor lightGrayColor]
        };
        
        CGSize textSize = [placeholder sizeWithAttributes:placeholderAttrs];
        CGRect placeholderRect = CGRectMake(
            logoRect.origin.x + (logoRect.size.width - textSize.width) / 2,
            logoRect.origin.y + (logoRect.size.height - textSize.height) / 2,
            textSize.width,
            textSize.height
        );
        [placeholder drawInRect:placeholderRect withAttributes:placeholderAttrs];
    }
}

- (void)calculateStandardProgressiOS:(float *)progress 
                     currentTimeStr:(NSString **)currentTimeStr 
                       totalTimeStr:(NSString **)totalTimeStr 
                    programStatusStr:(NSString **)programStatusStr 
                     programTimeRange:(NSString **)programTimeRange 
                       currentChannel:(VLCChannel *)currentChannel 
                       currentProgram:(VLCProgram *)currentProgram {
    // Standard progress calculation for live TV or movies
    
    if (self.player.media && self.player.media.length.intValue > 0) {
        // For media with known duration (movies)
        *progress = self.player.position;
        VLCTime *currentTime = self.player.time;
        VLCTime *totalTime = self.player.media.length;
        *currentTimeStr = [currentTime stringValue];
        *totalTimeStr = [totalTime stringValue];
        
        if (currentChannel) {
            *programStatusStr = currentChannel.name ?: @"Playing";
        } else {
            *programStatusStr = @"Playing";
        }
        
        if (currentProgram) {
            NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
            [timeFormatter setDateFormat:@"HH:mm"];
            NSString *startTime = [timeFormatter stringFromDate:currentProgram.startTime];
            NSString *endTime = [timeFormatter stringFromDate:currentProgram.endTime];
            *programTimeRange = [NSString stringWithFormat:@"%@ - %@", startTime, endTime];
        } else {
            *programTimeRange = @"";
        }
    } else {
        // For live TV or unknown duration
        *progress = 0.0;
        *currentTimeStr = @"LIVE";
        *totalTimeStr = @"∞";
        
        if (currentChannel) {
            *programStatusStr = currentChannel.name ?: @"Live TV";
        } else {
            *programStatusStr = @"Live TV";
        }
        
        if (currentProgram) {
            NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
            [timeFormatter setDateFormat:@"HH:mm"];
            NSString *startTime = [timeFormatter stringFromDate:currentProgram.startTime];
            NSString *endTime = [timeFormatter stringFromDate:currentProgram.endTime];
            *programTimeRange = [NSString stringWithFormat:@"%@ - %@", startTime, endTime];
        } else {
            *programTimeRange = @"";
        }
    }
}

- (void)calculateTimeshiftProgressiOS:(float *)progress 
                      currentTimeStr:(NSString **)currentTimeStr 
                        totalTimeStr:(NSString **)totalTimeStr 
                     programStatusStr:(NSString **)programStatusStr 
                      programTimeRange:(NSString **)programTimeRange 
                        currentChannel:(VLCChannel *)currentChannel 
                        currentProgram:(VLCProgram *)currentProgram {
    // Simplified version of Mac timeshift calculation for iOS
    VLCTime *currentTime = [self.player time];
    if (!currentTime) {
        *progress = 0.5;
        *currentTimeStr = @"--:--";
        *totalTimeStr = @"2:00:00";
        *programStatusStr = @"Timeshift - Loading...";
        *programTimeRange = @"";
        return;
    }
    
    // Extract timeshift start time from URL
    NSString *currentUrl = [self.player.media.url absoluteString];
    NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
    
    if (timeshiftStartTime) {
        // Apply EPG offset adjustment
        NSTimeInterval epgAdjustmentForDisplay = self.epgTimeOffsetHours * 3600.0;
        timeshiftStartTime = [timeshiftStartTime dateByAddingTimeInterval:epgAdjustmentForDisplay];
        
        // Calculate current playback position
        NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
        NSDate *actualPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
        
        // Create 2-hour sliding window centered around current play time
        NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
        [timeFormatter setDateFormat:@"HH:mm:ss"];
        [timeFormatter setTimeZone:[NSTimeZone localTimeZone]];
        
        NSDate *centeredStartTime = [actualPlayTime dateByAddingTimeInterval:-3600]; // -1 hour
        NSDate *centeredEndTime = [actualPlayTime dateByAddingTimeInterval:3600];    // +1 hour
        
        // Apply EPG offset for display
        NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
        NSDate *displayStartTime = [centeredStartTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSDate *displayEndTime = [centeredEndTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSDate *displayCurrentPlayTime = [actualPlayTime dateByAddingTimeInterval:displayOffsetSeconds];
        
        // Calculate progress within the 2-hour window
        NSTimeInterval windowDuration = [centeredEndTime timeIntervalSinceDate:centeredStartTime];
        NSTimeInterval playTimeOffset = [actualPlayTime timeIntervalSinceDate:centeredStartTime];
        
        if (windowDuration > 0) {
            *progress = playTimeOffset / windowDuration;
            *progress = MIN(1.0, MAX(0.0, *progress));
        } else {
            *progress = 0.5;
        }
        
        *currentTimeStr = [timeFormatter stringFromDate:displayStartTime];
        *totalTimeStr = [timeFormatter stringFromDate:displayEndTime];
        
        // Calculate time behind live
        NSDate *currentRealTime = [NSDate date];
        NSTimeInterval timeBehindLive = [currentRealTime timeIntervalSinceDate:actualPlayTime];
        
        NSString *currentPlayTimeStr = [timeFormatter stringFromDate:displayCurrentPlayTime];
        int behindMins = (int)(timeBehindLive / 60);
        
        if (behindMins < 60) {
            *programStatusStr = [NSString stringWithFormat:@"Timeshift - Playing: %@ (%d min behind)", currentPlayTimeStr, behindMins];
        } else {
            int behindHours = behindMins / 60;
            int remainingMins = behindMins % 60;
            *programStatusStr = [NSString stringWithFormat:@"Timeshift - Playing: %@ (%dh %dm behind)", currentPlayTimeStr, behindHours, remainingMins];
        }
        
        *programTimeRange = @"";
    } else {
        // Fallback
        *progress = 0.5;
        *currentTimeStr = @"--:--";
        *totalTimeStr = @"--:--";
        *programStatusStr = @"Timeshift";
        *programTimeRange = @"";
    }
}

- (void)drawProgressBariOS:(CGRect)progressRect progress:(float)progress {
    // Draw progress bar background
    UIColor *progressBgColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.3 alpha:0.8];
    [progressBgColor setFill];
    UIBezierPath *progressBgPath = [UIBezierPath bezierPathWithRoundedRect:progressRect cornerRadius:3];
    [progressBgPath fill];
    
    // Draw progress fill
    if (progress > 0) {
        CGFloat fillWidth = progressRect.size.width * progress;
        CGRect fillRect = CGRectMake(progressRect.origin.x, progressRect.origin.y, fillWidth, progressRect.size.height);
        
        UIColor *progressColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        [progressColor setFill];
        UIBezierPath *progressFillPath = [UIBezierPath bezierPathWithRoundedRect:fillRect cornerRadius:3];
        [progressFillPath fill];
    }
}

- (void)drawChannelInfoiOS:(CGRect)controlsRect 
              contentStart:(CGFloat)contentStartX 
              contentWidth:(CGFloat)contentWidth 
            currentChannel:(VLCChannel *)currentChannel 
            currentProgram:(VLCProgram *)currentProgram 
              currentTimeStr:(NSString *)currentTimeStr 
                totalTimeStr:(NSString *)totalTimeStr 
            programStatusStr:(NSString *)programStatusStr {
    
    // Draw channel name at top
    if (currentChannel && currentChannel.name) {
        NSDictionary *channelAttrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:14],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        
        CGRect channelRect = CGRectMake(contentStartX, controlsRect.origin.y + 5, contentWidth, 18);
        [currentChannel.name drawInRect:channelRect withAttributes:channelAttrs];
    }
    
    // Draw program title
    if (currentProgram && currentProgram.title) {
        NSDictionary *programAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.9 green:0.9 blue:0.9 alpha:1.0]
        };
        
        CGRect programRect = CGRectMake(contentStartX, controlsRect.origin.y + 25, contentWidth, 16);
        [currentProgram.title drawInRect:programRect withAttributes:programAttrs];
    }
    
    // Draw time info below progress bar
    NSString *timeText = [NSString stringWithFormat:@"%@ / %@", currentTimeStr, totalTimeStr];
    NSDictionary *timeAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11],
        NSForegroundColorAttributeName: [UIColor colorWithRed:0.8 green:0.8 blue:0.8 alpha:1.0]
    };
    
    CGRect timeRect = CGRectMake(contentStartX, controlsRect.origin.y + controlsRect.size.height - 35, contentWidth, 14);
    [timeText drawInRect:timeRect withAttributes:timeAttrs];
    
    // Draw status info at bottom
    if (programStatusStr && [programStatusStr length] > 0) {
        NSDictionary *statusAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.7 green:0.7 blue:0.7 alpha:1.0]
        };
        
        CGRect statusRect = CGRectMake(contentStartX, controlsRect.origin.y + controlsRect.size.height - 20, contentWidth, 12);
        [programStatusStr drawInRect:statusRect withAttributes:statusAttrs];
    }
}

- (void)drawPlayPauseButtoniOS:(CGRect)controlsRect {
    // Position play/pause button on the right side
    CGFloat buttonSize = 40;
    CGRect playButtonRect = CGRectMake(controlsRect.origin.x + controlsRect.size.width - buttonSize - 15, 
                                     controlsRect.origin.y + (controlsRect.size.height - buttonSize) / 2,
                                     buttonSize, buttonSize);
    
    // Determine if playing or paused
    BOOL isPlaying = (self.player.state == VLCMediaPlayerStatePlaying);
    NSString *buttonSymbol = isPlaying ? @"⏸" : @"▶️";
    
    // Draw button background
    UIColor *buttonBgColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.9];
    [buttonBgColor setFill];
    UIBezierPath *buttonPath = [UIBezierPath bezierPathWithRoundedRect:playButtonRect cornerRadius:20];
    [buttonPath fill];
    
    // Add subtle border
    UIColor *buttonBorderColor = [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.8];
    [buttonBorderColor setStroke];
    buttonPath.lineWidth = 1.0;
    [buttonPath stroke];
    
    // Draw play/pause symbol
    NSDictionary *symbolAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:18],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGSize symbolSize = [buttonSymbol sizeWithAttributes:symbolAttrs];
    CGRect symbolRect = CGRectMake(
        playButtonRect.origin.x + (buttonSize - symbolSize.width) / 2,
        playButtonRect.origin.y + (buttonSize - symbolSize.height) / 2,
        symbolSize.width,
        symbolSize.height
    );
    [buttonSymbol drawInRect:symbolRect withAttributes:symbolAttrs];
}

// Add Mac-style methods that the true implementation needs

- (void)calculateMacStandardProgress:(float *)progress 
                     currentTimeStr:(NSString **)currentTimeStr 
                       totalTimeStr:(NSString **)totalTimeStr 
                    programStatusStr:(NSString **)programStatusStr 
                     programTimeRange:(NSString **)programTimeRange 
                       currentChannel:(VLCChannel *)currentChannel 
                       currentProgram:(VLCProgram *)currentProgram {
    // EXACT Mac standard progress logic (extracted from Mac implementation)
    
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    if (!isTimeshiftPlaying && currentProgram && currentProgram.startTime && currentProgram.endTime) {
        // Mac EPG-based progress calculation
        NSDate *now = [NSDate date];
        NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600.0;
        NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
        
        NSTimeInterval programDuration = [currentProgram.endTime timeIntervalSinceDate:currentProgram.startTime];
        NSTimeInterval elapsed = [adjustedNow timeIntervalSinceDate:currentProgram.startTime];
        NSTimeInterval remaining = [currentProgram.endTime timeIntervalSinceDate:adjustedNow];
        
        if (programDuration > 0) {
            if (elapsed < 0) {
                *progress = 0.0;
            } else if (remaining < 0) {
                *progress = 1.0;
            } else {
                *progress = elapsed / programDuration;
                *progress = MIN(1.0, MAX(0.0, *progress));
            }
        } else {
            *progress = 0.0;
        }
        
        // Mac time formatting
        NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
        [timeFormatter setDateFormat:@"HH:mm:ss"];
        [timeFormatter setTimeZone:[NSTimeZone localTimeZone]];
        
        NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
        NSDate *adjustedStartTime = [currentProgram.startTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSDate *adjustedEndTime = [currentProgram.endTime dateByAddingTimeInterval:displayOffsetSeconds];
        
        *currentTimeStr = [timeFormatter stringFromDate:adjustedStartTime];
        *totalTimeStr = [timeFormatter stringFromDate:adjustedEndTime];
        
        // Mac status calculation
        if (elapsed < 0) {
            int minutesUntilStart = (int)(ABS(elapsed) / 60);
            if (minutesUntilStart > 60) {
                int hours = minutesUntilStart / 60;
                int mins = minutesUntilStart % 60;
                *programStatusStr = [NSString stringWithFormat:@"Starts in %dh %dm", hours, mins];
            } else {
                *programStatusStr = [NSString stringWithFormat:@"Starts in %d min", minutesUntilStart];
            }
        } else if (remaining > 0) {
            int remainingMins = (int)(remaining / 60);
            if (remainingMins > 60) {
                int hours = remainingMins / 60;
                int mins = remainingMins % 60;
                *programStatusStr = [NSString stringWithFormat:@"%dh %dm remaining", hours, mins];
            } else {
                *programStatusStr = [NSString stringWithFormat:@"%d min remaining", remainingMins];
            }
        } else {
            int minutesSinceEnd = (int)(ABS(remaining) / 60);
            *programStatusStr = [NSString stringWithFormat:@"Ended %d min ago", minutesSinceEnd];
        }
        
        *programTimeRange = [NSString stringWithFormat:@"%@ - %@", *currentTimeStr, *totalTimeStr];
    } else {
        // Fall back to video time (Mac logic)
        VLCTime *currentTime = [self.player time];
        VLCTime *totalTime = [self.player.media length];
        
        if (totalTime && [totalTime intValue] > 0 && currentTime) {
            float currentMs = (float)[currentTime intValue];
            float totalMs = (float)[totalTime intValue];
            *progress = currentMs / totalMs;
            *progress = MIN(1.0, MAX(0.0, *progress));
        }
        
        if (currentTime) {
            int currentSecs = [currentTime intValue] / 1000;
            *currentTimeStr = [NSString stringWithFormat:@"%d:%02d", currentSecs / 60, currentSecs % 60];
        }
        
        if (totalTime && [totalTime intValue] > 0) {
            int totalSecs = [totalTime intValue] / 1000;
            *totalTimeStr = [NSString stringWithFormat:@"%d:%02d", totalSecs / 60, totalSecs % 60];
        }
        
        *programStatusStr = currentChannel ? currentChannel.name : @"Playing";
        *programTimeRange = @"";
    }
}

- (void)drawMacStyleProgressBariOS:(CGRect)progressRect progress:(float)progress {
    // EXACT Mac progress bar drawing with tvOS focus support
    BOOL isProgressFocused = (_playerControlsNavigationMode && _selectedPlayerControl == 0);
    
    UIColor *progressBgColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.3 alpha:0.8];
    [progressBgColor setFill];
    UIBezierPath *progressBgPath = [UIBezierPath bezierPathWithRoundedRect:progressRect cornerRadius:4];
    [progressBgPath fill];
    
    // Add focus border for progress bar
    if (isProgressFocused) {
        [[UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0] setStroke];
        progressBgPath.lineWidth = 3.0;
        [progressBgPath stroke];
    }
    
    // Mac-style progress fill
    if (progress > 0) {
        CGFloat fillWidth = progressRect.size.width * progress;
        CGRect fillRect = CGRectMake(progressRect.origin.x, progressRect.origin.y, fillWidth, progressRect.size.height);
        
        UIColor *progressColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
        [progressColor setFill];
        UIBezierPath *progressFillPath = [UIBezierPath bezierPathWithRoundedRect:fillRect cornerRadius:4];
        [progressFillPath fill];
    }
    
    // Draw hover marker if hovering (Mac feature!) - only for seekable content
    if ([self isHoveringProgressBar]) {
        // Check if content is seekable before showing hover indicator
        BOOL canSeek = NO;
        
        // Check if it's movie content (always seekable with normal VLC seeking)
        BOOL isMovieContent = (_selectedCategoryIndex == CATEGORY_MOVIES) ||
                             (_selectedCategoryIndex == CATEGORY_SERIES) ||
                             (_selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]);
        
        // Check if it's timeshift content (needs URL-based seeking)
        BOOL isTimeshiftContent = [self isCurrentlyPlayingTimeshift];
        
        // Check if current channel supports timeshift
        VLCChannel *currentChannel = [self getCurrentChannel];
        BOOL channelSupportsTimeshift = (currentChannel && currentChannel.supportsCatchup);
        
        canSeek = isMovieContent || isTimeshiftContent || channelSupportsTimeshift;
        
        // Only draw hover indicator if content is seekable
        if (canSeek) {
        CGPoint hoverPoint = [self progressBarHoverPoint];
        CGFloat relativeX = hoverPoint.x - progressRect.origin.x;
        relativeX = MAX(0, MIN(progressRect.size.width, relativeX));
        
        // Draw vertical marker line
        CGRect markerRect = CGRectMake(progressRect.origin.x + relativeX - 1, 
                                     progressRect.origin.y - 4, 
                                     2, 
                                     progressRect.size.height + 8);
        
        UIColor *markerColor = [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.9];
        [markerColor setFill];
        UIRectFill(markerRect);
        }
    }
}

- (void)drawMacStyleControlButtonsiOS:(CGRect)controlsRect 
                         contentStart:(CGFloat)contentStartX 
                         contentWidth:(CGFloat)contentWidth {
    // EXACT Mac subtitle and audio buttons implementation - FIXED POSITIONING
    CGFloat buttonHeight = 28; // Slightly smaller for mobile
    CGFloat buttonSpacing = 8;
    CGFloat buttonPadding = 12; // Reduced padding to prevent overlap
    CGFloat buttonY = controlsRect.origin.y + 15; // Higher position to avoid overlap
    
    // Get current subtitle and audio states (Mac logic)
    BOOL hasSubtitles = NO;
    BOOL hasAudio = NO;
    NSString *currentSubtitleName = nil;
    NSString *currentAudioName = nil;
    
    if (self.player) {
        // Get current subtitle track
        NSArray *textTracks = [self.player textTracks];
        NSLog(@"📱 [TRACK-TIMING-DEBUG] Player controls drawing - Text tracks: %lu", (unsigned long)textTracks.count);
        for (VLCMediaPlayerTrack *track in textTracks) {
            NSLog(@"📱 [TRACK-TIMING-DEBUG] Text track: %@ (selected: %@)", track.trackName, track.selected ? @"YES" : @"NO");
            if (track.selected) {
                hasSubtitles = YES;
                currentSubtitleName = track.trackName;
                if ([currentSubtitleName isEqualToString:@"Disable"]) {
                    currentSubtitleName = nil;
                    hasSubtitles = NO;
                }
                break;
            }
        }
        
        // Get current audio track
        NSArray *audioTracks = [self.player audioTracks];
        NSLog(@"📱 [TRACK-TIMING-DEBUG] Player controls drawing - Audio tracks: %lu", (unsigned long)audioTracks.count);
        for (VLCMediaPlayerTrack *track in audioTracks) {
            NSLog(@"📱 [TRACK-TIMING-DEBUG] Audio track: %@ (selected: %@)", track.trackName, track.selected ? @"YES" : @"NO");
            if (track.selected) {
                hasAudio = YES;
                currentAudioName = track.trackName;
                break;
            }
        }
        hasAudio = (audioTracks.count > 0);
    } else {
        NSLog(@"📱 [TRACK-TIMING-DEBUG] No player available during controls drawing");
    }
    
    // Calculate button text and sizes (Mac logic) - ADJUSTED FOR MOBILE
    NSString *subtitleButtonText = hasSubtitles && currentSubtitleName ? currentSubtitleName : @"CC";
    if (hasSubtitles && currentSubtitleName && [currentSubtitleName length] > 15) { // Shorter for mobile
        subtitleButtonText = [[currentSubtitleName substringToIndex:12] stringByAppendingString:@"..."];
    }
    
    NSString *audioButtonText = hasAudio && currentAudioName ? currentAudioName : @"♪";
    if (hasAudio && currentAudioName && [currentAudioName length] > 15) { // Shorter for mobile
        audioButtonText = [[currentAudioName substringToIndex:12] stringByAppendingString:@"..."];
    }
    
    NSDictionary *buttonTextAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11], // Smaller font for mobile
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGSize subtitleTextSize = [subtitleButtonText sizeWithAttributes:buttonTextAttrs];
    CGSize audioTextSize = [audioButtonText sizeWithAttributes:buttonTextAttrs];
    
    // FIXED BUTTON SIZING: Use consistent button widths to prevent position shifting
    // This fixes the issue where CC button becomes unclickable when audio track names change
    CGFloat fixedSubtitleButtonWidth = MAX(60, subtitleTextSize.width + buttonPadding); // Fixed minimum width
    CGFloat fixedAudioButtonWidth = MAX(60, audioTextSize.width + buttonPadding); // Fixed minimum width
    
    // Cap maximum widths to prevent buttons from becoming too large
    fixedSubtitleButtonWidth = MIN(fixedSubtitleButtonWidth, 120);
    fixedAudioButtonWidth = MIN(fixedAudioButtonWidth, 120);
    
    // FIXED POSITIONING: Use consistent positioning regardless of content
    CGFloat totalButtonsWidth = fixedSubtitleButtonWidth + fixedAudioButtonWidth + buttonSpacing;
    CGFloat buttonsStartX = contentStartX + contentWidth - totalButtonsWidth - 10; // Extra margin to prevent overlap
    
    // Debug: Check if buttons are positioned correctly within content area
    //NSLog(@"📱 [POSITIONING-DEBUG] Content area: x=%.1f, width=%.1f (end at %.1f)", contentStartX, contentWidth, contentStartX + contentWidth);
    //NSLog(@"📱 [POSITIONING-DEBUG] Total buttons width: %.1f, buttons start at: %.1f", totalButtonsWidth, buttonsStartX);
    //NSLog(@"📱 [POSITIONING-DEBUG] Left button will be at: %.1f-%.1f", buttonsStartX, buttonsStartX + fixedSubtitleButtonWidth);
    
    // ORIGINAL BUTTON ORDER: CC button on left, Audio button on right
    // Subtitle button with fixed width (on the left)
    CGRect subtitleButtonRect = CGRectMake(buttonsStartX, buttonY, fixedSubtitleButtonWidth, buttonHeight);
    
    // Audio button with fixed width (on the right)
    CGRect audioButtonRect = CGRectMake(buttonsStartX + fixedSubtitleButtonWidth + buttonSpacing, buttonY, fixedAudioButtonWidth, buttonHeight);
    
    //NSLog(@"📱 [BUTTON-FIX-DEBUG] Fixed CC button width: %.1f (was dynamic)", fixedSubtitleButtonWidth);
    //NSLog(@"📱 [BUTTON-FIX-DEBUG] Fixed audio button width: %.1f (was dynamic)", fixedAudioButtonWidth);
    //NSLog(@"📱 [BUTTON-FIX-DEBUG] CC button text: '%@', Audio button text: '%@'", subtitleButtonText, audioButtonText);
    //NSLog(@"📱 [BUTTON-POSITION-DEBUG] CC button at x=%.1f, Audio button at x=%.1f", subtitleButtonRect.origin.x, audioButtonRect.origin.x);
    //NSLog(@"📱 [LEFT-BUTTON-DEBUG] Left button (CC) bounds: x=%.1f-%.1f, y=%.1f-%.1f", 
    //      subtitleButtonRect.origin.x, 
    //      subtitleButtonRect.origin.x + subtitleButtonRect.size.width,
    //      subtitleButtonRect.origin.y, 
    //      subtitleButtonRect.origin.y + subtitleButtonRect.size.height);
    
    // Store for click handling
    objc_setAssociatedObject(self, @"subtitlesButtonRect", [NSValue valueWithCGRect:subtitleButtonRect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Debug logging for button positioning
    //NSLog(@"📱 [CC-DRAW-DEBUG] Drawing subtitle button at rect: %@", NSStringFromCGRect(subtitleButtonRect));
    //NSLog(@"📱 [CC-DRAW-DEBUG] hasSubtitles: %@, hasAudio: %@", hasSubtitles ? @"YES" : @"NO", hasAudio ? @"YES" : @"NO");
    
    // Get track counts for debug logging
    NSUInteger textTrackCount = 0;
    NSUInteger audioTrackCount = 0;
    if (self.player) {
        NSArray *debugTextTracks = [self.player textTracks];
        NSArray *debugAudioTracks = [self.player audioTracks];
        textTrackCount = debugTextTracks.count;
        audioTrackCount = debugAudioTracks.count;
    }
    //NSLog(@"📱 [CC-DRAW-DEBUG] Text tracks: %lu, Audio tracks: %lu", (unsigned long)textTrackCount, (unsigned long)audioTrackCount);
    // Store for click handling
    objc_setAssociatedObject(self, @"audioButtonRect", [NSValue valueWithCGRect:audioButtonRect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Debug: Check for button overlap
    BOOL buttonsOverlap = CGRectIntersectsRect(subtitleButtonRect, audioButtonRect);
    //NSLog(@"📱 [BUTTON-OVERLAP-DEBUG] Subtitle rect: %@", NSStringFromCGRect(subtitleButtonRect));
    //NSLog(@"📱 [BUTTON-OVERLAP-DEBUG] Audio rect: %@", NSStringFromCGRect(audioButtonRect));
    //NSLog(@"📱 [BUTTON-OVERLAP-DEBUG] Buttons overlap: %@", buttonsOverlap ? @"YES" : @"NO");
    //NSLog(@"📱 [BUTTON-OVERLAP-DEBUG] Button spacing: %.1f", buttonSpacing);
    
    // Draw subtitle button first (on the left) with Mac state-based colors and tvOS focus
    UIBezierPath *subtitleBg = [UIBezierPath bezierPathWithRoundedRect:subtitleButtonRect cornerRadius:6];
    BOOL isSubtitleFocused = (_playerControlsNavigationMode && _selectedPlayerControl == 1);
    
    if (isSubtitleFocused) {
        // tvOS focus state - bright highlight
        [[UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.9] setFill];
    } else if (hasSubtitles) {
        [[UIColor colorWithRed:0.3 green:0.5 blue:0.8 alpha:0.9] setFill];
    } else {
        [[UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.8] setFill];
    }
    [subtitleBg fill];
    
    // Add focus border for tvOS
    if (isSubtitleFocused) {
        [[UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0] setStroke];
        subtitleBg.lineWidth = 3.0;
        [subtitleBg stroke];
    }
    
    // Subtitle text with focus-aware color (centered in fixed-width button)
    CGRect subtitleTextRect = CGRectMake(
        subtitleButtonRect.origin.x + (fixedSubtitleButtonWidth - subtitleTextSize.width) / 2,
        subtitleButtonRect.origin.y + (buttonHeight - subtitleTextSize.height) / 2,
        subtitleTextSize.width,
        subtitleTextSize.height
    );
    
    NSDictionary *subtitleTextAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11],
        NSForegroundColorAttributeName: isSubtitleFocused ? [UIColor blackColor] : [UIColor whiteColor]
    };
    [subtitleButtonText drawInRect:subtitleTextRect withAttributes:subtitleTextAttrs];
    
    // Draw audio button second (on the right) with Mac state-based colors and tvOS focus
    UIBezierPath *audioBg = [UIBezierPath bezierPathWithRoundedRect:audioButtonRect cornerRadius:6];
    BOOL isAudioFocused = (_playerControlsNavigationMode && _selectedPlayerControl == 2);
    
    if (isAudioFocused) {
        // tvOS focus state - bright highlight
        [[UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.9] setFill];
    } else if (hasAudio) {
        [[UIColor colorWithRed:0.3 green:0.5 blue:0.8 alpha:0.9] setFill];
    } else {
        [[UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.8] setFill];
    }
    [audioBg fill];
    
    // Add focus border for tvOS
    if (isAudioFocused) {
        [[UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0] setStroke];
        audioBg.lineWidth = 3.0;
        [audioBg stroke];
    }
    
    // Audio text with focus-aware color (centered in fixed-width button)
    CGRect audioTextRect = CGRectMake(
        audioButtonRect.origin.x + (fixedAudioButtonWidth - audioTextSize.width) / 2,
        audioButtonRect.origin.y + (buttonHeight - audioTextSize.height) / 2,
        audioTextSize.width,
        audioTextSize.height
    );
    
    NSDictionary *audioTextAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:11],
        NSForegroundColorAttributeName: isAudioFocused ? [UIColor blackColor] : [UIColor whiteColor]
    };
    [audioButtonText drawInRect:audioTextRect withAttributes:audioTextAttrs];
}

- (void)drawMacStyleChannelInfoiOS:(CGRect)controlsRect 
                      contentStart:(CGFloat)contentStartX 
                      contentWidth:(CGFloat)contentWidth 
                    currentChannel:(VLCChannel *)currentChannel 
                    currentProgram:(VLCProgram *)currentProgram 
                      currentTimeStr:(NSString *)currentTimeStr 
                        totalTimeStr:(NSString *)totalTimeStr 
                    programStatusStr:(NSString *)programStatusStr 
                     programTimeRange:(NSString *)programTimeRange {
    
    // EXACT Mac channel info layout - FIXED POSITIONING TO AVOID OVERLAPS WITH PROGRESS BAR
    CGFloat availableWidth = contentWidth - 150; // Leave space for buttons
    
    // Progress bar is at 55% of control height, so position text above it
    CGFloat progressBarY = controlsRect.origin.y + controlsRect.size.height * 0.55;
    CGFloat textAreaTop = controlsRect.origin.y + 10; // Start from top of controls
    CGFloat textAreaHeight = progressBarY - textAreaTop - 10; // Leave 10px margin above progress bar
    
    if (currentChannel && currentChannel.name) {
        NSDictionary *channelAttrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:15], // Slightly smaller for mobile
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        
        // Position at top of text area
        CGRect channelRect = CGRectMake(contentStartX, textAreaTop, availableWidth, 18);
        [currentChannel.name drawInRect:channelRect withAttributes:channelAttrs];
    }
    
    // Program title and description (Mac style) - POSITIONED BELOW CHANNEL NAME
    CGFloat currentY = textAreaTop + 22;
    if (currentProgram && currentProgram.title) {
        NSDictionary *programAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:13], // Smaller for mobile
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.9 green:0.9 blue:0.9 alpha:1.0]
        };
        
        CGRect programRect = CGRectMake(contentStartX, currentY, availableWidth, 15);
        [currentProgram.title drawInRect:programRect withAttributes:programAttrs];
        currentY += 18; // Move down for description
        
        // Add program description if available
        if (currentProgram.programDescription && [currentProgram.programDescription length] > 0) {
            NSString *description = currentProgram.programDescription;
            
            // Truncate long descriptions to fit in the available space
            NSInteger maxDescriptionLength = 120; // Reasonable length for mobile
            if (description.length > maxDescriptionLength) {
                description = [[description substringToIndex:(maxDescriptionLength - 3)] stringByAppendingString:@"..."];
            }
            
            NSDictionary *descAttrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:10], // Even smaller font for description
                NSForegroundColorAttributeName: [UIColor colorWithRed:0.7 green:0.7 blue:0.7 alpha:1.0] // Dimmer color
            };
            
            // Calculate available height for description (before progress bar)
            CGFloat availableDescHeight = progressBarY - currentY - 10; // 10px margin before progress bar
            CGFloat descHeight = MIN(24, availableDescHeight); // Max 2 lines, or available space
            
            if (descHeight > 10) { // Only show if we have enough space
                CGRect descRect = CGRectMake(contentStartX, currentY, availableWidth, descHeight);
                [description drawInRect:descRect withAttributes:descAttrs];
            }
        }
    }
    
    // Enhanced time display aligned with progress bar
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    
    // CRITICAL FIX: Get the ACTUAL progress bar coordinates that were stored during drawing
    NSValue *progressRectValue = objc_getAssociatedObject(self, @selector(progressBarRect));
    CGRect actualProgressRect;
    
    if (progressRectValue) {
        actualProgressRect = [progressRectValue CGRectValue];
    } else {
        // Fallback: calculate the same way as in drawUnifiedPlayerControlsiOS
        CGFloat logoSize = 60;
        CGFloat logoMargin = 15;
        CGFloat realContentStartX = controlsRect.origin.x + logoMargin + logoSize + logoMargin;
        CGFloat realContentWidth = controlsRect.size.width - (realContentStartX - controlsRect.origin.x) - logoMargin;
        CGFloat realProgressBarY = controlsRect.origin.y + controlsRect.size.height * 0.55;
        actualProgressRect = CGRectMake(realContentStartX, realProgressBarY, realContentWidth, 6);
    }
    
    // Use ACTUAL progress bar coordinates for perfect alignment
    CGFloat progressBarWidth = actualProgressRect.size.width;
    CGFloat progressBarStartX = actualProgressRect.origin.x;
    progressBarY = actualProgressRect.origin.y;
    
    if (isTimeshiftPlaying) {
        // For timeshift: currentTimeStr = start time, totalTimeStr = end time
        // Extract current playing time from programStatusStr
        NSString *currentPlayingTime = @"--:--";
        if (programStatusStr && [programStatusStr containsString:@"Playing: "]) {
            NSRange playingRange = [programStatusStr rangeOfString:@"Playing: "];
            if (playingRange.location != NSNotFound) {
                NSString *afterPlaying = [programStatusStr substringFromIndex:playingRange.location + playingRange.length];
                NSRange spaceRange = [afterPlaying rangeOfString:@" "];
                if (spaceRange.location != NSNotFound) {
                    currentPlayingTime = [afterPlaying substringToIndex:spaceRange.location];
                }
            }
        }
        
        // Fonts for timeshift times - smaller sizes
        NSDictionary *timeAttrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:12], // Reduced from 16
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        
        NSDictionary *currentTimeAttrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:14], // Reduced from 18
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0] // Blue highlight
        };
        
        CGFloat timeY = actualProgressRect.origin.y + 8; // Moved up from 15 to 8, using actual progress bar position
        CGFloat timeHeight = 16; // Reduced from 20
        
        // Start time aligned with beginning of progress bar
        CGRect startTimeRect = CGRectMake(progressBarStartX, timeY, 100, timeHeight);
        [currentTimeStr drawInRect:startTimeRect withAttributes:timeAttrs];
        
        // Current playing time perfectly centered on progress bar - FIXED CENTERING
        CGSize currentTimeSize = [currentPlayingTime sizeWithAttributes:currentTimeAttrs];
        CGFloat centerX = progressBarStartX + (progressBarWidth - currentTimeSize.width) / 2; // Fixed centering calculation
        CGRect currentTimeRect = CGRectMake(centerX, timeY - 1, currentTimeSize.width, timeHeight + 2);
        [currentPlayingTime drawInRect:currentTimeRect withAttributes:currentTimeAttrs];
        
        // End time aligned with END of progress bar - FIXED ALIGNMENT
        CGSize endTimeSize = [totalTimeStr sizeWithAttributes:timeAttrs];
        CGFloat rightX = progressBarStartX + progressBarWidth - endTimeSize.width; // This should align with progress bar end
        CGRect endTimeRect = CGRectMake(rightX, timeY, endTimeSize.width, timeHeight);
        [totalTimeStr drawInRect:endTimeRect withAttributes:timeAttrs];
        
    } else {
        // Enhanced non-timeshift display: Show EPG program times with current time in middle
        if (currentProgram && currentProgram.startTime && currentProgram.endTime) {
            // Format program start and end times
            NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
            [timeFormatter setDateFormat:@"HH:mm:ss"];
            [timeFormatter setTimeZone:[NSTimeZone localTimeZone]];
            
            // Apply EPG offset for display
            NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
            NSDate *displayStartTime = [currentProgram.startTime dateByAddingTimeInterval:displayOffsetSeconds];
            NSDate *displayEndTime = [currentProgram.endTime dateByAddingTimeInterval:displayOffsetSeconds];
            
            NSString *programStartTime = [timeFormatter stringFromDate:displayStartTime];
            NSString *programEndTime = [timeFormatter stringFromDate:displayEndTime];
            
            // Get current real time
            NSDate *now = [NSDate date];
            NSString *currentRealTime = [timeFormatter stringFromDate:now];
            
            [timeFormatter release];
            
            // Fonts for EPG times - smaller sizes
            NSDictionary *timeAttrs = @{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:12], // Reduced from 16
                NSForegroundColorAttributeName: [UIColor whiteColor]
            };
            
            NSDictionary *currentTimeAttrs = @{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:14], // Reduced from 18
                NSForegroundColorAttributeName: [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0] // Blue highlight
            };
            
            CGFloat timeY = actualProgressRect.origin.y + 8; // Moved up from 15 to 8, using actual progress bar position
            CGFloat timeHeight = 16; // Reduced from 20
            
            // Program start time aligned with beginning of progress bar
            CGRect startTimeRect = CGRectMake(progressBarStartX, timeY, 100, timeHeight);
            [programStartTime drawInRect:startTimeRect withAttributes:timeAttrs];
            
            // Current real time perfectly centered on progress bar - FIXED CENTERING
            CGSize currentTimeSize = [currentRealTime sizeWithAttributes:currentTimeAttrs];
            CGFloat centerX = progressBarStartX + (progressBarWidth - currentTimeSize.width) / 2; // Fixed centering calculation
            CGRect currentTimeRect = CGRectMake(centerX, timeY - 1, currentTimeSize.width, timeHeight + 2);
            [currentRealTime drawInRect:currentTimeRect withAttributes:currentTimeAttrs];
            
            // Program end time aligned with END of progress bar - FIXED ALIGNMENT
            CGSize endTimeSize = [programEndTime sizeWithAttributes:timeAttrs];
            CGFloat rightX = progressBarStartX + progressBarWidth - endTimeSize.width; // This should align with progress bar end
            CGRect endTimeRect = CGRectMake(rightX, timeY, endTimeSize.width, timeHeight);
            [programEndTime drawInRect:endTimeRect withAttributes:timeAttrs];
            
        } else {
            // Fallback: Standard time display for content without EPG
            NSString *timeText = [NSString stringWithFormat:@"%@ / %@", currentTimeStr, totalTimeStr];
            NSDictionary *timeAttrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [UIColor colorWithRed:0.8 green:0.8 blue:0.8 alpha:1.0]
            };
            
            CGRect timeRect = CGRectMake(progressBarStartX, actualProgressRect.origin.y + 15, progressBarWidth, 12);
            [timeText drawInRect:timeRect withAttributes:timeAttrs];
        }
    }
    
    // Status info positioned at bottom
    if (programStatusStr && [programStatusStr length] > 0) {
        NSDictionary *statusAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:10], // Smaller for mobile
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.7 green:0.7 blue:0.7 alpha:1.0]
        };
        
        CGRect statusRect = CGRectMake(progressBarStartX, actualProgressRect.origin.y + 30, progressBarWidth, 10); // Below time
        [programStatusStr drawInRect:statusRect withAttributes:statusAttrs];
    }
}

// Auto-hide timer using Mac logic
- (void)resetPlayerControlsTimer {
    #if TARGET_OS_IOS || TARGET_OS_TV
    // Use the same timer logic as Mac
    [self stopAutoHideTimer];
    
    if (_playerControlsVisible) {
        _autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                          target:self
                                                        selector:@selector(playerControlsTimerFired:)
                                                        userInfo:nil
                                                         repeats:NO];
        NSLog(@"📱 [MAC-TIMER] Player controls timer started - hiding in 5 seconds");
    }
    #endif
}

- (void)playerControlsTimerFired:(NSTimer *)timer {
    #if TARGET_OS_IOS || TARGET_OS_TV
    if (_playerControlsVisible) {
        NSLog(@"📱 [MAC-TIMER] Player controls timer fired - hiding controls");
        _playerControlsVisible = NO;
        [self setNeedsDisplay];
    }
    [self stopAutoHideTimer];
    #endif
}

// Add missing timeshift and interaction methods

- (void)calculateTimeshiftProgress:(float *)progress 
                   currentTimeStr:(NSString **)currentTimeStr 
                     totalTimeStr:(NSString **)totalTimeStr 
                  programStatusStr:(NSString **)programStatusStr 
                   programTimeRange:(NSString **)programTimeRange 
                     currentChannel:(VLCChannel *)currentChannel 
                     currentProgram:(VLCProgram *)currentProgram {
    // FULL Mac timeshift logic - IDENTICAL to Mac version
    // Check if we have frozen time values during seeking
    NSDictionary *frozenValues = [self getFrozenTimeValues];
    if (frozenValues && [self isTimeshiftSeeking]) {
        // Use frozen values during seeking to prevent flickering
        *currentTimeStr = [frozenValues objectForKey:@"currentTimeStr"];
        *totalTimeStr = [frozenValues objectForKey:@"totalTimeStr"];
        *programStatusStr = [frozenValues objectForKey:@"programStatusStr"];
        *programTimeRange = @"Seeking to new position...";
        *progress = 0.5; // Keep progress in middle during seeking
        return;
    }
    
    // Get current playback time
    VLCTime *currentTime = [self.player time];
    if (!currentTime) {
        *progress = 0.5; // Always middle when no time available
        *currentTimeStr = @"--:--";
        *totalTimeStr = @"2:00:00";
        *programStatusStr = @"Timeshift - Loading...";
        *programTimeRange = @"";
        return;
    }
    
    // Get current URL and extract timeshift start time
    NSString *currentUrl = [self.player.media.url absoluteString];
    NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
    NSDate *currentRealTime = [NSDate date];
    
    if (timeshiftStartTime) {
        // Apply EPG offset adjustment for display
        NSTimeInterval epgAdjustmentForDisplay = self.epgTimeOffsetHours * 3600.0;
        timeshiftStartTime = [timeshiftStartTime dateByAddingTimeInterval:epgAdjustmentForDisplay];
        
        // Calculate current playback position in seconds from timeshift start
        NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
        NSDate *actualPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
        
        // Create 2-hour sliding window centered around current play time (EXACT Mac logic)
        NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
        [timeFormatter setDateFormat:@"HH:mm:ss"];
        [timeFormatter setTimeZone:[NSTimeZone localTimeZone]];
        
        NSDate *centeredStartTime = [actualPlayTime dateByAddingTimeInterval:-3600]; // -1 hour
        NSDate *centeredEndTime = [actualPlayTime dateByAddingTimeInterval:3600];    // +1 hour
        
        // Apply EPG offset for display times (same as Mac)
        NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
        NSDate *displayStartTime = [centeredStartTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSDate *displayEndTime = [centeredEndTime dateByAddingTimeInterval:displayOffsetSeconds];
        NSDate *displayCurrentPlayTime = [actualPlayTime dateByAddingTimeInterval:displayOffsetSeconds];
        
        // Calculate progress: current play time position within the 2-hour window
        NSTimeInterval windowDuration = [centeredEndTime timeIntervalSinceDate:centeredStartTime];
        NSTimeInterval playTimeOffset = [actualPlayTime timeIntervalSinceDate:centeredStartTime];
        
        if (windowDuration > 0) {
            *progress = playTimeOffset / windowDuration;
            *progress = MIN(1.0, MAX(0.0, *progress)); // Clamp between 0 and 1
        } else {
            *progress = 0.5; // Fallback to middle
        }
      
        // Show the centered window times for progress bar (LIKE MAC)
        *currentTimeStr = [timeFormatter stringFromDate:displayStartTime];
        *totalTimeStr = [timeFormatter stringFromDate:displayEndTime];
        
        // Calculate how far behind live we are
        NSTimeInterval timeBehindLive = [currentRealTime timeIntervalSinceDate:actualPlayTime];
        
        // Status shows current play position within the sliding window
        NSString *currentPlayTimeStr = [timeFormatter stringFromDate:displayCurrentPlayTime];
        int behindMins = (int)(timeBehindLive / 60);
        
        if (behindMins < 60) {
            *programStatusStr = [NSString stringWithFormat:@"Timeshift - Playing: %@ (%d min behind)", currentPlayTimeStr, behindMins];
        } else {
            int behindHours = behindMins / 60;
            int remainingMins = behindMins % 60;
            *programStatusStr = [NSString stringWithFormat:@"Timeshift - Playing: %@ (%dh %dm behind)", currentPlayTimeStr, behindHours, remainingMins];
        }
        
        // Find EPG programs that fall within the timeshift window and display them
        NSString *epgProgramInfo = @"";
        if (currentChannel && currentChannel.programs && currentChannel.programs.count > 0) {
            // Get current timeshift playing program
            VLCProgram *currentTimeshiftProgram = [self getCurrentTimeshiftPlayingProgram];
            if (currentTimeshiftProgram && currentTimeshiftProgram.title) {
                NSDateFormatter *shortFormatter = [[NSDateFormatter alloc] init];
                [shortFormatter setDateFormat:@"HH:mm"];
                [shortFormatter setTimeZone:[NSTimeZone localTimeZone]];
                
                NSString *currentStr = [self formatProgramString:currentTimeshiftProgram formatter:shortFormatter isDimmed:NO];
                epgProgramInfo = [NSString stringWithFormat:@"► %@", currentStr];
                
                [shortFormatter release];
            } else {
                epgProgramInfo = @"No current program found";
            }
        } else {
            epgProgramInfo = @"No EPG data available";
        }
        
        *programTimeRange = epgProgramInfo;
        
        [timeFormatter release];
    } else {
        // Fallback when we can't extract timeshift start time
        *progress = 0.5; // Always middle
        
        // Format current time
        NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
        int currentMins = (int)(currentSeconds / 60);
        int currentSecs = (int)(currentSeconds) % 60;
        *currentTimeStr = [NSString stringWithFormat:@"%d:%02d", currentMins, currentSecs];
        
        *totalTimeStr = @"2:00:00";
        *programStatusStr = @"Timeshift - 2 hour window";
        *programTimeRange = @"Timeshift content";
    }
}

// Mac-style hover functionality for touch devices
- (BOOL)isHoveringProgressBar {
    #if TARGET_OS_IOS || TARGET_OS_TV
    return _progressBarBeingTouched;
    #else
    return NO;
    #endif
}

- (CGPoint)progressBarHoverPoint {
    #if TARGET_OS_IOS || TARGET_OS_TV
    return _progressBarTouchPoint;
    #else
    return CGPointZero;
    #endif
}

// Touch handling for control buttons  
- (BOOL)handlePlayerControlTouchAt:(CGPoint)touchPoint {
    //NSLog(@"📱 [TOUCH-DEBUG] Touch at point: (%.1f, %.1f)", touchPoint.x, touchPoint.y);
    
    // First check if tap is within the overall controls area
    CGFloat controlHeight = 140; // Same as Mac
    CGFloat margin = 20;
    CGFloat controlsWidth = MIN(600, self.bounds.size.width - 2 * margin); // Max width of 600pt or screen width
    CGFloat controlsX = (self.bounds.size.width - controlsWidth) / 2; // Center horizontally
    CGRect controlsRect = CGRectMake(controlsX, self.bounds.size.height - controlHeight - margin, 
                                   controlsWidth, controlHeight);
    
    if (!CGRectContainsPoint(controlsRect, touchPoint)) {
        //NSLog(@"📱 [TOUCH-DEBUG] Touch outside control area");
        return NO; // Touch is outside control area
    }
    
    // Check subtitle button
    NSValue *subtitleRectValue = objc_getAssociatedObject(self, @"subtitlesButtonRect");
    if (subtitleRectValue) {
        CGRect subtitleRect = [subtitleRectValue CGRectValue];
        //NSLog(@"📱 [TOUCH-DEBUG] Subtitle rect: %@", NSStringFromCGRect(subtitleRect));
        
        // Additional debug info
        NSArray *textTracks = [self.player textTracks];
        NSArray *audioTracks = [self.player audioTracks];
        //NSLog(@"📱 [CC-DEBUG] Text tracks: %lu, Audio tracks: %lu", (unsigned long)textTracks.count, (unsigned long)audioTracks.count);
        //NSLog(@"📱 [CC-DEBUG] Touch point: (%.1f, %.1f)", touchPoint.x, touchPoint.y);
        //NSLog(@"📱 [CC-DEBUG] Subtitle rect contains point: %@", CGRectContainsPoint(subtitleRect, touchPoint) ? @"YES" : @"NO");
        
        // DETAILED RECT ANALYSIS
        //NSLog(@"📱 [CC-RECT-DEBUG] CC rect bounds: x=%.1f-%.1f, y=%.1f-%.1f", 
        //      subtitleRect.origin.x, 
        //      subtitleRect.origin.x + subtitleRect.size.width,
        //      subtitleRect.origin.y, 
        //      subtitleRect.origin.y + subtitleRect.size.height);
        //NSLog(@"📱 [CC-RECT-DEBUG] Touch vs CC: x-diff=%.1f, y-diff=%.1f", 
        //      touchPoint.x - subtitleRect.origin.x,
        //      touchPoint.y - subtitleRect.origin.y);
        
        if (CGRectContainsPoint(subtitleRect, touchPoint)) {
            //NSLog(@"📱 [TOUCH-DEBUG] ✅ SUBTITLE BUTTON HIT!");
            //NSLog(@"📱 [CC-DEBUG] About to call showSubtitleDropdownList");
            [self showSubtitleDropdownList];
            [self resetPlayerControlsTimer];
            return YES;
        } else {
            //NSLog(@"📱 [TOUCH-DEBUG] ❌ SUBTITLE BUTTON MISSED!");
            //NSLog(@"📱 [CC-DEBUG] Touch point (%.1f, %.1f) is outside CC rect %@", touchPoint.x, touchPoint.y, NSStringFromCGRect(subtitleRect));
        }
    } else {
        //NSLog(@"📱 [TOUCH-DEBUG] No subtitle rect stored");
        //NSLog(@"📱 [CC-DEBUG] CRITICAL: Subtitle button rect was not stored during drawing!");
    }
    
    // Check audio button
    NSValue *audioRectValue = objc_getAssociatedObject(self, @"audioButtonRect");
    if (audioRectValue) {
        CGRect audioRect = [audioRectValue CGRectValue];
        //NSLog(@"📱 [TOUCH-DEBUG] Audio rect: %@", NSStringFromCGRect(audioRect));
        
        // DETAILED AUDIO RECT ANALYSIS (for comparison with CC)
        //NSLog(@"📱 [AUDIO-RECT-DEBUG] Audio rect bounds: x=%.1f-%.1f, y=%.1f-%.1f", 
         //     audioRect.origin.x, 
         //     audioRect.origin.x + audioRect.size.width,
         //     audioRect.origin.y, 
         //     audioRect.origin.y + audioRect.size.height);
        //NSLog(@"📱 [AUDIO-RECT-DEBUG] Touch vs Audio: x-diff=%.1f, y-diff=%.1f", 
        //      touchPoint.x - audioRect.origin.x,
        //      touchPoint.y - audioRect.origin.y);
        //NSLog(@"📱 [AUDIO-DEBUG] Audio rect contains point: %@", CGRectContainsPoint(audioRect, touchPoint) ? @"YES" : @"NO");
        
        if (CGRectContainsPoint(audioRect, touchPoint)) {
            //NSLog(@"📱 [TOUCH-DEBUG] ✅ AUDIO BUTTON HIT!");
            [self showAudioDropdownList];
            [self resetPlayerControlsTimer];
            return YES;
        } else {
            //NSLog(@"📱 [TOUCH-DEBUG] ❌ AUDIO BUTTON MISSED!");
        }
    } else {
        //NSLog(@"📱 [TOUCH-DEBUG] No audio rect stored");
    }
    
    //NSLog(@"📱 [TOUCH-DEBUG] Neither CC nor Audio button hit, checking progress bar...");
    
    // Check progress bar with expanded touch area for finger-friendly interaction
    // MOVED TO END: Check buttons first, then progress bar to avoid interference
    NSValue *progressRectValue = objc_getAssociatedObject(self, @selector(progressBarRect));
    if (progressRectValue) {
        CGRect progressRect = [progressRectValue CGRectValue];
        // Expand touch area significantly for finger touch (44pt minimum touch target as per Apple HIG)
        CGRect expandedProgressRect = CGRectInset(progressRect, -20, -20); // 40pt wider, 40pt taller
        //NSLog(@"📱 [TOUCH-DEBUG] Progress rect: %@ -> Expanded: %@", NSStringFromCGRect(progressRect), NSStringFromCGRect(expandedProgressRect));
        
        // Debug: Check if expanded progress bar interferes with CC button
        NSValue *subtitleRectDebug = objc_getAssociatedObject(self, @"subtitlesButtonRect");
        if (subtitleRectDebug) {
            CGRect subtitleRectDebugValue = [subtitleRectDebug CGRectValue];
            BOOL progressInterferesWithCC = CGRectIntersectsRect(expandedProgressRect, subtitleRectDebugValue);
            //NSLog(@"📱 [PROGRESS-INTERFERENCE-DEBUG] Expanded progress interferes with CC: %@", progressInterferesWithCC ? @"YES" : @"NO");
            //NSLog(@"📱 [PROGRESS-INTERFERENCE-DEBUG] Progress rect: %@", NSStringFromCGRect(progressRect));
            //NSLog(@"📱 [PROGRESS-INTERFERENCE-DEBUG] Expanded progress rect: %@", NSStringFromCGRect(expandedProgressRect));
            //NSLog(@"📱 [PROGRESS-INTERFERENCE-DEBUG] CC button rect: %@", NSStringFromCGRect(subtitleRectDebugValue));
            if (progressInterferesWithCC) {
                //NSLog(@"📱 [PROGRESS-INTERFERENCE-DEBUG] ⚠️ CRITICAL: Progress bar may be stealing CC touches!");
                //NSLog(@"📱 [PROGRESS-INTERFERENCE-DEBUG] ⚠️ Touch at (%.1f, %.1f) - checking if it's in expanded progress area", touchPoint.x, touchPoint.y);
                BOOL touchInExpandedProgress = CGRectContainsPoint(expandedProgressRect, touchPoint);
                BOOL touchInCCButton = CGRectContainsPoint(subtitleRectDebugValue, touchPoint);
                //NSLog(@"📱 [PROGRESS-INTERFERENCE-DEBUG] Touch in expanded progress: %@, Touch in CC: %@", 
                //      touchInExpandedProgress ? @"YES" : @"NO", touchInCCButton ? @"YES" : @"NO");
            }
        }
        
        if (CGRectContainsPoint(expandedProgressRect, touchPoint)) {
            //NSLog(@"📱 [TOUCH-DEBUG] PROGRESS BAR HIT!");
            [self handleProgressBarTouchAt:touchPoint inRect:progressRect]; // Use original rect for calculation
            [self resetPlayerControlsTimer];
            return YES;
        }
    } else {
        //NSLog(@"📱 [TOUCH-DEBUG] No progress rect stored");
    }
    
    //NSLog(@"📱 [TOUCH-DEBUG] No controls hit");
    return NO;
}

- (void)handleProgressBarTouchAt:(CGPoint)touchPoint inRect:(CGRect)progressRect {
    // Mac-style progress bar interaction with proper seeking for both movies and timeshift
    CGFloat relativeX = touchPoint.x - progressRect.origin.x;
    CGFloat seekPosition = relativeX / progressRect.size.width;
    seekPosition = MAX(0.0, MIN(1.0, seekPosition));
    
    // Store touch state for hover marker
    _progressBarBeingTouched = YES;
    _progressBarTouchPoint = touchPoint;
    
    NSLog(@"📱 [PROGRESS-SEEK] Touch at position: %.3f", seekPosition);
    
    // Determine if this is timeshift content or regular video/movie
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    
    if (isTimeshiftPlaying) {
        // Handle timeshift seeking (like Mac)
        [self handleTimeshiftSeekiOS:seekPosition];
        NSLog(@"📱 [PROGRESS-SEEK] Handling timeshift seek");
    } else {
        // Handle normal video/movie seeking (like Mac)
        [self handleNormalSeekiOS:seekPosition];
        NSLog(@"📱 [PROGRESS-SEEK] Handling normal video seek");
    }
    
    [self setNeedsDisplay];
    
    // Reset touch state after a short delay to hide hover marker
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _progressBarBeingTouched = NO;
        [self setNeedsDisplay];
    });
}

// iOS implementation of normal video/movie seeking (like Mac)
- (void)handleNormalSeekiOS:(CGFloat)relativePosition {
    NSLog(@"📱 [NORMAL-SEEK] Seeking to position: %.3f", relativePosition);
    
    // Get total duration and seek (basic VLC seeking for movies/videos)
    VLCTime *totalTime = [self.player.media length];
    if (totalTime && [totalTime intValue] > 0) {
        // Calculate new position in milliseconds
        int newPositionMs = (int)([totalTime intValue] * relativePosition);
        
        // Create a VLCTime object with the new position
        VLCTime *newTime = [VLCTime timeWithInt:newPositionMs];
        
        // Set the player to the new position
        [self.player setTime:newTime];
        
        NSLog(@"📱 [NORMAL-SEEK] Seeked to %d ms (%.1f%% of %d ms total)", 
              newPositionMs, relativePosition * 100.0, [totalTime intValue]);
    } else {
        NSLog(@"📱 [NORMAL-SEEK] Cannot seek - no valid duration");
    }
}

// iOS implementation of timeshift seeking (FULL Mac logic implementation)
- (void)handleTimeshiftSeekiOS:(CGFloat)relativePosition {
    NSLog(@"📱 [TIMESHIFT-SEEK] Seeking timeshift to position: %.3f", relativePosition);
    
    NSString *currentUrl = [self.player.media.url absoluteString];
    if (!currentUrl) {
        NSLog(@"📱 [TIMESHIFT-SEEK] No current URL - cannot seek");
        return;
    }
    
    // Extract timeshift start time from current URL (same as Mac)
    NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
    if (!timeshiftStartTime) {
        NSLog(@"📱 [TIMESHIFT-SEEK] Cannot extract timeshift start time - fallback to basic seek");
        [self handleNormalSeekiOS:relativePosition];
        return;
    }
    
    // Apply EPG offset adjustment (same as Mac)
    NSTimeInterval epgAdjustmentForDisplay = self.epgTimeOffsetHours * 3600.0;
    timeshiftStartTime = [timeshiftStartTime dateByAddingTimeInterval:epgAdjustmentForDisplay];
    
    // Get current playback position (same as Mac)
    VLCTime *currentTime = [self.player time];
    if (!currentTime) {
        NSLog(@"📱 [TIMESHIFT-SEEK] No current time - cannot seek");
        return;
    }
    
    NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
    NSDate *currentPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
    
    // Create 2-hour sliding window centered around current play time (EXACT Mac logic)
    NSDate *windowStartTime = [currentPlayTime dateByAddingTimeInterval:-3600]; // -1 hour
    NSDate *windowEndTime = [currentPlayTime dateByAddingTimeInterval:3600];    // +1 hour
    
    // Apply same constraint as Mac: cap end time at current real time
    NSDate *currentRealTime = [NSDate date];
    NSTimeInterval epgOffsetSeconds = -self.epgTimeOffsetHours * 3600.0;
    NSDate *maxAllowedTime = [currentRealTime dateByAddingTimeInterval:epgOffsetSeconds];
    
    if ([windowEndTime compare:maxAllowedTime] == NSOrderedDescending) {
        windowEndTime = maxAllowedTime;
    }
    
    // Calculate target time within sliding window based on position (same as Mac)
    NSTimeInterval windowDuration = [windowEndTime timeIntervalSinceDate:windowStartTime];
    NSTimeInterval targetOffsetFromWindowStart = relativePosition * windowDuration;
    NSDate *targetTime = [windowStartTime dateByAddingTimeInterval:targetOffsetFromWindowStart];
    
    // Don't seek if we're already very close to the target time (same as Mac)
    NSTimeInterval timeDifference = ABS([targetTime timeIntervalSinceDate:currentPlayTime]);
    if (timeDifference < 30) {
        NSLog(@"📱 [TIMESHIFT-SEEK] Already close to target time (%.1f seconds) - not seeking", timeDifference);
        return;
    }
    
    // Generate new timeshift URL using existing iOS method
    // Calculate seek offset in seconds from current play time to target time
    NSTimeInterval seekOffsetSeconds = [targetTime timeIntervalSinceDate:currentPlayTime];
    
    NSString *newTimeshiftUrl = [self generateTimeshiftURLFromOriginal:currentUrl 
                                                   withSeekOffsetSeconds:(NSInteger)seekOffsetSeconds];
    
    if (!newTimeshiftUrl) {
        NSLog(@"📱 [TIMESHIFT-SEEK] Failed to generate new timeshift URL - fallback to basic seek");
        [self handleNormalSeekiOS:relativePosition];
        return;
    }
    
    NSLog(@"📱 [TIMESHIFT-SEEK] Generated new timeshift URL for seeking");
    
    // Play the new URL (same as Mac)
    dispatch_async(dispatch_get_main_queue(), ^{
        // Stop current playback
        [self.player stop];
        
        // Brief pause to allow VLC to reset
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Create media object with new timeshift URL
            NSURL *url = [NSURL URLWithString:newTimeshiftUrl];
            VLCMedia *media = [VLCMedia mediaWithURL:url];
            
            // Set the media to the player
            [self.player setMedia:media];
            
            // Start playing
            [self.player play];
            
            NSLog(@"📱 [TIMESHIFT-SEEK] Successfully started playback with new timeshift URL");
            
            // Force UI update
            [self setNeedsDisplay];
        });
    });
}

- (void)showSubtitleDropdown {
    NSLog(@"📱 [MAC-DROPDOWN] Showing subtitle dropdown (cycle mode)");
    
    if (self.player) {
        NSArray *textTracks = [self.player textTracks];
        if (textTracks.count > 0) {
            // Cycle through subtitle tracks like Mac
            NSInteger currentIndex = -1;
            for (NSInteger i = 0; i < textTracks.count; i++) {
                VLCMediaPlayerTrack *track = textTracks[i];
                if (track.selected) {
                    currentIndex = i;
                    break;
                }
            }
            
            NSInteger nextIndex = (currentIndex + 1) % textTracks.count;
            VLCMediaPlayerTrack *nextTrack = textTracks[nextIndex];
            [self.player deselectAllTextTracks]; // First deselect all
            nextTrack.selectedExclusively = YES; // Then select the new one
            
            NSLog(@"📱 [MAC-DROPDOWN] Selected subtitle: %@", nextTrack.trackName);
        }
    }
}

- (void)showSubtitleDropdownList {
    NSLog(@"📱 [MAC-DROPDOWN] Showing subtitle dropdown list");
    
    if (!self.player) {
        NSLog(@"📱 [MAC-DROPDOWN] No player available");
        return;
    }
    
    NSArray *textTracks = [self.player textTracks];
    NSArray *audioTracks = [self.player audioTracks];
    NSLog(@"📱 [MAC-DROPDOWN] Found %lu text tracks, %lu audio tracks", (unsigned long)textTracks.count, (unsigned long)audioTracks.count);
    
    // Debug: Check if audio tracks are interfering
    NSLog(@"📱 [CC-INTERFERENCE-DEBUG] Audio tracks present: %@", audioTracks.count > 0 ? @"YES" : @"NO");
    for (NSInteger i = 0; i < audioTracks.count; i++) {
        VLCMediaPlayerTrack *track = audioTracks[i];
        NSLog(@"📱 [CC-INTERFERENCE-DEBUG] Audio track %ld: %@ (selected: %@)", (long)i, track.trackName, track.selected ? @"YES" : @"NO");
    }
    
    if (textTracks.count == 0) {
        // Show "No subtitles available" alert
        [self showAlertWithTitle:@"Subtitles" message:@"No subtitle tracks available"];
        return;
    }
    
    // Create action sheet with all available tracks
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:@"Select Subtitle Track"
                                                                         message:nil
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Add "Disable" option
    UIAlertAction *disableAction = [UIAlertAction actionWithTitle:@"Disable Subtitles"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * _Nonnull action) {
        [self.player deselectAllTextTracks];
        NSLog(@"📱 [MAC-DROPDOWN] Disabled all subtitles");
    }];
    [actionSheet addAction:disableAction];
    
    // Add each track
    for (NSInteger i = 0; i < textTracks.count; i++) {
        VLCMediaPlayerTrack *track = textTracks[i];
        NSString *trackTitle = track.trackName ?: [NSString stringWithFormat:@"Track %ld", (long)i];
        
        // Mark currently selected track
        if (track.selected) {
            trackTitle = [NSString stringWithFormat:@"✓ %@", trackTitle];
        }
        
        UIAlertAction *trackAction = [UIAlertAction actionWithTitle:trackTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction * _Nonnull action) {
            [self.player deselectAllTextTracks];
            track.selectedExclusively = YES;
            NSLog(@"📱 [MAC-DROPDOWN] Selected subtitle: %@", track.trackName);
        }];
        [actionSheet addAction:trackAction];
    }
    
    // Add cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    [actionSheet addAction:cancelAction];
    
    // Present the action sheet
    NSLog(@"📱 [CC-PRESENTATION-DEBUG] About to present subtitle action sheet with %lu tracks", (unsigned long)textTracks.count);
    [self presentActionSheet:actionSheet];
}

- (void)showAudioDropdown {
    NSLog(@"📱 [MAC-DROPDOWN] Showing audio dropdown (cycle mode)");
    
    if (self.player) {
        NSArray *audioTracks = [self.player audioTracks];
        if (audioTracks.count > 0) {
            // Cycle through audio tracks like Mac
            NSInteger currentIndex = -1;
            for (NSInteger i = 0; i < audioTracks.count; i++) {
                VLCMediaPlayerTrack *track = audioTracks[i];
                if (track.selected) {
                    currentIndex = i;
                    break;
                }
            }
            
            NSInteger nextIndex = (currentIndex + 1) % audioTracks.count;
            VLCMediaPlayerTrack *nextTrack = audioTracks[nextIndex];
            [self.player deselectAllAudioTracks]; // First deselect all
            nextTrack.selectedExclusively = YES; // Then select the new one
            
            NSLog(@"📱 [MAC-DROPDOWN] Selected audio: %@", nextTrack.trackName);
        }
    }
}

- (void)showAudioDropdownList {
    NSLog(@"📱 [MAC-DROPDOWN] Showing audio dropdown list");
    
    if (!self.player) {
        NSLog(@"📱 [MAC-DROPDOWN] No player available");
        return;
    }
    
    NSArray *audioTracks = [self.player audioTracks];
    NSLog(@"📱 [MAC-DROPDOWN] Found %lu audio tracks", (unsigned long)audioTracks.count);
    
    if (audioTracks.count == 0) {
        [self showAlertWithTitle:@"Audio" message:@"No audio tracks available"];
        return;
    }
    
    // Create action sheet with all available tracks
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:@"Select Audio Track"
                                                                         message:nil
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Add each track
    for (NSInteger i = 0; i < audioTracks.count; i++) {
        VLCMediaPlayerTrack *track = audioTracks[i];
        NSString *trackTitle = track.trackName ?: [NSString stringWithFormat:@"Track %ld", (long)i];
        
        // Mark currently selected track
        if (track.selected) {
            trackTitle = [NSString stringWithFormat:@"✓ %@", trackTitle];
        }
        
        UIAlertAction *trackAction = [UIAlertAction actionWithTitle:trackTitle
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(UIAlertAction * _Nonnull action) {
            [self.player deselectAllAudioTracks];
            track.selectedExclusively = YES;
            NSLog(@"📱 [MAC-DROPDOWN] Selected audio: %@", track.trackName);
        }];
        [actionSheet addAction:trackAction];
    }
    
    // Add cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    [actionSheet addAction:cancelAction];
    
    // Present the action sheet
    [self presentActionSheet:actionSheet];
}

// Helper methods for presenting alerts
- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil];
    [alert addAction:okAction];
    
    [self presentAlert:alert];
}

- (void)presentActionSheet:(UIAlertController *)actionSheet {
    NSLog(@"📱 [PRESENTATION-DEBUG] presentActionSheet called with title: %@", actionSheet.title);
    
    // Find the view controller to present from
    UIViewController *presentingVC = nil;
    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            presentingVC = (UIViewController *)responder;
            break;
        }
        responder = [responder nextResponder];
    }
    
    if (!presentingVC) {
        // Try to get from window
        UIWindow *window = self.window;
        if (!window && [UIApplication sharedApplication].windows.count > 0) {
            window = [UIApplication sharedApplication].windows[0];
        }
        presentingVC = window.rootViewController;
    }
    
    if (presentingVC) {
        // Configure for iPad (popover)
        if (actionSheet.popoverPresentationController) {
            actionSheet.popoverPresentationController.sourceView = self;
            actionSheet.popoverPresentationController.sourceRect = CGRectMake(self.bounds.size.width/2, self.bounds.size.height/2, 1, 1);
        }
        
        NSLog(@"📱 [PRESENTATION-DEBUG] Found presenting VC: %@", NSStringFromClass([presentingVC class]));
        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"📱 [PRESENTATION-DEBUG] Presenting action sheet on main queue");
            [presentingVC presentViewController:actionSheet animated:YES completion:^{
                NSLog(@"📱 [PRESENTATION-DEBUG] Action sheet presentation completed");
            }];
        });
    } else {
        NSLog(@"📱 [MAC-DROPDOWN] Could not find presenting view controller");
        NSLog(@"📱 [PRESENTATION-DEBUG] CRITICAL: No presenting view controller found!");
    }
}

- (void)presentAlert:(UIAlertController *)alert {
    // Find the view controller to present from
    UIViewController *presentingVC = nil;
    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            presentingVC = (UIViewController *)responder;
            break;
        }
        responder = [responder nextResponder];
    }
    
    if (!presentingVC) {
        UIWindow *window = self.window;
        if (!window && [UIApplication sharedApplication].windows.count > 0) {
            window = [UIApplication sharedApplication].windows[0];
        }
        presentingVC = window.rootViewController;
    }
    
    if (presentingVC) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [presentingVC presentViewController:alert animated:YES completion:nil];
        });
    }
}

#pragma mark - Responsive Layout Helpers

- (CGFloat)categoryWidth {
    CGFloat screenWidth = self.bounds.size.width;
    
    // Landscape-only optimized calculations
    if (screenWidth <= 667) {
        // iPhone in landscape (iPhone 6/7/8 and smaller)
        return MAX(120, screenWidth * 0.16); // 16% of screen width, minimum 120
    } else if (screenWidth <= 844) {
        // Larger iPhones in landscape (iPhone X/11/12/13/14 series)
        return MAX(130, screenWidth * 0.15); // 15% of screen width, minimum 130
    } else if (screenWidth <= 1024) {
        // iPad in landscape
        return MAX(140, screenWidth * 0.14); // 14% of screen width, minimum 140
    } else if (screenWidth <= 1366) {
        // Large iPad Pro in landscape
        return MAX(160, screenWidth * 0.12); // 12% of screen width, minimum 160
    } else {
        // Apple TV or very large displays
        return MAX(180, screenWidth * 0.10); // 10% of screen width, minimum 180
    }
}

- (CGFloat)groupWidth {
    CGFloat screenWidth = self.bounds.size.width;
    
    // Landscape-only optimized calculations
    if (screenWidth <= 667) {
        // iPhone in landscape (iPhone 6/7/8 and smaller)
        return MAX(140, screenWidth * 0.19); // 19% of screen width, minimum 140
    } else if (screenWidth <= 844) {
        // Larger iPhones in landscape (iPhone X/11/12/13/14 series)
        return MAX(150, screenWidth * 0.18); // 18% of screen width, minimum 150
    } else if (screenWidth <= 1024) {
        // iPad in landscape
        return MAX(160, screenWidth * 0.17); // 17% of screen width, minimum 160
    } else if (screenWidth <= 1366) {
        // Large iPad Pro in landscape
        return MAX(180, screenWidth * 0.15); // 15% of screen width, minimum 180
    } else {
        // Apple TV or very large displays
        return MAX(200, screenWidth * 0.12); // 12% of screen width, minimum 200
    }
}

- (CGFloat)programGuideWidth {
    CGFloat screenWidth = self.bounds.size.width;
    
    // Landscape-only optimized calculations - program guide can be more generous
    if (screenWidth <= 667) {
        // iPhone in landscape - compact program guide
        return MAX(150, screenWidth * 0.22); // 22% of screen width, minimum 150
    } else if (screenWidth <= 844) {
        // Larger iPhones in landscape 
        return MAX(180, screenWidth * 0.24); // 24% of screen width, minimum 180
    } else if (screenWidth <= 1024) {
        // iPad in landscape
        return MAX(220, screenWidth * 0.25); // 25% of screen width, minimum 220
    } else if (screenWidth <= 1366) {
        // Large iPad Pro in landscape
        return MAX(280, screenWidth * 0.28); // 28% of screen width, minimum 280
    } else {
        // Apple TV or very large displays
        return MAX(350, screenWidth * 0.30); // 30% of screen width, minimum 350
    }
}

- (CGFloat)gridItemWidth {
    CGFloat availableWidth = self.bounds.size.width - [self categoryWidth] - [self groupWidth];
    CGFloat itemsPerRow = floor(availableWidth / 220); // Aim for ~220pt wide items
    itemsPerRow = MAX(2, itemsPerRow); // At least 2 items per row
    return (availableWidth - (itemsPerRow - 1) * 10) / itemsPerRow; // 10pt spacing between items
}

// Smaller retina-optimized font sizes for iOS landscape mode
- (CGFloat)categoryFontSize {
    CGFloat screenWidth = self.bounds.size.width;
    CGFloat scale = [[UIScreen mainScreen] scale]; // Retina scale factor
    
    if (screenWidth <= 667) {
        return scale >= 3.0 ? 11 : 12; // iPhone in landscape - smaller for retina
    } else if (screenWidth <= 844) {
        return scale >= 3.0 ? 12 : 13; // Larger iPhones in landscape
    } else if (screenWidth <= 1024) {
        return scale >= 2.0 ? 13 : 14; // iPad in landscape
    } else if (screenWidth <= 1366) {
        return scale >= 2.0 ? 14 : 15; // Large iPad Pro in landscape
    } else {
        return 16; // Apple TV or very large displays
    }
}

- (CGFloat)groupFontSize {
    CGFloat screenWidth = self.bounds.size.width;
    CGFloat scale = [[UIScreen mainScreen] scale]; // Retina scale factor
    
    if (screenWidth <= 667) {
        return scale >= 3.0 ? 9 : 10; // iPhone in landscape - smaller for retina
    } else if (screenWidth <= 844) {
        return scale >= 3.0 ? 10 : 11; // Larger iPhones in landscape
    } else if (screenWidth <= 1024) {
        return scale >= 2.0 ? 11 : 12; // iPad in landscape
    } else if (screenWidth <= 1366) {
        return scale >= 2.0 ? 12 : 13; // Large iPad Pro in landscape
    } else {
        return 14; // Apple TV or very large displays
    }
}

- (CGFloat)channelFontSize {
    CGFloat screenWidth = self.bounds.size.width;
    CGFloat scale = [[UIScreen mainScreen] scale]; // Retina scale factor
    
    if (screenWidth <= 667) {
        return scale >= 3.0 ? 10 : 11; // iPhone in landscape - smaller for retina
    } else if (screenWidth <= 844) {
        return scale >= 3.0 ? 11 : 12; // Larger iPhones in landscape
    } else if (screenWidth <= 1024) {
        return scale >= 2.0 ? 12 : 13; // iPad in landscape
    } else if (screenWidth <= 1366) {
        return scale >= 2.0 ? 13 : 14; // Large iPad Pro in landscape
    } else {
        return 15; // Apple TV or very large displays
    }
}

- (CGFloat)channelNumberFontSize {
    CGFloat screenWidth = self.bounds.size.width;
    CGFloat scale = [[UIScreen mainScreen] scale]; // Retina scale factor
    
    if (screenWidth <= 667) {
        return scale >= 3.0 ? 8 : 9; // iPhone in landscape - very small for retina
    } else if (screenWidth <= 844) {
        return scale >= 3.0 ? 9 : 10; // Larger iPhones in landscape
    } else if (screenWidth <= 1024) {
        return scale >= 2.0 ? 10 : 11; // iPad in landscape
    } else if (screenWidth <= 1366) {
        return scale >= 2.0 ? 11 : 12; // Large iPad Pro in landscape
    } else {
        return 12; // Apple TV or very large displays
    }
}

- (CGFloat)rowHeight {
    CGFloat screenWidth = self.bounds.size.width;
    CGFloat scale = [[UIScreen mainScreen] scale]; // Retina scale factor
    
    if (screenWidth <= 667) {
        return scale >= 3.0 ? 32 : 36; // iPhone in landscape - smaller rows for retina
    } else if (screenWidth <= 844) {
        return scale >= 3.0 ? 34 : 38; // Larger iPhones in landscape
    } else if (screenWidth <= 1024) {
        return scale >= 2.0 ? 36 : 40; // iPad in landscape
    } else if (screenWidth <= 1366) {
        return scale >= 2.0 ? 38 : 42; // Large iPad Pro in landscape
    } else {
        return 44; // Apple TV or very large displays
    }
}

#pragma mark - Font Caching (Memory Management)

// Invalidate font caches when view size changes to prevent memory leaks
- (void)invalidateFontCaches {
    [_cachedCategoryFont release];
    _cachedCategoryFont = nil;
    [_cachedGroupFont release];
    _cachedGroupFont = nil;
    [_cachedChannelFont release];
    _cachedChannelFont = nil;
    [_cachedChannelNumberFont release];
    _cachedChannelNumberFont = nil;
    _cachedScreenWidth = 0;
    _cachedScreenScale = 0;
}

- (UIFont *)getCachedCategoryFont {
    CGFloat currentWidth = CGRectGetWidth(self.bounds);
    CGFloat currentScale = [[UIScreen mainScreen] scale];
    
    if (!_cachedCategoryFont || _cachedScreenWidth != currentWidth || _cachedScreenScale != currentScale) {
        _cachedScreenWidth = currentWidth;
        _cachedScreenScale = currentScale;
        
        CGFloat fontSize = [self categoryFontSize];
        [_cachedCategoryFont release];
        _cachedCategoryFont = [[UIFont boldSystemFontOfSize:fontSize] retain];
    }
    return _cachedCategoryFont ?: [UIFont boldSystemFontOfSize:[self categoryFontSize]];
}

- (UIFont *)getCachedGroupFont {
    CGFloat currentWidth = CGRectGetWidth(self.bounds);
    CGFloat currentScale = [[UIScreen mainScreen] scale];
    
    if (!_cachedGroupFont || _cachedScreenWidth != currentWidth || _cachedScreenScale != currentScale) {
        CGFloat fontSize = [self groupFontSize];
        [_cachedGroupFont release];
        _cachedGroupFont = [[UIFont systemFontOfSize:fontSize weight:UIFontWeightMedium] retain];
    }
    return _cachedGroupFont ?: [UIFont systemFontOfSize:[self groupFontSize] weight:UIFontWeightMedium];
}

- (UIFont *)getCachedChannelFont {
    CGFloat currentWidth = CGRectGetWidth(self.bounds);
    CGFloat currentScale = [[UIScreen mainScreen] scale];
    
    if (!_cachedChannelFont || _cachedScreenWidth != currentWidth || _cachedScreenScale != currentScale) {
        CGFloat fontSize = [self channelFontSize];
        [_cachedChannelFont release];
        _cachedChannelFont = [[UIFont systemFontOfSize:fontSize weight:UIFontWeightRegular] retain];
    }
    return _cachedChannelFont ?: [UIFont systemFontOfSize:[self channelFontSize] weight:UIFontWeightRegular];
}

- (UIFont *)getCachedChannelNumberFont {
    CGFloat currentWidth = CGRectGetWidth(self.bounds);
    CGFloat currentScale = [[UIScreen mainScreen] scale];
    
    if (!_cachedChannelNumberFont || _cachedScreenWidth != currentWidth || _cachedScreenScale != currentScale) {
        CGFloat fontSize = [self channelNumberFontSize];
        [_cachedChannelNumberFont release];
        _cachedChannelNumberFont = [[UIFont systemFontOfSize:fontSize weight:UIFontWeightBold] retain];
    }
    return _cachedChannelNumberFont ?: [UIFont systemFontOfSize:[self channelNumberFontSize] weight:UIFontWeightBold];
}

// Memory monitoring to prevent crashes
- (NSUInteger)getCurrentMemoryUsageMB {
    struct mach_task_basic_info info;
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &size);
    
    if (kerr == KERN_SUCCESS) {
        NSUInteger memoryMB = info.resident_size / (1024 * 1024);
        return memoryMB;
    }
    return 0;
}



- (NSUInteger)getCurrentMemoryUsageBytes {
    struct task_basic_info info;
    mach_msg_type_number_t size = sizeof(info);
    kern_return_t kerr = task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &size);
    if (kerr == KERN_SUCCESS) {
        return info.resident_size;
    }
    return 0;
}

- (NSUInteger)getAvailableMemoryMB {
    // Get total system memory
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    NSUInteger totalMemoryMB = (NSUInteger)(processInfo.physicalMemory / (1024 * 1024));
    
    // Get current app memory usage
    NSUInteger currentUsageMB = [self getCurrentMemoryUsageMB];
    
    // iOS typically allows apps to use ~30% of total memory before warnings
    // For conservative estimate, assume we can use 25% of total memory
    NSUInteger maxAllowedMB = (totalMemoryMB * 25) / 100;
    
    if (currentUsageMB >= maxAllowedMB) {
        return 0; // No available memory
    }
    
    return maxAllowedMB - currentUsageMB;
}

- (void)logMemoryUsage:(NSString *)context {
    NSUInteger memoryMB = [self getCurrentMemoryUsageMB];
    NSLog(@"📊 Memory usage at %@: %luMB", context, (unsigned long)memoryMB);
    
    if (memoryMB > 200) {
        NSLog(@"🚨 CRITICAL MEMORY WARNING: %luMB - triggering emergency cleanup!", (unsigned long)memoryMB);
        [self emergencyMemoryCleanup];
    } else if (memoryMB > 150) {
        NSLog(@"⚠️ HIGH MEMORY WARNING: %luMB - risk of crash!", (unsigned long)memoryMB);
    }
}

- (void)emergencyMemoryCleanup {
    NSLog(@"🧹 EMERGENCY MEMORY CLEANUP - freeing all possible memory");
    return;
    // This can be called from background thread during M3U processing
    // Only do thread-safe operations here
    
    // Cancel any ongoing downloads
    [self cancelAllDownloads];
    
    // Clear font caches (thread-safe)
    [self invalidateFontCaches];
    
    // Clear any cached drawing data (thread-safe)
    _lastDrawTime = nil;
    
    // Force garbage collection of autoreleased objects
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    
    // UI cleanup must be done on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        // Remove UI elements that aren't critical
        if (_settingsScrollViewiOS && _settingsScrollViewiOS.hidden) {
            [_settingsScrollViewiOS removeFromSuperview];
            [_settingsScrollViewiOS release];
            _settingsScrollViewiOS = nil;
        }
    });
    
    NSLog(@"🧹 Emergency cleanup completed - memory freed");
}

// Memory cleanup to prevent crashes
- (void)cancelAllDownloads {
    if (_currentChannelDownloadTask) {
        [_currentChannelDownloadTask cancel];
        _currentChannelDownloadTask = nil;
    }
    
    if (_currentEPGDownloadTask) {
        [_currentEPGDownloadTask cancel];
        _currentEPGDownloadTask = nil;
    }
    
    _isDownloadingChannels = NO;
    _isDownloadingEPG = NO;
}

- (void)dealloc {
    NSLog(@"🧹 VLCUIOverlayView dealloc - cleaning up memory");
    
    // Stop auto-alignment timer
    [self stopAutoAlignmentTimer];
    
    // Cancel any ongoing downloads
    [self cancelAllDownloads];
    
    // Stop all momentum animations to prevent crashes
    [self stopAllMomentumAnimations];
    
    // Invalidate font caches
    [self invalidateFontCaches];
    
    // Clean up data manager
    if (_dataManager) {
        _dataManager.delegate = nil;
        [_dataManager release];
        _dataManager = nil;
    }
    
    // Clean up UI elements
    if (_settingsScrollViewiOS) {
        [_settingsScrollViewiOS removeFromSuperview];
        [_settingsScrollViewiOS release];
        _settingsScrollViewiOS = nil;
    }
    
    if (_loadingPaneliOS) {
        [_loadingPaneliOS removeFromSuperview];
        [_loadingPaneliOS release];
        _loadingPaneliOS = nil;
    }
    
    // Clean up progress bar scrubbing UI
    if (_timePreviewOverlay) {
        [_timePreviewOverlay removeFromSuperview];
        [_timePreviewOverlay release];
        _timePreviewOverlay = nil;
    }
    
    if (_timePreviewLabel) {
        [_timePreviewLabel release];
        _timePreviewLabel = nil;
    }
    
#if TARGET_OS_TV
    [self stopContinuousScrolling];
#endif

    [super dealloc];
}

// Handle memory warnings to prevent crashes
- (void)didReceiveMemoryWarning {
    NSLog(@"⚠️ Memory warning received - cleaning up caches");
    
    // Cancel downloads to free memory
    [self cancelAllDownloads];
    
    // Clear font caches
    [self invalidateFontCaches];
    
    // Force garbage collection
    if (_settingsScrollViewiOS && _settingsScrollViewiOS.hidden) {
        [_settingsScrollViewiOS removeFromSuperview];
    }
}

// Synthesize data properties (shared with macOS)
@synthesize channels = _channels;
@synthesize groups = _groups;
@synthesize channelsByGroup = _channelsByGroup;
@synthesize categories = _categories;
@synthesize groupsByCategory = _groupsByCategory;
@synthesize simpleChannelNames = _simpleChannelNames;
@synthesize simpleChannelUrls = _simpleChannelUrls;

// Synthesize UI state
@synthesize isChannelListVisible = _isChannelListVisible;
@synthesize selectedCategoryIndex = _selectedCategoryIndex;
@synthesize selectedGroupIndex = _selectedGroupIndex;
@synthesize hoveredChannelIndex = _hoveredChannelIndex;

// Data manager property accessor
- (VLCDataManager *)dataManager {
    return _dataManager;
}

- (void)setDataManager:(VLCDataManager *)dataManager {
    if (_dataManager != dataManager) {
        if (_dataManager) {
            _dataManager.delegate = nil;
            [_dataManager release];
        }
        _dataManager = [dataManager retain];
        _dataManager.delegate = self;
        NSLog(@"🔧 [iOS] DataManager set: %@", _dataManager);
    }
}
@synthesize selectedChannelIndex = _selectedChannelIndex;

// Synthesize colors (backgroundColor inherited from UIView)
@synthesize hoverColor = _hoverColor;
@synthesize textColor = _textColor;
@synthesize groupColor = _groupColor;

// Synthesize theme colors
@synthesize themeChannelStartColor = _themeChannelStartColor;
@synthesize themeChannelEndColor = _themeChannelEndColor;
@synthesize themeAlpha = _themeAlpha;

#if TARGET_OS_TV
// Synthesize tvOS continuous scrolling properties
@synthesize continuousScrollTimer = _continuousScrollTimer;
@synthesize currentPressType = _currentPressType;
#endif

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    NSLog(@"🎬 iOS VLCUIOverlayView initWithFrame - minimal initialization");
    self = [super initWithFrame:frame];
    if (self) {
        
        // we need that here, otherwise it crashed
        _groupsByCategory = [[NSMutableDictionary alloc] init];
        // Set other categories with empty arrays
        for (NSString *category in @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES"]) {
            [_groupsByCategory setObject:[NSMutableArray array] forKey:category];
        }
        _channelsByGroup = [[NSMutableDictionary alloc] init];
        //end
        
        NSLog(@"🎬 Testing initializeThemeSystemiOS...");
        [self initializeThemeSystemiOS];
        NSLog(@"🎬 initializeThemeSystemiOS completed");
        
        NSLog(@"🎬 Testing setupView...");
        [self setupView];
        NSLog(@"🎬 setupView completed");
        
      
        
            NSLog(@"🎬 Data structures handled by VLCDataManager automatically");
        
        NSLog(@"🎬 Initializing VLCDataManager...");
        // Use VLCDataManager singleton to ensure we use the same instance across the app
        _dataManager = [VLCDataManager sharedManager];
        _dataManager.delegate = self;
        NSLog(@"🎬 Using VLCDataManager shared instance");
        
        // CRITICAL FIX: Listen for EPG matching completion to refresh UI
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(epgMatchingCompleted:) 
                                                     name:@"VLCEPGMatchingCompleted" 
                                                   object:nil];
        
        // PERFORMANCE FIX: Listen for progressive EPG matching updates
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(epgMatchingProgress:) 
                                                     name:@"VLCEPGMatchingProgress" 
                                                   object:nil];
        
        NSLog(@"🎬 Testing setupGestures...");
        [self setupGestures];
        NSLog(@"🎬 setupGestures completed");
        
        NSLog(@"🎬 Testing setupDrawingLayers...");
        [self setupDrawingLayers];
        NSLog(@"🎬 setupDrawingLayers completed");
        
        NSLog(@"🎬 Starting iOS startup sequence...");
        [self performStartupSequence];
        NSLog(@"🎬 iOS startup sequence initiated");
        
        NSLog(@"🎬 VLCUIOverlayView full initialization completed successfully!");
    }
    return self;
}



- (void)setupView {
    NSLog(@"🎬 setupView - testing minimal version");
    self.backgroundColor = [UIColor clearColor];
    
    // Test with scroll positions added
    NSLog(@"🎬 setupView - adding scroll positions");
    
    // Initialize scroll positions
    _categoryScrollPosition = 0;
    _groupScrollPosition = 0;
    _channelScrollPosition = 0;
    
    NSLog(@"🎬 setupView - scroll positions completed");
    
    // Test with UI state initialization
    NSLog(@"🎬 setupView - adding UI state");
    
    // Initialize UI state (show channel list by default for testing)
    _isChannelListVisible = YES;
    _selectedCategoryIndex = CATEGORY_FAVORITES;
    _selectedGroupIndex = -1;
    _hoveredChannelIndex = -1;
    _selectedChannelIndex = -1;
    _currentViewMode = VIEW_MODE_STACKED;
    _isGridViewActive = NO;
    _isStackedViewActive = YES;
    
    // Initialize memory constraints - DISABLED to allow full channel lists
    _maxChannelsPerGroup = NSUIntegerMax;   // No limit on channels per group
    _maxTotalChannels = NSUIntegerMax;      // No limit on total channels
    _isMemoryConstrained = NO;              // Disable memory constraints to load full lists
    
    NSLog(@"🎬 setupView - UI state completed");
    
    // Test with color setup - one at a time
    NSLog(@"🎬 setupView - testing first color assignment");
    
    // Setup all colors (backgroundColor conflict resolved)
    _hoverColor = [UIColor colorWithRed:0.15 green:0.3 blue:0.6 alpha:0.6];
    _textColor = [UIColor whiteColor];
    _groupColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.85];
    self.themeChannelStartColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:0.7];
    self.themeChannelEndColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.18 alpha:0.7];
    _themeAlpha = 0.9;
    
    NSLog(@"🎬 setupView - all colors completed successfully");
    
    // Initialize data structures
    self.m3uFilePath = @"";
    self.epgUrl = @"";
    self.isLoading = NO;
    
    // Initialize progress window state flags
    self.isStartupInProgress = NO;
    self.isManualLoadingInProgress = NO;
    self.isLoadingBothChannelsAndEPG = NO;
    
    NSLog(@"🎬 setupView - all initialization completed successfully");
}

- (void)performStartupSequence {
    NSLog(@"🚀 iOS performStartupSequence - loading settings and cache");
    [self logMemoryUsage:@"app startup"];
    
    // Load settings synchronously first (like macOS)
    NSLog(@"📋 Loading settings...");
    [self loadSettings];
    NSLog(@"📋 Settings loaded - M3U path: %@", self.m3uFilePath ? self.m3uFilePath : @"(nil)");
    
    [self loadThemeSettings];
    [self loadViewModePreference];
    
    // Ensure we have a valid M3U path
    if (!self.m3uFilePath || [self.m3uFilePath length] == 0) {
        NSLog(@"⚠️ No M3U path found in settings - first run detected");
        // For first run, set up example settings to show the settings panel
        self.m3uFilePath = @""; // Keep empty to show settings panel
        NSLog(@"📁 First run - settings panel will be shown");
        
        // Initialize default EPG time offset
        self.epgTimeOffsetHours = 0.0;
        
        // Initialize default selection colors (blue theme)
        self.customSelectionRed = 0.15;
        self.customSelectionGreen = 0.3;
        self.customSelectionBlue = 0.6;
    } else {
        NSLog(@"📁 Existing M3U path loaded: %@", self.m3uFilePath);
    }
    
    // Always regenerate EPG URL from M3U URL to ensure it's correct (overrides any saved incorrect URLs)
    if (self.m3uFilePath && [self.m3uFilePath hasPrefix:@"http"]) {
        // Generate EPG URL from M3U URL (like the macOS settings do)
        NSString *generatedEpgUrl = [self.m3uFilePath stringByReplacingOccurrencesOfString:@"get.php" withString:@"xmltv.php"];
        if (![generatedEpgUrl isEqualToString:self.m3uFilePath]) {
            self.epgUrl = generatedEpgUrl;
            NSLog(@"📅 ✅ EPG URL regenerated from M3U: %@", self.epgUrl);
            [self saveSettings]; // Save the corrected EPG URL
        }
    }
    
    // Startup sequence is now handled by AppDelegate via universal VLCDataManager
    // No need for duplicate iOS-specific startup logic
    NSLog(@"🎬 iOS startup sequence will be handled by AppDelegate - no duplicate logic needed");
    
    // Schedule auto-alignment timer to start after app is fully loaded
    dispatch_async(dispatch_get_main_queue(), ^{
        [self checkAndStartAutoAlignmentTimer];
    });
}

- (void)setupDrawingLayers {
    NSLog(@"🎨 iOS setupDrawingLayers - disabled for testing");
    // CALayer setup disabled for testing to avoid potential issues
    /*
    // Create separate layers for each UI component for efficient drawing
    _categoriesLayer = [CALayer layer];
    _categoriesLayer.frame = CGRectMake(0, 0, CATEGORY_WIDTH, self.bounds.size.height);
    [self.layer addSublayer:_categoriesLayer];
    
    _groupsLayer = [CALayer layer];
    _groupsLayer.frame = CGRectMake(CATEGORY_WIDTH, 0, GROUP_WIDTH, self.bounds.size.height);
    [self.layer addSublayer:_groupsLayer];
    
    _channelListLayer = [CALayer layer];
    CGFloat channelListWidth = self.bounds.size.width - CATEGORY_WIDTH - GROUP_WIDTH - 400; // 400 for program guide
    _channelListLayer.frame = CGRectMake(CATEGORY_WIDTH + GROUP_WIDTH, 0, channelListWidth, self.bounds.size.height);
    [self.layer addSublayer:_channelListLayer];
    
    _programGuideLayer = [CALayer layer];
    _programGuideLayer.frame = CGRectMake(self.bounds.size.width - 400, 0, 400, self.bounds.size.height);
    [self.layer addSublayer:_programGuideLayer];
    */
}

#pragma mark - Gesture Setup

- (void)setupGestures {
    #if TARGET_OS_IOS
    NSLog(@"👆 iOS setupGestures - enabling gestures with scroll priority");
    
    // Single tap to interact with UI elements - add this FIRST to get priority
    _singleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
    _singleTapGesture.numberOfTapsRequired = 1;
    _singleTapGesture.delaysTouchesEnded = NO; // Immediate response
    _singleTapGesture.delaysTouchesBegan = NO; // Immediate response
    [self addGestureRecognizer:_singleTapGesture];
    
    // Pan gesture for scrolling - should fail if single tap succeeds
    _panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
    // Touch properties only available on iOS
    _panGesture.minimumNumberOfTouches = 1;
    _panGesture.maximumNumberOfTouches = 1;
    _panGesture.delaysTouchesEnded = YES; // Allow tap to process first
    _panGesture.delaysTouchesBegan = YES; // Allow tap to process first
    // ANTI-FLICKER: Make pan gesture much less sensitive
    _panGesture.cancelsTouchesInView = NO; // Don't interfere with other touches
    [_panGesture requireGestureRecognizerToFail:_singleTapGesture];
    [self addGestureRecognizer:_panGesture];
    
    // Double tap to toggle fullscreen (iOS only)
    _doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    _doubleTapGesture.numberOfTapsRequired = 2;
    [self addGestureRecognizer:_doubleTapGesture];
    [_singleTapGesture requireGestureRecognizerToFail:_doubleTapGesture];
    
    // Long press for context menu with favorites
    _longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    _longPressGesture.minimumPressDuration = 1.0; // 1 second
    _longPressGesture.delegate = self;
    [self addGestureRecognizer:_longPressGesture];
    
    // Progress bar pan gesture for scrubbing
    _progressBarPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleProgressBarPan:)];
    _progressBarPanGesture.delegate = self;
    [self addGestureRecognizer:_progressBarPanGesture];
    
    // Initialize auto-hide timer for iOS/tvOS
    [self resetAutoHideTimer];
    #endif
    
    #if TARGET_OS_TV
    //NSLog(@"📺 tvOS setupGestures - enabling focus engine only");
    // Apple TV: Add focus engine support
    [self setupFocusEngine];
    #endif
}

#if TARGET_OS_TV
- (void)setupFocusEngine {
    // Make the view focusable for Apple TV remote navigation
    //NSLog(@"📺 Setting up tvOS focus engine");
    
    // Enable focus for this view
    [self setUserInteractionEnabled:YES];
    
    // Initialize focus state - start with TV category instead of SEARCH
    _selectedCategoryIndex = CATEGORY_TV; // Start with TV category (index 2) instead of SEARCH (index 0)
    
    // Initialize favorites category to ensure it's available for navigation
    [self ensureFavoritesCategory];
    NSLog(@"📺 [INIT] Starting with TV category (index %ld), FAVORITES category initialized", (long)_selectedCategoryIndex);
    _selectedGroupIndex = 0;
    _selectedChannelIndex = 0;
    _tvosNavigationArea = 0;
    _tvosSelectedSettingsControl = 0;
    
    // Show the menu by default on tvOS
    _isChannelListVisible = YES;
    
    // Initialize data structures - handled by VLCDataManager automatically
}

- (BOOL)canBecomeFocused {
    return YES;
}

- (void)didUpdateFocusInContext:(UIFocusUpdateContext *)context withAnimationCoordinator:(UIFocusAnimationCoordinator *)coordinator {
    [super didUpdateFocusInContext:context withAnimationCoordinator:coordinator];
    
    // Update display when focus changes
    [coordinator addCoordinatedAnimations:^{
        [self setNeedsDisplay];
    } completion:nil];
    
    //NSLog(@"📺 tvOS focus updated");
}

// Handle Apple TV remote button presses
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    BOOL handled = NO;
    
    for (UIPress *press in presses) {
        switch (press.type) {
            case UIPressTypeSelect: {
                // Handle center button press (selection)
                //NSLog(@"📺 tvOS Select button pressed");
                [self startTVOSSelectLongPressDetection];
                handled = YES;
                break;
            }
            case UIPressTypeMenu: {
                // Handle Menu button press (back/menu)
                //NSLog(@"📺 tvOS Menu button pressed");
                [self handleTVOSMenuPress];
                handled = YES;
                break;
            }
            case UIPressTypeUpArrow: {
                //NSLog(@"📺 tvOS Up arrow pressed");
                [self handleTVOSNavigationUp];
                [self startContinuousScrolling:UIPressTypeUpArrow];
                handled = YES;
                break;
            }
            case UIPressTypeDownArrow: {
                //NSLog(@"📺 tvOS Down arrow pressed");
                [self handleTVOSNavigationDown];
                [self startContinuousScrolling:UIPressTypeDownArrow];
                handled = YES;
                break;
            }
            case UIPressTypeLeftArrow: {
                //NSLog(@"📺 tvOS Left arrow pressed");
                [self handleTVOSNavigationLeft];
                [self startContinuousScrolling:UIPressTypeLeftArrow];
                handled = YES;
                break;
            }
            case UIPressTypeRightArrow: {
                //NSLog(@"📺 tvOS Right arrow pressed");
                [self handleTVOSNavigationRight];
                [self startContinuousScrolling:UIPressTypeRightArrow];
                handled = YES;
                break;
            }
            case UIPressTypePlayPause: {
                //NSLog(@"📺 tvOS Play/Pause button pressed");
                [self handleTVOSPlayPause];
                handled = YES;
                break;
            }
            default:
                break;
        }
    }
    
    if (!handled) {
        [super pressesBegan:presses withEvent:event];
    }
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    // Handle button release events
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect) {
            [self endTVOSSelectLongPressDetection];
        }
    }
    
    // Stop continuous scrolling when button is released
    [self stopContinuousScrolling];
    [super pressesEnded:presses withEvent:event];
}

- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    // Handle button cancellation events
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect) {
            [self cancelTVOSSelectLongPressDetection];
        }
    }
    
    // Stop continuous scrolling if presses are cancelled
    [self stopContinuousScrolling];
    [super pressesCancelled:presses withEvent:event];
}

#pragma mark - tvOS Continuous Scrolling

#if TARGET_OS_TV
- (void)startContinuousScrolling:(UIPressType)pressType {
    // Stop any existing timer
    [self stopContinuousScrolling];
    
    // Store the current press type
    _currentPressType = pressType;
    
    // Start continuous scrolling after initial delay
    _continuousScrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 // Initial delay
                                                              target:self
                                                            selector:@selector(continuousScrollTimerFired:)
                                                            userInfo:nil
                                                             repeats:NO];
}

- (void)stopContinuousScrolling {
    if (_continuousScrollTimer) {
        [_continuousScrollTimer invalidate];
        _continuousScrollTimer = nil;
    }
}

- (void)continuousScrollTimerFired:(NSTimer *)timer {
    // Start fast repeating timer for continuous scrolling
    _continuousScrollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 // Fast repeat interval
                                                              target:self
                                                            selector:@selector(performContinuousScroll:)
                                                            userInfo:nil
                                                             repeats:YES];
}

- (void)performContinuousScroll:(NSTimer *)timer {
    // Perform the appropriate navigation action based on stored press type
    switch (_currentPressType) {
        case UIPressTypeUpArrow:
            [self handleTVOSNavigationUp];
            break;
        case UIPressTypeDownArrow:
            [self handleTVOSNavigationDown];
            break;
        case UIPressTypeLeftArrow:
            [self handleTVOSNavigationLeft];
            break;
        case UIPressTypeRightArrow:
            [self handleTVOSNavigationRight];
            break;
        default:
            // Unknown press type, stop scrolling
            [self stopContinuousScrolling];
            break;
    }
}

#pragma mark - tvOS Long Press Detection

- (void)startTVOSSelectLongPressDetection {
    // Cancel any existing timer
    [self cancelTVOSSelectLongPressDetection];
    
    // Start timer for long press detection (1.5 seconds)
    _selectLongPressTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                             target:self
                                                           selector:@selector(handleTVOSSelectLongPress)
                                                           userInfo:nil
                                                            repeats:NO];
    
    NSLog(@"📺 [TVOS-LONG] Started long press detection");
}

- (void)endTVOSSelectLongPressDetection {
    if (_selectLongPressTimer && _selectLongPressTimer.isValid) {
        // Timer is still active = short press
        [self cancelTVOSSelectLongPressDetection];
        [self handleTVOSSelectPress];
        NSLog(@"📺 [TVOS-LONG] Short press detected - normal selection");
    }
}

- (void)cancelTVOSSelectLongPressDetection {
    if (_selectLongPressTimer) {
        [_selectLongPressTimer invalidate];
        _selectLongPressTimer = nil;
    }
}

- (void)handleTVOSSelectLongPress {
    _selectLongPressTimer = nil;
    
    NSLog(@"📺 [TVOS-LONG] Long press detected!");
    
    // Check for favorites functionality first in channels and groups
    if (_tvosNavigationArea == 2 && _selectedCategoryIndex != CATEGORY_SETTINGS) {
        // Long press on channel - show favorites context menu
        VLCChannel *channel = [self getChannelAtIndex:_selectedChannelIndex];
        if (channel) {
            NSLog(@"📺 [TVOS-LONG] Long press on channel: %@", channel.name);
            [self showTVOSContextMenuForChannel:channel];
            return;
        }
    } else if (_tvosNavigationArea == 1 && _selectedCategoryIndex != CATEGORY_SETTINGS) {
        // Long press on group - show favorites context menu
        NSArray *groups = [self getGroupsForSelectedCategory];
        if (_selectedGroupIndex >= 0 && _selectedGroupIndex < groups.count) {
            NSString *groupName = groups[_selectedGroupIndex];
            NSLog(@"📺 [TVOS-LONG] Long press on group: %@", groupName);
            [self showTVOSContextMenuForGroup:groupName];
            return;
        }
    }
    
    // Check if we're in EPG area and have a selected program with catchup
    if (_tvosNavigationArea == 3 && _selectedCategoryIndex != CATEGORY_SETTINGS && self.epgNavigationMode) {
        VLCChannel *channel = [self getChannelAtIndex:_selectedChannelIndex];
        if (channel && channel.programs && channel.programs.count > 0 && self.selectedEpgProgramIndex >= 0) {
            // Sort programs by start time to match display order
            NSArray *sortedPrograms = [channel.programs sortedArrayUsingComparator:^NSComparisonResult(VLCProgram *a, VLCProgram *b) {
                return [a.startTime compare:b.startTime];
            }];
            
            if (self.selectedEpgProgramIndex < sortedPrograms.count) {
                VLCProgram *selectedProgram = sortedPrograms[self.selectedEpgProgramIndex];
                
                // Check if this is a past program with catchup available
                NSDate *now = [NSDate date];
                NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600;
                NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
                BOOL isPastProgram = ([adjustedNow timeIntervalSinceDate:selectedProgram.endTime] > 0);
                BOOL hasCatchup = ([VLCProgram hasArchiveForProgramObject:selectedProgram] || channel.supportsCatchup || channel.catchupDays > 0);
                
                if (isPastProgram && hasCatchup) {
                    NSLog(@"📺 [TVOS-LONG] Long press on catchup program - starting timeshift");
                    [self playTimeshiftProgram:selectedProgram channel:channel];
                    
                    // Hide menu after selection
                    _isChannelListVisible = NO;
                    self.epgNavigationMode = NO;
                    [self setNeedsDisplay];
                    return;
                } else if (isPastProgram) {
                    NSLog(@"📺 [TVOS-LONG] Long press on past program without catchup");
                } else {
                    NSLog(@"📺 [TVOS-LONG] Long press on current/future program");
                }
            }
        }
    }
    
    // If we get here, just do normal selection
    [self handleTVOSSelectPress];
}
#endif

#pragma mark - tvOS Navigation Handlers

- (void)handleTVOSSelectPress {
    if (!_isChannelListVisible && !_playerControlsVisible) {
        // Nothing is visible - OK button shows player controls
        [self showPlayerControls];
        NSLog(@"📺 [TVOS-OK] Showing player controls (nothing visible)");
        return;
    } else if (!_isChannelListVisible && _playerControlsVisible) {
        // Player controls visible - handle player control interaction
        if (_playerControlsNavigationMode) {
            // Handle selection within player controls
            switch (_selectedPlayerControl) {
                case 0: // Progress bar selected - no action (seeking done with left/right)
                    NSLog(@"📺 [PLAYER-CONTROLS] Progress bar selected (use left/right to seek)");
                    break;
                case 1: // CC button selected
                    NSLog(@"📺 [PLAYER-CONTROLS] CC button activated");
                    [self showSubtitleDropdownList];
                    break;
                case 2: // Audio button selected
                    NSLog(@"📺 [PLAYER-CONTROLS] Audio button activated");
                    [self showAudioDropdownList];
                    break;
            }
            // Restart timer after selection
            [self performSelector:@selector(restartTimerAfterNavigation) withObject:nil afterDelay:1.0];
        } else {
            // Not in navigation mode - just toggle play/pause
            [self handleTVOSPlayPause];
            // Restart timer after play/pause
            [self performSelector:@selector(restartTimerAfterNavigation) withObject:nil afterDelay:1.0];
        }
        return;
    }
    
    // Menu is visible - ensure player controls are hidden (like Mac mode)
    if (_playerControlsVisible) {
        [self hidePlayerControls];
        NSLog(@"📺 [TVOS-MENU-VISIBLE] Hiding player controls (Mac mode behavior)");
    }
    
    // Determine current navigation area and handle selection
    switch (_tvosNavigationArea) {
        case 0: // Categories
            [self handleTVOSCategorySelection];
            break;
        case 1: // Groups
            [self handleTVOSGroupSelection];
            break;
        case 2: // Channels
            [self handleTVOSChannelSelection];
            break;
        case 3: // Settings controls or Program Guide
            if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
            [self handleTVOSSettingsSelection];
            } else {
                [self handleTVOSEpgProgramSelection];
            }
            break;
    }
}

- (void)handleTVOSMenuPress {
    // Two-stage back behavior for player controls
    if (!_isChannelListVisible && _playerControlsVisible) {
        if (_playerControlsNavigationMode) {
            // First back: Exit player controls navigation mode
            _playerControlsNavigationMode = NO;
            _selectedPlayerControl = -1;
            NSLog(@"📺 [MENU-BACK] Exited player controls navigation mode");
            [self setNeedsDisplay];
            return;
        } else {
            // Second back: Hide player controls
            [self hidePlayerControls];
            NSLog(@"📺 [MENU-BACK] Hidden player controls");
            return;
        }
    }
    
    // Normal menu toggle behavior
    if (_isChannelListVisible) {
        [self hideAllSettingsScrollViews];
        _isChannelListVisible = NO;
    } else {
        _isChannelListVisible = YES;
    }
    [self setNeedsDisplay];
}

- (void)handleTVOSNavigationUp {
    // Stop auto-hide timer during active navigation to prevent menu from disappearing
    [self stopAutoHideTimer];
    
    // Special handling when menu is not visible but player controls are visible
    if (!_isChannelListVisible && _playerControlsVisible) {
        if (!_playerControlsNavigationMode) {
            // Enter player controls navigation mode
            _playerControlsNavigationMode = YES;
            _selectedPlayerControl = 0; // Start with progress bar
            NSLog(@"📺 [PLAYER-CONTROLS] Entered navigation mode - selected progress bar");
        } else {
            // Navigate DOWN in 2D grid (UP press should go down to buttons)
            if (_selectedPlayerControl == 0) {
                // From progress bar, go down to CC button (left button)
                _selectedPlayerControl = 1;
                NSLog(@"📺 [PLAYER-CONTROLS] Navigated DOWN to CC button (UP press)");
            }
            // If already on CC/Audio buttons, stay in same row
        }
        [self setNeedsDisplay];
        
        // Restart timer after navigation completes
        [self performSelector:@selector(restartTimerAfterNavigation) withObject:nil afterDelay:1.0];
        return;
    }
    
    if (!_isChannelListVisible) return;
    
    // Menu is visible - ensure player controls are hidden (like Mac mode)
    if (_playerControlsVisible) {
        [self hidePlayerControls];
        NSLog(@"📺 [TVOS-MENU-VISIBLE] Hiding player controls (Mac mode behavior)");
    }
    
    switch (_tvosNavigationArea) {
        case 0: // Categories
            if (_selectedCategoryIndex > 0) {
                _selectedCategoryIndex--;
            } else {
                // Wrap around to last category (SETTINGS)
                _selectedCategoryIndex = 5;
            }
            [self handleTVOSCategoryChange];
            NSLog(@"📺 [CATEGORY-NAV] UP - Selected category index: %ld", (long)_selectedCategoryIndex);
            break;
        case 1: // Groups
            if (_selectedGroupIndex > 0) {
                _selectedGroupIndex--;
                [self handleTVOSGroupScroll];
            }
            break;
        case 2: // Channels
            if (_selectedChannelIndex > 0) {
                _selectedChannelIndex--;
                [self handleTVOSChannelScroll];
                //NSLog(@"📺 ✅ tvOS UP - Set selectedChannelIndex to: %ld (should show program guide)", (long)_selectedChannelIndex);
            }
            break;
        case 3: // Settings controls or Program Guide
            if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
            [self handleTVOSSettingsNavigationUp];
            } else {
                [self handleTVOSProgramGuideNavigationUp];
            }
            break;
    }
    [self setNeedsDisplay];
}

- (void)handleTVOSNavigationDown {
    // Stop auto-hide timer during active navigation to prevent menu from disappearing
    [self stopAutoHideTimer];
    
    // Special handling when menu is not visible but player controls are visible
    if (!_isChannelListVisible && _playerControlsVisible) {
        if (!_playerControlsNavigationMode) {
            // Enter player controls navigation mode
            _playerControlsNavigationMode = YES;
            _selectedPlayerControl = 0; // Start with progress bar
            NSLog(@"📺 [PLAYER-CONTROLS] Entered navigation mode - selected progress bar");
        } else {
            // Navigate UP in 2D grid (DOWN press should go up to progress bar)
            if (_selectedPlayerControl == 1 || _selectedPlayerControl == 2) {
                // From CC/Audio buttons, go up to progress bar
                _selectedPlayerControl = 0;
                NSLog(@"📺 [PLAYER-CONTROLS] Navigated UP to progress bar (DOWN press)");
            }
            // If already on progress bar, stay there
        }
        [self setNeedsDisplay];
        
        // Restart timer after navigation completes
        [self performSelector:@selector(restartTimerAfterNavigation) withObject:nil afterDelay:1.0];
        return;
    }
    
    if (!_isChannelListVisible) return;
    
    // Menu is visible - ensure player controls are hidden (like Mac mode)
    if (_playerControlsVisible) {
        [self hidePlayerControls];
        NSLog(@"📺 [TVOS-MENU-VISIBLE] Hiding player controls (Mac mode behavior)");
    }
    
    switch (_tvosNavigationArea) {
        case 0: // Categories
            if (_selectedCategoryIndex < 5) { // 6 categories (0-5)
                _selectedCategoryIndex++;
            } else {
                // Wrap around to first category (SEARCH)
                _selectedCategoryIndex = 0;
            }
            [self handleTVOSCategoryChange];
            NSLog(@"📺 [CATEGORY-NAV] DOWN - Selected category index: %ld", (long)_selectedCategoryIndex);
            break;
        case 1: // Groups
        {
            NSArray *groups = [self getGroupsForSelectedCategory];
            if (_selectedGroupIndex < groups.count - 1) {
                _selectedGroupIndex++;
                [self handleTVOSGroupScroll];
            }
            break;
        }
        case 2: // Channels
        {
            NSArray *channels = [self getChannelsForCurrentGroup];
            if (_selectedChannelIndex < channels.count - 1) {
                _selectedChannelIndex++;
                [self handleTVOSChannelScroll];
                //NSLog(@"📺 ✅ tvOS DOWN - Set selectedChannelIndex to: %ld (should show program guide)", (long)_selectedChannelIndex);
            }
            break;
        }
        case 3: // Settings controls or Program Guide
            if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
            [self handleTVOSSettingsNavigationDown];
            } else {
                [self handleTVOSProgramGuideNavigationDown];
            }
            break;
    }
    [self setNeedsDisplay];
}

- (void)handleTVOSNavigationLeft {
    // Stop auto-hide timer during active navigation
    [self stopAutoHideTimer];
    
    // Special handling when in player controls navigation mode
    if (!_isChannelListVisible && _playerControlsVisible && _playerControlsNavigationMode) {
        if (_selectedPlayerControl == 0) {
            // Progress bar selected - perform seek backward
            [self handleTVOSSeekBackward];
        } else if (_selectedPlayerControl == 2) {
            // Audio button selected - move left to CC button
            _selectedPlayerControl = 1;
            NSLog(@"📺 [PLAYER-CONTROLS] Navigated LEFT from Audio to CC button");
            [self setNeedsDisplay];
        }
        // If on CC button (1), stay there (can't go further left)
        
        // Restart timer after navigation completes
        [self performSelector:@selector(restartTimerAfterNavigation) withObject:nil afterDelay:1.0];
        return;
    }
    
    if (!_isChannelListVisible && !_playerControlsVisible) {
        // Nothing is visible - Left button shows menu
        _isChannelListVisible = YES;
        [self resetAutoHideTimer];
        [self setNeedsDisplay];
        NSLog(@"📺 [TVOS-LEFT] Showing menu (nothing visible)");
        return;
    } else if (!_isChannelListVisible && _playerControlsVisible) {
        // Only player controls visible - Left button shows menu
        _isChannelListVisible = YES;
        [self resetAutoHideTimer];
        [self setNeedsDisplay];
        NSLog(@"📺 [TVOS-LEFT] Showing menu (player controls visible)");
        return;
    }
    
    // Menu is visible - normal navigation behavior
    
    // Reset EPG navigation mode if leaving program guide area
    if (_tvosNavigationArea == 3 && _selectedCategoryIndex != CATEGORY_SETTINGS) {
        self.epgNavigationMode = NO;
        self.selectedEpgProgramIndex = -1;
        //NSLog(@"📺 [EPG] Exited EPG navigation mode");
    }
    
    // Move to previous navigation area
    if (_tvosNavigationArea > 0) {
        _tvosNavigationArea--;
        //NSLog(@"📺 tvOS moved to navigation area: %d", _tvosNavigationArea);
    }
    [self setNeedsDisplay];
}

- (void)handleTVOSNavigationRight {
    // Stop auto-hide timer during active navigation
    [self stopAutoHideTimer];
    
    // Special handling when in player controls navigation mode
    if (!_isChannelListVisible && _playerControlsVisible && _playerControlsNavigationMode) {
        if (_selectedPlayerControl == 0) {
            // Progress bar selected - perform seek forward
            [self handleTVOSSeekForward];
        } else if (_selectedPlayerControl == 1) {
            // CC button selected - move right to Audio button
            _selectedPlayerControl = 2;
            NSLog(@"📺 [PLAYER-CONTROLS] Navigated RIGHT from CC to Audio button");
            [self setNeedsDisplay];
        }
        // If on Audio button (2), stay there (can't go further right)
        
        // Restart timer after navigation completes
        [self performSelector:@selector(restartTimerAfterNavigation) withObject:nil afterDelay:1.0];
        return;
    }
    
    if (!_isChannelListVisible) return;
    
    // Menu is visible - ensure player controls are hidden (like Mac mode)
    if (_playerControlsVisible) {
        [self hidePlayerControls];
        NSLog(@"📺 [TVOS-MENU-VISIBLE] Hiding player controls (Mac mode behavior)");
    }
    
    // Move to next navigation area
    NSInteger maxArea;
    if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
        maxArea = 3; // Categories, Groups, Channels, Settings
    } else if (_selectedChannelIndex >= 0 && [self getChannelAtIndex:_selectedChannelIndex]) {
        maxArea = 3; // Categories, Groups, Channels, Program Guide
    } else {
        maxArea = 2; // Categories, Groups, Channels
    }
    
    if (_tvosNavigationArea < maxArea) {
        _tvosNavigationArea++;
        if (_tvosNavigationArea == 3) {
            if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
            _tvosSelectedSettingsControl = 0; // Start at first control
            } else {
                // Initialize EPG navigation starting at current program
                [self initializeEpgNavigation];
        }
        }
        //NSLog(@"📺 tvOS moved to navigation area: %d", _tvosNavigationArea);
    }
    [self setNeedsDisplay];
}

- (void)handleTVOSPlayPause {
    // Toggle playback if media is loaded
    if (self.player) {
        if (self.player.isPlaying) {
            [self.player pause];
            //NSLog(@"📺 tvOS paused playback");
        } else {
            [self.player play];
            //NSLog(@"📺 tvOS resumed playback");
        }
    }
}

- (void)handleTVOSSeekBackward {
    if (!self.player) return;
    
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    
    if (isTimeshiftPlaying) {
        // Timeshift seeking - go back 1 minute minimum (60 seconds)
        [self handleTimeshiftSeekBackwardTVOS:60]; // 60 seconds = 1 minute
        NSLog(@"📺 [SEEK-BACKWARD] Timeshift: Seeking back 1 minute");
    } else if (self.player.media && self.player.media.length.intValue > 0) {
        // Movie/video seeking - go back 10 seconds
        VLCTime *currentTime = [self.player time];
        if (currentTime) {
            int currentMs = [currentTime intValue];
            int newMs = MAX(0, currentMs - 10000); // 10 seconds back
            VLCTime *newTime = [VLCTime timeWithInt:newMs];
            [self.player setTime:newTime];
            NSLog(@"📺 [SEEK-BACKWARD] Video: %d ms -> %d ms", currentMs, newMs);
        }
    } else {
        // Live TV - can't seek backward
        NSLog(@"📺 [SEEK-BACKWARD] Cannot seek in live TV");
    }
    
    [self resetPlayerControlsTimer]; // Reset auto-hide timer
}

- (void)handleTVOSSeekForward {
    if (!self.player) return;
    
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    
    if (isTimeshiftPlaying) {
        // Timeshift seeking - go forward 1 minute minimum (60 seconds)
        [self handleTimeshiftSeekForwardTVOS:60]; // 60 seconds = 1 minute
        NSLog(@"📺 [SEEK-FORWARD] Timeshift: Seeking forward 1 minute");
    } else if (self.player.media && self.player.media.length.intValue > 0) {
        // Movie/video seeking - go forward 10 seconds
        VLCTime *currentTime = [self.player time];
        VLCTime *totalTime = [self.player.media length];
        if (currentTime && totalTime) {
            int currentMs = [currentTime intValue];
            int totalMs = [totalTime intValue];
            int newMs = MIN(totalMs, currentMs + 10000); // 10 seconds forward
            VLCTime *newTime = [VLCTime timeWithInt:newMs];
            [self.player setTime:newTime];
            NSLog(@"📺 [SEEK-FORWARD] Video: %d ms -> %d ms", currentMs, newMs);
        }
    } else {
        // Live TV - can't seek forward
        NSLog(@"📺 [SEEK-FORWARD] Cannot seek in live TV");
    }
    
    [self resetPlayerControlsTimer]; // Reset auto-hide timer
}

#pragma mark - tvOS Selection Handlers

- (void)handleTVOSCategorySelection {
    NSInteger previousCategoryIndex = _selectedCategoryIndex;
    
    // Hide settings scroll views when switching categories
    [self hideAllSettingsScrollViews];
    
    // Handle settings panel visibility
    if (previousCategoryIndex == CATEGORY_SETTINGS && _selectedCategoryIndex != CATEGORY_SETTINGS) {
        [self hideSettingsPanel];
    } else if (_selectedCategoryIndex == CATEGORY_SETTINGS && previousCategoryIndex != CATEGORY_SETTINGS) {
        [self showSettingsPanel];
    }
    
    // Reset group selection when changing categories
    _selectedGroupIndex = 0;
    _selectedChannelIndex = 0;
    _groupScrollPosition = 0;
    _channelScrollPosition = 0;
    
    //NSLog(@"📺 tvOS selected category: %ld", (long)_selectedCategoryIndex);
}

- (void)handleTVOSGroupSelection {
    NSArray *groups = [self getGroupsForSelectedCategory];
    if (_selectedGroupIndex >= 0 && _selectedGroupIndex < groups.count) {
        // Hide settings scroll views when switching groups
        [self hideAllSettingsScrollViews];
        
        // Reset channel selection when changing groups
        _selectedChannelIndex = 0;
        _channelScrollPosition = 0;
        
        // Reset settings control selection when switching groups
        _tvosSelectedSettingsControl = 0;
        
        //NSLog(@"📺 tvOS selected group: %@ (index: %ld)", groups[_selectedGroupIndex], (long)_selectedGroupIndex);
    }
}

- (void)handleTVOSChannelSelection {
    NSArray *channels = [self getChannelsForCurrentGroup];
    if (_selectedChannelIndex >= 0 && _selectedChannelIndex < channels.count) {
        // Play the selected channel
        [self playChannelAtIndex:_selectedChannelIndex];
        
        // Hide menu and all settings after selection on tvOS
        [self hideAllSettingsScrollViews];
        _isChannelListVisible = NO;
        [self setNeedsDisplay];
        
        //NSLog(@"📺 tvOS selected and playing channel at index: %ld", (long)_selectedChannelIndex);
    }
}

#pragma mark - tvOS Scroll Handlers

- (void)handleTVOSCategoryChange {
    // Reset group and channel selection when changing categories
    _selectedGroupIndex = 0;
    _selectedChannelIndex = 0;
    _groupScrollPosition = 0;
    _channelScrollPosition = 0;
    
    // Category-specific initialization
    if (_selectedCategoryIndex == CATEGORY_FAVORITES) {
        NSLog(@"📺 [FAVORITES] Switched to FAVORITES category");
        [self ensureFavoritesCategory];
    } else if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
        NSLog(@"📺 [SETTINGS] Switched to SETTINGS category");
        _tvosSelectedSettingsControl = 0;
    }
    
    NSLog(@"📺 [CATEGORY-CHANGE] Category changed to index: %ld", (long)_selectedCategoryIndex);
}

- (void)handleTVOSGroupScroll {
    // Ensure selected group is visible
    CGFloat itemHeight = [self rowHeight];
    CGFloat visibleHeight = self.bounds.size.height;
    CGFloat selectedItemY = _selectedGroupIndex * itemHeight;
    
    // Auto-scroll if selection is out of view
    if (selectedItemY < _groupScrollPosition) {
        _groupScrollPosition = selectedItemY;
    } else if (selectedItemY + itemHeight > _groupScrollPosition + visibleHeight) {
        _groupScrollPosition = selectedItemY + itemHeight - visibleHeight;
    }
    
    // Clamp scroll position
    NSArray *groups = [self getGroupsForSelectedCategory];
    CGFloat maxScroll = MAX(0, groups.count * itemHeight - visibleHeight);
    _groupScrollPosition = MAX(0, MIN(_groupScrollPosition, maxScroll));
}

- (void)handleTVOSChannelScroll {
    // Ensure selected channel is visible
    CGFloat itemHeight = [self rowHeight];
    CGFloat visibleHeight = self.bounds.size.height;
    CGFloat selectedItemY = _selectedChannelIndex * itemHeight;
    
    // Auto-scroll if selection is out of view
    if (selectedItemY < _channelScrollPosition) {
        _channelScrollPosition = selectedItemY;
    } else if (selectedItemY + itemHeight > _channelScrollPosition + visibleHeight) {
        _channelScrollPosition = selectedItemY + itemHeight - visibleHeight;
    }
    
    // Clamp scroll position
    NSArray *channels = [self getChannelsForCurrentGroup];
    CGFloat maxScroll = MAX(0, channels.count * itemHeight - visibleHeight);
    _channelScrollPosition = MAX(0, MIN(_channelScrollPosition, maxScroll));
}

#pragma mark - tvOS Program Guide Navigation

- (void)handleTVOSProgramGuideNavigationUp {
    VLCChannel *channel = [self getChannelAtIndex:_selectedChannelIndex];
    if (!channel || !channel.programs || channel.programs.count == 0) return;
    
    // Initialize EPG navigation mode if not already active
    if (!self.epgNavigationMode) {
        [self initializeEpgNavigation];
        return;
    }
    
    // Move to previous program
    if (self.selectedEpgProgramIndex > 0) {
        self.selectedEpgProgramIndex--;
        [self scrollToSelectedEpgProgram];
        //NSLog(@"📺 EPG UP - Selected program index: %ld", (long)self.selectedEpgProgramIndex);
        [self setNeedsDisplay];
    }
}

- (void)handleTVOSProgramGuideNavigationDown {
    VLCChannel *channel = [self getChannelAtIndex:_selectedChannelIndex];
    if (!channel || !channel.programs || channel.programs.count == 0) return;
    
    // Initialize EPG navigation mode if not already active
    if (!self.epgNavigationMode) {
        [self initializeEpgNavigation];
        return;
    }
    
    // Move to next program
    if (self.selectedEpgProgramIndex < channel.programs.count - 1) {
        self.selectedEpgProgramIndex++;
        [self scrollToSelectedEpgProgram];
        //NSLog(@"📺 EPG DOWN - Selected program index: %ld", (long)self.selectedEpgProgramIndex);
        [self setNeedsDisplay];
    }
}

#pragma mark - tvOS Settings Navigation

- (void)handleTVOSSettingsNavigationUp {
    if (_tvosSelectedSettingsControl > 0) {
        _tvosSelectedSettingsControl--;
        //NSLog(@"📺 tvOS settings control up: %ld", (long)_tvosSelectedSettingsControl);
    }
}

- (void)handleTVOSSettingsNavigationDown {
    NSInteger maxControls = [self getSettingsControlCount];
    if (_tvosSelectedSettingsControl < maxControls - 1) {
        _tvosSelectedSettingsControl++;
        //NSLog(@"📺 tvOS settings control down: %ld", (long)_tvosSelectedSettingsControl);
    }
}

- (void)handleTVOSSettingsSelection {
    //NSLog(@"📺 tvOS settings control selected: %ld", (long)_tvosSelectedSettingsControl);
    
    // Get current settings group
    NSArray *settingsGroups = [self getGroupsForSelectedCategory];
    if (_selectedGroupIndex >= 0 && _selectedGroupIndex < [settingsGroups count]) {
        NSString *selectedGroup = [settingsGroups objectAtIndex:_selectedGroupIndex];
        
        if ([selectedGroup isEqualToString:@"Playlist"]) {
            [self handleTVOSPlaylistSettingsSelection];
        } else if ([selectedGroup isEqualToString:@"Themes"]) {
            [self handleTVOSThemeSettingsSelection];
        } else if ([selectedGroup isEqualToString:@"General"]) {
            [self handleTVOSGeneralSettingsSelection];
        } else if ([selectedGroup isEqualToString:@"Movie Info"]) {
            [self handleTVOSMovieInfoSettingsSelection];
        }
    }
}

- (NSInteger)getSettingsControlCount {
    // Get current settings group and return control count
    NSArray *settingsGroups = [self getGroupsForSelectedCategory];
    if (_selectedGroupIndex >= 0 && _selectedGroupIndex < [settingsGroups count]) {
        NSString *selectedGroup = [settingsGroups objectAtIndex:_selectedGroupIndex];
        
        if ([selectedGroup isEqualToString:@"Playlist"]) {
            return 5; // M3U field, EPG field, Time offset button, Load button, Update EPG button
        } else if ([selectedGroup isEqualToString:@"Themes"]) {
            return 8; // Theme selection, transparency, RGB sliders, glassmorphism toggle, intensity, reset
        } else if ([selectedGroup isEqualToString:@"General"]) {
            return 1; // Placeholder
        } else if ([selectedGroup isEqualToString:@"Movie Info"]) {
            return 1; // Clear cache button
        }
    }
    return 0;
}

- (void)handleTVOSPlaylistSettingsSelection {
    switch (_tvosSelectedSettingsControl) {
        case 0: // M3U URL field
            //NSLog(@"📺 tvOS M3U URL field selected - show text input");
            [self showTVOSTextInput:@"Enter M3U URL" currentText:self.m3uFilePath completion:^(NSString *newText) {
                if (newText && newText.length > 0) {
                    self.m3uFilePath = newText;
                    [self saveSettings];
                    //NSLog(@"📺 M3U URL updated: %@", newText);
                }
            }];
            break;
        case 1: // EPG URL field  
            //NSLog(@"📺 tvOS EPG URL field selected - show text input");
            [self showTVOSTextInput:@"Enter EPG URL" currentText:self.epgUrl completion:^(NSString *newText) {
                if (newText && newText.length > 0) {
                    self.epgUrl = newText;
                    [self saveSettings];
                    //NSLog(@"📺 EPG URL updated: %@", newText);
                }
            }];
            break;
        case 2: // Time offset button
            //NSLog(@"📺 tvOS Time offset button selected");
            [self showTVOSTimeOffsetSelection];
            break;
        case 3: // Load button
            //NSLog(@"📺 tvOS Load button selected");
            if (self.m3uFilePath && self.m3uFilePath.length > 0) {
                [self loadChannelsFromUrl:self.m3uFilePath];
            }
            break;
        case 4: // Update EPG button
            NSLog(@"🔧 [UPDATE-EPG-TVOS] ===== TVOS UPDATE EPG BUTTON SELECTED =====");
            if (self.epgUrl && self.epgUrl.length > 0) {
                        // FORCE FRESH EPG DOWNLOAD: Use VLCDataManager
        NSLog(@"🔧 [UPDATE-EPG-TVOS] About to call VLCDataManager forceReloadEPG");
        if (self.epgUrl && ![self.epgUrl isEqualToString:@""]) {
            NSLog(@"🔧 [UPDATE-EPG-TVOS] ✅ Calling VLCDataManager forceReloadEPG");
            [[VLCDataManager sharedManager] forceReloadEPG];
            } else {
            NSLog(@"🔧 [UPDATE-EPG-TVOS] ❌ No EPG URL - cannot force reload");
                    // Fallback: bypass cache manually and call direct download
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [self loadEpgDataWithRetryCount:0];
                    });
                }
            } else {
                NSLog(@"🔧 [UPDATE-EPG-TVOS] ❌ No EPG URL configured for updating");
            }
            break;
    }
}

- (void)handleTVOSThemeSettingsSelection {
    //NSLog(@"📺 tvOS Theme settings selection: %ld", (long)_tvosSelectedSettingsControl);
    switch (_tvosSelectedSettingsControl) {
        case 0: // Theme selection
            //[self showTVOSThemeSelection];
            break;
        case 1: // Transparency
            //[self showTVOSTransparencySelection];
            break;
        case 2: // Selection Red
            //[self showTVOSSelectionColorSelection:@"Red" component:0];
            break;
        case 3: // Selection Green
            //[self showTVOSSelectionColorSelection:@"Green" component:1];
            break;
        case 4: // Selection Blue  
            //[self showTVOSSelectionColorSelection:@"Blue" component:2];
            break;
        case 5: // Glassmorphism toggle
            //[self toggleTVOSGlassmorphism];
            break;
        case 6: // Glassmorphism intensity
            //[self showTVOSGlassmorphismIntensitySelection];
            break;
        case 7: // Reset themes
            [self resetTVOSThemeSettings];
            break;
    }
}
/*
- (void)handleTVOSGeneralSettingsSelection {
    NSLog(@"📺 tvOS General settings selection: %ld", (long)_tvosSelectedSettingsControl);
    // Add general settings selection handling
}
*/
- (void)handleTVOSMovieInfoSettingsSelection {
    if (_tvosSelectedSettingsControl == 0) {
        //NSLog(@"📺 tvOS Clear movie info cache selected");
        [self clearMovieInfoCache];
    }
}

- (void)showTVOSTextInput:(NSString *)title currentText:(NSString *)currentText completion:(void(^)(NSString *newText))completion {
    //NSLog(@"📺 tvOS text input: %@", title);
    
#if TARGET_OS_TV
    // Create an alert controller with text field
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title
                                                                             message:@"Type using the on-screen keyboard. Select each letter, then use 'Done' button to save."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    // Store completion block for later use - copy to ensure proper memory management
    void(^storedCompletion)(NSString *) = [completion copy];
    
    // Add text field with tvOS-optimized configuration
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentText ?: @"";
        textField.placeholder = @"http://example.com/playlist.m3u";
        
        // tvOS-specific optimizations for proper character input
        textField.keyboardType = UIKeyboardTypeURL; // URL keyboard for better URL input
        textField.returnKeyType = UIReturnKeyDefault; // Don't auto-trigger Done
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.spellCheckingType = UITextSpellCheckingTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        
        // Better editing configuration for tvOS
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.adjustsFontSizeToFitWidth = YES;
        textField.minimumFontSize = 12.0;
    }];
    
    // Add Done action (primary)
    UIAlertAction *doneAction = [UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSString *newText = textField.text ?: @"";
        //NSLog(@"📺 tvOS text input completed: '%@'", newText);
        if (storedCompletion) {
            storedCompletion(newText);
        }
        [self setNeedsDisplay];
    }];
    
    // Add Cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        //NSLog(@"📺 tvOS text input cancelled");
        if (storedCompletion) {
            storedCompletion(currentText); // Return original text
        }
    }];
    
    // Add Clear action for convenience
    UIAlertAction *clearAction = [UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        //NSLog(@"📺 tvOS text input cleared");
        if (storedCompletion) {
            storedCompletion(@""); // Return empty text
        }
        [self setNeedsDisplay];
    }];
    
    // Add Paste action for clipboard support (only if clipboard has content)
    // Note: Clipboard functionality is not available on tvOS, so this is disabled
    // On tvOS, users will need to type the URL manually
#if !TARGET_OS_TV
    NSString *clipboardText = [self getClipboardText];
    if (clipboardText && clipboardText.length > 0) {
        NSString *pasteTitle = [NSString stringWithFormat:@"Paste: %@", [self truncateString:clipboardText maxLength:30]];
        UIAlertAction *pasteAction = [UIAlertAction actionWithTitle:pasteTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            //NSLog(@"📺 tvOS paste from clipboard: '%@'", clipboardText);
            if (storedCompletion) {
                storedCompletion(clipboardText);
            }
            [self setNeedsDisplay];
        }];
        [alertController addAction:pasteAction];
    }
#endif
    
    [alertController addAction:doneAction];
    [alertController addAction:clearAction];
    [alertController addAction:cancelAction];
    
    // Set Done as preferred action
    alertController.preferredAction = doneAction;
    
#else
    // iOS version - simpler implementation
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title
                                                                             message:@"Enter text"
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentText ?: @"";
        textField.placeholder = @"Enter URL";
        textField.keyboardType = UIKeyboardTypeURL;
    }];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSString *newText = textField.text;
        if (completion) {
            completion(newText);
        }
        [self setNeedsDisplay];
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if (completion) {
            completion(currentText);
        }
    }];
    
    [alertController addAction:okAction];
    [alertController addAction:cancelAction];
#endif
    
    // Present the alert
    UIViewController *topViewController = [self topViewController];
    if (topViewController) {
        [topViewController presentViewController:alertController animated:YES completion:^{
            // Auto-focus the text field after presentation with delay for tvOS
            UITextField *textField = alertController.textFields.firstObject;
            if (textField) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [textField becomeFirstResponder];
                    //NSLog(@"📺 Text field focused for input");
                });
            }
        }];
    } else {
        //NSLog(@"❌ No view controller found to present text input");
        if (completion) {
            completion(currentText);
        }
    }
}

- (UIViewController *)topViewController {
    UIViewController *topController = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}

- (NSString *)getClipboardText {
#if TARGET_OS_IOS
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    
    // Check if pasteboard has string content
    if (pasteboard.hasStrings && pasteboard.string) {
        NSString *clipboardContent = pasteboard.string;
        
        // Basic validation - check if it looks like a URL
        if ([clipboardContent hasPrefix:@"http://"] || 
            [clipboardContent hasPrefix:@"https://"] ||
            [clipboardContent containsString:@".m3u"] ||
            [clipboardContent containsString:@".m3u8"]) {
            return clipboardContent;
        }
        
        // Return content even if not URL-like, user can decide
        return clipboardContent;
    }
    
    return nil;
#else
    // Clipboard is not available on tvOS
    return nil;
#endif
}

- (NSString *)truncateString:(NSString *)string maxLength:(NSInteger)maxLength {
    if (!string || string.length <= maxLength) {
        return string;
    }
    
    NSString *truncated = [string substringToIndex:maxLength - 3];
    return [truncated stringByAppendingString:@"..."];
}

#if TARGET_OS_TV
- (void)drawTVOSPlaylistSettings:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 20;
    CGFloat startY = rect.size.height - 80;
    CGFloat lineHeight = 25;
    CGFloat controlHeight = 35;
    CGFloat spacing = 15;
    
    // Title
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:18],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGRect titleRect = CGRectMake(x + padding, startY, width - (padding * 2), lineHeight);
    [@"Playlist Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    CGFloat currentY = startY - 50;
    NSInteger controlIndex = 0;
    
    // Control 0: M3U URL Field
    [self drawTVOSControl:controlIndex
                    label:@"M3U URL:"
                    value:self.m3uFilePath ?: @"Not set"
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 1: EPG URL Field
    [self drawTVOSControl:controlIndex
                    label:@"EPG URL:"
                    value:self.epgUrl ?: @"Not set"
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 2: Time Offset
    NSString *timeOffsetText = [NSString stringWithFormat:@"%.1f hours", self.epgTimeOffsetHours];
    [self drawTVOSControl:controlIndex
                    label:@"Time Offset:"
                    value:timeOffsetText
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 3: Load Button
    [self drawTVOSControl:controlIndex
                    label:@"Load Channels"
                    value:@"Press to load"
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 4: Update EPG Button
    [self drawTVOSControl:controlIndex
                    label:@"Update EPG"
                    value:@"Press to update EPG data"
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
}

- (void)drawTVOSControl:(NSInteger)controlIndex label:(NSString *)label value:(NSString *)value rect:(CGRect)controlRect selected:(BOOL)selected {
    // Draw background with highlighting if selected
    if (selected) {
        // Bright blue highlight for focused control
        [[UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.8] setFill];
        UIBezierPath *highlightPath = [UIBezierPath bezierPathWithRoundedRect:controlRect cornerRadius:8];
        [highlightPath fill];
    } else {
        // Darker background for non-focused controls
        [[UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.6] setFill];
        UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:controlRect cornerRadius:8];
        [bgPath fill];
    }
    
    // Draw border
    [[UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0] setStroke];
    UIBezierPath *borderPath = [UIBezierPath bezierPathWithRoundedRect:controlRect cornerRadius:8];
    borderPath.lineWidth = 1.0;
    [borderPath stroke];
    
    // Label color based on selection
    UIColor *labelColor = selected ? [UIColor whiteColor] : [UIColor lightGrayColor];
    UIColor *valueColor = selected ? [UIColor whiteColor] : [UIColor grayColor];
    
    // Draw label
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:14],
        NSForegroundColorAttributeName: labelColor
    };
    
    CGRect labelRect = CGRectMake(controlRect.origin.x + 10, controlRect.origin.y + 2, controlRect.size.width - 20, 16);
    [label drawInRect:labelRect withAttributes:labelAttrs];
    
    // Draw value
    NSDictionary *valueAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:12],
        NSForegroundColorAttributeName: valueColor
    };
    
    CGRect valueRect = CGRectMake(controlRect.origin.x + 10, controlRect.origin.y + 18, controlRect.size.width - 20, 14);
    [value drawInRect:valueRect withAttributes:valueAttrs];
    
    // Show control index for debugging
    if (selected) {
        //NSLog(@"📺 tvOS control %ld highlighted: %@", (long)controlIndex, label);
    }
}
#endif

#endif

#pragma mark - Drawing Methods (Core UI Rendering)

- (void)drawRect:(CGRect)rect {
    @autoreleasepool {
        // No throttling - maximum smoothness for scrolling
        
        // Light memory monitoring during drawing
        static NSUInteger drawCount = 0;
        drawCount++;
        if (drawCount % 100 == 0) { // Check memory every 100 draws (reduced frequency)
            [self logMemoryUsage:@"during drawing"];
        }
        
        //NSLog(@"🎨 iOS drawRect called - rendering retina-optimized UI (scale: %.1fx)", [[UIScreen mainScreen] scale]);
        
        if (!_isChannelListVisible) {
            // Clear the background to be transparent when channel list is not visible
            // This allows the video underneath to show through
            CGContextRef context = UIGraphicsGetCurrentContext();
            if (context) {
                CGContextClearRect(context, rect);
            }
            
            // Channel switch overlay removed - player controls already show current channel
            
            // Draw player controls if visible and player is available (even when menu is hidden)
            if (_playerControlsVisible && self.player) {
                [self drawPlayerControlsOnRect:rect];
            }
            return;
        }
        
        // Get current graphics context
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) {
            NSLog(@"❌ No graphics context available");
            return;
        }
        
        CGContextSaveGState(context);
        
        // Draw components in order (matching macOS layout) with autorelease pools
        @autoreleasepool {
            [self drawCategories:rect];
        }
        
        @autoreleasepool {
            [self drawGroups:rect];
        }
        
        // Draw content based on selected category
        @autoreleasepool {
            if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
                [self drawSettingsPanel:rect];
            } else {
                // Check view mode for content categories - match macOS logic exactly
                BOOL isMovieCategory = (_selectedCategoryIndex == CATEGORY_MOVIES);
                BOOL isFavoritesWithMovies = (_selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]);
                
                // DEBUG: Show exactly what the drawing logic is deciding
                //NSLog(@"🎨 ========== DRAWING DECISION DEBUG ==========");
                //NSLog(@"🎨 _isGridViewActive: %@", _isGridViewActive ? @"YES" : @"NO");
                //NSLog(@"🎨 _isStackedViewActive: %@", _isStackedViewActive ? @"YES" : @"NO");
                //NSLog(@"🎨 isMovieCategory: %@", isMovieCategory ? @"YES" : @"NO");
                //NSLog(@"🎨 isFavoritesWithMovies: %@", isFavoritesWithMovies ? @"YES" : @"NO");
                //NSLog(@"🎨 Grid condition: %@", (_isGridViewActive && (isMovieCategory || isFavoritesWithMovies)) ? @"YES" : @"NO");
                //NSLog(@"🎨 Stacked condition: %@", ((_isStackedViewActive && isMovieCategory) || isFavoritesWithMovies) ? @"YES" : @"NO");
                
                if (_isGridViewActive && (isMovieCategory || isFavoritesWithMovies)) {
                    NSLog(@"🎨 DECISION: Drawing GRID view");
                    [self drawGridView:rect];
                } else if ((_isStackedViewActive && isMovieCategory) || isFavoritesWithMovies) {
                    NSLog(@"🎨 DECISION: Drawing STACKED view");
                    // CRITICAL: For favorites with movie channels, always use stacked view (matches macOS behavior)
                    [self drawStackedView:rect];
                } else {
                    NSLog(@"🎨 DECISION: Drawing LIST view (fallback)");
                    [self drawChannelList:rect];
                }
                NSLog(@"🎨 =============================================");
            }
        }
        
        // Draw player controls if visible and player is available
        @autoreleasepool {
            if (_playerControlsVisible && self.player) {
                [self drawPlayerControlsOnRect:rect];
            }
        }
        
        CGContextRestoreGState(context);
        //NSLog(@"🎨 Full UI rendering completed");
    }
}

- (void)drawCategories:(CGRect)rect {
    // Calculate responsive category width
    CGFloat categoryWidth = [self categoryWidth];
    
    // Draw background for categories panel using theme colors
    CGRect categoriesRect = CGRectMake(0, 0, categoryWidth, rect.size.height);
    
    // Use theme colors if available, otherwise fall back to default
    UIColor *categoryBgColor = self.themeCategoryStartColor ?: [UIColor darkGrayColor];
    [categoryBgColor setFill];
    UIRectFill(categoriesRect);
    
    // Draw category items
    NSArray *categoryNames = @[@"🔍 Search", @"⭐ Favorites", @"📺 TV", @"🎬 Movies", @"📚 Series", @"⚙️ Settings"];
    
    for (NSInteger i = 0; i < categoryNames.count; i++) {
        CGRect itemRect = CGRectMake(0, i * [self rowHeight], categoryWidth, [self rowHeight]);
        
        // Highlight selected category using custom selection colors (like macOS)
        if (i == _selectedCategoryIndex) {
            // Use user-customized selection colors instead of hardcoded blue
            UIColor *highlightColor;
            #if TARGET_OS_TV
            // Enhanced highlighting for tvOS when in category navigation area
            if (_tvosNavigationArea == 0) {
                // Bright selection color for focus
                highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.8];
            } else {
                // Dimmer selection color when not focused
                highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.75]; // Increased for better visibility
            }
            #else
            // Use custom selection colors for iOS (increased alpha for better visibility)
            highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.85];
            #endif
            
            // Apply glassmorphism visual effects if enabled (categories)
            if (self.glassmorphismEnabled) {
                // Create rounded rect with custom corner radius
                UIBezierPath *selectionPath = [UIBezierPath bezierPathWithRoundedRect:itemRect cornerRadius:self.glassmorphismCornerRadius];
                [highlightColor setFill];
                [selectionPath fill];
                
                // Add border if border width > 0
                if (self.glassmorphismBorderWidth > 0) {
                    // Create border color based on selection color
                    UIColor *borderColor = [UIColor colorWithRed:self.customSelectionRed * 1.2 
                                                           green:self.customSelectionGreen * 1.2 
                                                            blue:self.customSelectionBlue * 1.2 
                                                           alpha:0.8];
                    [borderColor setStroke];
                    selectionPath.lineWidth = self.glassmorphismBorderWidth;
                    [selectionPath stroke];
                }
            } else {
                // Fallback to simple rectangle
                [highlightColor setFill];
                UIRectFill(itemRect);
            }
        }
        
        // Draw category text using cached fonts with safety check
        NSString *categoryName = categoryNames[i];
        UIFont *categoryFont = [self getCachedCategoryFont];
        if (!categoryFont) {
            NSLog(@"⚠️ Warning: getCachedCategoryFont returned nil, using fallback font");
            categoryFont = [UIFont boldSystemFontOfSize:[self categoryFontSize]];
        }
        
        NSDictionary *textAttributes = @{
            NSFontAttributeName: categoryFont,
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        
        CGRect textRect = CGRectInset(itemRect, 10, 5);
        [categoryName drawInRect:textRect withAttributes:textAttributes];
    }
}

- (void)drawGroups:(CGRect)rect {
    // Calculate responsive widths
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    
    // Draw background for groups panel using theme colors  
    CGRect groupsRect = CGRectMake(categoryWidth, 0, groupWidth, rect.size.height);
    
    // Use theme colors if available, otherwise fall back to default
    UIColor *groupBgColor = self.themeCategoryEndColor ?: [UIColor grayColor];
    [groupBgColor setFill];
    UIRectFill(groupsRect);
    
    // Get groups for selected category with ultra-safe approach
    NSArray *groups = nil;
    @try {
        groups = [self getGroupsForSelectedCategory];
    } @catch (NSException *exception) {
        NSLog(@"❌ [SAFE-DRAW] Exception getting groups for category: %@", exception);
        groups = @[@"General"]; // Safe fallback
    }
    
    // Additional safety check for the groups array itself
    if (!groups || ![groups isKindOfClass:[NSArray class]]) {
        NSLog(@"⚠️ [SAFE-DRAW] Groups is not a valid array, using fallback");
        groups = @[@"General"];
    }
    
    for (NSInteger i = 0; i < groups.count; i++) {
        CGRect itemRect = CGRectMake(categoryWidth, i * [self rowHeight] - _groupScrollPosition, groupWidth, [self rowHeight]);
        
        // Skip items that are not visible
        if (itemRect.origin.y + itemRect.size.height < 0 || itemRect.origin.y > rect.size.height) {
            continue;
        }
        
        // Highlight selected group using custom selection colors (like macOS)
        if (i == _selectedGroupIndex) {
            UIColor *highlightColor;
            #if TARGET_OS_TV
            // Enhanced highlighting for tvOS when in group navigation area
            if (_tvosNavigationArea == 1) {
                // Bright selection color for focus
                highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.8];
            } else {
                // Dimmer selection color when not focused
                highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.75]; // Increased for better visibility
            }
            #else
            // Use custom selection colors for iOS (increased alpha for better visibility)
            highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.85];
            #endif
            
            // Apply glassmorphism visual effects if enabled (groups)
            if (self.glassmorphismEnabled) {
                // Create rounded rect with custom corner radius
                UIBezierPath *selectionPath = [UIBezierPath bezierPathWithRoundedRect:itemRect cornerRadius:self.glassmorphismCornerRadius];
                [highlightColor setFill];
                [selectionPath fill];
                
                // Add border if border width > 0
                if (self.glassmorphismBorderWidth > 0) {
                    // Create border color based on selection color
                    UIColor *borderColor = [UIColor colorWithRed:self.customSelectionRed * 1.2 
                                                           green:self.customSelectionGreen * 1.2 
                                                            blue:self.customSelectionBlue * 1.2 
                                                           alpha:0.8];
                    [borderColor setStroke];
                    selectionPath.lineWidth = self.glassmorphismBorderWidth;
                    [selectionPath stroke];
                }
            } else {
                // Fallback to simple rectangle
                [highlightColor setFill];
                UIRectFill(itemRect);
            }
        }
        
        // Draw group text using cached fonts with FULL safety checks
        id groupObject = groups[i];
        NSString *groupName = nil;
        
        // SAFETY: Validate groupObject before using it
        if (groupObject == nil || [groupObject isKindOfClass:[NSNull class]]) {
            NSLog(@"⚠️ [SAFE-DRAW] Group at index %ld is nil or NSNull, using fallback", (long)i);
            groupName = [NSString stringWithFormat:@"Group %ld", (long)i];
        } else if ([groupObject isKindOfClass:[NSString class]]) {
            groupName = (NSString *)groupObject;
            if (groupName.length == 0) {
                NSLog(@"⚠️ [SAFE-DRAW] Group at index %ld is empty string, using fallback", (long)i);
                groupName = [NSString stringWithFormat:@"Group %ld", (long)i];
            }
        } else {
            NSLog(@"⚠️ [SAFE-DRAW] Group at index %ld is not a string (class: %@), using fallback", (long)i, [groupObject class]);
            groupName = [NSString stringWithFormat:@"Group %ld", (long)i];
        }
        
        UIFont *groupFont = [self getCachedGroupFont];
        if (!groupFont) {
            NSLog(@"⚠️ Warning: getCachedGroupFont returned nil, using fallback font");
            groupFont = [UIFont systemFontOfSize:[self groupFontSize] weight:UIFontWeightMedium];
        }
        
        NSDictionary *textAttributes = @{
            NSFontAttributeName: groupFont,
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        
        CGRect textRect = CGRectInset(itemRect, 10, 5);
        
        // SAFETY: Double-check groupName is valid before drawing
        if (groupName && [groupName isKindOfClass:[NSString class]] && groupName.length > 0) {
        [groupName drawInRect:textRect withAttributes:textAttributes];
        } else {
            NSLog(@"⚠️ [SAFE-DRAW] Final groupName validation failed, skipping draw");
        }
        
        // Draw catchup icon if this group contains channels with catchup support - FIXED: flat white design, smaller size
        if ([self groupHasCatchupChannels:groupName]) {
            CGFloat catchupSize = 12; // Smaller size for groups: 14→12
            CGRect catchupRect = CGRectMake(itemRect.origin.x + itemRect.size.width - catchupSize - 8,
                                          itemRect.origin.y + (itemRect.size.height - catchupSize) / 2,
                                          catchupSize,
                                          catchupSize);
            
            // Draw flat white clock icon without background
            CGContextRef context = UIGraphicsGetCurrentContext();
            CGContextSaveGState(context);
            
            // Draw clock circle outline (white)
            CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(context, 1.0); // Thinner line for smaller icon
            CGFloat radius = catchupSize / 2 - 1;
            CGPoint center = CGPointMake(catchupRect.origin.x + catchupSize/2, catchupRect.origin.y + catchupSize/2);
            CGContextAddArc(context, center.x, center.y, radius, 0, 2 * M_PI, NO);
            CGContextStrokePath(context);
            
            // Draw clock hands (white)
            CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(context, 0.8); // Thinner line for smaller icon
            CGContextSetLineCap(context, kCGLineCapRound);
            
            // Hour hand (shorter, pointing to 10)
            CGFloat hourAngle = -M_PI/2 + (10.0/12.0) * 2 * M_PI; // 10 o'clock
            CGFloat hourLength = radius * 0.5;
            CGContextMoveToPoint(context, center.x, center.y);
            CGContextAddLineToPoint(context, 
                                   center.x + hourLength * cos(hourAngle),
                                   center.y + hourLength * sin(hourAngle));
            CGContextStrokePath(context);
            
            // Minute hand (longer, pointing to 2) 
            CGFloat minuteAngle = -M_PI/2 + (10.0/60.0) * 2 * M_PI; // 10 minutes
            CGFloat minuteLength = radius * 0.7;
            CGContextMoveToPoint(context, center.x, center.y);
            CGContextAddLineToPoint(context,
                                   center.x + minuteLength * cos(minuteAngle),
                                   center.y + minuteLength * sin(minuteAngle));
            CGContextStrokePath(context);
            
            // Center dot (white)
            CGContextSetFillColorWithColor(context, [UIColor whiteColor].CGColor);
            CGContextAddArc(context, center.x, center.y, 0.6, 0, 2 * M_PI, NO); // Smaller dot for smaller icon
            CGContextFillPath(context);
            
            CGContextRestoreGState(context);
        }
    }
}

- (void)drawChannelList:(CGRect)rect {
    // Calculate responsive dimensions
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat programGuideWidth = [self programGuideWidth];
    
    // Calculate channel list area - responsive to screen size
    CGFloat channelListX = categoryWidth + groupWidth;
    CGFloat channelListWidth = rect.size.width - channelListX - programGuideWidth;
    
    // Draw background for channel list using theme colors
    CGRect channelListRect = CGRectMake(channelListX, 0, channelListWidth, rect.size.height);
    
    // Use theme colors if available, otherwise fall back to default
    UIColor *channelBgColor = self.themeChannelStartColor ?: [UIColor lightGrayColor];
    [channelBgColor setFill];
    UIRectFill(channelListRect);
    
    // Get channels for current selection
    NSArray *channels = [self getChannelsForCurrentGroup];
    
    // Draw channel items
    for (NSInteger i = 0; i < channels.count; i++) {
        CGRect itemRect = CGRectMake(channelListX, i * [self rowHeight] - _channelScrollPosition, 
                                    channelListWidth, [self rowHeight]);
        
        // Skip items that are completely above the visible area (with buffer for smooth scrolling)
        // Allow items that are partially visible at the bottom to be rendered
        if (itemRect.origin.y + itemRect.size.height < -[self rowHeight]) {
            continue;
        }
        
        // Highlight hovered or selected channel using custom selection colors (like macOS)
        if (i == _hoveredChannelIndex || i == _selectedChannelIndex) {
            UIColor *highlightColor;
            
            if (i == _selectedChannelIndex) {
                // Selected channel - use custom selection colors
                #if TARGET_OS_TV
                // Enhanced highlighting for tvOS when in channel navigation area
                if (_tvosNavigationArea == 2) {
                    // Bright selection color for focus
                    highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.8];
                } else {
                    // Dimmer selection color when not focused
                    highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.6];
                }
                #else
                // Use custom selection colors for iOS (increased alpha for better visibility)
                highlightColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.85];
                #endif
            } else {
                // Hovered channel - lighter version of custom selection color (like macOS hover)
                CGFloat hoverRed = self.customSelectionRed * 0.9;
                CGFloat hoverGreen = self.customSelectionGreen * 0.9;
                CGFloat hoverBlue = self.customSelectionBlue * 0.9;
                highlightColor = [UIColor colorWithRed:hoverRed green:hoverGreen blue:hoverBlue alpha:0.7]; // Increased from 0.3 for better visibility
            }
            
            // Apply glassmorphism visual effects if enabled (channels)
            if (self.glassmorphismEnabled) {
                // Create rounded rect with custom corner radius
                UIBezierPath *selectionPath = [UIBezierPath bezierPathWithRoundedRect:itemRect cornerRadius:self.glassmorphismCornerRadius];
                [highlightColor setFill];
                [selectionPath fill];
                
                // Add border if border width > 0
                if (self.glassmorphismBorderWidth > 0) {
                    // Create border color based on selection color (brighter for channels)
                    UIColor *borderColor;
                    if (i == _selectedChannelIndex) {
                        // Bright border for selected channel
                        borderColor = [UIColor colorWithRed:self.customSelectionRed * 1.3 
                                                      green:self.customSelectionGreen * 1.3 
                                                       blue:self.customSelectionBlue * 1.3 
                                                      alpha:0.9];
                    } else {
                        // Dimmer border for hovered channel
                        borderColor = [UIColor colorWithRed:self.customSelectionRed * 1.1 
                                                      green:self.customSelectionGreen * 1.1 
                                                       blue:self.customSelectionBlue * 1.1 
                                                      alpha:0.7];
                    }
                    [borderColor setStroke];
                    selectionPath.lineWidth = self.glassmorphismBorderWidth;
                    [selectionPath stroke];
                }
            } else {
                // Fallback to simple rectangle
                [highlightColor setFill];
                UIRectFill(itemRect);
            }
        }
        
        // Get channel data
        NSString *channelName = @"Unknown Channel";
        VLCChannel *channel = nil;
        if ([channels[i] isKindOfClass:[VLCChannel class]]) {
            channel = (VLCChannel *)channels[i];
            channelName = channel.name ?: @"Unnamed Channel";
        } else if ([channels[i] isKindOfClass:[NSString class]]) {
            channelName = (NSString *)channels[i];
        }
        
        // Calculate text layout - channel name at top, EPG data below
        CGRect channelNameRect = CGRectInset(itemRect, 8, 4);
        channelNameRect.size.height = 22; // More space for channel name
        
        // Optional: Draw channel number on the left first
        if (i < 999) { // Only show numbers for reasonable range
            NSString *channelNumber = [NSString stringWithFormat:@"%ld", (long)(i + 1)];
            NSDictionary *numberAttributes = @{
                NSFontAttributeName: [self getCachedChannelNumberFont],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.7 alpha:1.0]
            };
            CGRect numberRect = CGRectMake(channelListX + 5, itemRect.origin.y + 8, 30, 20);
            [channelNumber drawInRect:numberRect withAttributes:numberAttributes];
            
            // Adjust channel name rect to account for channel number  
            channelNameRect.origin.x += 35;
            channelNameRect.size.width -= 35;
        }
        
        // Draw channel name with better styling
        NSDictionary *channelNameAttributes = @{
            NSFontAttributeName: [self getCachedChannelFont],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        [channelName drawInRect:channelNameRect withAttributes:channelNameAttributes];
        
        // Draw catchup icon if channel supports catchup - FIXED: flat white design, smaller size
        if (channel && (channel.supportsCatchup || channel.catchupDays > 0)) {
            CGFloat catchupSize = 12; // Smaller size: 16→12
            CGRect catchupRect = CGRectMake(channelNameRect.origin.x + channelNameRect.size.width - catchupSize - 5,
                                          channelNameRect.origin.y + 2,
                                          catchupSize,
                                          catchupSize);
            
            // Draw flat white clock icon without background
            CGContextRef context = UIGraphicsGetCurrentContext();
            CGContextSaveGState(context);
            
            // Draw clock circle outline (white)
            CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(context, 1.0); // Thinner line for smaller icon
            CGFloat radius = catchupSize / 2 - 1;
            CGPoint center = CGPointMake(catchupRect.origin.x + catchupSize/2, catchupRect.origin.y + catchupSize/2);
            CGContextAddArc(context, center.x, center.y, radius, 0, 2 * M_PI, NO);
            CGContextStrokePath(context);
            
            // Draw clock hands (white)
            CGContextSetStrokeColorWithColor(context, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(context, 1.0); // Thinner line for smaller icon
            CGContextSetLineCap(context, kCGLineCapRound);
            
            // Hour hand (shorter, pointing to 10)
            CGFloat hourAngle = -M_PI/2 + (10.0/12.0) * 2 * M_PI; // 10 o'clock
            CGFloat hourLength = radius * 0.5;
            CGContextMoveToPoint(context, center.x, center.y);
            CGContextAddLineToPoint(context, 
                                   center.x + hourLength * cos(hourAngle),
                                   center.y + hourLength * sin(hourAngle));
            CGContextStrokePath(context);
            
            // Minute hand (longer, pointing to 2) 
            CGFloat minuteAngle = -M_PI/2 + (10.0/60.0) * 2 * M_PI; // 10 minutes
            CGFloat minuteLength = radius * 0.7;
            CGContextMoveToPoint(context, center.x, center.y);
            CGContextAddLineToPoint(context,
                                   center.x + minuteLength * cos(minuteAngle),
                                   center.y + minuteLength * sin(minuteAngle));
            CGContextStrokePath(context);
            
            // Center dot (white)
            CGContextSetFillColorWithColor(context, [UIColor whiteColor].CGColor);
            CGContextAddArc(context, center.x, center.y, 0.8, 0, 2 * M_PI, NO); // Smaller dot for smaller icon
            CGContextFillPath(context);
            
            CGContextRestoreGState(context);
        }
        
        // Draw EPG data below channel name (like macOS version)
        if (channel) {
            VLCProgram *currentProgram = [channel currentProgramWithTimeOffset:self.epgTimeOffsetHours];
            
            // Check if we have EPG data
            BOOL hasEpgData = (self.isEpgLoaded && currentProgram != nil);
            if (hasEpgData) {
                // Draw current program title with smaller font
                NSDictionary *programAttributes = @{
                    NSFontAttributeName: [UIFont systemFontOfSize:10], // Smaller font: 12→10
                    NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1.0]
                };
                
                // Program info below channel name - FIXED: moved even higher up
                CGRect programRect = CGRectMake(channelNameRect.origin.x,
                                              itemRect.origin.y + 15, // Moved up from 18 to 15
                                              channelNameRect.size.width - 100, // More space for time
                                              12); // Smaller height for smaller font
                
                // Truncate program title if needed (with safety check)
                NSString *programTitle = currentProgram ? currentProgram.title : @"Loading...";
                if (programTitle && programTitle.length > 30) { // Allow more chars for smaller font
                    programTitle = [[programTitle substringToIndex:27] stringByAppendingString:@"..."];
                }
                if (!programTitle) programTitle = @"Loading...";
                [programTitle drawInRect:programRect withAttributes:programAttributes];
                
                // Draw program time on right side (with safety check) - FIXED: moved even higher up
                CGRect timeRect = CGRectMake(channelNameRect.origin.x + channelNameRect.size.width - 95,
                                           itemRect.origin.y + 15, // Moved up from 18 to 15
                                           90, // Wider to prevent clipping of "to" time
                                           12); // Smaller height for smaller font
                
                NSString *timeRange = currentProgram ? [currentProgram formattedTimeRangeWithOffset:self.epgTimeOffsetHours] : @"--:--";
                if (!timeRange) timeRange = @"--:--";
                [timeRange drawInRect:timeRect withAttributes:programAttributes];
                
                // Draw progress bar at bottom
                NSDate *now = [NSDate date];
                NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600.0;
                NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
                
                // Safety check: Ensure currentProgram is valid and both dates exist before calculating duration
                CGFloat progress = 0;
                if (currentProgram && currentProgram.startTime && currentProgram.endTime) {
                NSTimeInterval totalDuration = [currentProgram.endTime timeIntervalSinceDate:currentProgram.startTime];
                NSTimeInterval elapsed = [adjustedNow timeIntervalSinceDate:currentProgram.startTime];
                    progress = totalDuration > 0 ? (elapsed / totalDuration) : 0;
                progress = MAX(0, MIN(progress, 1.0)); // Clamp between 0 and 1
                } else {
                    // Silently handle nil program or dates - this is expected when EPG data is loading
                    progress = 0;
                }
                
                // Draw thin progress bar
                CGFloat progressBarHeight = 2;
                CGRect progressBarBg = CGRectMake(channelNameRect.origin.x,
                                                itemRect.origin.y + itemRect.size.height - 6,
                                                channelNameRect.size.width,
                                                progressBarHeight);
                
                // Background bar
                [[UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.7] setFill];
                UIRectFill(progressBarBg);
                
                // Progress fill
                CGRect progressBarFill = CGRectMake(progressBarBg.origin.x,
                                                  progressBarBg.origin.y,
                                                  progressBarBg.size.width * progress,
                                                  progressBarHeight);
                
                // Use color based on progress
                UIColor *progressColor;
                if (progress < 0.25) {
                    progressColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:0.8]; // Green
                } else if (progress < 0.75) {
                    progressColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:0.8]; // Blue
                } else {
                    progressColor = [UIColor colorWithRed:0.8 green:0.3 blue:0.2 alpha:0.8]; // Red
                }
                [progressColor setFill];
                UIRectFill(progressBarFill);
                
            } else if (self.isEpgLoaded) {
                // EPG is loaded but no program data for this channel
                NSDictionary *noDataAttributes = @{
                    NSFontAttributeName: [UIFont systemFontOfSize:10],
                    NSForegroundColorAttributeName: [UIColor darkGrayColor]
                };
                
                CGRect noDataRect = CGRectMake(channelNameRect.origin.x,
                                             itemRect.origin.y + 15, // Fixed: moved up to match program rect
                                             channelNameRect.size.width,
                                             12);
                
                [@"No program data available" drawInRect:noDataRect withAttributes:noDataAttributes];
            }
        }
    }
    
    // Draw program guide panel for hovered or selected channel (like macOS)
    NSInteger channelIndexForGuide = -1;
    
#if TARGET_OS_IOS
    // iOS: Show guide for hovered channel (single tap) or selected channel
    if (_hoveredChannelIndex >= 0) {
        channelIndexForGuide = _hoveredChannelIndex; // Show guide for hovered channel (single tap)
    } else if (_selectedChannelIndex >= 0) {
        channelIndexForGuide = _selectedChannelIndex; // Fallback to selected channel
    }
#elif TARGET_OS_TV
    // tvOS: Show guide for currently selected channel (removed navigation area restriction)
    if (_selectedChannelIndex >= 0) {
        channelIndexForGuide = _selectedChannelIndex; // Show guide for remote-selected channel
    }
#endif
    
    if (channelIndexForGuide >= 0 && channelIndexForGuide < channels.count) {
        //NSLog(@"📺 ✅ Drawing program guide for channel index: %ld (channels.count: %lu)", (long)channelIndexForGuide, (unsigned long)channels.count);
        [self drawProgramGuideForChannelAtIndex:channelIndexForGuide rect:rect];
    } else {
        //NSLog(@"📺 ❌ No program guide to draw - channelIndexForGuide: %ld, channels.count: %lu", 
         //     (long)channelIndexForGuide, (unsigned long)channels.count);
#if TARGET_OS_IOS
        //NSLog(@"📺 iOS debug - hoveredIndex: %ld, selectedIndex: %ld, channelListVisible: %d", 
        //      (long)_hoveredChannelIndex, (long)_selectedChannelIndex, _isChannelListVisible);
#elif TARGET_OS_TV
        //NSLog(@"📺 tvOS debug - selectedIndex: %ld, channelListVisible: %d", 
        //      (long)_selectedChannelIndex, _isChannelListVisible);
#endif
        //NSLog(@"📺 Debug - selectedCategory: %ld, selectedGroup: %ld, EPG loaded: %d, EPG loading: %d", 
        //      (long)_selectedCategoryIndex, (long)_selectedGroupIndex, self.isEpgLoaded, self.isLoadingEpg);
    }
}

- (void)drawGridView:(CGRect)rect {
    // Grid view for movies and series (like Mac version)
    if ((_selectedCategoryIndex != CATEGORY_MOVIES) && (_selectedCategoryIndex != CATEGORY_SERIES)) {
        [self drawChannelList:rect]; // Fallback to list view for non-movie categories
        return;
    }
    
    NSLog(@"📱 [GRID] Drawing grid view for category: %ld", (long)_selectedCategoryIndex);
    
    NSArray *channels = [self getChannelsForCurrentGroup];
    if (!channels || channels.count == 0) {
        return;
    }
    
    // Calculate grid layout
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat gridX = categoryWidth + groupWidth;
    CGFloat gridWidth = rect.size.width - gridX;
    CGFloat gridHeight = rect.size.height;
    
    // Grid settings
    CGFloat itemWidth = 180;
    CGFloat itemHeight = 240;
    CGFloat padding = 15;
    
    NSInteger itemsPerRow = MAX(1, (NSInteger)((gridWidth - padding) / (itemWidth + padding)));
    CGFloat actualItemWidth = (gridWidth - padding * (itemsPerRow + 1)) / itemsPerRow;
    
    NSInteger startRow = MAX(0, (NSInteger)(_channelScrollPosition / (itemHeight + padding)));
    NSInteger totalRows = (channels.count + itemsPerRow - 1) / itemsPerRow;
    
    for (NSInteger row = startRow; row < totalRows; row++) {
        CGFloat rowY = padding + row * (itemHeight + padding) - _channelScrollPosition;
        
        // Skip rows completely above the visible area
        if (rowY + itemHeight < 0) continue;
        
        // Skip rows completely below the visible area
        if (rowY > gridHeight) break;
        
        for (NSInteger col = 0; col < itemsPerRow; col++) {
            NSInteger index = row * itemsPerRow + col;
            if (index >= channels.count) break;
            
            // Load cached poster image for visible channels (like macOS version)
            VLCChannel *channel = channels[index];
            if ([channel.category isEqualToString:@"MOVIES"] && !channel.cachedPosterImage) {
                [self loadCachedPosterImageForChannel:channel];
            }
            
            CGFloat itemX = gridX + padding + col * (actualItemWidth + padding);
            CGFloat itemY = rowY;
            
            CGRect itemRect = CGRectMake(itemX, itemY, actualItemWidth, itemHeight);
            
            // Draw movie item (even if partially visible at bottom)
            [self drawMovieGridItem:channels[index] rect:itemRect isSelected:(index == _selectedChannelIndex)];
        }
    }
}

- (void)drawStackedView:(CGRect)rect {
    // Stacked view for movies, series, and favorites with movies (like Mac version)
    BOOL isMovieCategory = (_selectedCategoryIndex == CATEGORY_MOVIES);
    BOOL isSeriesCategory = (_selectedCategoryIndex == CATEGORY_SERIES);
    BOOL isFavoritesWithMovies = (_selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]);
    
    if (!isMovieCategory && !isSeriesCategory && !isFavoritesWithMovies) {
        NSLog(@"📱 [STACKED] Category %ld not suitable for stacked view, falling back to list", (long)_selectedCategoryIndex);
        [self drawChannelList:rect]; // Fallback to list view for non-movie categories
        return;
    }
    
    NSLog(@"📱 [STACKED] Drawing stacked view for category: %ld", (long)_selectedCategoryIndex);
    
    NSArray *channels = [self getChannelsForCurrentGroup];
    if (!channels || channels.count == 0) {
        return;
    }
    
    // Calculate stacked layout
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat stackedX = categoryWidth + groupWidth;
    CGFloat stackedWidth = rect.size.width - stackedX;
    
    // Stacked settings
    CGFloat itemHeight = 120;
    CGFloat padding = 10;
    
    // Calculate total content height for proper scrolling (like macOS version)
    CGFloat totalContentHeight = channels.count * (itemHeight + padding);
    
    // Add extra space at bottom to ensure last item is fully visible when scrolled to the end
    totalContentHeight += itemHeight;
    
    // Calculate scroll bounds to ensure last item is reachable (like macOS version)
    CGFloat stackedViewHeight = rect.size.height;
    CGFloat maxScroll = MAX(0, totalContentHeight - stackedViewHeight);
    CGFloat scrollPosition = MIN(_channelScrollPosition, maxScroll);
    
    NSLog(@"📱 [STACKED-SCROLL] Channels: %lu, totalHeight: %.1f, viewHeight: %.1f, maxScroll: %.1f, currentScroll: %.1f", 
          (unsigned long)channels.count, totalContentHeight, stackedViewHeight, maxScroll, scrollPosition);
    
    NSInteger startIndex = MAX(0, (NSInteger)(scrollPosition / (itemHeight + padding)));
    
    // Process all remaining items and let clipping logic handle visibility
    // This ensures we draw items that are partially visible at the bottom
    for (NSInteger i = startIndex; i < channels.count; i++) {
        CGFloat itemY = padding + i * (itemHeight + padding) - scrollPosition;
        
        // Skip items completely above the visible area
        if (itemY + itemHeight < 0) continue;
        
        // Skip items completely below the visible area (but allow partial visibility)
        if (itemY > rect.size.height) break;
        
        // Load cached poster image for visible channels (like macOS version)
        VLCChannel *channel = channels[i];
        if ([channel.category isEqualToString:@"MOVIES"] && !channel.cachedPosterImage) {
            [self loadCachedPosterImageForChannel:channel];
        }
        
        CGRect itemRect = CGRectMake(stackedX + padding, itemY, stackedWidth - 2 * padding, itemHeight);
        
        // Draw movie item (even if partially visible at bottom)
        [self drawMovieStackedItem:channels[i] rect:itemRect isSelected:(i == _selectedChannelIndex)];
    }
}

- (void)drawMovieGridItem:(id)channelObj rect:(CGRect)rect isSelected:(BOOL)selected {
    if (![channelObj isKindOfClass:[VLCChannel class]]) return;
    VLCChannel *channel = (VLCChannel *)channelObj;
    
    // Background
    UIColor *bgColor = selected ? 
        [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.8] :
        [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:0.8];
    
    [bgColor setFill];
    UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:8];
    [bgPath fill];
    
    if (selected) {
        [[UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:1.0] setStroke];
        bgPath.lineWidth = 2.0;
        [bgPath stroke];
    }
    
    // Movie poster area
    CGFloat posterHeight = rect.size.height * 0.7;
    CGRect posterRect = CGRectMake(rect.origin.x + 10, rect.origin.y + 10, rect.size.width - 20, posterHeight - 20);
    
    // Fetch movie info and poster using shared Mac methods
    if (!channel.hasLoadedMovieInfo && !channel.hasStartedFetchingMovieInfo) {
        // Try cache first, then fetch from network if needed (using shared Mac implementation)
        [self fetchMovieInfoForChannel:channel];
    }
    
    // Trigger download if no cached image and not already loading (like macOS version)
    if (!channel.cachedPosterImage && channel.logo && 
        !objc_getAssociatedObject(channel, "imageLoadingInProgress")) {
        [self loadImageAsynchronously:channel.logo forChannel:channel];
    }
    
    BOOL drewPoster = NO;
    
    // Try to draw cached poster image
    if (channel.cachedPosterImage) {
        [channel.cachedPosterImage drawInRect:posterRect];
        drewPoster = YES;
    }
    
    if (!drewPoster) {
        // Placeholder
        [[UIColor colorWithRed:0.25 green:0.25 blue:0.3 alpha:0.8] setFill];
        UIBezierPath *placeholderPath = [UIBezierPath bezierPathWithRoundedRect:posterRect cornerRadius:4];
        [placeholderPath fill];
        
        NSString *icon = [channel.category isEqualToString:@"MOVIES"] ? @"🎬" : @"📺";
        NSDictionary *iconAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:32],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.6 alpha:1.0]
        };
        CGRect iconRect = CGRectMake(posterRect.origin.x + posterRect.size.width/2 - 16, 
                                   posterRect.origin.y + posterRect.size.height/2 - 16, 32, 32);
        [icon drawInRect:iconRect withAttributes:iconAttrs];
    }
    
    // Title
    NSString *title = channel.name ?: @"Unknown";
    if (title.length > 18) {
        title = [[title substringToIndex:15] stringByAppendingString:@"..."];
    }
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGRect titleRect = CGRectMake(rect.origin.x + 8, rect.origin.y + posterHeight, rect.size.width - 16, 20);
    [title drawInRect:titleRect withAttributes:titleAttrs];
    
    // Year/Info - use channel properties directly
    if (channel.hasLoadedMovieInfo && channel.movieYear && ![channel.movieYear isEqualToString:@"N/A"]) {
        NSDictionary *yearAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.7 alpha:1.0]
        };
        
        CGRect yearRect = CGRectMake(rect.origin.x + 8, rect.origin.y + posterHeight + 20, rect.size.width - 16, 12);
        [channel.movieYear drawInRect:yearRect withAttributes:yearAttrs];
    }
}

- (void)drawMovieStackedItem:(id)channelObj rect:(CGRect)rect isSelected:(BOOL)selected {
    if (![channelObj isKindOfClass:[VLCChannel class]]) return;
    VLCChannel *channel = (VLCChannel *)channelObj;
    
    // Background
    UIColor *bgColor = selected ? 
        [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.8] :
        [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:0.8];
    
    [bgColor setFill];
    UIBezierPath *bgPath = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:8];
    [bgPath fill];
    
    if (selected) {
        [[UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:1.0] setStroke];
        bgPath.lineWidth = 2.0;
        [bgPath stroke];
    }
    
    // Movie poster (left side)
    CGFloat posterWidth = 80;
    CGFloat posterHeight = rect.size.height - 20;
    CGRect posterRect = CGRectMake(rect.origin.x + 10, rect.origin.y + 10, posterWidth, posterHeight);
    
    // Fetch movie info and poster using shared Mac methods
    if (!channel.hasLoadedMovieInfo && !channel.hasStartedFetchingMovieInfo) {
        // Try cache first, then fetch from network if needed (using shared Mac implementation)
        [self fetchMovieInfoForChannel:channel];
    }
    
    // Trigger download if no cached image and not already loading (like macOS version)
    if (!channel.cachedPosterImage && channel.logo && 
        !objc_getAssociatedObject(channel, "imageLoadingInProgress")) {
        [self loadImageAsynchronously:channel.logo forChannel:channel];
    }
    
    BOOL drewPoster = NO;
    
    // Try to draw cached poster image
    if (channel.cachedPosterImage) {
        [channel.cachedPosterImage drawInRect:posterRect];
        drewPoster = YES;
    }
    
    if (!drewPoster) {
        // Placeholder
        [[UIColor colorWithRed:0.25 green:0.25 blue:0.3 alpha:0.8] setFill];
        UIBezierPath *placeholderPath = [UIBezierPath bezierPathWithRoundedRect:posterRect cornerRadius:4];
        [placeholderPath fill];
        
        NSString *icon = [channel.category isEqualToString:@"MOVIES"] ? @"🎬" : @"📺";
        NSDictionary *iconAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:24],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.6 alpha:1.0]
        };
        CGRect iconRect = CGRectMake(posterRect.origin.x + posterWidth/2 - 12, 
                                   posterRect.origin.y + posterHeight/2 - 12, 24, 24);
        [icon drawInRect:iconRect withAttributes:iconAttrs];
    }
    
    // Text area (right side)
    CGFloat textX = rect.origin.x + posterWidth + 20;
    CGFloat textWidth = rect.size.width - posterWidth - 30;
    
    // Title
    NSString *title = channel.name ?: @"Unknown";
    if (title.length > 30) {
        title = [[title substringToIndex:27] stringByAppendingString:@"..."];
    }
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGRect titleRect = CGRectMake(textX, rect.origin.y + 15, textWidth, 20);
    [title drawInRect:titleRect withAttributes:titleAttrs];
    
    // Movie info - use channel properties directly
    if (channel.hasLoadedMovieInfo) {
        NSMutableString *infoString = [NSMutableString string];
        
        if (channel.movieYear) [infoString appendString:channel.movieYear];
        if (channel.movieRating && ![channel.movieRating isEqualToString:@"N/A"]) {
            if (infoString.length > 0) [infoString appendString:@" • "];
            [infoString appendString:channel.movieRating];
        }
        if (channel.movieGenre && ![channel.movieGenre isEqualToString:@"N/A"]) {
            if (infoString.length > 0) [infoString appendString:@" • "];
            [infoString appendString:channel.movieGenre];
        }
        
        if (infoString.length > 0) {
            NSDictionary *infoAttrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:12],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.7 alpha:1.0]
            };
            
            CGRect infoRect = CGRectMake(textX, rect.origin.y + 37, textWidth, 16);
            [infoString drawInRect:infoRect withAttributes:infoAttrs];
        }
        
        // Description
        if (channel.movieDescription && ![channel.movieDescription isEqualToString:@"N/A"] && channel.movieDescription.length > 0) {
            NSString *desc = channel.movieDescription;
            if (desc.length > 80) {
                desc = [[desc substringToIndex:77] stringByAppendingString:@"..."];
            }
            
            NSDictionary *descAttrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:11],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1.0]
            };
            
            CGRect descRect = CGRectMake(textX, rect.origin.y + 55, textWidth, 40);
            [desc drawInRect:descRect withAttributes:descAttrs];
        }
    }
}

- (void)drawSettingsPanel:(CGRect)rect {
    //NSLog(@"🔧 drawSettingsPanel called for iOS with macOS compatibility");
    
    // Calculate responsive dimensions
    CGFloat catWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat settingsPanelX = catWidth + groupWidth;
    CGFloat settingsPanelWidth = rect.size.width - settingsPanelX;
    
    // Draw the settings panel background
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    // Create a semitransparent background like macOS
    CGContextSetRGBFillColor(context, 0.0, 0.0, 0.0, 0.7);
    CGContextFillRect(context, CGRectMake(settingsPanelX, 0, settingsPanelWidth, rect.size.height));
    
    // Don't cleanup existing settings UI elements - let show/hide methods manage them
    // [self cleanupSettingsUIElements]; // REMOVED - this was causing the scroll view to be destroyed
    
    // Get the actual settings groups like macOS does
    NSArray *settingsGroups = [self getGroupsForSelectedCategory];
    
    if (_selectedGroupIndex >= 0 && _selectedGroupIndex < [settingsGroups count]) {
        NSString *selectedGroup = [settingsGroups objectAtIndex:_selectedGroupIndex];
        //NSLog(@"🔧 Drawing settings for group: %@", selectedGroup);
        
        if ([selectedGroup isEqualToString:@"Playlist"]) {
            [self drawPlaylistSettingsPanel:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"General"]) {
            [self drawGeneralSettingsPanel:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"Subtitles"]) {
#if TARGET_OS_IOS
            [self drawSubtitleSettingsPanel:rect x:settingsPanelX width:settingsPanelWidth];
#else
            [self drawDefaultSettingsPanel:rect x:settingsPanelX width:settingsPanelWidth group:selectedGroup];
#endif
        } else if ([selectedGroup isEqualToString:@"Movie Info"]) {
            [self drawMovieInfoSettingsPanel:rect x:settingsPanelX width:settingsPanelWidth];
        } else if ([selectedGroup isEqualToString:@"Themes"]) {
            [self drawThemeSettingsPanel:rect x:settingsPanelX width:settingsPanelWidth];
        } else {
            [self drawDefaultSettingsPanel:rect x:settingsPanelX width:settingsPanelWidth group:selectedGroup];
        }
    } else {
        // No group selected, show helper message
        NSString *helpText = @"Select a settings group from the left panel";
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        
        CGRect helpRect = CGRectMake(settingsPanelX + 20, rect.size.height / 2 - 10, settingsPanelWidth - 40, 20);
        [helpText drawInRect:helpRect withAttributes:attrs];
    }
}

- (void)cleanupSettingsUIElements {
    // Remove any existing iOS settings UI elements
    if (_settingsScrollViewiOS) {
        [_settingsScrollViewiOS removeFromSuperview];
        [_settingsScrollViewiOS release];
        _settingsScrollViewiOS = nil;
    }
    if (_m3uTextFieldiOS) {
        [_m3uTextFieldiOS removeFromSuperview];
        [_m3uTextFieldiOS release];
        _m3uTextFieldiOS = nil;
    }
    if (_epgLabeliOS) {
        [_epgLabeliOS removeFromSuperview];
        [_epgLabeliOS release];
        _epgLabeliOS = nil;
    }
    if (_timeOffsetButtoniOS) {
        [_timeOffsetButtoniOS removeFromSuperview];
        [_timeOffsetButtoniOS release];
        _timeOffsetButtoniOS = nil;
    }
    
    // Clean up new specialized settings scroll views
    if (_themeSettingsScrollView) {
        [_themeSettingsScrollView removeFromSuperview];
        [_themeSettingsScrollView release];
        _themeSettingsScrollView = nil;
    }
    if (_subtitleSettingsScrollView) {
        [_subtitleSettingsScrollView removeFromSuperview];
        [_subtitleSettingsScrollView release];
        _subtitleSettingsScrollView = nil;
    }
    
    // Clear subtitle slider references
#if TARGET_OS_IOS
    _subtitleFontSizeSlider = nil; // These are subviews that get released with their parent scroll view
#endif
    _subtitleFontSizeLabel = nil;
    
    // Clean up loading panel
    [self hideLoadingPanel];
}

- (void)hideAllSettingsScrollViews {
    // Hide all settings-related scroll views when switching between groups or categories
    // Don't remove from superview to allow proper recreation
    if (_settingsScrollViewiOS) {
        _settingsScrollViewiOS.hidden = YES;
    }
    if (_themeSettingsScrollView) {
        _themeSettingsScrollView.hidden = YES;
    }
    if (_subtitleSettingsScrollView) {
        _subtitleSettingsScrollView.hidden = YES;
    }
}

#pragma mark - Settings Panel Methods (iOS Adaptations of macOS)

- (void)drawPlaylistSettingsPanel:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
#if TARGET_OS_TV
    // tvOS: Draw simple controls with highlighting
    [self drawTVOSPlaylistSettings:rect x:x width:width];
#else
    // iOS: Create or update the scroll view for settings
    [self createOrUpdateSettingsScrollView:rect x:x width:width];
#endif
}

- (void)drawGeneralSettingsPanel:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 20;
    CGFloat startY = rect.size.height - 80;
    CGFloat lineHeight = 25;
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGRect titleRect = CGRectMake(x + padding, startY, width - (padding * 2), lineHeight);
    [@"General Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGFloat currentY = startY - 40;
    
    // Show general settings info
    NSArray *generalSettings = @[
        @"• Application preferences and behavior",
        @"• Default playback settings and controls", 
        @"• Network configuration and timeout",
        @"• Cache management and storage",
        @"• Auto-play and resume settings",
        @"• Language and region preferences"
    ];
    
    for (NSString *setting in generalSettings) {
        CGRect settingRect = CGRectMake(x + padding, currentY, width - (padding * 2), lineHeight);
        [setting drawInRect:settingRect withAttributes:labelAttrs];
        currentY -= lineHeight + 5;
    }
}

#if TARGET_OS_IOS
- (void)drawSubtitleSettingsPanel:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
    // Create or update the scroll view for subtitle settings
    [self createOrUpdateSubtitleSettingsScrollView:rect x:x width:width];
}
#endif

- (void)drawMovieInfoSettingsPanel:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 20;
    CGFloat startY = rect.size.height - 80;
    CGFloat lineHeight = 25;
    CGFloat buttonHeight = 40;
    CGFloat buttonWidth = 260;
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGRect titleRect = CGRectMake(x + padding, startY, width - (padding * 2), lineHeight);
    [@"Movie Information Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    NSDictionary *descAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [UIColor lightGrayColor]
    };
    
    CGRect descRect = CGRectMake(x + padding, startY - 25, width - (padding * 2), 16);
    [@"Manage movie information and poster images" drawInRect:descRect withAttributes:descAttrs];
    
    // Get cache directory info
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *cacheDir = [documentsPath stringByAppendingPathComponent:@"VLCCache"];
    NSString *movieInfoCacheDir = [cacheDir stringByAppendingPathComponent:@"MovieInfo"];
    NSString *posterCacheDir = [cacheDir stringByAppendingPathComponent:@"Posters"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    // Count files in cache directories
    NSInteger movieInfoCount = 0;
    NSInteger posterCount = 0;
    NSError *error = nil;
    
    if ([fileManager fileExistsAtPath:movieInfoCacheDir]) {
        NSArray *files = [fileManager contentsOfDirectoryAtPath:movieInfoCacheDir error:&error];
        if (!error) {
            movieInfoCount = files.count;
        }
    }
    
    if ([fileManager fileExistsAtPath:posterCacheDir]) {
        NSArray *posterFiles = [fileManager contentsOfDirectoryAtPath:posterCacheDir error:&error];
        if (!error) {
            posterCount = posterFiles.count;
        }
    }
    
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGFloat currentY = startY - 60;
    
    // Show cache information
    NSString *cacheInfo = [NSString stringWithFormat:@"• Movie info files cached: %ld", (long)movieInfoCount];
    CGRect cacheRect = CGRectMake(x + padding, currentY, width - (padding * 2), lineHeight);
    [cacheInfo drawInRect:cacheRect withAttributes:labelAttrs];
    currentY -= lineHeight + 5;
    
    NSString *posterInfo = [NSString stringWithFormat:@"• Movie posters cached: %ld", (long)posterCount];
    CGRect posterRect = CGRectMake(x + padding, currentY, width - (padding * 2), lineHeight);
    [posterInfo drawInRect:posterRect withAttributes:labelAttrs];
    currentY -= lineHeight + 15;
    
    // Draw cache management buttons
    CGRect clearCacheButtonRect = CGRectMake(x + padding, currentY, buttonWidth, buttonHeight);
    
    // Draw button background
    [[UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0] setFill];
    UIBezierPath *buttonPath = [UIBezierPath bezierPathWithRoundedRect:clearCacheButtonRect cornerRadius:8];
    [buttonPath fill];
    
    // Draw button text
    NSDictionary *buttonAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:14],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGRect buttonTextRect = CGRectMake(clearCacheButtonRect.origin.x + 10,
                                      clearCacheButtonRect.origin.y + 12,
                                      clearCacheButtonRect.size.width - 20,
                                      clearCacheButtonRect.size.height - 24);
    [@"Clear Movie Info Cache" drawInRect:buttonTextRect withAttributes:buttonAttrs];
    
    // Store button rect for touch handling
    _clearMovieInfoCacheButtonRect = clearCacheButtonRect;
}

- (void)drawThemeSettingsPanel:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
#if TARGET_OS_TV
    // tvOS: Draw theme controls with highlighting
    [self drawTVOSThemeSettings:rect x:x width:width];
#else
    // iOS: Create or update the scroll view for theme settings
    [self createOrUpdateThemeSettingsScrollView:rect x:x width:width];
#endif
}

- (void)drawDefaultSettingsPanel:(CGRect)rect x:(CGFloat)x width:(CGFloat)width group:(NSString *)groupName {
    CGFloat padding = 20;
    CGFloat startY = rect.size.height - 80;
    CGFloat lineHeight = 25;
    
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    NSString *title = [NSString stringWithFormat:@"%@ Settings", groupName];
    CGRect titleRect = CGRectMake(x + padding, startY, width - (padding * 2), lineHeight);
    [title drawInRect:titleRect withAttributes:titleAttrs];
    
    NSDictionary *labelAttrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [UIColor lightGrayColor]
    };
    
    CGFloat currentY = startY - 40;
    NSString *placeholder = [NSString stringWithFormat:@"Settings for %@ will be implemented here", groupName];
    CGRect placeholderRect = CGRectMake(x + padding, currentY, width - (padding * 2), lineHeight);
    [placeholder drawInRect:placeholderRect withAttributes:labelAttrs];
}

#pragma mark - Interactive Settings UI Elements (iOS)

- (void)createOrUpdateSettingsScrollView:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
    // Only recreate if scroll view doesn't exist or size changed significantly
    BOOL needsRecreation = NO;
    if (!_settingsScrollViewiOS) {
        needsRecreation = YES;
    } else {
        CGRect currentFrame = _settingsScrollViewiOS.frame;
        CGRect newFrame = CGRectMake(x, 0, width, rect.size.height);
        if (fabs(currentFrame.size.width - newFrame.size.width) > 10 || 
            fabs(currentFrame.size.height - newFrame.size.height) > 10) {
            needsRecreation = YES;
        }
    }
    
    if (!needsRecreation) {
        // Just update the frame and ensure it's visible
        _settingsScrollViewiOS.frame = CGRectMake(x, 0, width, rect.size.height);
        _settingsScrollViewiOS.hidden = NO; // Ensure it's visible after auto-hide
        NSLog(@"📱 [SETTINGS-PANEL] Settings scroll view already exists - making visible and updating frame");
        return;
    }
    
    // Remove existing scroll view if it exists
    if (_settingsScrollViewiOS) {
        [_settingsScrollViewiOS removeFromSuperview];
        [_settingsScrollViewiOS release];
        _settingsScrollViewiOS = nil;
    }
    
    // Create scroll view
    CGRect scrollFrame = CGRectMake(x, 0, width, rect.size.height);
    _settingsScrollViewiOS = [[UIScrollView alloc] initWithFrame:scrollFrame];
    _settingsScrollViewiOS.backgroundColor = [UIColor clearColor];
    _settingsScrollViewiOS.showsVerticalScrollIndicator = YES;
    _settingsScrollViewiOS.showsHorizontalScrollIndicator = NO;
    
    // Create content view inside scroll view
    CGFloat padding = 20;
    CGFloat lineHeight = 25;
    CGFloat fieldHeight = 35;
    CGFloat buttonHeight = 40;
    CGFloat currentY = padding;
    
    // Section title
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Playlist Settings";
    titleLabel.font = [UIFont boldSystemFontOfSize:16];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.frame = CGRectMake(padding, currentY, width - (padding * 2), lineHeight);
    [_settingsScrollViewiOS addSubview:titleLabel];
    [titleLabel release];
    currentY += lineHeight + 20;
    
    // M3U URL Label
    UILabel *m3uLabel = [[UILabel alloc] init];
    m3uLabel.text = @"M3U URL:";
    m3uLabel.font = [UIFont systemFontOfSize:14];
    m3uLabel.textColor = [UIColor whiteColor];
    m3uLabel.frame = CGRectMake(padding, currentY, width - (padding * 2), lineHeight);
    [_settingsScrollViewiOS addSubview:m3uLabel];
    [m3uLabel release];
    currentY += lineHeight + 5;
    
    // M3U URL Text Field
    [self createOrUpdateM3UTextField:CGRectMake(padding, currentY, width - (padding * 2), fieldHeight) inParent:_settingsScrollViewiOS];
    currentY += fieldHeight + 10;
    
    // Load URL Button
    self.loadUrlButtoniOS = [self createActionButton:@"Load URL" 
                                                 frame:CGRectMake(padding, currentY, 120, buttonHeight)
                                                action:@selector(loadUrlButtonTapped:)];
    [_settingsScrollViewiOS addSubview:self.loadUrlButtoniOS];
    currentY += buttonHeight + 20;
    
    // EPG URL Label
    UILabel *epgLabel = [[UILabel alloc] init];
    epgLabel.text = @"EPG XML URL (auto-generated):";
    epgLabel.font = [UIFont systemFontOfSize:14];
    epgLabel.textColor = [UIColor whiteColor];
    epgLabel.frame = CGRectMake(padding, currentY, width - (padding * 2), lineHeight);
    [_settingsScrollViewiOS addSubview:epgLabel];
    [epgLabel release];
    currentY += lineHeight + 5;
    
    // EPG URL Display
    [self createOrUpdateEPGLabel:CGRectMake(padding, currentY, width - (padding * 2), fieldHeight) inParent:_settingsScrollViewiOS];
    currentY += fieldHeight + 10;
    
    // Update EPG Button
    self.updateEpgButtoniOS = [self createActionButton:@"Update EPG" 
                                                   frame:CGRectMake(padding, currentY, 120, buttonHeight)
                                                  action:@selector(updateEpgButtonTapped:)];
    [_settingsScrollViewiOS addSubview:self.updateEpgButtoniOS];
    currentY += buttonHeight + 20;
    
    // EPG Time Offset Label
    UILabel *offsetLabel = [[UILabel alloc] init];
    offsetLabel.text = @"EPG Time Offset:";
    offsetLabel.font = [UIFont systemFontOfSize:14];
    offsetLabel.textColor = [UIColor whiteColor];
    offsetLabel.frame = CGRectMake(padding, currentY, width - (padding * 2), lineHeight);
    [_settingsScrollViewiOS addSubview:offsetLabel];
    [offsetLabel release];
    currentY += lineHeight + 5;
    
    // EPG Time Offset Button
    [self createOrUpdateTimeOffsetButton:CGRectMake(padding, currentY, 150, fieldHeight) inParent:_settingsScrollViewiOS];
    currentY += fieldHeight + 30;
    
    // Additional Settings Section
    UILabel *additionalLabel = [[UILabel alloc] init];
    additionalLabel.text = @"Additional Actions:";
    additionalLabel.font = [UIFont boldSystemFontOfSize:16];
    additionalLabel.textColor = [UIColor whiteColor];
    additionalLabel.frame = CGRectMake(padding, currentY, width - (padding * 2), lineHeight);
    [_settingsScrollViewiOS addSubview:additionalLabel];
    [additionalLabel release];
    currentY += lineHeight + 15;
    
    // Clear Cache Button
    UIButton *clearCacheButton = [self createActionButton:@"Clear Cache" 
                                                     frame:CGRectMake(padding, currentY, 120, buttonHeight)
                                                    action:@selector(clearCacheButtonTapped:)];
    [_settingsScrollViewiOS addSubview:clearCacheButton];
    
    // Reload Channels Button - properly aligned next to Clear Cache button
    UIButton *reloadChannelsButton = [self createActionButton:@"Reload Channels" 
                                                         frame:CGRectMake(padding + 130, currentY, 140, buttonHeight)
                                                        action:@selector(reloadChannelsButtonTapped:)];
    [_settingsScrollViewiOS addSubview:reloadChannelsButton];
    currentY += buttonHeight + 20;
    
    // Instructions
    UILabel *instructionLabel = [[UILabel alloc] init];
    instructionLabel.text = @"Settings changes are automatically saved and sync with the macOS version.";
    instructionLabel.font = [UIFont systemFontOfSize:12];
    instructionLabel.textColor = [UIColor lightGrayColor];
    instructionLabel.numberOfLines = 0;
    instructionLabel.frame = CGRectMake(padding, currentY, width - (padding * 2), lineHeight * 2);
    [_settingsScrollViewiOS addSubview:instructionLabel];
    [instructionLabel release];
    currentY += lineHeight * 2 + padding;
    
    // Set scroll view content size
    _settingsScrollViewiOS.contentSize = CGSizeMake(width, currentY);
    
    [self addSubview:_settingsScrollViewiOS];
}

- (UIButton *)createActionButton:(NSString *)title frame:(CGRect)frame action:(SEL)action {
    UIButton *button = [[UIButton alloc] initWithFrame:frame];
    button.backgroundColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:0.8];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14];
    button.layer.cornerRadius = 8;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithRed:0.0 green:0.4 blue:0.8 alpha:1.0].CGColor;
    
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    
    return [button autorelease];
}

- (void)createOrUpdateM3UTextField:(CGRect)frame {
    [self createOrUpdateM3UTextField:frame inParent:self];
}

- (void)createOrUpdateM3UTextField:(CGRect)frame inParent:(UIView *)parent {
    // Remove existing text field if it exists
    if (_m3uTextFieldiOS) {
        [_m3uTextFieldiOS removeFromSuperview];
        [_m3uTextFieldiOS release];
        _m3uTextFieldiOS = nil;
    }
    
    // Create new text field
    _m3uTextFieldiOS = [[UITextField alloc] initWithFrame:frame];
    _m3uTextFieldiOS.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.8];
    _m3uTextFieldiOS.textColor = [UIColor whiteColor];
    _m3uTextFieldiOS.font = [UIFont systemFontOfSize:14];
    _m3uTextFieldiOS.borderStyle = UITextBorderStyleRoundedRect;
    _m3uTextFieldiOS.placeholder = @"Enter M3U URL or path";
    _m3uTextFieldiOS.text = self.m3uFilePath ?: @"";
    _m3uTextFieldiOS.delegate = self;
    _m3uTextFieldiOS.returnKeyType = UIReturnKeyDone;
    _m3uTextFieldiOS.clearButtonMode = UITextFieldViewModeWhileEditing;
    
    [parent addSubview:_m3uTextFieldiOS];
}

- (void)createOrUpdateEPGLabel:(CGRect)frame {
    [self createOrUpdateEPGLabel:frame inParent:self];
}

- (void)createOrUpdateEPGLabel:(CGRect)frame inParent:(UIView *)parent {
    // Remove existing label if it exists
    if (_epgLabeliOS) {
        [_epgLabeliOS removeFromSuperview];
        [_epgLabeliOS release];
        _epgLabeliOS = nil;
    }
    
    // Create new label that looks like a text field but is clickable
    _epgLabeliOS = [[UILabel alloc] initWithFrame:frame];
    _epgLabeliOS.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.8];
    _epgLabeliOS.textColor = [UIColor lightGrayColor];
    _epgLabeliOS.font = [UIFont systemFontOfSize:14];
    _epgLabeliOS.layer.cornerRadius = 8;
    _epgLabeliOS.layer.borderWidth = 1;
    _epgLabeliOS.layer.borderColor = [UIColor darkGrayColor].CGColor;
    _epgLabeliOS.textAlignment = NSTextAlignmentLeft;
    _epgLabeliOS.userInteractionEnabled = YES;
    
    // Set EPG URL text - auto-generate if needed
    NSString *epgText;
    if (self.epgUrl && [self.epgUrl length] > 0) {
        epgText = self.epgUrl;
    } else if (self.m3uFilePath && [self.m3uFilePath hasPrefix:@"http"]) {
        // Auto-generate and display the EPG URL
        [self updateEPGURLFromM3U];
        epgText = self.epgUrl ?: @"Auto-generated from M3U URL";
    } else {
        epgText = @"Enter M3U URL first to auto-generate";
    }
    _epgLabeliOS.text = [NSString stringWithFormat:@"  %@", epgText]; // Add padding
    
    // Add tap gesture
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(epgLabelTapped:)];
    [_epgLabeliOS addGestureRecognizer:tapGesture];
    [tapGesture release];
    
    [parent addSubview:_epgLabeliOS];
}

- (void)createOrUpdateTimeOffsetButton:(CGRect)frame {
    [self createOrUpdateTimeOffsetButton:frame inParent:self];
}

- (void)createOrUpdateTimeOffsetButton:(CGRect)frame inParent:(UIView *)parent {
    // Remove existing button if it exists
    if (_timeOffsetButtoniOS) {
        [_timeOffsetButtoniOS removeFromSuperview];
        [_timeOffsetButtoniOS release];
        _timeOffsetButtoniOS = nil;
    }
    
    // Create new button
    _timeOffsetButtoniOS = [[UIButton alloc] initWithFrame:frame];
    _timeOffsetButtoniOS.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.8];
    [_timeOffsetButtoniOS setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _timeOffsetButtoniOS.titleLabel.font = [UIFont systemFontOfSize:14];
    _timeOffsetButtoniOS.layer.cornerRadius = 8;
    _timeOffsetButtoniOS.layer.borderWidth = 1;
    _timeOffsetButtoniOS.layer.borderColor = [UIColor darkGrayColor].CGColor;
    _timeOffsetButtoniOS.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    
    // Set current offset value with debugging
    NSInteger offset = (NSInteger)self.epgTimeOffsetHours;
    NSString *offsetText = [NSString stringWithFormat:@"  %+d hours", (int)offset];
    [_timeOffsetButtoniOS setTitle:offsetText forState:UIControlStateNormal];
    NSLog(@"🔧 [EPG-BUTTON] Created EPG offset button with value: %+d hours (epgTimeOffsetHours=%.1f)", (int)offset, self.epgTimeOffsetHours);
    
    [_timeOffsetButtoniOS addTarget:self action:@selector(timeOffsetButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    
    [parent addSubview:_timeOffsetButtoniOS];
}

#pragma mark - Settings Action Handlers (iOS)

- (void)loadUrlButtonTapped:(UIButton *)button {
    NSLog(@"🔧 Load URL button tapped");
    
    // Disable buttons during loading
    [self setLoadingButtonsEnabled:NO];
    
    // Set manual loading flag to protect loading panel from auto-hide
    self.isManualLoadingInProgress = YES;
    self.isLoadingBothChannelsAndEPG = YES;
    NSLog(@"📱 [MANUAL-LOAD] Manual loading started - protecting loading panel from auto-hide");
    NSLog(@"📱 [FULL-RELOAD] Full reload started - will load both channels and EPG");
    
    // Check current loading states first
    NSLog(@"🔧 Current loading states - M3U: %d, EPG: %d, isLoading: %d", _isDownloadingChannels, _isDownloadingEPG, self.isLoading);
    
    NSString *m3uUrl = _m3uTextFieldiOS.text;
    if (m3uUrl && [m3uUrl length] > 0) {
        // Ensure we have a clean state before starting
        NSLog(@"🔧 About to clear channel loading state...");
        [self clearChannelLoadingState];
        NSLog(@"🔧 Channel loading state cleared - new states: downloading=%d, isLoading=%d", _isDownloadingChannels, self.isLoading);
        
        // Update the property
        self.m3uFilePath = m3uUrl;
        
        // Show startup progress window for better progress visibility
        [self showStartupProgressWindow];
        [self updateStartupProgress:0.05 step:@"Starting" details:@"Preparing to load M3U URL..."];
        
        // CRITICAL FIX: Force fresh download from URL (not cache)
        NSLog(@"🚀 [LOAD-URL] Force downloading fresh channels from URL (bypassing cache)");
        
        // Use VLCDataManager's proper unified loading system
        NSLog(@"🔧 [LOAD-URL] Using VLCDataManager unified loading system");
        
        // Set the URLs in data manager
            self.dataManager.m3uURL = m3uUrl;
            
        // Auto-generate EPG URL and set it in data manager
        [self updateEPGURLFromM3U];
        if (self.epgUrl && [self.epgUrl length] > 0) {
            self.dataManager.epgURL = self.epgUrl;
            NSLog(@"🔧 [LOAD-URL] Set EPG URL in DataManager: %@", self.epgUrl);
        }
        
        // Use VLCDataManager's forceReloadChannels method which handles everything properly
        [self.dataManager forceReloadChannels];
        
        // Update EPG label to show the auto-generated URL
        if (_epgLabeliOS) {
            NSString *epgText = self.epgUrl ?: @"Auto-generated from M3U URL";
            _epgLabeliOS.text = [NSString stringWithFormat:@"  %@", epgText];
        }
        
        // Save settings
        [self saveSettings];
        
        // Set flag to force fresh EPG download after channels load
        _shouldForceEPGDownloadAfterChannels = YES;
        
        NSLog(@"🔧 M3U URL loaded: %@ (Both channels and EPG will be force downloaded fresh)", m3uUrl);
    } else {
        [self showBriefMessage:@"Please enter a valid M3U URL first" at:button.center];
    }
}

- (void)updateEpgButtonTapped:(UIButton *)button {
    NSLog(@"🔧 [UPDATE-EPG-BUTTON] ===== UPDATE EPG BUTTON CLICKED =====");
    
    // Disable buttons during loading
    [self setLoadingButtonsEnabled:NO];
    
    // Set manual loading flag to protect loading panel from auto-hide
    self.isManualLoadingInProgress = YES;
    NSLog(@"📱 [MANUAL-LOAD] Manual EPG loading started - protecting loading panel from auto-hide");
    
    // Try to auto-generate EPG URL if it's missing
    if (self.m3uFilePath && [self.m3uFilePath hasPrefix:@"http"]) {
        NSString *generatedEpgUrl = [self.m3uFilePath stringByReplacingOccurrencesOfString:@"get.php" withString:@"xmltv.php"];
        
        if (![generatedEpgUrl isEqualToString:self.m3uFilePath]) {
            if (!self.epgUrl || [self.epgUrl length] == 0 || ![self.epgUrl isEqualToString:generatedEpgUrl]) {
                self.epgUrl = generatedEpgUrl;
                [self saveSettings]; // Save the updated URL
            }
        }
    }
    
    NSString *epgUrl = self.epgUrl;
    
    if (epgUrl && [epgUrl length] > 0) {
        // Show loading panel
        [self showLoadingPanel];
        
        // FORCE FRESH EPG DOWNLOAD: Use VLCDataManager  
        NSLog(@"🔧 [UPDATE-EPG] About to call VLCDataManager forceReloadEPG");
        if (self.epgUrl && ![self.epgUrl isEqualToString:@""]) {
            NSLog(@"🔧 [UPDATE-EPG] ✅ Setting EPG URL in DataManager: %@", self.epgUrl);
            
            // CRITICAL: Set the EPG URL in the DataManager before calling forceReloadEPG
            self.dataManager.epgURL = self.epgUrl;
            
            NSLog(@"🔧 [UPDATE-EPG] ✅ Calling VLCDataManager forceReloadEPG");
            [self.dataManager forceReloadEPG];
        } else {
            NSLog(@"🔧 [UPDATE-EPG] ❌ No EPG URL - cannot force reload");
            // Fallback: bypass cache manually and call direct download
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self loadEpgDataWithRetryCount:0];
            });
        }
    } else {
        [self showBriefMessage:@"Load M3U URL first to generate EPG URL" at:button.center];
    }
}



#pragma mark - Settings UI Actions (iOS)

- (void)epgLabelTapped:(UITapGestureRecognizer *)gesture {
    NSString *epgUrl = self.epgUrl;
    if (epgUrl && [epgUrl length] > 0) {
        #if TARGET_OS_IOS
        // Copy EPG URL to clipboard (iOS only)
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = epgUrl;
        [self showBriefMessage:@"EPG URL copied to clipboard" at:_epgLabeliOS.center];
        #else
        // tvOS doesn't have clipboard
        [self showBriefMessage:@"EPG URL displayed (clipboard not available on tvOS)" at:_epgLabeliOS.center];
        #endif
    } else {
        [self showBriefMessage:@"Enter M3U URL first to generate EPG URL" at:_epgLabeliOS.center];
    }
}

- (void)timeOffsetButtonTapped:(UIButton *)button {
    NSLog(@"🔧 Time offset button tapped");
    
    // Create action sheet with time offset options
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:@"EPG Time Offset" 
                                                                         message:@"Select timezone offset for EPG data" 
                                                                  preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Add offset options from -12 to +12 hours
    for (NSInteger offset = -12; offset <= 12; offset++) {
        NSString *title = [NSString stringWithFormat:@"%+d hours", (int)offset];
        UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self setEpgTimeOffset:offset];
        }];
        [actionSheet addAction:action];
    }
    
    // Add cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [actionSheet addAction:cancelAction];
    
    // Configure popover for iPad
    if (actionSheet.popoverPresentationController) {
        actionSheet.popoverPresentationController.sourceView = button;
        actionSheet.popoverPresentationController.sourceRect = button.bounds;
        actionSheet.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    
    // Present action sheet
    UIViewController *rootVC = [self findRootViewController];
    if (rootVC) {
        [rootVC presentViewController:actionSheet animated:YES completion:nil];
    }
}

- (void)setEpgTimeOffset:(NSInteger)offset {
    // Update the offset value
    self.epgTimeOffsetHours = offset;
    
    // Update button title with proper padding
    NSString *offsetText = [NSString stringWithFormat:@"  %+d hours", (int)offset];
    [_timeOffsetButtoniOS setTitle:offsetText forState:UIControlStateNormal];
    
    // Save the setting
    [self saveSettings];
    
    NSLog(@"🔧 EPG time offset set to %+d hours and saved", (int)offset);
}

- (void)showBriefMessage:(NSString *)message at:(CGPoint)point {
    // Create a brief popup message
    UILabel *messageLabel = [[UILabel alloc] init];
    messageLabel.text = message;
    messageLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.8];
    messageLabel.textColor = [UIColor whiteColor];
    messageLabel.font = [UIFont systemFontOfSize:12];
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.layer.cornerRadius = 6;
    messageLabel.clipsToBounds = YES;
    
    // Size to fit content
    [messageLabel sizeToFit];
    CGRect frame = messageLabel.frame;
    frame.size.width += 20; // Add padding
    frame.size.height += 10;
    messageLabel.frame = frame;
    messageLabel.center = point;
    
    [self addSubview:messageLabel];
    
    // Fade out after 2 seconds
    [UIView animateWithDuration:0.3 delay:2.0 options:0 animations:^{
        messageLabel.alpha = 0.0;
    } completion:^(BOOL finished) {
        [messageLabel removeFromSuperview];
        [messageLabel release];
    }];
}

#pragma mark - Loading Panel (iOS - matching macOS style)

- (void)showLoadingPanel {
    // Remove existing panel if it exists
    [self hideLoadingPanel];
    
    // Create loading panel container (positioned at bottom right like macOS)
    CGFloat panelWidth = 300;
    CGFloat panelHeight = 120;
    CGFloat padding = 20;
    CGFloat panelX = self.bounds.size.width - panelWidth - padding;
    CGFloat panelY = self.bounds.size.height - panelHeight - padding;
    
    _loadingPaneliOS = [[UIView alloc] initWithFrame:CGRectMake(panelX, panelY, panelWidth, panelHeight)];
    _loadingPaneliOS.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
    _loadingPaneliOS.layer.cornerRadius = 12;
    _loadingPaneliOS.layer.borderWidth = 1;
    _loadingPaneliOS.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    _loadingPaneliOS.layer.shadowColor = [UIColor blackColor].CGColor;
    _loadingPaneliOS.layer.shadowOffset = CGSizeMake(0, 2);
    _loadingPaneliOS.layer.shadowOpacity = 0.5;
    _loadingPaneliOS.layer.shadowRadius = 4;
    
    CGFloat contentPadding = 15;
    CGFloat currentY = contentPadding;
    
    // Loading title
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"Loading...";
    titleLabel.font = [UIFont boldSystemFontOfSize:16];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.frame = CGRectMake(contentPadding, currentY, panelWidth - (contentPadding * 2), 20);
    [_loadingPaneliOS addSubview:titleLabel];
    [titleLabel release];
    currentY += 25;
    
    // M3U Progress Label
    _m3uProgressLabeliOS = [[UILabel alloc] init];
    _m3uProgressLabeliOS.text = @"M3U: Ready";
    _m3uProgressLabeliOS.font = [UIFont systemFontOfSize:12];
    _m3uProgressLabeliOS.textColor = [UIColor lightGrayColor];
    _m3uProgressLabeliOS.frame = CGRectMake(contentPadding, currentY, panelWidth - (contentPadding * 2), 15);
    [_loadingPaneliOS addSubview:_m3uProgressLabeliOS];
    currentY += 18;
    
    // M3U Progress Bar
    _m3uProgressBariOS = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _m3uProgressBariOS.frame = CGRectMake(contentPadding, currentY, panelWidth - (contentPadding * 2), 2);
    _m3uProgressBariOS.progressTintColor = [UIColor colorWithRed:0.0 green:0.6 blue:1.0 alpha:1.0];
    _m3uProgressBariOS.trackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    _m3uProgressBariOS.progress = 0.0f;
    _m3uProgressBariOS.hidden = YES; // Start hidden - only show during actual downloads
    [_loadingPaneliOS addSubview:_m3uProgressBariOS];
    currentY += 15;
    
    // EPG Progress Label
    _epgProgressLabeliOS = [[UILabel alloc] init];
    _epgProgressLabeliOS.text = @"EPG: Ready";
    _epgProgressLabeliOS.font = [UIFont systemFontOfSize:12];
    _epgProgressLabeliOS.textColor = [UIColor lightGrayColor];
    _epgProgressLabeliOS.frame = CGRectMake(contentPadding, currentY, panelWidth - (contentPadding * 2), 15);
    [_loadingPaneliOS addSubview:_epgProgressLabeliOS];
    currentY += 18;
    
    // EPG Progress Bar
    _epgProgressBariOS = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _epgProgressBariOS.frame = CGRectMake(contentPadding, currentY, panelWidth - (contentPadding * 2), 2);
    _epgProgressBariOS.progressTintColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.4 alpha:1.0];
    _epgProgressBariOS.trackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    _epgProgressBariOS.progress = 0.0f;
    _epgProgressBariOS.hidden = YES; // Start hidden - only show during actual downloads
    [_loadingPaneliOS addSubview:_epgProgressBariOS];
    
    // Add panel to view with animation
    _loadingPaneliOS.alpha = 0.0;
    _loadingPaneliOS.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [self addSubview:_loadingPaneliOS];
    
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0 animations:^{
        self->_loadingPaneliOS.alpha = 1.0;
        self->_loadingPaneliOS.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)hideLoadingPanel {
    // Don't hide loading panel if we're doing a full reload (channels + EPG)
    if (self.isLoadingBothChannelsAndEPG && self.isManualLoadingInProgress) {
        NSLog(@"🚧 [LOADING-PANEL] Ignoring hide command - full reload in progress");
        return;
    }
    
    if (_loadingPaneliOS) {
        [UIView animateWithDuration:0.2 animations:^{
            self->_loadingPaneliOS.alpha = 0.0;
            self->_loadingPaneliOS.transform = CGAffineTransformMakeScale(0.9, 0.9);
        } completion:^(BOOL finished) {
            [self->_loadingPaneliOS removeFromSuperview];
            [self->_loadingPaneliOS release];
            self->_loadingPaneliOS = nil;
            
            // Clean up progress elements
            [self->_m3uProgressLabeliOS release];
            self->_m3uProgressLabeliOS = nil;
            [self->_m3uProgressBariOS release];
            self->_m3uProgressBariOS = nil;
            [self->_epgProgressLabeliOS release];
            self->_epgProgressLabeliOS = nil;
            [self->_epgProgressBariOS release];
            self->_epgProgressBariOS = nil;
        }];
    }
}

- (void)updateLoadingProgress:(float)progress status:(NSString *)status {
    if (_m3uProgressBariOS && _m3uProgressLabeliOS) {
        _m3uProgressBariOS.progress = progress;
        _m3uProgressLabeliOS.text = [NSString stringWithFormat:@"M3U: %@", status];
        
        // Only set properties if they're different to avoid recursion
        if (self.isLoading != (progress < 1.0f)) {
            _isLoading = progress < 1.0f; // Set backing variable directly
        }
        
        // Auto-hide loading panel when complete
        if (progress >= 1.0f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self.isLoadingEpg) { // Only hide if EPG is not loading
                    [self hideLoadingPanel];
                    [self showBriefMessage:@"M3U file loaded successfully" at:CGPointMake(self.bounds.size.width - 150, self.bounds.size.height - 50)];
                }
            });
        }
    }
}

- (void)updateEPGLoadingProgress:(float)progress status:(NSString *)status {
    if (_epgProgressBariOS && _epgProgressLabeliOS) {
        _epgProgressBariOS.progress = progress;
        _epgProgressLabeliOS.text = [NSString stringWithFormat:@"EPG: %@", status];
        
        // Only set properties if they're different to avoid recursion
        if (self.isLoadingEpg != (progress < 1.0f)) {
            _isLoadingEpg = progress < 1.0f; // Set backing variable directly
        }
        
        // Auto-hide loading panel when complete
        if (progress >= 1.0f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self.isLoading) { // Only hide if M3U is not loading
                    [self hideLoadingPanel];
                    [self showBriefMessage:@"EPG data updated successfully" at:CGPointMake(self.bounds.size.width - 150, self.bounds.size.height - 50)];
                }
            });
        }
    }
}

#pragma mark - UITextFieldDelegate (iOS)

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    if (textField == _m3uTextFieldiOS) {
        // Get the text that will be in the field after this change
        NSString *newText = [textField.text stringByReplacingCharactersInRange:range withString:string];
        
        // Real-time EPG URL generation as user types (like macOS)
        NSLog(@"🔧 [REAL-TIME] M3U URL changing to: %@", newText);
        
        // Auto-generate EPG URL from the new M3U URL in real-time
        if (newText && [newText length] > 0 && [newText hasPrefix:@"http"]) {
            NSString *generatedEpgUrl = [newText stringByReplacingOccurrencesOfString:@"get.php" withString:@"xmltv.php"];
            
            // Fallback: Also try .m3u to .xml replacement for different URL formats
            if ([generatedEpgUrl isEqualToString:newText]) {
                // No replacement occurred, try file extension replacement
                generatedEpgUrl = [newText stringByReplacingOccurrencesOfString:@".m3u" withString:@".xml"];
                generatedEpgUrl = [generatedEpgUrl stringByReplacingOccurrencesOfString:@".M3U" withString:@".xml"];
            }
            
            // Only update if it generated a different URL
            if (![generatedEpgUrl isEqualToString:newText] && [generatedEpgUrl length] > 0) {
                self.epgUrl = generatedEpgUrl;
                NSLog(@"🔧 [REAL-TIME] Auto-generated EPG URL: %@", generatedEpgUrl);
                
                // Update EPG label immediately
                if (_epgLabeliOS) {
                    _epgLabeliOS.text = [NSString stringWithFormat:@"  %@", generatedEpgUrl];
                }
            }
        } else if ([newText length] == 0) {
            // Clear EPG URL when M3U URL is empty
            self.epgUrl = @"";
            if (_epgLabeliOS) {
                _epgLabeliOS.text = @"  Enter M3U URL first to auto-generate";
            }
            NSLog(@"🔧 [REAL-TIME] Cleared EPG URL (M3U URL is empty)");
        }
        
        // Temporarily store the new M3U text for real-time feedback
        // Note: Don't save to self.m3uFilePath yet - wait for textFieldDidEndEditing
    }
    
    // Allow the text change
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == _m3uTextFieldiOS) {
        // Update M3U file path (final save)
        self.m3uFilePath = textField.text;
        NSLog(@"🔧 M3U URL finalized to: %@", textField.text);
        
        // Final EPG URL update and save
        [self updateEPGURLFromM3U];
        
        // Final EPG label refresh
        if (_epgLabeliOS) {
            NSString *epgText = self.epgUrl ?: @"Auto-generated from M3U URL";
            _epgLabeliOS.text = [NSString stringWithFormat:@"  %@", epgText];
        }
        
        // Save settings
        [self saveSettings];
    }
}

- (void)updateEPGURLFromM3U {
    NSString *m3uUrl = self.m3uFilePath;
    if (m3uUrl && [m3uUrl hasPrefix:@"http"]) {
        // Generate EPG URL by replacing get.php with xmltv.php (like macOS)
        // This keeps all parameters including type=m3u_plus intact
        NSString *epgUrl = [m3uUrl stringByReplacingOccurrencesOfString:@"get.php" withString:@"xmltv.php"];
        
        // Fallback: Also try .m3u to .xml replacement for different URL formats
        if ([epgUrl isEqualToString:m3uUrl]) {
            // No replacement occurred, try file extension replacement
            epgUrl = [m3uUrl stringByReplacingOccurrencesOfString:@".m3u" withString:@".xml"];
        epgUrl = [epgUrl stringByReplacingOccurrencesOfString:@".M3U" withString:@".xml"];
        }
        
        self.epgUrl = epgUrl;
        NSLog(@"🔧 EPG URL auto-generated from M3U: %@", epgUrl);
        NSLog(@"🔧 Original M3U URL: %@", m3uUrl);
    } else {
        NSLog(@"🔧 Cannot auto-generate EPG URL - M3U URL is invalid or missing");
    }
}

- (UIViewController *)findRootViewController {
    // Find the root view controller properly for iOS 13+
    UIViewController *rootVC = nil;
    
    if (@available(iOS 13.0, *)) {
        // Use connected scenes for iOS 13+
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *window in scene.windows) {
                    if (window.isKeyWindow) {
                        rootVC = window.rootViewController;
                        break;
                    }
                }
                if (rootVC) break;
            }
        }
    } else {
        // Fallback for iOS 12 and earlier
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        #pragma clang diagnostic pop
    }
    
    // Find the topmost presented view controller
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    
    return rootVC;
}

#pragma mark - Data Access Methods (Shared with macOS)

- (NSArray *)getGroupsForSelectedCategory {
    // Thread-safe access with proper error handling
    @synchronized(self) {
        @try {
    NSString *categoryKey = @"";
    switch (_selectedCategoryIndex) {
        case CATEGORY_SEARCH: categoryKey = @"SEARCH"; break;
        case CATEGORY_FAVORITES: categoryKey = @"FAVORITES"; break;
        case CATEGORY_TV: categoryKey = @"TV"; break;
        case CATEGORY_MOVIES: categoryKey = @"MOVIES"; break;
        case CATEGORY_SERIES: categoryKey = @"SERIES"; break;
        case CATEGORY_SETTINGS: categoryKey = @"SETTINGS"; break;
        default: categoryKey = @"SETTINGS"; break;
    }
    
    //NSLog(@"🔍 [CATEGORY-ACCESS] Getting groups for category: %@ (index: %ld)", categoryKey, (long)_selectedCategoryIndex);
    
            // Fallback arrays for each category
            NSArray *fallbackGroups;
            if ([categoryKey isEqualToString:@"SETTINGS"]) {
                fallbackGroups = @[@"Playlist", @"General", @"Subtitles", @"Movie Info", @"Themes"];
            } else if ([categoryKey isEqualToString:@"FAVORITES"]) {
                fallbackGroups = @[@""]; // Will be populated when favorites are added
            } else {
                fallbackGroups = @[@""];
            }
            
            // ULTRA-SAFE: Multiple layers of validation to prevent any crashes
            if (!_groupsByCategory) {
                //NSLog(@"⚠️ [SAFE-ACCESS] groupsByCategory is nil, using fallback for category: %@", categoryKey);
                
                // Initialize FAVORITES category if it's being accessed
                if ([categoryKey isEqualToString:@"FAVORITES"]) {
                    [self ensureFavoritesCategory];
                    // Try again after initialization
                    if (_groupsByCategory) {
                        // Re-validate after initialization
                        @try {
                            if ([_groupsByCategory isKindOfClass:[NSDictionary class]]) {
                                NSArray *groups = [_groupsByCategory objectForKey:categoryKey];
                                return groups ?: fallbackGroups;
                            }
                        } @catch (NSException *exception) {
                            //NSLog(@"❌ [SAFE-ACCESS] Exception even after initialization: %@", exception);
                        }
                    }
                }
                
                return fallbackGroups;
            }
            
            // ULTRA-SAFE: Check for nil first, then wrap isKindOfClass in exception handling to prevent crashes
            BOOL isValidDictionary = NO;
            @try {
                // CRITICAL: Check for nil pointer first before calling any methods
                if (_groupsByCategory == nil) {
                    //NSLog(@"⚠️ [SAFE-ACCESS] groupsByCategory is nil, initializing...");
                    [self ensureFavoritesCategory];
                    isValidDictionary = (_groupsByCategory != nil);
                } else {
                    isValidDictionary = [_groupsByCategory isKindOfClass:[NSDictionary class]];
                }
            } @catch (NSException *exception) {
                //NSLog(@"❌ [SAFE-ACCESS] Exception calling isKindOfClass on groupsByCategory: %@", exception);
                //NSLog(@"❌ [SAFE-ACCESS] Resetting corrupted groupsByCategory to prevent further crashes");
                
                // Reset the corrupted pointer to prevent future crashes
                _groupsByCategory = nil;
                
                // Initialize FAVORITES category if it's being accessed
                if ([categoryKey isEqualToString:@"FAVORITES"]) {
                    [self ensureFavoritesCategory];
                }
                
                return fallbackGroups;
            }
            
            if (!isValidDictionary) {
                NSLog(@"⚠️ [SAFE-ACCESS] groupsByCategory is not a valid dictionary, using fallback");
                
                // Reset the invalid object to prevent future crashes
                _groupsByCategory = nil;
                
                // Initialize FAVORITES category if it's being accessed
                if ([categoryKey isEqualToString:@"FAVORITES"]) {
                    [self ensureFavoritesCategory];
                }
                
                return fallbackGroups;
            }
            
            // Safe access with exception handling
            NSArray *groups = nil;
            @try {
                groups = [_groupsByCategory objectForKey:categoryKey];
            } @catch (NSException *exception) {
                //NSLog(@"❌ [SAFE-ACCESS] Exception accessing groupsByCategory: %@", exception);
                return fallbackGroups;
            }
            
            // ENHANCED: Validate all items in the groups array
            if (groups && [groups isKindOfClass:[NSArray class]]) {
                //NSLog(@"🔍 [CATEGORY-ACCESS] Found %lu groups for category %@: %@", (unsigned long)groups.count, categoryKey, groups);
                NSMutableArray *validatedGroups = [NSMutableArray array];
                
                for (NSInteger i = 0; i < groups.count; i++) {
                    id groupItem = groups[i];
                    
                    if (groupItem == nil || [groupItem isKindOfClass:[NSNull class]]) {
                        //NSLog(@"⚠️ [SAFE-ACCESS] Group item at index %ld is nil/NSNull, replacing with fallback", (long)i);
                        [validatedGroups addObject:[NSString stringWithFormat:@"Group %ld", (long)i]];
                    } else if ([groupItem isKindOfClass:[NSString class]]) {
                        NSString *groupName = (NSString *)groupItem;
                        if (groupName.length > 0) {
                            [validatedGroups addObject:groupName];
                        } else {
                            //NSLog(@"⚠️ [SAFE-ACCESS] Group item at index %ld is empty string, replacing with fallback", (long)i);
                            [validatedGroups addObject:[NSString stringWithFormat:@"Group %ld", (long)i]];
                        }
                    } else {
                        //NSLog(@"⚠️ [SAFE-ACCESS] Group item at index %ld is not a string (class: %@), replacing with fallback", (long)i, [groupItem class]);
                        [validatedGroups addObject:[NSString stringWithFormat:@"Group %ld", (long)i]];
                    }
                }
                
                return validatedGroups.count > 0 ? [validatedGroups copy] : fallbackGroups;
            }
            
            // Return fallback if groups is nil or not an array
            return fallbackGroups;
            
        } @catch (NSException *exception) {
                //NSLog(@"❌ [SAFE-ACCESS] Exception in getGroupsForSelectedCategory: %@", exception);
            return @[@"General"];
        }
    }
}

- (NSArray *)getChannelsForCurrentGroup {
   // NSLog(@"🔧 iOS getChannelsForCurrentGroup - returning real channel data");
    
    // Handle no group selection
    if (_selectedGroupIndex < 0) {
        //NSLog(@"🔧 No group selected - returning empty array");
        return @[];
    }
    
    // Get groups for selected category
    NSArray *groups = [self getGroupsForSelectedCategory];
    if (_selectedGroupIndex >= groups.count) {
        //NSLog(@"🔧 Selected group index out of bounds - returning empty array");
        return @[];
    }
    
    // Get the selected group name
    NSString *groupName = groups[_selectedGroupIndex];
    NSLog(@"ACCESS] Getting channels for group: %@ (category index: %ld, group index: %ld)", groupName, (long)_selectedCategoryIndex, (long)_selectedGroupIndex);
    
    // Return channels from channelsByGroup dictionary
    if (_channelsByGroup && groupName) {
        NSArray *channelsInGroup = [_channelsByGroup objectForKey:groupName];
       // NSLog(@"🔧 [CHANNEL-ACCESS] channelsByGroup lookup for '%@': %lu channels found", groupName, (unsigned long)(channelsInGroup ? channelsInGroup.count : 0));
        if (channelsInGroup && [channelsInGroup count] > 0) {
         //   NSLog(@"🔧 [CHANNEL-ACCESS] Found %lu real channels in group: %@", (unsigned long)[channelsInGroup count], groupName);
            
            // Debug: Check what type of objects are in the array
            if ([channelsInGroup count] > 0) {
                id firstObject = [channelsInGroup objectAtIndex:0];
                //NSLog(@"🔧 First object in channels array is type: %@", [firstObject class]);
                if ([firstObject isKindOfClass:[VLCChannel class]]) {
                    VLCChannel *channel = (VLCChannel *)firstObject;
                    //NSLog(@"🔧 First channel name: %@, group: %@", channel.name, channel.group);
                } else if ([firstObject isKindOfClass:[NSString class]]) {
                    //NSLog(@"🔧 First object is a string: %@", (NSString *)firstObject);
                }
            }
            
            return channelsInGroup;
        }
    }
    
    // If no channels found in the data structures, check if we're in settings
    if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
        //NSLog(@"🔧 Settings category - returning empty array (handled by settings panel)");
        return @[];
    }
    
    // No channels loaded yet
    //NSLog(@"🔧 No channels loaded for group: %@", groupName);
    return @[];
}

// Helper method to check if the current group contains movie channels
- (BOOL)currentGroupContainsMovieChannels {
    NSArray *channelsInCurrentGroup = [self getChannelsForCurrentGroup];
    if (!channelsInCurrentGroup || channelsInCurrentGroup.count == 0) {
        return NO;
    }

    // Check if any channel in the current group is a movie channel using URL-based detection
    for (VLCChannel *channel in channelsInCurrentGroup) {
        // CRITICAL: Use URL-based movie detection instead of just checking category
        if ([self isMovieChannel:channel]) {
            return YES;
        }
    }
    
    return NO;
}

// Helper method to detect if a channel is a movie based on URL extensions
- (BOOL)isMovieChannel:(VLCChannel *)channel {
    if (!channel || !channel.url || channel.url.length == 0) return NO;
    
    NSString *lowerURL = [channel.url lowercaseString];
    
    // Common movie file extensions (same as VLCChannelManager)
    NSArray *movieExtensions = @[@".mp4", @".mkv", @".avi", @".mov", @".m4v", @".wmv", @".flv", 
                                @".webm", @".ogv", @".3gp", @".m2ts", @".ts", @".vob", @".divx", 
                                @".xvid", @".rmvb", @".asf", @".mpg", @".mpeg", @".m2v", @".mts"];
    
    // Check if URL ends with any movie extension (case insensitive)
    for (NSString *extension in movieExtensions) {
        if ([lowerURL hasSuffix:extension]) {
            return YES;
        }
    }
    
    return NO;
}

#pragma mark - Channel Data Preparation (Shared with macOS)

- (void)prepareSimpleChannelLists {
    @synchronized(self) {
        @try {
            // Get current category and group
            NSString *currentCategory = nil;
            NSArray *categoryTitles = @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
            if (_selectedCategoryIndex >= 0 && _selectedCategoryIndex < categoryTitles.count) {
                currentCategory = [categoryTitles objectAtIndex:_selectedCategoryIndex];
            }
            
            NSString *currentGroup = nil;
            NSArray *groups = [self getGroupsForSelectedCategory];
            
            // Get the current group from the selected index
            if (groups && _selectedGroupIndex >= 0 && _selectedGroupIndex < groups.count) {
                currentGroup = [groups objectAtIndex:_selectedGroupIndex];
            }
            
            // Get channels for the current group
            NSArray *channelsInGroup = nil;
            if (currentGroup && _channelsByGroup) {
                channelsInGroup = [_channelsByGroup objectForKey:currentGroup];
            }
            
            // Create simple arrays for the UI
            NSMutableArray *names = [NSMutableArray array];
            NSMutableArray *urls = [NSMutableArray array];
            
            if (channelsInGroup && [channelsInGroup count] > 0) {
                for (VLCChannel *channel in channelsInGroup) {
                    if ([channel isKindOfClass:[VLCChannel class]]) {
                        [names addObject:channel.name ? channel.name : @"Unknown"];
                        [urls addObject:channel.url ? channel.url : @""];
                    }
                }
            }
            
            // Update the simple lists with the new data (if they exist as properties)
            if ([self respondsToSelector:@selector(setSimpleChannelNames:)]) {
                [self setValue:[names copy] forKey:@"simpleChannelNames"];
            }
            if ([self respondsToSelector:@selector(setSimpleChannelUrls:)]) {
                [self setValue:[names copy] forKey:@"simpleChannelUrls"];
            }
            
            NSLog(@"📺 prepareSimpleChannelLists - prepared %lu channels for group: %@", 
                  (unsigned long)names.count, currentGroup ?: @"(none)");
            
        } @catch (NSException *exception) {
            NSLog(@"❌ Exception in prepareSimpleChannelLists: %@", exception);
        }
    }
}

#pragma mark - Gesture Handlers

- (void)handleSingleTap:(UITapGestureRecognizer *)gesture {
    CGPoint tapPoint = [gesture locationInView:self];
    
    // Reset auto-hide timer on user interaction
    [self resetAutoHideTimer];
    
    // Calculate responsive dimensions for tap handling
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat programGuideWidth = [self programGuideWidth];
    CGFloat channelAreaWidth = self.bounds.size.width - categoryWidth - groupWidth - programGuideWidth;
    CGFloat totalUIWidth = categoryWidth + groupWidth + channelAreaWidth;
    CGFloat programGuideX = totalUIWidth;
    
    // DEBUG: Show UI boundaries to understand touch routing
    //NSLog(@"📱 [UI-BOUNDARIES-DEBUG] Tap at (%.1f, %.1f)", tapPoint.x, tapPoint.y);
    //NSLog(@"📱 [UI-BOUNDARIES-DEBUG] categoryWidth: %.1f, groupWidth: %.1f, channelAreaWidth: %.1f", categoryWidth, groupWidth, channelAreaWidth);
    //NSLog(@"📱 [UI-BOUNDARIES-DEBUG] totalUIWidth: %.1f, screen width: %.1f", totalUIWidth, self.bounds.size.width);
    //NSLog(@"📱 [UI-BOUNDARIES-DEBUG] Tap in video area: %@", (tapPoint.x > totalUIWidth) ? @"YES" : @"NO");
    //NSLog(@"📱 [UI-BOUNDARIES-DEBUG] Channel list visible: %@", _isChannelListVisible ? @"YES" : @"NO");
    //NSLog(@"📱 [UI-BOUNDARIES-DEBUG] Player controls visible: %@", _playerControlsVisible ? @"YES" : @"NO");
    
    if (!_isChannelListVisible) {
        // Menu is hidden - iOS single tap behavior: show player controls only
        // (Double tap will show menu - see handleDoubleTap)
        if (tapPoint.x > totalUIWidth) {
            // Tap in video area (right side) - show/toggle player controls
            if (_playerControlsVisible) {
                // Check if tap is on player controls
                BOOL tappedOnControls = [self handlePlayerControlTouchAt:tapPoint];
                if (!tappedOnControls) {
                    // Tap outside controls - hide them
                    [self hidePlayerControls];
                    NSLog(@"📱 [iOS-SINGLE-TAP] Hiding player controls (tap outside)");
                }
                return;
            } else {
                // Show player controls (single tap in video area)
                [self showPlayerControls];
                NSLog(@"📱 [iOS-SINGLE-TAP] Showing player controls");
        return;
            }
        } else {
            // Tap in UI area when menu hidden - check if it's on player controls first
            if (_playerControlsVisible) {
                // Check if tap is on player controls (even in UI area)
                BOOL tappedOnControls = [self handlePlayerControlTouchAt:tapPoint];
                if (tappedOnControls) {
                    NSLog(@"📱 [iOS-SINGLE-TAP] Player control button tapped in UI area");
                    return;
                }
            }
            
            // Not on controls - show player controls (not menu)
            [self showPlayerControls];
            NSLog(@"📱 [iOS-SINGLE-TAP] Showing player controls (UI area tap)");
        return;
        }
    }
    
    // Menu is visible - ensure player controls are hidden (like Mac mode)
    if (_playerControlsVisible) {
        [self hidePlayerControls];
        NSLog(@"📱 [iOS-MENU-VISIBLE] Hiding player controls (Mac mode behavior)");
    }
    
    // Handle taps in different regions
    if (tapPoint.x < categoryWidth) {
        // Tap in categories area
        [self handleCategoryTap:tapPoint];
    } else if (tapPoint.x < categoryWidth + groupWidth) {
        // Tap in groups area
        [self handleGroupTap:tapPoint];
    } else if (tapPoint.x < totalUIWidth) {
        // Tap in channel list area
        [self handleChannelTapWithGesture:gesture];
    } else if (tapPoint.x < programGuideX + programGuideWidth) {
        // Tap in program guide area
        [self handleEpgTap:tapPoint];
    } else {
        // Tap in video area (right side) - hide menu
        [self hideAllSettingsScrollViews];
        _isChannelListVisible = NO;
        [self stopAutoHideTimer]; // Stop timer when menu is hidden
        [self setNeedsDisplay];
        NSLog(@"📱 [iOS-SINGLE-TAP] Hiding menu (video area tap)");
    }
}

- (void)handleEpgTap:(CGPoint)tapPoint {
    // Reset auto-hide timer on user interaction
    [self resetAutoHideTimer];
    
    // Check if we have a channel with EPG data
    VLCChannel *channel = [self getChannelAtIndex:_hoveredChannelIndex >= 0 ? _hoveredChannelIndex : _selectedChannelIndex];
    if (!channel || !channel.programs || channel.programs.count == 0) {
        return;
    }
    
    // Calculate which program was tapped
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat programGuideWidth = [self programGuideWidth];
    CGFloat channelAreaWidth = self.bounds.size.width - categoryWidth - groupWidth - programGuideWidth;
    CGFloat programGuideX = categoryWidth + groupWidth + channelAreaWidth;
    
    // Calculate program guide area dimensions
    CGFloat programHeight = 60;
    CGFloat programSpacing = 5;
    CGFloat contentStartY = self.bounds.size.height - 90; // Leave space for channel name
    
    // Calculate tapped program relative to scroll position
    CGFloat relativeY = tapPoint.y - 20; // Account for top margin
    CGFloat scrollAdjustedY = relativeY + _programGuideScrollPosition;
    NSInteger tappedProgramIndex = (NSInteger)(scrollAdjustedY / (programHeight + programSpacing));
    
    // Sort programs by start time to match display order
    NSArray *sortedPrograms = [channel.programs sortedArrayUsingComparator:^NSComparisonResult(VLCProgram *a, VLCProgram *b) {
        return [a.startTime compare:b.startTime];
    }];
    
    // Validate tapped program index
    if (tappedProgramIndex >= 0 && tappedProgramIndex < sortedPrograms.count) {
        // Enable EPG navigation mode and select the tapped program
        self.epgNavigationMode = YES;
        self.selectedEpgProgramIndex = tappedProgramIndex;
        
        VLCProgram *tappedProgram = sortedPrograms[tappedProgramIndex];
        NSLog(@"📺 [iOS-EPG-TAP] Selected program %ld: %@ at %@", 
              (long)tappedProgramIndex, tappedProgram.title, tappedProgram.startTime);
        
        [self setNeedsDisplay];
        
        // Start timer to auto-clear selection after 5 seconds (shorter than channel hover)
        [self startEpgSelectionClearTimer];
    }
}

- (void)startEpgSelectionClearTimer {
    // Clear any existing timer
    [self.hoverClearTimer invalidate];
    self.hoverClearTimer = nil;
    
    // Start new timer to clear EPG selection after 5 seconds
    self.hoverClearTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                            target:self
                                                          selector:@selector(clearEpgSelection)
                                                          userInfo:nil
                                                           repeats:NO];
}

- (void)clearEpgSelection {
    if (self.epgNavigationMode) {
        self.epgNavigationMode = NO;
        self.selectedEpgProgramIndex = -1;
        [self setNeedsDisplay];
        NSLog(@"📺 [iOS-EPG] Auto-cleared EPG selection after timeout");
    }
    
    self.hoverClearTimer = nil;
}

- (void)handleCategoryTap:(CGPoint)point {
    // Reset auto-hide timer on user interaction
    [self resetAutoHideTimer];
    
    NSInteger categoryIndex = (NSInteger)(point.y / [self rowHeight]);
    if (categoryIndex >= 0 && categoryIndex < 6) { // 6 categories
        NSInteger previousCategoryIndex = _selectedCategoryIndex;
        _selectedCategoryIndex = categoryIndex;
        _selectedGroupIndex = -1; // Reset group selection
        
        // Clear hover state when switching categories
        _hoveredChannelIndex = -1;
        [self.hoverClearTimer invalidate];
        self.hoverClearTimer = nil;
        
        // Handle settings panel visibility and hide all settings scroll views when switching
        if (previousCategoryIndex == CATEGORY_SETTINGS && categoryIndex != CATEGORY_SETTINGS) {
            // Switching away from Settings - hide the settings panel and all scroll views
            [self hideSettingsPanel];
            [self hideAllSettingsScrollViews];
        } else if (categoryIndex == CATEGORY_SETTINGS && previousCategoryIndex != CATEGORY_SETTINGS) {
            // Switching to Settings - show the settings panel
            [self showSettingsPanel];
        }
        
        // Always hide all settings scroll views when switching categories (not just from settings)
        [self hideAllSettingsScrollViews];
        
        [self setNeedsDisplay];
    }
}

- (void)handleGroupTap:(CGPoint)point {
    // Reset auto-hide timer on user interaction
    [self resetAutoHideTimer];
    
    NSInteger groupIndex = (NSInteger)((point.y + _groupScrollPosition) / [self rowHeight]);
    NSArray *groups = [self getGroupsForSelectedCategory];
    if (groupIndex >= 0 && groupIndex < groups.count) {
        NSString *selectedGroup = groups[groupIndex];
        
        _selectedGroupIndex = groupIndex;
        _selectedChannelIndex = -1; // Reset channel selection when switching groups
        _channelScrollPosition = 0; // Reset channel scroll when switching groups
        
        // Clear hover state when switching groups
        _hoveredChannelIndex = -1;
        [self.hoverClearTimer invalidate];
        self.hoverClearTimer = nil;
        
        // Always hide all settings scroll views when switching groups (fixes visibility issue)
        [self hideAllSettingsScrollViews];
        
        // DEBUG: Comprehensive group detection analysis
        NSLog(@"🎯 ========== GROUP CLICK DEBUG ==========");
        NSLog(@"🎯 Selected group: '%@' (index: %ld)", selectedGroup, (long)groupIndex);
        NSLog(@"🎯 Current category index: %ld (%@)", (long)_selectedCategoryIndex, [self getCategoryNameForIndex:_selectedCategoryIndex]);
        
        // Get channels for this group
        NSArray *channelsInGroup = [self getChannelsForCurrentGroup];
        NSLog(@"🎯 Channels in group: %lu", (unsigned long)channelsInGroup.count);
        
        // Test currentGroupContainsMovieChannels method
        BOOL containsMovies = [self currentGroupContainsMovieChannels];
        NSLog(@"🎯 currentGroupContainsMovieChannels: %@", containsMovies ? @"YES" : @"NO");
        
        // Analyze each channel in the group
        NSUInteger movieCount = 0;
        NSUInteger tvCount = 0;
        NSUInteger seriesCount = 0;
        NSUInteger otherCount = 0;
        
        for (VLCChannel *channel in channelsInGroup) {
            if ([channel.category isEqualToString:@"MOVIES"]) {
                movieCount++;
            } else if ([channel.category isEqualToString:@"TV"]) {
                tvCount++;
            } else if ([channel.category isEqualToString:@"SERIES"]) {
                seriesCount++;
            } else {
                otherCount++;
            }
            
            // Check if URL indicates movie
            BOOL isMovieURL = [self isMovieChannel:channel];
            NSLog(@"🎯 Channel '%@': category='%@', URL movie extension=%@, URL='%@'", 
                  channel.name, channel.category, isMovieURL ? @"YES" : @"NO", 
                  [channel.url substringToIndex:MIN(80, channel.url.length)]);
        }
        
        NSLog(@"🎯 Category distribution - Movies: %lu, TV: %lu, Series: %lu, Other: %lu", 
              (unsigned long)movieCount, (unsigned long)tvCount, (unsigned long)seriesCount, (unsigned long)otherCount);
        
        // Check if we're in favorites and what view mode will be used
        if (_selectedCategoryIndex == CATEGORY_FAVORITES) {
            BOOL isFavoritesWithMovies = (_selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]);
            NSLog(@"🎯 FAVORITES: isFavoritesWithMovies = %@", isFavoritesWithMovies ? @"YES" : @"NO");
            NSLog(@"🎯 FAVORITES: Will use %@ view", isFavoritesWithMovies ? @"STACKED MOVIE" : @"LIST");
        }
        
        NSLog(@"🎯 ========================================");
        
        [self setNeedsDisplay];
    }
}

- (void)handleChannelTapWithGesture:(UITapGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self];
    
    // Check if we're in settings category and handle settings panel taps
    if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
        [self handleSettingsPanelTap:point];
        return;
    }
    
    NSInteger channelIndex = [self channelIndexAtPoint:point];
    if (channelIndex >= 0) {
        
        // Check if this is a force touch (3D Touch on supported devices)
        BOOL isForceTouch = NO;
        if (@available(iOS 9.0, *)) {
            if (self.traitCollection.forceTouchCapability == UIForceTouchCapabilityAvailable) {
                // Check for force - threshold for "hard press"
                CGFloat forceThreshold = 2.0; // Adjust as needed
                if (gesture.view.gestureRecognizers.count > 0) {
                    // Try to get force from the gesture (this requires setup in the view controller)
                    // For now, we'll use a simpler approach
                }
            }
        }
        
        if (isForceTouch) {
            // Force touch = select and play channel immediately
            _selectedChannelIndex = channelIndex;
            _hoveredChannelIndex = -1; // Clear hover when selecting
            
            // Play the selected channel
            [self playChannelAtIndex:channelIndex];
        
        // Show player controls when playback starts
        [self showPlayerControls];
            
            // Hide menu and all settings after selection
            [self hideAllSettingsScrollViews];
            _isChannelListVisible = NO;
            [self setNeedsDisplay];
            
            NSLog(@"💪 Force touch - Playing channel: %ld", (long)channelIndex);
        } else {
            // Normal light tap = hover effect (like macOS hover)
            // This just highlights the channel without playing it
            _hoveredChannelIndex = channelIndex;
            
            // Don't change selected channel or play anything
            // This gives the user a preview of which channel they're about to select
            [self setNeedsDisplay];
            
            // Start/restart timer to clear hover after 10 seconds
            [self startHoverClearTimer];
            
            NSLog(@"🎯 ✅ Light tap - Set hoveredChannelIndex to: %ld (should show program guide)", (long)channelIndex);
        }
    }
}

// Keep the old method for backward compatibility (used in settings)
- (void)handleChannelTap:(CGPoint)point {
    // Legacy method - just create a fake gesture for the new method
    // This is used by settings panel handling
    if (_selectedCategoryIndex == CATEGORY_SETTINGS) {
        [self handleSettingsPanelTap:point];
        return;
    }
    
    // For non-settings, redirect to the new gesture-aware method
    NSInteger channelIndex = [self channelIndexAtPoint:point];
    if (channelIndex >= 0) {
        // Just do hover behavior for legacy calls
        _hoveredChannelIndex = channelIndex;
        [self setNeedsDisplay];
        NSLog(@"🎯 Legacy hover over channel: %ld", (long)channelIndex);
    }
}

- (void)handleSettingsPanelTap:(CGPoint)point {
    // Reset auto-hide timer on user interaction
    [self resetAutoHideTimer];
    
    // Handle taps in the settings panel area
    if (_selectedGroupIndex >= 0) {
        NSArray *settingsGroups = [self getGroupsForSelectedCategory];
        if (_selectedGroupIndex < settingsGroups.count) {
            NSString *selectedGroup = settingsGroups[_selectedGroupIndex];
            
            if ([selectedGroup isEqualToString:@"Movie Info"]) {
                // Check if tap is on clear cache button
                if (CGRectContainsPoint(_clearMovieInfoCacheButtonRect, point)) {
                    [self clearMovieInfoCache];
                }
            }
            // Add more settings button handling here for other groups as needed
        }
    }
}

- (void)clearMovieInfoCache {
    // Reset auto-hide timer on user interaction
    [self resetAutoHideTimer];
    
    // Get cache directory paths
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *cacheDir = [documentsPath stringByAppendingPathComponent:@"VLCCache"];
    NSString *movieInfoCacheDir = [cacheDir stringByAppendingPathComponent:@"MovieInfo"];
    NSString *posterCacheDir = [cacheDir stringByAppendingPathComponent:@"Posters"];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    
    // Clear movie info cache
    if ([fileManager fileExistsAtPath:movieInfoCacheDir]) {
        [fileManager removeItemAtPath:movieInfoCacheDir error:&error];
        if (error) {
            NSLog(@"❌ Error clearing movie info cache: %@", error.localizedDescription);
        } else {
            NSLog(@"✅ Movie info cache cleared successfully");
        }
    }
    
    // Clear poster cache
    if ([fileManager fileExistsAtPath:posterCacheDir]) {
        [fileManager removeItemAtPath:posterCacheDir error:&error];
        if (error) {
            NSLog(@"❌ Error clearing poster cache: %@", error.localizedDescription);
        } else {
            NSLog(@"✅ Poster cache cleared successfully");
        }
    }
    
    // Recreate directories for future use
    [fileManager createDirectoryAtPath:movieInfoCacheDir withIntermediateDirectories:YES attributes:nil error:&error];
    [fileManager createDirectoryAtPath:posterCacheDir withIntermediateDirectories:YES attributes:nil error:&error];
    
    // Refresh the settings panel to show updated cache counts
    [self setNeedsDisplay];
    
    // Show success message (optional - could add a temporary overlay)
    NSLog(@"🧹 Movie info and poster caches have been cleared");
}

- (NSString *)getCategoryNameForIndex:(NSInteger)index {
    NSArray *categoryNames = @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
    if (index >= 0 && index < categoryNames.count) {
        return categoryNames[index];
    }
    return @"UNKNOWN";
}

#pragma mark - Hover State Management

- (void)startHoverClearTimer {
    // DISABLED: Program guide should stay open as long as menu is open
    // The program guide relies on hoveredChannelIndex and should only close when menu closes
    // Timer was causing program guide to disappear after 10 seconds which is bad UX
    
    // Cancel any existing timer but don't start a new one
    [self.hoverClearTimer invalidate];
    self.hoverClearTimer = nil;
    
    NSLog(@"🎯 Hover clear timer disabled - program guide will stay open with menu");
    
    // NOTE: Hover state will now only be cleared when:
    // 1. Menu is closed (hoveredChannelIndex = -1)
    // 2. User explicitly selects a different channel
    // 3. User navigates away from the channel
}

- (void)clearHoverState {
    if (_hoveredChannelIndex >= 0) {
        _hoveredChannelIndex = -1;
        [self setNeedsDisplay];
        NSLog(@"⏰ Hover state cleared automatically");
    }
    self.hoverClearTimer = nil;
}

#if TARGET_OS_IOS
- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    CGPoint tapPoint = [gesture locationInView:self];
    
    // Reset auto-hide timer on user interaction
    [self resetAutoHideTimer];
    
    // Calculate responsive dimensions for double tap handling
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat programGuideWidth = [self programGuideWidth];
    CGFloat channelAreaWidth = self.bounds.size.width - categoryWidth - groupWidth - programGuideWidth;
    CGFloat totalUIWidth = categoryWidth + groupWidth + channelAreaWidth;
    CGFloat programGuideX = totalUIWidth;
    
    if (!_isChannelListVisible) {
        // Menu is hidden - double tap shows menu (like Mac mode)
        _isChannelListVisible = YES;
        
        // EXPLICITLY hide player controls when menu becomes visible (Mac mode consistency)
        if (_playerControlsVisible) {
            _playerControlsVisible = NO;
            [self stopAutoHideTimer]; // Stop player controls timer
            NSLog(@"📱 [MAC-CONSISTENCY] Hiding player controls when menu shows");
        }
        
        [self resetAutoHideTimer]; // Start timer when menu becomes visible
        [self setNeedsDisplay];
        NSLog(@"📱 [iOS-DOUBLE-TAP] Showing menu (Mac mode consistency)");
        return;
    }
    
    // Check if double tap is in the program guide area FIRST (prioritize EPG over channel)
    if (tapPoint.x >= programGuideX && tapPoint.x < programGuideX + programGuideWidth) {
        // Double tap in program guide area = select and play program
        if (self.epgNavigationMode && self.selectedEpgProgramIndex >= 0) {
            // Use the shared selection handler (same as tvOS) - handles catchup automatically
            [self handleTVOSEpgProgramSelection];
            NSLog(@"🎬 [iOS-EPG] Double tap - Playing selected program (with catchup if available)");
            return;
        } else {
            // No program selected - detect which program was double-tapped and select it
            VLCChannel *channel = [self getChannelAtIndex:_hoveredChannelIndex >= 0 ? _hoveredChannelIndex : _selectedChannelIndex];
            if (channel && channel.programs && channel.programs.count > 0) {
                // Calculate which program was tapped (using exact same logic as program guide drawing)
                CGFloat programHeight = 60;
                CGFloat programSpacing = 5;
                CGFloat contentStartY = self.bounds.size.height - 90; // Same as drawing
                CGFloat relativeY = tapPoint.y - 20; // Account for top margin in drawing
                CGFloat scrollAdjustedY = relativeY + _programGuideScrollPosition;
                NSInteger tappedProgramIndex = (NSInteger)(scrollAdjustedY / (programHeight + programSpacing));
                
                NSLog(@"🎬 [iOS-EPG-DEBUG] Double tap at Y:%.1f, relativeY:%.1f, scrollAdjusted:%.1f, index:%ld", 
                      tapPoint.y, relativeY, scrollAdjustedY, (long)tappedProgramIndex);
                
                // Sort programs by start time to match display order
                NSArray *sortedPrograms = [channel.programs sortedArrayUsingComparator:^NSComparisonResult(VLCProgram *a, VLCProgram *b) {
                    return [a.startTime compare:b.startTime];
                }];
                
                // Validate tapped program index
                if (tappedProgramIndex >= 0 && tappedProgramIndex < sortedPrograms.count) {
                    VLCProgram *tappedProgram = sortedPrograms[tappedProgramIndex];
                    NSLog(@"🎬 [iOS-EPG-DEBUG] Found program: %@ at %@", tappedProgram.title, tappedProgram.startTime);
                    
                    // Set up EPG navigation mode and select the program
                    self.epgNavigationMode = YES;
                    self.selectedEpgProgramIndex = tappedProgramIndex;
                    
                    // Update the selected channel index to match the hovered channel
                    if (_hoveredChannelIndex >= 0) {
                        _selectedChannelIndex = _hoveredChannelIndex;
                    }
                    
                    // Immediately play it (with catchup if available)
                    [self handleTVOSEpgProgramSelection];
                    NSLog(@"🎬 [iOS-EPG] Double tap - Direct play program '%@' (with catchup if available)", tappedProgram.title);
                    return;
                } else {
                    NSLog(@"🎬 [iOS-EPG-DEBUG] Invalid program index: %ld (total: %ld)", (long)tappedProgramIndex, (long)sortedPrograms.count);
                }
            } else {
                NSLog(@"🎬 [iOS-EPG-DEBUG] No channel or programs available");
            }
        }
    } else if (tapPoint.x >= categoryWidth + groupWidth && tapPoint.x < totalUIWidth) {
        // Double tap in channel area = select and play channel
        if (_selectedCategoryIndex != CATEGORY_SETTINGS) {
            NSInteger channelIndex = [self channelIndexAtPoint:tapPoint];
            if (channelIndex >= 0) {
                _selectedChannelIndex = channelIndex;
                _hoveredChannelIndex = -1; // Clear hover when selecting
                
                // Play the selected channel
                [self playChannelAtIndex:channelIndex];
                
                // Hide menu after selection
                _isChannelListVisible = NO;
                [self setNeedsDisplay];
                
                NSLog(@"🎬 Double tap - Playing channel: %ld", (long)channelIndex);
                return;
            }
        }
    }
    
    // If not handled as channel or EPG selection, toggle fullscreen
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ToggleFullscreen" object:nil];
}
#endif

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        CGPoint location = [gesture locationInView:self];
        NSLog(@"📱 [LONG-PRESS] Long press detected at point: %@", NSStringFromCGPoint(location));
        
        // Check if we have a channel list visible
        if (!_isChannelListVisible) {
            NSLog(@"📱 [LONG-PRESS] No menu visible, ignoring long press");
            return;
        }
        
        // Reset auto-hide timer during long press interaction
        [self resetAutoHideTimer];
        
        // Determine what was long pressed based on location
        VLCChannel *tappedChannel = [self getChannelAtTouchPoint:location];
        NSString *tappedGroup = [self getGroupAtTouchPoint:location];
        
        if (tappedChannel) {
            NSLog(@"📱 [LONG-PRESS] Long press on channel: %@", tappedChannel.name);
            [self showContextMenuForChannel:tappedChannel atPoint:location];
        } else if (tappedGroup) {
            NSLog(@"📱 [LONG-PRESS] Long press on group: %@", tappedGroup);
            [self showContextMenuForGroup:tappedGroup atPoint:location];
        } else {
            NSLog(@"📱 [LONG-PRESS] Long press on empty area");
        }
    }
}

#pragma mark - Track Refresh Helpers

- (void)refreshPlayerControlsForTrackChanges {
    // Force a redraw of player controls when tracks become available
    // This fixes the issue where tracks don't populate until hide/show
    if (_playerControlsVisible) {
        NSLog(@"📱 [TRACK-REFRESH-DEBUG] Refreshing player controls for track changes");
        [self setNeedsDisplay];
    }
}

- (void)scheduleTrackRefresh {
    // Schedule a delayed refresh to allow tracks to load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshPlayerControlsForTrackChanges];
    });
}

#pragma mark - Touch Calculation Helpers

- (NSInteger)channelIndexAtPoint:(CGPoint)point {
    NSArray *channels = [self getChannelsForCurrentGroup];
    if (!channels || channels.count == 0) {
        return -1;
    }
    
    // Calculate channel index based on current view mode
    NSInteger channelIndex = -1;
    BOOL isMovieCategory = (_selectedCategoryIndex == CATEGORY_MOVIES);
    BOOL isSeriesCategory = (_selectedCategoryIndex == CATEGORY_SERIES);
    BOOL isFavoritesWithMovies = (_selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]);
    
    if ((isMovieCategory || isSeriesCategory || isFavoritesWithMovies) && _isStackedViewActive) {
        // Stacked view touch calculation - must match drawStackedView positioning
        CGFloat itemHeight = 120;
        CGFloat padding = 10;
        CGFloat totalItemHeight = itemHeight + padding;
        
        // Reverse the drawing calculation: itemY = padding + i * (itemHeight + padding) - scrollPosition
        // So: i = (point.y + scrollPosition - padding) / (itemHeight + padding)
        channelIndex = (NSInteger)((point.y + _channelScrollPosition - padding) / totalItemHeight);
        
        NSLog(@"🎯 [STACKED-TOUCH] Touch at y=%.1f, scroll=%.1f, calculated index=%ld (itemHeight=%.1f)", 
              point.y, _channelScrollPosition, (long)channelIndex, totalItemHeight);
    } else {
        // Regular list view touch calculation
        channelIndex = (NSInteger)((point.y + _channelScrollPosition) / [self rowHeight]);
        
        NSLog(@"🎯 [LIST-TOUCH] Touch at y=%.1f, scroll=%.1f, calculated index=%ld (rowHeight=%.1f)", 
              point.y, _channelScrollPosition, (long)channelIndex, [self rowHeight]);
    }
    
    if (channelIndex >= 0 && channelIndex < channels.count) {
        return channelIndex;
    }
    
    return -1;
}

#pragma mark - Safe Data Access Helpers

- (NSArray *)safeGroupsForCategory:(NSString *)category {
    // THREAD-SAFE: Synchronize access to shared data structures
    @synchronized(self) {
    // Return empty array if any issue
    NSMutableArray *emptyGroups = [NSMutableArray array];
    
    @try {
        if (category == nil) {
            NSLog(@"📱 [SAFE-ACCESS] Category is nil");
            return emptyGroups;
        }
        
        // Enhanced nil checking - check both nil and NSNull
        if (_groupsByCategory == nil || _groupsByCategory == (id)[NSNull null]) {
            NSLog(@"📱 [SAFE-ACCESS] groupsByCategory is nil or NSNull, initializing new dictionary");
            _groupsByCategory = [[NSMutableDictionary alloc] init];
            return emptyGroups;
        }
        
        // Check if it's a valid object before calling respondsToSelector
        if (![_groupsByCategory isKindOfClass:[NSDictionary class]] && 
            ![_groupsByCategory isKindOfClass:[NSMutableDictionary class]]) {
            NSLog(@"📱 [SAFE-ACCESS] groupsByCategory is not a dictionary (class: %@), reinitializing", 
                  NSStringFromClass([_groupsByCategory class]));
            _groupsByCategory = [[NSMutableDictionary alloc] init];
            return emptyGroups;
        }
        
        // Now safe to call objectForKey since we verified it's a dictionary
        id groups = [_groupsByCategory objectForKey:category];
        
        // Check if we got a valid array
        if (groups == nil) {
            NSLog(@"📱 [SAFE-ACCESS] No groups found for category: %@", category);
            return emptyGroups;
        }
        
        if (![groups isKindOfClass:[NSArray class]] && ![groups isKindOfClass:[NSMutableArray class]]) {
            NSLog(@"📱 [SAFE-ACCESS] Groups for category %@ is not an array (class: %@)", 
                  category, NSStringFromClass([groups class]));
            return emptyGroups;
        }
        
        return groups;
        
    } @catch (NSException *exception) {
        NSLog(@"📱 [SAFE-ACCESS] Exception in safeGroupsForCategory: %@ - reinitializing data structures", exception);
        _groupsByCategory = [[NSMutableDictionary alloc] init];
        return emptyGroups;
    }
    
    } // End @synchronized(self)
}

- (void)ensureFavoritesCategory {
    @synchronized(self) {
        // Make sure FAVORITES category exists
        if (!_groupsByCategory) {
            _groupsByCategory = [NSMutableDictionary dictionary];
        }
        
        NSMutableArray *favoritesGroups = [_groupsByCategory objectForKey:@"FAVORITES"];
        if (!favoritesGroups || ![favoritesGroups isKindOfClass:[NSMutableArray class]]) {
            favoritesGroups = [NSMutableArray array];
            [_groupsByCategory setObject:favoritesGroups forKey:@"FAVORITES"];
        }
        
        NSLog(@"📱 [FAVORITES] Ensured FAVORITES category exists with %lu groups", (unsigned long)[favoritesGroups count]);
    }
}

- (void)saveSettingsState {
    // Store all settings in a single plist file in Application Support instead of UserDefaults
    NSString *settingsPath = [self settingsFilePath];
    NSMutableDictionary *settingsDict = [NSMutableDictionary dictionary];
    
    // Store playlist and EPG URLs (adapt property names for iOS)
    if (_m3uFilePath) [settingsDict setObject:_m3uFilePath forKey:@"PlaylistURL"];
    if (_epgUrl) [settingsDict setObject:_epgUrl forKey:@"EPGURL"];
    
    // Store EPG time offset
    [settingsDict setObject:@(_epgTimeOffsetHours) forKey:@"EPGTimeOffsetHours"];
    
    // Store last download timestamps
    NSDate *now = [NSDate date];
    
    // If we're downloading or updating M3U, save timestamp
    if (_isDownloadingChannels && !_isDownloadingEPG) {
        [settingsDict setObject:now forKey:@"LastM3UDownloadDate"];
    } else {
        // Preserve existing timestamp
        NSDictionary *existingSettings = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
        NSDate *existingM3UDate = [existingSettings objectForKey:@"LastM3UDownloadDate"];
        if (existingM3UDate) [settingsDict setObject:existingM3UDate forKey:@"LastM3UDownloadDate"];
    }
    
    // If we're downloading or updating EPG, save timestamp
    if (_isDownloadingEPG) {
        [settingsDict setObject:now forKey:@"LastEPGDownloadDate"];
    } else {
        // Preserve existing timestamp
        NSDictionary *existingSettings = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
        NSDate *existingEPGDate = [existingSettings objectForKey:@"LastEPGDownloadDate"];
        if (existingEPGDate) [settingsDict setObject:existingEPGDate forKey:@"LastEPGDownloadDate"];
    }
    
    // Save favorites data
    NSMutableDictionary *favoritesData = [NSMutableDictionary dictionary];
    NSArray *favoriteGroups = [self safeGroupsForCategory:@"FAVORITES"];
    if (favoriteGroups && favoriteGroups.count > 0) {
        [favoritesData setObject:favoriteGroups forKey:@"groups"];
        
        NSMutableArray *favoriteChannels = [NSMutableArray array];
        for (NSString *group in favoriteGroups) {
            NSArray *groupChannels = [_channelsByGroup objectForKey:group];
            if (groupChannels) {
                for (VLCChannel *channel in groupChannels) {
                    NSMutableDictionary *channelDict = [NSMutableDictionary dictionary];
                    [channelDict setObject:(channel.name ? channel.name : @"") forKey:@"name"];
                    [channelDict setObject:(channel.url ? channel.url : @"") forKey:@"url"];
                    [channelDict setObject:(channel.group ? channel.group : @"") forKey:@"group"];
                    if (channel.logo) [channelDict setObject:channel.logo forKey:@"logo"];
                    if (channel.channelId) [channelDict setObject:channel.channelId forKey:@"channelId"];
                    // CRITICAL: Save original category (MOVIES, SERIES, TV) to preserve display format
                    [channelDict setObject:(channel.category ? channel.category : @"TV") forKey:@"category"];
                    
                    // CRITICAL: Save timeshift/catchup properties to preserve timeshift icons and functionality
                    [channelDict setObject:@(channel.supportsCatchup) forKey:@"supportsCatchup"];
                    [channelDict setObject:@(channel.catchupDays) forKey:@"catchupDays"];
                    if (channel.catchupSource) [channelDict setObject:channel.catchupSource forKey:@"catchupSource"];
                    if (channel.catchupTemplate) [channelDict setObject:channel.catchupTemplate forKey:@"catchupTemplate"];
                    
                    [favoriteChannels addObject:channelDict];
                }
            }
        }
        if (favoriteChannels.count > 0) {
            [favoritesData setObject:favoriteChannels forKey:@"channels"];
        }
        
        // Store the favorites data
        [settingsDict setObject:favoritesData forKey:@"FavoritesData"];
        // Count timeshift channels being saved
        NSInteger timeshiftChannelsSaved = 0;
        for (NSDictionary *channelDict in favoriteChannels) {
            if ([[channelDict objectForKey:@"supportsCatchup"] boolValue] || 
                [[channelDict objectForKey:@"catchupDays"] integerValue] > 0) {
                timeshiftChannelsSaved++;
            }
        }
        
        NSLog(@"📱 [SETTINGS] Saved %lu favorite groups with %lu channels (%ld with timeshift support)", 
              (unsigned long)favoriteGroups.count, 
              (unsigned long)favoriteChannels.count,
              (long)timeshiftChannelsSaved);
    }
    
    // Write to file
    BOOL success = [settingsDict writeToFile:settingsPath atomically:YES];
    if (success) {
        NSLog(@"📱 [SETTINGS] Settings saved to Application Support: %@", settingsPath);
    } else {
        NSLog(@"📱 [SETTINGS] Failed to save settings to: %@", settingsPath);
    }
}

- (NSString *)settingsFilePath {
    NSString *appSupportDir = [self applicationSupportDirectory];
    return [appSupportDir stringByAppendingPathComponent:@"settings.plist"];
}

- (NSString *)applicationSupportDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *basePath = [paths firstObject];
    NSString *appName = @"BasicIPTV";
    NSString *appSupportDir = [basePath stringByAppendingPathComponent:appName];
    
    // Create directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:appSupportDir]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:appSupportDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"📱 [SETTINGS] Error creating application support directory: %@", error);
        }
    }
    
    return appSupportDir;
}



#pragma mark - Touch Point Detection Helpers

- (VLCChannel *)getChannelAtTouchPoint:(CGPoint)point {
    // Calculate responsive dimensions
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat programGuideWidth = [self programGuideWidth];
    CGFloat channelAreaWidth = self.bounds.size.width - categoryWidth - groupWidth - programGuideWidth;
    
    // Check if point is in channel area
    if (point.x >= categoryWidth + groupWidth && point.x < categoryWidth + groupWidth + channelAreaWidth) {
        NSInteger channelIndex = [self channelIndexAtPoint:point];
        if (channelIndex >= 0) {
        NSArray *channels = [self getChannelsForCurrentGroup];
            if (channelIndex < channels.count) {
            return channels[channelIndex];
            }
        }
    }
    
    return nil;
}

- (NSString *)getGroupAtTouchPoint:(CGPoint)point {
    // Calculate responsive dimensions
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    
    // Check if point is in group area
    if (point.x >= categoryWidth && point.x < categoryWidth + groupWidth) {
        NSArray *groups = [self getGroupsForSelectedCategory];
        NSInteger groupIndex = (NSInteger)((point.y + _groupScrollPosition) / [self rowHeight]);
        
        if (groupIndex >= 0 && groupIndex < groups.count) {
            return groups[groupIndex];
        }
    }
    
    return nil;
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)gesture {
    // ANTI-FLICKER: Strict checks to prevent pan from interfering with tap
    
    // CHANNEL SWITCHING: When menu is hidden, handle vertical swipes for channel navigation
    if (!_isChannelListVisible) {
        [self handleChannelSwitchingGesture:gesture];
        return;
    }
    
    // Reset auto-hide timer on user interaction
    [self resetAutoHideTimer];
    
    CGPoint translation = [gesture translationInView:self];
    CGPoint location = [gesture locationInView:self];
    CGPoint velocity = [gesture velocityInView:self];
    
    // 2. Require significant movement before considering it a pan
    CGFloat movementThreshold = 15.0; // Increased threshold - more restrictive
    CGFloat totalMovement = sqrt(translation.x * translation.x + translation.y * translation.y);
    
    // 3. Don't process until we have clear intent to scroll
    if (gesture.state == UIGestureRecognizerStateBegan) {
        return; // Never process "began" state
    }
    
    if (totalMovement < movementThreshold && gesture.state != UIGestureRecognizerStateEnded) {
        return; // Movement too small - definitely a tap, not scroll
    }
    
    // 4. Additional check - ensure we're in a scrollable area
    if (location.x < [self categoryWidth]) {
        return; // Don't scroll in category area
    }
    
    // iPhone-style scrolling with proper state tracking
    static BOOL _isActivelyScrolling = NO;
    static NSDate *_lastPanTime = nil;
    
    if (gesture.state == UIGestureRecognizerStateChanged && totalMovement >= movementThreshold) {
        _isActivelyScrolling = YES;
        _lastPanTime = [NSDate date];
        // Stop any ongoing momentum animations for true 1:1 finger tracking
        [self stopAllMomentumAnimations];
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        _isActivelyScrolling = NO;
    }
    
    // Direct finger tracking - 1:1 movement like iPhone
    CGFloat deltaY = translation.y;
    
    // Calculate responsive dimensions for gesture handling
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    
    // Determine which area is being scrolled
    if (location.x >= categoryWidth && location.x < categoryWidth + groupWidth) {
        // Scrolling in groups area - iPhone-style with bounce
        NSArray *groups = [self getGroupsForSelectedCategory];
        CGFloat contentHeight = groups.count * [self rowHeight];
        CGFloat visibleHeight = self.bounds.size.height;
        CGFloat maxScroll = MAX(0, contentHeight - visibleHeight);
        
        // Calculate new position
        CGFloat newPosition = _groupScrollPosition - deltaY;
        
        // iPhone-style bounce at edges
        if (newPosition < 0) {
            // Bounce at top - slow down as we go beyond bounds
            CGFloat overscroll = -newPosition;
            _groupScrollPosition = -(overscroll * 0.3); // Rubber band effect
        } else if (newPosition > maxScroll) {
            // Bounce at bottom - slow down as we go beyond bounds
            CGFloat overscroll = newPosition - maxScroll;
            _groupScrollPosition = maxScroll + (overscroll * 0.3); // Rubber band effect
        } else {
            // Normal scrolling within bounds
            _groupScrollPosition = newPosition;
        }
        
        [gesture setTranslation:CGPointZero inView:self];
        [self setNeedsDisplay];
        
        // Add momentum scrolling on gesture end with bounce-back
        if (gesture.state == UIGestureRecognizerStateEnded) {
            [self addMomentumScrollingForGroups:velocity.y maxScroll:maxScroll];
        }
        
    } else if (location.x > categoryWidth + groupWidth) {
        // Calculate program guide area
        CGFloat programGuideWidth = [self programGuideWidth];
        CGFloat channelListWidth = self.bounds.size.width - categoryWidth - groupWidth - programGuideWidth;
        CGFloat programGuideX = categoryWidth + groupWidth + channelListWidth;
        
        if (location.x >= programGuideX && (_hoveredChannelIndex >= 0 || _selectedChannelIndex >= 0)) {
            // Scrolling in program guide area - iPhone-style with bounce
            VLCChannel *channel = [self getChannelAtIndex:_hoveredChannelIndex >= 0 ? _hoveredChannelIndex : _selectedChannelIndex];
            if (channel && channel.programs && channel.programs.count > 0) {
                CGFloat programHeight = 60;
                CGFloat programSpacing = 5;
                CGFloat contentHeight = channel.programs.count * (programHeight + programSpacing);
                // Use same calculation as in program guide drawing for consistency
                CGFloat contentStartY = self.bounds.size.height - 90; // Leave space for channel name
                CGFloat visibleHeight = contentStartY - 20; // Bottom margin - matches drawing logic
                CGFloat maxScroll = MAX(0, contentHeight - visibleHeight);
                
                // Calculate new position (now that programs flow top-to-bottom, use normal scrolling)
                CGFloat newPosition = _programGuideScrollPosition - deltaY;
                
                // iPhone-style bounce at edges
                if (newPosition < 0) {
                    CGFloat overscroll = -newPosition;
                    _programGuideScrollPosition = -(overscroll * 0.3); // Rubber band effect
                } else if (newPosition > maxScroll) {
                    CGFloat overscroll = newPosition - maxScroll;
                    _programGuideScrollPosition = maxScroll + (overscroll * 0.3); // Rubber band effect
                } else {
                    _programGuideScrollPosition = newPosition;
                }
                
                [gesture setTranslation:CGPointZero inView:self];
                [self setNeedsDisplay];
                
                // Add momentum scrolling on gesture end (invert velocity to match new direction)
                if (gesture.state == UIGestureRecognizerStateEnded) {
                    [self addMomentumScrollingForProgramGuide:-velocity.y maxScroll:maxScroll];
                }
            }
        } else {
        // Scrolling in channel list area - iPhone-style with bounce
        NSArray *channels = [self getChannelsForCurrentGroup];
        
        // Calculate content height based on current view mode
        CGFloat contentHeight;
        BOOL isMovieCategory = (_selectedCategoryIndex == CATEGORY_MOVIES);
        BOOL isSeriesCategory = (_selectedCategoryIndex == CATEGORY_SERIES);
        BOOL isFavoritesWithMovies = (_selectedCategoryIndex == CATEGORY_FAVORITES && [self currentGroupContainsMovieChannels]);
        
        if ((isMovieCategory || isSeriesCategory || isFavoritesWithMovies) && _isStackedViewActive) {
            // Stacked view uses different item height and padding
            CGFloat itemHeight = 120;
            CGFloat padding = 10;
            contentHeight = channels.count * (itemHeight + padding) + itemHeight; // Extra space for last item
            NSLog(@"📱 [SCROLL-CALC] Using stacked view content height: %.1f for %lu channels", contentHeight, (unsigned long)channels.count);
        } else {
            // Regular list view
            contentHeight = channels.count * [self rowHeight];
            NSLog(@"📱 [SCROLL-CALC] Using list view content height: %.1f for %lu channels", contentHeight, (unsigned long)channels.count);
        }
        
        CGFloat visibleHeight = self.bounds.size.height;
        CGFloat maxScroll = MAX(0, contentHeight - visibleHeight);
        
        // Calculate new position
        CGFloat newPosition = _channelScrollPosition - deltaY;
        
        // iPhone-style bounce at edges
        if (newPosition < 0) {
            // Bounce at top - slow down as we go beyond bounds
            CGFloat overscroll = -newPosition;
            _channelScrollPosition = -(overscroll * 0.3); // Rubber band effect
        } else if (newPosition > maxScroll) {
            // Bounce at bottom - slow down as we go beyond bounds
            CGFloat overscroll = newPosition - maxScroll;
            _channelScrollPosition = maxScroll + (overscroll * 0.3); // Rubber band effect
        } else {
            // Normal scrolling within bounds
            _channelScrollPosition = newPosition;
        }
        
        [gesture setTranslation:CGPointZero inView:self];
        [self setNeedsDisplay];
        
        // Add momentum scrolling on gesture end with bounce-back
        if (gesture.state == UIGestureRecognizerStateEnded) {
            [self addMomentumScrollingForChannels:velocity.y maxScroll:maxScroll];
            }
        }
    }
}

- (void)addMomentumScrollingForGroups:(CGFloat)velocity maxScroll:(CGFloat)maxScroll {
    // True iPhone-style momentum with CADisplayLink for smooth animation
    if (fabs(velocity) < 50) {
        // Too slow for momentum - just snap back if needed
        [self snapGroupScrollToValidPosition:maxScroll];
        return;
    }
    
    // Stop any existing momentum
    [self stopGroupMomentumAnimation];
    
    // Store momentum parameters as instance variables
    _groupMomentumVelocity = velocity;
    _groupMomentumMaxScroll = maxScroll;
    
    // Create display link for smooth 60fps momentum animation
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateGroupMomentumScroll:)];
    _groupMomentumDisplayLink = displayLink; // weak reference
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)updateGroupMomentumScroll:(CADisplayLink *)displayLink {
    // iPhone deceleration rate
    CGFloat deceleration = 2000.0; // pixels per second^2
    CGFloat frameTime = displayLink.targetTimestamp - displayLink.timestamp;
    
    // Update velocity with deceleration
    if (_groupMomentumVelocity > 0) {
        _groupMomentumVelocity = MAX(0, _groupMomentumVelocity - deceleration * frameTime);
    } else {
        _groupMomentumVelocity = MIN(0, _groupMomentumVelocity + deceleration * frameTime);
    }
    
    // Update position
    _groupScrollPosition -= _groupMomentumVelocity * frameTime;
    
    // Handle bouncing at edges
    if (_groupScrollPosition < 0) {
        _groupScrollPosition = _groupScrollPosition * 0.5; // Rubber band
        _groupMomentumVelocity *= 0.8; // Reduce velocity when bouncing
    } else if (_groupScrollPosition > _groupMomentumMaxScroll) {
        CGFloat overshoot = _groupScrollPosition - _groupMomentumMaxScroll;
        _groupScrollPosition = _groupMomentumMaxScroll + overshoot * 0.5; // Rubber band
        _groupMomentumVelocity *= 0.8; // Reduce velocity when bouncing
    }
    
    // Stop if velocity is too low
    if (fabs(_groupMomentumVelocity) < 10) {
        [self stopGroupMomentumAnimation];
        [self snapGroupScrollToValidPosition:_groupMomentumMaxScroll];
        return;
    }
    
    [self setNeedsDisplay];
}

- (void)snapGroupScrollToValidPosition:(CGFloat)maxScroll {
    if (_groupScrollPosition < 0 || _groupScrollPosition > maxScroll) {
        CGFloat targetPosition = MAX(0, MIN(_groupScrollPosition, maxScroll));
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             self->_groupScrollPosition = targetPosition;
                             [self setNeedsDisplay];
                         } completion:nil];
    }
}

- (void)addMomentumScrollingForChannels:(CGFloat)velocity maxScroll:(CGFloat)maxScroll {
    // True iPhone-style momentum with CADisplayLink for smooth animation
    if (fabs(velocity) < 50) {
        // Too slow for momentum - just snap back if needed
        [self snapChannelScrollToValidPosition:maxScroll];
        return;
    }
    
    // Stop any existing momentum
    [self stopChannelMomentumAnimation];
    
    // Store momentum parameters as instance variables
    _channelMomentumVelocity = velocity;
    _channelMomentumMaxScroll = maxScroll;
    
    // Create display link for smooth 60fps momentum animation
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateChannelMomentumScroll:)];
    _channelMomentumDisplayLink = displayLink; // weak reference
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)updateChannelMomentumScroll:(CADisplayLink *)displayLink {
    // iPhone deceleration rate
    CGFloat deceleration = 2000.0; // pixels per second^2
    CGFloat frameTime = displayLink.targetTimestamp - displayLink.timestamp;
    
    // Update velocity with deceleration
    if (_channelMomentumVelocity > 0) {
        _channelMomentumVelocity = MAX(0, _channelMomentumVelocity - deceleration * frameTime);
    } else {
        _channelMomentumVelocity = MIN(0, _channelMomentumVelocity + deceleration * frameTime);
    }
    
    // Update position
    _channelScrollPosition -= _channelMomentumVelocity * frameTime;
    
    // Handle bouncing at edges
    if (_channelScrollPosition < 0) {
        _channelScrollPosition = _channelScrollPosition * 0.5; // Rubber band
        _channelMomentumVelocity *= 0.8; // Reduce velocity when bouncing
    } else if (_channelScrollPosition > _channelMomentumMaxScroll) {
        CGFloat overshoot = _channelScrollPosition - _channelMomentumMaxScroll;
        _channelScrollPosition = _channelMomentumMaxScroll + overshoot * 0.5; // Rubber band
        _channelMomentumVelocity *= 0.8; // Reduce velocity when bouncing
    }
    
    // Stop if velocity is too low
    if (fabs(_channelMomentumVelocity) < 10) {
        [self stopChannelMomentumAnimation];
        [self snapChannelScrollToValidPosition:_channelMomentumMaxScroll];
        return;
    }
    
    [self setNeedsDisplay];
}

- (void)snapChannelScrollToValidPosition:(CGFloat)maxScroll {
    if (_channelScrollPosition < 0 || _channelScrollPosition > maxScroll) {
        CGFloat targetPosition = MAX(0, MIN(_channelScrollPosition, maxScroll));
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
                             self->_channelScrollPosition = targetPosition;
                             [self setNeedsDisplay];
                         } completion:nil];
    }
}

- (void)stopGroupMomentumAnimation {
    CADisplayLink *displayLink = _groupMomentumDisplayLink;
    if (displayLink) {
        [displayLink invalidate];
        _groupMomentumDisplayLink = nil;
        _groupMomentumVelocity = 0;
    }
}

- (void)stopChannelMomentumAnimation {
    CADisplayLink *displayLink = _channelMomentumDisplayLink;
    if (displayLink) {
        [displayLink invalidate];
        _channelMomentumDisplayLink = nil;
        _channelMomentumVelocity = 0;
    }
}

- (void)addMomentumScrollingForProgramGuide:(CGFloat)velocity maxScroll:(CGFloat)maxScroll {
    // Program guide momentum scrolling
    if (fabs(velocity) < 50) {
        [self snapProgramGuideScrollToValidPosition:maxScroll];
        return;
    }
    
    [self stopProgramGuideMomentumAnimation];
    
    _programGuideMomentumVelocity = velocity;
    _programGuideMomentumMaxScroll = maxScroll;
    
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateProgramGuideMomentumScroll:)];
    _programGuideMomentumDisplayLink = displayLink;
    [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)updateProgramGuideMomentumScroll:(CADisplayLink *)displayLink {
    // Smoother deceleration for better feel
    CGFloat deceleration = 1200.0;  // Reduced from 2000 for smoother scrolling
    CGFloat frameTime = displayLink.targetTimestamp - displayLink.timestamp;
    
    if (_programGuideMomentumVelocity > 0) {
        _programGuideMomentumVelocity = MAX(0, _programGuideMomentumVelocity - deceleration * frameTime);
    } else {
        _programGuideMomentumVelocity = MIN(0, _programGuideMomentumVelocity + deceleration * frameTime);
    }
    
    _programGuideScrollPosition += _programGuideMomentumVelocity * frameTime;
    
    // Smoother rubber band effect with less aggressive dampening
    if (_programGuideScrollPosition < 0) {
        _programGuideScrollPosition = _programGuideScrollPosition * 0.7;  // Less aggressive bounce back
        _programGuideMomentumVelocity *= 0.9;  // Less velocity reduction
    } else if (_programGuideScrollPosition > _programGuideMomentumMaxScroll) {
        CGFloat overshoot = _programGuideScrollPosition - _programGuideMomentumMaxScroll;
        _programGuideScrollPosition = _programGuideMomentumMaxScroll + overshoot * 0.7;  // Less aggressive bounce back
        _programGuideMomentumVelocity *= 0.9;  // Less velocity reduction
    }
    
    // Lower threshold for stopping animation to reduce jerkiness
    if (fabs(_programGuideMomentumVelocity) < 5) {  // Reduced from 10 for smoother stop
        [self stopProgramGuideMomentumAnimation];
        [self snapProgramGuideScrollToValidPosition:_programGuideMomentumMaxScroll];
        return;
    }
    
    [self setNeedsDisplay];
}

- (void)snapProgramGuideScrollToValidPosition:(CGFloat)maxScroll {
    if (_programGuideScrollPosition < 0 || _programGuideScrollPosition > maxScroll) {
        CGFloat targetPosition = MAX(0, MIN(_programGuideScrollPosition, maxScroll));
        
        // Smoother spring animation with reduced duration and improved damping
        [UIView animateWithDuration:0.4  // Slightly longer for smoother feel
                              delay:0
             usingSpringWithDamping:0.9   // Higher damping for less oscillation
              initialSpringVelocity:0.3   // Small initial velocity for natural movement
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             self->_programGuideScrollPosition = targetPosition;
                             [self setNeedsDisplay];
                         } completion:nil];
    }
}

- (void)stopProgramGuideMomentumAnimation {
    CADisplayLink *displayLink = _programGuideMomentumDisplayLink;
    if (displayLink) {
        [displayLink invalidate];
        _programGuideMomentumDisplayLink = nil;
        _programGuideMomentumVelocity = 0;
    }
}

- (void)stopAllMomentumAnimations {
    [self stopGroupMomentumAnimation];
    [self stopChannelMomentumAnimation];
    [self stopProgramGuideMomentumAnimation];
}

#pragma mark - iOS Channel Switching (Menu Hidden)

- (void)handleChannelSwitchingGesture:(UIPanGestureRecognizer *)gesture {
    // CRITICAL: Only process when gesture ends - ignore all other states
    if (gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }
    
    NSLog(@"📺 [CHANNEL-SWITCH] Processing swipe gesture (touch released)");
    
    // Only process vertical movements for channel switching
    CGPoint translation = [gesture translationInView:self];
    CGPoint velocity = [gesture velocityInView:self];
    
    // Require significant vertical movement before considering it a channel switch
    CGFloat verticalThreshold = 50.0; // Minimum vertical movement
    CGFloat horizontalThreshold = 30.0; // Maximum horizontal movement (to avoid accidental horizontal swipes)
    
    CGFloat verticalMovement = fabs(translation.y);
    CGFloat horizontalMovement = fabs(translation.x);
    
    // Check if this is a clear vertical swipe
    if (verticalMovement >= verticalThreshold && horizontalMovement <= horizontalThreshold) {
        
        // Determine direction: swipe up = previous channel, swipe down = next channel
        BOOL swipeUp = translation.y < 0;
        NSLog(@"📺 [CHANNEL-SWITCH] %@ swipe detected (vertical: %.1f, horizontal: %.1f)", 
              swipeUp ? @"UP" : @"DOWN", verticalMovement, horizontalMovement);
        
        // Get current playing channel and find its group
        VLCChannel *currentPlayingChannel = [self getCurrentlyPlayingChannel];
        NSString *playingChannelGroup = nil;
        NSArray *channels = nil;
        NSInteger currentIndex = -1;
        
        if (currentPlayingChannel && currentPlayingChannel.group) {
            playingChannelGroup = currentPlayingChannel.group;
            channels = [_channelsByGroup objectForKey:playingChannelGroup];
            
            // Find the current channel's index within its group
            for (NSInteger i = 0; i < channels.count; i++) {
                VLCChannel *channel = channels[i];
                if ([channel.url isEqualToString:currentPlayingChannel.url]) {
                    currentIndex = i;
                    break;
                }
            }
            
            NSLog(@"📺 [CHANNEL-SWITCH] Playing channel: %@ in group: %@ (index %ld of %lu)", 
                  currentPlayingChannel.name, playingChannelGroup, (long)currentIndex, (unsigned long)channels.count);
        }
        
        // Fallback to menu selection if no playing channel found
        if (!channels || channels.count == 0 || currentIndex == -1) {
            NSLog(@"📺 [CHANNEL-SWITCH] No playing channel found, using menu selection");
            channels = [self getChannelsForCurrentGroup];
            currentIndex = _selectedChannelIndex;
            
            if (!channels || channels.count == 0) {
                NSLog(@"📺 [CHANNEL-SWITCH] No channels available for switching");
                return;
            }
        }
        
        // Calculate new channel index
        NSInteger newIndex;
        
        if (swipeUp) {
            // Swipe up = previous channel (decrement)
            newIndex = currentIndex - 1;
            if (newIndex < 0) {
                newIndex = channels.count - 1; // Wrap to last channel
            }
            NSLog(@"📺 [CHANNEL-SWITCH] Previous channel: %ld → %ld", (long)currentIndex, (long)newIndex);
        } else {
            // Swipe down = next channel (increment)
            newIndex = currentIndex + 1;
            if (newIndex >= channels.count) {
                newIndex = 0; // Wrap to first channel
            }
            NSLog(@"📺 [CHANNEL-SWITCH] Next channel: %ld → %ld", (long)currentIndex, (long)newIndex);
        }
        
        // Validate new index
                    if (newIndex >= 0 && newIndex < channels.count) {
                VLCChannel *newChannel = channels[newIndex];
                if (newChannel && [newChannel isKindOfClass:[VLCChannel class]]) {
                    
                    NSLog(@"📺 [CHANNEL-SWITCH] Switching to channel: %@ (index %ld)", 
                          newChannel.name, (long)newIndex);
                    NSLog(@"📺 [CHANNEL-SWITCH] Channel URL: %@", newChannel.url);
                    
                    // Play the new channel immediately using the URL
                    NSLog(@"📺 [CHANNEL-SWITCH] Starting playback...");
                    [self playChannelWithUrl:newChannel.url];
                    
                                         // Update menu selection to match the new playing channel
                     [self updateMenuSelectionForChannel:newChannel inGroup:playingChannelGroup ?: newChannel.group atIndex:newIndex];
                     
                     // Perform background alignment after channel switch
                     [self performBackgroundAlignment];
                     
                     // Save the new selection
                     [self saveCurrentSelectionState];
                    
                } else {
                    NSLog(@"📺 [CHANNEL-SWITCH] Invalid channel object at index %ld", (long)newIndex);
                }
            } else {
                NSLog(@"📺 [CHANNEL-SWITCH] Invalid channel index: %ld (total: %lu)", 
                      (long)newIndex, (unsigned long)channels.count);
            }
    } else {
        NSLog(@"📺 [CHANNEL-SWITCH] Gesture ignored - not a clear vertical swipe (v:%.1f h:%.1f)", 
              verticalMovement, horizontalMovement);
    }
    
    // Note: Don't reset translation here - let the gesture recognizer handle it naturally
}

- (void)updateMenuSelectionForChannel:(VLCChannel *)channel inGroup:(NSString *)groupName atIndex:(NSInteger)channelIndex {
    NSLog(@"📺 [MENU-SYNC] Updating menu selection for channel: %@ in group: %@", channel.name, groupName);
    
    if (!groupName || !channel) {
        NSLog(@"📺 [MENU-SYNC] Invalid parameters for menu sync");
        return;
    }
    
    // Find which category contains this group
    NSString *targetCategory = nil;
    NSInteger targetCategoryIndex = -1;
    NSInteger targetGroupIndex = -1;
    
    NSArray *categoryNames = @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
    
    for (NSInteger catIndex = 0; catIndex < categoryNames.count; catIndex++) {
        NSString *categoryKey = categoryNames[catIndex];
        NSArray *categoryGroups = [_groupsByCategory objectForKey:categoryKey];
        
        if (categoryGroups && [categoryGroups containsObject:groupName]) {
            targetCategory = categoryKey;
            targetCategoryIndex = catIndex;
            targetGroupIndex = [categoryGroups indexOfObject:groupName];
            break;
        }
    }
    
    if (targetCategory && targetCategoryIndex >= 0 && targetGroupIndex >= 0) {
        // Update menu selection to match playing channel
        _selectedCategoryIndex = targetCategoryIndex;
        _selectedGroupIndex = targetGroupIndex;
        _selectedChannelIndex = channelIndex;
        
        NSLog(@"📺 [MENU-SYNC] Updated menu: category=%@ (%ld), group=%@ (%ld), channel=%ld", 
              targetCategory, (long)targetCategoryIndex, groupName, (long)targetGroupIndex, (long)channelIndex);
    } else {
        NSLog(@"📺 [MENU-SYNC] Could not find group '%@' in any category", groupName);
    }
}

#pragma mark - Auto-Alignment Timer Management

- (void)startAutoAlignmentTimer {
    [self stopAutoAlignmentTimer];
    
    NSLog(@"🔄 [AUTO-ALIGN] Starting 15-second auto-alignment timer");
    self.autoAlignmentTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                              target:self
                                                            selector:@selector(autoAlignmentTimerFired:)
                                                            userInfo:nil
                                                             repeats:NO];
}

- (void)stopAutoAlignmentTimer {
    if (self.autoAlignmentTimer) {
        NSLog(@"🔄 [AUTO-ALIGN] Stopping auto-alignment timer");
        [self.autoAlignmentTimer invalidate];
        self.autoAlignmentTimer = nil;
    }
}

- (void)autoAlignmentTimerFired:(NSTimer *)timer {
    NSLog(@"🔄 [AUTO-ALIGN] Timer fired - performing background alignment");
    [self performBackgroundAlignment];
    self.autoAlignmentTimer = nil;
}

- (void)checkAndStartAutoAlignmentTimer {
    // Only start the timer if menu is hidden
    if (!self.isChannelListVisible) {
        NSLog(@"🔄 [AUTO-ALIGN] App startup: Menu is hidden, starting auto-alignment timer");
        [self startAutoAlignmentTimer];
    } else {
        NSLog(@"🔄 [AUTO-ALIGN] App startup: Menu is visible, no auto-alignment timer needed");
    }
}

#pragma mark - Background Alignment Methods

- (void)performBackgroundAlignment {
    NSLog(@"🔄 [AUTO-ALIGN] Performing complete background alignment");
    
    // Align menu to playing channel
    [self alignMenuToPlayingChannelInBackground];
    
    // Align EPG to playing program
    [self alignEpgToPlayingProgramInBackground];
}

- (void)alignMenuToPlayingChannelInBackground {
    VLCChannel *currentChannel = [self getCurrentlyPlayingChannel];
    if (!currentChannel || !currentChannel.group) {
        NSLog(@"🔄 [MENU-ALIGN] No playing channel to align to");
        return;
    }
    
    NSLog(@"🔄 [MENU-ALIGN] Aligning menu to playing channel: %@ in group: %@", currentChannel.name, currentChannel.group);
    
    // Find the channel's position in its group
    NSArray *groupChannels = [_channelsByGroup objectForKey:currentChannel.group];
    NSInteger channelIndex = -1;
    
    for (NSInteger i = 0; i < groupChannels.count; i++) {
        VLCChannel *channel = groupChannels[i];
        if ([channel.url isEqualToString:currentChannel.url]) {
            channelIndex = i;
            break;
        }
    }
    
    if (channelIndex >= 0) {
        // Update menu selection (this will be used when menu opens next time)
        [self updateMenuSelectionForChannel:currentChannel inGroup:currentChannel.group atIndex:channelIndex];
        
        // If menu is hidden, calculate and store scroll positions for when it opens
        if (!self.isChannelListVisible) {
            [self calculateAndStoreScrollPositionsForChannel:currentChannel atIndex:channelIndex];
        }
    }
}

- (void)alignEpgToPlayingProgramInBackground {
    VLCChannel *currentChannel = [self getCurrentlyPlayingChannel];
    if (!currentChannel) {
        NSLog(@"🔄 [EPG-ALIGN] No playing channel for EPG alignment");
        return;
    }
    
    VLCProgram *currentProgram = [self getCurrentlyPlayingProgram];
    if (!currentProgram) {
        NSLog(@"🔄 [EPG-ALIGN] No current program found for channel: %@", currentChannel.name);
        return;
    }
    
    NSLog(@"🔄 [EPG-ALIGN] Aligning EPG to current program: %@", currentProgram.title);
    
    // Find the current program index in EPG data
    NSArray *channelPrograms = [self.epgData objectForKey:currentChannel.name];
    if (channelPrograms) {
        NSInteger programIndex = [channelPrograms indexOfObject:currentProgram];
        if (programIndex != NSNotFound) {
            self.selectedEpgProgramIndex = programIndex;
            
            // Calculate EPG scroll position if menu is hidden
            if (!self.isChannelListVisible) {
                [self calculateAndStoreEpgScrollPosition:programIndex];
            }
            
            NSLog(@"🔄 [EPG-ALIGN] Set EPG program index to: %ld", (long)programIndex);
        }
    }
}

- (void)calculateAndStoreScrollPositionsForChannel:(VLCChannel *)channel atIndex:(NSInteger)channelIndex {
    // Calculate ideal scroll positions for when menu opens
    // This is platform-specific but follows the same principles
    
    CGFloat itemHeight = 40.0; // Approximate item height
    CGFloat visibleHeight = self.bounds.size.height * 0.6; // Approximate visible area
    CGFloat idealScrollPosition = (channelIndex * itemHeight) - (visibleHeight / 2);
    
    // Clamp scroll position to valid range
    NSArray *channels = [self getChannelsForCurrentGroup];
    CGFloat maxScroll = MAX(0, (channels.count * itemHeight) - visibleHeight);
    idealScrollPosition = MAX(0, MIN(idealScrollPosition, maxScroll));
    
    // Store for when menu opens
    self.scrollPosition = idealScrollPosition;
    
    NSLog(@"🔄 [SCROLL-CALC] Calculated scroll position: %.1f for channel at index %ld", 
          idealScrollPosition, (long)channelIndex);
}

- (void)calculateAndStoreEpgScrollPosition:(NSInteger)programIndex {
    // Calculate EPG scroll position
    CGFloat programHeight = 60.0; // Approximate program item height
    CGFloat visibleHeight = self.bounds.size.height * 0.4; // EPG visible area
    CGFloat idealEpgScroll = (programIndex * programHeight) - (visibleHeight / 2);
    
    // Store for when EPG opens
    self.epgScrollPosition = MAX(0, idealEpgScroll);
    
    NSLog(@"🔄 [EPG-SCROLL-CALC] Calculated EPG scroll position: %.1f for program at index %ld", 
          idealEpgScroll, (long)programIndex);
}

#pragma mark - Button State Management

- (void)setLoadingButtonsEnabled:(BOOL)enabled {
    if (self.loadUrlButtoniOS) {
        self.loadUrlButtoniOS.enabled = enabled;
        self.loadUrlButtoniOS.alpha = enabled ? 1.0 : 0.5;
        NSLog(@"🔧 [BUTTON-STATE] Load URL button %@", enabled ? @"enabled" : @"disabled");
    }
    
    if (self.updateEpgButtoniOS) {
        self.updateEpgButtoniOS.enabled = enabled;
        self.updateEpgButtoniOS.alpha = enabled ? 1.0 : 0.5;
        NSLog(@"🔧 [BUTTON-STATE] Update EPG button %@", enabled ? @"enabled" : @"disabled");
    }
}

#pragma mark - Menu Visibility with Auto-Alignment Integration

- (void)setIsChannelListVisible:(BOOL)isChannelListVisible {
    BOOL wasVisible = _isChannelListVisible;
    _isChannelListVisible = isChannelListVisible;
    
    if (wasVisible != isChannelListVisible) {
        if (isChannelListVisible) {
            // Menu is being shown - stop auto-alignment timer
            NSLog(@"👁️ [MENU-VISIBILITY] Menu shown - stopping auto-alignment timer");
            [self stopAutoAlignmentTimer];
        } else {
            // Menu is being hidden - start auto-alignment timer
            NSLog(@"👁️ [MENU-VISIBILITY] Menu hidden - starting 15-second auto-alignment timer");
            [self startAutoAlignmentTimer];
        }
    }
}

// Channel switch overlay methods removed - player controls already show current channel

- (NSString *)formatProgramTimeInfo:(VLCProgram *)program {
    if (!program) {
        return @"";
    }
    
    NSDateFormatter *timeFormatter = [[NSDateFormatter alloc] init];
    [timeFormatter setDateFormat:@"HH:mm"];
    
    NSString *startTime = program.startTime ? [timeFormatter stringFromDate:program.startTime] : @"--:--";
    NSString *endTime = program.endTime ? [timeFormatter stringFromDate:program.endTime] : @"--:--";
    
    [timeFormatter release];
    
    return [NSString stringWithFormat:@"%@ - %@", startTime, endTime];
}

- (void)saveCurrentSelectionState {
    // Save current selection state for persistence across app restarts
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    [defaults setInteger:_selectedCategoryIndex forKey:@"selectedCategoryIndex"];
    [defaults setInteger:_selectedGroupIndex forKey:@"selectedGroupIndex"];
    [defaults setInteger:_selectedChannelIndex forKey:@"selectedChannelIndex"];
    
    // Also save the currently playing channel URL for restoration
    NSArray *channels = [self getChannelsForCurrentGroup];
    if (_selectedChannelIndex >= 0 && _selectedChannelIndex < channels.count) {
        VLCChannel *currentChannel = channels[_selectedChannelIndex];
        if (currentChannel && currentChannel.url) {
            [defaults setObject:currentChannel.url forKey:@"lastPlayedChannelUrl"];
            NSLog(@"📺 [STATE] Saved selection state: cat=%ld, group=%ld, channel=%ld, url=%@", 
                  (long)_selectedCategoryIndex, (long)_selectedGroupIndex, (long)_selectedChannelIndex, currentChannel.url);
        }
    }
    
    [defaults synchronize];
}

#pragma mark - iOS Progress Bar Scrubbing

- (void)handleProgressBarPan:(UIPanGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:self];
    
    // Check if the pan started on the progress bar
    if (gesture.state == UIGestureRecognizerStateBegan) {
        NSValue *progressRectValue = objc_getAssociatedObject(self, @selector(progressBarRect));
        if (!progressRectValue) {
            return; // No progress bar rect stored
        }
        
        CGRect progressRect = [progressRectValue CGRectValue];
        // Expand touch area for easier touch detection
        CGRect expandedProgressRect = CGRectInset(progressRect, -20, -20);
        
        if (CGRectContainsPoint(expandedProgressRect, location)) {
            NSLog(@"📱 [SCRUB] Started scrubbing progress bar");
            _isScrubbingProgressBar = YES;
            _progressBarScrubStartPoint = location;
            
            // Calculate initial position
            CGFloat relativeX = location.x - progressRect.origin.x;
            _progressBarScrubStartPosition = relativeX / progressRect.size.width;
            _progressBarScrubStartPosition = MAX(0.0, MIN(1.0, _progressBarScrubStartPosition));
            
            [self createTimePreviewOverlay];
            [self updateTimePreviewAtPosition:_progressBarScrubStartPosition withPoint:location];
            
            // STOP auto-hide timer during scrubbing to prevent controls from hiding
            [self stopAutoHideTimer];
            NSLog(@"📱 [SCRUB] Auto-hide timer stopped during scrubbing");
        }
        return;
    }
    
    // Only process if we're actually scrubbing
    if (!_isScrubbingProgressBar) {
        return;
    }
    
    NSValue *progressRectValue = objc_getAssociatedObject(self, @selector(progressBarRect));
    if (!progressRectValue) {
        [self endProgressBarScrubbing];
        return;
    }
    
    CGRect progressRect = [progressRectValue CGRectValue];
    
    if (gesture.state == UIGestureRecognizerStateChanged) {
        // Update preview position during dragging
        CGFloat relativeX = location.x - progressRect.origin.x;
        CGFloat seekPosition = relativeX / progressRect.size.width;
        seekPosition = MAX(0.0, MIN(1.0, seekPosition));
        
        [self updateTimePreviewAtPosition:seekPosition withPoint:location];
        
        // Update progress bar visual feedback
        _progressBarBeingTouched = YES;
        _progressBarTouchPoint = location;
        [self setNeedsDisplay];
        
        NSLog(@"📱 [SCRUB] Scrubbing to position: %.3f", seekPosition);
        
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        // Seek to final position and end scrubbing
        CGFloat relativeX = location.x - progressRect.origin.x;
        CGFloat seekPosition = relativeX / progressRect.size.width;
        seekPosition = MAX(0.0, MIN(1.0, seekPosition));
        
        NSLog(@"📱 [SCRUB] Ended scrubbing, seeking to position: %.3f", seekPosition);
        
        // Perform the actual seek
        [self performSeekToPosition:seekPosition];
        
        [self endProgressBarScrubbing];
    }
}

- (void)createTimePreviewOverlay {
    if (_timePreviewOverlay) {
        return; // Already created
    }
    
    // Create semi-transparent overlay view
    _timePreviewOverlay = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    _timePreviewOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.8];
    _timePreviewOverlay.layer.cornerRadius = 8;
    _timePreviewOverlay.layer.masksToBounds = YES;
    
    // Create time label
    _timePreviewLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
    _timePreviewLabel.textColor = [UIColor whiteColor];
    _timePreviewLabel.textAlignment = NSTextAlignmentCenter;
    _timePreviewLabel.font = [UIFont boldSystemFontOfSize:14];
    _timePreviewLabel.numberOfLines = 2;
    
    [_timePreviewOverlay addSubview:_timePreviewLabel];
    [self addSubview:_timePreviewOverlay];
    
    NSLog(@"📱 [SCRUB] Created time preview overlay");
}

- (void)updateTimePreviewAtPosition:(CGFloat)position withPoint:(CGPoint)point {
    if (!_timePreviewOverlay || !_timePreviewLabel) {
        return;
    }
    
    // Calculate the time at this position
    NSString *timeString = [self calculateTimeStringAtPosition:position];
    _timePreviewLabel.text = timeString;
    
    // Position the overlay above the touch point
    CGFloat overlayWidth = 100;
    CGFloat overlayHeight = 40;
    CGFloat overlayX = point.x - overlayWidth / 2;
    CGFloat overlayY = point.y - overlayHeight - 60; // 60pt above touch point (lower than before)
    
    // Keep overlay within bounds
    overlayX = MAX(10, MIN(self.bounds.size.width - overlayWidth - 10, overlayX));
    overlayY = MAX(10, overlayY);
    
    _timePreviewOverlay.frame = CGRectMake(overlayX, overlayY, overlayWidth, overlayHeight);
    _timePreviewOverlay.hidden = NO;
    
    NSLog(@"📱 [SCRUB] Updated time preview: %@ at position %.3f", timeString, position);
}

- (NSString *)calculateTimeStringAtPosition:(CGFloat)position {
    if (!self.player || !self.player.media) {
        return @"--:--";
    }
    
    // Check if we're in timeshift mode
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    
    if (isTimeshiftPlaying) {
        // FIXED: Use Mac-style 2-hour sliding window calculation for timeshift
        NSString *currentUrl = [self.player.media.url absoluteString];
        NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
        
        if (timeshiftStartTime) {
            // Apply EPG offset adjustment (same as Mac version)
            NSTimeInterval epgAdjustmentForDisplay = self.epgTimeOffsetHours * 3600.0;
            timeshiftStartTime = [timeshiftStartTime dateByAddingTimeInterval:epgAdjustmentForDisplay];
            
            // Get current playback position
            VLCTime *currentTime = [self.player time];
            if (currentTime) {
                NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
                NSDate *actualPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
                
                // Create 2-hour sliding window centered around current play time (EXACT Mac logic)
                NSDate *windowStartTime = [actualPlayTime dateByAddingTimeInterval:-3600]; // -1 hour
                NSDate *windowEndTime = [actualPlayTime dateByAddingTimeInterval:3600];    // +1 hour
                
                // Apply same constraint as Mac: cap end time at current real time
                NSDate *currentRealTime = [NSDate date];
                NSTimeInterval epgOffsetSeconds = -self.epgTimeOffsetHours * 3600.0;
                NSDate *maxAllowedTime = [currentRealTime dateByAddingTimeInterval:epgOffsetSeconds];
                
                if ([windowEndTime compare:maxAllowedTime] == NSOrderedDescending) {
                    windowEndTime = maxAllowedTime;
                }
                
                // Calculate target time within sliding window based on position
                NSTimeInterval windowDuration = [windowEndTime timeIntervalSinceDate:windowStartTime];
                NSTimeInterval targetOffsetFromWindowStart = position * windowDuration;
                NSDate *targetTime = [windowStartTime dateByAddingTimeInterval:targetOffsetFromWindowStart];
                
                // Apply EPG offset for display (same as Mac)
                NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
                NSDate *displayTargetTime = [targetTime dateByAddingTimeInterval:displayOffsetSeconds];
                
                // Format as actual time (not duration)
                NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                [formatter setDateFormat:@"HH:mm:ss"];
                [formatter setTimeZone:[NSTimeZone localTimeZone]];
                NSString *timeString = [formatter stringFromDate:displayTargetTime];
                [formatter release];
                
                NSLog(@"📱 [TIMESHIFT-PREVIEW] Position %.3f = %@ (Mac-style sliding window)", 
                      position, timeString);
                
                return timeString;
            }
        }
        
        // Fallback for timeshift if we can't get start time
        NSLog(@"📱 [TIMESHIFT-PREVIEW] Could not extract timeshift start time, using duration fallback");
    }
    
    // For normal content or timeshift fallback, show duration-based time
    VLCTime *totalTime = [self.player.media length];
    if (!totalTime || [totalTime intValue] <= 0) {
        return @"--:--";
    }
    
    // Calculate target time as duration
    int totalMs = [totalTime intValue];
    int targetMs = (int)(totalMs * position);
    
    // Format as duration string
    int seconds = targetMs / 1000;
    int minutes = seconds / 60;
    int hours = minutes / 60;
    
    seconds = seconds % 60;
    minutes = minutes % 60;
    
    if (hours > 0) {
        return [NSString stringWithFormat:@"%d:%02d:%02d", hours, minutes, seconds];
    } else {
        return [NSString stringWithFormat:@"%d:%02d", minutes, seconds];
    }
}

- (void)performSeekToPosition:(CGFloat)position {
    // Use existing seeking logic
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    
    if (isTimeshiftPlaying) {
        [self handleTimeshiftSeekiOS:position];
        NSLog(@"📱 [SCRUB] Performed timeshift seek to position: %.3f", position);
    } else {
        [self handleNormalSeekiOS:position];
        NSLog(@"📱 [SCRUB] Performed normal seek to position: %.3f", position);
    }
}

- (void)endProgressBarScrubbing {
    _isScrubbingProgressBar = NO;
    _progressBarBeingTouched = NO;
    
    // Hide and clean up time preview overlay
    if (_timePreviewOverlay) {
        _timePreviewOverlay.hidden = YES;
        [_timePreviewOverlay removeFromSuperview];
        [_timePreviewOverlay release];
        _timePreviewOverlay = nil;
    }
    
    if (_timePreviewLabel) {
        [_timePreviewLabel release];
        _timePreviewLabel = nil;
    }
    
    // RESTART auto-hide timer after scrubbing ends
    if (_playerControlsVisible) {
        [self resetPlayerControlsTimer];
        NSLog(@"📱 [SCRUB] Auto-hide timer restarted after scrubbing ended");
    }
    
    [self setNeedsDisplay];
    NSLog(@"📱 [SCRUB] Ended progress bar scrubbing");
}

#pragma mark - Shared Timeshift Methods (iOS Implementation)

- (BOOL)isCurrentlyPlayingTimeshift {
    // iOS implementation of timeshift detection
    if (!self.player || !self.player.media) {
        return NO;
    }
    
    NSString *currentUrl = [self.player.media.url absoluteString];
    if (!currentUrl) {
        return NO;
    }
    
    // Check if URL contains timeshift parameters
    return ([currentUrl rangeOfString:@"timeshift.php"].location != NSNotFound ||
            [currentUrl rangeOfString:@"timeshift"].location != NSNotFound);
}

- (VLCProgram *)getCurrentTimeshiftPlayingProgram {
    // iOS implementation of timeshift program detection - Enhanced to match macOS logic
    NSLog(@"📺 iOS getCurrentTimeshiftPlayingProgram - enhanced implementation");
    
    // Check if we're actually playing timeshift content
    if (![self isCurrentlyPlayingTimeshift]) {
        return nil;
    }
    
    NSLog(@"📺 iOS getCurrentTimeshiftPlayingProgram - REAL-TIME CALCULATION");
    
    // FORCE REAL-TIME CALCULATION: Always calculate based on current playing time
    // instead of relying on potentially outdated cached information
    
    // Get current channel - Try to find the original channel that this timeshift content belongs to
    VLCChannel *currentChannel = nil;
    
    // First, try to get cached content info to find the channel
    NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
    NSString *channelName = [cachedInfo objectForKey:@"channelName"];
    NSString *channelUrl = [cachedInfo objectForKey:@"url"];
    
    NSLog(@"📺 Cached channel info: name='%@', url='%@'", channelName, channelUrl);
    
    // Extract original channel name from timeshift name (remove timeshift suffix)
    NSString *originalChannelName = channelName;
    if (channelName && [channelName containsString:@" (Timeshift:"]) {
        NSRange timeshiftRange = [channelName rangeOfString:@" (Timeshift:"];
        if (timeshiftRange.location != NSNotFound) {
            originalChannelName = [channelName substringToIndex:timeshiftRange.location];
            NSLog(@"📺 Extracted original channel name: '%@'", originalChannelName);
        }
    }
    
    if (originalChannelName && _channels && _channels.count > 0) {
        // Search for the original channel by name
        for (VLCChannel *channel in _channels) {
            if ([channel isKindOfClass:[VLCChannel class]] && [channel.name isEqualToString:originalChannelName]) {
                currentChannel = channel;
                NSLog(@"📺 ✅ Found original channel by name: %@ with %ld programs", 
                      channel.name, (long)channel.programs.count);
                break;
            }
        }
    }
    
    // Final fallback: Try selection-based approach if we still don't have a channel
    if (!currentChannel && _selectedChannelIndex >= 0) {
        NSArray *channels = [self getChannelsForCurrentGroup];
        if (_selectedChannelIndex < channels.count) {
            id channelObject = channels[_selectedChannelIndex];
            if ([channelObject isKindOfClass:[VLCChannel class]]) {
                currentChannel = (VLCChannel *)channelObject;
                NSLog(@"📺 ✅ Found channel from selection: %@ with %ld programs", 
                      currentChannel.name, (long)currentChannel.programs.count);
            }
        }
    }
    
    if (!currentChannel || !currentChannel.programs) {
        NSLog(@"📺 ❌ No current channel or programs available - channel: %@, programs count: %ld", 
              currentChannel ? currentChannel.name : @"nil", 
              currentChannel ? (long)currentChannel.programs.count : 0);
        return nil;
    }
    
    // Get timeshift start time and current playback position
    NSString *currentUrl = [self.player.media.url absoluteString];
    NSDate *timeshiftStartTime = [self extractTimeshiftStartTimeFromUrl:currentUrl];
    
    if (!timeshiftStartTime) {
        NSLog(@"📺 Could not extract timeshift start time from URL: %@", currentUrl);
        return nil;
    }
    
    VLCTime *currentTime = [self.player time];
    if (!currentTime) {
        NSLog(@"📺 No current player time available");
        return nil;
    }
    
    // Calculate the actual time being played
    NSTimeInterval currentSeconds = [currentTime intValue] / 1000.0;
    NSDate *actualPlayTime = [timeshiftStartTime dateByAddingTimeInterval:currentSeconds];
    
    NSLog(@"📺 Timeshift start time: %@", timeshiftStartTime);
    NSLog(@"📺 Current player time: %.1f seconds", currentSeconds);
    NSLog(@"📺 Actual play time: %@", actualPlayTime);
    NSLog(@"📺 EPG offset: %ld hours", (long)self.epgTimeOffsetHours);
    
    // Apply EPG offset to the actual play time for program matching
    // When EPG offset is -1 hour, we need to subtract 1 hour from actual play time
    // to match against the program times which are in the EPG's time zone
    NSTimeInterval epgOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
    NSDate *adjustedPlayTime = [actualPlayTime dateByAddingTimeInterval:epgOffsetSeconds];
    
    NSLog(@"📺 Adjusted play time for program matching: %@", adjustedPlayTime);
    
    // Find the program that was playing at this adjusted time
    VLCProgram *matchedProgram = nil;
    for (VLCProgram *program in currentChannel.programs) {
        if (program.startTime && program.endTime) {
            //NSLog(@"📺 Checking program: %@ (%@ - %@)", program.title, program.startTime, program.endTime);
            
            if ([adjustedPlayTime compare:program.startTime] != NSOrderedAscending && 
                [adjustedPlayTime compare:program.endTime] == NSOrderedAscending) {
                matchedProgram = program;
                NSLog(@"📺 ✅ MATCHED timeshift program: %@", program.title);
                break;
            }
        }
    }
    
    if (!matchedProgram) {
        NSLog(@"📺 ❌ No matching timeshift program found for time: %@", adjustedPlayTime);
    }
    
    NSLog(@"📺 === iOS getCurrentTimeshiftPlayingProgram - RETURNING: %@ ===", matchedProgram ? matchedProgram.title : @"nil");
    
    return matchedProgram;
}

// Add helper method to extract timeshift start time from URL (iOS implementation)
- (NSDate *)extractTimeshiftStartTimeFromUrl:(NSString *)url {
    if (!url) return nil;
    
    // Look for timeshift parameters in URL
    // Common patterns: utc=1234567890, timestamp=1234567890, time=1234567890, start=2085-06-11:05-30
    NSArray *patterns = @[@"utc=", @"timestamp=", @"time=", @"start="];
    
    for (NSString *pattern in patterns) {
        NSRange patternRange = [url rangeOfString:pattern];
        if (patternRange.location != NSNotFound) {
            NSInteger startPos = patternRange.location + patternRange.length;
            NSString *remaining = [url substringFromIndex:startPos];
            
            // Find the end of the timestamp (next & or end of string)
            NSRange endRange = [remaining rangeOfString:@"&"];
            NSString *timestampStr;
            if (endRange.location != NSNotFound) {
                timestampStr = [remaining substringToIndex:endRange.location];
            } else {
                timestampStr = remaining;
            }
            
            NSLog(@"📺 Raw timestamp string: %@", timestampStr);
            
            // Handle different timestamp formats
            NSDate *date = [self parseTimeshiftTimestamp:timestampStr];
            if (date) {
                NSLog(@"📺 Extracted timeshift start time: %@ from timestamp: %@", date, timestampStr);
                return date;
            }
        }
    }
    
    NSLog(@"📺 Could not extract timeshift start time from URL: %@", url);
    return nil;
}

- (NSDate *)parseTimeshiftTimestamp:(NSString *)timestampStr {
    if (!timestampStr || timestampStr.length == 0) {
        return nil;
    }
    
    // Check for complex format like "2085-06-11:05-30"
    if ([timestampStr containsString:@"-"] && [timestampStr containsString:@":"]) {
        NSLog(@"📺 Parsing complex timestamp format: %@", timestampStr);
        
        // Split by first dash to separate timestamp from date/time suffix
        NSRange firstDash = [timestampStr rangeOfString:@"-"];
        if (firstDash.location != NSNotFound) {
            NSString *baseTimestamp = [timestampStr substringToIndex:firstDash.location];
            NSString *suffix = [timestampStr substringFromIndex:firstDash.location + 1];
            
            NSLog(@"📺 Base timestamp: %@, Suffix: %@", baseTimestamp, suffix);
            
            // Try to parse the suffix as a date/time format MM-dd:HH-mm
            NSRegularExpression *suffixRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d{2})-(\\d{2}):(\\d{2})-(\\d{2})" options:0 error:nil];
            NSTextCheckingResult *suffixMatch = [suffixRegex firstMatchInString:suffix options:0 range:NSMakeRange(0, suffix.length)];
            
            if (suffixMatch && suffixMatch.numberOfRanges >= 5) {
                int month = [[suffix substringWithRange:[suffixMatch rangeAtIndex:1]] intValue];
                int day = [[suffix substringWithRange:[suffixMatch rangeAtIndex:2]] intValue];
                int hour = [[suffix substringWithRange:[suffixMatch rangeAtIndex:3]] intValue];
                int minute = [[suffix substringWithRange:[suffixMatch rangeAtIndex:4]] intValue];
                
                NSLog(@"📺 Parsed date components - Month: %d, Day: %d, Hour: %d, Minute: %d", month, day, hour, minute);
                
                // Create a date from these components (assuming current year)
                NSCalendar *calendar = [NSCalendar currentCalendar];
                NSDateComponents *components = [[NSDateComponents alloc] init];
                [components setYear:2025]; // Use current year
                [components setMonth:month];
                [components setDay:day];
                [components setHour:hour];
                [components setMinute:minute];
                [components setSecond:0];
                
                NSDate *parsedDate = [calendar dateFromComponents:components];
                [components release];
                
                if (parsedDate) {
                    NSLog(@"📺 Successfully parsed complex timestamp to date: %@", parsedDate);
                    return parsedDate;
                }
            }
            
            // If suffix parsing fails, try the base timestamp as Unix timestamp
            NSTimeInterval baseUnixTimestamp = [baseTimestamp doubleValue];
            if (baseUnixTimestamp > 0) {
                NSDate *fallbackDate = [NSDate dateWithTimeIntervalSince1970:baseUnixTimestamp];
                NSLog(@"📺 Using base timestamp as Unix time: %@", fallbackDate);
                return fallbackDate;
            }
        }
    }
    
    // Handle simple Unix timestamp format
    NSTimeInterval timestamp = [timestampStr doubleValue];
    if (timestamp > 0) {
        // Check if it's a reasonable Unix timestamp (after 2000)
        if (timestamp > 946684800) { // Jan 1, 2000
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp];
            NSLog(@"📺 Parsed as Unix timestamp: %@", date);
            return date;
        } else {
            NSLog(@"📺 Timestamp %@ seems too small to be a valid Unix timestamp", timestampStr);
        }
    }
    
    NSLog(@"📺 Failed to parse timestamp: %@", timestampStr);
    return nil;
}

// Add methods for caching content info (iOS implementation)
- (NSDictionary *)getLastPlayedContentInfo {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *info = [defaults objectForKey:@"LastPlayedContentInfo"];
    return info;
}



- (VLCChannel *)getCurrentlyPlayingChannel {
    // Get the currently playing channel (for regular and timeshift playback)
    if (!self.player || !self.player.media) {
        return nil;
    }
    
    NSString *currentUrl = [self.player.media.url absoluteString];
    if (!currentUrl) {
        return nil;
    }
    
    NSArray *allChannels = _channels;
    if (!allChannels) {
        return nil;
    }
    
    // Find channel with matching URL
    for (VLCChannel *channel in allChannels) {
        if ([channel isKindOfClass:[VLCChannel class]] && [channel.url isEqualToString:currentUrl]) {
            return channel;
        }
    }
    
    return nil;
}

- (VLCProgram *)getCurrentlyPlayingProgram {
    // Get the currently playing program (live TV program for the playing channel)
    VLCChannel *currentChannel = [self getCurrentlyPlayingChannel];
    if (!currentChannel || !currentChannel.programs || currentChannel.programs.count == 0) {
        return nil;
    }
    
    // Get current time with EPG offset
    NSDate *now = [NSDate date];
    NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600;
    NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
    
    // Find current program
    for (VLCProgram *program in currentChannel.programs) {
        if ([adjustedNow timeIntervalSinceDate:program.startTime] >= 0 && 
            [adjustedNow timeIntervalSinceDate:program.endTime] < 0) {
            return program;
        }
    }
    
    return nil;
}

- (void)clearLoadingState {
    // Clear all loading states to prevent concurrent operations
    _isDownloadingChannels = NO;
    _isDownloadingEPG = NO;
    self.isLoading = NO;
    self.isLoadingEpg = NO;
    NSLog(@"🔧 All loading states cleared");
}

- (void)clearChannelLoadingState {
    // Clear only M3U/channel loading states (keeps EPG separate)
    _isDownloadingChannels = NO;
    self.isLoading = NO;
    NSLog(@"🔧 Channel loading states cleared");
}

- (void)clearEpgLoadingState {
    // Clear only EPG loading states (keeps M3U separate)
    _isDownloadingEPG = NO;
    self.isLoadingEpg = NO;
    NSLog(@"🔧 EPG loading states cleared");
}

- (void)safelyReplaceChannelData:(NSMutableArray *)newChannels 
                          groups:(NSMutableArray *)newGroups 
                 channelsByGroup:(NSMutableDictionary *)newChannelsByGroup 
                groupsByCategory:(NSMutableDictionary *)newGroupsByCategory {
    
    NSLog(@"🔧 safelyReplaceChannelData called with:");
    NSLog(@"🔧   - %lu channels", (unsigned long)[newChannels count]);
    NSLog(@"🔧   - %lu groups", (unsigned long)[newGroups count]);
    NSLog(@"🔧   - %lu groups by category", (unsigned long)[newChannelsByGroup count]);
    NSLog(@"🔧   - %lu categories", (unsigned long)[newGroupsByCategory count]);
    
    // Replace data atomically to prevent enumeration crashes
    @synchronized(self) {
        // Release old data
        [_channels release];
        [_groups release];
        [_channelsByGroup release];
        [_groupsByCategory release];
        
        // Set new data
        _channels = [newChannels retain];
        _groups = [newGroups retain];
        _channelsByGroup = [newChannelsByGroup retain];
        _groupsByCategory = [newGroupsByCategory retain];
        
        NSLog(@"🔧 Data replacement completed - new counts:");
        NSLog(@"🔧   - _channels: %lu", (unsigned long)[_channels count]);
        NSLog(@"🔧   - _groups: %lu", (unsigned long)[_groups count]);
        NSLog(@"🔧   - _channelsByGroup: %lu", (unsigned long)[_channelsByGroup count]);
        NSLog(@"🔧   - _groupsByCategory: %lu", (unsigned long)[_groupsByCategory count]);
        
        // Populate _categories from the loaded data
        NSMutableArray *loadedCategories = [[NSMutableArray alloc] init];
        // Add standard categories first
        [loadedCategories addObject:@"SEARCH"];
        [loadedCategories addObject:@"FAVORITES"];
        
        // Add categories that have actual data
        for (NSString *category in [_groupsByCategory allKeys]) {
            if (![loadedCategories containsObject:category]) {
                [loadedCategories addObject:category];
            }
        }
        
        // Always ensure Settings is last
        if (![loadedCategories containsObject:@"SETTINGS"]) {
            [loadedCategories addObject:@"SETTINGS"];
        }
        
        // Replace categories array
        [_categories release];
        _categories = [loadedCategories retain];
        [loadedCategories release];
        
        NSLog(@"🔧 Updated _categories with %lu categories: %@", (unsigned long)[_categories count], _categories);
        
        // Auto-trigger EPG loading now that channels are loaded
        if ([_channels count] > 0 && !self.isEpgLoaded && !self.isLoadingEpg && self.epgUrl) {
            NSLog(@"📅 ✅ Channels loaded successfully - triggering EPG loading via VLCDataManager");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[VLCDataManager sharedManager] loadEPGFromURL:self.epgUrl];
            });
        }
    }
}

#pragma mark - Channel Playback (Shared Interface)

- (void)playChannelAtIndex:(NSInteger)index {
    NSArray *channels = [self getChannelsForCurrentGroup];
    NSLog(@"📺 playChannelAtIndex:%ld with %lu channels available", (long)index, (unsigned long)channels.count);
    
    if (index < 0 || index >= channels.count) {
        NSLog(@"❌ Invalid channel index: %ld (available: %lu)", (long)index, (unsigned long)channels.count);
        return;
    }
    
    id channel = channels[index];
    NSString *channelUrl = nil;
    NSString *channelName = @"Unknown Channel";
    VLCChannel *vlcChannelObj = nil;
    
    if ([channel isKindOfClass:[VLCChannel class]]) {
        vlcChannelObj = (VLCChannel *)channel;
        channelUrl = vlcChannelObj.url;
        channelName = vlcChannelObj.name;
        NSLog(@"📺 Playing VLCChannel: %@ (URL: %@)", channelName, channelUrl);
    } else if ([channel isKindOfClass:[NSString class]]) {
        // If it's a simple string, check if we have URLs array
        channelName = (NSString *)channel;
        if (index < _simpleChannelUrls.count) {
            channelUrl = _simpleChannelUrls[index];
            NSLog(@"📺 Playing simple channel: %@ (URL: %@)", channelName, channelUrl);
        } else {
            NSLog(@"❌ No URL available for simple channel: %@", channelName);
        }
    } else {
        NSLog(@"❌ Unknown channel type: %@", NSStringFromClass([channel class]));
    }
    
    if (channelUrl && [channelUrl length] > 0 && self.player) {
        // Save last played content info BEFORE starting playback
        if (vlcChannelObj) {
            [self saveLastPlayedChannelUrl:channelUrl];
            [self saveLastPlayedContentInfo:vlcChannelObj];
        } else {
            // Create minimal channel object for saving
            VLCChannel *tempChannel = [[VLCChannel alloc] init];
            tempChannel.name = channelName;
            tempChannel.url = channelUrl;
            tempChannel.group = @"Unknown";
            tempChannel.category = @"TV";
            [self saveLastPlayedChannelUrl:channelUrl];
            [self saveLastPlayedContentInfo:tempChannel];
            [tempChannel release];
        }
        
        NSURL *url = [NSURL URLWithString:channelUrl];
        if (url) {
            VLCMedia *media = [VLCMedia mediaWithURL:url];
            [self.player setMedia:media];
            [self.player play];
            
            // Auto-show player controls when playback starts
            [self showPlayerControls];
            
            NSLog(@"✅ Started playback for: %@ (%@)", channelName, channelUrl);
        } else {
            NSLog(@"❌ Invalid URL format: %@", channelUrl);
        }
    } else {
        if (!channelUrl) {
            NSLog(@"❌ No URL available for channel: %@", channelName);
        } else if (!self.player) {
            NSLog(@"❌ No VLC player available");
        }
    }
}

// Play a channel directly from VLCChannel object (compatibility with Mac version)
- (void)playChannel:(VLCChannel *)channel {
    if (!channel) {
        NSLog(@"❌ [PLAYBACK] No channel provided");
        return;
    }
    
    NSLog(@"📺 [PLAYBACK] Playing channel: %@ (URL: %@)", channel.name, channel.url);
    
    // Save last played content info BEFORE starting playback
    [self saveLastPlayedChannelUrl:channel.url];
    [self saveLastPlayedContentInfo:channel];
    
    // Start playback using the URL method
    [self playChannelWithUrl:channel.url];
}

// Play a channel directly from URL (for timeshift/catchup)
- (void)playChannelWithUrl:(NSString *)urlString {
    if (!urlString || [urlString length] == 0) {
        NSLog(@"❌ [PLAYBACK] Invalid URL provided");
        return;
    }
    
    if (!self.player) {
        NSLog(@"❌ [PLAYBACK] No VLC player available");
        return;
    }
    
    NSLog(@"📺 [PLAYBACK] Starting playback with URL: %@", urlString);
    
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSLog(@"❌ [PLAYBACK] Invalid URL format: %@", urlString);
        return;
    }
    
    VLCMedia *media = [VLCMedia mediaWithURL:url];
    [self.player setMedia:media];
    [self.player play];
    
    // Auto-show player controls when playback starts
    [self showPlayerControls];
    
    // Schedule background alignment after a brief delay to allow playback to stabilize
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self performBackgroundAlignment];
    });
    
    NSLog(@"✅ [PLAYBACK] Started playback for URL: %@", urlString);
}

#pragma mark - Data Structure Management (Shared with macOS)

- (void)ensureDataStructuresInitialized {
    NSLog(@"📺 iOS ensureDataStructuresInitialized - now handled by VLCDataManager");
    // VLCDataManager now handles all data structure initialization universally
    return;
    
    /* OLD IMPLEMENTATION - NOW HANDLED BY VLCDataManager
    //NSLog(@"🔧 Safe data structure initialization for iOS");
    
    // Initialize all data structures if not already done
    if (!_channels) {
        _channels = [[NSMutableArray alloc] init];
       // NSLog(@"🔧 Initialized _channels array");
    }
    
    if (!_groups) {
        _groups = [[NSMutableArray alloc] init];
        //NSLog(@"🔧 Initialized _groups array");
    }
    
    if (!_channelsByGroup) {
        _channelsByGroup = [[NSMutableDictionary alloc] init];
        //NSLog(@"🔧 Initialized _channelsByGroup dictionary");
    }
    
    if (!_groupsByCategory) {
        _groupsByCategory = [[NSMutableDictionary alloc] init];
        //NSLog(@"🔧 Initialized _groupsByCategory dictionary");
        
        // Add the real macOS settings groups
        NSMutableArray *settingsGroups = [NSMutableArray arrayWithObjects:
            @"General", @"Playlist", @"Subtitles", @"Movie Info", @"Themes", nil];
        [_groupsByCategory setObject:settingsGroups forKey:@"SETTINGS"];
        
        // Set other categories with empty arrays
        for (NSString *category in @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES"]) {
            [_groupsByCategory setObject:[NSMutableArray array] forKey:category];
        }
    }
    
    if (!_categories) {
        _categories = [@[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"] retain];
        //NSLog(@"🔧 Initialized _categories array");
    }
    
    // Initialize EPG data dictionary - CRITICAL FIX for cache loading
    if (!self.epgData) {
        self.epgData = [NSMutableDictionary dictionary];
        NSLog(@"🔧 ✅ Initialized self.epgData dictionary - required for EPG cache loading");
    }
    
    //NSLog(@"🔧 All data structures initialized successfully");
    */
}

#pragma mark - Layout

- (void)layoutSubviews {
    // Prevent infinite layout loops that cause memory crashes
    if (_isInLayoutUpdate) {
        return;
    }
    _isInLayoutUpdate = YES;
    
    [super layoutSubviews];
    
    CGFloat screenWidth = self.bounds.size.width;
    CGFloat screenHeight = self.bounds.size.height;
    
    NSLog(@"📱 layoutSubviews called - updating landscape-optimized layout for bounds: %@ (width: %.0f)", 
          NSStringFromCGRect(self.bounds), screenWidth);
    
    // Invalidate font caches when layout changes to prevent memory leaks
    [self invalidateFontCaches];
    
    // Update scroll view frame if it exists using responsive dimensions
    if (_settingsScrollViewiOS) {
        CGFloat catWidth = [self categoryWidth];
        CGFloat groupWidth = [self groupWidth];
        CGFloat settingsPanelX = catWidth + groupWidth;
        CGFloat settingsPanelWidth = self.bounds.size.width - settingsPanelX;
        
        CGRect newFrame = CGRectMake(settingsPanelX, 0, settingsPanelWidth, self.bounds.size.height);
        if (!CGRectEqualToRect(_settingsScrollViewiOS.frame, newFrame)) {
            _settingsScrollViewiOS.frame = newFrame;
            NSLog(@"📱 Updated settings scroll view frame: %@", NSStringFromCGRect(newFrame));
        }
    }
    
    // Update loading panel position if it exists
    if (_loadingPaneliOS) {
        CGFloat panelWidth = 300;
        CGFloat panelHeight = 120;
        CGFloat padding = 20;
        CGFloat panelX = self.bounds.size.width - panelWidth - padding;
        CGFloat panelY = self.bounds.size.height - panelHeight - padding;
        
        CGRect newLoadingFrame = CGRectMake(panelX, panelY, panelWidth, panelHeight);
        if (!CGRectEqualToRect(_loadingPaneliOS.frame, newLoadingFrame)) {
            _loadingPaneliOS.frame = newLoadingFrame;
            NSLog(@"📱 Updated loading panel frame: %@", NSStringFromCGRect(newLoadingFrame));
        }
    }
    
    // Trigger a redraw since our responsive calculations depend on bounds
    [self setNeedsDisplay];
    
    _isInLayoutUpdate = NO;
}

#pragma mark - iOS-Specific Method Implementations

// iOS implementations - load settings from NSUserDefaults
- (void)loadSettings {
    NSLog(@"📋 iOS loadSettings - loading from NSUserDefaults");
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Load M3U file path
    NSString *savedM3uPath = [defaults stringForKey:@"m3uFilePath"];
    if (savedM3uPath && [savedM3uPath length] > 0) {
        self.m3uFilePath = savedM3uPath;
        NSLog(@"📂 Loaded M3U path: %@", self.m3uFilePath);
    } else {
        NSLog(@"📂 No saved M3U path found");
    }
    
    // Load EPG URL
    NSString *savedEpgUrl = [defaults stringForKey:@"epgUrl"];
    if (savedEpgUrl && [savedEpgUrl length] > 0) {
        self.epgUrl = savedEpgUrl;
        NSLog(@"📅 Loaded EPG URL: %@", self.epgUrl);
    } else {
        NSLog(@"📅 No saved EPG URL found");
    }
    
    // Load EPG time offset
    if ([defaults objectForKey:@"epgTimeOffsetHours"]) {
        self.epgTimeOffsetHours = [defaults floatForKey:@"epgTimeOffsetHours"];
        NSLog(@"⏰ Loaded EPG time offset: %.1f hours", self.epgTimeOffsetHours);
    } else {
        // Set default offset and save it
        self.epgTimeOffsetHours = 0.0;
        NSLog(@"⏰ No saved EPG time offset found, setting default: 0.0 hours");
    }
    
    // Load favorites data from Application Support (iOS should use the same system as Mac)
    [self loadFavoritesFromSettings];
    
    NSLog(@"📋 Settings loading completed");
}

- (void)loadFavoritesFromSettings {
    //NSLog(@"⭐ iOS loadFavoritesFromSettings - loading favorites from Application Support");
    
    // Use the same Application Support file system as Mac for consistency
    NSString *settingsPath = [self settingsFilePath];
    //NSLog(@"⭐ [DEBUG] Settings file path: %@", settingsPath);
    
    // Check if file exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL fileExists = [fileManager fileExistsAtPath:settingsPath];
    //NSLog(@"⭐ [DEBUG] Settings file exists: %@", fileExists ? @"YES" : @"NO");
    
    if (fileExists) {
        NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:settingsPath error:nil];
        NSNumber *fileSize = [fileAttributes objectForKey:NSFileSize];
        //NSLog(@"⭐ [DEBUG] Settings file size: %@ bytes", fileSize);
    }
    
    NSDictionary *settingsDict = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
    
    if (!settingsDict) {
        //NSLog(@"⭐ No settings file found or failed to load, no favorites to load");
        return;
    }
    
    //NSLog(@"⭐ [DEBUG] Settings file loaded successfully, keys: %@", [settingsDict allKeys]);
    
    // Load favorites data
    NSDictionary *favoritesData = [settingsDict objectForKey:@"FavoritesData"];
    if (!favoritesData) {
        //NSLog(@"⭐ No favorites data found in settings file");
        return;
    }
    
    //NSLog(@"⭐ Found favorites data, keys: %@", [favoritesData allKeys]);
    
    // CRITICAL: Ensure data structures are initialized before loading favorites
    if (!_channelsByGroup) {
        _channelsByGroup = [NSMutableDictionary dictionary];
        //NSLog(@"⭐ [INIT] Created _channelsByGroup dictionary");
    }
    
    // Ensure favorites category exists
    [self ensureFavoritesCategory];
    
    //NSLog(@"⭐ [DEBUG] Data structures after ensureFavoritesCategory - groupsByCategory: %@, channelsByGroup: %@", 
    //      _groupsByCategory ? @"EXISTS" : @"NIL", _channelsByGroup ? @"EXISTS" : @"NIL");
    
    // Restore favorite groups
    NSArray *favoriteGroups = [favoritesData objectForKey:@"groups"];
    //NSLog(@"⭐ [DEBUG] Favorite groups from file: %@", favoriteGroups);
    
    if (favoriteGroups && [favoriteGroups isKindOfClass:[NSArray class]]) {
        NSMutableArray *favoritesArray = [_groupsByCategory objectForKey:@"FAVORITES"];
        //NSLog(@"⭐ [DEBUG] Current FAVORITES array: %@", favoritesArray);
        
        if (!favoritesArray) {
            favoritesArray = [NSMutableArray array];
            [_groupsByCategory setObject:favoritesArray forKey:@"FAVORITES"];
            //NSLog(@"⭐ [DEBUG] Created new FAVORITES array");
        }
        
        // Add favorite groups
        for (NSString *group in favoriteGroups) {
            if (![favoritesArray containsObject:group]) {
                [favoritesArray addObject:group];
                //NSLog(@"⭐ [DEBUG] Added group to FAVORITES: %@", group);
                // Initialize empty array for this group if it doesn't exist
                if (![_channelsByGroup objectForKey:group]) {
                    [_channelsByGroup setObject:[NSMutableArray array] forKey:group];
                    //NSLog(@"⭐ [DEBUG] Created empty channel array for group: %@", group);
                }
            } else {
                //NSLog(@"⭐ [DEBUG] Group already exists in FAVORITES: %@", group);
            }
        }
        
        //NSLog(@"⭐ Loaded %lu favorite groups", (unsigned long)favoriteGroups.count);
    } else {
        //NSLog(@"⭐ [DEBUG] No valid favorite groups found");
    }
    
    // Restore favorite channels
    NSArray *favoriteChannels = [favoritesData objectForKey:@"channels"];
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
            // CRITICAL: Restore original category (MOVIES, SERIES, TV) to maintain display format
            channel.category = [channelDict objectForKey:@"category"] ?: @"TV";
            channel.programs = [NSMutableArray array];
            
            // CRITICAL: Restore timeshift/catchup properties to preserve timeshift icons and functionality
            channel.supportsCatchup = [[channelDict objectForKey:@"supportsCatchup"] boolValue];
            channel.catchupDays = [[channelDict objectForKey:@"catchupDays"] integerValue];
            channel.catchupSource = [channelDict objectForKey:@"catchupSource"];
            channel.catchupTemplate = [channelDict objectForKey:@"catchupTemplate"];
            
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
        
        NSLog(@"⭐ Loaded %lu favorite channels from settings", (unsigned long)favoriteChannels.count);
        
        // DIAGNOSTIC: Count and log timeshift-enabled favorites
        NSInteger timeshiftFavorites = 0;
        for (NSString *group in favoriteGroups) {
            NSArray *groupChannels = [_channelsByGroup objectForKey:group];
            for (VLCChannel *channel in groupChannels) {
                if (channel.supportsCatchup || channel.catchupDays > 0) {
                    timeshiftFavorites++;
                }
            }
        }
        NSLog(@"⭐ [TIMESHIFT-CHECK] %ld favorite channels have timeshift support", (long)timeshiftFavorites);
    }
    
    //NSLog(@"⭐ Favorites loading completed successfully");
    
    // DIAGNOSTIC: Check final data structure state
    NSArray *allCategories = [_groupsByCategory allKeys];
    NSArray *favoritesGroups = [_groupsByCategory objectForKey:@"FAVORITES"];
    //NSLog(@"⭐ [FINAL-CHECK] Available categories: %@", allCategories);
    //NSLog(@"⭐ [FINAL-CHECK] FAVORITES groups count: %lu", (unsigned long)(favoritesGroups ? favoritesGroups.count : 0));
    
    // CRITICAL: Check if we have channel data loaded yet
    //NSLog(@"⭐ [DATA-CHECK] _channels count: %lu", (unsigned long)(_channels ? _channels.count : 0));
    //NSLog(@"⭐ [DATA-CHECK] _groups count: %lu", (unsigned long)(_groups ? _groups.count : 0));
    
    // Check sample channel in favorites
    if (favoritesGroups && favoritesGroups.count > 0) {
        NSString *firstGroup = [favoritesGroups objectAtIndex:0];
        NSArray *groupChannels = [_channelsByGroup objectForKey:firstGroup];
        //NSLog(@"⭐ [CHANNEL-CHECK] Channels in '%@': %lu", firstGroup, (unsigned long)(groupChannels ? groupChannels.count : 0));
        if (groupChannels && groupChannels.count > 0) {
            VLCChannel *firstChannel = [groupChannels objectAtIndex:0];
            //NSLog(@"⭐ [CHANNEL-CHECK] First channel: %@ (class: %@)", firstChannel.name, [firstChannel class]);
        }
    }
    
    // CRITICAL: Refresh the UI to show loaded favorites
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay];
        //NSLog(@"⭐ [UI-REFRESH] Triggered UI refresh after favorites loading");
    });
}

- (void)loadThemeSettings {
    //NSLog(@"🎨 iOS loadThemeSettings - loading theme from NSUserDefaults");
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Load custom selection colors
    if ([defaults objectForKey:@"customSelectionRed"]) {
        self.customSelectionRed = [defaults floatForKey:@"customSelectionRed"];
        self.customSelectionGreen = [defaults floatForKey:@"customSelectionGreen"];
        self.customSelectionBlue = [defaults floatForKey:@"customSelectionBlue"];
        
        // Update hover color based on custom selection
        _hoverColor = [UIColor colorWithRed:self.customSelectionRed 
                                      green:self.customSelectionGreen 
                                       blue:self.customSelectionBlue 
                                      alpha:0.6];
        
        NSLog(@"🎨 Loaded custom selection color: R=%.2f G=%.2f B=%.2f", 
              self.customSelectionRed, self.customSelectionGreen, self.customSelectionBlue);
    }
    
    NSLog(@"🎨 Theme settings loading completed");
}

- (void)loadViewModePreference {
    NSLog(@"👁 iOS loadViewModePreference - loading view mode from NSUserDefaults");
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Load view mode preference
    if ([defaults objectForKey:@"currentViewMode"]) {
        _currentViewMode = [defaults integerForKey:@"currentViewMode"];
        _isGridViewActive = (_currentViewMode == VIEW_MODE_GRID);
        _isStackedViewActive = (_currentViewMode == VIEW_MODE_STACKED);
        
        NSLog(@"👁 Loaded view mode: %ld", (long)_currentViewMode);
    }
    
    NSLog(@"👁 View mode preference loading completed");
}

- (BOOL)loadChannelsFromCache:(NSString *)sourcePath {
    NSLog(@"📺 iOS loadChannelsFromCache for: %@ - delegating to universal VLCDataManager", sourcePath);
    
    // UNIVERSAL APPROACH: Delegate entirely to VLCDataManager instead of duplicating logic
    VLCDataManager *dataManager = [VLCDataManager sharedManager];
    if (!dataManager.delegate) {
        dataManager.delegate = self;
    }
    
    // Use the universal channel loading method which handles caching internally
    [dataManager loadChannelsFromURL:sourcePath];
    
    return YES; // Loading initiated via universal manager
}

    
    /* OLD IMPLEMENTATION - NOW HANDLED BY VLCDataManager
    [self logMemoryUsage:@"start of loadChannelsFromCache"];
    
    NSString *cachePath = [self channelCacheFilePath:sourcePath];
    
    // Check if the cache file exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cachePath]) {
        NSLog(@"Cache file does not exist: %@", cachePath);
        return NO;
    }
    
    // CRITICAL: Check cache file size before attempting to load
    NSError *fileError = nil;
    NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:cachePath error:&fileError];
    if (fileAttributes) {
        NSNumber *fileSize = [fileAttributes objectForKey:NSFileSize];
        NSUInteger fileSizeMB = [fileSize unsignedIntegerValue] / (1024 * 1024);
        
        NSLog(@"📁 Cache file size: %luMB", (unsigned long)fileSizeMB);
        
        // Load full cache regardless of size
        NSLog(@"📺 Cache file size: %luMB - loading FULL channel list", (unsigned long)fileSizeMB);
    }
    
    // Load from the cache file
    NSDictionary *cacheDict = [NSDictionary dictionaryWithContentsOfFile:cachePath];
    if (!cacheDict) {
        NSLog(@"Failed to load channels cache from %@", cachePath);
        return NO;
    }
    
    // Check cache version
    NSString *cacheVersion = [cacheDict objectForKey:@"cacheVersion"];
    if (!cacheVersion || (![cacheVersion isEqualToString:@"1.0"] && ![cacheVersion isEqualToString:@"1.1"])) {
        NSLog(@"Unsupported cache version: %@", cacheVersion);
        return NO;
    }
    
    // Check timestamp (1 week max)
    NSDate *cacheDate = [cacheDict objectForKey:@"cacheDate"];
    if (cacheDate) {
        NSTimeInterval cacheAge = [[NSDate date] timeIntervalSinceDate:cacheDate];
        NSTimeInterval oneWeek = 7 * 24 * 60 * 60; // 7 days in seconds
        
        if (cacheAge > oneWeek) {
            NSLog(@"Cache is too old (%.1f days), will refresh", cacheAge / (24 * 60 * 60));
            return NO;
        }
    }
    
    // Load cached data
    NSArray *serializedChannels = [cacheDict objectForKey:@"channels"];
    NSArray *groups = [cacheDict objectForKey:@"groups"];
    NSDictionary *serializedChannelsByGroup = [cacheDict objectForKey:@"channelsByGroup"];
    NSDictionary *groupsByCategory = [cacheDict objectForKey:@"groupsByCategory"];
    
    if (!serializedChannels || !groups) {
        NSLog(@"Invalid cache data structure");
        return NO;
    }
    
    // Initialize data structures - handled by VLCDataManager automatically
    
    // Update progress
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setLoadingStatusText:@"Loading channels from cache..."];
        self.loadingProgress = 0.0;
    });
    
    // Deserialize channels - NO LIMITS, load full channel list with memory optimization
    NSUInteger totalChannels = [serializedChannels count];
    NSMutableArray *channels = [[NSMutableArray alloc] initWithCapacity:totalChannels];
    
    NSLog(@"📺 Loading FULL channel list from cache: %lu channels", (unsigned long)totalChannels);
    
    for (NSUInteger i = 0; i < totalChannels; i++) {
        @autoreleasepool { // Wrap each channel creation in autorelease pool
        if (i % 500 == 0) { // Check more frequently for memory issues
            float progress = (float)i / (float)totalChannels;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.loadingProgress = progress;
                [self setLoadingStatusText:[NSString stringWithFormat:@"Loading channel %lu of %lu from cache...", 
                                          (unsigned long)(i + 1), (unsigned long)totalChannels]];
            });
            
            // Memory monitoring (informational only - no limits)
            if (i > 1000 && i % 1000 == 0) {
                NSUInteger currentMemoryMB = [self getCurrentMemoryUsageMB];
                NSLog(@"📊 Memory usage: %luMB at channel %lu of %lu", 
                      (unsigned long)currentMemoryMB, (unsigned long)i, (unsigned long)totalChannels);
            }
        }
        
        NSDictionary *channelDict = [serializedChannels objectAtIndex:i];
        if (![channelDict isKindOfClass:[NSDictionary class]]) continue;
        
        VLCChannel *channel = [[VLCChannel alloc] init];
        channel.name = [channelDict objectForKey:@"name"];
        channel.url = [channelDict objectForKey:@"url"];
        channel.group = [channelDict objectForKey:@"group"];
        channel.logo = [channelDict objectForKey:@"logo"];
        channel.channelId = [channelDict objectForKey:@"channelId"];
        channel.category = [channelDict objectForKey:@"category"];
        channel.programs = [[NSMutableArray alloc] init];
        
        // Load catch-up properties
        channel.supportsCatchup = [[channelDict objectForKey:@"supportsCatchup"] boolValue];
        channel.catchupDays = [[channelDict objectForKey:@"catchupDays"] integerValue];
        channel.catchupSource = [channelDict objectForKey:@"catchupSource"];
        channel.catchupTemplate = [channelDict objectForKey:@"catchupTemplate"];
        
        [channels addObject:channel];
        } // End autorelease pool
    }
    
    // Set the loaded data using underlying instance variables (properties are readonly)
    _channels = channels;
    _groups = [groups mutableCopy];
    _groupsByCategory = [groupsByCategory mutableCopy];
    
    // Rebuild channelsByGroup from indices
    NSMutableDictionary *channelsByGroup = [[NSMutableDictionary alloc] init];
    for (NSString *group in [serializedChannelsByGroup allKeys]) {
        NSArray *indices = [serializedChannelsByGroup objectForKey:group];
        NSMutableArray *groupChannels = [[NSMutableArray alloc] init];
        
        for (NSNumber *indexNum in indices) {
            NSUInteger index = [indexNum unsignedIntegerValue];
            if (index < [channels count]) {
                [groupChannels addObject:[channels objectAtIndex:index]];
            }
        }
        
        [channelsByGroup setObject:groupChannels forKey:group];
    }
    _channelsByGroup = channelsByGroup;
    
    // Update UI
    dispatch_async(dispatch_get_main_queue(), ^{
        self.loadingProgress = 1.0;
        [self setLoadingStatusText:[NSString stringWithFormat:@"Loaded %lu channels from cache", 
                                  (unsigned long)totalChannels]];
        
        // Auto-start EPG loading if we have EPG URL
        if (self.epgUrl && [self.epgUrl length] > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), 
                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[VLCDataManager sharedManager] loadEPGFromURL:self.epgUrl];
            });
        }
        
        // Clear loading state after a brief delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.isLoading = NO;
            [self setNeedsDisplay];
        });
    });
    
    NSLog(@"Successfully loaded %lu channels from cache", (unsigned long)totalChannels);
    
    // Count and log timeshift channels loaded from cache
    NSInteger timeshiftChannelCount = 0;
    for (VLCChannel *channel in channels) {
        if (channel.supportsCatchup || channel.catchupDays > 0) {
            timeshiftChannelCount++;
        }
    }
    NSLog(@"🔧 [TIMESHIFT-CACHE] Found %ld channels with timeshift support from cache", (long)timeshiftChannelCount);
    [self logMemoryUsage:@"end of loadChannelsFromCache"];
    return YES;
    */
//}

// Cache cleanup utilities for memory management
- (void)clearOversizedCache {
    NSLog(@"🧹 Clearing oversized cache files...");
    
    NSString *cachePath = [self channelCacheFilePath:self.m3uFilePath];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    if ([fileManager fileExistsAtPath:cachePath]) {
        NSError *error = nil;
        if ([fileManager removeItemAtPath:cachePath error:&error]) {
            NSLog(@"✅ Oversized cache cleared successfully");
        } else {
            NSLog(@"❌ Failed to clear cache: %@", error.localizedDescription);
        }
    }
}

- (BOOL)isCacheOversized:(NSString *)sourcePath {
    // Always allow cache loading - no size restrictions
    NSLog(@"📱 [MEMORY] Cache loading allowed - no size restrictions");
    return NO;
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

// Method removed - now handled by VLCCacheManager

- (NSString *)md5HashForString:(NSString *)string {
    const char *cStr = [string UTF8String];
    unsigned char result[16];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), result);
    
    NSMutableString *hash = [NSMutableString string];
    for (int i = 0; i < 16; i++) {
        [hash appendFormat:@"%02x", result[i]];
    }
    
    return hash;
}

// ❌ LEGACY METHOD REMOVED: applicationSupportDirectory - now handled by VLCCacheManager



// ❌ LEGACY METHOD REMOVED: settingsFilePath - now handled by VLCCacheManager

- (BOOL)shouldUpdateM3UAtStartup {
    NSLog(@"🔄 Universal shouldUpdateM3UAtStartup - using macOS implementation");
    // The macOS VLCOverlayView+Caching.m handles update logic
    return YES; // Will be implemented by macOS category method
}

- (BOOL)shouldUpdateEPGAtStartup {
    NSLog(@"🔄 iOS shouldUpdateEPGAtStartup - checking 6-hour rule");
    
    // Check if we have a valid EPG URL first
    if (!self.epgUrl || [self.epgUrl length] == 0) {
        NSLog(@"🔄 No EPG URL - no update needed");
        return NO;
    }
    
    // Load EPG download timestamp from NSUserDefaults (iOS style)
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *lastDownload = [defaults objectForKey:@"lastEPGDownloadDate"];
    
    if (!lastDownload) {
        // No previous download, should update
        NSLog(@"🔄 No previous EPG download date found - will update");
        return YES;
    }
    
    NSTimeInterval timeSinceDownload = [[NSDate date] timeIntervalSinceDate:lastDownload];
    NSTimeInterval sixHoursInSeconds = 6 * 60 * 60; // 6 hours
    
    BOOL shouldUpdate = timeSinceDownload > sixHoursInSeconds;
    NSLog(@"🔄 Last EPG download was %.1f hours ago - %@", 
          timeSinceDownload / 3600.0, 
          shouldUpdate ? @"will update" : @"using cache");
    
    return shouldUpdate;
}

// ❌ REMOVED: Old redundant EPG methods - now using VLCDataManager

- (void)startEarlyPlaybackIfAvailable {
    NSLog(@"▶️ iOS startEarlyPlaybackIfAvailable - implementing full auto-play functionality");
    
    // Get cached content info (like Mac version)
    NSDictionary *cachedInfo = [self getLastPlayedContentInfo];
    if (!cachedInfo) {
        NSLog(@"📱 [STARTUP] No cached content info available for early playback");
        return;
    }
    
    NSString *lastUrl = [cachedInfo objectForKey:@"url"];
    if (!lastUrl || [lastUrl length] == 0) {
        NSLog(@"📱 [STARTUP] No URL in cached content info");
        return;
    }
    
    NSString *channelName = [cachedInfo objectForKey:@"channelName"];
    NSLog(@"📱 [STARTUP] Found cached content: %@ with URL: %@", channelName, lastUrl);
    
    // STARTUP POLICY: Always switch to live content, never play timeshift
    NSString *playbackUrl = lastUrl;
    NSString *originalChannelName = channelName;
    BOOL isTimeshiftUrl = ([lastUrl rangeOfString:@"timeshift.php"].location != NSNotFound ||
                          [lastUrl rangeOfString:@"timeshift"].location != NSNotFound);
    
    if (isTimeshiftUrl) {
        NSLog(@"📱 [STARTUP] Detected timeshift URL, finding live channel");
        
        // Extract the original channel name from timeshift channel name
        if (channelName && [channelName containsString:@" (Timeshift:"]) {
            NSRange timeshiftRange = [channelName rangeOfString:@" (Timeshift:"];
            if (timeshiftRange.location != NSNotFound) {
                originalChannelName = [channelName substringToIndex:timeshiftRange.location];
                NSLog(@"📱 [STARTUP] Extracted original channel name: %@", originalChannelName);
            }
        }
        
        // Search for the original live channel
        VLCChannel *originalChannel = nil;
        if (_channels && _channels.count > 0) {
            for (VLCChannel *channel in _channels) {
                if ([channel.name isEqualToString:originalChannelName]) {
                    originalChannel = channel;
                    NSLog(@"📱 [STARTUP] Found original live channel: %@", channel.name);
                    break;
                }
            }
        }
        
        if (originalChannel && originalChannel.url) {
            playbackUrl = originalChannel.url;
            NSLog(@"📱 [STARTUP] Using original channel live URL: %@", playbackUrl);
        } else {
            NSLog(@"📱 [STARTUP] Could not find original channel, skipping startup playback");
            return;
        }
    }
    
    // Find the channel and set proper selection indices
    BOOL channelFound = NO;
    VLCChannel *targetChannel = nil;
    
    if (_channels && _channels.count > 0) {
        for (VLCChannel *channel in _channels) {
            if ([channel.url isEqualToString:playbackUrl] || 
                [channel.name isEqualToString:originalChannelName]) {
                targetChannel = channel;
                channelFound = YES;
                NSLog(@"📱 [STARTUP] Found target channel: %@", channel.name);
                break;
            }
        }
    }
    
    if (channelFound && targetChannel) {
        // Find the channel in the organized structure and set selection indices
        BOOL selectionSet = NO;
        
        // Search through categories and groups to find this channel
        NSArray *categories = @[@"FAVORITES", @"TV", @"MOVIES", @"SERIES"];
        
        for (NSInteger catIndex = 0; catIndex < categories.count; catIndex++) {
            NSString *category = categories[catIndex];
            NSArray *groups = nil;
            
            if ([category isEqualToString:@"FAVORITES"]) {
                groups = [_groupsByCategory objectForKey:@"FAVORITES"];
            } else if ([category isEqualToString:@"TV"]) {
                groups = [_groupsByCategory objectForKey:@"TV"];
            } else if ([category isEqualToString:@"MOVIES"]) {
                groups = [_groupsByCategory objectForKey:@"MOVIES"];
            } else if ([category isEqualToString:@"SERIES"]) {
                groups = [_groupsByCategory objectForKey:@"SERIES"];
            }
            
            if (groups) {
                for (NSInteger groupIndex = 0; groupIndex < groups.count; groupIndex++) {
                    NSString *group = groups[groupIndex];
                    NSArray *channelsInGroup = [_channelsByGroup objectForKey:group];
                    
                    if (channelsInGroup) {
                        for (NSInteger channelIndex = 0; channelIndex < channelsInGroup.count; channelIndex++) {
                            VLCChannel *channel = channelsInGroup[channelIndex];
                            if (channel == targetChannel) {
                                // Found it! Set the selection indices
                                _selectedCategoryIndex = catIndex;
                                _selectedGroupIndex = groupIndex;
                                _selectedChannelIndex = channelIndex;
                                
                                NSLog(@"📱 [STARTUP] Set selection indices - Category: %ld, Group: %ld, Channel: %ld", 
                                      (long)catIndex, (long)groupIndex, (long)channelIndex);
                                
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
            NSLog(@"📱 [STARTUP] Starting playback of channel: %@", targetChannel.name);
            
            // Start playback
            [self playChannel:targetChannel];
            
            // Show player controls after startup
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self->_isChannelListVisible) {
                    [self showPlayerControls];
                    NSLog(@"📱 [STARTUP] Showed player controls after startup");
                }
            });
        }
    }
}

- (void)loadChannelsFile {
    NSLog(@"📺 iOS loadChannelsFile - implementing iOS-specific startup progress");
    
    // Show startup progress window for iOS
    [self showStartupProgressWindow];
    [self updateStartupProgress:0.05 step:@"Initializing" details:@"Starting BasicIPTV..."];
    
    // The macOS VLCOverlayView+ChannelManagement.m handles the actual file loading
    // This ensures iOS gets the startup progress window
}

- (NSString *)localM3uFilePath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths firstObject];
    return [documentsDirectory stringByAppendingPathComponent:@"channels.m3u"];
}

#pragma mark - Method Stubs (iOS-specific implementations)

- (void)loadChannelsFromM3uFile:(NSString *)path {
    NSLog(@"🔧 loadChannelsFromM3uFile called on iOS - using iOS implementation");
    NSLog(@"🔧 Input path: %@", path);
    NSLog(@"🔧 Current downloading state: %s", _isDownloadingChannels ? "YES" : "NO");
    NSLog(@"🔧 Current loading state: %s", self.isLoading ? "YES" : "NO");
    
    // Prevent multiple simultaneous loads
    if (_isDownloadingChannels || self.isLoading) {
        NSLog(@"⚠️ Channel loading already in progress - ignoring duplicate request");
        return;
    }
    
    if (!path || [path length] == 0) {
        NSLog(@"❌ No M3U file path specified");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearLoadingState];
            [self setLoadingStatusText:@"Error: No file path specified"];
        });
        return;
    }
    
    // Cancel any existing downloads first
    [self cancelAllDownloads];
    
    // Check if path is URL or local file
    BOOL isUrl = [path hasPrefix:@"http://"] || [path hasPrefix:@"https://"];
    NSLog(@"🔧 Is URL: %s", isUrl ? "YES" : "NO");
    
    if (isUrl) {
        NSLog(@"🔧 Detected URL - calling loadChannelsFromUrl (which will set its own loading state)");
        NSLog(@"🔧 States just before calling loadChannelsFromUrl: downloading=%d, isLoading=%d", _isDownloadingChannels, self.isLoading);
        // For URLs, call our iOS URL loading method (don't set loading state here - let loadChannelsFromUrl do it)
        [self loadChannelsFromUrl:path];
        NSLog(@"🔧 States just after calling loadChannelsFromUrl: downloading=%d, isLoading=%d", _isDownloadingChannels, self.isLoading);
    } else {
        NSLog(@"🔧 Detected local file - processing locally");
        
        // Show startup progress window if not already shown
        if (!self.isStartupInProgress) {
            [self showStartupProgressWindow];
            [self updateStartupProgress:0.05 step:@"Initializing" details:@"Starting BasicIPTV..."];
        }
        
        // For local files, set loading state here since we handle it directly
        _isDownloadingChannels = YES;
        self.isLoading = YES;
        // For local files, implement basic file loading
        self.loadingProgress = 0.1f;
        [self setLoadingStatusText:@"Reading local M3U file..."];
        [self updateStartupProgress:0.20 step:@"Loading Local File" details:@"Reading local M3U file..."];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Simulate local file processing
            for (int i = 1; i <= 5; i++) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    float progress = 0.1f + (i / 5.0f) * 0.9f;
                    self.loadingProgress = progress;
                    [self setLoadingStatusText:[NSString stringWithFormat:@"Processing local file: %d%%", (int)(progress * 100)]];
                    
                    // Update startup progress
                    float startupProgress = 0.20 + (progress * 0.3); // 20% to 50% for file processing
                    [self updateStartupProgress:startupProgress 
                                            step:@"Processing File" 
                                         details:[NSString stringWithFormat:@"Processing local file: %d%%", (int)(progress * 100)]];
                    
                    if (progress >= 1.0f) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [self clearLoadingState];
                            [self setLoadingStatusText:@"Local file loaded successfully"];
                            
                            // Complete startup progress
                            [self updateStartupProgress:1.0 step:@"Complete" details:@"BasicIPTV ready to use"];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                [self hideStartupProgressWindow];
                            });
                            
                            NSLog(@"✅ Local file loading completed: %@", path);
                        });
                    }
                });
                usleep(200000); // 200ms between updates
            }
        });
    }
}

- (void)saveCurrentPlaybackPosition {
    NSLog(@"🔧 saveCurrentPlaybackPosition called on iOS (stub implementation)");
    // TODO: Implement playback position saving for iOS
    // For now, this is a stub to satisfy the compiler
}

- (NSString *)getLastPlayedChannelUrl {
    NSLog(@"🔧 iOS getLastPlayedChannelUrl - retrieving from NSUserDefaults");
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *url = [defaults objectForKey:@"LastPlayedChannelURL"];
    NSLog(@"🔧 Retrieved last played URL: %@", url);
    return url;
}

- (void)saveLastPlayedChannelUrl:(NSString *)urlString {
    NSLog(@"💾 iOS saveLastPlayedChannelUrl: %@", urlString);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (urlString) {
        [defaults setObject:urlString forKey:@"LastPlayedChannelURL"];
    } else {
        [defaults removeObjectForKey:@"LastPlayedChannelURL"];
    }
    [defaults synchronize];
}

- (void)saveLastPlayedContentInfo:(VLCChannel *)channel {
    NSLog(@"💾 iOS saveLastPlayedContentInfo for channel: %@", channel.name);
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *contentInfo = [NSMutableDictionary dictionary];
    
    if (channel.name) {
        [contentInfo setObject:channel.name forKey:@"channelName"];
    }
    if (channel.url) {
        [contentInfo setObject:channel.url forKey:@"url"];
    }
    if (channel.logo) {
        [contentInfo setObject:channel.logo forKey:@"logo"];
    }
    if (channel.group) {
        [contentInfo setObject:channel.group forKey:@"group"];
    }
    if (channel.category) {
        [contentInfo setObject:channel.category forKey:@"category"];
    }
    if (channel.channelId) {
        [contentInfo setObject:channel.channelId forKey:@"channelId"];
    }
    
    // Save current program if available
    if (channel.programs && channel.programs.count > 0) {
        VLCProgram *currentProgram = [channel.programs firstObject];
        if (currentProgram.title) {
            [contentInfo setObject:currentProgram.title forKey:@"currentProgramTitle"];
        }
        if (currentProgram.description) {
            [contentInfo setObject:currentProgram.description forKey:@"currentProgramDescription"];
        }
        if (currentProgram.startTime) {
            [contentInfo setObject:currentProgram.startTime forKey:@"currentProgramStartTime"];
        }
        if (currentProgram.endTime) {
            [contentInfo setObject:currentProgram.endTime forKey:@"currentProgramEndTime"];
        }
    }
    
    // Add timestamp
    [contentInfo setObject:[NSDate date] forKey:@"lastPlayedTime"];
    
    [defaults setObject:contentInfo forKey:@"LastPlayedContentInfo"];
    [defaults synchronize];
    
    NSLog(@"💾 Saved content info with %lu keys", (unsigned long)contentInfo.count);
}

- (void)saveSettings {
    NSLog(@"💾 iOS saveSettings - saving to NSUserDefaults");
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    // Save M3U file path
    if (self.m3uFilePath) {
        [defaults setObject:self.m3uFilePath forKey:@"m3uFilePath"];
        NSLog(@"💾 Saved M3U path: %@", self.m3uFilePath);
    }
    
    // Save EPG URL
    if (self.epgUrl) {
        [defaults setObject:self.epgUrl forKey:@"epgUrl"];
        NSLog(@"💾 Saved EPG URL: %@", self.epgUrl);
    }
    
    // Save EPG time offset
    [defaults setFloat:self.epgTimeOffsetHours forKey:@"epgTimeOffsetHours"];
    NSLog(@"💾 Saved EPG time offset: %.1f hours", self.epgTimeOffsetHours);
    
    // Save custom selection colors
    [defaults setFloat:self.customSelectionRed forKey:@"customSelectionRed"];
    [defaults setFloat:self.customSelectionGreen forKey:@"customSelectionGreen"];
    [defaults setFloat:self.customSelectionBlue forKey:@"customSelectionBlue"];
    
    // Save view mode preference
    [defaults setInteger:_currentViewMode forKey:@"currentViewMode"];
    
    // Force synchronization
    [defaults synchronize];
    
    NSLog(@"💾 Settings saved successfully");
}

// Compatibility method for macOS setNeedsDisplay: - UIKit doesn't use the boolean parameter
- (void)setNeedsDisplay:(BOOL)flag {
    // On iOS/tvOS, just call setNeedsDisplay (UIKit ignores the boolean parameter)
    [self setNeedsDisplay];
}

#pragma mark - EPG Cache Methods (iOS/tvOS Implementation)

// ❌ LEGACY METHOD REMOVED: epgCacheFilePath - now handled by VLCCacheManager
// ❌ LEGACY METHOD REMOVED: loadEpgDataFromCache - now handled by VLCCacheManager

// ❌ LEGACY METHOD REMOVED: loadEpgDataFromCacheWithoutChecks - now handled by VLCCacheManager

// ❌ LEGACY METHOD REMOVED: loadEpgDataFromCacheWithoutAgeCheck - now handled by VLCCacheManager

// Method removed - now handled by VLCCacheManager

// Progress timer methods for EPG module compatibility
- (void)startProgressRedrawTimer {
    if (gProgressRedrawTimer) {
        [gProgressRedrawTimer invalidate];
        gProgressRedrawTimer = nil;
    }
    
    gProgressRedrawTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                           target:self
                                                         selector:@selector(progressRedrawTimerFired:)
                                                         userInfo:nil
                                                          repeats:YES];
}

- (void)stopProgressRedrawTimer {
    if (gProgressRedrawTimer) {
        [gProgressRedrawTimer invalidate];
        gProgressRedrawTimer = nil;
    }
}

- (void)progressRedrawTimerFired:(NSTimer *)timer {
    if (self.isLoading || self.isLoadingEpg) {
        [self setNeedsDisplay];
    } else {
        [self stopProgressRedrawTimer];
    }
}

- (void)clearCacheButtonTapped:(UIButton *)button {
    NSLog(@"🔧 Clear Cache button tapped");
    
    // Call the macOS-compatible cache clearing methods
    if ([self respondsToSelector:@selector(clearCachedTimeshiftChannel)]) {
        [self clearCachedTimeshiftChannel];
    }
    if ([self respondsToSelector:@selector(clearCachedTimeshiftProgramInfo)]) {
        [self clearCachedTimeshiftProgramInfo];
    }
    
    [self showBriefMessage:@"Cache cleared" at:button.center];
}

- (void)reloadChannelsButtonTapped:(UIButton *)button {
    NSLog(@"🔧 Reload Channels button tapped");
    NSLog(@"🔧 Current M3U file path: %@", self.m3uFilePath);
    NSLog(@"🔧 M3U file path length: %lu", (unsigned long)[self.m3uFilePath length]);
    
    if (self.m3uFilePath && [self.m3uFilePath length] > 0) {
        NSLog(@"✅ M3U URL is valid, starting channel loading...");
        [self showBriefMessage:@"Reloading channels..." at:button.center];
        [self showLoadingPanel];
        [self loadChannelsFromM3uFile:self.m3uFilePath];
    } else {
        NSLog(@"❌ No M3U URL set - showing error message");
        [self showBriefMessage:@"Set M3U URL first" at:button.center];
    }
}

#pragma mark - Property Setters (iOS Progress Integration)

- (void)setLoadingProgress:(float)loadingProgress {
    _loadingProgress = loadingProgress;
    
    // Update startup progress if active, otherwise use old progress bars
    if (self.isStartupInProgress) {
        // Convert 0-1 range to 0-50% range for channels (startup goes 0-50% for channels, 50-90% for EPG)
        float startupProgress = 0.05 + (loadingProgress * 0.45); // 5% to 50%
        NSString *status = self.loadingStatusText ?: @"Loading channels...";
        NSString *enhancedDetails = [self enhanceProgressDetails:status forType:@"channels"];
        [self updateStartupProgress:startupProgress step:@"Loading Channels" details:enhancedDetails];
    } else if (_m3uProgressBariOS && _m3uProgressLabeliOS) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *status = self.loadingStatusText ?: @"Loading...";
            [self updateLoadingProgress:loadingProgress status:status];
        });
    }
}

- (void)setEpgLoadingProgress:(float)epgLoadingProgress {
    _epgLoadingProgress = epgLoadingProgress;
    
    // Update startup progress if active, otherwise use old progress bars
    if (self.isStartupInProgress) {
        // Convert 0-1 range to 50-90% range for EPG (startup goes 0-50% for channels, 50-90% for EPG)
        float startupProgress = 0.5 + (epgLoadingProgress * 0.4); // 50% to 90%
        NSString *status = self.epgLoadingStatusText ?: @"Loading EPG...";
        NSString *enhancedDetails = [self enhanceProgressDetails:status forType:@"epg"];
        [self updateStartupProgress:startupProgress step:@"Loading EPG Data" details:enhancedDetails];
    } else if (_epgProgressBariOS && _epgProgressLabeliOS) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *status = self.epgLoadingStatusText ?: @"Loading EPG...";
            [self updateEPGLoadingProgress:epgLoadingProgress status:status];
        });
    }
}

- (void)setIsLoading:(BOOL)isLoading {
    _isLoading = isLoading;
    
    // Show/hide loading panel based on loading state - BUT only if startup progress is not active
    if (isLoading && !_loadingPaneliOS && !self.isStartupInProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLoadingPanel];
        });
    }
}

- (void)setIsLoadingEpg:(BOOL)isLoadingEpg {
    _isLoadingEpg = isLoadingEpg;
    
    // Show/hide loading panel based on EPG loading state - BUT only if startup progress is not active
    if (isLoadingEpg && !_loadingPaneliOS && !self.isStartupInProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showLoadingPanel];
        });
    }
}

- (void)setLoadingStatusText:(NSString *)loadingStatusText {
    if (_loadingStatusText != loadingStatusText) {
        [_loadingStatusText release];
        _loadingStatusText = [loadingStatusText retain];
        
        // Update iOS UI with new status text - BUT only if startup progress is not active
        if (_m3uProgressBariOS && _m3uProgressLabeliOS && !self.isStartupInProgress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateLoadingProgress:self.loadingProgress status:loadingStatusText];
            });
        }
        
        // Startup progress is now handled by setLoadingProgress method to use actual progress values
    }
}

- (void)setEpgLoadingStatusText:(NSString *)epgLoadingStatusText {
    if (_epgLoadingStatusText != epgLoadingStatusText) {
        [_epgLoadingStatusText release];
        _epgLoadingStatusText = [epgLoadingStatusText retain];
        
        // Update iOS UI with new EPG status text - BUT only if startup progress is not active
        if (_epgProgressBariOS && _epgProgressLabeliOS && !self.isStartupInProgress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateEPGLoadingProgress:self.epgLoadingProgress status:epgLoadingStatusText];
            });
        }
        
        // Startup progress is now handled by setEpgLoadingProgress method to use actual progress values
    }
}

#pragma mark - Channel Loading (Shared with macOS)

- (void)loadChannelsFromUrl:(NSString *)urlStr {
    NSLog(@"🔧 iOS loadChannelsFromUrl called (using VLCDataManager): %@", urlStr);
    
    // Show startup progress window if not already shown
    if (!self.isStartupInProgress) {
        [self showStartupProgressWindow];
        [self updateStartupProgress:0.05 step:@"Initializing" details:@"Starting BasicIPTV..."];
    }
    
    // Prevent multiple simultaneous loads
    if (_dataManager.isLoadingChannels) {
        NSLog(@"⚠️ Channel loading already in progress - ignoring duplicate request");
        return;
    }
    
    if (!urlStr || [urlStr length] == 0) {
        NSLog(@"❌ Invalid URL string passed to loadChannelsFromUrl");
        return;
    }
    
    // Update progress for URL loading
    [self updateStartupProgress:0.20 step:@"Loading from URL" details:@"Downloading channel list..."];
    
    // Set M3U URL in data manager
    _dataManager.m3uURL = urlStr;
    
    // Load channels using universal data manager
    [_dataManager loadChannelsFromURL:urlStr];
}



// loadChannelsFromLocalFile implementation removed - using the one in VLCOverlayView+ChannelManagement.m category

- (void)processM3uContent:(NSString *)content sourcePath:(NSString *)sourcePath {
    NSLog(@"📺 iOS processM3uContent - now handled by VLCDataManager/VLCChannelManager");
    // VLCDataManager/VLCChannelManager now handles all M3U processing universally
    return;
    
    /* OLD IMPLEMENTATION - NOW HANDLED BY VLCDataManager/VLCChannelManager
    NSLog(@"🔧 OPTIMIZED processM3uContent: %lu chars", (unsigned long)[content length]);
    
    // Split content efficiently
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    NSUInteger lineCount = [lines count];
    
    if (lineCount == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearLoadingState];
            [self setLoadingStatusText:@"Error: Empty M3U file"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self setLoadingStatusText:@""];
            });
        });
        return;
    }
    
    // Data structures handled by VLCDataManager automatically
    [self setLoadingStatusText:@"Processing channels..."];
    
    // OPTIMIZED: Minimal temporary collections
    NSMutableArray *tempChannels = [[NSMutableArray alloc] initWithCapacity:50000];
    NSMutableArray *tempGroups = [[NSMutableArray alloc] initWithCapacity:200];
    NSMutableDictionary *tempChannelsByGroup = [[NSMutableDictionary alloc] initWithCapacity:200];
    NSMutableDictionary *tempGroupsByCategory = [[NSMutableDictionary alloc] initWithCapacity:5];
    
    // OPTIMIZED: Global string intern table for maximum memory efficiency
    static NSMutableDictionary *stringInternTable = nil;
    if (!stringInternTable) {
        stringInternTable = [[NSMutableDictionary alloc] initWithCapacity:10000];
    }
    
    // OPTIMIZED: Pre-compiled regex patterns (compiled once, used many times)
    static NSRegularExpression *groupRegex = nil;
    static NSRegularExpression *logoRegex = nil;
    static NSRegularExpression *idRegex = nil;
    
    if (!groupRegex) {
        groupRegex = [[NSRegularExpression alloc] initWithPattern:@"group-title=\"([^\"]*)\""
                                                          options:0 error:nil];
        logoRegex = [[NSRegularExpression alloc] initWithPattern:@"tvg-logo=\"([^\"]*)\""
                                                         options:0 error:nil];
        idRegex = [[NSRegularExpression alloc] initWithPattern:@"tvg-id=\"([^\"]*)\""
                                                       options:0 error:nil];
    }
    
    VLCChannel *currentChannel = nil;
    
    for (NSUInteger i = 0; i < lineCount; i++) {
        @autoreleasepool {
            // Show processing progress like macOS version
            if (i % 1000 == 0) {
                NSUInteger percentage = (i * 100) / lineCount;
                NSUInteger channelCount = [tempChannels count];
                
                // Update UI on main thread to show progress
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setLoadingStatusText:[NSString stringWithFormat:@"Processing: %lu%% (%lu/%lu) - %lu channels", 
                                               (unsigned long)percentage, 
                                               (unsigned long)i, 
                                               (unsigned long)lineCount,
                                               (unsigned long)channelCount]];
                });
                
                // Memory monitoring every 5000 lines
                if (i % 5000 == 0 && i > 0) {
                    NSUInteger memoryMB = [self getCurrentMemoryUsageMB];
                    NSLog(@"📊 Processing line %lu: %luMB memory, %lu channels loaded", 
                          (unsigned long)i, (unsigned long)memoryMB, (unsigned long)channelCount);
                    
                    if (memoryMB > 3000) { // 3GB limit
                        NSLog(@"🚨 Memory limit reached at %luMB", (unsigned long)memoryMB);
                        break;
                    }
                }
            }
            
            NSString *line = [[lines objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            
            if ([line length] == 0 || ([line hasPrefix:@"#"] && ![line hasPrefix:@"#EXTINF"])) {
                continue;
            }
            
            if ([line hasPrefix:@"#EXTINF"]) {
                // Clean up previous channel
                if (currentChannel) {
                    [currentChannel release];
                    currentChannel = nil;
                }
                
                currentChannel = [[VLCChannel alloc] init];
                
                // OPTIMIZED: Extract channel name efficiently
                NSRange commaRange = [line rangeOfString:@"," options:NSBackwardsSearch];
                NSString *channelName = @"Unknown Channel";
                if (commaRange.location != NSNotFound) {
                    channelName = [[line substringFromIndex:commaRange.location + 1] 
                                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
                
                // OPTIMIZED: Intern channel name
                NSString *internedName = [stringInternTable objectForKey:channelName];
                if (!internedName) {
                    internedName = [channelName copy];
                    [stringInternTable setObject:internedName forKey:channelName];
                    [internedName release];
                }
                currentChannel.name = internedName;
                
                // OPTIMIZED: Extract group using pre-compiled regex
                NSString *group = @"General";
                NSTextCheckingResult *groupMatch = [groupRegex firstMatchInString:line options:0 
                                                                            range:NSMakeRange(0, line.length)];
                if (groupMatch && groupMatch.numberOfRanges > 1) {
                    group = [line substringWithRange:[groupMatch rangeAtIndex:1]];
                }
                
                // OPTIMIZED: Intern group name
                NSString *internedGroup = [stringInternTable objectForKey:group];
                if (!internedGroup) {
                    internedGroup = [group copy];
                    [stringInternTable setObject:internedGroup forKey:group];
                    [internedGroup release];
                }
                currentChannel.group = internedGroup;
                
                // OPTIMIZED: Only extract logo if reasonable size
                NSTextCheckingResult *logoMatch = [logoRegex firstMatchInString:line options:0 
                                                                         range:NSMakeRange(0, line.length)];
                if (logoMatch && logoMatch.numberOfRanges > 1) {
                    NSString *logo = [line substringWithRange:[logoMatch rangeAtIndex:1]];
                    if (logo.length > 0 && logo.length < 200) {
                        NSString *internedLogo = [stringInternTable objectForKey:logo];
                        if (!internedLogo) {
                            internedLogo = [logo copy];
                            [stringInternTable setObject:internedLogo forKey:logo];
                            [internedLogo release];
                        }
                        currentChannel.logo = internedLogo;
                    }
                }
                
                // OPTIMIZED: Extract ID efficiently
                NSTextCheckingResult *idMatch = [idRegex firstMatchInString:line options:0 
                                                                      range:NSMakeRange(0, line.length)];
                if (idMatch && idMatch.numberOfRanges > 1) {
                    NSString *channelId = [line substringWithRange:[idMatch rangeAtIndex:1]];
                    if (channelId.length > 0 && channelId.length < 50) {
                        NSString *internedId = [stringInternTable objectForKey:channelId];
                        if (!internedId) {
                            internedId = [channelId copy];
                            [stringInternTable setObject:internedId forKey:channelId];
                            [internedId release];
                        }
                        currentChannel.channelId = internedId;
                    }
                }
                
                // TIMESHIFT DETECTION: Parse catchup attributes (iOS/tvOS implementation)
                // NSLog(@"🔧 [TIMESHIFT] Parsing catchup attributes for channel: %@", currentChannel.name);
                
                // Extract catchup value
                NSRange catchupRange = [line rangeOfString:@"catchup=\""];
                if (catchupRange.location != NSNotFound) {
                    NSUInteger startPos = catchupRange.location + catchupRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *catchupValue = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        
                        // FIXED: Only consider specific valid catchup values as supporting timeshift
                        currentChannel.supportsCatchup = ([catchupValue isEqualToString:@"1"] || 
                                                         [catchupValue isEqualToString:@"default"] || 
                                                         [catchupValue isEqualToString:@"append"] ||
                                                         [catchupValue isEqualToString:@"timeshift"] ||
                                                         [catchupValue isEqualToString:@"shift"]);
                        currentChannel.catchupSource = catchupValue;
                        
                        // NSLog(@"🔧 [TIMESHIFT] Channel '%@' supports catch-up: %@ (source: %@)", 
                        //       currentChannel.name, currentChannel.supportsCatchup ? @"YES" : @"NO", catchupValue);
                    }
                }
                
                // Extract catchup-days value
                NSRange catchupDaysRange = [line rangeOfString:@"catchup-days=\""];
                if (catchupDaysRange.location != NSNotFound) {
                    NSUInteger startPos = catchupDaysRange.location + catchupDaysRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *catchupDaysStr = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        currentChannel.catchupDays = [catchupDaysStr integerValue];
                        // NSLog(@"🔧 [TIMESHIFT] Channel '%@' catch-up days: %ld", currentChannel.name, (long)currentChannel.catchupDays);
                    }
                } else if (currentChannel.supportsCatchup) {
                    // Default to 7 days if catch-up is supported but no days specified
                    currentChannel.catchupDays = 7;
                    // NSLog(@"🔧 [TIMESHIFT] Channel '%@' defaulting to 7 days catchup", currentChannel.name);
                }
                
                // Extract catchup-template value
                NSRange catchupTemplateRange = [line rangeOfString:@"catchup-template=\""];
                if (catchupTemplateRange.location != NSNotFound) {
                    NSUInteger startPos = catchupTemplateRange.location + catchupTemplateRange.length;
                    NSRange endQuoteRange = [line rangeOfString:@"\"" options:0 range:NSMakeRange(startPos, line.length - startPos)];
                    if (endQuoteRange.location != NSNotFound) {
                        NSString *catchupTemplate = [line substringWithRange:NSMakeRange(startPos, endQuoteRange.location - startPos)];
                        currentChannel.catchupTemplate = catchupTemplate;
                        // NSLog(@"🔧 [TIMESHIFT] Channel '%@' catchup template: %@", currentChannel.name, catchupTemplate);
                    }
                }
                
            } else if (currentChannel && [line hasPrefix:@"http"]) {
                // OPTIMIZED: Intern URL
                NSString *internedUrl = [stringInternTable objectForKey:line];
                if (!internedUrl) {
                    internedUrl = [line copy];
                    [stringInternTable setObject:internedUrl forKey:line];
                    [internedUrl release];
                }
                currentChannel.url = internedUrl;
                
                // OPTIMIZED: Determine and intern category
                NSString *category = [self determineCategoryForGroup:currentChannel.group];
                NSString *internedCategory = [stringInternTable objectForKey:category];
                if (!internedCategory) {
                    internedCategory = [category copy];
                    [stringInternTable setObject:internedCategory forKey:category];
                    [internedCategory release];
                }
                currentChannel.category = internedCategory;
                
                // Add to collections efficiently
                [tempChannels addObject:currentChannel];
                
                if (![tempGroups containsObject:currentChannel.group]) {
                    [tempGroups addObject:currentChannel.group];
                }
                
                NSMutableArray *groupChannels = [tempChannelsByGroup objectForKey:currentChannel.group];
                if (!groupChannels) {
                    groupChannels = [[NSMutableArray alloc] initWithCapacity:500];
                    [tempChannelsByGroup setObject:groupChannels forKey:currentChannel.group];
                    [groupChannels release];
                }
                [groupChannels addObject:currentChannel];
                
                NSMutableArray *categoryGroups = [tempGroupsByCategory objectForKey:currentChannel.category];
                if (!categoryGroups) {
                    categoryGroups = [[NSMutableArray alloc] initWithCapacity:100];
                    [tempGroupsByCategory setObject:categoryGroups forKey:currentChannel.category];
                    [categoryGroups release];
                }
                if (![categoryGroups containsObject:currentChannel.group]) {
                    [categoryGroups addObject:currentChannel.group];
                }
                
                currentChannel = nil; // Clear reference
            }
        }
    }
    
    // Clean up any remaining channel
    if (currentChannel) {
        [currentChannel release];
    }
    
    // Atomically replace data
    [self safelyReplaceChannelData:tempChannels 
                            groups:tempGroups 
                   channelsByGroup:tempChannelsByGroup 
                  groupsByCategory:tempGroupsByCategory];
    
    // Clean up
    [tempChannels release];
    [tempGroups release]; 
    [tempChannelsByGroup release];
    [tempGroupsByCategory release];
    
    // Save channels to cache for faster startup next time
    NSString *cacheSourcePath = self.m3uFilePath;
    if ([sourcePath hasPrefix:NSTemporaryDirectory()]) {
        // Use original URL for cache instead of temp file
        cacheSourcePath = self.m3uFilePath;
    } else {
        cacheSourcePath = sourcePath;
    }
    // Cache saving is now handled automatically by VLCDataManager/VLCCacheManager
    NSLog(@"📺 iOS: Cache saving delegated to VLCDataManager - no manual caching needed");
    
    NSLog(@"✅ OPTIMIZED: %lu channels loaded efficiently", (unsigned long)[_channels count]);
    
    // Count and log timeshift channels for debugging
    NSInteger timeshiftChannelCount = 0;
    for (VLCChannel *channel in _channels) {
        if (channel.supportsCatchup || channel.catchupDays > 0) {
            timeshiftChannelCount++;
        }
    }
    NSLog(@"🔧 [TIMESHIFT-SUMMARY] Found %ld channels with timeshift support out of %lu total channels", 
          (long)timeshiftChannelCount, (unsigned long)[_channels count]);
    
    // Complete loading
    dispatch_async(dispatch_get_main_queue(), ^{
        [self clearChannelLoadingState];
        
        // Show final loading statistics like macOS
        NSUInteger totalChannels = [_channels count];
        NSUInteger totalGroups = [_channelsByGroup count];
        [self setLoadingStatusText:[NSString stringWithFormat:@"✅ Loaded %lu channels in %lu groups", 
                                   (unsigned long)totalChannels, (unsigned long)totalGroups]];
        
        // Clear status after delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self setLoadingStatusText:@""];
        });
        
        [self setNeedsDisplay];
        
        // Auto-select best category and first group
        if ([_categories count] > 0) {
            // Find TV category or category with most groups (skip Settings)
            NSInteger bestCategoryIndex = 0;
            NSInteger bestGroupCount = 0;
            
            for (NSInteger i = 0; i < [_categories count]; i++) {
                NSString *category = [_categories objectAtIndex:i];
                if ([category isEqualToString:@"SETTINGS"]) continue;
                
                NSArray *groupsForCategory = [_groupsByCategory objectForKey:category];
                NSInteger groupCount = [groupsForCategory count];
                
                if ([category isEqualToString:@"TV"] || groupCount > bestGroupCount) {
                    bestCategoryIndex = i;
                    bestGroupCount = groupCount;
                    if ([category isEqualToString:@"TV"]) break;
                }
            }
            
            NSInteger previousCategoryIndex = _selectedCategoryIndex;
            _selectedCategoryIndex = bestCategoryIndex;
            
            // Handle settings panel visibility
            if (previousCategoryIndex == CATEGORY_SETTINGS && _selectedCategoryIndex != CATEGORY_SETTINGS) {
                [self hideSettingsPanel];
            } else if (_selectedCategoryIndex == CATEGORY_SETTINGS && previousCategoryIndex != CATEGORY_SETTINGS) {
                [self showSettingsPanel];
            }
            
            NSString *selectedCategory = [_categories objectAtIndex:_selectedCategoryIndex];
            NSArray *groupsForCategory = [_groupsByCategory objectForKey:selectedCategory];
            
            if ([groupsForCategory count] > 0) {
                _selectedGroupIndex = 0;
                _selectedChannelIndex = 0;
                NSLog(@"✅ Auto-selected category: %@ (%lu groups)", selectedCategory, (unsigned long)[groupsForCategory count]);
            }
        }
        
        // Auto-fetch catchup info for channels
        NSLog(@"🔄 Checking if autoFetchCatchupInfo method is available...");
        if ([self respondsToSelector:@selector(autoFetchCatchupInfo)]) {
            NSLog(@"✅ autoFetchCatchupInfo method found - calling it...");
            [self autoFetchCatchupInfo];
        } else {
            NSLog(@"❌ autoFetchCatchupInfo method NOT found - this should not happen anymore!");
        }
        
        // Auto-start EPG loading if configured
        if (self.epgUrl && [self.epgUrl length] > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 
                          dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[VLCDataManager sharedManager] loadEPGFromURL:self.epgUrl];
            });
        }
    });
    */
}

#pragma mark - Settings Panel Management (iOS)

- (void)showSettingsPanel {
    NSLog(@"🔧 showSettingsPanel called");
    
    // Only show if we're in the Settings category
    if (_selectedCategoryIndex != CATEGORY_SETTINGS) {
        return;
    }
    
    // If settings scroll view doesn't exist, create it by triggering a redraw
    if (!_settingsScrollViewiOS) {
        // Trigger the drawing system to create the settings panel
        [self setNeedsDisplay];
        
        // Give the drawing system a chance to create the UI elements
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_settingsScrollViewiOS) {
                _settingsScrollViewiOS.hidden = NO;
                if (_settingsScrollViewiOS.superview != self) {
                    [self addSubview:_settingsScrollViewiOS];
                }
            }
        });
    } else {
        // Make sure it's visible and added to the view
        if (_settingsScrollViewiOS.superview != self) {
            [self addSubview:_settingsScrollViewiOS];
        }
        _settingsScrollViewiOS.hidden = NO;
    }
}

- (void)hideSettingsPanel {
    NSLog(@"🔧 hideSettingsPanel called");
    
    if (_settingsScrollViewiOS) {
        // Hide the scroll view instead of removing it completely
        _settingsScrollViewiOS.hidden = YES;
        
        // Optionally remove from superview to save memory
        [_settingsScrollViewiOS removeFromSuperview];
    }
}

- (NSString *)determineCategoryForGroup:(NSString *)group {
    // Implement your logic to determine category based on group
    // This is just a placeholder implementation
    if ([group isEqualToString:@"General"]) return @"Settings";
    if ([group isEqualToString:@"Playlist"]) return @"Settings";
    if ([group isEqualToString:@"Subtitles"]) return @"Settings";
    if ([group isEqualToString:@"Movie Info"]) return @"Settings";
    if ([group isEqualToString:@"Themes"]) return @"Settings";
    return @"TV";
}

// ❌ REMOVED: Old loadEpgData method - now using VLCDataManager.loadEPGFromURL
//}

#pragma mark - Theme Settings ScrollView

- (void)createOrUpdateThemeSettingsScrollView:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
    if (!_themeSettingsScrollView) {
        CGRect scrollFrame = CGRectMake(x, 0, width, rect.size.height);
        _themeSettingsScrollView = [[UIScrollView alloc] initWithFrame:scrollFrame];
        _themeSettingsScrollView.backgroundColor = [UIColor clearColor];
        _themeSettingsScrollView.showsVerticalScrollIndicator = YES;
        _themeSettingsScrollView.showsHorizontalScrollIndicator = NO;
        _themeSettingsScrollView.userInteractionEnabled = YES;
        _themeSettingsScrollView.scrollEnabled = YES;
        _themeSettingsScrollView.bounces = YES;
        _themeSettingsScrollView.delaysContentTouches = NO; // Allow immediate touch response for sliders
        _themeSettingsScrollView.canCancelContentTouches = NO; // Don't cancel slider touches
        
        // Additional scroll view touch optimizations for single-tap slider response
        if ([_themeSettingsScrollView respondsToSelector:@selector(setContentInsetAdjustmentBehavior:)]) {
            _themeSettingsScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
        
#if TARGET_OS_IOS
        // Critical: Make the scroll view delegate touches immediately to subviews (iOS only)
        _themeSettingsScrollView.exclusiveTouch = NO;
        _themeSettingsScrollView.multipleTouchEnabled = YES;
        
        // Override all gesture recognizers to allow immediate slider interaction
        for (UIGestureRecognizer *gestureRecognizer in _themeSettingsScrollView.gestureRecognizers) {
            gestureRecognizer.cancelsTouchesInView = NO;
            gestureRecognizer.delaysTouchesBegan = NO;
            gestureRecognizer.delaysTouchesEnded = NO;
            
            if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
                UIPanGestureRecognizer *panGesture = (UIPanGestureRecognizer *)gestureRecognizer;
                // Only respond to multi-finger or very deliberate pan gestures
                panGesture.minimumNumberOfTouches = 1;
                panGesture.maximumNumberOfTouches = 2;
            }
        }
#endif
        [self addSubview:_themeSettingsScrollView];
        
        [self setupThemeSettingsContent];
    } else {
        // Update frame and show the scroll view
        CGRect newFrame = CGRectMake(x, 0, width, rect.size.height);
        _themeSettingsScrollView.frame = newFrame;
        _themeSettingsScrollView.hidden = NO; // Ensure it's visible
        
        // Recreate content if scroll view was hidden (returning from another group)
        if (_themeSettingsScrollView.subviews.count == 0) {
            [self setupThemeSettingsContent];
        }
    }
}

- (void)setupThemeSettingsContent {
#if TARGET_OS_IOS
    // Remove existing subviews
    for (UIView *subview in _themeSettingsScrollView.subviews) {
        [subview removeFromSuperview];
    }
    
    CGFloat padding = 20;
    CGFloat currentY = padding;
    CGFloat controlWidth = _themeSettingsScrollView.frame.size.width - (padding * 2);
    CGFloat spacing = 25;
    
    // Title
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 30)];
    titleLabel.text = @"Theme Settings";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [_themeSettingsScrollView addSubview:titleLabel];
    [titleLabel release];
    currentY += 30 + spacing;
    
    // Theme label and dropdown (like macOS)
    UILabel *themeLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, 80, 20)];
    themeLabel.text = @"Theme:";
    themeLabel.textColor = [UIColor whiteColor];
    themeLabel.font = [UIFont systemFontOfSize:14];
    [_themeSettingsScrollView addSubview:themeLabel];
    [themeLabel release];
    
    // Theme dropdown button (styled like macOS)
    UIButton *themeDropdown = [UIButton buttonWithType:UIButtonTypeSystem];
    themeDropdown.frame = CGRectMake(padding + 90, currentY - 5, controlWidth - 100, 35);
    [themeDropdown setTitle:[self getCurrentThemeDisplayTextiOS] forState:UIControlStateNormal];
    [themeDropdown setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    themeDropdown.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:0.9];
    themeDropdown.layer.cornerRadius = 6;
    themeDropdown.layer.borderWidth = 1;
    themeDropdown.layer.borderColor = [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0].CGColor;
    themeDropdown.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    themeDropdown.titleEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 0);
    themeDropdown.userInteractionEnabled = YES;
    [themeDropdown addTarget:self action:@selector(showThemeDropdown:) forControlEvents:UIControlEventTouchUpInside];
    [_themeSettingsScrollView addSubview:themeDropdown];
    
    // Add dropdown arrow
    UILabel *arrowLabel = [[UILabel alloc] initWithFrame:CGRectMake(themeDropdown.frame.size.width - 25, 8, 20, 20)];
    arrowLabel.text = @"▼";
    arrowLabel.textColor = [UIColor lightGrayColor];
    arrowLabel.font = [UIFont systemFontOfSize:12];
    arrowLabel.textAlignment = NSTextAlignmentCenter;
    arrowLabel.userInteractionEnabled = NO;
    [themeDropdown addSubview:arrowLabel];
    [arrowLabel release];
    
    currentY += 35 + spacing;
    
    // Transparency label and slider (like macOS)
    UILabel *transparencyLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
    transparencyLabel.text = [NSString stringWithFormat:@"Transparency: %.0f%%", (self.themeAlpha ?: 0.8) * 100];
    transparencyLabel.textColor = [UIColor whiteColor];
    transparencyLabel.font = [UIFont systemFontOfSize:14];
    transparencyLabel.tag = 999; // For updating the label
    [_themeSettingsScrollView addSubview:transparencyLabel];
    [transparencyLabel release];
    currentY += 20 + 10;
    
    // Transparency slider (with proper touch handling)
    UISlider *transparencySlider = [[UISlider alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 30)];
    transparencySlider.minimumValue = 0.3;
    transparencySlider.maximumValue = 1.0;
    transparencySlider.value = self.themeAlpha ?: 0.8;
    transparencySlider.tintColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0];
    transparencySlider.userInteractionEnabled = YES;
    transparencySlider.continuous = YES;
    transparencySlider.multipleTouchEnabled = NO; // Disable multi-touch for better single finger response
    transparencySlider.tag = 998; // For finding the slider
    // Add comprehensive touch event handlers for all slider interactions
    [transparencySlider addTarget:self action:@selector(transparencySliderChanged:) forControlEvents:UIControlEventValueChanged];
    [transparencySlider addTarget:self action:@selector(transparencySliderChanged:) forControlEvents:UIControlEventTouchDown];
    [transparencySlider addTarget:self action:@selector(transparencySliderChanged:) forControlEvents:UIControlEventTouchDragInside];
    [transparencySlider addTarget:self action:@selector(transparencySliderChanged:) forControlEvents:UIControlEventTouchDragOutside];
    [transparencySlider addTarget:self action:@selector(transparencySliderChanged:) forControlEvents:UIControlEventTouchUpInside];
    [transparencySlider addTarget:self action:@selector(transparencySliderChanged:) forControlEvents:UIControlEventTouchUpOutside];
    [transparencySlider addTarget:self action:@selector(transparencySliderChanged:) forControlEvents:UIControlEventTouchCancel];
    
    // Optimize slider for immediate single-tap response
    [self optimizeSliderForSingleTapResponse:transparencySlider];
    
    [_themeSettingsScrollView addSubview:transparencySlider];
    [transparencySlider release];
    currentY += 30 + spacing;
    
    // Custom theme controls (shown when Custom is selected)
    if (self.currentTheme == VLC_THEME_CUSTOM) {
        currentY = [self addCustomThemeControlsAtY:currentY padding:padding controlWidth:controlWidth spacing:spacing];
    }
    
    // Selection Colors section (like macOS)
    currentY += spacing;
    UILabel *selectionLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
    selectionLabel.text = @"Selection Colors";
    selectionLabel.textColor = [UIColor whiteColor];
    selectionLabel.font = [UIFont boldSystemFontOfSize:16];
    [_themeSettingsScrollView addSubview:selectionLabel];
    [selectionLabel release];
    currentY += 20 + 15;
    
    // Selection Red
    currentY = [self addCustomColorSliderAtY:currentY 
                                    padding:padding 
                               controlWidth:controlWidth 
                                    spacing:spacing 
                                      title:@"Selection Red" 
                                        tag:11 
                                      value:self.customSelectionRed ?: 0.2];
    
    // Selection Green
    currentY = [self addCustomColorSliderAtY:currentY 
                                    padding:padding 
                               controlWidth:controlWidth 
                                    spacing:spacing 
                                      title:@"Selection Green" 
                                        tag:12 
                                      value:self.customSelectionGreen ?: 0.4];
    
    // Selection Blue
    currentY = [self addCustomColorSliderAtY:currentY 
                                    padding:padding 
                               controlWidth:controlWidth 
                                    spacing:spacing 
                                      title:@"Selection Blue" 
                                        tag:13 
                                      value:self.customSelectionBlue ?: 0.9];
    
    // Advanced Settings section
    currentY += spacing;
    UILabel *advancedLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
    advancedLabel.text = @"Advanced Settings";
    advancedLabel.textColor = [UIColor whiteColor];
    advancedLabel.font = [UIFont boldSystemFontOfSize:16];
    [_themeSettingsScrollView addSubview:advancedLabel];
    [advancedLabel release];
    currentY += 20 + 15;
    
    // Glassmorphism toggle
    UILabel *glassLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
    glassLabel.text = [NSString stringWithFormat:@"Glassmorphism Effects: %@", self.glassmorphismEnabled ? @"Enabled" : @"Disabled"];
    glassLabel.textColor = [UIColor whiteColor];
    glassLabel.font = [UIFont systemFontOfSize:14];
    glassLabel.tag = 1999; // For updating
    [_themeSettingsScrollView addSubview:glassLabel];
    [glassLabel release];
    currentY += 20 + 5;
    
    UISwitch *glassSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(padding, currentY, 60, 30)];
    glassSwitch.on = self.glassmorphismEnabled;
    glassSwitch.tag = 1998; // For identification
    [glassSwitch addTarget:self action:@selector(glassmorphismToggleChanged:) forControlEvents:UIControlEventValueChanged];
    [_themeSettingsScrollView addSubview:glassSwitch];
    [glassSwitch release];
    currentY += 30 + spacing;
    
    // Advanced Glassmorphism Controls (when enabled)
    if (self.glassmorphismEnabled) {
        currentY += 10; // Extra spacing before advanced controls
        
        // Glassmorphism Intensity
        currentY = [self addGlassmorphismSliderAtY:currentY 
                                          padding:padding 
                                     controlWidth:controlWidth 
                                          spacing:spacing 
                                            title:@"Glassmorphism Intensity" 
                                              tag:21 
                                            value:self.glassmorphismIntensity ?: 1.0
                                         minValue:0.0
                                         maxValue:1.0
                                      displayUnit:@"%"];
        
        // Blur Radius
        currentY = [self addGlassmorphismSliderAtY:currentY 
                                          padding:padding 
                                     controlWidth:controlWidth 
                                          spacing:spacing 
                                            title:@"Blur Radius" 
                                              tag:22 
                                            value:self.glassmorphismBlurRadius ?: 25.0
                                         minValue:0.0
                                         maxValue:50.0
                                      displayUnit:@"px"];
        
        // Border Width
        currentY = [self addGlassmorphismSliderAtY:currentY 
                                          padding:padding 
                                     controlWidth:controlWidth 
                                          spacing:spacing 
                                            title:@"Border Width" 
                                              tag:23 
                                            value:self.glassmorphismBorderWidth ?: 1.0
                                         minValue:0.0
                                         maxValue:5.0
                                      displayUnit:@"px"];
        
        // Corner Radius
        currentY = [self addGlassmorphismSliderAtY:currentY 
                                          padding:padding 
                                     controlWidth:controlWidth 
                                          spacing:spacing 
                                            title:@"Corner Radius" 
                                              tag:24 
                                            value:self.glassmorphismCornerRadius ?: 8.0
                                         minValue:0.0
                                         maxValue:20.0
                                      displayUnit:@"px"];
        
        // Sanded Texture Intensity
        currentY = [self addGlassmorphismSliderAtY:currentY 
                                          padding:padding 
                                     controlWidth:controlWidth 
                                          spacing:spacing 
                                            title:@"Sanded Texture" 
                                              tag:25 
                                            value:self.glassmorphismSandedIntensity ?: 0.0
                                         minValue:0.0
                                         maxValue:3.0
                                      displayUnit:@""];
        
        // High Quality toggle
        currentY += 10;
        UILabel *qualityLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
        qualityLabel.text = [NSString stringWithFormat:@"High Quality Mode: %@", self.glassmorphismHighQuality ? @"Enabled" : @"Disabled"];
        qualityLabel.textColor = [UIColor whiteColor];
        qualityLabel.font = [UIFont systemFontOfSize:14];
        qualityLabel.tag = 1997; // For updating
        [_themeSettingsScrollView addSubview:qualityLabel];
        [qualityLabel release];
        currentY += 20 + 5;
        
        UISwitch *qualitySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(padding, currentY, 60, 30)];
        qualitySwitch.on = self.glassmorphismHighQuality;
        qualitySwitch.tag = 1996; // For identification
        [qualitySwitch addTarget:self action:@selector(glassmorphismQualityToggleChanged:) forControlEvents:UIControlEventValueChanged];
        [_themeSettingsScrollView addSubview:qualitySwitch];
        [qualitySwitch release];
        currentY += 30 + spacing;
        
        // Ignore Transparency toggle
        UILabel *ignoreLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
        ignoreLabel.text = [NSString stringWithFormat:@"Independent Transparency: %@", self.glassmorphismIgnoreTransparency ? @"Yes" : @"No"];
        ignoreLabel.textColor = [UIColor whiteColor];
        ignoreLabel.font = [UIFont systemFontOfSize:14];
        ignoreLabel.tag = 1995; // For updating
        [_themeSettingsScrollView addSubview:ignoreLabel];
        [ignoreLabel release];
        currentY += 20 + 5;
        
        UISwitch *ignoreSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(padding, currentY, 60, 30)];
        ignoreSwitch.on = self.glassmorphismIgnoreTransparency;
        ignoreSwitch.tag = 1994; // For identification
        [ignoreSwitch addTarget:self action:@selector(glassmorphismIgnoreToggleChanged:) forControlEvents:UIControlEventValueChanged];
        [_themeSettingsScrollView addSubview:ignoreSwitch];
        [ignoreSwitch release];
        currentY += 30 + spacing;
    }
    
    // Set content size with extra padding
    _themeSettingsScrollView.contentSize = CGSizeMake(_themeSettingsScrollView.frame.size.width, currentY + 50);
#else
    // tvOS fallback - show a simple message
    UILabel *tvosLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, _themeSettingsScrollView.frame.size.width - 40, 40)];
    tvosLabel.text = @"Theme settings not available on tvOS";
    tvosLabel.textColor = [UIColor whiteColor];
    tvosLabel.font = [UIFont systemFontOfSize:16];
    tvosLabel.textAlignment = NSTextAlignmentCenter;
    [_themeSettingsScrollView addSubview:tvosLabel];
    [tvosLabel release];
    
    _themeSettingsScrollView.contentSize = CGSizeMake(_themeSettingsScrollView.frame.size.width, 100);
#endif
}

- (NSString *)getCurrentThemeDisplayTextiOS {
    switch (self.currentTheme) {
        case VLC_THEME_DARK: return @"Dark";
        case VLC_THEME_DARKER: return @"Darker";
        case VLC_THEME_BLUE: return @"Blue";
        case VLC_THEME_GREEN: return @"Green";
        case VLC_THEME_PURPLE: return @"Purple";
        case VLC_THEME_CUSTOM: return @"Custom";
        default: return @"Dark";
    }
}

- (void)showThemeDropdown:(UIButton *)sender {
    NSLog(@"🎨 Theme dropdown tapped");
    
    // Create action sheet (iOS dropdown equivalent)
    UIAlertController *themeSheet = [UIAlertController alertControllerWithTitle:@"Select Theme" 
                                                                        message:nil 
                                                                 preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Add theme options
    NSArray *themes = @[
        @[@"Dark", @(VLC_THEME_DARK)],
        @[@"Darker", @(VLC_THEME_DARKER)],
        @[@"Blue", @(VLC_THEME_BLUE)],
        @[@"Green", @(VLC_THEME_GREEN)],
        @[@"Purple", @(VLC_THEME_PURPLE)],
        @[@"Custom", @(VLC_THEME_CUSTOM)]
    ];
    
    for (NSArray *themeInfo in themes) {
        NSString *themeName = themeInfo[0];
        VLCColorTheme themeValue = [themeInfo[1] integerValue];
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:themeName 
                                                         style:UIAlertActionStyleDefault 
                                                       handler:^(UIAlertAction * _Nonnull action) {
            [self selectTheme:themeValue];
        }];
        
        // Mark current theme
        if (themeValue == self.currentTheme) {
            [action setValue:[UIImage systemImageNamed:@"checkmark"] forKey:@"image"];
        }
        
        [themeSheet addAction:action];
    }
    
    // Add cancel button
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" 
                                                           style:UIAlertActionStyleCancel 
                                                         handler:nil];
    [themeSheet addAction:cancelAction];
    
    // Present the action sheet
    // Find the view controller
    UIViewController *viewController = nil;
    UIResponder *responder = self;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            viewController = (UIViewController *)responder;
            break;
        }
        responder = [responder nextResponder];
    }
    
    if (viewController) {
        // Configure for iPad
        if (themeSheet.popoverPresentationController) {
            themeSheet.popoverPresentationController.sourceView = sender;
            themeSheet.popoverPresentationController.sourceRect = sender.bounds;
        }
        
        [viewController presentViewController:themeSheet animated:YES completion:nil];
    }
}

- (void)selectTheme:(VLCColorTheme)theme {
    NSLog(@"🎨 Selected theme: %ld", (long)theme);
    
    // Apply the theme
    [self applyThemeiOS:theme];
    
    // Update dropdown button text
    for (UIView *subview in _themeSettingsScrollView.subviews) {
        if ([subview isKindOfClass:[UIButton class]]) {
            UIButton *button = (UIButton *)subview;
            if ([button.titleLabel.text containsString:@"Dark"] || 
                [button.titleLabel.text containsString:@"Custom"] ||
                [button.titleLabel.text containsString:@"Blue"] ||
                [button.titleLabel.text containsString:@"Green"] ||
                [button.titleLabel.text containsString:@"Purple"]) {
                [button setTitle:[self getCurrentThemeDisplayTextiOS] forState:UIControlStateNormal];
                break;
            }
        }
    }
    
    // Refresh the theme settings to show/hide custom controls
    [self setupThemeSettingsContent];
}

#if TARGET_OS_IOS
- (void)transparencySliderChanged:(UISlider *)sender {
    CGFloat transparency = sender.value;
    NSLog(@"🌫️ Transparency slider changed to: %.2f", transparency);
    
    // Update theme alpha and apply immediately
    self.themeAlpha = transparency;
    [self updateThemeColorsiOS];
    [self setNeedsDisplay];
    
    // Update the transparency label
    for (UIView *subview in _themeSettingsScrollView.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && subview.tag == 999) {
            UILabel *label = (UILabel *)subview;
            label.text = [NSString stringWithFormat:@"Transparency: %.0f%%", transparency * 100];
            break;
        }
    }
}

- (CGFloat)addCustomThemeControlsAtY:(CGFloat)currentY 
                             padding:(CGFloat)padding 
                        controlWidth:(CGFloat)controlWidth 
                             spacing:(CGFloat)spacing {
    
    // Custom RGB Controls section
    UILabel *customLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
    customLabel.text = @"Custom Colors";
    customLabel.textColor = [UIColor whiteColor];
    customLabel.font = [UIFont boldSystemFontOfSize:16];
    [_themeSettingsScrollView addSubview:customLabel];
    [customLabel release];
    currentY += 20 + 15;
    
    // Red component
    currentY = [self addCustomColorSliderAtY:currentY 
                                    padding:padding 
                               controlWidth:controlWidth 
                                    spacing:spacing 
                                      title:@"Red" 
                                        tag:1 
                                      value:self.customThemeRed ?: 0.10];
    
    // Green component  
    currentY = [self addCustomColorSliderAtY:currentY 
                                    padding:padding 
                               controlWidth:controlWidth 
                                    spacing:spacing 
                                      title:@"Green" 
                                        tag:2 
                                      value:self.customThemeGreen ?: 0.12];
    
    // Blue component
    currentY = [self addCustomColorSliderAtY:currentY 
                                    padding:padding 
                               controlWidth:controlWidth 
                                    spacing:spacing 
                                      title:@"Blue" 
                                        tag:3 
                                      value:self.customThemeBlue ?: 0.16];
    
    return currentY;
}

- (CGFloat)addCustomColorSliderAtY:(CGFloat)currentY 
                           padding:(CGFloat)padding 
                      controlWidth:(CGFloat)controlWidth 
                           spacing:(CGFloat)spacing 
                             title:(NSString *)title 
                               tag:(NSInteger)tag 
                             value:(CGFloat)value {
    
    // Color label
    UILabel *colorLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
    colorLabel.text = [NSString stringWithFormat:@"%@: %.2f", title, value];
    colorLabel.textColor = [UIColor whiteColor];
    colorLabel.font = [UIFont systemFontOfSize:14];
    colorLabel.tag = tag + 100; // For updating the label
    [_themeSettingsScrollView addSubview:colorLabel];
    [colorLabel release];
    currentY += 20 + 5;
    
    // Color slider with enhanced touch handling
    UISlider *colorSlider = [[UISlider alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 30)];
    colorSlider.minimumValue = 0.0;
    colorSlider.maximumValue = 1.0;
    colorSlider.value = value;
    colorSlider.tag = tag;
    colorSlider.userInteractionEnabled = YES;
    colorSlider.continuous = YES;
    colorSlider.multipleTouchEnabled = NO; // Disable multi-touch for better single finger response
    
    // Set appropriate color for each slider
    switch (tag) {
        case 1: // Red
            colorSlider.tintColor = [UIColor redColor];
            break;
        case 2: // Green
            colorSlider.tintColor = [UIColor greenColor];
            break;
        case 3: // Blue
            colorSlider.tintColor = [UIColor blueColor];
            break;
        default:
            colorSlider.tintColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0];
            break;
    }
    
    // Add comprehensive touch event handlers for all slider interactions
    [colorSlider addTarget:self action:@selector(customColorSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [colorSlider addTarget:self action:@selector(customColorSliderChanged:) forControlEvents:UIControlEventTouchDown];
    [colorSlider addTarget:self action:@selector(customColorSliderChanged:) forControlEvents:UIControlEventTouchDragInside];
    [colorSlider addTarget:self action:@selector(customColorSliderChanged:) forControlEvents:UIControlEventTouchDragOutside];
    [colorSlider addTarget:self action:@selector(customColorSliderChanged:) forControlEvents:UIControlEventTouchUpInside];
    [colorSlider addTarget:self action:@selector(customColorSliderChanged:) forControlEvents:UIControlEventTouchUpOutside];
    [colorSlider addTarget:self action:@selector(customColorSliderChanged:) forControlEvents:UIControlEventTouchCancel];
    
    // Optimize slider for immediate single-tap response
    [self optimizeSliderForSingleTapResponse:colorSlider];
    
    [_themeSettingsScrollView addSubview:colorSlider];
    [colorSlider release];
    currentY += 30 + spacing;
    
    return currentY;
}

- (CGFloat)addGlassmorphismSliderAtY:(CGFloat)currentY 
                             padding:(CGFloat)padding 
                        controlWidth:(CGFloat)controlWidth 
                             spacing:(CGFloat)spacing 
                               title:(NSString *)title 
                                 tag:(NSInteger)tag 
                               value:(CGFloat)value
                            minValue:(CGFloat)minValue
                            maxValue:(CGFloat)maxValue
                         displayUnit:(NSString *)displayUnit {
    
    // Format display value based on unit
    NSString *displayValue;
    if ([displayUnit isEqualToString:@"%"]) {
        displayValue = [NSString stringWithFormat:@"%.0f%%", value * 100];
    } else if ([displayUnit isEqualToString:@"px"]) {
        displayValue = [NSString stringWithFormat:@"%.1f px", value];
    } else {
        displayValue = [NSString stringWithFormat:@"%.1f", value];
    }
    
    // Glassmorphism slider label
    UILabel *glassLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
    glassLabel.text = [NSString stringWithFormat:@"%@: %@", title, displayValue];
    glassLabel.textColor = [UIColor whiteColor];
    glassLabel.font = [UIFont systemFontOfSize:14];
    glassLabel.tag = tag + 100; // For updating the label
    [_themeSettingsScrollView addSubview:glassLabel];
    [glassLabel release];
    currentY += 20 + 5;
    
    // Glassmorphism slider with optimized touch handling
    UISlider *glassSlider = [[UISlider alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 30)];
    glassSlider.minimumValue = minValue;
    glassSlider.maximumValue = maxValue;
    glassSlider.value = value;
    glassSlider.tag = tag;
    glassSlider.userInteractionEnabled = YES;
    glassSlider.continuous = YES;
    glassSlider.multipleTouchEnabled = NO;
    
    // Set appropriate colors for different glassmorphism sliders
    switch (tag) {
        case 21: // Intensity
            glassSlider.tintColor = [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1.0];
            break;
        case 22: // Blur
            glassSlider.tintColor = [UIColor colorWithRed:0.5 green:0.8 blue:1.0 alpha:1.0];
            break;
        case 23: // Border
            glassSlider.tintColor = [UIColor colorWithRed:0.7 green:0.9 blue:1.0 alpha:1.0];
            break;
        case 24: // Corner
            glassSlider.tintColor = [UIColor colorWithRed:0.9 green:1.0 blue:1.0 alpha:1.0];
            break;
        case 25: // Sanded
            glassSlider.tintColor = [UIColor colorWithRed:1.0 green:0.9 blue:0.7 alpha:1.0];
            break;
        default:
            glassSlider.tintColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0];
            break;
    }
    
    // Add comprehensive touch event handlers for all slider interactions
    [glassSlider addTarget:self action:@selector(glassmorphismSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [glassSlider addTarget:self action:@selector(glassmorphismSliderChanged:) forControlEvents:UIControlEventTouchDown];
    [glassSlider addTarget:self action:@selector(glassmorphismSliderChanged:) forControlEvents:UIControlEventTouchDragInside];
    [glassSlider addTarget:self action:@selector(glassmorphismSliderChanged:) forControlEvents:UIControlEventTouchDragOutside];
    [glassSlider addTarget:self action:@selector(glassmorphismSliderChanged:) forControlEvents:UIControlEventTouchUpInside];
    [glassSlider addTarget:self action:@selector(glassmorphismSliderChanged:) forControlEvents:UIControlEventTouchUpOutside];
    [glassSlider addTarget:self action:@selector(glassmorphismSliderChanged:) forControlEvents:UIControlEventTouchCancel];
    
    // Optimize slider for immediate single-tap response
    [self optimizeSliderForSingleTapResponse:glassSlider];
    
    [_themeSettingsScrollView addSubview:glassSlider];
    [glassSlider release];
    currentY += 30 + spacing;
    
    return currentY;
}

- (void)customColorSliderChanged:(UISlider *)sender {
    NSInteger colorTag = sender.tag;
    CGFloat colorValue = sender.value;
    
    // Update the corresponding label
    for (UIView *subview in _themeSettingsScrollView.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && subview.tag == (colorTag + 100)) {
            UILabel *label = (UILabel *)subview;
            NSString *colorName = @"";
            
            // Handle both custom theme colors (1-3) and selection colors (11-13)
            switch (colorTag) {
                case 1: colorName = @"Red"; break;
                case 2: colorName = @"Green"; break;
                case 3: colorName = @"Blue"; break;
                case 11: colorName = @"Selection Red"; break;
                case 12: colorName = @"Selection Green"; break;
                case 13: colorName = @"Selection Blue"; break;
            }
            label.text = [NSString stringWithFormat:@"%@: %.2f", colorName, colorValue];
            break;
        }
    }
    
    // Update color values
    switch (colorTag) {
        case 1: // Custom Theme Red
            self.customThemeRed = colorValue;
            NSLog(@"🔴 Custom red changed to: %.2f", colorValue);
            break;
        case 2: // Custom Theme Green
            self.customThemeGreen = colorValue;
            NSLog(@"🟢 Custom green changed to: %.2f", colorValue);
            break;
        case 3: // Custom Theme Blue
            self.customThemeBlue = colorValue;
            NSLog(@"🔵 Custom blue changed to: %.2f", colorValue);
            break;
        case 11: // Selection Red
            self.customSelectionRed = colorValue;
            NSLog(@"🟡 Selection red changed to: %.2f", colorValue);
            break;
        case 12: // Selection Green
            self.customSelectionGreen = colorValue;
            NSLog(@"🟡 Selection green changed to: %.2f", colorValue);
            break;
        case 13: // Selection Blue
            self.customSelectionBlue = colorValue;
            NSLog(@"🟡 Selection blue changed to: %.2f", colorValue);
            break;
    }
    
    // Apply theme colors immediately like macOS
    [self updateThemeColorsiOS];
    [self updateSelectionColorsToCurrentTheme];
    [self setNeedsDisplay];
    
    NSLog(@"🎨 Applied color changes, theme updated");
}

- (void)glassmorphismSliderChanged:(UISlider *)sender {
    NSInteger sliderTag = sender.tag;
    CGFloat sliderValue = sender.value;
    
    // Update the corresponding label with proper formatting
    for (UIView *subview in _themeSettingsScrollView.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && subview.tag == (sliderTag + 100)) {
            UILabel *label = (UILabel *)subview;
            NSString *sliderName = @"";
            NSString *displayValue = @"";
            
            // Handle different glassmorphism sliders with proper display formatting
            switch (sliderTag) {
                case 21: // Intensity
                    sliderName = @"Glassmorphism Intensity";
                    displayValue = [NSString stringWithFormat:@"%.0f%%", sliderValue * 100];
                    break;
                case 22: // Blur Radius
                    sliderName = @"Blur Radius";
                    displayValue = [NSString stringWithFormat:@"%.1f px", sliderValue];
                    break;
                case 23: // Border Width
                    sliderName = @"Border Width";
                    displayValue = [NSString stringWithFormat:@"%.1f px", sliderValue];
                    break;
                case 24: // Corner Radius
                    sliderName = @"Corner Radius";
                    displayValue = [NSString stringWithFormat:@"%.1f px", sliderValue];
                    break;
                case 25: // Sanded Texture
                    sliderName = @"Sanded Texture";
                    displayValue = [NSString stringWithFormat:@"%.1f", sliderValue];
                    break;
            }
            label.text = [NSString stringWithFormat:@"%@: %@", sliderName, displayValue];
            break;
        }
    }
    
    // Update glassmorphism property values
    switch (sliderTag) {
        case 21: // Glassmorphism Intensity
            self.glassmorphismIntensity = sliderValue;
            NSLog(@"✨ Glassmorphism intensity changed to: %.2f", sliderValue);
            break;
        case 22: // Blur Radius
            self.glassmorphismBlurRadius = sliderValue;
            NSLog(@"✨ Glassmorphism blur radius changed to: %.2f", sliderValue);
            break;
        case 23: // Border Width
            self.glassmorphismBorderWidth = sliderValue;
            NSLog(@"✨ Glassmorphism border width changed to: %.2f", sliderValue);
            break;
        case 24: // Corner Radius
            self.glassmorphismCornerRadius = sliderValue;
            NSLog(@"✨ Glassmorphism corner radius changed to: %.2f", sliderValue);
            break;
        case 25: // Sanded Texture Intensity
            self.glassmorphismSandedIntensity = sliderValue;
            NSLog(@"✨ Glassmorphism sanded intensity changed to: %.2f", sliderValue);
            break;
    }
    
    // Apply glassmorphism changes immediately like macOS
    [self updateThemeColorsiOS];
    [self setNeedsDisplay];
    
    NSLog(@"✨ Applied glassmorphism changes");
}

- (void)glassmorphismToggleChanged:(UISwitch *)sender {
    BOOL enabled = sender.isOn;
    NSLog(@"✨ Glassmorphism toggled: %@", enabled ? @"ON" : @"OFF");
    
    self.glassmorphismEnabled = enabled;
    
    // Update the label
    for (UIView *subview in _themeSettingsScrollView.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && subview.tag == 1999) {
            UILabel *label = (UILabel *)subview;
            label.text = [NSString stringWithFormat:@"Glassmorphism Effects: %@", enabled ? @"Enabled" : @"Disabled"];
            break;
        }
    }
    
    // Recreate the entire theme settings to show/hide advanced controls
    [self setupThemeSettingsContent];
    
    // Apply the change immediately
    [self updateThemeColorsiOS];
    [self setNeedsDisplay];
}

- (void)glassmorphismQualityToggleChanged:(UISwitch *)sender {
    BOOL enabled = sender.isOn;
    NSLog(@"✨ Glassmorphism quality toggled: %@", enabled ? @"HIGH" : @"LOW");
    
    self.glassmorphismHighQuality = enabled;
    
    // Update the label
    for (UIView *subview in _themeSettingsScrollView.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && subview.tag == 1997) {
            UILabel *label = (UILabel *)subview;
            label.text = [NSString stringWithFormat:@"High Quality Mode: %@", enabled ? @"Enabled" : @"Disabled"];
            break;
        }
    }
    
    // Apply the change immediately
    [self updateThemeColorsiOS];
    [self setNeedsDisplay];
}

- (void)glassmorphismIgnoreToggleChanged:(UISwitch *)sender {
    BOOL enabled = sender.isOn;
    NSLog(@"✨ Glassmorphism ignore transparency toggled: %@", enabled ? @"YES" : @"NO");
    
    self.glassmorphismIgnoreTransparency = enabled;
    
    // Update the label
    for (UIView *subview in _themeSettingsScrollView.subviews) {
        if ([subview isKindOfClass:[UILabel class]] && subview.tag == 1995) {
            UILabel *label = (UILabel *)subview;
            label.text = [NSString stringWithFormat:@"Independent Transparency: %@", enabled ? @"Yes" : @"No"];
            break;
        }
    }
    
    // Apply the change immediately
    [self updateThemeColorsiOS];
    [self setNeedsDisplay];
}

- (void)optimizeSliderForSingleTapResponse:(UISlider *)slider {
    // Ensure slider responds immediately to single tap without scroll view interference
    
    // Disable all gesture recognizers that might delay touch response
    for (UIGestureRecognizer *gesture in slider.gestureRecognizers) {
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;
        gesture.cancelsTouchesInView = NO;
    }
    
    // Set additional slider properties for immediate response
    slider.exclusiveTouch = YES;  // Prevent other controls from interfering
    
    // Force the slider to be higher priority than its superview's gesture recognizers
    if (slider.superview) {
        for (UIGestureRecognizer *superGesture in slider.superview.gestureRecognizers) {
            for (UIGestureRecognizer *sliderGesture in slider.gestureRecognizers) {
                [superGesture requireGestureRecognizerToFail:sliderGesture];
            }
        }
    }
    
    // Create a custom tap gesture specifically for immediate slider response
    UITapGestureRecognizer *immediateSliderTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleImmediateSliderTap:)];
    immediateSliderTap.delaysTouchesBegan = NO;
    immediateSliderTap.delaysTouchesEnded = NO;
    immediateSliderTap.cancelsTouchesInView = NO;
    immediateSliderTap.numberOfTapsRequired = 1;
    immediateSliderTap.numberOfTouchesRequired = 1;
    [slider addGestureRecognizer:immediateSliderTap];
    [immediateSliderTap release];
}

- (void)handleImmediateSliderTap:(UITapGestureRecognizer *)gesture {
    if ([gesture.view isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)gesture.view;
        
        // Get tap location and convert to slider value
        CGPoint tapLocation = [gesture locationInView:slider];
        CGFloat sliderWidth = slider.bounds.size.width;
        CGFloat percentage = tapLocation.x / sliderWidth;
        percentage = MAX(0.0, MIN(1.0, percentage)); // Clamp to valid range
        
        // Calculate new slider value
        CGFloat newValue = slider.minimumValue + (percentage * (slider.maximumValue - slider.minimumValue));
        
        // Update slider value and trigger events
        slider.value = newValue;
        [slider sendActionsForControlEvents:UIControlEventValueChanged];
        [slider sendActionsForControlEvents:UIControlEventTouchDown];
        [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
        
        NSLog(@"🎯 Single tap on slider detected - immediate response with value: %.2f", newValue);
    }
}
#endif // TARGET_OS_IOS - End of iOS-specific UI methods

#pragma mark - Subtitle Settings ScrollView

#if TARGET_OS_IOS
- (void)createOrUpdateSubtitleSettingsScrollView:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
    if (!_subtitleSettingsScrollView) {
        CGRect scrollFrame = CGRectMake(x, 0, width, rect.size.height);
        _subtitleSettingsScrollView = [[UIScrollView alloc] initWithFrame:scrollFrame];
        _subtitleSettingsScrollView.backgroundColor = [UIColor clearColor];
        _subtitleSettingsScrollView.showsVerticalScrollIndicator = YES;
        _subtitleSettingsScrollView.showsHorizontalScrollIndicator = NO;
        [self addSubview:_subtitleSettingsScrollView];
        
        [self setupSubtitleSettingsContent];
    } else {
        // Update frame and ensure it's visible
        CGRect newFrame = CGRectMake(x, 0, width, rect.size.height);
        _subtitleSettingsScrollView.frame = newFrame;
        _subtitleSettingsScrollView.hidden = NO; // Ensure it's visible after auto-hide
        NSLog(@"📱 [SUBTITLE-PANEL] Subtitle settings scroll view already exists - making visible and updating frame");
    }
}

- (void)setupSubtitleSettingsContent {
    // Remove existing subviews
    for (UIView *subview in _subtitleSettingsScrollView.subviews) {
        [subview removeFromSuperview];
    }
    
    CGFloat padding = 20;
    CGFloat currentY = padding;
    CGFloat controlWidth = _subtitleSettingsScrollView.frame.size.width - (padding * 2);
    CGFloat controlHeight = 40;
    CGFloat spacing = 15;
    
    // Title
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 30)];
    titleLabel.text = @"Subtitle Settings";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [_subtitleSettingsScrollView addSubview:titleLabel];
    currentY += 30 + spacing;
    
    // Description
    UILabel *descLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 20)];
    descLabel.text = @"Move the slider to adjust subtitle text size in real-time";
    descLabel.textColor = [UIColor lightGrayColor];
    descLabel.font = [UIFont systemFontOfSize:12];
    [_subtitleSettingsScrollView addSubview:descLabel];
    currentY += 20 + spacing * 2;
    
    // Font Size Section
    _subtitleFontSizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 25)];
    _subtitleFontSizeLabel.text = @"Font Size: 16 px";
    _subtitleFontSizeLabel.textColor = [UIColor whiteColor];
    _subtitleFontSizeLabel.font = [UIFont boldSystemFontOfSize:16];
    [_subtitleSettingsScrollView addSubview:_subtitleFontSizeLabel];
    currentY += 25 + 10;
    
    // Font size slider (like macOS)
#if TARGET_OS_IOS
    _subtitleFontSizeSlider = [[UISlider alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, controlHeight)];
    _subtitleFontSizeSlider.minimumValue = 8;
    _subtitleFontSizeSlider.maximumValue = 32;
    _subtitleFontSizeSlider.value = 16;
    _subtitleFontSizeSlider.tintColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0];
    [_subtitleFontSizeSlider addTarget:self action:@selector(subtitleFontSizeChanged:) forControlEvents:UIControlEventValueChanged];
    [_subtitleSettingsScrollView addSubview:_subtitleFontSizeSlider];
#endif
    currentY += controlHeight + spacing * 2;
    
    // Additional subtitle options
    NSArray *subtitleOptions = @[
        @"Font Color",
        @"Background Color", 
        @"Position", 
        @"Language",
        @"Encoding"
    ];
    
    for (NSString *option in subtitleOptions) {
        UILabel *optionLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, currentY, controlWidth, 25)];
        optionLabel.text = option;
        optionLabel.textColor = [UIColor whiteColor];
        optionLabel.font = [UIFont boldSystemFontOfSize:14];
        [_subtitleSettingsScrollView addSubview:optionLabel];
        currentY += 25 + 5;
        
        UIButton *optionButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        optionButton.frame = CGRectMake(padding, currentY, controlWidth, 35);
        [optionButton setTitle:[NSString stringWithFormat:@"Configure %@", option] forState:UIControlStateNormal];
        [optionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        optionButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.3 blue:0.4 alpha:1.0];
        optionButton.layer.cornerRadius = 6;
        [optionButton addTarget:self action:@selector(subtitleOptionSelected:) forControlEvents:UIControlEventTouchUpInside];
        [_subtitleSettingsScrollView addSubview:optionButton];
        currentY += 35 + spacing;
    }
    
    // Set content size
    _subtitleSettingsScrollView.contentSize = CGSizeMake(_subtitleSettingsScrollView.frame.size.width, currentY + padding);
}

#if TARGET_OS_IOS
- (void)subtitleFontSizeChanged:(UISlider *)sender {
    NSInteger fontSize = (NSInteger)sender.value;
    _subtitleFontSizeLabel.text = [NSString stringWithFormat:@"Font Size: %ld px", (long)fontSize];
    NSLog(@"🔤 Subtitle font size changed to: %ld px", (long)fontSize);
    
    // TODO: Apply to VLC player immediately like macOS version
    // Example: [self.player.currentVideoSubTitleIndex setFont...];
}
#endif

- (void)subtitleOptionSelected:(UIButton *)sender {
    NSLog(@"🔧 Subtitle option selected: %@", sender.titleLabel.text);
    // TODO: Implement subtitle option dialogs
}
#endif // TARGET_OS_IOS - End of iOS subtitle settings

#pragma mark - iOS Gesture Handlers


#pragma mark - Program Guide Drawing (iOS/tvOS)

- (void)drawProgramGuideForChannelAtIndex:(NSInteger)channelIndex rect:(CGRect)rect {
    // Calculate responsive dimensions
    CGFloat categoryWidth = [self categoryWidth];
    CGFloat groupWidth = [self groupWidth];
    CGFloat programGuideWidth = [self programGuideWidth];
    
    // Calculate program guide area
    CGFloat channelListX = categoryWidth + groupWidth;
    CGFloat channelListWidth = rect.size.width - channelListX - programGuideWidth;
    CGFloat programGuideX = channelListX + channelListWidth;
    
    // Draw program guide background
    CGRect programGuideRect = CGRectMake(programGuideX, 0, programGuideWidth, rect.size.height);
    [[UIColor colorWithRed:0.1 green:0.1 blue:0.15 alpha:0.8] setFill];
    UIRectFill(programGuideRect);
    
    // Get channel data using the same method as macOS
    VLCChannel *channel = [self getChannelAtIndex:channelIndex];
    
    // Auto-trigger EPG loading if not loaded
    if (!self.isEpgLoaded && !self.isLoadingEpg) {
        // First, try to auto-generate EPG URL if missing
        if (!self.epgUrl || [self.epgUrl length] == 0) {
            NSLog(@"📺 [AUTO-EPG] No EPG URL found, trying to auto-generate...");
            [self autoGenerateEpgUrl];
        }
        
        // Now try to load EPG if we have a URL - but only once per app lifecycle
        static BOOL hasTriggeredAutoEPG = NO;
        static NSString *lastTriggeredURL = nil;
        
        // Check if we should trigger auto-EPG (only once per unique URL per app session)
        BOOL shouldTrigger = !hasTriggeredAutoEPG && 
                           self.epgUrl && 
                           [self.epgUrl length] > 0 &&
                           (lastTriggeredURL == nil || ![lastTriggeredURL isEqualToString:self.epgUrl]);
        
        if (shouldTrigger) {
            hasTriggeredAutoEPG = YES;
            lastTriggeredURL = [self.epgUrl copy];
            NSLog(@"📺 [AUTO-EPG] Triggering EPG loading via VLCDataManager (one-time auto-trigger for URL: %@)...", self.epgUrl);
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[VLCDataManager sharedManager] loadEPGFromURL:self.epgUrl];
            });
        } else if (hasTriggeredAutoEPG && self.epgUrl) {
            // Don't spam logs - only log once per 100 calls
            static NSInteger skipCount = 0;
            if (skipCount % 100 == 0) {
                NSLog(@"📺 [AUTO-EPG] 🚫 Skipping auto-trigger (already triggered for session)");
            }
            skipCount++;
        } else if (!self.epgUrl || [self.epgUrl length] == 0) {
            static NSInteger noUrlLogCount = 0;
            if (noUrlLogCount % 100 == 0) { // Reduce spam
                NSLog(@"📺 [AUTO-EPG] ❌ No EPG URL available and could not auto-generate from M3U URL");
            }
            noUrlLogCount++;
        }
    }
    
    if (!channel) {
        // Show "No program data available" message
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [UIColor lightGrayColor]
        };
        
        CGRect messageRect = CGRectMake(programGuideX + 20, rect.size.height / 2 - 10, programGuideWidth - 40, 20);
        [@"No program data available" drawInRect:messageRect withAttributes:attrs];
        return;
    }
    
    // Draw channel name at top
    NSDictionary *channelNameAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:16],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGRect channelNameRect = CGRectMake(programGuideX + 15, rect.size.height - 45, programGuideWidth - 30, 25);
    NSString *channelName = channel.name ?: @"Unknown Channel";
    [channelName drawInRect:channelNameRect withAttributes:channelNameAttrs];
    
    // Check if channel has EPG data
    if (!channel.programs || [channel.programs count] == 0) {
        // Show appropriate message based on EPG loading state
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [UIColor lightGrayColor]
        };
        
        CGRect messageRect = CGRectMake(programGuideX + 15, rect.size.height - 80, programGuideWidth - 30, 20);
        
        NSString *message;
        if (self.isEpgLoaded) {
            message = @"No program schedule available";
        } else if (self.isLoadingEpg) {
            message = @"Loading program guide...";
        } else {
            message = @"Program guide not loaded";
        }
        
        [message drawInRect:messageRect withAttributes:attrs];
        return;
    }
    
    // Sort programs by start time
    NSArray *sortedPrograms = [channel.programs sortedArrayUsingComparator:^NSComparisonResult(VLCProgram *a, VLCProgram *b) {
        return [a.startTime compare:b.startTime];
    }];
    
    // Get current time for highlighting current program
    NSDate *now = [NSDate date];
    NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600;
    NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
    
    // Find current program
    NSInteger currentProgramIndex = -1;
    for (NSInteger i = 0; i < sortedPrograms.count; i++) {
        VLCProgram *program = sortedPrograms[i];
        if ([adjustedNow timeIntervalSinceDate:program.startTime] >= 0 && 
            [adjustedNow timeIntervalSinceDate:program.endTime] < 0) {
            currentProgramIndex = i;
            break;
        }
    }
    
    // Check if we're playing timeshift content and get the timeshift playing program
    BOOL isTimeshiftPlaying = [self isCurrentlyPlayingTimeshift];
    VLCProgram *timeshiftPlayingProgram = nil;
    NSInteger timeshiftProgramIndex = -1;
    
    if (isTimeshiftPlaying) {
        // Get the program that's currently being played via timeshift
        timeshiftPlayingProgram = [self getCurrentTimeshiftPlayingProgram];
        
        // Find the index of the timeshift playing program
        if (timeshiftPlayingProgram && channel.programs) {
            for (NSInteger i = 0; i < channel.programs.count; i++) {
                VLCProgram *program = [channel.programs objectAtIndex:i];
                if ([program.title isEqualToString:timeshiftPlayingProgram.title] &&
                    [program.startTime isEqualToDate:timeshiftPlayingProgram.startTime]) {
                    timeshiftProgramIndex = i;
                    break;
                }
            }
        }
    }
    
    // Check if this channel is currently playing and get its live program
    VLCChannel *currentlyPlayingChannel = [self getCurrentlyPlayingChannel];
    VLCProgram *currentlyPlayingProgram = [self getCurrentlyPlayingProgram];
    NSInteger livePlayingProgramIndex = -1;
    BOOL isChannelCurrentlyPlaying = NO;
    
    if (currentlyPlayingChannel && [channel.name isEqualToString:currentlyPlayingChannel.name] && 
        currentlyPlayingProgram && !isTimeshiftPlaying) {
        isChannelCurrentlyPlaying = YES;
        
        // Find the index of the currently playing live program in sorted programs
        for (NSInteger i = 0; i < sortedPrograms.count; i++) {
            VLCProgram *program = sortedPrograms[i];
            if ([program.title isEqualToString:currentlyPlayingProgram.title] &&
                [program.startTime isEqualToDate:currentlyPlayingProgram.startTime]) {
                livePlayingProgramIndex = i;
                break;
            }
        }
    }
    
    // Calculate drawing parameters
    CGFloat programHeight = 60;
    CGFloat programSpacing = 5;
    CGFloat contentStartY = rect.size.height - 90; // Leave space for channel name
    CGFloat visibleHeight = contentStartY - 20; // Bottom margin
    
    // Calculate total content height for scrolling
    CGFloat totalContentHeight = sortedPrograms.count * (programHeight + programSpacing);
    CGFloat maxScrollPosition = MAX(0, totalContentHeight - visibleHeight);
    
    // Auto-scroll to current program when EPG first opens (center it in the view)
    static NSMutableDictionary *centeredChannels = nil;
    if (!centeredChannels) {
        centeredChannels = [[NSMutableDictionary alloc] init];
    }
    
    NSString *channelKey = [NSString stringWithFormat:@"%@_%ld", channel.name ?: @"unknown", (long)channel.programs.count];
    if (currentProgramIndex >= 0 && ![centeredChannels objectForKey:channelKey]) {
        // Calculate position to center the current program
        CGFloat currentProgramY = currentProgramIndex * (programHeight + programSpacing);
        CGFloat targetScrollPosition = currentProgramY - (visibleHeight / 2) + (programHeight / 2);
        targetScrollPosition = MAX(0, MIN(targetScrollPosition, maxScrollPosition));
        
        _programGuideScrollPosition = targetScrollPosition;
        [centeredChannels setObject:@YES forKey:channelKey];
        
        NSLog(@"📺 [EPG-CENTER] Auto-centered current program %ld at scroll position %.1f", (long)currentProgramIndex, targetScrollPosition);
    }
    
    // DEBUG: Log scroll calculations
    static NSInteger debugLogCount = 0;
    if (debugLogCount % 60 == 0) { // Log every 60 frames to avoid spam
        NSLog(@"📺 [EPG-SCROLL] Programs: %ld, ContentHeight: %.1f, VisibleHeight: %.1f, MaxScroll: %.1f, CurrentScroll: %.1f", 
              (long)sortedPrograms.count, totalContentHeight, visibleHeight, maxScrollPosition, _programGuideScrollPosition);
    }
    debugLogCount++;
    
    // Clamp scroll position
    _programGuideScrollPosition = MAX(0, MIN(_programGuideScrollPosition, maxScrollPosition));
    
    // Calculate which programs are visible based on scroll position
    NSInteger maxVisiblePrograms = (NSInteger)(visibleHeight / (programHeight + programSpacing)) + 2; // +2 for partial visibility
    NSInteger startIndex = MAX(0, (NSInteger)(_programGuideScrollPosition / (programHeight + programSpacing)));
    NSInteger endIndex = MIN(sortedPrograms.count, startIndex + maxVisiblePrograms);
    
    for (NSInteger i = startIndex; i < endIndex; i++) {
        VLCProgram *program = sortedPrograms[i];
        
        // Calculate Y position accounting for scroll position
        // FIXED: Past programs at top, future programs at bottom (normal order)
        CGFloat baseY = i * (programHeight + programSpacing);
        CGFloat programY = 20 + baseY - _programGuideScrollPosition; // Start from top, subtract scroll
        CGRect programRect = CGRectMake(programGuideX + 10, programY, programGuideWidth - 20, programHeight);
        
        // Skip if not visible (programs outside the visible area)
        if (programY + programHeight < 20 || programY > contentStartY) {
            continue;
        }
        
        // Determine program colors based on status (matching Mac version logic)
        UIColor *bgColor, *textColor, *timeColor, *borderColor = nil;
        BOOL isPastProgram = ([adjustedNow timeIntervalSinceDate:program.endTime] > 0);
        BOOL hasCatchup = [VLCProgram hasArchiveForProgramObject:program];
        BOOL channelSupportsCatchup = (channel.supportsCatchup || channel.catchupDays > 0);
        
        // Check if this program is selected in EPG navigation mode (iOS/tvOS)
        BOOL isSelectedInEpg = (self.epgNavigationMode && i == self.selectedEpgProgramIndex);
        
        if (isSelectedInEpg) {
            // Selected program gets bright focus highlighting (iOS/tvOS)
            bgColor = [UIColor colorWithRed:self.customSelectionRed green:self.customSelectionGreen blue:self.customSelectionBlue alpha:0.9];
            borderColor = [UIColor colorWithRed:self.customSelectionRed * 1.2 green:self.customSelectionGreen * 1.2 blue:self.customSelectionBlue * 1.2 alpha:1.0];
            textColor = [UIColor whiteColor];
            timeColor = [UIColor colorWithRed:1.0 green:1.0 blue:0.8 alpha:1.0];
        } else if (isTimeshiftPlaying && i == timeshiftProgramIndex) {
            // Timeshift playing program gets special orange/amber highlight (like Mac)
            bgColor = [UIColor colorWithRed:0.35 green:0.25 blue:0.10 alpha:0.7];
            borderColor = [UIColor colorWithRed:1.0 green:0.6 blue:0.2 alpha:0.9];
            textColor = [UIColor whiteColor];
            timeColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.4 alpha:1.0];
        } else if (isChannelCurrentlyPlaying && i == livePlayingProgramIndex) {
            // Live playing program gets bright red highlight (different from current time program)
            bgColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:0.8];
            borderColor = [UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0];
            textColor = [UIColor whiteColor];
            timeColor = [UIColor colorWithRed:1.0 green:0.9 blue:0.4 alpha:1.0];
        } else if (i == currentProgramIndex) {
            // Current live program - blue highlight
            if (hasCatchup || channelSupportsCatchup) {
                bgColor = [UIColor colorWithRed:0.15 green:0.35 blue:0.25 alpha:0.7]; // Green-blue tint for catchup
                borderColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.6 alpha:0.8];
        } else {
                bgColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.8 alpha:0.6]; // Standard blue
                borderColor = [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.7];
            }
            textColor = [UIColor whiteColor];
            timeColor = [UIColor colorWithRed:1.0 green:1.0 blue:0.8 alpha:1.0];
        } else if (isPastProgram && (hasCatchup || channelSupportsCatchup)) {
            // Past program with catchup available - GREEN like Mac version
            bgColor = [UIColor colorWithRed:0.10 green:0.30 blue:0.15 alpha:0.7]; // More prominent green
            borderColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.8]; // Green border like Mac
            textColor = [UIColor colorWithWhite:0.95 alpha:1.0]; // Brighter text
            timeColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0]; // Bright green time
        } else {
            // Other programs (future or past without catchup)
            bgColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:0.6];
            textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
            timeColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        }
        
        // Draw program background
        [bgColor setFill];
        UIBezierPath *programPath = [UIBezierPath bezierPathWithRoundedRect:programRect cornerRadius:6];
        [programPath fill];
        
        // Draw border for special programs
        if (borderColor) {
            [borderColor setStroke];
            // Make EPG selection border thicker for better visibility
            if (isSelectedInEpg) {
                programPath.lineWidth = 3.0; // Thick border for EPG selection
            } else {
                programPath.lineWidth = 1.5; // Normal border for other states
            }
            [programPath stroke];
        }
        
        // Draw program time
        NSString *timeString = [program formattedTimeRangeWithOffset:self.epgTimeOffsetHours];
        NSDictionary *timeAttrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:11],
            NSForegroundColorAttributeName: timeColor
        };
        
        CGRect timeRect = CGRectMake(programRect.origin.x + 8, 
                                   programRect.origin.y + programHeight - 18, 
                                   programRect.size.width - 16, 
                                   14);
        [timeString drawInRect:timeRect withAttributes:timeAttrs];
        
        // MOVIE/SERIES COVERS AND DESCRIPTIONS (like Mac version)
        BOOL isMovieOrSeries = (channel.category && ([channel.category isEqualToString:@"MOVIES"] || [channel.category isEqualToString:@"SERIES"]));
        
        if (isMovieOrSeries) {
            // Draw movie cover image if available (like Mac version)
            BOOL hasCoverImage = NO;
            CGFloat coverWidth = 40;
            CGFloat coverHeight = 56;
            CGRect coverRect = CGRectMake(programRect.origin.x + 8, 
                                        programRect.origin.y + 4, 
                                        coverWidth, 
                                        coverHeight);
            
            // Fetch movie info using shared Mac methods
            if (!channel.hasLoadedMovieInfo && !channel.hasStartedFetchingMovieInfo) {
                // Try cache first, then fetch from network if needed (using shared Mac implementation)
                [self fetchMovieInfoForChannel:channel];
            }
            
            // Try to display cached poster image
            if (channel.cachedPosterImage) {
                [channel.cachedPosterImage drawInRect:coverRect];
                hasCoverImage = YES;
                
                // Draw subtle border around image
                [[UIColor colorWithWhite:0.3 alpha:0.8] setStroke];
                UIBezierPath *borderPath = [UIBezierPath bezierPathWithRoundedRect:coverRect cornerRadius:3];
                borderPath.lineWidth = 1.0;
                [borderPath stroke];
            }
            
            if (!hasCoverImage) {
                // Draw placeholder cover for movies/series
                [[UIColor colorWithRed:0.2 green:0.2 blue:0.25 alpha:0.8] setFill];
                UIBezierPath *placeholderPath = [UIBezierPath bezierPathWithRoundedRect:coverRect cornerRadius:3];
                [placeholderPath fill];
                
                // Draw film icon
                NSDictionary *iconAttrs = @{
                    NSFontAttributeName: [UIFont systemFontOfSize:20],
                    NSForegroundColorAttributeName: [UIColor colorWithWhite:0.6 alpha:1.0]
                };
                NSString *icon = [channel.category isEqualToString:@"MOVIES"] ? @"🎬" : @"📺";
                CGRect iconRect = CGRectMake(coverRect.origin.x + 8, 
                                           coverRect.origin.y + 16, 
                                           24, 24);
                [icon drawInRect:iconRect withAttributes:iconAttrs];
            }
            
            // Adjust title and description layout for movies with covers
            CGFloat textStartX = programRect.origin.x + coverWidth + 16;
            CGFloat textWidth = programRect.size.width - coverWidth - 24;
            
            // Draw program title (movie/series title)
            NSString *title = program.title ?: channel.name ?: @"Unknown";
            if (title.length > 25) {
                title = [[title substringToIndex:22] stringByAppendingString:@"..."];
            }
            
            NSDictionary *titleAttrs = @{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:13],
                NSForegroundColorAttributeName: textColor
            };
            
            CGRect titleRect = CGRectMake(textStartX, 
                                        programRect.origin.y + 6, 
                                        textWidth, 
                                        16);
            [title drawInRect:titleRect withAttributes:titleAttrs];
            
            // Draw movie info (year, rating, etc.) from channel properties
            if (channel.hasLoadedMovieInfo) {
                NSMutableString *infoString = [NSMutableString string];
                
                if (channel.movieYear) [infoString appendString:channel.movieYear];
                if (channel.movieRating && ![channel.movieRating isEqualToString:@"N/A"]) {
                    if (infoString.length > 0) [infoString appendString:@" • "];
                    [infoString appendString:channel.movieRating];
                }
                if (channel.movieGenre && ![channel.movieGenre isEqualToString:@"N/A"] && infoString.length < 20) {
                    if (infoString.length > 0) [infoString appendString:@" • "];
                    [infoString appendString:channel.movieGenre];
                }
                
                if (infoString.length > 0) {
                    NSDictionary *infoAttrs = @{
                        NSFontAttributeName: [UIFont systemFontOfSize:10],
                        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.7 alpha:1.0]
                    };
                    
                    CGRect infoRect = CGRectMake(textStartX, 
                                               programRect.origin.y + 24, 
                                               textWidth, 
                                               12);
                    [infoString drawInRect:infoRect withAttributes:infoAttrs];
                }
                
                // Draw movie description if available
                NSString *desc = channel.movieDescription;
                if (!desc || [desc isEqualToString:@"N/A"]) {
                    desc = program.description;
                }
                
                if (desc && desc.length > 0) {
                    if (desc.length > 40) {
                        desc = [[desc substringToIndex:37] stringByAppendingString:@"..."];
                    }
                    
                    NSDictionary *descAttrs = @{
                        NSFontAttributeName: [UIFont systemFontOfSize:9],
                        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1.0]
                    };
                    
                    CGRect descRect = CGRectMake(textStartX, 
                                               programRect.origin.y + 38, 
                                               textWidth, 
                                               12);
                    [desc drawInRect:descRect withAttributes:descAttrs];
                }
            } else {
                // No movie info - just draw description if available
                if (program.description && program.description.length > 0) {
                    NSString *desc = program.description;
                    if (desc.length > 40) {
                        desc = [[desc substringToIndex:37] stringByAppendingString:@"..."];
                    }
                    
                    NSDictionary *descAttrs = @{
                        NSFontAttributeName: [UIFont systemFontOfSize:10],
                        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1.0]
                    };
                    
                    CGRect descRect = CGRectMake(textStartX, 
                                               programRect.origin.y + 24, 
                                               textWidth, 
                                               14);
                    [desc drawInRect:descRect withAttributes:descAttrs];
                }
            }
        } else {
            // Regular TV channels - original layout
            // Draw program title
            NSString *title = program.title ?: @"Unknown Program";
            if (title.length > 30) {
                title = [[title substringToIndex:27] stringByAppendingString:@"..."];
            }
            
            NSDictionary *titleAttrs = @{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:13],
                NSForegroundColorAttributeName: textColor
            };
            
            CGRect titleRect = CGRectMake(programRect.origin.x + 8, 
                                        programRect.origin.y + 8, 
                                        programRect.size.width - 16, 
                                        18);
            [title drawInRect:titleRect withAttributes:titleAttrs];
            
            // Draw program description if available
            if (program.description && program.description.length > 0) {
                NSString *desc = program.description;
                if (desc.length > 50) {
                    desc = [[desc substringToIndex:47] stringByAppendingString:@"..."];
                }
                
                NSDictionary *descAttrs = @{
                    NSFontAttributeName: [UIFont systemFontOfSize:10],
                    NSForegroundColorAttributeName: [UIColor colorWithWhite:0.8 alpha:1.0]
                };
                
                CGRect descRect = CGRectMake(programRect.origin.x + 8, 
                                           programRect.origin.y + 28, 
                                           programRect.size.width - 16, 
                                           14);
                [desc drawInRect:descRect withAttributes:descAttrs];
            }
        }
        
        // Draw catchup indicator if program has archive OR channel supports catchup (like Mac version)
        if ([VLCProgram hasArchiveForProgramObject:program] || (channelSupportsCatchup && isPastProgram)) {
            CGFloat catchupSize = 20; // Smaller, more subtle size
            CGRect catchupRect = CGRectMake(programRect.origin.x + programRect.size.width - catchupSize - 8,
                                          programRect.origin.y + 8,
                                          catchupSize, 
                                          catchupSize);
            
            // Rewind symbol directly without background
            UIColor *symbolColor = isPastProgram ? 
                [UIColor colorWithRed:0.2 green:0.7 blue:0.4 alpha:1.0] :  // Green for past programs
                [UIColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:1.0];   // Blue for current programs
            
            NSDictionary *symbolAttrs = @{
                NSFontAttributeName: [UIFont systemFontOfSize:16],
                NSForegroundColorAttributeName: symbolColor
            };
            
            [@"⏪" drawInRect:catchupRect withAttributes:symbolAttrs];
        }
        
        // Draw progress bar for current program
        if (i == currentProgramIndex) {
            NSTimeInterval totalDuration = [program.endTime timeIntervalSinceDate:program.startTime];
            NSTimeInterval elapsed = [adjustedNow timeIntervalSinceDate:program.startTime];
            CGFloat progress = totalDuration > 0 ? (elapsed / totalDuration) : 0;
            progress = MAX(0, MIN(progress, 1.0));
            
            CGFloat progressBarHeight = 2;
            CGRect progressBg = CGRectMake(programRect.origin.x + 8, 
                                         programRect.origin.y + programHeight - 6, 
                                         programRect.size.width - 16, 
                                         progressBarHeight);
            
            // Background
            [[UIColor colorWithWhite:0.3 alpha:0.8] setFill];
            UIRectFill(progressBg);
            
            // Progress
            CGRect progressFill = CGRectMake(progressBg.origin.x, 
                                           progressBg.origin.y, 
                                           progressBg.size.width * progress, 
                                           progressBarHeight);
            
            UIColor *progressColor;
            if (progress < 0.25) {
                progressColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.3 alpha:1.0]; // Green
            } else if (progress < 0.75) {
                progressColor = [UIColor colorWithRed:0.3 green:0.6 blue:1.0 alpha:1.0]; // Blue
            } else {
                progressColor = [UIColor colorWithRed:1.0 green:0.4 blue:0.2 alpha:1.0]; // Red
            }
            [progressColor setFill];
            UIRectFill(progressFill);
        }
    }
}

#pragma mark - Channel Data Helpers

- (VLCChannel *)getChannelAtIndex:(NSInteger)channelIndex {
    NSArray *channels = [self getChannelsForCurrentGroup];
    if (channelIndex < 0 || channelIndex >= channels.count) {
        return nil;
    }
    
    id channelObject = channels[channelIndex];
    if ([channelObject isKindOfClass:[VLCChannel class]]) {
        return (VLCChannel *)channelObject;
    }
    
    return nil;
}

- (VLCChannel *)getCurrentChannel {
    return [self getChannelAtIndex:_selectedChannelIndex];
}

#pragma mark - Theme Action Handlers (iOS)

// Old theme button handlers removed - using new dropdown system

#pragma mark - iOS Theme System

- (void)initializeThemeSystemiOS {
    NSLog(@"🎨 Initializing iOS theme system");
    
    // Set default theme values
    self.currentTheme = VLC_THEME_DARK;
    self.themeAlpha = 0.8;
    self.customThemeRed = 0.10;
    self.customThemeGreen = 0.12;
    self.customThemeBlue = 0.16;
    self.customSelectionRed = 0.2;
    self.customSelectionGreen = 0.4;
    self.customSelectionBlue = 0.9;
    
    // Set default glassmorphism values
    self.glassmorphismEnabled = YES;
    self.glassmorphismIntensity = 1.0;
    self.glassmorphismHighQuality = NO;
    
    // Initialize advanced glassmorphism controls (matching macOS defaults)
    self.glassmorphismOpacity = 0.6;
    self.glassmorphismBlurRadius = 25.0;
    self.glassmorphismBorderWidth = 1.0;
    self.glassmorphismCornerRadius = 8.0;
    self.glassmorphismIgnoreTransparency = NO;
    self.glassmorphismSandedIntensity = 0.0;
    
    // Apply default theme
    [self updateThemeColorsiOS];
    
    NSLog(@"🎨 iOS theme system initialized with default dark theme");
}

- (void)updateSelectionColorsToCurrentTheme {
    // This method applies the selection colors to all UI elements that use them
    // Similar to macOS updateSelectionColors method
    
    NSLog(@"🎯 Updating selection colors: R:%.2f G:%.2f B:%.2f", 
          self.customSelectionRed, self.customSelectionGreen, self.customSelectionBlue);
    
    // Force redraw to apply new selection colors to buttons and highlights
    [self setNeedsDisplay];
}

- (void)applyThemeiOS:(VLCColorTheme)theme {
    self.currentTheme = theme;
    [self updateThemeColorsiOS];
    [self setNeedsDisplay];
    NSLog(@"🎨 Applied iOS theme: %ld", (long)theme);
}

- (void)updateThemeColorsiOS {
    CGFloat alpha = self.themeAlpha ?: 0.8;
    
    switch (self.currentTheme) {
        case VLC_THEME_DARK:
            // Default dark theme (current colors)
            self.themeCategoryStartColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.14 alpha:alpha];
            self.themeCategoryEndColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:alpha];
            self.themeChannelStartColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:alpha];
            self.themeChannelEndColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.18 alpha:alpha];
            break;
            
        case VLC_THEME_DARKER:
            // Even darker theme
            self.themeCategoryStartColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.05 alpha:alpha];
            self.themeCategoryEndColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:alpha];
            self.themeChannelStartColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:alpha];
            self.themeChannelEndColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.10 alpha:alpha];
            break;
            
        case VLC_THEME_BLUE:
            // Blue accent theme
            self.themeCategoryStartColor = [UIColor colorWithRed:0.05 green:0.08 blue:0.15 alpha:alpha];
            self.themeCategoryEndColor = [UIColor colorWithRed:0.08 green:0.12 blue:0.20 alpha:alpha];
            self.themeChannelStartColor = [UIColor colorWithRed:0.08 green:0.12 blue:0.20 alpha:alpha];
            self.themeChannelEndColor = [UIColor colorWithRed:0.10 green:0.15 blue:0.25 alpha:alpha];
            break;
            
        case VLC_THEME_GREEN:
            // Green accent theme
            self.themeCategoryStartColor = [UIColor colorWithRed:0.05 green:0.12 blue:0.08 alpha:alpha];
            self.themeCategoryEndColor = [UIColor colorWithRed:0.08 green:0.16 blue:0.12 alpha:alpha];
            self.themeChannelStartColor = [UIColor colorWithRed:0.08 green:0.16 blue:0.12 alpha:alpha];
            self.themeChannelEndColor = [UIColor colorWithRed:0.10 green:0.20 blue:0.15 alpha:alpha];
            break;
            
        case VLC_THEME_PURPLE:
            // Purple accent theme
            self.themeCategoryStartColor = [UIColor colorWithRed:0.12 green:0.08 blue:0.15 alpha:alpha];
            self.themeCategoryEndColor = [UIColor colorWithRed:0.16 green:0.12 blue:0.20 alpha:alpha];
            self.themeChannelStartColor = [UIColor colorWithRed:0.16 green:0.12 blue:0.20 alpha:alpha];
            self.themeChannelEndColor = [UIColor colorWithRed:0.20 green:0.15 blue:0.25 alpha:alpha];
            break;
            
        case VLC_THEME_CUSTOM:
            // Custom theme - use user-defined RGB values
            CGFloat baseR = self.customThemeRed ?: 0.10;
            CGFloat baseG = self.customThemeGreen ?: 0.12;
            CGFloat baseB = self.customThemeBlue ?: 0.16;
            
            // Create gradient variations using the base custom color
            self.themeCategoryStartColor = [UIColor colorWithRed:baseR * 0.8 green:baseG * 0.8 blue:baseB * 0.8 alpha:alpha];
            self.themeCategoryEndColor = [UIColor colorWithRed:baseR green:baseG blue:baseB alpha:alpha];
            self.themeChannelStartColor = [UIColor colorWithRed:baseR green:baseG blue:baseB alpha:alpha];
            self.themeChannelEndColor = [UIColor colorWithRed:baseR * 1.2 green:baseG * 1.2 blue:baseB * 1.2 alpha:alpha];
            break;
            
        default:
            // Fall back to dark theme
            self.themeCategoryStartColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.14 alpha:alpha];
            self.themeCategoryEndColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:alpha];
            self.themeChannelStartColor = [UIColor colorWithRed:0.10 green:0.12 blue:0.16 alpha:alpha];
            self.themeChannelEndColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.18 alpha:alpha];
            break;
    }
    
    NSLog(@"🎨 Updated iOS theme colors for theme: %ld", (long)self.currentTheme);
}

// Old custom theme control methods removed - functionality moved to setupThemeSettingsContent with new dropdown system

#pragma mark - tvOS Selection Methods

#if TARGET_OS_TV
- (void)showTVOSTimeOffsetSelection {
    NSLog(@"📺 tvOS Time offset selection");
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"EPG Time Offset"
                                                                             message:@"Select time offset for EPG data"
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *timeOffsets = @[@(-12.0), @(-6.0), @(-3.0), @(-1.0), @(0.0), @(1.0), @(3.0), @(6.0), @(12.0)];
    NSArray *timeLabels = @[@"-12 hours", @"-6 hours", @"-3 hours", @"-1 hour", @"No offset", @"+1 hour", @"+3 hours", @"+6 hours", @"+12 hours"];
    
    for (NSInteger i = 0; i < timeOffsets.count; i++) {
        NSNumber *offset = timeOffsets[i];
        NSString *label = timeLabels[i];
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.epgTimeOffsetHours = offset.doubleValue;
            [self saveSettings];
            NSLog(@"📺 Time offset set to: %.1f hours", self.epgTimeOffsetHours);
            [self setNeedsDisplay];
        }];
        
        // Mark current selection
        if (fabs(self.epgTimeOffsetHours - offset.doubleValue) < 0.1) {
            action.accessibilityLabel = [NSString stringWithFormat:@"%@ (Current)", label];
        }
        
        [alertController addAction:action];
    }
    
    // Cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alertController addAction:cancelAction];
    
    // Present the alert
    UIViewController *topViewController = [self topViewController];
    if (topViewController) {
        [topViewController presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)showTVOSThemeSelection {
    //NSLog(@"📺 tvOS Theme selection");
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Select Theme"
                                                                             message:@"Choose a color theme"
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *themeValues = @[@(VLC_THEME_DARK), @(VLC_THEME_DARKER), @(VLC_THEME_BLUE), @(VLC_THEME_GREEN), @(VLC_THEME_PURPLE), @(VLC_THEME_CUSTOM)];
    NSArray *themeNames = @[@"Dark", @"Darker", @"Blue", @"Green", @"Purple", @"Custom"];
    
    for (NSInteger i = 0; i < themeValues.count; i++) {
        VLCColorTheme theme = ((NSNumber *)themeValues[i]).integerValue;
        NSString *name = themeNames[i];
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self applyThemeiOS:theme];
            [self saveSettings];
            //NSLog(@"📺 Theme set to: %@", name);
        }];
        
        // Mark current selection
        if (self.currentTheme == theme) {
            action.accessibilityLabel = [NSString stringWithFormat:@"%@ (Current)", name];
        }
        
        [alertController addAction:action];
    }
    
    // Cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alertController addAction:cancelAction];
    
    // Present the alert
    UIViewController *topViewController = [self topViewController];
    if (topViewController) {
        [topViewController presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)showTVOSTransparencySelection {
    //NSLog(@"📺 tvOS Transparency selection");
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Transparency"
                                                                             message:@"Select transparency level"
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *transparencyValues = @[@(0.3), @(0.5), @(0.7), @(0.8), @(0.9), @(1.0)];
    NSArray *transparencyLabels = @[@"30%", @"50%", @"70%", @"80%", @"90%", @"100% (Opaque)"];
    
    for (NSInteger i = 0; i < transparencyValues.count; i++) {
        NSNumber *transparency = transparencyValues[i];
        NSString *label = transparencyLabels[i];
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.themeAlpha = transparency.doubleValue;
            [self updateThemeColorsiOS];
            [self saveSettings];
            //NSLog(@"📺 Transparency set to: %.0f%%", transparency.doubleValue * 100);
            [self setNeedsDisplay];
        }];
        
        // Mark current selection
        if (fabs((self.themeAlpha ?: 0.8) - transparency.doubleValue) < 0.05) {
            action.accessibilityLabel = [NSString stringWithFormat:@"%@ (Current)", label];
        }
        
        [alertController addAction:action];
    }
    
    // Cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alertController addAction:cancelAction];
    
    // Present the alert
    UIViewController *topViewController = [self topViewController];
    if (topViewController) {
        [topViewController presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)showTVOSSelectionColorSelection:(NSString *)colorName component:(NSInteger)component {
    //NSLog(@"📺 tvOS Selection color selection: %@", colorName);
    
    NSString *title = [NSString stringWithFormat:@"Selection %@", colorName];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title
                                                                             message:@"Select color intensity"
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *colorValues = @[@(0.0), @(0.1), @(0.2), @(0.3), @(0.4), @(0.5), @(0.6), @(0.7), @(0.8), @(0.9), @(1.0)];
    
    for (NSNumber *value in colorValues) {
        NSString *label = [NSString stringWithFormat:@"%.0f%%", value.doubleValue * 100];
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            switch (component) {
                case 0: // Red
                    self.customSelectionRed = value.doubleValue;
                    break;
                case 1: // Green
                    self.customSelectionGreen = value.doubleValue;
                    break;
                case 2: // Blue
                    self.customSelectionBlue = value.doubleValue;
                    break;
            }
            [self updateSelectionColorsToCurrentTheme];
            [self saveSettings];
            //NSLog(@"📺 Selection %@ set to: %.0f%%", colorName, value.doubleValue * 100);
        }];
        
        // Mark current selection
        CGFloat currentValue = 0;
        switch (component) {
            case 0: currentValue = self.customSelectionRed ?: 0.2; break;
            case 1: currentValue = self.customSelectionGreen ?: 0.4; break;
            case 2: currentValue = self.customSelectionBlue ?: 0.9; break;
        }
        
        if (fabs(currentValue - value.doubleValue) < 0.05) {
            action.accessibilityLabel = [NSString stringWithFormat:@"%@ (Current)", label];
        }
        
        [alertController addAction:action];
    }
    
    // Cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alertController addAction:cancelAction];
    
    // Present the alert
    UIViewController *topViewController = [self topViewController];
    if (topViewController) {
        [topViewController presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)toggleTVOSGlassmorphism {
    self.glassmorphismEnabled = !self.glassmorphismEnabled;
    [self saveSettings];
    //NSLog(@"📺 Glassmorphism %@", self.glassmorphismEnabled ? @"enabled" : @"disabled");
    [self setNeedsDisplay];
}

- (void)showTVOSGlassmorphismIntensitySelection {
    //NSLog(@"📺 tvOS Glassmorphism intensity selection");
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Glassmorphism Intensity"
                                                                             message:@"Select glassmorphism effect intensity"
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *intensityValues = @[@(0.0), @(0.25), @(0.5), @(0.75), @(1.0), @(1.25), @(1.5), @(2.0)];
    NSArray *intensityLabels = @[@"Off", @"Light", @"Medium", @"Strong", @"Full", @"Enhanced", @"Maximum", @"Extreme"];
    
    for (NSInteger i = 0; i < intensityValues.count; i++) {
        NSNumber *intensity = intensityValues[i];
        NSString *label = intensityLabels[i];
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.glassmorphismIntensity = intensity.doubleValue;
            if (intensity.doubleValue > 0) {
                self.glassmorphismEnabled = YES;
            }
            [self saveSettings];
            //NSLog(@"📺 Glassmorphism intensity set to: %.2f", self.glassmorphismIntensity);
            [self setNeedsDisplay];
        }];
        
        // Mark current selection
        if (fabs((self.glassmorphismIntensity ?: 1.0) - intensity.doubleValue) < 0.1) {
            action.accessibilityLabel = [NSString stringWithFormat:@"%@ (Current)", label];
        }
        
        [alertController addAction:action];
    }
    
    // Cancel action
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alertController addAction:cancelAction];
    
    // Present the alert
    UIViewController *topViewController = [self topViewController];
    if (topViewController) {
        [topViewController presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)resetTVOSThemeSettings {
    //NSLog(@"📺 tvOS Reset theme settings");
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Reset Theme Settings"
                                                                             message:@"This will reset all theme settings to defaults"
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *resetAction = [UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        // Reset to defaults
        [self initializeThemeSystemiOS];
        [self saveSettings];
        //NSLog(@"📺 Theme settings reset to defaults");
        [self setNeedsDisplay];
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    
    [alertController addAction:resetAction];
    [alertController addAction:cancelAction];
    
    // Present the alert
    UIViewController *topViewController = [self topViewController];
    if (topViewController) {
        [topViewController presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)drawTVOSThemeSettings:(CGRect)rect x:(CGFloat)x width:(CGFloat)width {
    CGFloat padding = 20;
    CGFloat startY = rect.size.height - 80;
    CGFloat lineHeight = 25;
    CGFloat controlHeight = 35;
    CGFloat spacing = 15;
    
    // Title
    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:18],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    CGRect titleRect = CGRectMake(x + padding, startY, width - (padding * 2), lineHeight);
    [@"Theme Settings" drawInRect:titleRect withAttributes:titleAttrs];
    
    CGFloat currentY = startY - 50;
    NSInteger controlIndex = 0;
    
    // Control 0: Theme Selection
    NSString *currentThemeName = [self getCurrentThemeDisplayTextiOS];
    [self drawTVOSControl:controlIndex
                    label:@"Theme:"
                    value:currentThemeName
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 1: Transparency
    NSString *transparencyText = [NSString stringWithFormat:@"%.0f%%", (self.themeAlpha ?: 0.8) * 100];
    [self drawTVOSControl:controlIndex
                    label:@"Transparency:"
                    value:transparencyText
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 2: Selection Red
    NSString *redText = [NSString stringWithFormat:@"%.0f%%", (self.customSelectionRed ?: 0.2) * 100];
    [self drawTVOSControl:controlIndex
                    label:@"Selection Red:"
                    value:redText
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 3: Selection Green
    NSString *greenText = [NSString stringWithFormat:@"%.0f%%", (self.customSelectionGreen ?: 0.4) * 100];
    [self drawTVOSControl:controlIndex
                    label:@"Selection Green:"
                    value:greenText
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 4: Selection Blue
    NSString *blueText = [NSString stringWithFormat:@"%.0f%%", (self.customSelectionBlue ?: 0.9) * 100];
    [self drawTVOSControl:controlIndex
                    label:@"Selection Blue:"
                    value:blueText
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 5: Glassmorphism Toggle
    NSString *glassmorphismText = self.glassmorphismEnabled ? @"Enabled" : @"Disabled";
    [self drawTVOSControl:controlIndex
                    label:@"Glassmorphism:"
                    value:glassmorphismText
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 6: Glassmorphism Intensity
    NSString *intensityText = [NSString stringWithFormat:@"%.1f", self.glassmorphismIntensity ?: 1.0];
    [self drawTVOSControl:controlIndex
                    label:@"Intensity:"
                    value:intensityText
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
    currentY -= controlHeight + spacing;
    controlIndex++;
    
    // Control 7: Reset Button
    [self drawTVOSControl:controlIndex
                    label:@"Reset to Defaults"
                    value:@"Press to reset"
                    rect:CGRectMake(x + padding, currentY, width - (padding * 2), controlHeight)
                 selected:(_tvosNavigationArea == 3 && _tvosSelectedSettingsControl == controlIndex)];
}
#endif

#pragma mark - tvOS EPG Navigation Helpers

- (void)initializeEpgNavigation {
    VLCChannel *channel = [self getChannelAtIndex:_selectedChannelIndex];
    if (!channel || !channel.programs || channel.programs.count == 0) return;
    
    // Enable EPG navigation mode
    self.epgNavigationMode = YES;
    
    // Find current program index to start selection there
    NSDate *now = [NSDate date];
    NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600;
    NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
    
    // Sort programs by start time
    NSArray *sortedPrograms = [channel.programs sortedArrayUsingComparator:^NSComparisonResult(VLCProgram *a, VLCProgram *b) {
        return [a.startTime compare:b.startTime];
    }];
    
    // Find current program
    NSInteger currentProgramIndex = -1;
    for (NSInteger i = 0; i < sortedPrograms.count; i++) {
        VLCProgram *program = sortedPrograms[i];
        if ([adjustedNow timeIntervalSinceDate:program.startTime] >= 0 && 
            [adjustedNow timeIntervalSinceDate:program.endTime] < 0) {
            currentProgramIndex = i;
            break;
        }
    }
    
    // Start at current program, or first program if no current program found
    self.selectedEpgProgramIndex = (currentProgramIndex >= 0) ? currentProgramIndex : 0;
    
    NSLog(@"📺 [EPG-INIT] Started EPG navigation at program index: %ld (current program: %ld)", 
          (long)self.selectedEpgProgramIndex, (long)currentProgramIndex);
    
    // Scroll to show the selected program
    [self scrollToSelectedEpgProgram];
    [self setNeedsDisplay];
}

- (void)scrollToSelectedEpgProgram {
    VLCChannel *channel = [self getChannelAtIndex:_selectedChannelIndex];
    if (!channel || !channel.programs || channel.programs.count == 0) return;
    
    CGFloat programHeight = 60;
    CGFloat programSpacing = 5;
    CGFloat visibleHeight = self.bounds.size.height - 110; // Account for margins
    
    // Calculate position of selected program
    CGFloat selectedProgramY = self.selectedEpgProgramIndex * (programHeight + programSpacing);
    
    // Calculate scroll position to center the selected program
    CGFloat targetScrollPosition = selectedProgramY - (visibleHeight / 2) + (programHeight / 2);
    
    // Calculate max scroll position
    CGFloat totalContentHeight = channel.programs.count * (programHeight + programSpacing);
    CGFloat maxScrollPosition = MAX(0, totalContentHeight - visibleHeight);
    
    // Clamp scroll position
    _programGuideScrollPosition = MAX(0, MIN(targetScrollPosition, maxScrollPosition));
    
    NSLog(@"📺 [EPG-SCROLL] Scrolled to program %ld, scroll position: %.1f", 
          (long)self.selectedEpgProgramIndex, _programGuideScrollPosition);
}

- (void)handleTVOSEpgProgramSelection {
    if (!self.epgNavigationMode) return;
    
    VLCChannel *channel = [self getChannelAtIndex:_selectedChannelIndex];
    if (!channel || !channel.programs || channel.programs.count == 0) return;
    
    if (self.selectedEpgProgramIndex < 0 || self.selectedEpgProgramIndex >= channel.programs.count) return;
    
    // Sort programs by start time to match the display order
    NSArray *sortedPrograms = [channel.programs sortedArrayUsingComparator:^NSComparisonResult(VLCProgram *a, VLCProgram *b) {
        return [a.startTime compare:b.startTime];
    }];
    
    VLCProgram *selectedProgram = sortedPrograms[self.selectedEpgProgramIndex];
    
    NSLog(@"📺 [EPG-SELECT] Selected program: %@ at %@", 
          selectedProgram.title, selectedProgram.startTime);
    
    // Check if this is a past program with catchup available
    NSDate *now = [NSDate date];
    NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600;
    NSDate *adjustedNow = [now dateByAddingTimeInterval:offsetSeconds];
    BOOL isPastProgram = ([adjustedNow timeIntervalSinceDate:selectedProgram.endTime] > 0);
    BOOL hasCatchup = ([VLCProgram hasArchiveForProgramObject:selectedProgram] || channel.supportsCatchup || channel.catchupDays > 0);
    
    if (isPastProgram && hasCatchup) {
        // IMPLEMENTED: Timeshift playback for past program with catchup
        NSLog(@"📺 [EPG-SELECT] ⏱ Starting timeshift playback for past program with catchup");
        [self playTimeshiftProgram:selectedProgram channel:channel];
    } else if (!isPastProgram) {
        // Future program - just play the channel normally  
        NSLog(@"📺 [EPG-SELECT] ▶️ Playing channel for future/current program");
        [self playChannelAtIndex:_selectedChannelIndex];
    } else {
        // Past program without catchup
        NSLog(@"📺 [EPG-SELECT] ❌ Past program without catchup - playing current channel");
        [self playChannelAtIndex:_selectedChannelIndex];
    }
    
    // Hide menu after selection
    _isChannelListVisible = NO;
    self.epgNavigationMode = NO;
    [self setNeedsDisplay];
}

#pragma mark - Catchup/Timeshift Playback

- (void)playTimeshiftProgram:(VLCProgram *)program channel:(VLCChannel *)channel {
    if (!program || !channel) {
        //NSLog(@"❌ [TIMESHIFT] Invalid program or channel");
        [self playChannelAtIndex:_selectedChannelIndex];
        return;
    }
    
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] Starting playback for program: '%@' on channel: '%@'", program.title, channel.name);
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] Program start: %@, end: %@", program.startTime, program.endTime);
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] Channel supports catchup: %@, catchup days: %ld", 
    //      channel.supportsCatchup ? @"YES" : @"NO", (long)channel.catchupDays);
    
    // Get timeshift manager from data manager  
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] dataManager: %@", self.dataManager);
    VLCTimeshiftManager *timeshiftManager = self.dataManager.timeshiftManager;
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] timeshiftManager: %@", timeshiftManager);
    
    if (!timeshiftManager) {
        //NSLog(@"❌ [TIMESHIFT] No timeshift manager available (dataManager: %@)", self.dataManager);
        
        // Try to create and use the shared manager directly as fallback
        VLCDataManager *sharedDataManager = [VLCDataManager sharedManager];
        //NSLog(@"🔍 [TIMESHIFT-DEBUG] sharedDataManager: %@", sharedDataManager);
        timeshiftManager = sharedDataManager.timeshiftManager;
        //NSLog(@"🔍 [TIMESHIFT-DEBUG] Using shared manager - timeshiftManager: %@", timeshiftManager);
        
        if (!timeshiftManager) {
            //NSLog(@"❌ [TIMESHIFT] Even shared manager has no timeshift manager - fallback to regular playback");
            [self playChannelAtIndex:_selectedChannelIndex];
            return;
        }
    }
    
    // Calculate time offset based on EPG time offset
    NSTimeInterval offsetSeconds = -self.epgTimeOffsetHours * 3600;
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] EPG time offset: %.1f hours = %.0f seconds", self.epgTimeOffsetHours, offsetSeconds);
    
    // Generate timeshift URL for the specific program
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] Calling generateTimeshiftURLForProgram...");
    NSString *timeshiftURL = [timeshiftManager generateTimeshiftURLForProgram:program
                                                                      channel:channel
                                                                   timeOffset:offsetSeconds];
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] Generated timeshift URL: '%@'", timeshiftURL ?: @"(nil)");
    
    if (!timeshiftURL || timeshiftURL.length == 0) {
        //NSLog(@"❌ [TIMESHIFT] Failed to generate timeshift URL for program: %@", program.title);
        //NSLog(@"❌ [TIMESHIFT] Possible reasons: No catchup support, invalid URL format, or API issue");
        // Fallback to regular channel playback
        [self playChannelAtIndex:_selectedChannelIndex];
        return;
    }
    
    //NSLog(@"✅ [TIMESHIFT] Generated timeshift URL for program '%@': %@", program.title, timeshiftURL);
    
    // Create a temporary channel with the timeshift URL
    VLCChannel *timeshiftChannel = [[VLCChannel alloc] init];
    timeshiftChannel.name = [NSString stringWithFormat:@"📺 %@ - %@", channel.name, program.title];
    timeshiftChannel.url = timeshiftURL;
    timeshiftChannel.logo = channel.logo;
    timeshiftChannel.category = channel.category;
    timeshiftChannel.group = channel.group;
    timeshiftChannel.channelId = channel.channelId;
    timeshiftChannel.supportsCatchup = channel.supportsCatchup;
    timeshiftChannel.catchupDays = channel.catchupDays;
    
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] Created timeshift channel: name='%@', url='%@'", timeshiftChannel.name, timeshiftChannel.url);
    
    // Play the timeshift channel directly using the URL
    //NSLog(@"🔍 [TIMESHIFT-DEBUG] Starting playback with timeshift URL...");
    [self playChannelWithUrl:timeshiftChannel.url];
    
    //NSLog(@"📺 [TIMESHIFT] ✅ Started timeshift playback for program '%@' at %@", 
          //program.title, program.startTime);
}

// Helper method to check if a group has channels with catch-up functionality
- (BOOL)groupHasCatchupChannels:(NSString *)groupName {
    if (!groupName) return NO;
    
    NSArray *channelsInGroup = [self.channelsByGroup objectForKey:groupName];
    if (!channelsInGroup) return NO;
    
    for (VLCChannel *channel in channelsInGroup) {
        // Check both EPG-based catch-up and channel-level catch-up
        if (channel.supportsCatchup || channel.catchupDays > 0) {
            return YES; // Channel-level catch-up support
        }
        
        if (channel.programs && channel.programs.count > 0) {
            for (id program in channel.programs) {
                if ([VLCProgram hasArchiveForProgramObject:program]) {
                    return YES; // EPG-based catch-up support
                }
            }
        }
    }
    
    return NO;
}

#pragma mark - Timeshift/Catchup Support (iOS/tvOS)

// Auto-fetch catch-up info when loading M3U (called from M3U loading)
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
    
    NSLog(@"🔄 Constructed live streams API URL: %@", apiUrl);
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
    NSLog(@"🔄 Processing catch-up info for %lu API channels", (unsigned long)[apiChannels count]);
    
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
    
    NSLog(@"🔄 Created catch-up lookup table with %lu entries", (unsigned long)[catchupInfo count]);
    
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
    
    NSLog(@"🔄 Updated catch-up info for %ld channels", (long)updatedChannels);
    
    // Log final summary 
    NSInteger finalCatchupChannels = 0;
    for (VLCChannel *channel in self.channels) {
        if (channel.supportsCatchup || channel.catchupDays > 0) {
            finalCatchupChannels++;
        }
    }
    NSLog(@"🔧 [TIMESHIFT-API-SUMMARY] Now have %ld channels with timeshift support after API fetch", (long)finalCatchupChannels);
    
    // Cache saving for catch-up information is now handled automatically by VLCDataManager/VLCCacheManager
    if (updatedChannels > 0 && self.m3uFilePath) {
        NSLog(@"📺 iOS: Catch-up info updated for %ld channels - cache will be updated automatically by VLCDataManager", (long)updatedChannels);
    }
    
    // Trigger UI update to show catch-up indicators
    [self setNeedsDisplay];
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
                return streamId;
            }
        }
    }
    
    return nil;
}

#pragma mark - VLCDataManagerDelegate

- (void)dataManagerDidStartLoading:(NSString *)operation {
    NSLog(@"🔄 VLCDataManager started loading: %@", operation);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = YES;
        
        if ([operation containsString:@"Channels"]) {
            _isDownloadingChannels = YES;
        } else if ([operation containsString:@"EPG"]) {
            _isDownloadingEPG = YES;
        }
        
        [self setNeedsDisplay];
    });
}

- (void)dataManagerDidUpdateProgress:(float)progress operation:(NSString *)operation {
    NSLog(@"📊 VLCDataManager progress: %.1f%% for %@", progress * 100, operation);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // PROGRESS ROUTING: Use startup progress window for both startup and manual loading operations
        if (self.isStartupInProgress || self.isManualLoadingInProgress) {
            // Determine which phase we're in and map progress accordingly  
            if ([operation containsString:@"Channels"] || [operation containsString:@"channel"] || [operation containsString:@"M3U"]) {
                // Channel loading: 5% to 50% of startup progress
                float startupProgress = 0.05 + (progress * 0.45);
                NSString *step = @"Loading Channels";
                
                // Enhance the operation description for cache loading vs downloads
                NSString *enhancedDetails;
                if ([operation containsString:@"📁"] || [operation containsString:@"cache"] || [operation containsString:@"Cache"]) {
                    enhancedDetails = [self enhanceProgressDetails:operation forType:@"channels"];
                    step = @"Loading from Cache";
                } else if ([operation containsString:@"🌐"] || [operation containsString:@"Downloading"]) {
                    enhancedDetails = [self enhanceProgressDetails:operation forType:@"channels"];
                    step = @"Downloading Channels";
                } else {
                    enhancedDetails = [self enhanceProgressDetails:operation forType:@"channels"];
                    step = @"Processing Channels";
                }
                
                [self updateStartupProgress:startupProgress step:step details:enhancedDetails];
                NSLog(@"🚀 [STARTUP] Channel progress routed to startup window: %.1f%% - %@", startupProgress * 100, enhancedDetails);
                return; // Skip old progress bars
            } else if ([operation containsString:@"EPG"]) {
                // EPG loading: 50% to 90% of startup progress
                float startupProgress = 0.5 + (progress * 0.4);
                NSString *step = @"Loading EPG Data";
                
                // Enhance the operation description for EPG cache loading vs downloads
                NSString *enhancedDetails;
                if ([operation containsString:@"📁"] || [operation containsString:@"cache"] || [operation containsString:@"Cache"]) {
                    enhancedDetails = [self enhanceProgressDetails:operation forType:@"epg"];
                    step = @"Loading EPG Cache";
                } else if ([operation containsString:@"🌐"] || [operation containsString:@"Downloading"]) {
                    enhancedDetails = [self enhanceProgressDetails:operation forType:@"epg"];
                    step = @"Downloading EPG";
                } else {
                    enhancedDetails = [self enhanceProgressDetails:operation forType:@"epg"];
                    step = @"Processing EPG";
                }
                
                [self updateStartupProgress:startupProgress step:step details:enhancedDetails];
                NSLog(@"🚀 [STARTUP] EPG progress routed to startup window: %.1f%% - %@", startupProgress * 100, enhancedDetails);
                return; // Skip old progress bars
            }
        }
        
        // FALLBACK: Only show old progress bars if startup progress is NOT active
        BOOL isActualDownload = ([operation containsString:@"🌐"] || [operation containsString:@"Downloading"]) || 
                               [operation containsString:@"Processing"] ||
                               [operation containsString:@"Parsing"];
        BOOL isCacheLoading = [operation containsString:@"📁"] || [operation containsString:@"cache"] || [operation containsString:@"Cache"];
        
        if (isActualDownload) {
            // Update progress indicators and labels with detailed status
            if ([operation containsString:@"Channels"] || [operation containsString:@"channel"] || [operation containsString:@"M3U"]) {
                if (_m3uProgressBariOS && _m3uProgressLabeliOS) {
                    _m3uProgressBariOS.progress = progress;
                    _m3uProgressBariOS.hidden = NO; // Show during download
                    
                    // Extract and format the operation text for better display
                    NSString *displayText = [self formatProgressText:operation forType:@"M3U"];
                    _m3uProgressLabeliOS.text = displayText;
                    
                                                NSLog(@"📊 [iOS] Updated M3U: %@ (%.1f%%)", displayText, progress * 100);
                            
                            // Ensure progress window stays visible during active processing
                            if (_loadingPaneliOS && _loadingPaneliOS.hidden) {
                                _loadingPaneliOS.hidden = NO;
                                NSLog(@"📱 [iOS] Re-showing progress window during active M3U processing");
                            }
                }
            } else if ([operation containsString:@"EPG"]) {
                if (_epgProgressBariOS && _epgProgressLabeliOS) {
                    _epgProgressBariOS.progress = progress;
                    _epgProgressBariOS.hidden = NO; // Show during download
                    
                    // Extract and format the operation text for better display
                    NSString *displayText = [self formatProgressText:operation forType:@"EPG"];
                    _epgProgressLabeliOS.text = displayText;
                    
                                                NSLog(@"📊 [iOS] Updated EPG: %@ (%.1f%%)", displayText, progress * 100);
                            
                            // Ensure progress window stays visible during active processing
                            if (_loadingPaneliOS && _loadingPaneliOS.hidden) {
                                _loadingPaneliOS.hidden = NO;
                                NSLog(@"📱 [iOS] Re-showing progress window during active EPG processing");
                            }
                }
            }
        } else if (isCacheLoading) {
            // Show light progress for cache operations with different styling
            NSLog(@"💾 [iOS] Cache operation detected - showing cache progress: %@", operation);
            if ([operation containsString:@"Channels"] || [operation containsString:@"channel"] || [operation containsString:@"M3U"]) {
                if (_m3uProgressBariOS && _m3uProgressLabeliOS) {
                    _m3uProgressBariOS.progress = progress;
                    _m3uProgressBariOS.hidden = NO;
                    
                    // Show cache-specific message
                    NSString *displayText = [self formatProgressText:operation forType:@"Cache"];
                    _m3uProgressLabeliOS.text = displayText;
                    
                    NSLog(@"📊 [iOS] Updated M3U Cache: %@ (%.1f%%)", displayText, progress * 100);
                }
            } else if ([operation containsString:@"EPG"]) {
                if (_epgProgressBariOS && _epgProgressLabeliOS) {
                    _epgProgressBariOS.progress = progress;
                    _epgProgressBariOS.hidden = NO;
                    
                    // Show cache-specific message
                    NSString *displayText = [self formatProgressText:operation forType:@"EPG-Cache"];
                    _epgProgressLabeliOS.text = displayText;
                    
                    NSLog(@"📊 [iOS] Updated EPG Cache: %@ (%.1f%%)", displayText, progress * 100);
                }
            }
        } else {
            // Hide progress bars for unrecognized operations
            NSLog(@"🔧 [iOS] Unknown operation - hiding progress bars: %@", operation);
            if (_m3uProgressBariOS && ([operation containsString:@"Channels"] || [operation containsString:@"channel"])) {
                _m3uProgressBariOS.hidden = YES;
                if (_m3uProgressLabeliOS) {
                    _m3uProgressLabeliOS.text = @"M3U: Ready";
                }
            }
            if (_epgProgressBariOS && [operation containsString:@"EPG"]) {
                _epgProgressBariOS.hidden = YES;
                if (_epgProgressLabeliOS) {
                    _epgProgressLabeliOS.text = @"EPG: Ready";
                }
            }
        }
        
        [self setNeedsDisplay];
    });
}

- (void)dataManagerDidFinishLoading:(NSString *)operation success:(BOOL)success {
    NSLog(@"✅ VLCDataManager finished loading: %@ (success: %@)", operation, success ? @"YES" : @"NO");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([operation containsString:@"Channels"] || [operation containsString:@"channel"]) {
            _isDownloadingChannels = NO;
            // Hide M3U progress bar and reset label when done
            if (_m3uProgressBariOS) {
                _m3uProgressBariOS.hidden = YES;
                _m3uProgressBariOS.progress = 0.0;
                NSLog(@"📊 [iOS] Hidden M3U progress bar after completion");
            }
            if (_m3uProgressLabeliOS) {
                _m3uProgressLabeliOS.text = @"M3U: Ready";
            }
        } else if ([operation containsString:@"EPG"]) {
            _isDownloadingEPG = NO;
            // Hide EPG progress bar and reset label when done
            if (_epgProgressBariOS) {
                _epgProgressBariOS.hidden = YES;
                _epgProgressBariOS.progress = 0.0;
                NSLog(@"📊 [iOS] Hidden EPG progress bar after completion");
            }
            if (_epgProgressLabeliOS) {
                _epgProgressLabeliOS.text = @"EPG: Ready";
            }
            
            // Clear manual loading flag for EPG operations (only if NOT doing full reload)
            if (self.isManualLoadingInProgress && !self.isLoadingBothChannelsAndEPG) {
                self.isManualLoadingInProgress = NO;
                [self hideLoadingPanel];
                NSLog(@"📱 [MANUAL-LOAD] Manual EPG loading completed - loading panel can now be hidden");
            } else if (self.isLoadingBothChannelsAndEPG) {
                NSLog(@"📱 [FULL-RELOAD] EPG completed but full reload still in progress - keeping flags");
            }
        }
        
        self.isLoading = (_isDownloadingChannels || _isDownloadingEPG);
        
        // Check if all operations are complete and hide progress window
        [self checkAndHideProgressWindow];
        
        // Clear manual loading flag on any error (only if NOT doing full reload)
        if (self.isManualLoadingInProgress && !success && !self.isLoadingBothChannelsAndEPG) {
            self.isManualLoadingInProgress = NO;
            [self hideLoadingPanel];
            NSLog(@"📱 [MANUAL-LOAD] Manual loading failed - clearing flag and hiding loading panel");
        }
        
        // Re-enable buttons when loading completes
        [self setLoadingButtonsEnabled:YES];
        
        [self setNeedsDisplay];
    });
}

- (void)epgMatchingProgress:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSNumber *processed = userInfo[@"processed"];
    NSNumber *total = userInfo[@"total"];
    NSNumber *matched = userInfo[@"matched"];
    
    NSLog(@"📅 [iOS-UI] EPG matching progress: %@/%@ channels (%@ matched)", processed, total, matched);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Progressive UI update - refresh display as EPG data becomes available
        [self setNeedsDisplay];
    });
}

- (void)epgMatchingCompleted:(NSNotification *)notification {
    NSLog(@"📅 [iOS-UI] EPG matching completed notification received - refreshing UI");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // CRITICAL FIX: Update favorites with EPG data when matching completes
        [self updateFavoritesWithEPGData];
        
        // Force refresh of the channel list to show updated EPG data
        [self setNeedsDisplay];
        
        // Also trigger channel selection update to refresh program guide
        if (self.selectedChannelIndex >= 0 && self.selectedChannelIndex < self.channels.count) {
            // This will trigger program guide refresh with the newly matched EPG data
            [self setNeedsDisplay];
        }
        
        NSLog(@"📅 [iOS-UI] UI refresh completed after EPG matching (including favorites)");
    });
}

- (void)dataManagerDidUpdateChannels:(NSArray<VLCChannel *> *)channels {
    NSLog(@"📺 VLCDataManager updated channels: %lu channels", (unsigned long)channels.count);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Data processing happens asynchronously in VLCDataManager
        // Update local data structures with new channels when they're ready
        [self replaceChannelsWithDataFromManager:channels];
        
        NSLog(@"🔗 [iOS] Data sync: DataManager has %lu groups, %lu channelsByGroup, %lu groupsByCategory", 
              (unsigned long)self.dataManager.groups.count,
              (unsigned long)self.dataManager.channelsByGroup.count, 
              (unsigned long)self.dataManager.groupsByCategory.count);
              
        // DIAGNOSTIC: Check if data is actually ready
        if (channels.count > 0 && _groups.count == 0) {
            NSLog(@"🚨 [iOS] CRITICAL: Have %lu channels but 0 groups - background processing may not be complete", 
                  (unsigned long)channels.count);
            NSLog(@"🚨 [iOS] DataManager internal state: groups=%lu channelsByGroup=%lu", 
                  (unsigned long)self.dataManager.groups.count, (unsigned long)self.dataManager.channelsByGroup.count);
        }
        
        // CRITICAL: Make channel list visible if we have channels
        if (channels.count > 0) {
            _isChannelListVisible = YES;
            NSLog(@"📺 [iOS] Made channel list visible with %lu channels", (unsigned long)channels.count);
            
            // Initialize selection if not set - DEFAULT TO FAVORITES
            if (_selectedCategoryIndex < 0 && _categories && _categories.count > 0) {
                _selectedCategoryIndex = CATEGORY_FAVORITES;
                NSLog(@"📺 [iOS] Set selectedCategoryIndex to FAVORITES");
            }
            if (_selectedGroupIndex < 0 && _groups && _groups.count > 0) {
                _selectedGroupIndex = 0; 
                NSLog(@"📺 [iOS] Set selectedGroupIndex to 0");
            }
        }
        
        // Update UI
        [self setNeedsDisplay];
        NSLog(@"📺 [iOS] IMMEDIATE: Channel list should now be visible with %lu channels", (unsigned long)channels.count);
        
        // Auto-start playback if available
        [self startEarlyPlaybackIfAvailable];
        
        // Update startup progress when channels are loaded
        if (self.isStartupInProgress) {
            [self updateStartupProgress:0.50 step:@"Channels Loaded" details:@"Channel list loaded successfully"];
        }
        
        // EPG loading is now handled automatically by VLCDataManager's universal sequence
        // Just ensure EPG URL is updated in the data manager for the sequential loading
        if (channels.count > 0) {
            // Try to auto-generate EPG URL if we don't have one
            if (!self.epgUrl || [self.epgUrl length] == 0) {
                NSString *m3uUrl = self.m3uFilePath;
                if (m3uUrl && [m3uUrl length] > 0) {
                    NSString *generatedEpgUrl = [self generateEpgUrlFromM3uUrl:m3uUrl];
                    if (generatedEpgUrl && [generatedEpgUrl length] > 0) {
                        self.epgUrl = generatedEpgUrl;
                        NSLog(@"📅 Auto-generated EPG URL: %@", self.epgUrl);
                    }
                }
            }
            
            // Update data manager with EPG URL (it will handle the sequential loading)
            if (self.epgUrl && [self.epgUrl length] > 0) {
                self.dataManager.epgURL = self.epgUrl;
                NSLog(@"📅 [UNIVERSAL] EPG URL set in DataManager - sequential loading will handle EPG");
                } else {
                NSLog(@"⚠️ No EPG URL available - EPG will be skipped in universal sequence");
            }
        }
    });
}

- (void)dataManagerDidUpdateEPG:(NSDictionary *)epgData {
    NSLog(@"📅 VLCDataManager updated EPG: %lu programs", (unsigned long)epgData.count);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update EPG data
        self.epgData = epgData;
        
        // CRITICAL: Mark EPG as loaded so channel list shows current programs
        self.isEpgLoaded = YES;
        
        // EPG matching now handled automatically by VLCEPGManager
        
        NSLog(@"🎯 [iOS] Updated EPG from VLCDataManager: %lu channels, EPG loaded flag set to YES", (unsigned long)epgData.count);
        
        // CRITICAL FIX: Update favorites with EPG data
        [self updateFavoritesWithEPGData];
        
        // Check if this is a full reload (channels + EPG) and clear flags
        if (self.isLoadingBothChannelsAndEPG && self.isManualLoadingInProgress) {
            self.isLoadingBothChannelsAndEPG = NO;
            self.isManualLoadingInProgress = NO;
            NSLog(@"📱 [FULL-RELOAD] Both channels and EPG completed - clearing flags and hiding progress window");
            
            // Show completion message and hide startup progress window
            [self updateStartupProgress:1.0 step:@"Complete" details:@"All data loaded successfully"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self hideStartupProgressWindow];
            });
        }
        
        // Update startup progress when EPG is loaded
        if (self.isStartupInProgress) {
            [self updateStartupProgress:0.90 step:@"EPG Loaded" details:@"Program guide loaded successfully"];
            
            // Complete startup after EPG loads
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self updateStartupProgress:1.0 step:@"Complete" details:@"BasicIPTV ready to use"];
                
                // Hide startup progress window after completion
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self hideStartupProgressWindow];
                });
            });
        }
        
        // Update UI
        [self setNeedsDisplay];
    });
}

- (void)dataManagerDidDetectTimeshift:(NSInteger)timeshiftChannelCount {
    NSLog(@"⏱ VLCDataManager detected timeshift: %ld channels", (long)timeshiftChannelCount);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update UI to show timeshift indicators
        [self setNeedsDisplay];
    });
}

- (void)dataManagerDidEncounterError:(NSError *)error operation:(NSString *)operation {
    NSLog(@"❌ VLCDataManager error in %@: %@", operation, error.localizedDescription);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = NO;
        _isDownloadingChannels = NO;
        _isDownloadingEPG = NO;
        
        // Hide all progress bars and reset labels on error
        if (_m3uProgressBariOS) {
            _m3uProgressBariOS.hidden = YES;
            _m3uProgressBariOS.progress = 0.0;
        }
        if (_m3uProgressLabeliOS) {
            _m3uProgressLabeliOS.text = @"M3U: Error";
        }
        if (_epgProgressBariOS) {
            _epgProgressBariOS.hidden = YES;
            _epgProgressBariOS.progress = 0.0;
        }
        if (_epgProgressLabeliOS) {
            _epgProgressLabeliOS.text = @"EPG: Error";
        }
        
        NSLog(@"📊 [iOS] Hidden all progress bars due to error");
        
        // Hide progress window after error with slight delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self hideProgressWindow];
        });
        
        // Handle startup progress error
        if (self.isStartupInProgress) {
            [self updateStartupProgress:0.0 step:@"Error" details:[NSString stringWithFormat:@"Failed to load %@", operation]];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self hideStartupProgressWindow];
            });
        }
        
        // Show error to user if needed
        [self setNeedsDisplay];
    });
}

#pragma mark - Data Manager Integration Helpers

- (void)replaceChannelsWithDataFromManager:(NSArray<VLCChannel *> *)channels {
    NSLog(@"🔄 [DATA-REPLACE] Starting data replacement, checking for favorites to preserve...");
    
    // THREAD-SAFE: Synchronize data replacement to prevent concurrent access crashes
    @synchronized(self) {
    
    // Preserve existing Settings and Favorites before updating
    NSMutableArray *savedSettingsGroups = nil;
    NSMutableDictionary *savedSettingsChannels = [NSMutableDictionary dictionary];
    NSMutableArray *savedFavoritesGroups = nil;
    NSMutableDictionary *savedFavoritesChannels = [NSMutableDictionary dictionary];
    
    // Preserve SETTINGS category
    if (_groupsByCategory && [_groupsByCategory isKindOfClass:[NSDictionary class]]) {
        id settingsGroups = [_groupsByCategory objectForKey:@"SETTINGS"];
        if (settingsGroups && [settingsGroups isKindOfClass:[NSArray class]]) {
            savedSettingsGroups = [settingsGroups mutableCopy];
        
        // Also preserve Settings channels
        for (NSString *settingsGroup in savedSettingsGroups) {
            NSArray *groupChannels = [_channelsByGroup objectForKey:settingsGroup];
            if (groupChannels) {
                [savedSettingsChannels setObject:groupChannels forKey:settingsGroup];
                }
            }
        }
    }
    
    // ENHANCED: Preserve FAVORITES category (check both current data AND reload from disk if needed)
    if (_groupsByCategory && [_groupsByCategory isKindOfClass:[NSDictionary class]]) {
        id favoritesGroups = [_groupsByCategory objectForKey:@"FAVORITES"];
        //NSLog(@"🔍 [STARTUP-DEBUG] Current _groupsByCategory keys: %@", [_groupsByCategory allKeys]);
        //NSLog(@"🔍 [STARTUP-DEBUG] FAVORITES object type: %@, content: %@", 
        //      [favoritesGroups class], favoritesGroups);
              
        if (favoritesGroups && [favoritesGroups isKindOfClass:[NSArray class]]) {
            savedFavoritesGroups = [favoritesGroups mutableCopy];
        
        // Also preserve Favorites channels
        for (NSString *favoritesGroup in savedFavoritesGroups) {
            NSArray *groupChannels = [_channelsByGroup objectForKey:favoritesGroup];
           // NSLog(@"🔍 [STARTUP-DEBUG] Group '%@' has %lu channels", favoritesGroup, (unsigned long)(groupChannels ? groupChannels.count : 0));
            if (groupChannels) {
                [savedFavoritesChannels setObject:groupChannels forKey:favoritesGroup];
            }
            }
            
            //NSLog(@"💾 [FAVORITES-iOS] Preserved %lu favorites groups from current data before replacement", 
            //      (unsigned long)savedFavoritesGroups.count);
        } else {
           // NSLog(@"⚠️ [STARTUP-DEBUG] No valid FAVORITES found in _groupsByCategory during data replacement");
        }
    }
    
    // CRITICAL FIX: If no favorites found in current data, try to reload them from disk
    // This handles the case where favorites were loaded but data replacement happened before they were integrated
    if (!savedFavoritesGroups || savedFavoritesGroups.count == 0) {
        NSLog(@"🔍 [FAVORITES-iOS] No favorites in current data, attempting to reload from disk...");
        
        // Force reload favorites from settings file
        NSDictionary *reloadedFavorites = [self loadFavoritesFromSettingsFile];
        if (reloadedFavorites) {
            savedFavoritesGroups = [[reloadedFavorites objectForKey:@"groups"] mutableCopy];
            savedFavoritesChannels = [[reloadedFavorites objectForKey:@"channels"] mutableCopy];
            
            NSLog(@"🔄 [FAVORITES-iOS] Reloaded %lu favorites groups from disk for preservation", 
                  (unsigned long)savedFavoritesGroups.count);
        }
    }
    
    // Update local data structures with data from the universal manager
    _channels = [channels mutableCopy];
    
    // THREAD-SAFE: Store old references and release after setting new ones to prevent crashes
    NSMutableArray *oldGroups = _groups;
    NSMutableDictionary *oldChannelsByGroup = _channelsByGroup;
    NSMutableDictionary *oldGroupsByCategory = _groupsByCategory;
    NSArray *oldCategories = _categories;
    
    // Set new data structures FIRST (retain immediately)
    _groups = [[_dataManager.groups mutableCopy] retain];
    _channelsByGroup = [[_dataManager.channelsByGroup mutableCopy] retain];
    _groupsByCategory = [[_dataManager.groupsByCategory mutableCopy] retain];
    _categories = [_dataManager.categories retain];
    
    // Release old objects AFTER new ones are set to prevent crashes during concurrent access
    [oldGroups release];
    [oldChannelsByGroup release];
    [oldGroupsByCategory release];
    [oldCategories release];
    
    NSLog(@"🔄 [STARTUP-DEBUG] After rebuilding from DataManager:");
    NSLog(@"🔄 [STARTUP-DEBUG] - _groupsByCategory keys: %@", [_groupsByCategory allKeys]);
    NSLog(@"🔄 [STARTUP-DEBUG] - _groups count: %lu", (unsigned long)_groups.count);
    NSLog(@"🔄 [STARTUP-DEBUG] - _channelsByGroup count: %lu", (unsigned long)_channelsByGroup.count);
    
    // Restore Settings category and its groups/channels
    if (savedSettingsGroups) {
        [_groupsByCategory setObject:savedSettingsGroups forKey:@"SETTINGS"];
        
        // Restore Settings groups to main groups list
        for (NSString *settingsGroup in savedSettingsGroups) {
            if (![_groups containsObject:settingsGroup]) {
                [_groups addObject:settingsGroup];
            }
            
            // Restore Settings channels
            NSArray *groupChannels = [savedSettingsChannels objectForKey:settingsGroup];
            if (groupChannels) {
                [_channelsByGroup setObject:groupChannels forKey:settingsGroup];
            }
        }
        
        [savedSettingsGroups release];
    } else {
        // If no settings were saved, create default Settings category
        NSMutableArray *defaultSettingsGroups = [NSMutableArray arrayWithObjects:
            @"General", @"Playlist", @"Subtitles", @"Movie Info", @"Themes", nil];
        [_groupsByCategory setObject:defaultSettingsGroups forKey:@"SETTINGS"];
        
        // Add Settings groups to main groups list
        for (NSString *settingsGroup in defaultSettingsGroups) {
            if (![_groups containsObject:settingsGroup]) {
                [_groups addObject:settingsGroup];
            }
        }
    }
    
    // Restore Favorites category and its groups/channels
    if (savedFavoritesGroups) {
        [_groupsByCategory setObject:savedFavoritesGroups forKey:@"FAVORITES"];
        
        // Restore Favorites groups to main groups list
        for (NSString *favoritesGroup in savedFavoritesGroups) {
            if (![_groups containsObject:favoritesGroup]) {
                [_groups addObject:favoritesGroup];
            }
            
            // Restore Favorites channels
            NSArray *groupChannels = [savedFavoritesChannels objectForKey:favoritesGroup];
            if (groupChannels) {
                [_channelsByGroup setObject:groupChannels forKey:favoritesGroup];
            }
        }
        
        [savedFavoritesGroups release];
        
        //NSLog(@"✅ [FAVORITES-iOS] Restored %lu favorites groups after data update", 
        //      (unsigned long)savedFavoritesGroups.count);
        
        // DIAGNOSTIC: Verify favorites are actually accessible
        NSArray *verifyFavorites = [_groupsByCategory objectForKey:@"FAVORITES"];
        //NSLog(@"🔍 [VERIFY] FAVORITES after restoration: %@", verifyFavorites);
        
        // Check sample channel in first group
        if (verifyFavorites && verifyFavorites.count > 0) {
            NSString *firstGroup = [verifyFavorites objectAtIndex:0];
            NSArray *groupChannels = [_channelsByGroup objectForKey:firstGroup];
            //NSLog(@"🔍 [VERIFY] Channels in '%@': %lu", firstGroup, (unsigned long)(groupChannels ? groupChannels.count : 0));
        }
    }
    
    // Rebuild simple arrays for compatibility
    NSMutableArray *channelNames = [NSMutableArray array];
    NSMutableArray *channelUrls = [NSMutableArray array];
    
    for (VLCChannel *channel in channels) {
        [channelNames addObject:channel.name ?: @""];
        [channelUrls addObject:channel.url ?: @""];
    }
    
    _simpleChannelNames = [[channelNames copy] autorelease];
    _simpleChannelUrls = [[channelUrls copy] autorelease];
    
    //NSLog(@"🔄 Replaced local data with universal manager data: %lu channels, %lu groups, Settings and Favorites preserved", 
    //      (unsigned long)channels.count, (unsigned long)_groups.count);
    
    // FINAL DEBUG: Check if FAVORITES category is actually accessible after all operations
    NSArray *finalFavoritesCheck = [_groupsByCategory objectForKey:@"FAVORITES"];
    //NSLog(@"🔍 [FINAL-DEBUG] FAVORITES category after restoration: %@ (count: %lu)", 
    //      finalFavoritesCheck, (unsigned long)(finalFavoritesCheck ? finalFavoritesCheck.count : 0));
    //NSLog(@"🔍 [FINAL-DEBUG] All categories after restoration: %@", [_groupsByCategory allKeys]);
    
    // SAFETY NET: If favorites were lost despite preservation attempts, force reload them
    if (!finalFavoritesCheck || finalFavoritesCheck.count == 0) {
        //NSLog(@"🚨 [EMERGENCY] FAVORITES category lost after data replacement - forcing emergency reload");
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Give the UI a moment to settle, then reload favorites
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self loadFavoritesFromSettings];
                //NSLog(@"🔄 [EMERGENCY] Re-triggered favorites loading after data replacement");
            });
        });
    }
    
    // CRITICAL: Trigger UI refresh after data replacement
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay];
        //NSLog(@"🔄 [UI-REFRESH] Triggered UI refresh after data replacement");
    });
    
    } // End @synchronized(self)
}

- (void)updateFavoritesWithEPGData {
    //NSLog(@"📅 [FAVORITES-iOS] Updating existing favorites with EPG data...");
    
    // Get all favorites groups
    NSArray *favoriteGroups = [_groupsByCategory objectForKey:@"FAVORITES"];
    if (!favoriteGroups || favoriteGroups.count == 0) {
        //NSLog(@"📅 [FAVORITES-iOS] No favorites groups to update");
        return;
    }
    
    NSUInteger updatedChannels = 0;
    NSUInteger totalPrograms = 0;
    
    // Update each favorites group
    for (NSString *groupName in favoriteGroups) {
        NSMutableArray *favoriteChannels = [_channelsByGroup objectForKey:groupName];
        if (!favoriteChannels) continue;
        
        // Update each channel in the group
        for (VLCChannel *favChannel in favoriteChannels) {
            if (!favChannel.channelId || [favChannel.channelId length] == 0) continue;
            
            // Find the corresponding channel in the main channel list with EPG data
            VLCChannel *mainChannel = [self findMainChannelWithId:favChannel.channelId url:favChannel.url];
            if (mainChannel && mainChannel.programs && mainChannel.programs.count > 0) {
                // Update favorite channel with EPG data
                [favChannel.programs release];
                favChannel.programs = [mainChannel.programs mutableCopy];
                updatedChannels++;
                totalPrograms += mainChannel.programs.count;
                NSLog(@"📅 [FAVORITES-iOS] Updated %@ with %lu EPG programs", 
                      favChannel.name, (unsigned long)mainChannel.programs.count);
            }
        }
    }
    
    //NSLog(@"📅 [FAVORITES-iOS] EPG update complete: %lu channels updated with %lu total programs", 
    //      (unsigned long)updatedChannels, (unsigned long)totalPrograms);
}

- (VLCChannel *)findMainChannelWithId:(NSString *)channelId url:(NSString *)url {
    // Search through all main channels to find matching channel with EPG data
    for (VLCChannel *channel in _channels) {
        // Try to match by channel ID first (most accurate)
        if (channelId && [channelId length] > 0 && 
            channel.channelId && [channelId isEqualToString:channel.channelId]) {
            return channel;
        }
        
        // Fallback to URL matching if channel ID doesn't match
        if (url && [url length] > 0 && 
            channel.url && [url isEqualToString:channel.url]) {
            return channel;
        }
    }
    
    return nil;
}

// Emergency method to reload favorites directly from settings file
- (NSDictionary *)loadFavoritesFromSettingsFile {
    NSLog(@"📁 [FAVORITES-RELOAD] Emergency loading favorites directly from settings file...");
    
    // Get the settings file path
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) {
        NSLog(@"❌ [FAVORITES-RELOAD] Could not find Application Support directory");
        return nil;
    }
    
    NSString *appSupportDir = [paths firstObject];
    NSString *basicIPTVDir = [appSupportDir stringByAppendingPathComponent:@"BasicIPTV"];
    NSString *settingsPath = [basicIPTVDir stringByAppendingPathComponent:@"settings.plist"];
    
    NSLog(@"📁 [FAVORITES-RELOAD] Loading from: %@", settingsPath);
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:settingsPath]) {
        NSLog(@"❌ [FAVORITES-RELOAD] Settings file does not exist: %@", settingsPath);
        return nil;
    }
    
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:settingsPath];
    if (!settings) {
        NSLog(@"❌ [FAVORITES-RELOAD] Could not load settings dictionary");
        return nil;
    }
    
    // Extract favorites from settings
    NSArray *favoriteGroupsData = [settings objectForKey:@"favoriteGroups"];
    NSArray *favoriteChannelsData = [settings objectForKey:@"favoriteChannels"];
    
    if (!favoriteGroupsData || favoriteGroupsData.count == 0) {
        NSLog(@"ℹ️ [FAVORITES-RELOAD] No favorite groups found in settings file");
        return nil;
    }
    
    NSMutableArray *favoriteGroups = [NSMutableArray array];
    NSMutableDictionary *favoriteChannels = [NSMutableDictionary dictionary];
    
    // Process favorite groups
    for (NSString *groupName in favoriteGroupsData) {
        if ([groupName isKindOfClass:[NSString class]]) {
            [favoriteGroups addObject:groupName];
            
            // Initialize empty channel array for this group
            [favoriteChannels setObject:[NSMutableArray array] forKey:groupName];
        }
    }
    
    // Process favorite channels
    if (favoriteChannelsData && [favoriteChannelsData isKindOfClass:[NSArray class]]) {
        for (NSDictionary *channelData in favoriteChannelsData) {
            if (![channelData isKindOfClass:[NSDictionary class]]) continue;
            
            // Recreate VLCChannel object
            VLCChannel *channel = [[VLCChannel alloc] init];
            channel.name = [channelData objectForKey:@"name"] ?: @"Unknown";
            channel.url = [channelData objectForKey:@"url"] ?: @"";
            channel.channelId = [channelData objectForKey:@"channelId"];
            channel.logo = [channelData objectForKey:@"logo"];
            channel.category = [channelData objectForKey:@"category"] ?: @"Favorites";
            channel.group = [channelData objectForKey:@"group"] ?: @"Default";
            
            // CRITICAL: Restore timeshift/catchup properties in emergency reload too
            channel.supportsCatchup = [[channelData objectForKey:@"supportsCatchup"] boolValue];
            channel.catchupDays = [[channelData objectForKey:@"catchupDays"] integerValue];
            channel.catchupSource = [channelData objectForKey:@"catchupSource"];
            channel.catchupTemplate = [channelData objectForKey:@"catchupTemplate"];
            
            // Add to appropriate group
            NSString *groupName = channel.group;
            NSMutableArray *groupChannels = [favoriteChannels objectForKey:groupName];
            if (!groupChannels) {
                groupChannels = [NSMutableArray array];
                [favoriteChannels setObject:groupChannels forKey:groupName];
                
                // Add group to favorites list if not already there
                if (![favoriteGroups containsObject:groupName]) {
                    [favoriteGroups addObject:groupName];
                }
            }
            
            [groupChannels addObject:channel];
            [channel release];
        }
    }
    
    //NSLog(@"✅ [FAVORITES-RELOAD] Successfully reloaded %lu favorite groups with channels from disk", 
    //      (unsigned long)favoriteGroups.count);
    
    return @{
        @"groups": favoriteGroups,
        @"channels": favoriteChannels
    };
}

#pragma mark - Progress Helper Methods

- (NSString *)formatProgressText:(NSString *)operation forType:(NSString *)type {
    // Extract download progress (MB format)
    if ([operation containsString:@"Downloading"]) {
        // Look for patterns like "🌐 Downloading EPG: 46.7 MB / -0.0 MB" or "Downloading: 4.3 MB / 160.0 MB"
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(-?\\d+\\.?\\d*)\\s*MB\\s*/\\s*(-?\\d+\\.?\\d*)\\s*MB" options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:operation options:0 range:NSMakeRange(0, operation.length)];
        
        if (match) {
            NSString *downloaded = [operation substringWithRange:[match rangeAtIndex:1]];
            NSString *total = [operation substringWithRange:[match rangeAtIndex:2]];
            float downloadedMB = downloaded.floatValue;
            float totalMB = total.floatValue;
            
            // Handle case where total is negative or zero (unknown total size)
            if (totalMB <= 0) {
                return [NSString stringWithFormat:@"%@: Downloading %.1fMB", type, downloadedMB];
            } else {
                return [NSString stringWithFormat:@"%@: Downloading %.1fMB of %.1fMB", type, downloadedMB, totalMB];
            }
        } else if ([operation containsString:@"MB"]) {
            // Fallback for other MB formats - extract any number before MB
            NSRegularExpression *simpleRegex = [NSRegularExpression regularExpressionWithPattern:@"(-?\\d+\\.?\\d*)\\s*MB" options:0 error:nil];
            NSTextCheckingResult *simpleMatch = [simpleRegex firstMatchInString:operation options:0 range:NSMakeRange(0, operation.length)];
            if (simpleMatch) {
                NSString *downloaded = [operation substringWithRange:[simpleMatch rangeAtIndex:1]];
                return [NSString stringWithFormat:@"%@: Downloading %.1fMB", type, downloaded.floatValue];
            }
            return [NSString stringWithFormat:@"%@: Downloading...", type];
        }
        return [NSString stringWithFormat:@"%@: Downloading", type];
    }
    
    // Extract cache loading progress (item counts)
    if ([type isEqualToString:@"Cache"] || [type isEqualToString:@"EPG-Cache"] || [operation containsString:@"📁"] || [operation containsString:@"cache"]) {
        // Look for patterns like "📁 Loading channel 1234 of 44357 from cache"
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*of\\s*(\\d+)" options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:operation options:0 range:NSMakeRange(0, operation.length)];
        
        if (match) {
            NSString *current = [operation substringWithRange:[match rangeAtIndex:1]];
            NSString *total = [operation substringWithRange:[match rangeAtIndex:2]];
            if ([type isEqualToString:@"EPG-Cache"]) {
                return [NSString stringWithFormat:@"EPG: From Cache (%@ of %@)", current, total];
            } else {
                return [NSString stringWithFormat:@"M3U: From Cache (%@ of %@)", current, total];
            }
        }
        
        if ([operation containsString:@"Reading"]) {
            if ([type isEqualToString:@"EPG-Cache"]) {
                return @"EPG: Reading Cache...";
            } else {
                return @"M3U: Reading Cache...";
            }
        }
        
        if ([type isEqualToString:@"EPG-Cache"]) {
            return @"EPG: Loading from Cache";
        } else {
            return @"M3U: Loading from Cache";
        }
    }
    
    // Extract processing progress (item counts)
    if ([operation containsString:@"Processing"]) {
        // Look for patterns like "Processing channel 1234 of 44357"
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*of\\s*(\\d+)" options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:operation options:0 range:NSMakeRange(0, operation.length)];
        
        if (match) {
            NSString *current = [operation substringWithRange:[match rangeAtIndex:1]];
            NSString *total = [operation substringWithRange:[match rangeAtIndex:2]];
            return [NSString stringWithFormat:@"%@: Processing (%@ of %@)", type, current, total];
        }
        return [NSString stringWithFormat:@"%@: Processing", type];
    }
    
    // Extract parsing progress (item counts)
    if ([operation containsString:@"Parsing"]) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*of\\s*(\\d+)" options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:operation options:0 range:NSMakeRange(0, operation.length)];
        
        if (match) {
            NSString *current = [operation substringWithRange:[match rangeAtIndex:1]];
            NSString *total = [operation substringWithRange:[match rangeAtIndex:2]];
            return [NSString stringWithFormat:@"%@: Parsing (%@ of %@)", type, current, total];
        }
        return [NSString stringWithFormat:@"%@: Parsing", type];
    }
    
    // Default fallback
    return [NSString stringWithFormat:@"%@: %@", type, operation];
}

- (void)checkAndHideProgressWindow {
    // Check if both progress bars are hidden AND no loading operations are active
    BOOL m3uComplete = _m3uProgressBariOS.hidden;
    BOOL epgComplete = _epgProgressBariOS.hidden;
    BOOL actuallyComplete = !self.isLoading && !_isDownloadingChannels && !_isDownloadingEPG;
    
    NSLog(@"📊 [PROGRESS-CHECK] Current state: m3u=%@ epg=%@ loading=%@ downloading_ch=%@ downloading_epg=%@", 
          m3uComplete ? @"complete" : @"active",
          epgComplete ? @"complete" : @"active", 
          self.isLoading ? @"YES" : @"NO",
          _isDownloadingChannels ? @"YES" : @"NO",
          _isDownloadingEPG ? @"YES" : @"NO");
    
    // FIXED: More comprehensive completion check
    // Hide if: (both progress bars hidden OR all flags indicate completion) AND not actively loading
    BOOL progressBarsComplete = (m3uComplete && epgComplete);
    BOOL flagsComplete = (!_isDownloadingChannels && !_isDownloadingEPG);
    BOOL shouldHide = progressBarsComplete && flagsComplete && !self.isLoading;
    
    if (shouldHide) {
        NSLog(@"✅ [PROGRESS-CHECK] All operations truly completed - hiding progress window");
        
        // Hide the progress window after a brief delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self hideProgressWindow];
        });
    } else {
        NSLog(@"📊 [PROGRESS-CHECK] Operations still active - keeping progress window visible");
    }
}

- (void)hideProgressWindow {
    NSLog(@"🚪 Hiding progress window and resetting all indicators");
    
    // Hide the loading panel
    if (_loadingPaneliOS) {
        _loadingPaneliOS.hidden = YES;
        NSLog(@"📱 [iOS] Progress window hidden");
    }
    
    // Reset all progress indicators
    if (_m3uProgressBariOS) {
        _m3uProgressBariOS.hidden = YES;
        _m3uProgressBariOS.progress = 0.0;
    }
    if (_epgProgressBariOS) {
        _epgProgressBariOS.hidden = YES;
        _epgProgressBariOS.progress = 0.0;
    }
    
    // Reset labels to ready state
    if (_m3uProgressLabeliOS) {
        _m3uProgressLabeliOS.text = @"M3U: Ready";
    }
    if (_epgProgressLabeliOS) {
        _epgProgressLabeliOS.text = @"EPG: Ready";
    }
    
    // Clear loading state
    self.isLoading = NO;
    _isDownloadingChannels = NO;
    _isDownloadingEPG = NO;
    
    [self setNeedsDisplay];
}

#pragma mark - EPG URL Generation

// Helper method to generate EPG URL from M3U URL following XMLTV standards
- (NSString *)generateEpgUrlFromM3uUrl:(NSString *)m3uUrl {
    if (!m3uUrl || [m3uUrl length] == 0) {
        return nil;
    }
    
    // Parse the M3U URL to extract components
    NSURL *url = [NSURL URLWithString:m3uUrl];
    if (!url) {
        // If not a valid URL, try adding http://
        if (![m3uUrl hasPrefix:@"http://"] && ![m3uUrl hasPrefix:@"https://"]) {
            url = [NSURL URLWithString:[@"http://" stringByAppendingString:m3uUrl]];
        }
        
        if (!url) {
            return nil; // Still not a valid URL
        }
    }
    
    // Extract the basic URL components
    NSString *host = [url host];
    if (!host) {
        return nil;
    }
    
    NSString *scheme = [url scheme] ?: @"http";
    NSNumber *port = [url port];
    NSString *portString = port ? [NSString stringWithFormat:@":%@", port] : @"";
    
    // Extract query parameters to find username and password
    NSString *username = @"";
    NSString *password = @"";
    
    // Parse the query string
    NSString *query = [url query];
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
    
    // If no username/password in query, look for them in the URL path
    if (username.length == 0 || password.length == 0) {
        NSString *path = [url path];
        if (path) {
            // Look for patterns like /path/username/password/ or /path/username/password/stream
            NSArray *pathComponents = [path pathComponents];
            if (pathComponents.count >= 3) {
                // Try to identify username and password components
                // Typically, username and password are consecutive path components
                for (NSInteger i = 1; i < pathComponents.count - 1; i++) {
                    // Check for common username patterns (non-empty, not standard directories)
                    NSString *potentialUsername = pathComponents[i];
                    if (potentialUsername.length > 0 && 
                        ![potentialUsername isEqualToString:@"live"] &&
                        ![potentialUsername isEqualToString:@"iptv"] &&
                        ![potentialUsername isEqualToString:@"api"] &&
                        ![potentialUsername isEqualToString:@"xmltv"]) {
                        username = potentialUsername;
                        
                        // Next component might be password
                        if (i + 1 < pathComponents.count) {
                            NSString *potentialPassword = pathComponents[i+1];
                            if (potentialPassword.length > 0) {
                                password = potentialPassword;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Build the EPG URL in the standard format
    // http://SERVER_URL:PORT/xmltv.php?username=YOUR_USERNAME&password=YOUR_PASSWORD&type=m3u_plus&output=ts
    NSString *epgUrl = [NSString stringWithFormat:@"%@://%@%@/xmltv.php", scheme, host, portString];
    
    // Add query parameters if we have username/password
    if (username.length > 0 || password.length > 0) {
        epgUrl = [epgUrl stringByAppendingFormat:@"?username=%@&password=%@&type=m3u_plus&output=ts", 
                  username, password];
    }
    
    return epgUrl;
}

#pragma mark - Startup Progress System Implementation

- (void)showStartupProgressWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_startupProgressWindow) {
            self.isStartupInProgress = YES;
            
            // Create startup progress window - FIXED: positioned at right bottom
            CGFloat screenWidth = self.bounds.size.width;
            CGFloat screenHeight = self.bounds.size.height;
            CGFloat windowWidth = MIN(350.0, screenWidth * 0.6); // Slightly smaller
            CGFloat windowHeight = MIN(180.0, screenHeight * 0.35); // Slightly smaller
            
            // Position at right bottom corner with margin
            CGFloat margin = 20.0;
            CGRect windowFrame = CGRectMake(
                screenWidth - windowWidth - margin,  // Right side
                screenHeight - windowHeight - margin, // Bottom side
                windowWidth,
                windowHeight
            );
            
#if TARGET_OS_IOS || TARGET_OS_TV
            _startupProgressWindow = [[UIView alloc] initWithFrame:windowFrame];
            
            // Background with blur effect
            UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
            blurView.frame = _startupProgressWindow.bounds;
            blurView.layer.cornerRadius = 12.0;
            blurView.clipsToBounds = YES;
            [_startupProgressWindow addSubview:blurView];
            
            // Add border
            _startupProgressWindow.layer.borderWidth = 1.0;
            _startupProgressWindow.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.8].CGColor;
            _startupProgressWindow.layer.cornerRadius = 12.0;
            
            // Title label
            _startupProgressTitle = [[UILabel alloc] initWithFrame:CGRectMake(20, 20, windowWidth - 40, 30)];
            _startupProgressTitle.text = @"🚀 Loading BasicIPTV";
            _startupProgressTitle.textColor = [UIColor whiteColor];
            _startupProgressTitle.font = [UIFont boldSystemFontOfSize:18];
            _startupProgressTitle.textAlignment = NSTextAlignmentCenter;
            [_startupProgressWindow addSubview:_startupProgressTitle];
            
            // Current step label
            _startupProgressStep = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, windowWidth - 40, 25)];
            _startupProgressStep.text = @"Initializing...";
            _startupProgressStep.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
            _startupProgressStep.font = [UIFont systemFontOfSize:16];
            _startupProgressStep.textAlignment = NSTextAlignmentCenter;
            [_startupProgressWindow addSubview:_startupProgressStep];
            
            // Progress bar
            _startupProgressBar = [[UIProgressView alloc] initWithFrame:CGRectMake(40, 95, windowWidth - 80, 4)];
            _startupProgressBar.progressTintColor = [UIColor colorWithRed:0.0 green:0.6 blue:1.0 alpha:1.0];
            _startupProgressBar.trackTintColor = [UIColor colorWithWhite:0.3 alpha:0.6];
            _startupProgressBar.progress = 0.0;
            [_startupProgressWindow addSubview:_startupProgressBar];
            
            // Percentage label
            _startupProgressPercent = [[UILabel alloc] initWithFrame:CGRectMake(20, 110, windowWidth - 40, 20)];
            _startupProgressPercent.text = @"0%";
            _startupProgressPercent.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
            _startupProgressPercent.font = [UIFont systemFontOfSize:14];
            _startupProgressPercent.textAlignment = NSTextAlignmentCenter;
            [_startupProgressWindow addSubview:_startupProgressPercent];
            
            // Details label
            _startupProgressDetails = [[UILabel alloc] initWithFrame:CGRectMake(20, 140, windowWidth - 40, 40)];
            _startupProgressDetails.text = @"Starting up...";
            _startupProgressDetails.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
            _startupProgressDetails.font = [UIFont systemFontOfSize:12];
            _startupProgressDetails.textAlignment = NSTextAlignmentCenter;
            _startupProgressDetails.numberOfLines = 2;
            [_startupProgressWindow addSubview:_startupProgressDetails];
            
            [self addSubview:_startupProgressWindow];
#endif
            
            NSLog(@"🚀 [STARTUP] Created progress window: %.0fx%.0f", windowWidth, windowHeight);
        }
        
        _startupProgressWindow.hidden = NO;
        [self setNeedsDisplay];
    });
}

- (void)hideStartupProgressWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_startupProgressWindow) {
            self.isStartupInProgress = NO;
            _startupProgressWindow.hidden = YES;
            
            // Restart auto-hide timer if menu is visible now that startup is complete
            if (_isChannelListVisible) {
                NSLog(@"📱 [STARTUP-COMPLETE] Restarting auto-hide timer after startup completion");
                [self resetAutoHideTimer];
            }
            
            // Fade out animation
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [_startupProgressWindow removeFromSuperview];
                [_startupProgressWindow release];
                _startupProgressWindow = nil;
                
                [_startupProgressTitle release];
                _startupProgressTitle = nil;
                
                [_startupProgressStep release];
                _startupProgressStep = nil;
                
                [_startupProgressBar release];
                _startupProgressBar = nil;
                
                [_startupProgressPercent release];
                _startupProgressPercent = nil;
                
                [_startupProgressDetails release];
                _startupProgressDetails = nil;
                
                NSLog(@"🚀 [STARTUP] Progress window cleaned up");
                [self setNeedsDisplay];
            });
        }
    });
}

- (void)updateStartupProgress:(float)progress step:(NSString *)step details:(NSString *)details {
    self.currentStartupProgress = progress;
    self.currentStartupStep = step;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_startupProgressWindow && !_startupProgressWindow.hidden) {
            // Update progress bar
#if TARGET_OS_IOS || TARGET_OS_TV
            _startupProgressBar.progress = progress;
            _startupProgressStep.text = step;
            _startupProgressDetails.text = details;
            _startupProgressPercent.text = [NSString stringWithFormat:@"%.0f%%", progress * 100];
#endif
            
            NSLog(@"🚀 [STARTUP] %.0f%% - %@ - %@", progress * 100, step, details);
            [self setNeedsDisplay];
        }
    });
}

- (void)setStartupPhase:(NSString *)phase {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_startupProgressWindow && !_startupProgressWindow.hidden) {
#if TARGET_OS_IOS || TARGET_OS_TV
            _startupProgressTitle.text = [NSString stringWithFormat:@"🚀 %@", phase];
#endif
            NSLog(@"🚀 [STARTUP] Phase: %@", phase);
            [self setNeedsDisplay];
        }
    });
}

- (float)extractProgressFromStatusText:(NSString *)statusText {
    if (!statusText || [statusText length] == 0) {
        return 0.0;
    }
    
    // Look for percentage patterns like "50%" or "Processing: 50%"
    NSRegularExpression *percentRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)%" options:0 error:nil];
    NSTextCheckingResult *percentMatch = [percentRegex firstMatchInString:statusText options:0 range:NSMakeRange(0, statusText.length)];
    
    if (percentMatch) {
        NSString *percentStr = [statusText substringWithRange:[percentMatch rangeAtIndex:1]];
        return [percentStr floatValue] / 100.0;
    }
    
    // Look for fraction patterns like "1234 of 44357" or "Loading channel 1234 of 44357"
    NSRegularExpression *fractionRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*of\\s*(\\d+)" options:0 error:nil];
    NSTextCheckingResult *fractionMatch = [fractionRegex firstMatchInString:statusText options:0 range:NSMakeRange(0, statusText.length)];
    
    if (fractionMatch) {
        NSString *currentStr = [statusText substringWithRange:[fractionMatch rangeAtIndex:1]];
        NSString *totalStr = [statusText substringWithRange:[fractionMatch rangeAtIndex:2]];
        
        float current = [currentStr floatValue];
        float total = [totalStr floatValue];
        
        if (total > 0) {
            return current / total;
        }
    }
    
    // For known loading states, assign approximate progress values
    if ([statusText containsString:@"Initializing"]) return 0.05;
    if ([statusText containsString:@"Checking cache"]) return 0.10;
    if ([statusText containsString:@"Loading channels from cache"]) return 0.20;
    if ([statusText containsString:@"Downloading"]) return 0.30;
    if ([statusText containsString:@"Processing"]) return 0.50;
    if ([statusText containsString:@"Parsing"]) return 0.60;
    if ([statusText containsString:@"Organizing"]) return 0.70;
    if ([statusText containsString:@"Loading EPG"]) return 0.80;
    if ([statusText containsString:@"Matching EPG"]) return 0.85;
    if ([statusText containsString:@"Finalizing"]) return 0.90;
    if ([statusText containsString:@"Complete"] || [statusText containsString:@"Success"]) return 1.0;
    
    return 0.0;
}

- (NSString *)enhanceProgressDetails:(NSString *)statusText forType:(NSString *)type {
    if (!statusText || [statusText length] == 0) {
        return statusText;
    }
    
    // Look for fraction patterns like "1234 of 44357" and enhance them
    NSRegularExpression *fractionRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*of\\s*(\\d+)" options:0 error:nil];
    NSTextCheckingResult *fractionMatch = [fractionRegex firstMatchInString:statusText options:0 range:NSMakeRange(0, statusText.length)];
    
    if (fractionMatch) {
        NSString *currentStr = [statusText substringWithRange:[fractionMatch rangeAtIndex:1]];
        NSString *totalStr = [statusText substringWithRange:[fractionMatch rangeAtIndex:2]];
        
        int current = [currentStr intValue];
        int total = [totalStr intValue];
        
        if ([type isEqualToString:@"channels"]) {
            return [NSString stringWithFormat:@"Loading channel %d of %d", current, total];
        } else if ([type isEqualToString:@"epg"]) {
            return [NSString stringWithFormat:@"Processing EPG program %d of %d", current, total];
        }
    }
    
    // Look for percentage patterns and enhance them
    NSRegularExpression *percentRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)%" options:0 error:nil];
    NSTextCheckingResult *percentMatch = [percentRegex firstMatchInString:statusText options:0 range:NSMakeRange(0, statusText.length)];
    
    if (percentMatch) {
        NSString *percentStr = [statusText substringWithRange:[percentMatch rangeAtIndex:1]];
        int percent = [percentStr intValue];
        
        if ([type isEqualToString:@"channels"]) {
            return [NSString stringWithFormat:@"Channel processing %d%% complete", percent];
        } else if ([type isEqualToString:@"epg"]) {
            return [NSString stringWithFormat:@"EPG processing %d%% complete", percent];
        }
    }
    
    // Look for channel/program counts and enhance them
    if ([statusText containsString:@"channels"] && [type isEqualToString:@"channels"]) {
        // Extract channel count if mentioned
        NSRegularExpression *channelCountRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*channels?" options:0 error:nil];
        NSTextCheckingResult *countMatch = [channelCountRegex firstMatchInString:statusText options:0 range:NSMakeRange(0, statusText.length)];
        
        if (countMatch) {
            NSString *countStr = [statusText substringWithRange:[countMatch rangeAtIndex:1]];
            int count = [countStr intValue];
            return [NSString stringWithFormat:@"Processed %d channels successfully", count];
        }
    }
    
    if ([statusText containsString:@"programs"] && [type isEqualToString:@"epg"]) {
        // Extract program count if mentioned
        NSRegularExpression *programCountRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*programs?" options:0 error:nil];
        NSTextCheckingResult *countMatch = [programCountRegex firstMatchInString:statusText options:0 range:NSMakeRange(0, statusText.length)];
        
        if (countMatch) {
            NSString *countStr = [statusText substringWithRange:[countMatch rangeAtIndex:1]];
            int count = [countStr intValue];
            return [NSString stringWithFormat:@"Processed %d EPG programs", count];
        }
    }
    
    // Enhanced messages for common loading states
    if ([statusText containsString:@"cache"] || [statusText containsString:@"Cache"]) {
        if ([type isEqualToString:@"channels"]) {
            return @"Loading channels from cache...";
        } else if ([type isEqualToString:@"epg"]) {
            return @"Loading EPG data from cache...";
        }
    }
    
    if ([statusText containsString:@"Downloading"]) {
        if ([type isEqualToString:@"channels"]) {
            return @"Downloading channel list from server...";
        } else if ([type isEqualToString:@"epg"]) {
            return @"Downloading EPG data from server...";
        }
    }
    
    if ([statusText containsString:@"Processing"]) {
        // Enhanced processing messages with more detail
        if ([statusText containsString:@"lines"] && [statusText containsString:@"channels"] && [statusText containsString:@"groups"]) {
            // Parse the detailed processing message: "📊 Processing M3U: 1234/5678 lines • 456 channels • 12 groups"
            NSRegularExpression *detailRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)/(\\d+)\\s*lines\\s*•\\s*(\\d+)\\s*channels\\s*•\\s*(\\d+)\\s*groups" options:0 error:nil];
            NSTextCheckingResult *detailMatch = [detailRegex firstMatchInString:statusText options:0 range:NSMakeRange(0, statusText.length)];
            
            if (detailMatch) {
                NSString *currentLines = [statusText substringWithRange:[detailMatch rangeAtIndex:1]];
                NSString *totalLines = [statusText substringWithRange:[detailMatch rangeAtIndex:2]];
                NSString *channelCount = [statusText substringWithRange:[detailMatch rangeAtIndex:3]];
                NSString *groupCount = [statusText substringWithRange:[detailMatch rangeAtIndex:4]];
                
                return [NSString stringWithFormat:@"Processing %@ channels in %@ groups (%@/%@ lines)", channelCount, groupCount, currentLines, totalLines];
            }
        }
        
        if ([type isEqualToString:@"channels"]) {
            return @"Processing channel information...";
        } else if ([type isEqualToString:@"epg"]) {
            return @"Processing program guide data...";
        }
    }
    
    if ([statusText containsString:@"Matching EPG"]) {
        return @"Matching programs with channels...";
    }
    
    if ([statusText containsString:@"Preparing"]) {
        if ([type isEqualToString:@"channels"]) {
            return @"Preparing channel processing...";
        } else if ([type isEqualToString:@"epg"]) {
            return @"Preparing EPG processing...";
        }
    }
    
    if ([statusText containsString:@"timeshift"] || [statusText containsString:@"Timeshift"]) {
        return @"Processing timeshift/catchup data...";
    }
    
    if ([statusText containsString:@"Complete"] || [statusText containsString:@"Success"]) {
        if ([type isEqualToString:@"channels"]) {
            return @"Channel loading completed successfully";
        } else if ([type isEqualToString:@"epg"]) {
            return @"EPG loading completed successfully";
        }
    }
    
    // Return original if no enhancement possible
    return statusText;
}

- (void)handleTimeshiftSeekBackwardTVOS:(NSInteger)seekSeconds {
    NSLog(@"📺 [TIMESHIFT-SEEK] Attempting to seek backward %ld seconds", (long)seekSeconds);
    
    // Get current media URL
    NSURL *currentURL = self.player.media.url;
    if (!currentURL || !currentURL.absoluteString) {
        NSLog(@"📺 [TIMESHIFT-SEEK] No current URL found");
        return;
    }
    
    NSString *currentURLString = currentURL.absoluteString;
    NSLog(@"📺 [TIMESHIFT-SEEK] Current URL: %@", currentURLString);
    
    // Generate new timeshift URL by seeking backward (negative offset)
    NSString *newURLString = [self generateTimeshiftURLFromOriginal:currentURLString withSeekOffsetSeconds:-seekSeconds];
    if (!newURLString) {
        NSLog(@"📺 [TIMESHIFT-SEEK] Failed to generate new timeshift URL");
        return;
    }
    
    NSLog(@"📺 [TIMESHIFT-SEEK] New URL: %@", newURLString);
    
    // Play the new timeshift URL
    NSURL *newURL = [NSURL URLWithString:newURLString];
    VLCMedia *newMedia = [VLCMedia mediaWithURL:newURL];
    
    if (newMedia) {
        [self.player setMedia:newMedia];
        [self.player play];
        NSLog(@"📺 [TIMESHIFT-SEEK] Successfully seeked backward %ld seconds", (long)seekSeconds);
        
        // Show controls briefly to indicate seeking happened
        [self showPlayerControls];
    } else {
        NSLog(@"📺 [TIMESHIFT-SEEK] Failed to create new media from URL");
    }
}

- (void)handleTimeshiftSeekForwardTVOS:(NSInteger)seekSeconds {
    NSLog(@"📺 [TIMESHIFT-SEEK] Attempting to seek forward %ld seconds", (long)seekSeconds);
    
    // Get current media URL
    NSURL *currentURL = self.player.media.url;
    if (!currentURL || !currentURL.absoluteString) {
        NSLog(@"📺 [TIMESHIFT-SEEK] No current URL found");
        return;
    }
    
    NSString *currentURLString = currentURL.absoluteString;
    NSLog(@"📺 [TIMESHIFT-SEEK] Current URL: %@", currentURLString);
    
    // Generate new timeshift URL by seeking forward (positive offset)
    NSString *newURLString = [self generateTimeshiftURLFromOriginal:currentURLString withSeekOffsetSeconds:seekSeconds];
    if (!newURLString) {
        NSLog(@"📺 [TIMESHIFT-SEEK] Failed to generate new timeshift URL");
        return;
    }
    
    NSLog(@"📺 [TIMESHIFT-SEEK] New URL: %@", newURLString);
    
    // Play the new timeshift URL
    NSURL *newURL = [NSURL URLWithString:newURLString];
    VLCMedia *newMedia = [VLCMedia mediaWithURL:newURL];
    
    if (newMedia) {
        [self.player setMedia:newMedia];
        [self.player play];
        NSLog(@"📺 [TIMESHIFT-SEEK] Successfully seeked forward %ld seconds", (long)seekSeconds);
        
        // Show controls briefly to indicate seeking happened
        [self showPlayerControls];
    } else {
        NSLog(@"📺 [TIMESHIFT-SEEK] Failed to create new media from URL");
    }
}

- (NSString *)generateTimeshiftURLFromOriginal:(NSString *)originalURL withSeekOffsetSeconds:(NSInteger)seekOffsetSeconds {
    if (!originalURL || originalURL.length == 0) {
        return nil;
    }
    
    NSLog(@"📺 [SIMPLE-SEEK] Seeking %ld seconds from current position", (long)seekOffsetSeconds);
    
    // Handle different timeshift URL formats by simple pattern replacement
    if ([originalURL containsString:@"start="]) {
        // Find the start= parameter and extract the existing format
        NSRange startRange = [originalURL rangeOfString:@"start="];
        if (startRange.location != NSNotFound) {
            NSInteger startPos = startRange.location + startRange.length;
            NSString *remaining = [originalURL substringFromIndex:startPos];
            
            // Find the end of the start parameter (next & or end of string)
            NSRange endRange = [remaining rangeOfString:@"&"];
            NSString *startValue;
            if (endRange.location != NSNotFound) {
                startValue = [remaining substringToIndex:endRange.location];
            } else {
                startValue = remaining;
            }
            
            NSLog(@"📺 [SIMPLE-SEEK] Original start value: %@", startValue);
            
            // Check if it's a proper date format (YYYY-MM-DD:HH-MM)
            NSRegularExpression *dateFormatRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}:\\d{2}-\\d{2}$" options:0 error:nil];
            if ([dateFormatRegex numberOfMatchesInString:startValue options:0 range:NSMakeRange(0, startValue.length)] > 0) {
                // Parse the date format and add the seek offset
                NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                [formatter setDateFormat:@"yyyy-MM-dd:HH-mm"];
                [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
                
                NSDate *currentDate = [formatter dateFromString:startValue];
                if (currentDate) {
                    // Simply add the seek offset to get the new date
                    NSDate *newDate = [currentDate dateByAddingTimeInterval:seekOffsetSeconds];
                    
                    NSString *newStartValue = [formatter stringFromDate:newDate];
                    NSString *newURL = [originalURL stringByReplacingOccurrencesOfString:startValue withString:newStartValue];
                    NSLog(@"📺 [SIMPLE-SEEK] Date format - old: %@, new: %@", startValue, newStartValue);
                    [formatter release];
                    return newURL;
                } else {
                    NSLog(@"📺 [SIMPLE-SEEK] Failed to parse date format: %@", startValue);
                }
                [formatter release];
            }
            
            // Check if it's a Unix timestamp (10+ digits)
            NSRegularExpression *timestampRegex = [NSRegularExpression regularExpressionWithPattern:@"^\\d{10,}$" options:0 error:nil];
            if ([timestampRegex numberOfMatchesInString:startValue options:0 range:NSMakeRange(0, startValue.length)] > 0) {
                // Simple Unix timestamp - just add the offset
                NSInteger currentTimestamp = [startValue integerValue];
                NSInteger newTimestamp = currentTimestamp + seekOffsetSeconds;
                
                NSString *newStartValue = [NSString stringWithFormat:@"%ld", (long)newTimestamp];
                NSString *newURL = [originalURL stringByReplacingOccurrencesOfString:startValue withString:newStartValue];
                NSLog(@"📺 [SIMPLE-SEEK] Unix timestamp - old: %@, new: %@", startValue, newStartValue);
                return newURL;
            }
        }
    }
    
    // If we can't parse the format, return original URL
    NSLog(@"📺 [SIMPLE-SEEK] Could not parse URL format, returning original");
    return originalURL;
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // Only block simultaneous recognition if progress bar is actively being scrubbed
    if ((gestureRecognizer == _progressBarPanGesture || otherGestureRecognizer == _progressBarPanGesture) && _isScrubbingProgressBar) {
        return NO;
    }
    
    // Allow other gestures to work simultaneously
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    // Only allow progress bar pan gesture to begin if the touch is on the progress bar
    if (gestureRecognizer == _progressBarPanGesture) {
        CGPoint location = [gestureRecognizer locationInView:self];
        
        // Check if we have player controls visible and a progress bar
        if (!_playerControlsVisible) {
            return NO;
        }
        
        NSValue *progressRectValue = objc_getAssociatedObject(self, @selector(progressBarRect));
        if (!progressRectValue) {
            return NO;
        }
        
        CGRect progressRect = [progressRectValue CGRectValue];
        CGRect expandedProgressRect = CGRectInset(progressRect, -20, -20);
        
        // Only begin if touch is on or near the progress bar
        return CGRectContainsPoint(expandedProgressRect, location);
    }
    
    // Allow all other gestures to begin normally
    return YES;
}

#pragma mark - Timeshift Support Methods

// Methods missing from iOS that are needed for Mac-style timeshift functionality

static char frozenTimeValuesKey;
static char timeshiftSeekingKey;
static char lastHoverTextKey;

// Method to get frozen time values
- (NSDictionary *)getFrozenTimeValues {
    return objc_getAssociatedObject(self, &frozenTimeValuesKey);
}

// Method to clear frozen time values
- (void)clearFrozenTimeValues {
    objc_setAssociatedObject(self, &frozenTimeValuesKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &lastHoverTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Method to freeze time values during seeking
- (void)freezeTimeValues:(NSString *)currentTimeStr totalTimeStr:(NSString *)totalTimeStr programStatusStr:(NSString *)programStatusStr {
    NSString *safeCurrentTimeStr = currentTimeStr ?: @"--:--";
    NSString *safeTotalTimeStr = totalTimeStr ?: @"--:--";
    NSString *safeProgramStatusStr = programStatusStr ?: @"Seeking...";
    
    NSDictionary *frozenValues = @{
        @"currentTimeStr": safeCurrentTimeStr,
        @"totalTimeStr": safeTotalTimeStr, 
        @"programStatusStr": safeProgramStatusStr
    };
    
    objc_setAssociatedObject(self, &frozenTimeValuesKey, frozenValues, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)isTimeshiftSeeking {
    NSNumber *seekingState = objc_getAssociatedObject(self, &timeshiftSeekingKey);
    return seekingState ? [seekingState boolValue] : NO;
}

- (void)setTimeshiftSeekingState:(BOOL)seeking {
    objc_setAssociatedObject(self, &timeshiftSeekingKey, @(seeking), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    if (!seeking) {
        [self clearFrozenTimeValues];
    }
    
    [self setNeedsDisplay];
}

- (NSString *)formatProgramString:(VLCProgram *)program formatter:(NSDateFormatter *)formatter isDimmed:(BOOL)isDimmed {
    if (!program || !formatter) {
        return @"";
    }
    
    NSTimeInterval displayOffsetSeconds = self.epgTimeOffsetHours * 3600.0;
    NSDate *displayProgramStartTime = [program.startTime dateByAddingTimeInterval:displayOffsetSeconds];
    NSDate *displayProgramEndTime = [program.endTime dateByAddingTimeInterval:displayOffsetSeconds];
    
    NSString *startStr = [formatter stringFromDate:displayProgramStartTime];
    NSString *endStr = [formatter stringFromDate:displayProgramEndTime];
    
    // Truncate long program titles
    NSString *title = program.title ?: @"Unknown";
    NSInteger maxLength = isDimmed ? 20 : 25;
    if (title.length > maxLength) {
        title = [[title substringToIndex:(maxLength - 3)] stringByAppendingString:@"..."];
    }
    
    NSString *programStr = [NSString stringWithFormat:@"%@-%@ %@", startStr, endStr, title];
    
    if (isDimmed) {
        programStr = [NSString stringWithFormat:@"◦ %@", programStr];
    }
    
    return programStr;
}

#pragma mark - Movie Info Cache Methods

// TODO: This method duplicates Mac functionality and should be removed
// The shared Mac method loadMovieInfoFromCacheForChannel is already available
// Load movie info from cache for a channel  
- (BOOL)loadMovieInfoFromCacheForChannel:(VLCChannel *)channel {
    if (!channel || !channel.name) return NO;
    
    // Get the movie info cache directory
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *movieInfoCacheDir = [appSupportDir stringByAppendingPathComponent:@"MovieInfo"];
    
    // Create a safe filename from the channel name
    NSString *safeFilename = [self md5HashForString:channel.name];
    NSString *cacheFilePath = [movieInfoCacheDir stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"%@.plist", safeFilename]];
    
    // Check if cache file exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cacheFilePath]) {
        return NO;
    }
    
    // Load the plist file
    NSDictionary *movieInfo = [NSDictionary dictionaryWithContentsOfFile:cacheFilePath];
    
    // Check if we have cached data and it's not too old (30 days)
    if (movieInfo) {
        NSNumber *timestamp = [movieInfo objectForKey:@"timestamp"];
        if (timestamp) {
            NSTimeInterval cacheAge = [[NSDate date] timeIntervalSince1970] - [timestamp doubleValue];
            if (cacheAge < (30 * 24 * 60 * 60)) { // 30 days in seconds
                
                // Validate that cached data is actually useful before loading it
                NSString *cachedDescription = [movieInfo objectForKey:@"description"];
                NSString *cachedYear = [movieInfo objectForKey:@"year"];
                NSString *cachedGenre = [movieInfo objectForKey:@"genre"];
                NSString *cachedDirector = [movieInfo objectForKey:@"director"];
                NSString *cachedRating = [movieInfo objectForKey:@"rating"];
                
                // Check if we have at least a meaningful description OR sufficient metadata
                BOOL hasUsefulDescription = (cachedDescription && [cachedDescription length] > 10);
                BOOL hasUsefulMetadata = ((cachedYear && [cachedYear length] > 0) || 
                                         (cachedGenre && [cachedGenre length] > 0) || 
                                         (cachedDirector && [cachedDirector length] > 0) || 
                                         (cachedRating && [cachedRating length] > 0));
                
                if (!hasUsefulDescription && !hasUsefulMetadata) {
                    // Remove the incomplete cache file
                    [fileManager removeItemAtPath:cacheFilePath error:nil];
                    return NO;
                }
                
                // Load data from cache only if it passes validation
                channel.movieId = [movieInfo objectForKey:@"movieId"];
                channel.movieDescription = cachedDescription;
                channel.movieGenre = cachedGenre;
                channel.movieYear = cachedYear;
                channel.movieRating = cachedRating;
                channel.movieDuration = [movieInfo objectForKey:@"duration"];
                channel.movieDirector = [movieInfo objectForKey:@"director"];
                channel.movieCast = [movieInfo objectForKey:@"cast"];
                
                // Mark as loaded
                channel.hasStartedFetchingMovieInfo = YES;
                channel.hasLoadedMovieInfo = YES;
                
                return YES;
            } else {
                // Remove old cache file
                [fileManager removeItemAtPath:cacheFilePath error:nil];
            }
        }
    }
    
    return NO;
}

// Get cached poster path for a channel
- (NSString *)cachedPosterPathForChannel:(VLCChannel *)channel {
    if (!channel || !channel.name) return nil;
    
    // Get the posters cache directory
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *postersCacheDir = [appSupportDir stringByAppendingPathComponent:@"Cache/Posters"];
    
    // Create a safe filename from the channel name
    NSString *safeFilename = [self md5HashForString:channel.name];
    
    // Check for different image extensions
    NSArray *extensions = @[@"jpg", @"jpeg", @"png", @"webp"];
    for (NSString *ext in extensions) {
        NSString *posterPath = [postersCacheDir stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"%@.%@", safeFilename, ext]];
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:posterPath]) {
            return posterPath;
        }
    }
    
    return nil;
}

#pragma mark - Movie Info Methods

// Helper to check if a string is numeric
- (BOOL)isNumeric:(NSString *)string {
    NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
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
                    return idValue;
                }
            }
        }
    }
    
    // If we couldn't extract an ID, return nil
    return nil;
}

// Construct API URL for movie info
- (NSString *)constructMovieApiUrlForChannel:(VLCChannel *)channel {
    // We need: server, port, username, password, and movie ID
    if (!channel || !self.m3uFilePath) return nil;
    
    NSString *movieId = channel.movieId;
    if (!movieId) {
        movieId = [self extractMovieIdFromUrl:channel.url];
        if (!movieId) {
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
    
    return apiUrl;
}

// Save movie info to cache
- (void)saveMovieInfoToCache:(VLCChannel *)channel {
    if (!channel || !channel.name || !channel.hasLoadedMovieInfo) return;
    
    // Get the movie info cache directory
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *movieInfoCacheDir = [appSupportDir stringByAppendingPathComponent:@"MovieInfo"];
    
    // Create cache directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fileManager fileExistsAtPath:movieInfoCacheDir]) {
        [fileManager createDirectoryAtPath:movieInfoCacheDir 
                withIntermediateDirectories:YES 
                                 attributes:nil 
                                      error:&error];
        if (error) {
            NSLog(@"Failed to create movie info cache directory: %@", error.localizedDescription);
            return;
        }
    }
    
    // Create a safe filename from the channel name
    NSString *safeFilename = [self md5HashForString:channel.name];
    NSString *cacheFilePath = [movieInfoCacheDir stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"%@.plist", safeFilename]];
    
    // Create dictionary with movie info
    NSMutableDictionary *movieInfo = [NSMutableDictionary dictionary];
    [movieInfo setObject:@([[NSDate date] timeIntervalSince1970]) forKey:@"timestamp"];
    
    if (channel.movieId) [movieInfo setObject:channel.movieId forKey:@"movieId"];
    if (channel.movieDescription) [movieInfo setObject:channel.movieDescription forKey:@"description"];
    if (channel.movieGenre) [movieInfo setObject:channel.movieGenre forKey:@"genre"];
    if (channel.movieYear) [movieInfo setObject:channel.movieYear forKey:@"year"];
    if (channel.movieRating) [movieInfo setObject:channel.movieRating forKey:@"rating"];
    if (channel.movieDuration) [movieInfo setObject:channel.movieDuration forKey:@"duration"];
    if (channel.movieDirector) [movieInfo setObject:channel.movieDirector forKey:@"director"];
    if (channel.movieCast) [movieInfo setObject:channel.movieCast forKey:@"cast"];
    
    // Write to file
    BOOL success = [movieInfo writeToFile:cacheFilePath atomically:YES];
    if (!success) {
        NSLog(@"Failed to save movie info to cache for: %@", channel.name);
    }
}

// Static queue and semaphore for request throttling
static dispatch_queue_t movieInfoQueue = nil;
static dispatch_semaphore_t movieInfoSemaphore = nil;
static NSUInteger maxConcurrentRequests = 2; // Limit concurrent requests

// Initialize request throttling (call this once)
+ (void)initializeMovieInfoThrottling {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        movieInfoQueue = dispatch_queue_create("com.vlc.movieinfo", DISPATCH_QUEUE_CONCURRENT);
        movieInfoSemaphore = dispatch_semaphore_create(maxConcurrentRequests);
    });
}

// Test server connectivity before making movie info requests
- (void)testServerConnectivity:(NSString *)baseUrl completion:(void(^)(BOOL isReachable))completion {
    // Try a simple player_api request to test connectivity
    NSString *testUrl = [NSString stringWithFormat:@"%@/player_api.php", baseUrl];
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 10.0; // Short timeout for connectivity test
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:testUrl]];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL isReachable = NO;
        if (!error && response) {
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                // Server is reachable if we get any HTTP response (even error codes)
                isReachable = (httpResponse.statusCode > 0);
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(isReachable);
        });
    }];
    
    [task resume];
}

// Fetch movie information from the API with throttling and retry logic
- (void)fetchMovieInfoForChannel:(VLCChannel *)channel {
    if (!channel || channel.hasLoadedMovieInfo) return;
    
    // Try to load from cache first before making network request
    if ([self loadMovieInfoFromCacheForChannel:channel]) {
        return; // Successfully loaded from cache, no need to fetch from network
    }
    
    NSString *apiUrl = [self constructMovieApiUrlForChannel:channel];
    if (!apiUrl) {
        return;
    }
    
    // Mark as started fetching to prevent multiple simultaneous requests
    channel.hasStartedFetchingMovieInfo = YES;
    
    // Initialize throttling if needed
    [VLCUIOverlayView initializeMovieInfoThrottling];
    
    // Use the movie info queue with throttling
    dispatch_async(movieInfoQueue, ^{
        // Wait for semaphore (throttle concurrent requests)
        dispatch_semaphore_wait(movieInfoSemaphore, DISPATCH_TIME_FOREVER);
        
        // Add a small delay between requests to avoid overwhelming the server
        usleep(500000); // 500ms delay
        
        [self performMovieInfoRequest:channel apiUrl:apiUrl retryCount:0];
    });
}

// Perform the actual network request with retry logic
- (void)performMovieInfoRequest:(VLCChannel *)channel apiUrl:(NSString *)apiUrl retryCount:(NSInteger)retryCount {
    const NSInteger maxRetries = 2;
    const NSTimeInterval baseDelay = 2.0; // Start with 2 second delay
    
    // Create custom URL session configuration with progressive timeouts
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 45.0 + (retryCount * 15.0); // Increase timeout with retries
    config.timeoutIntervalForResource = 90.0 + (retryCount * 30.0);
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    
    // Enable cellular access for iOS
    #if TARGET_OS_IOS
    config.allowsCellularAccess = YES;
    #endif
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    
    // Create the URL request
    NSURL *url = [NSURL URLWithString:apiUrl];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    
    // Set appropriate headers for iOS
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"keep-alive" forHTTPHeaderField:@"Connection"];
    
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request 
                                               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        
        // Always signal the semaphore when done
        dispatch_semaphore_signal(movieInfoSemaphore);
        
        if (error || !data) {
            // Check if we should retry
            BOOL shouldRetry = (retryCount < maxRetries) && 
                              error && 
                              (error.code == NSURLErrorTimedOut || 
                               error.code == NSURLErrorNetworkConnectionLost ||
                               error.code == NSURLErrorNotConnectedToInternet);
            
            if (shouldRetry) {
                NSTimeInterval delay = baseDelay * pow(2, retryCount); // Exponential backoff
                NSLog(@"Movie info fetch failed for '%@' (attempt %ld/%ld): %@. Retrying in %.1fs...", 
                      channel.name, (long)(retryCount + 1), (long)(maxRetries + 1), error.localizedDescription, delay);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    dispatch_async(movieInfoQueue, ^{
                        dispatch_semaphore_wait(movieInfoSemaphore, DISPATCH_TIME_FOREVER);
                        [self performMovieInfoRequest:channel apiUrl:apiUrl retryCount:retryCount + 1];
                    });
                });
                return;
            }
            
            // Final failure
            NSLog(@"Movie info fetch permanently failed for '%@' after %ld attempts: %@", 
                  channel.name, (long)(retryCount + 1), error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                channel.hasStartedFetchingMovieInfo = NO;
                [self setNeedsDisplay];
            });
            return;
        }
        
        // Validate HTTP response code
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSInteger statusCode = [httpResponse statusCode];
            
            if (statusCode < 200 || statusCode >= 300) {
                NSLog(@"HTTP error %ld for movie info: %@ (attempt %ld)", (long)statusCode, channel.name, (long)(retryCount + 1));
                dispatch_async(dispatch_get_main_queue(), ^{
                    channel.hasStartedFetchingMovieInfo = NO;
                    [self setNeedsDisplay];
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
            NSLog(@"JSON parsing error for '%@': %@", channel.name, jsonError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                channel.hasStartedFetchingMovieInfo = NO;
                [self setNeedsDisplay];
            });
            return;
        }
        
        // Extract info from response
        NSDictionary *info = [jsonResponse objectForKey:@"info"];
        if (!info || ![info isKindOfClass:[NSDictionary class]]) {
            NSLog(@"Invalid movie info response format for '%@' - no 'info' object", channel.name);
            dispatch_async(dispatch_get_main_queue(), ^{
                channel.hasStartedFetchingMovieInfo = NO;
                [self setNeedsDisplay];
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
            if (coverUrl && coverUrl.length > 0) {
                channel.logo = coverUrl;
                
                // Download the poster image asynchronously
                [self loadImageAsynchronously:coverUrl forChannel:channel];
            }
            
            channel.hasLoadedMovieInfo = YES;
            NSLog(@"✅ Successfully loaded movie info for '%@' (attempt %ld)", channel.name, (long)(retryCount + 1));
            
            // Save the movie info to cache after successful fetching
            [self saveMovieInfoToCache:channel];
            
            // Trigger UI update
            [self setNeedsDisplay];
        });
    }];
    
    [dataTask resume];
}

// Async version of fetchMovieInfoForChannel for iOS
- (void)fetchMovieInfoForChannelAsync:(VLCChannel *)channel {
    if (!channel) return;
    
    // Fetch movie info asynchronously on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Call the actual movie info fetching logic
        [self fetchMovieInfoForChannel:channel];
    });
}

// Generate cache path for image URL
- (NSString *)cachePathForImageURL:(NSString *)url {
    if (!url || url.length == 0) return nil;
    
    // Create a unique filename based on the URL
    NSString *filename = [self md5HashForString:url];
    
    // Add the original extension if it exists
    NSString *extension = [url pathExtension];
    if (extension && extension.length > 0) {
        filename = [filename stringByAppendingFormat:@".%@", extension];
    } else {
        filename = [filename stringByAppendingString:@".png"];
    }
    
    return [[self postersCacheDirectory] stringByAppendingPathComponent:filename];
}

// Get posters cache directory
- (NSString *)postersCacheDirectory {
    NSString *appSupportDir = [self applicationSupportDirectory];
    NSString *postersCacheDir = [appSupportDir stringByAppendingPathComponent:@"Cache/Posters"];
    
    // Create directory if it doesn't exist
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:postersCacheDir]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:postersCacheDir 
                withIntermediateDirectories:YES 
                                 attributes:nil 
                                      error:&error];
        if (error) {
            NSLog(@"Failed to create posters cache directory: %@", error.localizedDescription);
        }
    }
    
    return postersCacheDir;
}

// Download poster image asynchronously for iOS
- (void)loadImageAsynchronously:(NSString *)imageUrl forChannel:(VLCChannel *)channel {
    // Thorough validation to prevent empty URL errors
    if (!imageUrl || !channel || [imageUrl length] == 0 || 
        [imageUrl isEqualToString:@"(null)"] || [imageUrl isEqualToString:@"null"]) {
        NSLog(@"Cannot load image: Invalid or empty URL or channel");
        return;
    }
    
    // Don't reload if we already have a cached image
    if (channel.cachedPosterImage) {
        return;
    }
    
    // Check if loading is already in progress using associated objects
    if (objc_getAssociatedObject(channel, "imageLoadingInProgress")) {
        return;
    }
    
    // Mark that we're starting image loading
    objc_setAssociatedObject(channel, "imageLoadingInProgress", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Try to load from disk cache first
    [self loadCachedPosterImageForChannel:channel];
    
    // If successfully loaded from disk cache, return early
    if (channel.cachedPosterImage) {
        objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self setNeedsDisplay];
        return;
    }
    
    // Add protocol prefix if missing
    if (![imageUrl hasPrefix:@"http://"] && ![imageUrl hasPrefix:@"https://"]) {
        imageUrl = [@"http://" stringByAppendingString:imageUrl];
    }
    
    NSLog(@"🖼 Starting poster download for '%@' from: %@", channel.name, imageUrl);
    
    // Create URL object with validation
    NSURL *url = [NSURL URLWithString:imageUrl];
    if (!url || !url.host || [url.host length] == 0) {
        NSLog(@"Invalid image URL: %@", imageUrl);
        objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    
    // Create session with appropriate timeout for images
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 60.0;
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request 
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // Always clear the loading flag when done
        dispatch_async(dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(channel, "imageLoadingInProgress", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
        
        if (error) {
            NSLog(@"Poster download failed for '%@': %@", channel.name, error.localizedDescription);
            return;
        }
        
        // Check HTTP status
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode != 200) {
                NSLog(@"HTTP error downloading poster for '%@': %ld", channel.name, (long)httpResponse.statusCode);
                return;
            }
        }
        
        if (!data || data.length == 0) {
            NSLog(@"Empty poster data received for '%@'", channel.name);
            return;
        }
        
        // Process the image on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Create image from data
            UIImage *downloadedImage = [UIImage imageWithData:data];
            if (!downloadedImage) {
                NSLog(@"Failed to create image from downloaded data for '%@'", channel.name);
                return;
            }
            
            // Cache the image in memory
            channel.cachedPosterImage = downloadedImage;
            
            // Save to disk cache for persistence
            [self savePosterImageToDiskCache:downloadedImage forURL:imageUrl];
            
            NSLog(@"✅ Successfully downloaded poster for '%@' (%.1f KB)", 
                  channel.name, (float)data.length / 1024.0);
            
            // Trigger a redraw to show the new image
            [self setNeedsDisplay];
        });
    }];
    
    [task resume];
}

// Save poster image to disk cache for iOS
- (void)savePosterImageToDiskCache:(UIImage *)image forURL:(NSString *)url {
    if (!image || !url || url.length == 0) return;
    
    NSString *cachePath = [self cachePathForImageURL:url];
    if (!cachePath) return;
    
    // Make sure the directory exists
    NSString *directory = [cachePath stringByDeletingLastPathComponent];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:directory]) {
        NSError *dirError = nil;
        [fileManager createDirectoryAtPath:directory 
                withIntermediateDirectories:YES 
                                 attributes:nil 
                                      error:&dirError];
        if (dirError) {
            NSLog(@"Error creating poster cache directory: %@", dirError.localizedDescription);
            return;
        }
    }
    
    // Convert UIImage to PNG data
    NSData *imageData = UIImagePNGRepresentation(image);
    if (!imageData) {
        NSLog(@"Failed to convert image to PNG data");
        return;
    }
    
    // Write to a temporary file first, then move to final location for atomicity
    NSString *tempPath = [cachePath stringByAppendingString:@".temp"];
    BOOL tempSuccess = [imageData writeToFile:tempPath atomically:YES];
    
    if (tempSuccess) {
        NSError *moveError = nil;
        // Remove existing file if it exists
        if ([fileManager fileExistsAtPath:cachePath]) {
            [fileManager removeItemAtPath:cachePath error:nil];
        }
        // Move the temp file to the final location
        BOOL moveSuccess = [fileManager moveItemAtPath:tempPath toPath:cachePath error:&moveError];
        
        if (moveSuccess) {
            NSLog(@"💾 Saved poster to disk cache: %@", [cachePath lastPathComponent]);
        } else {
            NSLog(@"Failed to move temp file to cache path: %@", moveError.localizedDescription);
        }
    } else {
        NSLog(@"Failed to write image to temp path: %@", tempPath);
    }
}

// Load poster image from disk cache for iOS
- (void)loadCachedPosterImageForChannel:(VLCChannel *)channel {
    if (!channel || !channel.logo || channel.logo.length == 0) return;
    
    // Don't load if already in memory - this prevents unnecessary disk I/O
    if (channel.cachedPosterImage) {
        return;
    }
    
    NSString *cachePath = [self cachePathForImageURL:channel.logo];
    if (cachePath) {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:cachePath]) {
            // Check file age to ensure cache is still valid (e.g., not older than 30 days)
            NSError *error;
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:cachePath error:&error];
            if (attributes && !error) {
                NSDate *modificationDate = [attributes fileModificationDate];
                NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:modificationDate];
                
                // Cache expires after 30 days (2592000 seconds)
                if (age > 2592000) {
                    [fileManager removeItemAtPath:cachePath error:nil];
                    return;
                }
            }
            
            // Load the cached image data
            NSData *imageData = [NSData dataWithContentsOfFile:cachePath];
            if (imageData && imageData.length > 0) {
                UIImage *cachedImage = [UIImage imageWithData:imageData];
                if (cachedImage) {
                    channel.cachedPosterImage = cachedImage;
                    NSLog(@"Loaded poster image from disk cache for channel: %@ (%.1f KB)", 
                          channel.name, (float)imageData.length / 1024.0);
                } else {
                    NSLog(@"Failed to create image from cached data for %@, removing corrupt cache", channel.name);
                    [fileManager removeItemAtPath:cachePath error:nil];
                }
            } else {
                NSLog(@"Empty or corrupt cache file for %@, removing", channel.name);
                [fileManager removeItemAtPath:cachePath error:nil];
            }
        }
    }
}

@end

#endif // TARGET_OS_IOS || TARGET_OS_TV 
