import AppKit
import Darwin
import Foundation
import IOKit.ps
import UserNotifications

private let commandURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
    "CB_BREAK_COMMAND_PATH"
] ?? "/Library/Application Support/ChickenBlocker/break-command.json")
private let requestURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
    "CB_BREAK_REQUEST_PATH"
] ?? "/tmp/com.chickenblocker.break-request.\(getuid()).json")

private struct BreakCommand: Decodable {
    let mode: String
    let until: TimeInterval
    let kind: String
    let message: String
    let allowEscape: Bool
    let interval: Int?
    let totalIntervals: Int?
    let warningSeconds: Int?
    let nextBreakKind: String?
    let away: Bool?

    private enum CodingKeys: String, CodingKey {
        case mode, until, kind, message, interval, away
        case allowEscape = "allow_escape"
        case totalIntervals = "total_intervals"
        case warningSeconds = "warning_seconds"
        case nextBreakKind = "next_break_kind"
    }
}

@MainActor
private final class OverlayViewController: NSViewController {
    private let messageLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start work", target: nil, action: nil)
    private let escapeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    var onStartWork: (() -> Void)?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor

        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 36, weight: .semibold)
        messageLabel.textColor = .white
        messageLabel.maximumNumberOfLines = 4
        messageLabel.lineBreakMode = .byWordWrapping

        countdownLabel.alignment = .center
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 64, weight: .medium)
        countdownLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1)

        startButton.target = self
        startButton.action = #selector(startWork)
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.font = .systemFont(ofSize: 20, weight: .medium)
        startButton.keyEquivalent = "\r"
        startButton.isHidden = true

        escapeLabel.alignment = .center
        escapeLabel.font = .systemFont(ofSize: 16)
        escapeLabel.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)

        statusLabel.alignment = .right
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
        statusLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusLabel)

        let stack = NSStackView(views: [messageLabel, countdownLabel, startButton, escapeLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 80),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -80),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 900),
            statusLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -36),
        ])
        view = root
    }

    func update(command: BreakCommand, now: TimeInterval, status: String, scheduleOverdue: Bool) {
        messageLabel.stringValue = scheduleOverdue
            ? "Break schedule is overdue. Waiting for the scheduler."
            : command.message
        if command.mode == "gate" {
            countdownLabel.stringValue = ""
            startButton.isHidden = false
        } else {
            let remaining = max(0, Int(ceil(command.until - now)))
            countdownLabel.stringValue = String(
                format: "%02d:%02d:%02d", remaining / 3600, (remaining / 60) % 60, remaining % 60
            )
            startButton.isHidden = true
        }
        escapeLabel.stringValue = command.allowEscape ? "TEST MODE - press Escape to dismiss this break" : ""
        statusLabel.stringValue = status
    }

    @objc private func startWork() {
        onStartWork?()
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var windows: [NSWindow] = []
    private var controllers: [OverlayViewController] = []
    private var timer: Timer?
    private var cursorHidden = false
    private var currentCommand: BreakCommand?
    private var dismissedUntil: TimeInterval = 0
    private var keyMonitor: Any?
    private var statusItem: NSStatusItem?
    private let intervalItem = NSMenuItem(title: "Interval: -", action: nil, keyEquivalent: "")
    private let scheduleItem = NSMenuItem(title: "Schedule unavailable", action: nil, keyEquivalent: "")
    private lazy var takeBreakItem = NSMenuItem(
        title: "Take a break now", action: #selector(requestBreakNow), keyEquivalent: ""
    )
    private var requestPendingAt: TimeInterval?
    private var startRequestPendingAt: TimeInterval?
    private var notifiedDeadline: TimeInterval?
    private let warningNotificationID = "com.chickenblocker.break-warning"
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM  HH:mm"
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        notificationCenter.requestAuthorization(options: [.alert]) { _, _ in }
        configureStatusItem()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let command = self?.currentCommand, command.allowEscape {
                self?.dismissedUntil = command.until
                self?.hideOverlay()
                return nil
            }
            return event
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "eye", accessibilityDescription: "ChickenBlocker breaks"
        )
        let menu = NSMenu()
        intervalItem.isEnabled = false
        menu.addItem(intervalItem)
        scheduleItem.isEnabled = false
        menu.addItem(scheduleItem)
        menu.addItem(.separator())
        takeBreakItem.target = self
        menu.addItem(takeBreakItem)
        item.menu = menu
        statusItem = item
    }

    @objc private func requestBreakNow() {
        let now = Date().timeIntervalSince1970
        guard currentCommand?.mode == "work" else { return }
        guard writeRequest(action: "take_break", now: now) else { return }
        requestPendingAt = now
        scheduleItem.title = "Break requested"
        takeBreakItem.isEnabled = false
    }

    private func requestStartWork() {
        let now = Date().timeIntervalSince1970
        guard currentCommand?.mode == "gate" else { return }
        guard writeRequest(action: "start_work", now: now) else { return }
        startRequestPendingAt = now
        hideOverlay()
    }

    private func writeRequest(action: String, now: TimeInterval) -> Bool {
        let payload: [String: Any] = ["action": action, "requested_at": Int(now)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            scheduleItem.title = "Could not send request"
            return false
        }
        let temporaryURL = requestURL.deletingLastPathComponent().appendingPathComponent(
            ".\(requestURL.lastPathComponent).\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard FileManager.default.createFile(
            atPath: temporaryURL.path, contents: data, attributes: [.posixPermissions: 0o600]
        ), rename(temporaryURL.path, requestURL.path) == 0 else {
            scheduleItem.title = "Could not send request"
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateCancel
    }

    private func readCommand() -> BreakCommand? {
        guard let data = try? Data(contentsOf: commandURL) else { return nil }
        return try? JSONDecoder().decode(BreakCommand.self, from: data)
    }

    private func batteryStatus() -> String? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }
            let percent = min(100, max(0, current * 100 / maximum))
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return charging ? "Battery \(percent)% charging" : "Battery \(percent)%"
        }
        return nil
    }

    private func statusText(now: TimeInterval) -> String {
        let clock = dateFormatter.string(from: Date(timeIntervalSince1970: now))
        guard let battery = batteryStatus() else { return clock }
        return "\(clock)   \(battery)"
    }

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        controllers.removeAll()

        for screen in NSScreen.screens {
            let controller = OverlayViewController()
            controller.onStartWork = { [weak self] in self?.requestStartWork() }
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.contentViewController = controller
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
            ]
            window.ignoresMouseEvents = false
            window.setFrame(screen.frame, display: true)
            windows.append(window)
            controllers.append(controller)
        }
    }

    private func refresh() {
        let now = Date().timeIntervalSince1970
        guard let command = readCommand() else {
            scheduleItem.title = "Schedule unavailable"
            takeBreakItem.isEnabled = false
            currentCommand = nil
            dismissedUntil = 0
            hideOverlay()
            return
        }
        currentCommand = command
        if command.mode != "gate" {
            startRequestPendingAt = nil
        }
        updateStatusMenu(command: command, now: now)
        updateBreakWarning(command: command, now: now)
        if command.mode == "gate", let pendingAt = startRequestPendingAt, now - pendingAt < 30 {
            hideOverlay()
            return
        }
        if command.away == true {
            dismissedUntil = 0
            hideOverlay()
            return
        }
        let scheduleOverdue = command.mode == "work" && command.until <= now
        guard command.mode == "gate" || scheduleOverdue
                || (command.mode == "break" && command.until > now) else {
            dismissedUntil = 0
            hideOverlay()
            return
        }
        if command.mode != "gate", dismissedUntil >= command.until {
            hideOverlay()
            return
        }

        if windows.count != NSScreen.screens.count {
            rebuildWindows()
        }
        let status = statusText(now: now)
        for controller in controllers {
            controller.update(
                command: command, now: now, status: status, scheduleOverdue: scheduleOverdue
            )
        }
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if command.mode == "gate", cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        } else if command.mode != "gate", !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
    }

    private func updateStatusMenu(command: BreakCommand, now: TimeInterval) {
        if let interval = command.interval, let total = command.totalIntervals {
            intervalItem.title = "Interval: \(interval)/\(total)"
            intervalItem.isHidden = false
        } else {
            intervalItem.isHidden = true
        }
        if command.away == true {
            scheduleItem.title = "Away - work timer paused"
            takeBreakItem.isEnabled = false
            requestPendingAt = nil
            return
        }
        if command.mode == "gate" {
            scheduleItem.title = "Waiting for Start work"
            takeBreakItem.isEnabled = false
            requestPendingAt = nil
            return
        }
        if command.mode == "break", command.until > now {
            scheduleItem.title = "Break in progress"
            takeBreakItem.isEnabled = false
            requestPendingAt = nil
            return
        }
        if command.mode == "work", command.until <= now {
            scheduleItem.title = "Break overdue - scheduler unavailable"
            takeBreakItem.isEnabled = false
            return
        }
        if let pendingAt = requestPendingAt, now - pendingAt < 30 {
            scheduleItem.title = "Break requested"
            takeBreakItem.isEnabled = false
            return
        }
        requestPendingAt = nil
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        scheduleItem.title = "Next break at \(formatter.string(from: Date(timeIntervalSince1970: command.until)))"
        takeBreakItem.isEnabled = command.mode == "work" && command.until > now
    }

    private func updateBreakWarning(command: BreakCommand, now: TimeInterval) {
        guard command.mode == "work", command.until > now, command.away != true else {
            clearBreakWarning()
            notifiedDeadline = nil
            return
        }
        if let notifiedDeadline, notifiedDeadline != command.until {
            clearBreakWarning()
            self.notifiedDeadline = nil
        }
        let warningSeconds = max(0, command.warningSeconds ?? 10)
        let remaining = Int(ceil(command.until - now))
        guard warningSeconds > 0, remaining <= warningSeconds,
              notifiedDeadline != command.until else { return }

        let content = UNMutableNotificationContent()
        content.title = "ChickenBlocker"
        let kind = command.nextBreakKind == "long" ? "long" : "short"
        content.body = "Ready for a \(kind) break in \(remaining) seconds"
        let request = UNNotificationRequest(
            identifier: warningNotificationID, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        notifiedDeadline = command.until
    }

    private func clearBreakWarning() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [warningNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [warningNotificationID])
    }

    private func hideOverlay() {
        windows.forEach { $0.orderOut(nil) }
        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }
}

@main
private struct BreakOverlayMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
