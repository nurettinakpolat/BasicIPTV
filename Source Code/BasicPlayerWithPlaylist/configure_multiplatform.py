#!/usr/bin/env python3
"""
Multi-platform Configuration Script for BasicIPTV
This script helps configure the Xcode project to support macOS, iOS, and tvOS platforms.
"""

import os
import sys
import subprocess
import json

def run_command(cmd):
    """Run a shell command and return the result."""
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return result.returncode == 0, result.stdout, result.stderr
    except Exception as e:
        return False, "", str(e)

def backup_project():
    """Create a backup of the current project file."""
    project_path = "BasicIPTV.xcodeproj/project.pbxproj"
    backup_path = "BasicIPTV.xcodeproj/project.pbxproj.backup"
    
    if os.path.exists(project_path):
        success, _, error = run_command(f"cp '{project_path}' '{backup_path}'")
        if success:
            print("✅ Project backup created")
            return True
        else:
            print(f"❌ Failed to create backup: {error}")
            return False
    return False

def add_ios_target():
    """Add iOS target configuration to the project."""
    print("📱 Configuring iOS target...")
    
    # This would typically involve using xcodeproj tools or manual editing
    # For now, we'll provide instructions
    instructions = """
    To add iOS target support:
    1. Open BasicIPTV.xcodeproj in Xcode
    2. Select the project in the navigator
    3. Click the '+' button to add a new target
    4. Choose 'iOS' -> 'App'
    5. Set Product Name to 'BasicIPTV-iOS'
    6. Set Bundle Identifier to 'com.nucom.basictv.ios'
    7. Choose Objective-C as the language
    8. Add the following files to the iOS target:
       - All .m files except main.m (use main_ios.m instead)
       - All .h files
       - VLCKit.xcframework
       - Info-iOS.plist (as Info.plist for iOS target)
    """
    print(instructions)

def add_tvos_target():
    """Add tvOS target configuration to the project."""
    print("📺 Configuring tvOS target...")
    
    instructions = """
    To add tvOS target support:
    1. In Xcode, add another new target
    2. Choose 'tvOS' -> 'App'
    3. Set Product Name to 'BasicIPTV-tvOS'
    4. Set Bundle Identifier to 'com.nucom.basictv.tvos'
    5. Choose Objective-C as the language
    6. Add the same files as iOS target
    7. Use Info-tvOS.plist as Info.plist for tvOS target
    """
    print(instructions)

def update_build_settings():
    """Update build settings for multi-platform support."""
    print("⚙️ Updating build settings...")
    
    settings_info = """
    Update these build settings for each target:
    
    For macOS target:
    - SUPPORTED_PLATFORMS = macosx
    - SDKROOT = macosx
    - MACOSX_DEPLOYMENT_TARGET = 15.0
    - INFOPLIST_FILE = Info.plist
    
    For iOS target:
    - SUPPORTED_PLATFORMS = iphoneos iphonesimulator
    - SDKROOT = iphoneos
    - IPHONEOS_DEPLOYMENT_TARGET = 15.0
    - INFOPLIST_FILE = Info-iOS.plist
    - TARGETED_DEVICE_FAMILY = 1,2 (iPhone and iPad)
    
    For tvOS target:
    - SUPPORTED_PLATFORMS = appletvos appletvsimulator
    - SDKROOT = appletvos
    - TVOS_DEPLOYMENT_TARGET = 15.0
    - INFOPLIST_FILE = Info-tvOS.plist
    - TARGETED_DEVICE_FAMILY = 3 (Apple TV)
    """
    print(settings_info)

def create_scheme_configurations():
    """Create scheme configurations for each platform."""
    print("🎯 Creating scheme configurations...")
    
    scheme_info = """
    Create the following schemes in Xcode:
    
    1. BasicIPTV-macOS
       - Target: BasicIPTV (original)
       - Run Destination: My Mac
    
    2. BasicIPTV-iOS
       - Target: BasicIPTV-iOS
       - Run Destination: iPhone/iPad Simulator or Device
    
    3. BasicIPTV-tvOS
       - Target: BasicIPTV-tvOS
       - Run Destination: Apple TV Simulator or Device
    """
    print(scheme_info)

def verify_vlc_framework():
    """Verify VLCKit.xcframework supports all platforms."""
    print("🔍 Verifying VLCKit.xcframework...")
    
    framework_path = "../../VLCKit.xcframework"
    if os.path.exists(framework_path):
        # List the platforms in the framework
        success, output, error = run_command(f"ls -la '{framework_path}'")
        if success:
            print("VLCKit.xcframework contents:")
            print(output)
            
            # Check for required platforms
            required_platforms = [
                "macos-arm64_x86_64",
                "ios-arm64",
                "ios-arm64_x86_64-simulator",
                "tvos-arm64",
                "tvos-arm64_x86_64-simulator"
            ]
            
            for platform in required_platforms:
                platform_path = os.path.join(framework_path, platform)
                if os.path.exists(platform_path):
                    print(f"✅ {platform} - Available")
                else:
                    print(f"❌ {platform} - Missing")
        else:
            print(f"❌ Failed to read framework: {error}")
    else:
        print("❌ VLCKit.xcframework not found")

def main():
    """Main configuration function."""
    print("🚀 BasicIPTV Multi-Platform Configuration")
    print("=" * 50)
    
    # Check if we're in the right directory
    if not os.path.exists("BasicIPTV.xcodeproj"):
        print("❌ Error: BasicIPTV.xcodeproj not found in current directory")
        print("Please run this script from the project directory")
        sys.exit(1)
    
    # Create backup
    if not backup_project():
        print("❌ Failed to create project backup")
        sys.exit(1)
    
    # Verify VLC framework
    verify_vlc_framework()
    
    # Configuration steps
    add_ios_target()
    add_tvos_target()
    update_build_settings()
    create_scheme_configurations()
    
    print("\n" + "=" * 50)
    print("✅ Configuration guide complete!")
    print("\nNext steps:")
    print("1. Open BasicIPTV.xcodeproj in Xcode")
    print("2. Follow the instructions above to add targets")
    print("3. Build and test each platform")
    print("\nFiles created:")
    print("- PlatformBridge.h (Platform abstraction)")
    print("- VLCUIVideoView.h/m (iOS/tvOS video view)")
    print("- VLCUIOverlayView.h/m (iOS/tvOS overlay)")
    print("- Info-iOS.plist (iOS configuration)")
    print("- Info-tvOS.plist (tvOS configuration)")
    print("- main.m (Updated with platform conditionals)")

if __name__ == "__main__":
    main() 