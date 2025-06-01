#import "VLCClickableLabel.h"

@interface VLCClickableLabel ()
@property (nonatomic, retain) NSTrackingArea *trackingArea;
@end

@implementation VLCClickableLabel

@synthesize delegate;
@synthesize identifier = _identifier;
@synthesize text = _text;
@synthesize placeholderText = _placeholderText;
@synthesize isHovered;
@synthesize trackingArea = _trackingArea;

- (instancetype)initWithFrame:(NSRect)frame identifier:(NSString *)identifier {
    self = [super initWithFrame:frame];
    if (self) {
        self.identifier = identifier;
        self.isHovered = NO;
        self.text = @"";
        self.placeholderText = @"";
        
        [self setupTrackingArea];
    }
    return self;
}

- (void)dealloc {
    [_identifier release];
    [_text release];
    [_placeholderText release];
    [_trackingArea release];
    [super dealloc];
}

- (void)setupTrackingArea {
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
        [self.trackingArea release];
    }
    
    self.trackingArea = [[NSTrackingArea alloc] 
        initWithRect:self.bounds
        options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow)
        owner:self
        userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    [self setupTrackingArea];
}

- (void)setText:(NSString *)text {
    if (_text != text) {
        [_text release];
        _text = [text retain];
        [self setNeedsDisplay:YES];
    }
}

- (void)setPlaceholderText:(NSString *)placeholder {
    if (_placeholderText != placeholder) {
        [_placeholderText release];
        _placeholderText = [placeholder retain];
        [self setNeedsDisplay:YES];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    // No background or border - transparent label
    
    // Draw text
    NSString *displayText = (self.text && [self.text length] > 0) ? self.text : self.placeholderText;
    NSColor *textColor = (self.text && [self.text length] > 0) ? [NSColor whiteColor] : [NSColor grayColor];
    
    if (displayText && [displayText length] > 0) {
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        [style setAlignment:NSTextAlignmentLeft];
        [style setLineBreakMode:NSLineBreakByTruncatingTail];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSRect textRect = NSInsetRect(self.bounds, 5, 5);
        [displayText drawInRect:textRect withAttributes:attrs];
        
        [style release];
    }
    
    // Draw copy icon if there's text and we're hovered
    if (self.text && [self.text length] > 0 && self.isHovered) {
        NSRect iconRect = NSMakeRect(self.bounds.size.width - 25, 
                                   (self.bounds.size.height - 15) / 2, 
                                   15, 15);
        
        // Draw a simple copy icon (two overlapping rectangles)
        [[NSColor lightGrayColor] set];
        NSRect rect1 = NSMakeRect(iconRect.origin.x + 2, iconRect.origin.y + 2, 8, 8);
        NSRect rect2 = NSMakeRect(iconRect.origin.x + 5, iconRect.origin.y + 5, 8, 8);
        
        NSFrameRect(rect1);
        NSFrameRect(rect2);
    }
}

- (void)mouseEntered:(NSEvent *)event {
    self.isHovered = YES;
    [self setNeedsDisplay:YES];
    
    // Change cursor to pointing hand if there's text
    if (self.text && [self.text length] > 0) {
        [[NSCursor pointingHandCursor] set];
    }
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovered = NO;
    [self setNeedsDisplay:YES];
    [[NSCursor arrowCursor] set];
}

- (void)mouseDown:(NSEvent *)event {
    if (self.text && [self.text length] > 0) {
        // Copy text to clipboard
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard setString:self.text forType:NSPasteboardTypeString];
        
        // Notify delegate
        if (self.delegate && [self.delegate respondsToSelector:@selector(clickableLabelWasClicked:withText:)]) {
            [self.delegate clickableLabelWasClicked:self.identifier withText:self.text];
        }
        
        // Visual feedback - briefly change background color
        NSColor *originalColor = [NSColor colorWithCalibratedRed:0.2 green:0.3 blue:0.4 alpha:1.0];
        NSColor *clickColor = [NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.3 alpha:1.0];
        
        [clickColor set];
        NSRectFill(self.bounds);
        [self displayIfNeeded];
        
        // Restore original color after a brief delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            [self setNeedsDisplay:YES];
        });
    }
}

@end 