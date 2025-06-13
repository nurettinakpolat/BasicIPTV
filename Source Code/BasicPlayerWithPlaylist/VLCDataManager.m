//
//  VLCDataManager.m
//  BasicPlayerWithPlaylist
//
//  Universal Data Manager - Platform Independent
//  Central coordinator for all data operations across macOS, iOS, and tvOS
//

#import "VLCDataManager.h"
#import "VLCChannelManager.h"
#import "VLCEPGManager.h" 
#import "VLCTimeshiftManager.h"
#import "VLCCacheManager.h"
#import "VLCChannel.h"
#import "VLCProgram.h"

@interface VLCDataManager () <NSObject>

// Sub-managers (lazy loaded for memory efficiency)
@property (nonatomic, strong) VLCChannelManager *channelManager;
@property (nonatomic, strong) VLCEPGManager *epgManager;
@property (nonatomic, strong) VLCTimeshiftManager *timeshiftManager;
@property (nonatomic, strong) VLCCacheManager *cacheManager;

// Internal data state
@property (nonatomic, strong) NSArray<VLCChannel *> *internalChannels;
@property (nonatomic, strong) NSArray<NSString *> *internalGroups;
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<VLCChannel *> *> *internalChannelsByGroup;
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<NSString *> *> *internalGroupsByCategory;
@property (nonatomic, strong) NSArray<NSString *> *internalCategories;
@property (nonatomic, strong) NSDictionary *internalEpgData;

// Loading states
@property (nonatomic, assign) BOOL internalIsLoadingChannels;
@property (nonatomic, assign) BOOL internalIsLoadingEPG;
@property (nonatomic, assign) BOOL internalIsEPGLoaded;
@property (nonatomic, assign) float internalChannelLoadingProgress;
@property (nonatomic, assign) float internalEpgLoadingProgress;

// Current operations (for cancellation)
@property (nonatomic, strong) NSOperation *currentChannelOperation;
@property (nonatomic, strong) NSOperation *currentEPGOperation;

@end

@implementation VLCDataManager

#pragma mark - Singleton

+ (instancetype)sharedManager {
    static VLCDataManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[VLCDataManager alloc] init];
    });
    return sharedInstance;
}

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupDefaultConfiguration];
        [self initializeDataStructures];
    }
    return self;
}

- (void)setupDefaultConfiguration {
    self.epgTimeOffsetHours = 0.0;
    self.internalIsLoadingChannels = NO;
    self.internalIsLoadingEPG = NO;
    self.internalIsEPGLoaded = NO;
    self.internalChannelLoadingProgress = 0.0;
    self.internalEpgLoadingProgress = 0.0;
}

- (void)initializeDataStructures {
    self.internalChannels = @[];
    self.internalGroups = @[];
    self.internalChannelsByGroup = @{};
    self.internalGroupsByCategory = @{};
    self.internalCategories = @[@"SEARCH", @"FAVORITES", @"TV", @"MOVIES", @"SERIES", @"SETTINGS"];
    self.internalEpgData = @{};
}

#pragma mark - Lazy Loading Sub-managers

- (VLCChannelManager *)channelManager {
    if (!_channelManager) {
        _channelManager = [[VLCChannelManager alloc] init];
        _channelManager.cacheManager = self.cacheManager;
        
        // DEBUGGING: Log stack trace to see what's causing reinitialization
        NSArray *callStack = [NSThread callStackSymbols];
        NSString *caller = (callStack.count > 1) ? callStack[1] : @"Unknown";
        NSLog(@"📊 [DATA] Created VLCChannelManager (Caller: %@)", caller);
        
        if (callStack.count > 2) {
            NSLog(@"📊 [DATA] Call Stack: %@", callStack[2]);
        }
    }
    return _channelManager;
}

