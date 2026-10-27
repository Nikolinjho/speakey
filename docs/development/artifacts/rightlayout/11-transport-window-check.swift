import AppKit
final class FixtureApplication: NSApplication {}
let app = FixtureApplication.shared
app.setActivationPolicy(.prohibited)
app.finishLaunching()
let window = NSWindow(contentRect: NSRect(x:0,y:0,width:320,height:80), styleMask:.borderless, backing:.buffered, defer:false)
window.isReleasedWhenClosed = false
let field = NSTextView(frame:window.contentView!.bounds)
window.contentView=field
print("responder",window.makeFirstResponder(field))
field.string="ghbdtn"
field.setSelectedRange(NSRange(location:6,length:0))
let source = CGEventSource(stateID:.privateState)
for key:CGKeyCode in [51,51,51,51,51,51,0] {
 let event = CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:true)!
 event.flags=[]
 if key == 0 { let units = Array("привет".utf16); units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength:$0.count,unicodeString:$0.baseAddress) } }
 let original=NSEvent(cgEvent:event)!
 let native=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:original.modifierFlags,timestamp:original.timestamp,windowNumber:window.windowNumber,context:nil,characters:original.characters ?? "",charactersIgnoringModifiers:original.charactersIgnoringModifiers ?? "",isARepeat:false,keyCode:original.keyCode)!
 print("event",key,String(reflecting:native.characters),native.windowNumber)
 field.keyDown(with:native)
 print("field",String(reflecting:field.string),field.selectedRange())
}
