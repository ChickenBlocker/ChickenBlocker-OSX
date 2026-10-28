import Foundation
import AppKit
import ApplicationServices

func runAppleScript(_ source: String) -> String? {
    var error: NSDictionary?
    let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
    return output?.stringValue
}

func axString(_ elem: AXUIElement, _ attr: CFString) -> String {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(elem, attr, &ref) == .success,
          let value = ref as? String else { return "" }
    return value
}

func axChildren(_ elem: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &ref) == .success,
          let children = ref as? [AXUIElement] else { return [] }
    return children
}

func dumpElement(_ elem: AXUIElement, depth: Int, out: inout [String]) {
    guard depth <= 12, out.count < 1200 else { return }
    let role = axString(elem, kAXRoleAttribute as CFString)
    let title = axString(elem, kAXTitleAttribute as CFString)
    let value = axString(elem, kAXValueAttribute as CFString)
    let description = axString(elem, kAXDescriptionAttribute as CFString)
    let identifier = axString(elem, "AXIdentifier" as CFString)
    let help = axString(elem, "AXHelp" as CFString)
    let enabled = axString(elem, kAXEnabledAttribute as CFString)
    let button = role == (kAXButtonRole as String) ? "button" : ""
    if !title.isEmpty || !value.isEmpty || !description.isEmpty ||
        !identifier.isEmpty || !help.isEmpty || role == "AXSheet" || role == "AXWindow" || !button.isEmpty {
        out.append(String(repeating: " ", count: depth * 2) +
                   "\(role) \(button) title='\(title)' desc='\(description)' id='\(identifier)' help='\(help)' enabled=\(enabled.isEmpty ? "?" : enabled) value='\(value.prefix(80))'")
    }
    for child in axChildren(elem).prefix(40) {
        dumpElement(child, depth: depth + 1, out: &out)
    }
}

func appendLine(_ line: String, to path: String) {
    let handle = FileHandle(forWritingAtPath: path)
    handle?.seekToEndOfFile()
    handle?.write(Data((line + "\n").utf8))
    handle?.closeFile()
}

func collectTexts(_ elem: AXUIElement, depth: Int, out: inout [String]) {
    guard depth <= 16, out.count < 200 else { return }
    if axString(elem, kAXRoleAttribute as CFString) == kAXStaticTextRole {
        let value = axString(elem, kAXValueAttribute as CFString)
        if !value.isEmpty {
            out.append(value)
        }
    }
    for child in axChildren(elem).prefix(40) {
        collectTexts(child, depth: depth + 1, out: &out)
    }
}

func settingsSheet() -> AXUIElement? {
    for app in NSWorkspace.shared.runningApplications
    where app.bundleIdentifier == "com.apple.systempreferences" {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
              let windows = winRef as? [AXUIElement] else { continue }
        for window in windows {
            for child in axChildren(window) where axString(child, kAXRoleAttribute as CFString) == "AXSheet" {
                return child
            }
        }
    }
    return nil
}

func findButton(_ elem: AXUIElement, title: String, depth: Int = 0) -> AXUIElement? {
    guard depth <= 10 else { return nil }
    if axString(elem, kAXRoleAttribute as CFString) == (kAXButtonRole as String) {
        let elementTitle = axString(elem, kAXTitleAttribute as CFString)
        let description = axString(elem, kAXDescriptionAttribute as CFString)
        if elementTitle == title || description == title {
            return elem
        }
    }
    for child in axChildren(elem).prefix(40) {
        if let button = findButton(child, title: title, depth: depth + 1) {
            return button
        }
    }
    return nil
}

func focusedElement(_ app: NSRunningApplication) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
          let ref else { return nil }
    return (ref as! AXUIElement)
}

func postEvent(_ event: CGEvent?, pid: pid_t?) {
    guard let event else { return }
    if let pid {
        event.postToPid(pid)
    } else {
        event.post(tap: .cghidEventTap)
    }
}

func postKey(_ code: CGKeyCode, flags: CGEventFlags = [], pid: pid_t? = nil) {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    down?.flags = flags
    up?.flags = flags
    postEvent(down, pid: pid)
    postEvent(up, pid: pid)
}

func postText(_ text: String, pid: pid_t? = nil) {
    var chars = Array(text.utf16)
    for index in chars.indices {
        var char = chars[index]
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &char)
        up?.keyboardSetUnicodeString(stringLength: 0, unicodeString: nil)
        postEvent(down, pid: pid)
        postEvent(up, pid: pid)
        Thread.sleep(forTimeInterval: 0.025)
    }
    chars.withUnsafeMutableBufferPointer { buffer in
        buffer.initialize(repeating: 0)
    }
}

func focusRole(_ app: NSRunningApplication) -> String {
    guard let element = focusedElement(app) else { return "" }
    return axString(element, kAXRoleAttribute as CFString)
}

func focusSubrole(_ app: NSRunningApplication) -> String {
    guard let element = focusedElement(app) else { return "" }
    return axString(element, kAXSubroleAttribute as CFString)
}

func writeResult(_ text: String, to path: String) {
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
}

func installedProfilesContain(uuid: String, marker: String) -> Bool {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPConfigurationProfileDataType", "-json"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return false }
        return output.contains(uuid) && output.contains(marker)
    } catch {
        return false
    }
}

func collectButtonTitles(_ elem: AXUIElement, depth: Int, out: inout [String]) {
    guard depth <= 6, out.count < 50 else { return }
    if axString(elem, kAXRoleAttribute as CFString) == (kAXButtonRole as String) {
        let title = axString(elem, kAXTitleAttribute as CFString)
        let description = axString(elem, kAXDescriptionAttribute as CFString)
        let label = title.isEmpty ? description : title
        if !label.isEmpty {
            out.append(label)
        }
    }
    for child in axChildren(elem).prefix(40) {
        collectButtonTitles(child, depth: depth + 1, out: &out)
    }
}

