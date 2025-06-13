//
//  VLCOverlayView.m
//
//  Created by Nurettin Akpolat on 13/05/2025.
//

#import "VLCOverlayView.h"

#if TARGET_OS_OSX
#import "VLCOverlayView_Private.h"
#import "VLCChannel.h"
#import "VLCProgram.h"
#import <VLCKit/VLCKit.h>

// Import category headers
#import "VLCOverlayView+Utilities.h"
#import "VLCOverlayView+UI.h"
#import "VLCOverlayView+ChannelManagement.h"
// #import "VLCOverlayView+EPG.h" - REMOVED: Old EPG system eliminated
#import "VLCOverlayView+Favorites.h"
#import "VLCOverlayView+PlayerControls.h"
#import "VLCOverlayView+Theming.h"
#import "VLCOverlayView+Glassmorphism.h"
#import "VLCDataManager.h"


// Implementation of global progress message
NSString *gProgressMessage = nil;
NSLock *gProgressMessageLock = nil;

// Global variable for EPG catchup icon hover tracking
NSInteger hoveredCatchupProgramIndex = -1;

@implementation VLCOverlayView

@synthesize hoveredChannelIndex = _hoveredChannelIndex;

// Data manager property accessor
- (VLCDataManager *)dataManager {
    return _dataManager;
}

// Custom setter for hoveredChannelIndex to prevent changes during EPG preservation
- (void)setHoveredChannelIndex:(NSInteger)newIndex {
    extern BOOL isPersistingHoverState;
    extern NSInteger lastValidHoveredChannelIndex;
    
    //NSLog(@"🔧 SETTER: Attempting to set hover index from %ld to %ld (isPersisting: %@)", 
    //      (long)_hoveredChannelIndex, (long)newIndex, isPersistingHoverState ? @"YES" : @"NO");
    
    // If we're preserving hover state for EPG
    if (isPersistingHoverState) {
        if (newIndex == -1) {
            // IGNORE -1 values during preservation - don't overwrite the stored valid index
            //NSLog(@"BLOCKED: Ignoring -1 during EPG preservation, keeping current value %ld", (long)_hoveredChannelIndex);
            return;
        } else if (lastValidHoveredChannelIndex >= 0 && _hoveredChannelIndex != lastValidHoveredChannelIndex) {
            // Restore the stored valid index if we don't have it yet
            //NSLog(@"RESTORING: Setting hover index to stored valid value %ld", (long)lastValidHoveredChannelIndex);
            _hoveredChannelIndex = lastValidHoveredChannelIndex;
            return;
        }
        // Allow other valid changes during preservation (user hovering over different channels in EPG)
    }
    
    // Allow the change
    _hoveredChannelIndex = newIndex;
    //NSLog(@"🔧 SETTER: Successfully set hover index to %ld", (long)_hoveredChannelIndex);
}

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
        self.hoverColor = [NSColor colorWithCalibratedRed:0.15 green:0.3 blue:0.6 alpha:0.6]; // Darker version of initial selection color
        self.textColor = [NSColor whiteColor];
        self.groupColor = [NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:0.85];
        
        // Initialize UI state - start with menu hidden
        self.isChannelListVisible = NO; // Start hidden
        self.hoveredCategoryIndex = -1;
        self.hoveredGroupIndex = -1;
        self.hoveredChannelIndex = -1;
        self.selectedChannelIndex = -1;
        self.isLoading = NO;
        self.showEpgPanel = NO;
        self.isTextFieldActive = NO;
        trackingArea = nil;
        
        // Initialize text field properties
        self.m3uFieldActive = NO;
        self.epgFieldActive = NO;
        // EPG Time Offset dropdown is now handled by VLCDropdownManager
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
        
        // Initialize EPG catchup icon hover tracking
        hoveredCatchupProgramIndex = -1;
        
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
        
        // Initialize search resources
        self.searchQueue = dispatch_queue_create("com.vlc.search", DISPATCH_QUEUE_SERIAL);
        self.searchResults = [NSMutableArray array];
        self.searchChannelResults = [NSMutableArray array];
        self.searchMovieResults = [NSMutableArray array];
        self.isSearchActive = NO;
        self.searchChannelScrollPosition = 0;
        self.searchMovieScrollPosition = 0;
        
        // Initialize input state
        self.inputUrlString = @"";
        
        // Initialize dropdown manager
        self.dropdownManager = [[VLCDropdownManager alloc] initWithParentView:self];
        
        // Initialize universal data manager
        NSLog(@"🔄 [MAC] Initializing VLCDataManager...");
        // Use VLCDataManager singleton to ensure we use the same instance across the app
        _dataManager = [VLCDataManager sharedManager];
        _dataManager.delegate = self;
        NSLog(@"🔄 [MAC] Using VLCDataManager shared instance");
        
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
        
        // Show menu initially with basic structure (especially Settings for configuration)
        self.isChannelListVisible = YES;
        
        // Initialize EPG time offset dropdown
        [self setupEpgTimeOffsetDropdown];
        
        // Initialize new UI components
        self.m3uTextField = nil; // Will be created when needed
        self.epgLabel = nil; // Will be created when needed
        
        // Initialize theme system
        // TEMPORARILY DISABLED due to infinite recursion
       [self initializeThemeSystem];
        
        // Load view mode preferences (must be after UI initialization)
        if ([self respondsToSelector:@selector(loadViewModePreference)]) {
            [self loadViewModePreference];
        }
        
        // Initialize player controls if available
        if ([self respondsToSelector:@selector(setupPlayerControls)]) {
            //NSLog(@"Setting up player controls during initialization");
            [self setupPlayerControls];
        } else {
            //NSLog(@"Player controls methods not available");
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
        //NSLog(@"Making overlay view first responder for keyboard events");
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
    
    // Invalidate performance optimization timers
    if (movieInfoDebounceTimer) {
        [movieInfoDebounceTimer invalidate];
        movieInfoDebounceTimer = nil;
    }
    
    if (displayUpdateTimer) {
        [displayUpdateTimer invalidate];
        displayUpdateTimer = nil;
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
    
    // Release data manager
    if (_dataManager) {
        _dataManager.delegate = nil;
        [_dataManager release];
        _dataManager = nil;
    }
    
    // Release new UI components
    self.m3uTextField = nil;
    self.epgLabel = nil;
    
    // Release search components
    if (self.searchTimer) {
        [self.searchTimer invalidate];
        self.searchTimer = nil;
    }
    self.searchTextField = nil;
    self.searchResults = nil;
    if (self.searchQueue) {
        dispatch_release(self.searchQueue);
        self.searchQueue = nil;
    }
    
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
            //NSLog(@"ESC key pressed");
            
            // Priority 1: Hide channel list menu if it's visible
            if (self.isChannelListVisible) {
                //NSLog(@"ESC: Hiding channel list menu");
                // Hide all controls before hiding the menu
                [self hideControls];
                self.isChannelListVisible = NO;
                [self setNeedsDisplay:YES];
                return; // Don't pass to super, and don't check player controls yet
            }
            
            // Priority 2: Hide player controls if they're visible (only if menu is already hidden)
            extern BOOL playerControlsVisible;
            if (playerControlsVisible) {
                //NSLog(@"ESC: Hiding player controls");
                [self hidePlayerControls:nil];
                return; // Don't pass to super
            }
            
            //NSLog(@"ESC: Nothing to hide");
        }
    }
    
    // Pass other key events to super
    [super keyDown:event];
}

