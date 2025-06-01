#import "VLCDropdownManager.h"

#pragma mark - VLCDropdownItem Implementation

@implementation VLCDropdownItem

+ (instancetype)itemWithValue:(id)value displayText:(NSString *)text {
    return [self itemWithValue:value displayText:text selected:NO];
}

+ (instancetype)itemWithValue:(id)value displayText:(NSString *)text selected:(BOOL)selected {
    VLCDropdownItem *item = [[VLCDropdownItem alloc] init];
    item.value = value;
    item.displayText = text;
    item.isSelected = selected;
    item.isHovered = NO;
    return [item autorelease];
}

- (void)dealloc {
    [_value release];
    [_displayText release];
    [super dealloc];
}

@end

#pragma mark - VLCDropdown Implementation

@implementation VLCDropdown

+ (instancetype)dropdownWithIdentifier:(NSString *)identifier frame:(NSRect)frame {
    VLCDropdown *dropdown = [[VLCDropdown alloc] init];
    dropdown.identifier = identifier;
    dropdown.frame = frame;
    dropdown.items = [NSMutableArray array];
    dropdown.selectedIndex = -1;
    dropdown.hoveredIndex = -1;
    dropdown.isOpen = NO;
    dropdown.autoCloseOnMouseLeave = YES;
    dropdown.optionHeight = 25.0;
    dropdown.maxVisibleOptions = 8; // Show max 8 items at once
    dropdown.scrollOffset = 0; // Start at top
    
    // Default styling
    dropdown.backgroundColor = [NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:0.98];
    dropdown.borderColor = [NSColor colorWithCalibratedRed:0.5 green:0.5 blue:0.5 alpha:1.0];
    dropdown.selectedColor = [NSColor colorWithCalibratedRed:0.3 green:0.5 blue:0.7 alpha:0.8];
    dropdown.hoveredColor = [NSColor colorWithCalibratedRed:0.25 green:0.25 blue:0.25 alpha:0.8];
    dropdown.textColor = [NSColor lightGrayColor];
    dropdown.font = [NSFont systemFontOfSize:13];
    
    return [dropdown autorelease];
}

- (void)addItem:(VLCDropdownItem *)item {
    [self.items addObject:item];
}

- (void)addItemWithValue:(id)value displayText:(NSString *)text {
    VLCDropdownItem *item = [VLCDropdownItem itemWithValue:value displayText:text];
    [self addItem:item];
}

- (void)removeAllItems {
    [self.items removeAllObjects];
    self.selectedIndex = -1;
    self.hoveredIndex = -1;
}

- (VLCDropdownItem *)itemAtIndex:(NSInteger)index {
    if (index >= 0 && index < [self.items count]) {
        return [self.items objectAtIndex:index];
    }
    return nil;
}

- (NSRect)expandedFrame {
    NSInteger visibleItemCount = MIN([self.items count], self.maxVisibleOptions);
    CGFloat optionsHeight = visibleItemCount * self.optionHeight;
    return NSMakeRect(self.frame.origin.x,
                     self.frame.origin.y - optionsHeight,
                     self.frame.size.width,
                     optionsHeight);
}

// Scrolling methods
- (void)scrollUp {
    if (self.scrollOffset > 0) {
        self.scrollOffset--;
    }
}

- (void)scrollDown {
    NSInteger maxOffset = [self maxScrollOffset];
    if (self.scrollOffset < maxOffset) {
        self.scrollOffset++;
    }
}

- (void)scrollToItem:(NSInteger)itemIndex {
    if (itemIndex < 0 || itemIndex >= [self.items count]) {
        return;
    }
    
    // If item is above visible area, scroll up
    if (itemIndex < self.scrollOffset) {
        self.scrollOffset = itemIndex;
    }
    // If item is below visible area, scroll down
    else if (itemIndex >= self.scrollOffset + self.maxVisibleOptions) {
        self.scrollOffset = itemIndex - self.maxVisibleOptions + 1;
    }
    
    // Ensure we don't scroll past bounds
    self.scrollOffset = MAX(0, MIN(self.scrollOffset, [self maxScrollOffset]));
}