func securityAgents() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == "com.apple.SecurityAgent" && !$0.isTerminated
    }
}

func containsText(_ elem: AXUIElement, text: String, depth: Int = 0) -> Bool {
    guard depth <= 16 else { return false }
    for attribute in [kAXTitleAttribute as CFString, kAXValueAttribute as CFString,
                      kAXDescriptionAttribute as CFString] {
        if axString(elem, attribute).localizedCaseInsensitiveContains(text) { return true }
    }
    return axChildren(elem).prefix(40).contains {
        containsText($0, text: text, depth: depth + 1)
    }
}

func dismissProfileStatusPopup() -> String? {
    for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        var roots: [AXUIElement] = []
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
           let windows = winRef as? [AXUIElement] {
            roots = windows
        }
        if roots.isEmpty { roots = axChildren(axApp) }
        for root in roots where containsText(root, text: "Profile Downloaded") ||
                                  containsText(root, text: "Profile Installed") {
            if let ok = findButton(root, title: "OK"),
               AXUIElementPerformAction(ok, kAXPressAction as CFString) == .success {
                return "\(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "unknown"))"
            }
        }
    }
    return nil
}

func hasVisibleWindow(pid: pid_t) -> Bool {
    guard let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return false }
    for window in windows {
        let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
        guard ownerPID == pid, alpha > 0,
              let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              bounds.width > 200, bounds.height > 100 else { continue }
        return true
    }
    return false
}

func securityAgentSnapshot(_ apps: [NSRunningApplication]) -> String {
    var parts: [String] = []
    for app in apps {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
              let windows = winRef as? [AXUIElement] else {
            parts.append("SecurityAgent windows=inaccessible")
            continue
        }
        var texts: [String] = []
        var buttons: [String] = []
        for window in windows {
            collectTexts(window, depth: 0, out: &texts)
            collectButtonTitles(window, depth: 0, out: &buttons)
        }
        if texts.isEmpty && buttons.isEmpty {
            parts.append("SecurityAgent secure-input=opaque")
            continue
        }
        let safeTexts = texts.prefix(4).map { String($0.prefix(120)) }.joined(separator: " | ")
        parts.append("SecurityAgent texts=[\(safeTexts)] buttons=[\(buttons.joined(separator: ","))]")
    }
    return parts.joined(separator: "; ")
}

func disableRemovalControls(_ elem: AXUIElement, depth: Int, out: inout [String]) {
    guard depth <= 7, out.count < 100 else { return }
    let role = axString(elem, kAXRoleAttribute as CFString)
    if role == "AXSheet" {
        return
    }
    if role == (kAXButtonRole as String) {
        let title = axString(elem, kAXTitleAttribute as CFString).lowercased()
        let description = axString(elem, kAXDescriptionAttribute as CFString).lowercased()
        if title.contains("remove") || description.contains("remove") {
            let label = description.isEmpty ? title : description
            if AXUIElementSetAttributeValue(elem, kAXEnabledAttribute as CFString, kCFBooleanFalse) == .success {
                out.append("locked:\(label)")
            } else {
                out.append("lock-failed:\(label)")
            }
        }
    }
    for child in axChildren(elem).prefix(40) {
        disableRemovalControls(child, depth: depth + 1, out: &out)
    }
}

func settingsWindows() -> [AXUIElement] {
    for app in NSWorkspace.shared.runningApplications
    where app.bundleIdentifier == "com.apple.systempreferences" {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
           let windows = winRef as? [AXUIElement] {
            return windows
        }
    }
    return []
}

func settingsApplication() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == "com.apple.systempreferences" && !$0.isTerminated
    }
}

func settingsButton(titles: [String]) -> AXUIElement? {
    for window in settingsWindows() {
        for title in titles {
            if let button = findButton(window, title: title) {
                return button
            }
        }
    }
    return nil
}

func settingsContains(_ expected: [String]) -> Bool {
    var texts: [String] = []
    for window in settingsWindows() {
        collectTexts(window, depth: 0, out: &texts)
    }
    return expected.allSatisfy { needle in
        texts.contains { $0.contains(needle) }
    }
}

func downloadedProfileContainer(_ elem: AXUIElement, name: String, depth: Int = 0) -> AXUIElement? {
    guard depth <= 16 else { return nil }
    var texts: [String] = []
    collectTexts(elem, depth: 0, out: &texts)
    guard texts.contains(where: { $0 == name }),
          texts.contains(where: { $0.contains("Profile not installed") }) else { return nil }
    for child in axChildren(elem).prefix(40) {
        if let match = downloadedProfileContainer(child, name: name, depth: depth + 1) {
            return match
        }
    }
    return elem
}

func downloadedProfileContainer(name: String) -> AXUIElement? {
    for window in settingsWindows() {
        if let match = downloadedProfileContainer(window, name: name) {
            return match
        }
    }
    return nil
}

func findStaticText(_ elem: AXUIElement, value: String, depth: Int = 0) -> AXUIElement? {
    guard depth <= 16 else { return nil }
    if axString(elem, kAXRoleAttribute as CFString) == (kAXStaticTextRole as String),
       axString(elem, kAXValueAttribute as CFString) == value {
        return elem
    }
    for child in axChildren(elem).prefix(40) {
        if let match = findStaticText(child, value: value, depth: depth + 1) {
            return match
        }
    }
    return nil
}

