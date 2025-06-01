//
//  VLCOverlayView.m
//  BasicPlayerWithPlaylist
//
//  Created by Nurettin Akpolat on 13/05/2025.
//

#import "VLCOverlayView.h"
#import "VLCOverlayView_Private.h"
#import "VLCChannel.h"
#import "VLCProgram.h"
#import <VLCKit/VLCKit.h>

// Import category headers
#import "VLCOverlayView+Utilities.h"
#import "VLCOverlayView+UI.h"
#import "VLCOverlayView+ChannelManagement.h"
#import "VLCOverlayView+EPG.h"
#import "VLCOverlayView+Favorites.h"
#import "VLCOverlayView+Caching.h"
#import "VLCOverlayView+PlayerControls.h"


// Implementation of global progress message
NSString *gProgressMessage = nil;
NSLock *gProgressMessageLock = nil;

@implementation VLCOverlayView

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Initialize our global progress message lock
        if (gProgressMessageLock == nil) {
            gProgressMessageLock = [[NSLock alloc] init];
        }
        
        // Initialize synchronization objects
        channelsLock = [[NSLock alloc] init];
        epgDataLock = [[NSLock alloc] init];
        
        // Initialize data structures with default values
        [self ensureDataStructuresInitialized];
        
        // Set default colors with semi-transparent black backgrounds
        self.backgroundColor = [NSColor colorWithCalibratedRed:0.0 green:0.0 blue:0.0 alpha:0.75];
        self.hoverColor = [NSColor colorWithCalibratedRed:0.2 green:0.5 blue:0.8 alpha:0.6];
        self.textColor = [NSColor whiteColor];
        self.groupColor = [NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:0.85];
        
        // Initialize UI state - start with menu hidden
        self.isChannelListVisible = NO; // Start hidden
        self.hoveredChannelIndex = -1;
        self.selectedChannelIndex = -1;
        self.isLoading = NO;
        self.showEpgPanel = NO;
        self.isTextFieldActive = NO;
        trackingArea = nil;
        
        // Initialize text field properties
        self.m3uFieldActive = NO;
        self.epgFieldActive = NO;
        self.epgTimeOffsetDropdownActive = NO;
        self.epgTimeOffsetDropdownHoveredIndex = -1; // No hover initially
        self.tempM3uUrl = @"";
        self.tempEpgUrl = @"";
        self.m3uCursorPosition = 0;
        self.epgCursorPosition = 0;
        self.epgTimeOffsetHours = 0; // Default to no offset
        
        // Initialize scroll positions
        categoryScrollPosition = 0;
        groupScrollPosition = 0;
        channelScrollPosition = 0;
        activeScrollPanel = 0;
        self.movieInfoScrollPosition = 0;
        self.isHoveringMovieInfoPanel = NO;
        
        // Initialize user interaction tracking
        isUserInteracting = YES; // Start with YES to prevent immediate hiding
        lastInteractionTime = [NSDate timeIntervalSinceReferenceDate];
        
        // Initialize cursor hiding tracking
        lastMouseMoveTime = [NSDate timeIntervalSinceReferenceDate];
        isCursorHidden = NO;
        
        // Initialize EPG auto-scroll tracking
        lastAutoScrolledChannelIndex = -1;
        hasUserScrolledEpg = NO;
        
        // Initialize EPG program context menu tracking
        rightClickedProgram = nil;
        rightClickedProgramChannel = nil;
        
        // Initialize EPG data
        self.epgData = [NSMutableDictionary dictionary];
        
        // Setup tracking area for mouse events
        [self setupTrackingArea];
        
        // Set the default EPG URL
        self.epgUrl = @"";
        
        // Set the default m3u file path to the local file in Application Support
        self.m3uFilePath = [self localM3uFilePath];
        
        // Initialize threading resources
        serialAccessQueue = dispatch_queue_create("com.vlckit.overlayview.serialqueue", NULL);
        
        // Initialize input state
        self.inputUrlString = @"";
        
        // Initialize dropdown manager
        self.dropdownManager = [[VLCDropdownManager alloc] initWithParentView:self];
        
        // Initialize EPG time offset dropdown
        [self setupEpgTimeOffsetDropdown];
        
        // Initialize new UI components
        self.m3uTextField = nil; // Will be created when needed
        self.epgLabel = nil; // Will be created when needed
        
        // Initialize player controls if available
        if ([self respondsToSelector:@selector(setupPlayerControls)]) {
            NSLog(@"Setting up player controls during initialization");
            [self setupPlayerControls];
        } else {
            NSLog(@"Player controls methods not available");
        }
        
        // Start the auto-hide timer
        [self scheduleInteractionCheck];
    }
    return self;
}

// Add this method to update tracking area when the frame changes
- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    
    // Update tracking area to match new size
    [self setupTrackingArea];
    
    // Reset interaction timestamp to prevent immediate hiding after resize
    [self markUserInteraction];
}