- (NSInteger)maxScrollOffset {
    NSInteger itemCount = [self.items count];
    if (itemCount <= self.maxVisibleOptions) {
        return 0;
    }
    return itemCount - self.maxVisibleOptions;
}

- (void)dealloc {
    [_identifier release];
    [_items release];
    [_backgroundColor release];
    [_borderColor release];
    [_selectedColor release];
    [_hoveredColor release];
    [_textColor release];
    [_font release];
    [_onSelectionChanged release];
    [_onHoverChanged release];
    [_onClosed release];
    [super dealloc];
}

@end

#pragma mark - VLCDropdownManager Implementation

static VLCDropdownManager *sharedInstance = nil;

@implementation VLCDropdownManager

+ (instancetype)sharedManager {
    @synchronized(self) {
        if (sharedInstance == nil) {
            sharedInstance = [[VLCDropdownManager alloc] init];
        }
    }
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.activeDropdowns = [NSMutableDictionary dictionary];
        self.lastMousePosition = NSMakePoint(-1, -1);
    }
    return self;
}

- (instancetype)initWithParentView:(NSView *)parentView {
    self = [self init];
    if (self) {
        self.parentView = parentView;
    }
    return self;
}

- (void)dealloc {
    [self.mouseTrackingTimer invalidate];
    [_activeDropdowns release];
    [_mouseTrackingTimer release];
    [super dealloc];
}

#pragma mark - Dropdown Management

- (VLCDropdown *)createDropdownWithIdentifier:(NSString *)identifier frame:(NSRect)frame {
    VLCDropdown *dropdown = [VLCDropdown dropdownWithIdentifier:identifier frame:frame];
    [self.activeDropdowns setObject:dropdown forKey:identifier];
    return dropdown;
}

- (void)showDropdown:(NSString *)identifier {
    //NSLog(@"VLCDropdownManager showDropdown called for '%@'", identifier);
    VLCDropdown *dropdown = [self.activeDropdowns objectForKey:identifier];
    if (dropdown) {
        NSLog(@"Found dropdown, setting isOpen to YES");
        dropdown.isOpen = YES;
        
        // Scroll to selected item if there is one
        if (dropdown.selectedIndex >= 0) {
            [dropdown scrollToItem:dropdown.selectedIndex];
        }
        
        [self startMouseTracking];
        [self.parentView setNeedsDisplay:YES];
        //NSLog(@"Dropdown '%@' is now open, triggering redraw", identifier);
    } else {
        //NSLog(@"ERROR: Dropdown '%@' not found in activeDropdowns", identifier);
    }
}

- (void)hideDropdown:(NSString *)identifier {
    VLCDropdown *dropdown = [self.activeDropdowns objectForKey:identifier];
    if (dropdown && dropdown.isOpen) {
        dropdown.isOpen = NO;
        dropdown.hoveredIndex = -1;
        
        // Call close callback
        if (dropdown.onClosed) {
            dropdown.onClosed(dropdown);
        }
        
        [self.parentView setNeedsDisplay:YES];
        [self checkIfShouldStopMouseTracking];
    }
}

- (void)hideAllDropdowns {
    for (NSString *identifier in self.activeDropdowns) {
        [self hideDropdown:identifier];
    }
    [self stopMouseTracking];
}

- (VLCDropdown *)dropdownWithIdentifier:(NSString *)identifier {
    return [self.activeDropdowns objectForKey:identifier];
}

#pragma mark - Rendering

- (void)drawAllDropdowns:(NSRect)dirtyRect {
    //NSLog(@"VLCDropdownManager drawAllDropdowns called with %ld dropdowns", [self.activeDropdowns count]);
    
    // Draw all open dropdowns (this ensures they render on top)
    BOOL foundOpenDropdown = NO;
    for (VLCDropdown *dropdown in [self.activeDropdowns allValues]) {
        //NSLog(@"Checking dropdown '%@': isOpen=%@", dropdown.identifier, dropdown.isOpen ? @"YES" : @"NO");
        if (dropdown.isOpen) {
            foundOpenDropdown = YES;
            //NSLog(@"Drawing open dropdown '%@' with %ld items", dropdown.identifier, [dropdown.items count]);
            [self drawDropdown:dropdown];
        }
    }
    
    if (!foundOpenDropdown) {
        //NSLog(@"No open dropdowns to draw");
    }
}