func elementFrame(_ elem: AXUIElement) -> CGRect? {
    var positionRef: CFTypeRef?
    var sizeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(elem, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(elem, kAXSizeAttribute as CFString, &sizeRef) == .success,
          let positionRef, let sizeRef,
          CFGetTypeID(positionRef) == AXValueGetTypeID(),
          CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
    let positionValue = positionRef as! AXValue
    let sizeValue = sizeRef as! AXValue
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &position),
          AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
    return CGRect(origin: position, size: size)
}

func debugElement(_ elem: AXUIElement, label: String) -> String {
    var attributeNames: CFArray?
    var actionNames: CFArray?
    AXUIElementCopyAttributeNames(elem, &attributeNames)
    AXUIElementCopyActionNames(elem, &actionNames)
    let attributes = (attributeNames as? [String] ?? []).joined(separator: ",")
    let actions = (actionNames as? [String] ?? []).joined(separator: ",")
    let frame = elementFrame(elem).map {
        "x=\(Int($0.origin.x)) y=\(Int($0.origin.y)) w=\(Int($0.width)) h=\(Int($0.height))"
    } ?? "unavailable"
    let identifier = axString(elem, "AXIdentifier" as CFString)
    return "\(label) role='\(axString(elem, kAXRoleAttribute as CFString))' subrole='\(axString(elem, kAXSubroleAttribute as CFString))' title='\(axString(elem, kAXTitleAttribute as CFString))' value='\(axString(elem, kAXValueAttribute as CFString))' desc='\(axString(elem, kAXDescriptionAttribute as CFString))' id='\(identifier)' frame=[\(frame)] attributes=[\(attributes)] actions=[\(actions)]"
}

func parentElement(_ elem: AXUIElement) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(elem, kAXParentAttribute as CFString, &ref) == .success,
          let ref else { return nil }
    return (ref as! AXUIElement)
}

func focusAndRaise(_ elem: AXUIElement) {
    _ = AXUIElementSetAttributeValue(elem, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    var current = elem
    for _ in 0..<8 {
        guard let parent = parentElement(current) else { break }
        if axString(parent, kAXRoleAttribute as CFString) == (kAXWindowRole as String) {
            _ = AXUIElementPerformAction(parent, kAXRaiseAction as CFString)
            break
        }
        current = parent
    }
}

func click(_ elem: AXUIElement, count: Int) -> Bool {
    guard let frame = elementFrame(elem), frame.width > 0, frame.height > 0 else { return false }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    let source = CGEventSource(stateID: .hidSystemState)
    for clickNumber in 1...count {
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
        up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickNumber))
        postEvent(down, pid: nil)
        postEvent(up, pid: nil)
        Thread.sleep(forTimeInterval: 0.08)
    }
    return true
}

func settingsShowsRemovingProfile() -> Bool {
    for window in settingsWindows() {
        var texts: [String] = []
        collectTexts(window, depth: 0, out: &texts)
        if texts.contains(where: { $0.contains("Removing profile") }) {
            return true
        }
    }
    return false
}

let arguments = CommandLine.arguments

if arguments.count >= 6 && arguments[1] == "--start-profile-removal" {
    let resultPath = arguments[2]
    let logPath = arguments[3]
    let expectedProfileName = arguments[4]
    let expectedProfileID = arguments[5]
    guard let settings = settingsApplication() else {
        writeResult("removal_started=0 reason=System Settings is not running", to: resultPath)
        exit(13)
    }
    settings.activate(options: [])
    var profileText: AXUIElement?
    let rowDeadline = Date().addingTimeInterval(20)
    while Date() < rowDeadline && profileText == nil {
        for window in settingsWindows() {
            if let match = findStaticText(window, value: expectedProfileName) {
                profileText = match
                break
            }
        }
        if profileText == nil { Thread.sleep(forTimeInterval: 0.2) }
    }
    guard let profileText, click(profileText, count: 1) else {
        writeResult("removal_started=0 reason=installed profile row not found", to: resultPath)
        exit(13)
    }
    Thread.sleep(forTimeInterval: 0.5)
    guard let remove = settingsButton(titles: ["Remove selected profiles"]),
          AXUIElementPerformAction(remove, kAXPressAction as CFString) == .success else {
        writeResult("removal_started=0 reason=remove control could not be pressed", to: resultPath)
        exit(13)
    }
    let confirmationDeadline = Date().addingTimeInterval(20)
    var confirmed = false
    while Date() < confirmationDeadline && !confirmed {
        if let sheet = settingsSheet() {
            var texts: [String] = []
            collectTexts(sheet, depth: 0, out: &texts)
            let expected = texts.contains { $0.contains(expectedProfileName) } ||
                texts.contains { $0.contains(expectedProfileID) }
            if expected, let action = findButton(sheet, title: "Remove") {
                confirmed = AXUIElementPerformAction(action, kAXPressAction as CFString) == .success
            }
        }
        if !confirmed { Thread.sleep(forTimeInterval: 0.2) }
    }
    guard confirmed else {
        writeResult("removal_started=0 reason=expected removal confirmation not found", to: resultPath)
        exit(13)
    }
    appendLine("started removal for expected profile name=\(expectedProfileName) id=\(expectedProfileID)", to: logPath)
    writeResult("removal_started=1", to: resultPath)
    exit(0)
}