// Ensure mouse movement tracking works even when view moves
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self setupTrackingArea];
    [self markUserInteraction];
    
    // Make this view the first responder to receive keyboard events
    if (self.window) {
        NSLog(@"Making overlay view first responder for keyboard events");
        [self.window makeFirstResponder:self];
        
        // Add window notifications for fullscreen changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidEnterFullScreen:)
                                                     name:NSWindowDidEnterFullScreenNotification
                                                   object:self.window];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidExitFullScreen:)
                                                     name:NSWindowDidExitFullScreenNotification
                                                   object:self.window];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidBecomeActive:)
                                                     name:NSApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
}

#pragma mark - Memory Management

- (void)dealloc {
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // Ensure cursor is visible before dealloc
    [self ensureCursorVisible];
    
    // Stop any ongoing operations
    [self stopProgressRedrawTimer];
    [autoHideTimer invalidate];
    
    // Invalidate any timers
    if (movieInfoHoverTimer) {
        [movieInfoHoverTimer invalidate];
        movieInfoHoverTimer = nil;
    }
    
    // Release retained objects
    [channelsLock release];
    [epgDataLock release];
    
    self.channels = nil;
    self.groups = nil;
    self.channelsByGroup = nil;
    self.groupsByCategory = nil;
    self.categories = nil;
    self.backgroundColor = nil;
    self.hoverColor = nil;
    self.textColor = nil;
    self.groupColor = nil;
    self.inputUrlString = nil;
    self.loadingStatusText = nil;
    self.loadingProgressTimer = nil;
    self.epgUrl = nil;
    self.epgLoadingStatusText = nil;
    self.epgData = nil;
    self.simpleChannelNames = nil;
    self.simpleChannelUrls = nil;
    
    // Release text field properties
    self.tempM3uUrl = nil;
    self.tempEpgUrl = nil;
    
    // Release dropdown manager
    self.dropdownManager = nil;
    
    // Release new UI components
    self.m3uTextField = nil;
    self.epgLabel = nil;
    
    // Release tracking area
    if (trackingArea) {
        [trackingArea release];
        trackingArea = nil;
    }
    
    dispatch_release(serialAccessQueue);
    
    [super dealloc];
}

#pragma mark - Drawing

- (BOOL)isOpaque {
    return NO;
}

// Enable the view to receive keyboard events
- (BOOL)acceptsFirstResponder {
    return YES;
}

// Handle keyboard events
- (void)keyDown:(NSEvent *)event {
    NSString *characters = [event charactersIgnoringModifiers];
    
    if ([characters length] > 0) {
        unichar keyChar = [characters characterAtIndex:0];
        
        // Handle ESC key (keycode 27)
        if (keyChar == 27) { // ESC key
            NSLog(@"ESC key pressed");
            
            // Priority 1: Hide channel list menu if it's visible
            if (self.isChannelListVisible) {
                NSLog(@"ESC: Hiding channel list menu");
                // Hide all controls before hiding the menu
                [self hideControls];
                self.isChannelListVisible = NO;
                [self setNeedsDisplay:YES];
                return; // Don't pass to super, and don't check player controls yet
            }
            
            // Priority 2: Hide player controls if they're visible (only if menu is already hidden)
            extern BOOL playerControlsVisible;
            if (playerControlsVisible) {
                NSLog(@"ESC: Hiding player controls");
                [self hidePlayerControls:nil];
                return; // Don't pass to super
            }
            
            NSLog(@"ESC: Nothing to hide");
        }
    }
    
    // Pass other key events to super
    [super keyDown:event];
}

#pragma mark - Window Notifications

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    NSLog(@"Entered fullscreen - cursor hiding will be active");
    // Reset mouse movement time when entering fullscreen
    lastMouseMoveTime = [NSDate timeIntervalSinceReferenceDate];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    NSLog(@"Exited fullscreen - ensuring cursor is visible");
    // Always show cursor when exiting fullscreen
    [self ensureCursorVisible];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    NSLog(@"Application became active - ensuring cursor is visible");
    // Always show cursor when app becomes active
    [self ensureCursorVisible];
}

#pragma mark - Player Controls Setup

// This method is implemented in VLCOverlayView+PlayerControls.m
// Here we just have a stub to ensure the category method is found properly
- (void)setupPlayerControls {
    // This is now implemented in VLCOverlayView+PlayerControls.m
    // The category implementation will be called instead when this method is invoked
}

