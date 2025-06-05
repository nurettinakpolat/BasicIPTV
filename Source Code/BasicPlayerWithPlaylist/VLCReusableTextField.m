#import "VLCReusableTextField.h"

@interface VLCReusableTextField ()
@property (nonatomic, retain) NSString *originalValue;
@end

@implementation VLCReusableTextField

@synthesize textFieldDelegate;
@synthesize identifier = _identifier;
@synthesize isActive;
@synthesize originalValue = _originalValue;

- (instancetype)initWithFrame:(NSRect)frame identifier:(NSString *)identifier {
    self = [super initWithFrame:frame];
    if (self) {
        self.identifier = identifier;
        self.isActive = NO;
        
        // Configure the text field appearance
        [self setBordered:YES];
        [self setBezeled:YES];
        [self setBezelStyle:NSTextFieldSquareBezel];
        [self setEditable:YES];
        [self setSelectable:YES];
        [self setFont:[NSFont systemFontOfSize:14]];
        
        // Set colors
        [self setBackgroundColor:[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0]];
        [self setTextColor:[NSColor whiteColor]];
        
        // Set up target-action for text changes
        [self setTarget:self];
        [self setAction:@selector(textDidChange:)];
        
        // Set up delegate for editing events
        [self setDelegate:self];
    }
    return self;
}

- (void)dealloc {
    [_identifier release];
    [_originalValue release];
    [super dealloc];
}

- (void)setPlaceholderText:(NSString *)placeholder {
    NSAttributedString *placeholderAttr = [[NSAttributedString alloc] 
        initWithString:placeholder 
        attributes:@{
            NSForegroundColorAttributeName: [NSColor grayColor],
            NSFontAttributeName: [NSFont systemFontOfSize:14]
        }];
    [self setPlaceholderAttributedString:placeholderAttr];
    [placeholderAttr release];
}

- (void)setTextValue:(NSString *)text {
    // Don't update the text value if the field is currently being edited
    if (self.isActive) {
        //NSLog(@"setTextValue called while field is active - ignoring to prevent interference with editing");
        return;
    }
    
    [self setStringValue:text ? text : @""];
    self.originalValue = text ? text : @"";
}

- (void)activateField {
    //NSLog(@"Activating text field: %@ with current value: '%@'", self.identifier, [self stringValue]);
    
    // Store the original value before editing starts
    self.originalValue = [self stringValue];
    self.isActive = YES;
    
    // Update appearance for active state
    [self setBackgroundColor:[NSColor colorWithCalibratedRed:0.2 green:0.3 blue:0.4 alpha:1.0]];
    
    // Make first responder and select all text
    if ([[self window] makeFirstResponder:self]) {
        // Start editing with field editor
        NSText *fieldEditor = [[self window] fieldEditor:YES forObject:self];
        if (fieldEditor) {
            [fieldEditor setString:[self stringValue]];
            [fieldEditor selectAll:self];
        }
    }
    
    // Notify delegate
    if (self.textFieldDelegate && [self.textFieldDelegate respondsToSelector:@selector(textFieldDidBeginEditing:)]) {
        [self.textFieldDelegate textFieldDidBeginEditing:self.identifier];
    }
}

- (void)deactivateField {
    //NSLog(@"VLCReusableTextField deactivateField called for identifier: %@", self.identifier);
    self.isActive = NO;
    
    // Update appearance for inactive state
    [self setBackgroundColor:[NSColor colorWithCalibratedRed:0.1 green:0.1 blue:0.1 alpha:1.0]];
    
    // Resign first responder
    [[self window] makeFirstResponder:nil];
    
    // Notify delegate of final value
    if (self.textFieldDelegate && [self.textFieldDelegate respondsToSelector:@selector(textFieldDidEndEditing:forIdentifier:)]) {
        [self.textFieldDelegate textFieldDidEndEditing:[self stringValue] forIdentifier:self.identifier];
    }
}