- (VLCEPGManager *)epgManager {
    if (!_epgManager) {
        _epgManager = [[VLCEPGManager alloc] init];
        _epgManager.cacheManager = self.cacheManager;
        _epgManager.timeOffsetHours = self.epgTimeOffsetHours;
        NSLog(@"📊 [DATA] Created VLCEPGManager");
    }
    return _epgManager;
}

- (VLCTimeshiftManager *)timeshiftManager {
    if (!_timeshiftManager) {
        _timeshiftManager = [[VLCTimeshiftManager alloc] init];
        NSLog(@"📊 [DATA] Created VLCTimeshiftManager");
    }
    return _timeshiftManager;
}

- (VLCCacheManager *)cacheManager {
    if (!_cacheManager) {
        _cacheManager = [[VLCCacheManager alloc] init];
        NSLog(@"📊 [DATA] Created VLCCacheManager");
    }
    return _cacheManager;
}

#pragma mark - Public Property Accessors

- (NSArray<VLCChannel *> *)channels { return self.internalChannels ?: @[]; }
- (NSArray<NSString *> *)groups { return self.internalGroups ?: @[]; }
- (NSDictionary<NSString *, NSArray<VLCChannel *> *> *)channelsByGroup { return self.internalChannelsByGroup ?: @{}; }
- (NSDictionary<NSString *, NSArray<NSString *> *> *)groupsByCategory { return self.internalGroupsByCategory ?: @{}; }
- (NSArray<NSString *> *)categories { return self.internalCategories ?: @[]; }
- (NSDictionary *)epgData { return self.internalEpgData ?: @{}; }

- (BOOL)isLoadingChannels { return self.internalIsLoadingChannels; }
- (BOOL)isLoadingEPG { return self.internalIsLoadingEPG; }
- (BOOL)isEPGLoaded { return self.internalIsEPGLoaded; }
- (float)channelLoadingProgress { return self.internalChannelLoadingProgress; }
- (float)epgLoadingProgress { return self.internalEpgLoadingProgress; }

#pragma mark - High-level Operations

- (void)loadChannelsFromURL:(NSString *)m3uURL {
    if (self.internalIsLoadingChannels) {
        NSLog(@"⚠️ [DATA] Channel loading already in progress, ignoring request");
        return;
    }
    
    NSLog(@"📊 [DATA] Starting channel loading from URL: %@", m3uURL);
    self.m3uURL = m3uURL;
    self.internalIsLoadingChannels = YES;
    self.internalChannelLoadingProgress = 0.0;
    
    [self.delegate dataManagerDidStartLoading:@"Loading Channels"];
    
    __weak __typeof__(self) weakSelf = self;
    [self.channelManager loadChannelsFromURL:m3uURL
                                  completion:^(NSArray<VLCChannel *> *channels, NSError *error) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.internalIsLoadingChannels = NO;
            strongSelf.internalChannelLoadingProgress = 1.0;
            
            if (error) {
                NSLog(@"❌ [DATA] Channel loading failed: %@", error.localizedDescription);
                [strongSelf.delegate dataManagerDidEncounterError:error operation:@"Loading Channels"];
                [strongSelf.delegate dataManagerDidFinishLoading:@"Loading Channels" success:NO];
            } else {
                NSLog(@"✅ [DATA] Channel loading completed: %lu channels", (unsigned long)channels.count);
                [strongSelf updateChannelData:channels];
                
                // NOTE: dataManagerDidUpdateChannels is now called after background processing completes
                [strongSelf.delegate dataManagerDidFinishLoading:@"Loading Channels" success:YES];
                
                // CORRECT SEQUENCE: Timeshift detection will be triggered after EPG loading completes
                NSLog(@"📺 [DATA] Channels loaded successfully - timeshift detection will happen after EPG loads");
            }
        });
    } progress:^(float progress, NSString *status) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.internalChannelLoadingProgress = progress;
            [strongSelf.delegate dataManagerDidUpdateProgress:progress operation:status];
        });
    }];
}