- (void)drawDropdown:(VLCDropdown *)dropdown {
    if (!dropdown.isOpen || [dropdown.items count] == 0) {
        return;
    }
    
    NSRect expandedFrame = [dropdown expandedFrame];
    
    // Add shadow effect
    NSRect shadowRect = NSOffsetRect(expandedFrame, 2, -2);
    [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.3] set];
    NSRectFill(shadowRect);
    
    // Background
    [dropdown.backgroundColor set];
    NSRectFill(expandedFrame);
    
    // Border
    [dropdown.borderColor set];
    NSFrameRect(expandedFrame);
    
    // Draw options
    [self drawDropdownOptions:dropdown];
}

- (void)drawDropdownOptions:(VLCDropdown *)dropdown {
    NSRect expandedFrame = [dropdown expandedFrame];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    [style setAlignment:NSTextAlignmentLeft];
    
    // Calculate visible item range
    NSInteger totalItems = [dropdown.items count];
    NSInteger visibleItemCount = MIN(totalItems - dropdown.scrollOffset, dropdown.maxVisibleOptions);
    
    // Draw only visible items
    for (NSInteger visibleIndex = 0; visibleIndex < visibleItemCount; visibleIndex++) {
        NSInteger actualIndex = dropdown.scrollOffset + visibleIndex;
        VLCDropdownItem *item = [dropdown.items objectAtIndex:actualIndex];
        
        // Calculate position for this visible item (from top to bottom)
        NSRect optionRect = NSMakeRect(expandedFrame.origin.x,
                                      expandedFrame.origin.y + expandedFrame.size.height - (visibleIndex + 1) * dropdown.optionHeight,
                                      expandedFrame.size.width,
                                      dropdown.optionHeight);
        
        // Determine colors
        NSColor *bgColor = nil;
        NSColor *textColor = dropdown.textColor;
        
        if (actualIndex == dropdown.selectedIndex && actualIndex == dropdown.hoveredIndex) {
            // Both selected and hovered
            bgColor = [NSColor colorWithCalibratedRed:0.4 green:0.6 blue:0.9 alpha:0.9];
            textColor = [NSColor whiteColor];
        } else if (actualIndex == dropdown.selectedIndex) {
            // Selected but not hovered
            bgColor = dropdown.selectedColor;
            textColor = [NSColor whiteColor];
        } else if (actualIndex == dropdown.hoveredIndex) {
            // Hovered but not selected
            bgColor = dropdown.hoveredColor;
            textColor = [NSColor whiteColor];
        }
        
        // Fill background if needed
        if (bgColor) {
            [bgColor set];
            NSRectFill(optionRect);
        }
        
        // Draw text
        NSDictionary *attrs = @{
            NSFontAttributeName: dropdown.font,
            NSForegroundColorAttributeName: textColor,
            NSParagraphStyleAttributeName: style
        };
        
        NSRect textRect = NSMakeRect(optionRect.origin.x + 10,
                                    optionRect.origin.y + (dropdown.optionHeight - 16) / 2,
                                    optionRect.size.width - 20,
                                    16);
        [item.displayText drawInRect:textRect withAttributes:attrs];
    }
    
    // Draw scroll indicators if needed
    if (totalItems > dropdown.maxVisibleOptions) {
        // Top scroll indicator (if can scroll up)
        if (dropdown.scrollOffset > 0) {
            NSRect topIndicator = NSMakeRect(expandedFrame.origin.x + expandedFrame.size.width - 15,
                                           expandedFrame.origin.y + expandedFrame.size.height - 10,
                                           10, 5);
            [[NSColor lightGrayColor] set];
            NSBezierPath *upArrow = [NSBezierPath bezierPath];
            [upArrow moveToPoint:NSMakePoint(topIndicator.origin.x, topIndicator.origin.y)];
            [upArrow lineToPoint:NSMakePoint(topIndicator.origin.x + 5, topIndicator.origin.y + 5)];
            [upArrow lineToPoint:NSMakePoint(topIndicator.origin.x + 10, topIndicator.origin.y)];
            [upArrow stroke];
        }
        
        // Bottom scroll indicator (if can scroll down)
        if (dropdown.scrollOffset < [dropdown maxScrollOffset]) {
            NSRect bottomIndicator = NSMakeRect(expandedFrame.origin.x + expandedFrame.size.width - 15,
                                              expandedFrame.origin.y + 5,
                                              10, 5);
            [[NSColor lightGrayColor] set];
            NSBezierPath *downArrow = [NSBezierPath bezierPath];
            [downArrow moveToPoint:NSMakePoint(bottomIndicator.origin.x, bottomIndicator.origin.y + 5)];
            [downArrow lineToPoint:NSMakePoint(bottomIndicator.origin.x + 5, bottomIndicator.origin.y)];
            [downArrow lineToPoint:NSMakePoint(bottomIndicator.origin.x + 10, bottomIndicator.origin.y + 5)];
            [downArrow stroke];
        }
    }
    
    [style release];
}

