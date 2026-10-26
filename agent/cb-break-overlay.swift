import AppKit
import Foundation
import IOKit.ps

private let commandURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment[
    "CB_BREAK_COMMAND_PATH"
] ?? "/Library/Application Support/ChickenBlocker/break-command.json")

private struct BreakCommand: Decodable {
    let mode: String
    let until: TimeInterval
    let kind: String
    let message: String
    let allowEscape: Bool

    private enum CodingKeys: String, CodingKey {
        case mode, until, kind, message
        case allowEscape = "allow_escape"
    }
}

@MainActor
private final class OverlayViewController: NSViewController {
    private let messageLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let escapeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

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

        escapeLabel.alignment = .center
        escapeLabel.font = .systemFont(ofSize: 16)
        escapeLabel.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)

        statusLabel.alignment = .right
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .regular)
        statusLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statusLabel)

        let stack = NSStackView(views: [messageLabel, countdownLabel, escapeLabel])
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

    func update(command: BreakCommand, now: TimeInterval, status: String) {
        messageLabel.stringValue = command.message
        let remaining = max(0, Int(ceil(command.until - now)))
        countdownLabel.stringValue = String(
            format: "%02d:%02d:%02d", remaining / 3600, (remaining / 60) % 60, remaining % 60
        )
        escapeLabel.stringValue = command.allowEscape ? "TEST MODE - press Escape to dismiss this break" : ""
        statusLabel.stringValue = status
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var controllers: [OverlayViewController] = []
    private var timer: Timer?
    private var cursorHidden = false
    private var currentCommand: BreakCommand?
    private var dismissedUntil: TimeInterval = 0
    private var keyMonitor: Any?
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM  HH:mm"
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        guard let command = readCommand(), command.mode == "break", command.until > now else {
            currentCommand = nil
            dismissedUntil = 0
            hideOverlay()
            return
        }
        currentCommand = command
        if dismissedUntil >= command.until {
            hideOverlay()
            return
        }

        if windows.count != NSScreen.screens.count {
            rebuildWindows()
        }
        let status = statusText(now: now)
        for controller in controllers {
            controller.update(command: command, now: now, status: status)
        }
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        }
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