- (void)loadEPGFromURL:(NSString *)epgURL {
    if (self.internalIsLoadingEPG) {
        NSLog(@"⚠️ [DATA] EPG loading already in progress, ignoring request (URL: %@)", epgURL ?: @"nil");
        return;
    }
    
    if (!epgURL || [epgURL length] == 0) {
        NSLog(@"⚠️ [DATA] Cannot load EPG - no URL provided");
        return;
    }
    
    // Prevent rapid successive calls with stronger startup protection
    static NSTimeInterval lastEPGLoadTime = 0;
    static NSString *lastEPGURL = nil;
    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    
    // Stronger rate limiting: 10 seconds for same URL, 3 seconds for different URLs
    NSTimeInterval cooldownTime = (lastEPGURL && [lastEPGURL isEqualToString:epgURL]) ? 10.0 : 3.0;
    
    if (currentTime - lastEPGLoadTime < cooldownTime) {
        // Include stack trace information to identify duplicate callers
        NSArray *callStack = [NSThread callStackSymbols];
        NSString *caller = (callStack.count > 1) ? callStack[1] : @"Unknown";
        NSLog(@"🚫 [DATA] EPG loading BLOCKED - wait %.1f seconds (URL: %@, Caller: %@)", 
              cooldownTime - (currentTime - lastEPGLoadTime), epgURL, caller);
        return;
    }
    
    lastEPGLoadTime = currentTime;
    lastEPGURL = [epgURL copy];
    
    // Log caller information to track EPG loading sources
    NSArray *callStack = [NSThread callStackSymbols];
    NSString *caller = (callStack.count > 1) ? callStack[1] : @"Unknown";
    NSLog(@"📊 [DATA] ✅ ALLOWED EPG loading from URL: %@ (Caller: %@)", epgURL, caller);
    self.epgURL = epgURL;
    self.internalIsLoadingEPG = YES;
    self.internalEpgLoadingProgress = 0.0;
    
    [self.delegate dataManagerDidStartLoading:@"Loading EPG"];
    
    // Update EPG manager time offset
    self.epgManager.timeOffsetHours = self.epgTimeOffsetHours;
    
    __weak __typeof__(self) weakSelf = self;
    [self.epgManager loadEPGFromURL:epgURL
                         completion:^(NSDictionary *epgData, NSError *error) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.internalIsLoadingEPG = NO;
            strongSelf.internalEpgLoadingProgress = 1.0;
            
            if (error) {
                NSLog(@"❌ [DATA] EPG loading failed: %@", error.localizedDescription);
                strongSelf.internalIsEPGLoaded = NO;
                [strongSelf.delegate dataManagerDidEncounterError:error operation:@"Loading EPG"];
                [strongSelf.delegate dataManagerDidFinishLoading:@"Loading EPG" success:NO];
            } else {
                NSLog(@"✅ [DATA] EPG loading completed: %lu programs", (unsigned long)[(NSDictionary *)epgData count]);
                strongSelf.internalEpgData = epgData;
                strongSelf.internalIsEPGLoaded = YES;
                
                // CRITICAL FIX: Check if channels are available before matching
                if (strongSelf.channels && strongSelf.channels.count > 0) {
                    NSLog(@"🔗 [DATA] Matching EPG with %lu available channels", (unsigned long)strongSelf.channels.count);
                    [strongSelf.epgManager matchEPGWithChannels:strongSelf.channels];
                } else {
                    NSLog(@"⚠️ [DATA] No channels available for EPG matching yet - EPG will be matched when channels are loaded");
                }
                
                [strongSelf.delegate dataManagerDidUpdateEPG:epgData];
                [strongSelf.delegate dataManagerDidFinishLoading:@"Loading EPG" success:YES];
                
                // CORRECT SEQUENCE: Step 3 - Now that EPG is loaded, start timeshift detection
                NSLog(@"📅 [UNIVERSAL] Step 3: EPG complete, now starting timeshift detection...");
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [strongSelf detectTimeshiftSupport];
                });
            }
        });
    } progress:^(float progress, NSString *status) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.internalEpgLoadingProgress = progress;
            [strongSelf.delegate dataManagerDidUpdateProgress:progress operation:status];
        });
    }];
}