#pragma mark - Mouse Events

- (BOOL)handleMouseDown:(NSEvent *)event {
    NSPoint point = [self.parentView convertPoint:[event locationInWindow] fromView:nil];
    VLCDropdown *dropdown = [self dropdownAtPoint:point];
    
    if (dropdown) {
        NSInteger optionIndex = [self optionIndexAtPoint:point inDropdown:dropdown];
        
        if (optionIndex >= 0) {
            // Option selected
            dropdown.selectedIndex = optionIndex;
            VLCDropdownItem *selectedItem = [dropdown itemAtIndex:optionIndex];
            
            if (dropdown.onSelectionChanged) {
                dropdown.onSelectionChanged(dropdown, selectedItem, optionIndex);
            }
        }
        
        // Close dropdown after selection
        [self hideDropdown:dropdown.identifier];
        return YES;
    }
    
    // Click outside any dropdown - close all
    [self hideAllDropdowns];
    return NO;
}

- (BOOL)handleMouseMoved:(NSEvent *)event {
    NSPoint point = [self.parentView convertPoint:[event locationInWindow] fromView:nil];
    self.lastMousePosition = point;
    
    BOOL handledHover = NO;
    
    for (VLCDropdown *dropdown in [self.activeDropdowns allValues]) {
        if (!dropdown.isOpen) continue;
        
        NSInteger oldHoveredIndex = dropdown.hoveredIndex;
        NSInteger newHoveredIndex = -1;
        
        if ([self isPoint:point inDropdown:dropdown]) {
            newHoveredIndex = [self optionIndexAtPoint:point inDropdown:dropdown];
            handledHover = YES;
        }
        
        if (oldHoveredIndex != newHoveredIndex) {
            dropdown.hoveredIndex = newHoveredIndex;
            
            VLCDropdownItem *hoveredItem = nil;
            if (newHoveredIndex >= 0) {
                hoveredItem = [dropdown itemAtIndex:newHoveredIndex];
            }
            
            if (dropdown.onHoverChanged) {
                dropdown.onHoverChanged(dropdown, hoveredItem, newHoveredIndex);
            }
            
            [self.parentView setNeedsDisplay:YES];
        }
    }
    
    return handledHover;
}

- (void)handleMouseExited:(NSEvent *)event {
    // Start a timer to check if mouse has truly left all dropdown areas
    [self performSelector:@selector(checkMouseLeaveAfterDelay) withObject:nil afterDelay:0.1];
}

- (void)checkMouseLeaveAfterDelay {
    // Check if mouse is outside all dropdown areas
    for (VLCDropdown *dropdown in [self.activeDropdowns allValues]) {
        if (dropdown.isOpen && dropdown.autoCloseOnMouseLeave) {
            if (![self isPoint:self.lastMousePosition inDropdown:dropdown]) {
                [self hideDropdown:dropdown.identifier];
            }
        }
    }
}

#pragma mark - Mouse Tracking

- (void)startMouseTracking {
    if (!self.mouseTrackingTimer) {
        self.mouseTrackingTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                                   target:self
                                                                 selector:@selector(trackMouse:)
                                                                 userInfo:nil
                                                                  repeats:YES];
    }
}

