//
//  PlatformBridge.h
//  BasicIPTV
//
//  Platform abstraction layer for multi-platform support
//

#ifndef PlatformBridge_h
#define PlatformBridge_h

#if TARGET_OS_IOS || TARGET_OS_TV
    #import <UIKit/UIKit.h>
    #import <Foundation/Foundation.h>

    // Platform-specific type definitions for iOS/tvOS
    typedef UIView PlatformView;
    typedef UIViewController PlatformViewController;
    typedef UIColor PlatformColor;
    typedef UIFont PlatformFont;
    typedef CGRect PlatformRect;
    typedef CGSize PlatformSize;
    typedef CGPoint PlatformPoint;
    typedef UIEvent PlatformEvent;
    typedef UITouch PlatformTouch;
    typedef UIImage PlatformImage;
    typedef UITextField PlatformTextField;
    typedef UIButton PlatformButton;
    typedef UILabel PlatformLabel;
    typedef UIScrollView PlatformScrollView;
    typedef UIApplication PlatformApplication;
    typedef UIWindow PlatformWindow;
    typedef UIScreen PlatformScreen;
    typedef UIGestureRecognizer PlatformGestureRecognizer;
    typedef UITableView PlatformTableView;
    #if TARGET_OS_IOS
        typedef UISlider PlatformSlider;
    #else
        // tvOS doesn't have UISlider, use a generic view instead
        typedef UIView PlatformSlider;
    #endif
    typedef UIActivityIndicatorView PlatformActivityIndicator;

    #define PlatformMainScreen [UIScreen mainScreen]
    #define PlatformSharedApplication [UIApplication sharedApplication]

#elif TARGET_OS_OSX
    #import <Cocoa/Cocoa.h>
    #import <AppKit/AppKit.h>

    // Platform-specific type definitions for macOS
    typedef NSView PlatformView;
    typedef NSViewController PlatformViewController;
    typedef NSColor PlatformColor;
    typedef NSFont PlatformFont;
    typedef NSRect PlatformRect;
    typedef NSSize PlatformSize;
    typedef NSPoint PlatformPoint;
    typedef NSEvent PlatformEvent;
    typedef NSTouch PlatformTouch;
    typedef NSImage PlatformImage;
    typedef NSTextField PlatformTextField;
    typedef NSButton PlatformButton;
    typedef NSTextField PlatformLabel;
    typedef NSScrollView PlatformScrollView;
    typedef NSApplication PlatformApplication;
    typedef NSWindow PlatformWindow;
    typedef NSScreen PlatformScreen;
    typedef NSGestureRecognizer PlatformGestureRecognizer;
    typedef NSTableView PlatformTableView;
    typedef NSSlider PlatformSlider;
    typedef NSProgressIndicator PlatformActivityIndicator;

    #define PlatformMainScreen [NSScreen mainScreen]
    #define PlatformSharedApplication [NSApplication sharedApplication]

#endif

// Common macros and utilities
#define PLATFORM_IS_IOS (TARGET_OS_IOS && !TARGET_OS_TV)
#define PLATFORM_IS_TVOS TARGET_OS_TV
#define PLATFORM_IS_MACOS TARGET_OS_OSX

// Color creation macros
#if TARGET_OS_IOS || TARGET_OS_TV
    #define PlatformColorRGBA(r,g,b,a) [UIColor colorWithRed:(r) green:(g) blue:(b) alpha:(a)]
    #define PlatformColorRGB(r,g,b) [UIColor colorWithRed:(r) green:(g) blue:(b) alpha:1.0]
    #define PlatformColorWhite [UIColor whiteColor]
    #define PlatformColorBlack [UIColor blackColor]
    #define PlatformColorClear [UIColor clearColor]
#else
    #define PlatformColorRGBA(r,g,b,a) [NSColor colorWithRed:(r) green:(g) blue:(b) alpha:(a)]
    #define PlatformColorRGB(r,g,b) [NSColor colorWithRed:(r) green:(g) blue:(b) alpha:1.0]
    #define PlatformColorWhite [NSColor whiteColor]
    #define PlatformColorBlack [NSColor blackColor]
    #define PlatformColorClear [NSColor clearColor]
#endif

// Font creation macros
#if TARGET_OS_IOS || TARGET_OS_TV
    #define PlatformSystemFont(size) [UIFont systemFontOfSize:(size)]
    #define PlatformBoldSystemFont(size) [UIFont boldSystemFontOfSize:(size)]
#else
    #define PlatformSystemFont(size) [NSFont systemFontOfSize:(size)]
    #define PlatformBoldSystemFont(size) [NSFont boldSystemFontOfSize:(size)]
#endif

#endif /* PlatformBridge_h */ 