- (void)forceReloadChannels {
    if (self.m3uURL) {
        NSLog(@"🔄 [DATA] Force reloading channels (bypassing cache)");
        [self forceReloadChannelsFromURL:self.m3uURL];
    } else {
        NSLog(@"⚠️ [DATA] Cannot force reload channels - no URL set");
    }
}

- (void)forceReloadChannelsFromURL:(NSString *)m3uURL {
    if (self.internalIsLoadingChannels) {
        NSLog(@"⚠️ [DATA] Channel force reload blocked - loading already in progress");
        return;
    }
    
    NSLog(@"🚀 [DATA] Force reloading channels from URL (BYPASSING CACHE): %@", m3uURL);
    self.m3uURL = m3uURL;
    self.internalIsLoadingChannels = YES;
    self.internalChannelLoadingProgress = 0.0;
    
    [self.delegate dataManagerDidStartLoading:@"Loading Channels"];
    
    __weak __typeof__(self) weakSelf = self;
    // CRITICAL: Call downloadAndParseM3U directly to bypass cache
    [self.channelManager downloadAndParseM3U:m3uURL
                                  completion:^(NSArray<VLCChannel *> *channels, NSError *error) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.internalIsLoadingChannels = NO;
            strongSelf.internalChannelLoadingProgress = 1.0;
            
            if (error) {
                NSLog(@"❌ [DATA] Channel force reload failed: %@", error.localizedDescription);
                [strongSelf.delegate dataManagerDidEncounterError:error operation:@"Force Loading Channels"];
                [strongSelf.delegate dataManagerDidFinishLoading:@"Loading Channels" success:NO];
            } else {
                NSLog(@"✅ [DATA] Channel force reload completed: %lu channels", (unsigned long)channels.count);
                [strongSelf updateChannelData:channels];
                
                // NOTE: dataManagerDidUpdateChannels is now called after background processing completes
                [strongSelf.delegate dataManagerDidFinishLoading:@"Loading Channels" success:YES];
                
                // CORRECT SEQUENCE: Timeshift detection will be triggered after EPG loading completes
                NSLog(@"📺 [DATA] Channels force reloaded successfully - timeshift detection will happen after EPG loads");
            }
        });
    } progress:^(float progress, NSString *status) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.internalChannelLoadingProgress = progress;
            [strongSelf.delegate dataManagerDidUpdateProgress:progress operation:status];
        });
    }];
}