#pragma mark - Window Notifications

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    //NSLog(@"Entered fullscreen - cursor hiding will be active");
    // Reset mouse movement time when entering fullscreen
    lastMouseMoveTime = [NSDate timeIntervalSinceReferenceDate];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    //NSLog(@"Exited fullscreen - ensuring cursor is visible");
    // Always show cursor when exiting fullscreen
    [self ensureCursorVisible];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    //NSLog(@"Application became active - ensuring cursor is visible");
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
            //NSLog(@"Will draw player controls");
            [self drawPlayerControls:dirtyRect];
        } else if (self.player) {
            //NSLog(@"Player exists but controls not visible");
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
        // Draw background based on glassmorphism setting
        if ([self glassmorphismEnabled]) {
            // Use glassmorphism background for the entire menu with user's blur radius setting
            [self drawGlassmorphismBackground:self.bounds opacity:1.0 blurRadius:[self glassmorphismBlurRadius]];
        } else {
            // Draw theme-aware transparent background when glassmorphism is disabled
            NSColor *backgroundColorWithTransparency;
            switch (self.currentTheme) {
                case VLC_THEME_DARK:
                    backgroundColorWithTransparency = [NSColor colorWithRed:0.15 green:0.15 blue:0.15 alpha:self.themeAlpha];
                    break;
                case VLC_THEME_DARKER:
                    backgroundColorWithTransparency = [NSColor colorWithRed:0.05 green:0.05 blue:0.05 alpha:self.themeAlpha];
                    break;
                case VLC_THEME_BLUE:
                    backgroundColorWithTransparency = [NSColor colorWithRed:0.0 green:0.15 blue:0.20 alpha:self.themeAlpha];
                    break;
                case VLC_THEME_GREEN:
                    backgroundColorWithTransparency = [NSColor colorWithRed:0.0 green:0.2 blue:0.1 alpha:self.themeAlpha];
                    break;
                case VLC_THEME_PURPLE:
                    backgroundColorWithTransparency = [NSColor colorWithRed:0.15 green:0.1 blue:0.2 alpha:self.themeAlpha];
                    break;
                case VLC_THEME_CUSTOM:
                    backgroundColorWithTransparency = [NSColor colorWithRed:self.customThemeRed green:self.customThemeGreen blue:self.customThemeBlue alpha:self.themeAlpha];
                    break;
                default:
                    backgroundColorWithTransparency = [NSColor colorWithRed:0.1 green:0.12 blue:0.16 alpha:self.themeAlpha];
                    break;
            }
            
            [backgroundColorWithTransparency set];
            NSRectFill(self.bounds);
        }
        
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
    
    // Reset scroll positions when changing categories to prevent carryover
    extern CGFloat channelScrollPosition;
    extern CGFloat groupScrollPosition; 
    extern CGFloat categoryScrollPosition;
    
    NSLog(@"🔄 CATEGORY CHANGE: Resetting scroll positions - old channelScrollPosition was %.1f", channelScrollPosition);
    channelScrollPosition = 0;
    groupScrollPosition = 0;
    categoryScrollPosition = 0;
    self.searchChannelScrollPosition = 0;
    self.searchMovieScrollPosition = 0;
    self.epgScrollPosition = 0;
    self.movieInfoScrollPosition = 0;
    
    self.selectedCategoryIndex = categoryIndex;
    self.selectedGroupIndex = -1;
    self.selectedChannelIndex = -1;
    
    // Initialize category-specific view modes
    [self initializeCategoryViewModes];
    
    // Update UI components visibility based on new category
    [self updateUIComponentsVisibility];
    
    [self updateViewBasedOnSelection];
}