if arguments.count >= 12 && arguments[1] == "--install-profile" {
    let profilePath = arguments[2]
    let fifoPath = arguments[3]
    let resultPath = arguments[4]
    let username = arguments[5]
    let logPath = arguments[6]
    let expectedProfileName = arguments[7]
    let expectedProfileID = arguments[8]
    let expectedVersion = arguments[9]
    let expectedUUID = arguments[10]
    let expectedPayloadMarker = arguments[11]
    let expectedContext = [expectedProfileName, expectedProfileID]

    guard profilePath.hasPrefix("/"), FileManager.default.isReadableFile(atPath: profilePath) else {
        writeResult("submitted=0 reason=profile path is not a readable absolute path", to: resultPath)
        exit(9)
    }
    guard let settings = settingsApplication() else {
        writeResult("submitted=0 reason=System Settings is not running", to: resultPath)
        exit(9)
    }
    settings.activate(options: [])

    if let stale = downloadedProfileContainer(name: expectedProfileName) {
        guard click(stale, count: 1),
              let remove = settingsButton(titles: ["Remove selected profiles"]),
              AXUIElementPerformAction(remove, kAXPressAction as CFString) == .success else {
            writeResult("submitted=0 reason=stale downloaded profile could not be removed", to: resultPath)
            exit(10)
        }
        Thread.sleep(forTimeInterval: 0.5)
        if let confirm = settingsButton(titles: ["Remove", "Delete"]) {
            _ = AXUIElementPerformAction(confirm, kAXPressAction as CFString)
        }
        appendLine("removed stale downloaded profile", to: logPath)
        Thread.sleep(forTimeInterval: 0.8)
    }

    NSWorkspace.shared.open(URL(fileURLWithPath: profilePath))
    let downloadDeadline = Date().addingTimeInterval(20)
    var downloaded: AXUIElement?
    while Date() < downloadDeadline && downloaded == nil {
        downloaded = downloadedProfileContainer(name: expectedProfileName)
        if downloaded == nil { Thread.sleep(forTimeInterval: 0.2) }
    }
    guard let downloaded, click(downloaded, count: 2) else {
        writeResult("submitted=0 reason=downloaded profile row not found or could not be opened", to: resultPath)
        exit(10)
    }
    appendLine("opened downloaded profile row for exact path: \(profilePath)", to: logPath)

    let deadline = Date().addingTimeInterval(120)
    var transactionArmed = false
    var actionPressed = false
    var pressedActionTitles: Set<String> = []
    var authorization = "not-shown-or-cached"
    var authorizationSubmitted = false
    var lastProfileCheck = Date.distantPast
    while Date() < deadline {
        if let owner = dismissProfileStatusPopup() {
            appendLine("dismissed profile status popup owner=\(owner)", to: logPath)
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !transactionArmed && settingsContains(expectedContext) {
            transactionArmed = true
            appendLine("armed expected profile name=\(expectedProfileName) id=\(expectedProfileID) version=\(expectedVersion)", to: logPath)
        }
        let actionTitles = [
            "Install…", "Install...", "Install",
            "Update…", "Update...", "Update",
            "Replace…", "Replace...", "Replace"
        ]
        var pendingAction: (String, AXUIElement)?
        if transactionArmed {
            for title in actionTitles where !pressedActionTitles.contains(title) {
                if let button = settingsButton(titles: [title]) {
                    pendingAction = (title, button)
                    break
                }
            }
        }
        if let (title, action) = pendingAction {
            if AXUIElementPerformAction(action, kAXPressAction as CFString) == .success {
                actionPressed = true
                pressedActionTitles.insert(title)
                appendLine("submitted profile action: \(title)", to: logPath)
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        if transactionArmed, !authorizationSubmitted, let securityAgent = securityAgents().first,
           securityAgent.bundleURL?.path.hasPrefix("/System/Library/") == true {
            let snapshot = securityAgentSnapshot([securityAgent])
            let verifiedPrompt = snapshot.contains("Device Management") && snapshot.contains("Allow Access")
            guard verifiedPrompt || hasVisibleWindow(pid: securityAgent.processIdentifier) else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            authorization = "submitted"
            authorizationSubmitted = true
            appendLine("verified optional SecurityAgent prompt: \(snapshot)", to: logPath)
            guard let fifo = FileHandle(forReadingAtPath: fifoPath) else {
                writeResult("submitted=0 reason=credential pipe could not be opened", to: resultPath)
                exit(11)
            }
            var secretData = fifo.readDataToEndOfFile()
            try? fifo.close()
            while secretData.last == 10 || secretData.last == 13 { secretData.removeLast() }
            guard !secretData.isEmpty, let secret = String(data: secretData, encoding: .utf8) else {
                secretData.resetBytes(in: 0..<secretData.count)
                writeResult("submitted=0 reason=authorization appeared but credential was empty", to: resultPath)
                exit(11)
            }
            if let owner = dismissProfileStatusPopup() {
                appendLine("dismissed profile status popup before input owner=\(owner)", to: logPath)
                Thread.sleep(forTimeInterval: 0.5)
            }
            securityAgent.activate(options: [])
            var visibleSamples = 0
            let settleDeadline = Date().addingTimeInterval(5)
            while Date() < settleDeadline && visibleSamples < 3 {
                if hasVisibleWindow(pid: securityAgent.processIdentifier) {
                    visibleSamples += 1
                } else {
                    visibleSamples = 0
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard visibleSamples >= 3 else {
                secretData.resetBytes(in: 0..<secretData.count)
                writeResult("submitted=0 reason=SecurityAgent window did not settle", to: resultPath)
                exit(11)
            }
            Thread.sleep(forTimeInterval: 0.5)
            let role = focusRole(securityAgent)
            let subrole = focusSubrole(securityAgent)
            appendLine("initial focused role=\(role.isEmpty ? "none" : role) subrole=\(subrole.isEmpty ? "none" : subrole)", to: logPath)
            guard role == (kAXTextFieldRole as String) || role == "AXSecureTextField" else {
                secretData.resetBytes(in: 0..<secretData.count)
                writeResult("submitted=0 reason=credential field was not focused", to: resultPath)
                exit(11)
            }

            if subrole != "AXSecureTextField" {
                appendLine("credential strategy=username then password", to: logPath)
                var usernameVerified = false
                for attempt in 1...3 {
                    guard let field = focusedElement(securityAgent) else { break }
                    focusAndRaise(field)
                    var valueSettable: DarwinBoolean = false
                    let settableResult = AXUIElementIsAttributeSettable(
                        field, kAXValueAttribute as CFString, &valueSettable
                    )
                    var directResult: AXError = .failure
                    if settableResult == .success && valueSettable.boolValue {
                        directResult = AXUIElementSetAttributeValue(
                            field, kAXValueAttribute as CFString, username as CFString
                        )
                    }
                    if directResult != .success {
                        _ = click(field, count: 1)
                    }
                    Thread.sleep(forTimeInterval: 0.3)
                    if directResult != .success {
                        postKey(0, flags: .maskCommand)
                        postText(username)
                    }
                    Thread.sleep(forTimeInterval: 0.4)
                    let actual = focusedElement(securityAgent).map {
                        axString($0, kAXValueAttribute as CFString)
                    } ?? ""
                    usernameVerified = actual == username
                    appendLine("username input attempt=\(attempt) direct=\(directResult.rawValue) settable=\(valueSettable.boolValue) verified=\(usernameVerified) value='\(actual)'", to: logPath)
                    if usernameVerified { break }
                }
                guard usernameVerified else {
                    secretData.resetBytes(in: 0..<secretData.count)
                    writeResult("submitted=0 reason=username input could not be verified", to: resultPath)
                    exit(11)
                }
                var passwordFocused = false
                for tab in 1...12 {
                    postKey(48)
                    Thread.sleep(forTimeInterval: 0.15)
                    if focusSubrole(securityAgent) == "AXSecureTextField" {
                        passwordFocused = true
                        appendLine("secure password field reached after tabs=\(tab)", to: logPath)
                        break
                    }
                }
                guard passwordFocused else {
                    secretData.resetBytes(in: 0..<secretData.count)
                    writeResult("submitted=0 reason=secure password field could not be focused", to: resultPath)
                    exit(11)
                }
                Thread.sleep(forTimeInterval: 0.5)
            } else {
                appendLine("credential strategy=remembered account password only", to: logPath)
            }

            let expectedSecretLength = secret.utf16.count
            var passwordVerified = false
            for attempt in 1...3 {
                guard focusedElement(securityAgent) != nil,
                      focusSubrole(securityAgent) == "AXSecureTextField" else { break }
                let passwordField = focusedElement(securityAgent)!
                var valueSettable: DarwinBoolean = false
                let settableResult = AXUIElementIsAttributeSettable(
                    passwordField, kAXValueAttribute as CFString, &valueSettable
                )
                var directResult: AXError = .failure
                if settableResult == .success && valueSettable.boolValue {
                    directResult = AXUIElementSetAttributeValue(
                        passwordField, kAXValueAttribute as CFString, secret as CFString
                    )
                }
                if directResult != .success {
                    postKey(0, flags: .maskCommand)
                    postText(secret)
                }
                Thread.sleep(forTimeInterval: 0.5)
                let enteredLength = focusedElement(securityAgent).map {
                    axString($0, kAXValueAttribute as CFString).utf16.count
                } ?? 0
                passwordVerified = enteredLength == expectedSecretLength
                appendLine("password input attempt=\(attempt) direct=\(directResult.rawValue) settable=\(valueSettable.boolValue) verified=\(passwordVerified) entered_length=\(enteredLength) expected_length=\(expectedSecretLength)", to: logPath)
                if passwordVerified { break }
            }
            guard passwordVerified else {
                secretData.resetBytes(in: 0..<secretData.count)
                writeResult("submitted=0 reason=password input could not be verified", to: resultPath)
                exit(11)
            }
            Thread.sleep(forTimeInterval: 0.5)
            let axApp = AXUIElementCreateApplication(securityAgent.processIdentifier)
            var winRef: CFTypeRef?
            var pressed = false
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
               let windows = winRef as? [AXUIElement] {
                for window in windows {
                    if let allow = findButton(window, title: "Allow Access") {
                        pressed = AXUIElementPerformAction(allow, kAXPressAction as CFString) == .success
                        if pressed { break }
                    }
                }
            }
            if !pressed { postKey(36) }
            appendLine("optional authorization submitted", to: logPath)
            secretData.resetBytes(in: 0..<secretData.count)
        }
        if actionPressed && Date().timeIntervalSince(lastProfileCheck) >= 2 {
            lastProfileCheck = Date()
            if installedProfilesContain(uuid: expectedUUID, marker: expectedPayloadMarker) {
                writeResult("submitted=1 authorization=\(authorization) expected_version=\(expectedVersion) expected_uuid=\(expectedUUID)", to: resultPath)
                exit(0)
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    writeResult("submitted=0 reason=profile transaction timed out armed=\(transactionArmed) action=\(actionPressed)", to: resultPath)
    exit(12)
}

if arguments.count >= 7 && arguments[1] == "--inject-auth" {
    let fifoPath = arguments[2]
    let resultPath = arguments[3]
    let username = arguments[4]
    let logPath = arguments[5]
    let expectedProfileName = arguments[6]
    appendLine("waiting for verified SecurityAgent", to: logPath)
    let deadline = Date().addingTimeInterval(120)
    var securityAgent: NSRunningApplication?
    var transactionArmed = false
    while Date() < deadline {
        if !transactionArmed, let sheet = settingsSheet() {
            var texts: [String] = []
            var buttons: [String] = []
            collectTexts(sheet, depth: 0, out: &texts)
            collectButtonTitles(sheet, depth: 0, out: &buttons)
            let expectedConfirmation = texts.contains { $0.contains(expectedProfileName) }
            let destructiveAction = buttons.contains {
                let label = $0.lowercased()
                return label.contains("remove") || label.contains("delete")
            }
            if expectedConfirmation && destructiveAction {
                transactionArmed = true
                appendLine("armed from expected removal confirmation: \(expectedProfileName)", to: logPath)
            }
        }
        if let app = securityAgents().first,
           app.bundleURL?.path.hasPrefix("/System/Library/") == true {
            let snapshot = securityAgentSnapshot([app])
            let promptVisible = snapshot.contains("Device Management") && snapshot.contains("Allow Access")
            let windowVisible = hasVisibleWindow(pid: app.processIdentifier)
            if windowVisible && (promptVisible || transactionArmed || settingsShowsRemovingProfile()) {
                securityAgent = app
                appendLine("verified SecurityAgent windowVisible=true promptVisible=\(promptVisible) transactionArmed=\(transactionArmed) settingsRemoving=\(settingsShowsRemovingProfile()) snapshot=\(snapshot)", to: logPath)
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard let securityAgent else {
        writeResult("submitted=0 reason=verified SecurityAgent prompt not found", to: resultPath)
        exit(4)
    }

    guard let fifo = FileHandle(forReadingAtPath: fifoPath) else {
        writeResult("submitted=0 reason=credential pipe could not be opened", to: resultPath)
        exit(5)
    }
    var secretData = fifo.readDataToEndOfFile()
    try? fifo.close()
    guard !secretData.isEmpty else {
        writeResult("submitted=0 reason=credential pipe was empty", to: resultPath)
        exit(5)
    }
    while secretData.last == 10 || secretData.last == 13 { secretData.removeLast() }
    guard let secret = String(data: secretData, encoding: .utf8) else {
        secretData.resetBytes(in: 0..<secretData.count)
        writeResult("submitted=0 reason=credential was not UTF-8", to: resultPath)
        exit(6)
    }
    appendLine("credential received through FIFO", to: logPath)

    securityAgent.activate(options: [])
    var visibleSamples = 0
    let visibilityDeadline = Date().addingTimeInterval(5)
    while Date() < visibilityDeadline && visibleSamples < 3 {
        if hasVisibleWindow(pid: securityAgent.processIdentifier) {
            visibleSamples += 1
        } else {
            visibleSamples = 0
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard visibleSamples >= 3 else {
        secretData.resetBytes(in: 0..<secretData.count)
        writeResult("submitted=0 reason=SecurityAgent window did not settle", to: resultPath)
        exit(7)
    }
    appendLine("SecurityAgent window settled", to: logPath)
    Thread.sleep(forTimeInterval: 0.5)
    let role = focusRole(securityAgent)
    let subrole = focusSubrole(securityAgent)
    appendLine("initial focused role=\(role.isEmpty ? "none" : role) subrole=\(subrole.isEmpty ? "none" : subrole)", to: logPath)
    guard role == (kAXTextFieldRole as String) || role == "AXSecureTextField" else {
        secretData.resetBytes(in: 0..<secretData.count)
        writeResult("submitted=0 reason=credential field was not focused", to: resultPath)
        exit(7)
    }
    if subrole != "AXSecureTextField" {
        guard let usernameField = focusedElement(securityAgent) else {
            secretData.resetBytes(in: 0..<secretData.count)
            writeResult("submitted=0 reason=username field was unavailable", to: resultPath)
            exit(7)
        }
        focusAndRaise(usernameField)
        guard
              AXUIElementSetAttributeValue(
                usernameField, kAXValueAttribute as CFString, username as CFString
              ) == .success,
              axString(usernameField, kAXValueAttribute as CFString) == username else {
            secretData.resetBytes(in: 0..<secretData.count)
            writeResult("submitted=0 reason=username input could not be verified", to: resultPath)
            exit(7)
        }
        appendLine("username value set and verified", to: logPath)
        postKey(48)
        Thread.sleep(forTimeInterval: 0.5)
    }
    guard focusSubrole(securityAgent) == "AXSecureTextField" else {
        secretData.resetBytes(in: 0..<secretData.count)
        writeResult("submitted=0 reason=secure password field could not be focused", to: resultPath)
        exit(7)
    }
    let expectedSecretLength = secret.utf16.count
    var passwordVerified = false
    for attempt in 1...3 {
        postKey(0, flags: .maskCommand)
        postText(secret)
        Thread.sleep(forTimeInterval: 0.6)
        let enteredLength = focusedElement(securityAgent).map {
            axString($0, kAXValueAttribute as CFString).utf16.count
        } ?? 0
        passwordVerified = enteredLength == expectedSecretLength
        appendLine("password input attempt=\(attempt) verified=\(passwordVerified) entered_length=\(enteredLength) expected_length=\(expectedSecretLength)", to: logPath)
        if passwordVerified { break }
    }
    guard passwordVerified else {
        secretData.resetBytes(in: 0..<secretData.count)
        writeResult("submitted=0 reason=password input could not be verified", to: resultPath)
        exit(7)
    }
    secretData.resetBytes(in: 0..<secretData.count)
    appendLine("password input length verified", to: logPath)

    let axApp = AXUIElementCreateApplication(securityAgent.processIdentifier)
    var winRef: CFTypeRef?
    var submitted = false
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
       let windows = winRef as? [AXUIElement] {
        for window in windows {
            if let allow = findButton(window, title: "Allow Access") {
                submitted = AXUIElementPerformAction(allow, kAXPressAction as CFString) == .success
                if submitted { break }
            }
        }
    }
    if !submitted {
        postKey(36)
        submitted = true
        appendLine("Allow Access submitted with Return because AX button was opaque", to: logPath)
    } else {
        appendLine("Allow Access AX action submitted", to: logPath)
    }
    let closeDeadline = Date().addingTimeInterval(20)
    while Date() < closeDeadline && hasVisibleWindow(pid: securityAgent.processIdentifier) {
        Thread.sleep(forTimeInterval: 0.2)
    }
    let windowClosed = !hasVisibleWindow(pid: securityAgent.processIdentifier)
    writeResult("submitted=1 authorization_window_closed=\(windowClosed)", to: resultPath)
    appendLine("authorization window closed=\(windowClosed)", to: logPath)
    exit(windowClosed ? 0 : 8)
}

if arguments.count >= 3 && arguments[1] == "--dump-all" {
    let dumpPath = arguments[2]
    var out: [String] = []
    let apps = NSWorkspace.shared.runningApplications.sorted {
        let left = ($0.localizedName ?? "").lowercased()
        let right = ($1.localizedName ?? "").lowercased()
        let leftPriority = left.contains("security") || left.contains("authoriz") || left == "system settings"
        let rightPriority = right.contains("security") || right.contains("authoriz") || right == "system settings"
        if leftPriority != rightPriority { return leftPriority }
        return left < right
    }
    for app in apps where !app.isTerminated {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        let windows: [AXUIElement]
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
           let accessibleWindows = winRef as? [AXUIElement], !accessibleWindows.isEmpty {
            windows = accessibleWindows
        } else {
            windows = axChildren(axApp)
        }
        guard !windows.isEmpty else { continue }
        out.append("APP name='\(app.localizedName ?? "")' bundle='\(app.bundleIdentifier ?? "")' pid=\(app.processIdentifier) roots=\(windows.count)")
        if let focused = focusedElement(app) {
            out.append("  FOCUSED")
            dumpElement(focused, depth: 2, out: &out)
        }
        for window in windows {
            dumpElement(window, depth: 1, out: &out)
        }
        if out.count >= 1200 { break }
    }
    if out.isEmpty { out.append("No accessible windows") }
    try? out.joined(separator: "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
    exit(0)
}

if arguments.count >= 4 && arguments[1] == "--dump-pid",
   let pid = pid_t(arguments[2]) {
    let dumpPath = arguments[3]
    let app = NSRunningApplication(processIdentifier: pid)
    let axApp = AXUIElementCreateApplication(pid)
    var out = ["APP name='\(app?.localizedName ?? "")' bundle='\(app?.bundleIdentifier ?? "")' pid=\(pid)"]
    if let app, let focused = focusedElement(app) {
        out.append(debugElement(focused, label: "FOCUSED"))
        dumpElement(focused, depth: 1, out: &out)
        var current = focused
        for level in 1...6 {
            guard let parent = parentElement(current) else { break }
            out.append(debugElement(parent, label: "PARENT\(level)"))
            current = parent
        }
    }
    var winRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
       let windows = winRef as? [AXUIElement] {
        for window in windows { dumpElement(window, depth: 0, out: &out) }
    }
    try? out.joined(separator: "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
    exit(0)
}

if arguments.count >= 3 && arguments[1] == "--dump" {
    let dumpPath = arguments[2]
    var out: [String] = []
    for app in NSWorkspace.shared.runningApplications
    where app.bundleIdentifier == "com.apple.systempreferences" {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winRef) == .success,
           let windows = winRef as? [AXUIElement] {
            out.append("windows=\(windows.count)")
            for window in windows {
                dumpElement(window, depth: 0, out: &out)
            }
        }
    }
    if out.isEmpty {
        out.append("System Settings not running")
    }
    try? out.joined(separator: "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
    exit(0)
}

if arguments.count >= 7 && arguments[1] == "--watch" {
    let statePath = arguments[2]
    let baseline = arguments[3]
    let paneURL = URL(string: arguments[4])!
    let duration = Double(arguments[5]) ?? 60
    let stopPath = arguments[6]
    let allowedProfileID = arguments.count >= 8 ? arguments[7] : ""
    let allowedProfileName = arguments.count >= 9 ? arguments[8] : ""
    FileManager.default.createFile(atPath: statePath, contents: Data())
    let deadline = Date().addingTimeInterval(duration)
    var lastRemoveLockLog = Date.distantPast
    var allowedAuthUntil = Date.distantPast
    var lastAuthSnapshot = ""
    var lastDetail = ""
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: stopPath) {
            break
        }
        let titles = runAppleScript("tell application \"System Events\" to tell process \"System Settings\" to get name of every window")
        var detail: String
        var strayed = false
        if let titles, !titles.isEmpty {
            let current = titles.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if current == baseline {
                detail = "ok \(current)"
            } else {
                strayed = true
                detail = "strayed \(current)"
            }
        } else {
            strayed = true
            detail = "settings-closed"
        }
        if !strayed, let sheet = settingsSheet() {
            var texts: [String] = []
            collectTexts(sheet, depth: 0, out: &texts)
            var buttonTitles: [String] = []
            collectButtonTitles(sheet, depth: 0, out: &buttonTitles)
            let destructiveButton = buttonTitles.first {
                let title = $0.lowercased()
                return title.contains("remove") || title.contains("delete") ||
                    title.contains("unenroll") || title.contains("disconnect") ||
                    title.contains("forget")
            }
            if let destructiveButton {
                let allowed = !allowedProfileName.isEmpty && texts.contains {
                    $0.contains(allowedProfileName)
                }
                if allowed {
                    allowedAuthUntil = Date().addingTimeInterval(60)
                    detail = "ok removal-confirmation \(allowedProfileName)"
                } else {
                    var cancelled = false
                    for cancelTitle in ["Cancel", "Deny", "Don't Allow"] {
                        if let cancel = findButton(sheet, title: cancelTitle) {
                            cancelled = AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success
                            if cancelled { break }
                        }
                    }
                    if !cancelled {
                        cancelled = AXUIElementPerformAction(sheet, kAXCancelAction as CFString) == .success
                    }
                    let message = texts.first ?? "unknown"
                    detail = "blocked destructive-sheet action=\(destructiveButton) cancelled=\(cancelled) message=\(message)"
                    appendLine("\(Int(Date().timeIntervalSince1970)) \(detail)", to: statePath)
                    Thread.sleep(forTimeInterval: 0.3)
                    continue
                }
            }
            let policyID = texts.first {
                $0.hasPrefix("com.") && !$0.contains(" ")
            } ?? ""
            if !policyID.isEmpty {
                if policyID == allowedProfileID {
                    allowedAuthUntil = Date().addingTimeInterval(60)
                    detail = "ok policy-sheet \(policyID)"
                } else {
                    var disabled: [String] = []
                    disableRemovalControls(sheet, depth: 0, out: &disabled)
                    if AXUIElementPerformAction(sheet, kAXCancelAction as CFString) != .success {
                        if let app = NSWorkspace.shared.runningApplications.first(where: {
                            $0.bundleIdentifier == "com.apple.systempreferences"
                        }) {
                            app.terminate()
                        }
                        NSWorkspace.shared.open(paneURL)
                    }
                    detail = "blocked policy-sheet \(policyID)"
                    appendLine("\(Int(Date().timeIntervalSince1970)) \(detail)", to: statePath)
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }
            }
        }
        let authApps = securityAgents()
        if authApps.isEmpty {
            if !lastAuthSnapshot.isEmpty {
                appendLine("\(Int(Date().timeIntervalSince1970)) auth-window closed", to: statePath)
                lastAuthSnapshot = ""
            }
        } else if Date() >= allowedAuthUntil {
            var terminated = true
            for app in authApps {
                if !app.terminate() {
                    terminated = app.forceTerminate() && terminated
                }
            }
            appendLine("\(Int(Date().timeIntervalSince1970)) blocked SecurityAgent terminated=\(terminated)", to: statePath)
            lastAuthSnapshot = ""
            Thread.sleep(forTimeInterval: 0.3)
            continue
        } else {
            let snapshot = securityAgentSnapshot(authApps)
            if snapshot != lastAuthSnapshot {
                appendLine("\(Int(Date().timeIntervalSince1970)) allowed auth-window \(snapshot)", to: statePath)
                lastAuthSnapshot = snapshot
            }
        }
        if !strayed {
            var disabled: [String] = []
            for window in settingsWindows() {
                disableRemovalControls(window, depth: 0, out: &disabled)
            }
            if !disabled.isEmpty && Date().timeIntervalSince(lastRemoveLockLog) >= 5 {
                appendLine("\(Int(Date().timeIntervalSince1970)) disabled-remove \(disabled.joined(separator: ","))", to: statePath)
                lastRemoveLockLog = Date()
            }
        }
        if strayed {
            if let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.apple.systempreferences"
            }) {
                app.terminate()
            }
            Thread.sleep(forTimeInterval: 1.0)
            NSWorkspace.shared.open(paneURL)
            detail += " -> snapped-back"
            appendLine("\(Int(Date().timeIntervalSince1970)) \(detail)", to: statePath)
            let settingsQuery = "tell application \"System Events\" to tell process \"System Settings\" to get name of every window"
            var settled = false
            let settleDeadline = Date().addingTimeInterval(10)
            while Date() < settleDeadline {
                if FileManager.default.fileExists(atPath: stopPath) {
                    break
                }
                Thread.sleep(forTimeInterval: 1.0)
                if let t = runAppleScript(settingsQuery),
                   t.components(separatedBy: ",").first?
                    .trimmingCharacters(in: .whitespaces) == baseline {
                    settled = true
                    break
                }
            }
            appendLine("\(Int(Date().timeIntervalSince1970)) settled=\(settled)", to: statePath)
            continue
        }
        if detail != lastDetail {
            appendLine("\(Int(Date().timeIntervalSince1970)) \(detail)", to: statePath)
            lastDetail = detail
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    exit(0)
}

let resultPath = arguments.count > 1 ? arguments[1] : "/dev/stdout"
let windowQuery: String
if arguments.count >= 3 && !arguments[2].isEmpty {
    windowQuery = "tell application \"System Events\" to tell process \"\(arguments[2])\" to get name of every window"
} else {
    windowQuery = "tell application \"System Events\" to count windows of (first application process whose frontmost is true)"
}
let front = runAppleScript(windowQuery)
let text: String
let status: Int32
if let front {
    text = "ok \(front)"
    status = 0
} else {
    text = "error no window list"
    status = 3
}
try? text.write(toFile: resultPath, atomically: true, encoding: .utf8)
exit(status)