- (void)forceReloadEPG {
    if (self.internalIsLoadingEPG) {
        NSLog(@"⚠️ [DATA] EPG force reload blocked - loading already in progress");
        return;
    }
    
    if (self.epgURL) {
        NSLog(@"🔄 [DATA] Force reloading EPG");
        self.internalIsLoadingEPG = YES; // Prevent concurrent loads
        
        // CRITICAL: Declare weak reference OUTSIDE the blocks
        __weak __typeof__(self) weakSelf = self;
        
        [self.epgManager forceReloadEPGFromURL:self.epgURL completion:^(NSDictionary *epgData, NSError *error) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            // Handle completion similar to loadEPGFromURL
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.internalIsLoadingEPG = NO; // CRITICAL: Clear loading state
                
                if (error) {
                    NSLog(@"❌ [DATA] EPG force reload failed: %@", error.localizedDescription);
                    strongSelf.internalIsEPGLoaded = NO;
                    [strongSelf.delegate dataManagerDidEncounterError:error operation:@"Force Reload EPG"];
                    [strongSelf.delegate dataManagerDidFinishLoading:@"Loading EPG" success:NO];
                } else {
                    NSLog(@"✅ [DATA] EPG force reload completed: %lu programs", (unsigned long)[(NSDictionary *)epgData count]);
                    strongSelf.internalEpgData = epgData;
                    strongSelf.internalIsEPGLoaded = YES;
                    
                    // CRITICAL FIX: Check if channels are available before matching
                    if (strongSelf.channels && strongSelf.channels.count > 0) {
                        NSLog(@"🔗 [DATA] Force reload - Matching EPG with %lu available channels", (unsigned long)strongSelf.channels.count);
                        [strongSelf.epgManager matchEPGWithChannels:strongSelf.channels];
                    } else {
                        NSLog(@"⚠️ [DATA] Force reload - No channels available for EPG matching yet");
                    }
                    
                    [strongSelf.delegate dataManagerDidUpdateEPG:epgData];
                    [strongSelf.delegate dataManagerDidFinishLoading:@"Loading EPG" success:YES];
                    
                    // CORRECT SEQUENCE: Start timeshift detection after force EPG reload completes
                    NSLog(@"📅 [DATA] Force EPG reload complete, now starting timeshift detection...");
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [strongSelf detectTimeshiftSupport];
                    });
                }
            });
        } progress:^(float progress, NSString *status) {
            __strong __typeof__(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            NSLog(@"📊 [DATA-PROGRESS] EPG progress: %.1f%% - %@", progress * 100, status);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.internalEpgLoadingProgress = progress;
                [strongSelf.delegate dataManagerDidUpdateProgress:progress operation:status];
            });
        }];
    } else {
        NSLog(@"⚠️ [DATA] Cannot force reload EPG - no URL set");
    }
}

- (void)detectTimeshiftSupport {
    if (self.channels.count == 0) {
        NSLog(@"⚠️ [DATA] Cannot detect timeshift - no channels loaded");
        return;
    }
    
    // Prevent duplicate timeshift detection calls
    static NSTimeInterval lastTimeshiftDetection = 0;
    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
    if (currentTime - lastTimeshiftDetection < 30.0) { // 30 second cooldown
        NSLog(@"⚠️ [DATA] Timeshift detection rate limited - wait %.1f seconds", 
              30.0 - (currentTime - lastTimeshiftDetection));
        return;
    }
    lastTimeshiftDetection = currentTime;
    
    NSLog(@"🔄 [DATA] Starting timeshift detection for %lu channels with M3U URL: %@", (unsigned long)self.channels.count, self.m3uURL ?: @"None");
    
    __weak __typeof__(self) weakSelf = self;
    [self.timeshiftManager detectTimeshiftSupport:self.channels
                                        m3uURL:self.m3uURL
                                       completion:^(NSInteger detectedChannels, NSError *error) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                NSLog(@"❌ [DATA] Timeshift detection failed: %@", error.localizedDescription);
            } else {
                NSLog(@"✅ [DATA] Timeshift detection completed: %ld channels support timeshift", (long)detectedChannels);
                [strongSelf.delegate dataManagerDidDetectTimeshift:detectedChannels];
            }
        });
    }];
}

#pragma mark - Data Access Helpers

- (VLCChannel *)channelAtIndex:(NSInteger)index {
    if (index >= 0 && index < self.channels.count) {
        return self.channels[index];
    }
    return nil;
}

- (NSArray<VLCChannel *> *)channelsInGroup:(NSString *)groupName {
    return self.channelsByGroup[groupName];
}

- (NSArray<NSString *> *)groupsInCategory:(NSString *)categoryName {
    return self.groupsByCategory[categoryName];
}

- (VLCProgram *)currentProgramForChannel:(VLCChannel *)channel {
    return [self.epgManager currentProgramForChannel:channel];
}

- (NSArray<VLCProgram *> *)programsForChannel:(VLCChannel *)channel {
    return [self.epgManager programsForChannel:channel];
}

#pragma mark - Internal Data Updates

- (void)updateDataStructuresWithChannels:(NSArray<VLCChannel *> *)channels {
    [self updateChannelData:channels];
}