#pragma mark - Category-Specific View Modes

- (void)initializeCategoryViewModes {
    if (!categoryViewModes) {
        categoryViewModes = [[NSMutableDictionary alloc] init];
        
        // Only set default view modes when first creating the dictionary
        // TV: List view
        [categoryViewModes setObject:@{@"grid": @NO, @"stacked": @NO} forKey:@(CATEGORY_TV)];
        // Movies: Stacked view  
        [categoryViewModes setObject:@{@"grid": @NO, @"stacked": @YES} forKey:@(CATEGORY_MOVIES)];
        // Series: List view
        [categoryViewModes setObject:@{@"grid": @NO, @"stacked": @NO} forKey:@(CATEGORY_SERIES)];
        // Favorites: List view
        [categoryViewModes setObject:@{@"grid": @NO, @"stacked": @NO} forKey:@(CATEGORY_FAVORITES)];
        // Search: List view
        [categoryViewModes setObject:@{@"grid": @NO, @"stacked": @NO} forKey:@(CATEGORY_SEARCH)];
        // Settings: List view
        [categoryViewModes setObject:@{@"grid": @NO, @"stacked": @NO} forKey:@(CATEGORY_SETTINGS)];
    }
}

- (BOOL)isGridViewActiveForCategory:(NSInteger)categoryIndex {
    [self initializeCategoryViewModes];
    
    NSDictionary *viewMode = [categoryViewModes objectForKey:@(categoryIndex)];
    if (viewMode) {
        BOOL result = [[viewMode objectForKey:@"grid"] boolValue];
        //NSLog(@"🔍 isGridViewActiveForCategory:%ld = %@ (grid=%@, stacked=%@)", 
        //      (long)categoryIndex, result ? @"YES" : @"NO", 
        //      [viewMode objectForKey:@"grid"], [viewMode objectForKey:@"stacked"]);
        return result;
    }
    //NSLog(@"🔍 isGridViewActiveForCategory:%ld = NO (no viewMode found)", (long)categoryIndex);
    return NO; // Default to list view
}

- (void)setGridViewActive:(BOOL)active forCategory:(NSInteger)categoryIndex {
    NSLog(@"🔧 setGridViewActive:%@ forCategory:%ld CALLED", active ? @"YES" : @"NO", (long)categoryIndex);
    
    [self initializeCategoryViewModes];
    
    // Get current view mode settings for this category
    NSMutableDictionary *viewMode = [[categoryViewModes objectForKey:@(categoryIndex)] mutableCopy];
    if (!viewMode) {
        viewMode = [NSMutableDictionary dictionaryWithDictionary:@{@"grid": @NO, @"stacked": @NO}];
        NSLog(@"🔧 Created new viewMode dictionary for category %ld", (long)categoryIndex);
    }
    
    NSLog(@"🔧 BEFORE: grid=%@, stacked=%@", [viewMode objectForKey:@"grid"], [viewMode objectForKey:@"stacked"]);
    
    // Update grid view setting
    [viewMode setObject:@(active) forKey:@"grid"];
    
    // If enabling grid view, disable stacked view
    if (active) {
        [viewMode setObject:@NO forKey:@"stacked"];
    }
    
    NSLog(@"🔧 AFTER: grid=%@, stacked=%@", [viewMode objectForKey:@"grid"], [viewMode objectForKey:@"stacked"]);
    
    // Save back to dictionary
    [categoryViewModes setObject:viewMode forKey:@(categoryIndex)];
    [viewMode release];
    
    NSLog(@"🔧 SAVED to categoryViewModes for category %ld", (long)categoryIndex);
}

- (BOOL)isStackedViewActiveForCategory:(NSInteger)categoryIndex {
    [self initializeCategoryViewModes];
    
    // Special handling for FAVORITES: use stacked view if the current group contains movie channels
    if (categoryIndex == CATEGORY_FAVORITES) {
        BOOL favoritesHasMovieChannels = [self currentGroupContainsMovieChannels];
        if (favoritesHasMovieChannels) {
            // Return stacked view active for favorites containing movie channels
            return YES;
        }
        // Otherwise fall through to normal view mode check
    }
    
    NSDictionary *viewMode = [categoryViewModes objectForKey:@(categoryIndex)];
    if (viewMode) {
        return [[viewMode objectForKey:@"stacked"] boolValue];
    }
    return NO; // Default to list view
}