- (void)drawRect:(NSRect)dirtyRect {
    // Hide all controls first to ensure clean state
    [self hideControls];
    
    // Prepare the simple channel lists for display
    [self prepareSimpleChannelLists];
    
    // Log current state for debugging
    extern BOOL playerControlsVisible;
    //NSLog(@"drawRect called with dirtyRect: {{%.1f, %.1f}, {%.1f, %.1f}} - playerControlsVisible: %@, menu: %@",
    //     dirtyRect.origin.x, dirtyRect.origin.y, dirtyRect.size.width, dirtyRect.size.height,
    //     playerControlsVisible ? @"YES" : @"NO",
    //     self.isChannelListVisible ? @"visible" : @"hidden");
    
    // Call superclass
    [super drawRect:dirtyRect];
    
    // If channel list and EPG are not visible, draw player controls if needed
    if (!self.isChannelListVisible && !self.showEpgPanel) {
        // Draw player controls if player exists (NO background drawing here)
        if (self.player && playerControlsVisible) {
            NSLog(@"Will draw player controls");
            [self drawPlayerControls:dirtyRect];
        } else if (self.player) {
            NSLog(@"Player exists but controls not visible");
        }
        
        // Even if we're returning early, still draw the loading indicator if needed
        if (self.isLoading) {
            [self drawLoadingIndicator:dirtyRect];
        }
        return;
    }
    
    // Update UI components visibility based on menu state
    [self updateUIComponentsVisibility];
    
    // Only draw menu background if the menu is visible
    if (self.isChannelListVisible) {
        // Use semi-transparent black background for menu
        [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.7] set];
        NSRectFill(self.bounds);
        
        // Draw the three-panel layout
        [self drawCategories:dirtyRect];
        
        if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < [self.categories count]) {
            [self drawGroups:dirtyRect];
            
            // Get the appropriate groups based on category
            NSArray *groups = nil;
            if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
                groups = [self safeGroupsForCategory:@"FAVORITES"];
            } else if (self.selectedCategoryIndex == CATEGORY_TV) {
                groups = [self safeTVGroups];
            } else if (self.selectedCategoryIndex == CATEGORY_MOVIES) {
                groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
            } else if (self.selectedCategoryIndex == CATEGORY_SERIES) {
                groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
            }

            // Only draw the channel list if we have a selected group
            if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < (NSInteger)[groups count]) {
                if (self.showEpgPanel) {
                    [self drawEpgPanel:dirtyRect];
                } else {
                    [self drawChannelList:dirtyRect];
                }
            }
            
            // Draw settings panel if settings category is selected
            if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
                [self drawSettingsPanel:dirtyRect];
            }
        }
    }
    
    // Draw URL input field if active
    if (self.isTextFieldActive) {
        [self drawURLInputField:dirtyRect];
    }
    
    // Draw dropdowns LAST (except loading indicator) for proper z-ordering
    [self drawDropdowns:dirtyRect];
    
    // Draw loading indicator LAST to ensure it's on top of everything else
    if (self.isLoading) {
        [self drawLoadingIndicator:dirtyRect];
    }
}

#pragma mark - Helper Methods

- (void)updateLayout {
    [self setupTrackingArea];
    [self setNeedsDisplay:YES];
}

- (BOOL)isOverlayActive {
    // The overlay is considered active if loading, or showing channel list/EPG panel
    if (self.isLoading) {
        return YES;
    }

    // Also active if showing channel list or EPG panel
    if (!self.isChannelListVisible && !self.showEpgPanel) {
        return NO;
    }
    
    return YES;
}

- (void)updateViewBasedOnSelection {
    // Get the appropriate groups based on category and selection
    NSArray *groups = nil;
    
    if (self.selectedCategoryIndex >= 0 && self.selectedCategoryIndex < [self.categories count]) {
        NSString *currentCategory = [self.categories objectAtIndex:self.selectedCategoryIndex];
        
        if (self.selectedCategoryIndex == CATEGORY_FAVORITES) {
            groups = [self safeGroupsForCategory:@"FAVORITES"];
        } else if (self.selectedCategoryIndex == CATEGORY_TV) {
            groups = [self safeTVGroups];
        } else if (self.selectedCategoryIndex == CATEGORY_MOVIES) {
            groups = [self safeValueForKey:@"MOVIES" fromDictionary:self.groupsByCategory];
        } else if (self.selectedCategoryIndex == CATEGORY_SERIES) {
            groups = [self safeValueForKey:@"SERIES" fromDictionary:self.groupsByCategory];
        } else if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
            groups = [self safeValueForKey:@"SETTINGS" fromDictionary:self.groupsByCategory];
        }
        
        // Update the available channels based on group selection
        if (self.selectedGroupIndex >= 0 && self.selectedGroupIndex < (NSInteger)[groups count]) {
            NSString *selectedGroup = [groups objectAtIndex:self.selectedGroupIndex];
            NSArray *channelsInGroup = [self.channelsByGroup objectForKey:selectedGroup];
            
            // Prepare simple display lists
            [self prepareSimpleChannelLists];
        }
        
        // If we're in settings category, we should show settings instead of channels
        if (self.selectedCategoryIndex == CATEGORY_SETTINGS) {
            // Nothing special to prepare for now
        }
    }
    
    [self setNeedsDisplay:YES];
}

- (void)scrollToSelectedItems {
    // This can be implemented to scroll to ensure the selected items are visible
    [self setNeedsDisplay:YES];
}

- (void)setCurrentCategory:(NSInteger)categoryIndex {
    // Hide all controls before changing category
    [self hideControls];
    
    self.selectedCategoryIndex = categoryIndex;
    self.selectedGroupIndex = -1;
    self.selectedChannelIndex = -1;
    [self updateViewBasedOnSelection];
}

@end