- (void)updateChannelData:(NSArray<VLCChannel *> *)channels {
    // Update internal data structures through channel manager
    self.internalChannels = channels;
    
    // ULTRA-FAST STARTUP: Move ALL heavy processing to background thread
    NSLog(@"🚀 [DATA] FAST STARTUP: Processing %lu channels in background thread...", (unsigned long)channels.count);
    
    // Notify delegate that initial channel data is available (for immediate UI display)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate dataManagerDidUpdateChannels:channels];
        NSLog(@"📱 [DATA] ✅ Initial channel data sent to UI (%lu channels)", (unsigned long)channels.count);
    });
    
    __weak __typeof__(self) weakSelf = self;
    
    // Listen for completion notification
    [[NSNotificationCenter defaultCenter] addObserverForName:@"VLCChannelManagerDataUpdated" 
                                                       object:self.channelManager 
                                                        queue:[NSOperationQueue mainQueue] 
                                                   usingBlock:^(NSNotification *note) {
        __strong __typeof__(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        // Remove observer to prevent multiple calls
        [[NSNotificationCenter defaultCenter] removeObserver:strongSelf name:@"VLCChannelManagerDataUpdated" object:strongSelf.channelManager];
        
        // Get the organized data from channel manager (already on main thread)
        NSArray *cmGroups = [strongSelf.channelManager groups];
        NSDictionary *cmChannelsByGroup = [strongSelf.channelManager channelsByGroup];
        NSDictionary *cmGroupsByCategory = [strongSelf.channelManager groupsByCategory];
        
        NSLog(@"🔍 [DATA] ChannelManager provides: %lu groups, %lu group mappings, %lu categories", 
              (unsigned long)cmGroups.count, (unsigned long)cmChannelsByGroup.count, (unsigned long)cmGroupsByCategory.count);
        
        // Update internal data (already on main thread)
        strongSelf.internalGroups = cmGroups;
        strongSelf.internalChannelsByGroup = cmChannelsByGroup;
        strongSelf.internalGroupsByCategory = cmGroupsByCategory;
        strongSelf.internalCategories = [strongSelf.channelManager categories];
        
        NSLog(@"📊 [DATA] ✅ Updated channel data: %lu channels, %lu groups", 
              (unsigned long)channels.count, (unsigned long)strongSelf.internalGroups.count);
        
        // CRITICAL: Notify delegate that channels are ready AFTER background processing completes
        [strongSelf.delegate dataManagerDidUpdateChannels:channels];
            
        // CRITICAL FIX: Always force EPG matching when channels are updated
        // This ensures that EPG data loaded from cache gets properly matched
        if (strongSelf.internalEpgData && strongSelf.internalEpgData.count > 0) {
            NSLog(@"🔗 [DATA] EPG data available (%lu entries) - force matching with %lu channels", 
                  (unsigned long)strongSelf.internalEpgData.count, (unsigned long)channels.count);
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [strongSelf.epgManager matchEPGWithChannels:channels];
                dispatch_async(dispatch_get_main_queue(), ^{
                    strongSelf.internalIsEPGLoaded = YES;
                    [strongSelf.delegate dataManagerDidUpdateEPG:strongSelf.internalEpgData];
                    NSLog(@"🔗 [DATA] Forced EPG matching completed and delegate notified");
                    
                    // CORRECT SEQUENCE: Start timeshift detection after EPG matching completes (cache case)
                    NSLog(@"📅 [UNIVERSAL] Step 3: EPG cache matched, now starting timeshift detection...");
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        [strongSelf detectTimeshiftSupport];
                    });
                });
            });
        } else if (!strongSelf.internalIsEPGLoaded && !strongSelf.internalIsLoadingEPG && strongSelf.epgURL && [strongSelf.epgURL length] > 0) {
            // UNIVERSAL SEQUENCE: Now that channels are loaded, start EPG loading
            NSLog(@"📅 [UNIVERSAL] Step 2: Channels complete (%lu channels), now loading EPG from: %@", (unsigned long)channels.count, strongSelf.epgURL);
            [strongSelf loadEPGFromURL:strongSelf.epgURL];
        } else if (!strongSelf.epgURL || [strongSelf.epgURL length] == 0) {
            NSLog(@"⚠️ [DATA] No EPG URL available - skipping EPG loading");
        } else if (strongSelf.internalIsLoadingEPG) {
            NSLog(@"📅 [DATA] EPG loading already in progress - waiting for completion");
        } else {
            NSLog(@"📅 [DATA] EPG loading conditions not met - EPG loaded: %@, EPG data count: %lu", 
                  strongSelf.internalIsEPGLoaded ? @"YES" : @"NO", (unsigned long)strongSelf.internalEpgData.count);
        }
    }];
    
    // CRITICAL FIX: Only call updateInternalDataFromCachedChannels if channels haven't been processed yet
    // Check if channel manager already has organized data (from cache loading)
    NSArray *existingGroups = [self.channelManager groups];
    if (!existingGroups || existingGroups.count == 0) {
        NSLog(@"🚀 [DATA] Channel manager has no organized data - starting background processing");
        // Start the background processing immediately (non-blocking)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            // CRITICAL: Ensure VLCChannelManager organizes the channels (BACKGROUND THREAD)
            [weakSelf.channelManager updateInternalDataFromCachedChannels:channels];
        });
    } else {
        NSLog(@"✅ [DATA] Channel manager already has organized data (%lu groups) - skipping duplicate processing", (unsigned long)existingGroups.count);
        // Data is already organized, just trigger the notification manually
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"VLCChannelManagerDataUpdated" object:self.channelManager];
        });
    }
}