- (void)setStackedViewActive:(BOOL)active forCategory:(NSInteger)categoryIndex {
    NSLog(@"🔧 setStackedViewActive:%@ forCategory:%ld CALLED", active ? @"YES" : @"NO", (long)categoryIndex);
    
    [self initializeCategoryViewModes];
    
    // Get current view mode settings for this category
    NSMutableDictionary *viewMode = [[categoryViewModes objectForKey:@(categoryIndex)] mutableCopy];
    if (!viewMode) {
        viewMode = [NSMutableDictionary dictionaryWithDictionary:@{@"grid": @NO, @"stacked": @NO}];
        NSLog(@"🔧 Created new viewMode dictionary for category %ld", (long)categoryIndex);
    }
    
    NSLog(@"🔧 BEFORE: grid=%@, stacked=%@", [viewMode objectForKey:@"grid"], [viewMode objectForKey:@"stacked"]);
    
    // Update stacked view setting
    [viewMode setObject:@(active) forKey:@"stacked"];
    
    // If enabling stacked view, disable grid view
    if (active) {
        [viewMode setObject:@NO forKey:@"grid"];
    }
    
    NSLog(@"🔧 AFTER: grid=%@, stacked=%@", [viewMode objectForKey:@"grid"], [viewMode objectForKey:@"stacked"]);
    
    // Save back to dictionary
    [categoryViewModes setObject:viewMode forKey:@(categoryIndex)];
    [viewMode release];
    
    NSLog(@"🔧 SAVED to categoryViewModes for category %ld", (long)categoryIndex);
}

#pragma mark - VLCDataManagerDelegate

- (void)dataManagerDidStartLoading:(NSString *)operation {
    NSLog(@"🔄 [MAC] VLCDataManager started loading: %@", operation);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = YES;
        
        if ([operation containsString:@"Channels"]) {
            [self setLoadingStatusText:@"Loading channels..."];
        } else if ([operation containsString:@"EPG"]) {
            self.isLoadingEpg = YES;  // CRITICAL: Set EPG loading flag
            [self setLoadingStatusText:@"Loading EPG data..."];
            [self setEpgLoadingStatusText:@"Loading EPG data..."];
        }
        
        [self setNeedsDisplay:YES];
    });
}

- (void)dataManagerDidUpdateProgress:(float)progress operation:(NSString *)operation {
    NSLog(@"📊 [DELEGATE] Progress update: %.1f%% for operation: %@", progress * 100, operation);
    
    // Only update for actual downloads, not cache operations
    if ([operation containsString:@"Downloading"] || [operation containsString:@"Processing"] || [operation containsString:@"Parsing"]) {
        NSString *formattedProgress = [self formatProgressTextMac:operation forProgress:progress];
        NSLog(@"🎨 [PROGRESS-FORMAT] Input: '%@' -> Output: '%@'", operation, formattedProgress);
        
        [self setLoadingStatusText:formattedProgress];
        self.loadingProgress = progress;
        
        // EPG-specific progress updates
        if ([operation containsString:@"EPG"]) {
            [self setEpgLoadingStatusText:formattedProgress];
            self.epgLoadingProgress = progress;
            NSLog(@"📱 [EPG-PROGRESS] Set EPG text to: '%@', progress: %.2f", formattedProgress, progress);
        }
        
        [self setNeedsDisplay:YES];
    } else {
        NSLog(@"⚠️ [PROGRESS-SKIP] Skipping progress update for operation: '%@'", operation);
    }
}

- (NSString *)formatProgressTextMac:(NSString *)operation forProgress:(float)progress {
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
                return [NSString stringWithFormat:@"Downloading %.1fMB (%.0f%%)", downloadedMB, progress * 100];
            } else {
                return [NSString stringWithFormat:@"Downloading %.1fMB of %.1fMB (%.0f%%)", downloadedMB, totalMB, progress * 100];
            }
        } else if ([operation containsString:@"MB"]) {
            // Fallback for other MB formats - extract any number before MB
            NSRegularExpression *simpleRegex = [NSRegularExpression regularExpressionWithPattern:@"(-?\\d+\\.?\\d*)\\s*MB" options:0 error:nil];
            NSTextCheckingResult *simpleMatch = [simpleRegex firstMatchInString:operation options:0 range:NSMakeRange(0, operation.length)];
            if (simpleMatch) {
                NSString *downloaded = [operation substringWithRange:[simpleMatch rangeAtIndex:1]];
                return [NSString stringWithFormat:@"Downloading %.1fMB (%.0f%%)", downloaded.floatValue, progress * 100];
            }
            return [NSString stringWithFormat:@"Downloading... (%.0f%%)", progress * 100];
        }
        return [NSString stringWithFormat:@"Downloading (%.0f%%)", progress * 100];
    }
    
    // Extract processing progress (item counts)
    if ([operation containsString:@"Processing"]) {
        // Look for patterns like "Processing channel 1234 of 44357"
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*of\\s*(\\d+)" options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:operation options:0 range:NSMakeRange(0, operation.length)];
        
        if (match) {
            NSString *current = [operation substringWithRange:[match rangeAtIndex:1]];
            NSString *total = [operation substringWithRange:[match rangeAtIndex:2]];
            return [NSString stringWithFormat:@"Processing (%@ of %@) - %.0f%%", current, total, progress * 100];
        }
        return [NSString stringWithFormat:@"Processing (%.0f%%)", progress * 100];
    }
    
    // Extract parsing progress (item counts)
    if ([operation containsString:@"Parsing"]) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*of\\s*(\\d+)" options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:operation options:0 range:NSMakeRange(0, operation.length)];
        
        if (match) {
            NSString *current = [operation substringWithRange:[match rangeAtIndex:1]];
            NSString *total = [operation substringWithRange:[match rangeAtIndex:2]];
            return [NSString stringWithFormat:@"Parsing (%@ of %@) - %.0f%%", current, total, progress * 100];
        }
        return [NSString stringWithFormat:@"Parsing (%.0f%%)", progress * 100];
    }
    
    // Default fallback with percentage
    return [NSString stringWithFormat:@"%@ (%.0f%%)", operation, progress * 100];
}

