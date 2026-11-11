import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Dock にもアプリスイッチャーにも出さない常駐アプリとして動かす
app.setActivationPolicy(.accessory)
app.run()