- (void)textDidChange:(id)sender {
    // Notify delegate of text changes
    if (self.textFieldDelegate && [self.textFieldDelegate respondsToSelector:@selector(textFieldDidChange:forIdentifier:)]) {
        [self.textFieldDelegate textFieldDidChange:[self stringValue] forIdentifier:self.identifier];
    }
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification *)notification {
    // Also handle text changes through delegate
    [self textDidChange:self];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    [self deactivateField];
}

#pragma mark - Key Handling

- (void)keyDown:(NSEvent *)event {
    unichar key = [[event charactersIgnoringModifiers] characterAtIndex:0];
    
    if (key == 13) { // Enter
        //NSLog(@"Enter key pressed in text field: %@", self.identifier);
        [self deactivateField];
    } else if (key == 27) { // Escape
        // Restore original value and deactivate
        [self setStringValue:self.originalValue];
        [self deactivateField];
    } else {
        // Handle copy/paste and other standard key commands
        [super keyDown:event];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Handle Cmd+C, Cmd+V, Cmd+X, etc.
    if ([event modifierFlags] & NSEventModifierFlagCommand) {
        NSString *characters = [event charactersIgnoringModifiers];
        if ([characters isEqualToString:@"c"]) {
            [self copy:nil];
            return YES;
        } else if ([characters isEqualToString:@"v"]) {
            [self paste:nil];
            return YES;
        } else if ([characters isEqualToString:@"x"]) {
            [self cut:nil];
            return YES;
        } else if ([characters isEqualToString:@"a"]) {
            [self selectAll:nil];
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
    return [super resignFirstResponder];
}

#pragma mark - Copy/Paste Support

- (void)copy:(id)sender {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    
    NSString *selectedText = nil;
    NSText *fieldEditor = [[self window] fieldEditor:YES forObject:self];
    if (fieldEditor && [fieldEditor selectedRange].length > 0) {
        selectedText = [[fieldEditor string] substringWithRange:[fieldEditor selectedRange]];
    } else {
        // If no selection, copy the entire text
        selectedText = [self stringValue];
    }
    
    if (selectedText && [selectedText length] > 0) {
        [pasteboard setString:selectedText forType:NSPasteboardTypeString];
        //NSLog(@"Copied text: %@", selectedText);
    }
}

- (void)cut:(id)sender {
    [self copy:sender];
    
    NSText *fieldEditor = [[self window] fieldEditor:YES forObject:self];
    if (fieldEditor && [fieldEditor selectedRange].length > 0) {
        [fieldEditor delete:sender];
    } else {
        // If no selection, clear the entire field
        [self setStringValue:@""];
    }
    
    // Notify delegate of the change
    if (self.textFieldDelegate && [self.textFieldDelegate respondsToSelector:@selector(textFieldDidChange:forIdentifier:)]) {
        [self.textFieldDelegate textFieldDidChange:[self stringValue] forIdentifier:self.identifier];
    }
}

- (void)paste:(id)sender {
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSString *pastedText = [pasteboard stringForType:NSPasteboardTypeString];
    
    if (pastedText) {
        NSText *fieldEditor = [[self window] fieldEditor:YES forObject:self];
        if (fieldEditor) {
            [fieldEditor insertText:pastedText];
        } else {
            // Fallback: replace entire content
            [self setStringValue:pastedText];
        }
        
        //NSLog(@"Pasted text: %@", pastedText);
        
        // Notify delegate of the change
        if (self.textFieldDelegate && [self.textFieldDelegate respondsToSelector:@selector(textFieldDidChange:forIdentifier:)]) {
            [self.textFieldDelegate textFieldDidChange:[self stringValue] forIdentifier:self.identifier];
        }
    }
}

- (void)selectAll:(id)sender {
    NSText *fieldEditor = [[self window] fieldEditor:YES forObject:self];
    if (fieldEditor) {
        [fieldEditor selectAll:sender];
    } else {
        [super selectText:sender];
    }
}

@end 