- (void)dataManagerDidFinishLoading:(NSString *)operation success:(BOOL)success {
    NSLog(@"✅ [MAC] VLCDataManager finished loading: %@ (success: %@)", operation, success ? @"YES" : @"NO");
    NSLog(@"🔍 [MAC] Current state before completion: isLoading=%@ isLoadingEpg=%@ loadingProgress=%.2f epgProgress=%.2f", 
          self.isLoading ? @"YES" : @"NO", 
          self.isLoadingEpg ? @"YES" : @"NO", 
          self.loadingProgress, 
          self.epgLoadingProgress);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Copy iOS approach: Simple completion handling
        if ([operation containsString:@"Channels"] || [operation containsString:@"M3U"]) {
            // Reset channel loading progress
            self.loadingProgress = 0.0;
                    if (success) {
            [self setLoadingStatusText:@"✅ Channels loaded successfully"];
            // Update startup progress to 50% when channels are loaded
            if (self.isStartupInProgress) {
                [self updateStartupProgress:0.50 step:@"Channels Loaded" details:@"Channel list loaded successfully"];
            }
        } else {
            [self setLoadingStatusText:@"❌ Error loading channels"];
            if (self.isStartupInProgress) {
                [self updateStartupProgress:0.50 step:@"Channel Error" details:@"Failed to load channels"];
            }
        }
            NSLog(@"📊 [MAC] Reset channel progress after completion");
        } else if ([operation containsString:@"EPG"]) {
            // Reset EPG loading progress
            self.isLoadingEpg = NO;
            self.epgLoadingProgress = 0.0;
            if (success) {
                [self setEpgLoadingStatusText:@"✅ EPG loaded successfully"];
                // Update startup progress to 90% when EPG is loaded
                if (self.isStartupInProgress) {
                    [self updateStartupProgress:0.90 step:@"EPG Loaded" details:@"Program guide loaded successfully"];
                }
            } else {
                [self setEpgLoadingStatusText:@"❌ Error loading EPG"];
                if (self.isStartupInProgress) {
                    [self updateStartupProgress:0.90 step:@"EPG Error" details:@"Failed to load program guide"];
                }
            }
            NSLog(@"📊 [MAC] Reset EPG progress after completion");
        }
        
        // CRITICAL FIX: Set isLoading to NO when operations complete
        // Simple check: if no operations are active, hide progress window
        BOOL anyOperationsActive = (self.isLoadingEpg || self.loadingProgress > 0.0);
        NSLog(@"🔍 [MAC] After completion: isLoadingEpg=%@ loadingProgress=%.2f anyOperationsActive=%@", 
              self.isLoadingEpg ? @"YES" : @"NO", 
              self.loadingProgress, 
              anyOperationsActive ? @"YES" : @"NO");
        
        if (!anyOperationsActive) {
            NSLog(@"🎯 [MAC] No operations active - hiding progress window");
            self.isLoading = NO;  // CRITICAL: This was missing!
            
            // Complete startup progress
            if (self.isStartupInProgress) {
                [self updateStartupProgress:1.0 step:@"Complete" details:@"BasicIPTV ready to use"];
                
                // Hide startup progress window after showing completion
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self hideStartupProgressWindow];
                });
            }
            
            // Hide progress window after brief delay
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSLog(@"🚪 [MAC] Delayed hide progress window triggered");
                [self hideProgressWindowMac];
            });
        } else {
            NSLog(@"📊 [MAC] Operations still active - keeping progress window visible");
        }
        
        [self setNeedsDisplay:YES];
    });
}

- (void)hideProgressWindowMac {
    NSLog(@"🚪 [MAC] Hiding progress window and resetting all indicators");
    
    // Clear loading state
    self.isLoading = NO;
    self.isLoadingEpg = NO;
    
    // Reset progress indicators
    self.loadingProgress = 0.0;
    self.epgLoadingProgress = 0.0;
    
    // Clear status text
    [self setLoadingStatusText:@""];
    [self setEpgLoadingStatusText:@""];
    
    [self setNeedsDisplay:YES];
}

- (void)epgMatchingProgress:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSNumber *processed = userInfo[@"processed"];
    NSNumber *total = userInfo[@"total"];
    NSNumber *matched = userInfo[@"matched"];
    
    NSLog(@"📅 [MAC-UI] EPG matching progress: %@/%@ channels (%@ matched)", processed, total, matched);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Progressive UI update - refresh display as EPG data becomes available
        [self setNeedsDisplay:YES];
    });
}

- (void)epgMatchingCompleted:(NSNotification *)notification {
    NSLog(@"📅 [MAC-UI] EPG matching completed notification received - refreshing UI");
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // CRITICAL FIX: Update favorites with EPG data when matching completes
        [self updateFavoritesWithEPGData];
        
        // Force refresh of the channel list to show updated EPG data
        [self setNeedsDisplay:YES];
        
        // Also trigger channel selection update to refresh program guide
        if (self.selectedChannelIndex >= 0 && self.selectedChannelIndex < self.channels.count) {
            // This will trigger program guide refresh with the newly matched EPG data
            [self refreshCurrentEPGInfo];
        }
        
        NSLog(@"📅 [MAC-UI] UI refresh completed after EPG matching (including favorites)");
    });
}