- (void)stopMouseTracking {
    if (self.mouseTrackingTimer) {
        [self.mouseTrackingTimer invalidate];
        self.mouseTrackingTimer = nil;
    }
}

- (void)checkIfShouldStopMouseTracking {
    BOOL hasOpenDropdowns = NO;
    for (VLCDropdown *dropdown in [self.activeDropdowns allValues]) {
        if (dropdown.isOpen) {
            hasOpenDropdowns = YES;
            break;
        }
    }
    
    if (!hasOpenDropdowns) {
        [self stopMouseTracking];
    }
}

- (void)trackMouse:(NSTimer *)timer {
    NSPoint currentMouseLocation = [NSEvent mouseLocation];
    NSPoint viewMouseLocation = [self.parentView.window convertPointFromScreen:currentMouseLocation];
    viewMouseLocation = [self.parentView convertPoint:viewMouseLocation fromView:nil];
    
    if (!NSEqualPoints(self.lastMousePosition, viewMouseLocation)) {
        self.lastMousePosition = viewMouseLocation;
        
        // Check if mouse is outside all dropdown areas
        BOOL mouseInAnyDropdown = NO;
        for (VLCDropdown *dropdown in [self.activeDropdowns allValues]) {
            if (dropdown.isOpen && [self isPoint:viewMouseLocation inDropdown:dropdown]) {
                mouseInAnyDropdown = YES;
                break;
            }
        }
        
        if (!mouseInAnyDropdown) {
            // Mouse has left all dropdown areas - close them if autoClose is enabled
            for (VLCDropdown *dropdown in [self.activeDropdowns allValues]) {
                if (dropdown.isOpen && dropdown.autoCloseOnMouseLeave) {
                    [self hideDropdown:dropdown.identifier];
                }
            }
        }
    }
}

#pragma mark - Utility Methods

- (VLCDropdown *)dropdownAtPoint:(NSPoint)point {
    for (VLCDropdown *dropdown in [self.activeDropdowns allValues]) {
        if (dropdown.isOpen && [self isPoint:point inDropdown:dropdown]) {
            return dropdown;
        }
    }
    return nil;
}

- (BOOL)isPointInAnyDropdown:(NSPoint)point {
    return [self dropdownAtPoint:point] != nil;
}

- (BOOL)isPoint:(NSPoint)point inDropdown:(VLCDropdown *)dropdown {
    if (!dropdown.isOpen) return NO;
    
    // Check both button area and expanded area
    NSRect buttonRect = dropdown.frame;
    NSRect expandedRect = [dropdown expandedFrame];
    
    return NSPointInRect(point, buttonRect) || NSPointInRect(point, expandedRect);
}

- (NSInteger)optionIndexAtPoint:(NSPoint)point inDropdown:(VLCDropdown *)dropdown {
    NSRect expandedFrame = [dropdown expandedFrame];
    
    if (!NSPointInRect(point, expandedFrame)) {
        return -1;
    }
    
    // Calculate which visible item was clicked
    CGFloat relativeY = point.y - expandedFrame.origin.y;
    NSInteger visibleIndex = (NSInteger)((expandedFrame.size.height - relativeY) / dropdown.optionHeight);
    
    // Convert visible index to actual item index by adding scroll offset
    NSInteger actualIndex = dropdown.scrollOffset + visibleIndex;
    
    // Validate against actual item count
    if (actualIndex >= 0 && actualIndex < [dropdown.items count]) {
        return actualIndex;
    }
    
    return -1;
}

// Add mouse wheel scrolling support
- (BOOL)handleScrollWheel:(NSEvent *)event {
    NSPoint point = [self.parentView convertPoint:[event locationInWindow] fromView:nil];
    VLCDropdown *dropdown = [self dropdownAtPoint:point];
    
    if (dropdown && dropdown.isOpen) {
        // Scroll the dropdown
        CGFloat deltaY = [event deltaY];
        if (deltaY > 0) {
            [dropdown scrollUp];
        } else if (deltaY < 0) {
            [dropdown scrollDown];
        }
        
        [self.parentView setNeedsDisplay:YES];
        return YES;
    }
    
    return NO;
}

@end 