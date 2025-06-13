# BasicIPTV Multi-Platform Setup Guide

This guide explains how to configure the BasicIPTV app to run on macOS, iOS, iPad, and Apple TV while maintaining the existing macOS functionality.

## Overview

The app has been restructured to support multiple platforms using:
- **Platform Bridge**: Abstraction layer for platform-specific APIs
- **Conditional Compilation**: Platform-specific code paths
- **Shared Business Logic**: Common functionality across platforms
- **Platform-Specific UI**: Native UI for each platform

## Files Created/Modified

### New Platform Abstraction Files
- `PlatformBridge.h` - Platform abstraction layer
- `VLCUIVideoView.h/m` - UIKit-based video view for iOS/tvOS
- `VLCUIOverlayView.h/m` - UIKit-based overlay for iOS/tvOS
- `Info-iOS.plist` - iOS-specific configuration
- `Info-tvOS.plist` - tvOS-specific configuration

### Modified Files
- `main.m` - Updated with platform conditionals
- `VLCOverlayView.h` - Updated to use platform types

## Setup Instructions

### 1. Run Configuration Script
```bash
cd "Source Code/BasicPlayerWithPlaylist"
python3 configure_multiplatform.py
```

### 2. Open Project in Xcode
Open `BasicIPTV.xcodeproj` in Xcode.

### 3. Add iOS Target

1. Select the project in the navigator
2. Click the '+' button to add a new target
3. Choose **iOS** → **App**
4. Configure the target:
   - **Product Name**: `BasicIPTV-iOS`
   - **Bundle Identifier**: `com.nucom.basictv.ios`
   - **Language**: Objective-C
   - **Use Core Data**: No
   - **Include Tests**: No

5. Add files to the iOS target:
   - All `.h` files
   - All `.m` files except `main.m`
   - `VLCKit.xcframework`
   - Set `Info-iOS.plist` as the Info.plist file

6. Update iOS target build settings:
   - **Supported Platforms**: `iphoneos iphonesimulator`
   - **iOS Deployment Target**: `15.0`
   - **Targeted Device Family**: `1,2` (iPhone and iPad)
   - **Info.plist File**: `Info-iOS.plist`

### 4. Add tvOS Target

1. Add another new target
2. Choose **tvOS** → **App**
3. Configure the target:
   - **Product Name**: `BasicIPTV-tvOS`
   - **Bundle Identifier**: `com.nucom.basictv.tvos`
   - **Language**: Objective-C

4. Add the same files as iOS target
5. Update tvOS target build settings:
   - **Supported Platforms**: `appletvos appletvsimulator`
   - **tvOS Deployment Target**: `15.0`
   - **Targeted Device Family**: `3` (Apple TV)
   - **Info.plist File**: `Info-tvOS.plist`

### 5. Configure Build Settings

For each target, ensure these settings are correct:

#### macOS Target (Original)
```
SUPPORTED_PLATFORMS = macosx
SDKROOT = macosx
MACOSX_DEPLOYMENT_TARGET = 15.0
INFOPLIST_FILE = Info.plist
```

#### iOS Target
```
SUPPORTED_PLATFORMS = iphoneos iphonesimulator
SDKROOT = iphoneos
IPHONEOS_DEPLOYMENT_TARGET = 15.0
INFOPLIST_FILE = Info-iOS.plist
TARGETED_DEVICE_FAMILY = 1,2
```

#### tvOS Target
```
SUPPORTED_PLATFORMS = appletvos appletvsimulator
SDKROOT = appletvos
TVOS_DEPLOYMENT_TARGET = 15.0
INFOPLIST_FILE = Info-tvOS.plist
TARGETED_DEVICE_FAMILY = 3
```

### 6. Create Schemes

Create separate schemes for each platform:

1. **BasicIPTV-macOS**
   - Target: BasicIPTV (original)
   - Run Destination: My Mac

2. **BasicIPTV-iOS**
   - Target: BasicIPTV-iOS
   - Run Destination: iPhone/iPad Simulator or Device

3. **BasicIPTV-tvOS**
   - Target: BasicIPTV-tvOS
   - Run Destination: Apple TV Simulator or Device

## Platform-Specific Features

### macOS
- Full desktop UI with mouse/keyboard support
- Window management and fullscreen
- Menu bar integration
- All existing features preserved

### iOS/iPad
- Touch-based navigation
- Gesture controls (tap, pan, pinch)
- Portrait and landscape orientations
- iOS-specific UI patterns

### Apple TV
- Remote control navigation
- Focus-based UI
- Living room optimized interface
- tvOS-specific interactions

## Architecture

### Platform Bridge
The `PlatformBridge.h` file provides:
- Type aliases for platform-specific classes
- Unified macros for common operations
- Conditional compilation directives

### Shared Business Logic
All business logic remains in the existing categories:
- Channel management
- EPG handling
- Settings persistence
- Media playback

### Platform-Specific UI
Each platform has its own UI implementation:
- **macOS**: `VLCOverlayView` (NSView-based)
- **iOS/tvOS**: `VLCUIOverlayView` (UIView-based)

## Building and Testing

### Build for macOS
```bash
xcodebuild -scheme BasicIPTV-macOS -destination "platform=macOS"
```

### Build for iOS
```bash
xcodebuild -scheme BasicIPTV-iOS -destination "platform=iOS Simulator,name=iPhone 15"
```

### Build for tvOS
```bash
xcodebuild -scheme BasicIPTV-tvOS -destination "platform=tvOS Simulator,name=Apple TV"
```

## Troubleshooting

### Common Issues

1. **VLCKit Framework Missing**
   - Ensure `VLCKit.xcframework` is added to all targets
   - Check framework search paths

2. **Platform-Specific Code Errors**
   - Verify conditional compilation directives
   - Check import statements

3. **Build Settings Conflicts**
   - Ensure each target has correct platform settings
   - Check deployment targets

### Debug Tips

1. Use `#if TARGET_OS_*` to debug platform-specific issues
2. Check the build log for missing frameworks
3. Verify Info.plist files are correctly assigned

## Next Steps

1. Test basic functionality on each platform
2. Implement platform-specific optimizations
3. Add platform-specific features (e.g., Siri Remote support for tvOS)
4. Optimize UI for different screen sizes
5. Add App Store metadata for each platform

## Support

For issues with the multi-platform setup:
1. Check the build logs for specific errors
2. Verify all files are added to the correct targets
3. Ensure VLCKit.xcframework supports the target platform
4. Review the platform bridge implementation

The existing macOS functionality remains completely intact, and the new platforms share the same core functionality with platform-appropriate UI adaptations. 