- (void)dataManagerDidUpdateChannels:(NSArray<VLCChannel *> *)channels {
    NSLog(@"📺 [MAC] VLCDataManager updated channels: %lu channels", (unsigned long)channels.count);
    
    // CRITICAL: Update channels and basic UI immediately for responsiveness
    self.channels = [NSMutableArray arrayWithArray:channels];
    
    // RACE CONDITION PROTECTION: Ensure background processing has completed
    if (self.dataManager.groups.count == 0 && channels.count > 0) {
        NSLog(@"⚠️ [MAC] Background processing not complete yet - deferring data sync...");
        
        // Retry after a short delay to allow background processing to complete
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"🔄 [MAC] Retrying data sync after delay...");
            [self syncDataFromManager:channels];
        });
        return;
    }
    
    // Proceed with immediate sync if data is ready
    [self syncDataFromManager:channels];
}

- (void)syncDataFromManager:(NSArray<VLCChannel *> *)channels {
    // CRITICAL FIX: Preserve favorites BEFORE replacing data structures
    NSMutableArray *savedFavoritesGroups = nil;
    NSMutableDictionary *savedFavoritesChannels = [NSMutableDictionary dictionary];
    
    // Save current favorites before they get wiped out
    if (self.groupsByCategory && [self.groupsByCategory isKindOfClass:[NSDictionary class]]) {
        id favoritesGroups = [self.groupsByCategory objectForKey:@"FAVORITES"];
        if (favoritesGroups && [favoritesGroups isKindOfClass:[NSArray class]]) {
            savedFavoritesGroups = [favoritesGroups mutableCopy];
            
            // Also preserve the actual favorite channels
            for (NSString *favoritesGroup in savedFavoritesGroups) {
                NSArray *groupChannels = [self.channelsByGroup objectForKey:favoritesGroup];
                if (groupChannels) {
                    [savedFavoritesChannels setObject:groupChannels forKey:favoritesGroup];
                }
            }
            
            //NSLog(@"💾 [FAVORITES] Preserved %lu favorites groups with channels before data sync", 
            //      (unsigned long)savedFavoritesGroups.count);
        }
    }
    
    // Data processing happens asynchronously in VLCDataManager
    // Now sync ALL data structures from DataManager (should be ready after background processing)
    self.groups = [NSMutableArray arrayWithArray:self.dataManager.groups];
    self.channelsByGroup = [NSMutableDictionary dictionaryWithDictionary:self.dataManager.channelsByGroup];
    self.groupsByCategory = [NSMutableDictionary dictionaryWithDictionary:self.dataManager.groupsByCategory];
    self.categories = self.dataManager.categories;
    
    // CRITICAL FIX: Restore favorites IMMEDIATELY after data sync
    if (savedFavoritesGroups && savedFavoritesGroups.count > 0) {
        [self.groupsByCategory setObject:savedFavoritesGroups forKey:@"FAVORITES"];
        
        // Restore favorites groups to main groups list
        for (NSString *favoritesGroup in savedFavoritesGroups) {
            if (![self.groups containsObject:favoritesGroup]) {
                [self.groups addObject:favoritesGroup];
            }
            
            // Restore favorites channels
            NSArray *groupChannels = [savedFavoritesChannels objectForKey:favoritesGroup];
            if (groupChannels) {
                [self.channelsByGroup setObject:groupChannels forKey:favoritesGroup];
            }
        }
        
        //NSLog(@"✅ [FAVORITES] Restored %lu favorites groups immediately after data sync", 
        //      (unsigned long)savedFavoritesGroups.count);
    }
    
    //NSLog(@"🔗 [MAC] Data sync: DataManager has %lu groups, %lu channelsByGroup, %lu groupsByCategory", 
    //      (unsigned long)self.dataManager.groups.count,
    //      (unsigned long)self.dataManager.channelsByGroup.count, 
    //      (unsigned long)self.dataManager.groupsByCategory.count);
    
    //NSLog(@"🔗 [MAC] Local sync: OverlayView now has %lu groups, %lu channelsByGroup, %lu groupsByCategory", 
    //      (unsigned long)self.groups.count,
    //      (unsigned long)self.channelsByGroup.count, 
    //      (unsigned long)self.groupsByCategory.count);
    
    // DIAGNOSTIC: Check if data is actually ready
    if (channels.count > 0 && self.groups.count == 0) {
        //NSLog(@"🚨 [MAC] CRITICAL: Have %lu channels but 0 groups - background processing may not be complete", 
        //      (unsigned long)channels.count);
        //NSLog(@"🚨 [MAC] DataManager internal state: groups=%lu channelsByGroup=%lu", 
        //      (unsigned long)self.dataManager.groups.count, (unsigned long)self.dataManager.channelsByGroup.count);
    }
    
    // Show channels immediately
    if (channels.count > 0) {
        self.isChannelListVisible = YES;
        
        // Set basic selection if not set - DEFAULT TO FAVORITES
        if (self.selectedCategoryIndex < 0 && self.categories.count > 0) {
            self.selectedCategoryIndex = CATEGORY_FAVORITES;
        }
        if (self.selectedGroupIndex < 0 && self.groups.count > 0) {
            self.selectedGroupIndex = 0;
        }
        
        [self prepareSimpleChannelLists];
    }
    
    [self setLoadingStatusText:@"Channels loaded successfully"];
    [self setNeedsDisplay:YES];
    
    NSLog(@"🎯 [MAC] IMMEDIATE: Channels displayed - %lu channels, %lu groups", 
          (unsigned long)channels.count, (unsigned long)self.groups.count);
    
    // IMMEDIATE: Restore Settings categories (favorites already restored above)
    [self ensureSettingsGroups];
    
    // DEFERRED: EPG URL handling in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // EPG URL handling for universal sequence
            if (channels.count > 0) {
                if (!self.epgUrl || [self.epgUrl length] == 0) {
                    NSString *m3uUrl = self.m3uFilePath;
                    if (m3uUrl && [m3uUrl length] > 0) {
                        NSString *generatedEpgUrl = [self generateEpgUrlFromM3uUrl:m3uUrl];
                        if (generatedEpgUrl && [generatedEpgUrl length] > 0) {
                            self.epgUrl = generatedEpgUrl;
                            [self saveSettingsState];
                            NSLog(@"📅 Auto-generated EPG URL: %@", self.epgUrl);
                            // Update data manager with new EPG URL
                            self.dataManager.epgURL = self.epgUrl;
                        }
                    }
                } else if (self.epgUrl && [self.epgUrl length] > 0) {
                    // Update data manager with EPG URL (it will handle the sequential loading)
                    self.dataManager.epgURL = self.epgUrl;
                    NSLog(@"📅 [UNIVERSAL] EPG URL set in DataManager - sequential loading will handle EPG");
                }
            }
            
            NSLog(@"🎯 [MAC] DEFERRED: EPG URL configuration completed");
            [self setNeedsDisplay:YES];
        });
    });
}

