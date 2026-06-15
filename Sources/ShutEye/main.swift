import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory = 菜单栏代理应用,无 Dock 图标(等价于 Info.plist 的 LSUIElement)
app.setActivationPolicy(.accessory)
app.run()