#pragma mark - Memory Management

- (void)clearAllData {
    NSLog(@"🧹 [DATA] Clearing all data");
    [self clearChannelData];
    [self clearEPGData];
}

- (void)clearChannelData {
    NSLog(@"🧹 [DATA] Clearing channel data");
    self.internalChannels = @[];
    self.internalGroups = @[];
    self.internalChannelsByGroup = @{};
    self.internalGroupsByCategory = @{};
    [self initializeDataStructures];
}

- (void)clearEPGData {
    NSLog(@"🧹 [DATA] Clearing EPG data");
    self.internalEpgData = @{};
    self.internalIsEPGLoaded = NO;
    [self.epgManager clearEPGData];
}

- (NSUInteger)memoryUsageInBytes {
    NSUInteger total = 0;
    
    if (self.channelManager) {
        total += [self.channelManager estimatedMemoryUsage];
    }
    
    if (self.epgManager) {
        total += [self.epgManager estimatedMemoryUsage];
    }
    
    if (self.cacheManager) {
        total += self.cacheManager.totalCacheSizeBytes;
    }
    
    return total;
}

#pragma mark - Configuration Updates

- (void)setEpgTimeOffsetHours:(NSTimeInterval)epgTimeOffsetHours {
    _epgTimeOffsetHours = epgTimeOffsetHours;
    
    // Update EPG manager if it exists
    if (_epgManager) {
        _epgManager.timeOffsetHours = epgTimeOffsetHours;
    }
}

#pragma mark - Universal Startup (All Platforms)

- (void)startUniversalDataLoading {
    NSLog(@"🚀 [UNIVERSAL] Starting universal data loading sequence...");
    
    // Ensure we have URLs to load from
    if (!self.m3uURL || [self.m3uURL length] == 0) {
        NSLog(@"⚠️ [UNIVERSAL] No M3U URL available - cannot start data loading");
        return;
    }
    
    NSLog(@"📺 [UNIVERSAL] Step 1: Loading channels from: %@", self.m3uURL);
    
    // STEP 1: Load channels first (EPG will load automatically when channels complete)
    [self loadChannelsFromURL:self.m3uURL];
    
    // Note: EPG loading will be triggered automatically in updateChannelData when channels complete
    // Note: Timeshift detection will be triggered after EPG loading completes
    // This ensures proper sequential loading: Channels → EPG → Timeshift
}

@end 