- (void)dataManagerDidUpdateEPG:(NSDictionary *)epgData {
    NSLog(@"📅 [MAC] VLCDataManager updated EPG: %lu programs", (unsigned long)epgData.count);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update EPG from universal manager - VLCEPGManager already processed it
        self.epgData = [NSMutableDictionary dictionaryWithDictionary:epgData];
        
        // CRITICAL: Mark EPG as loaded so channel list shows current programs
        self.isEpgLoaded = YES;
        
        // Set EPG time offset from the data manager
        self.epgTimeOffsetHours = self.dataManager.epgTimeOffsetHours;
        
        [self setEpgLoadingStatusText:@"EPG loaded successfully"];
        
        NSLog(@"🎯 [MAC] Updated EPG from VLCDataManager: %lu channels, EPG loaded flag set to YES", (unsigned long)[self.epgData count]);
        
        // CRITICAL FIX: Update favorites with EPG data
        [self updateFavoritesWithEPGData];
        
        [self setNeedsDisplay:YES];
    });
}

- (void)dataManagerDidDetectTimeshift:(NSInteger)timeshiftChannelCount {
    NSLog(@"⏱ [MAC] VLCDataManager detected timeshift: %ld channels", (long)timeshiftChannelCount);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update UI to show timeshift indicators
        [self setNeedsDisplay:YES];
    });
}

- (void)dataManagerDidEncounterError:(NSError *)error operation:(NSString *)operation {
    NSLog(@"❌ [MAC] VLCDataManager error in %@: %@", operation, error.localizedDescription);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isLoading = NO;
        
        if ([operation containsString:@"Channels"]) {
            [self setLoadingStatusText:[NSString stringWithFormat:@"Error loading channels: %@", error.localizedDescription]];
        } else if ([operation containsString:@"EPG"]) {
            [self setEpgLoadingStatusText:[NSString stringWithFormat:@"Error loading EPG: %@", error.localizedDescription]];
        }
        
        [self setNeedsDisplay:YES];
    });
}

#pragma mark - Startup Progress System Implementation (macOS)

- (void)showStartupProgressWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_startupProgressWindow) {
            self.isStartupInProgress = YES;
            
            // Create startup progress window
            CGFloat screenWidth = self.bounds.size.width;
            CGFloat screenHeight = self.bounds.size.height;
            CGFloat windowWidth = MIN(400.0, screenWidth * 0.8);
            CGFloat windowHeight = MIN(200.0, screenHeight * 0.4);
            
            CGRect windowFrame = CGRectMake(
                (screenWidth - windowWidth) / 2.0,
                (screenHeight - windowHeight) / 2.0,
                windowWidth,
                windowHeight
            );
            
            _startupProgressWindow = [[NSView alloc] initWithFrame:windowFrame];
            
            // Background
            _startupProgressWindow.wantsLayer = YES;
            _startupProgressWindow.layer.backgroundColor = [NSColor colorWithWhite:0.1 alpha:0.95].CGColor;
            _startupProgressWindow.layer.cornerRadius = 12.0;
            _startupProgressWindow.layer.borderWidth = 1.0;
            _startupProgressWindow.layer.borderColor = [NSColor colorWithWhite:0.3 alpha:0.8].CGColor;
            
            // Shadow
            _startupProgressWindow.shadow = [[NSShadow alloc] init];
            _startupProgressWindow.shadow.shadowOffset = NSMakeSize(0, -5);
            _startupProgressWindow.shadow.shadowBlurRadius = 10.0;
            _startupProgressWindow.shadow.shadowColor = [NSColor colorWithWhite:0.0 alpha:0.5];
            
            // Title label
            _startupProgressTitle = [[NSTextField alloc] initWithFrame:CGRectMake(20, windowHeight - 50, windowWidth - 40, 30)];
            _startupProgressTitle.stringValue = @"🚀 Loading BasicIPTV";
            _startupProgressTitle.textColor = [NSColor whiteColor];
            _startupProgressTitle.font = [NSFont boldSystemFontOfSize:18];
            _startupProgressTitle.alignment = NSTextAlignmentCenter;
            _startupProgressTitle.editable = NO;
            _startupProgressTitle.selectable = NO;
            _startupProgressTitle.drawsBackground = NO;
            _startupProgressTitle.bordered = NO;
            [_startupProgressWindow addSubview:_startupProgressTitle];
            
            // Current step label
            _startupProgressStep = [[NSTextField alloc] initWithFrame:CGRectMake(20, windowHeight - 80, windowWidth - 40, 25)];
            _startupProgressStep.stringValue = @"Initializing...";
            _startupProgressStep.textColor = [NSColor colorWithWhite:0.9 alpha:1.0];
            _startupProgressStep.font = [NSFont systemFontOfSize:16];
            _startupProgressStep.alignment = NSTextAlignmentCenter;
            _startupProgressStep.editable = NO;
            _startupProgressStep.selectable = NO;
            _startupProgressStep.drawsBackground = NO;
            _startupProgressStep.bordered = NO;
            [_startupProgressWindow addSubview:_startupProgressStep];
            
            // Progress bar
            _startupProgressBar = [[NSProgressIndicator alloc] initWithFrame:CGRectMake(40, windowHeight - 110, windowWidth - 80, 8)];
            _startupProgressBar.style = NSProgressIndicatorStyleBar;
            _startupProgressBar.indeterminate = NO;
            _startupProgressBar.minValue = 0.0;
            _startupProgressBar.maxValue = 100.0;
            _startupProgressBar.doubleValue = 0.0;
            [_startupProgressWindow addSubview:_startupProgressBar];
            
            // Percentage label
            _startupProgressPercent = [[NSTextField alloc] initWithFrame:CGRectMake(20, windowHeight - 135, windowWidth - 40, 20)];
            _startupProgressPercent.stringValue = @"0%";
            _startupProgressPercent.textColor = [NSColor colorWithWhite:0.8 alpha:1.0];
            _startupProgressPercent.font = [NSFont systemFontOfSize:14];
            _startupProgressPercent.alignment = NSTextAlignmentCenter;
            _startupProgressPercent.editable = NO;
            _startupProgressPercent.selectable = NO;
            _startupProgressPercent.drawsBackground = NO;
            _startupProgressPercent.bordered = NO;
            [_startupProgressWindow addSubview:_startupProgressPercent];
            
            // Details label
            _startupProgressDetails = [[NSTextField alloc] initWithFrame:CGRectMake(20, windowHeight - 170, windowWidth - 40, 40)];
            _startupProgressDetails.stringValue = @"Starting up...";
            _startupProgressDetails.textColor = [NSColor colorWithWhite:0.7 alpha:1.0];
            _startupProgressDetails.font = [NSFont systemFontOfSize:12];
            _startupProgressDetails.alignment = NSTextAlignmentCenter;
            _startupProgressDetails.editable = NO;
            _startupProgressDetails.selectable = NO;
            _startupProgressDetails.drawsBackground = NO;
            _startupProgressDetails.bordered = NO;
            [_startupProgressWindow addSubview:_startupProgressDetails];
            
            [self addSubview:_startupProgressWindow];
            
            NSLog(@"🚀 [STARTUP] Created macOS progress window: %.0fx%.0f", windowWidth, windowHeight);
        }
        
        _startupProgressWindow.hidden = NO;
        [self setNeedsDisplay:YES];
    });
}

- (void)hideStartupProgressWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_startupProgressWindow) {
            self.isStartupInProgress = NO;
            _startupProgressWindow.hidden = YES;
            
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
                
                NSLog(@"🚀 [STARTUP] macOS progress window cleaned up");
                [self setNeedsDisplay:YES];
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
            _startupProgressBar.doubleValue = progress * 100;
            _startupProgressStep.stringValue = step;
            _startupProgressDetails.stringValue = details;
            _startupProgressPercent.stringValue = [NSString stringWithFormat:@"%.0f%%", progress * 100];
            
            NSLog(@"🚀 [STARTUP] %.0f%% - %@ - %@", progress * 100, step, details);
            [self setNeedsDisplay:YES];
        }
    });
}

- (void)setStartupPhase:(NSString *)phase {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_startupProgressWindow && !_startupProgressWindow.hidden) {
            _startupProgressTitle.stringValue = [NSString stringWithFormat:@"🚀 %@", phase];
            NSLog(@"🚀 [STARTUP] Phase: %@", phase);
            [self setNeedsDisplay:YES];
        }
    });
}

@end

#endif // TARGET_OS_OSX
