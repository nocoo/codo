import AppKit
import CodoCore
import os

private let logger = Logger(subsystem: "ai.hexly.codo.04", category: "banner")

/// Custom banner notification provider using a floating NSPanel.
/// Replaces UNUserNotificationCenter to avoid system notification grouping/suppression.
public final class BannerProvider: NotificationProvider, @unchecked Sendable {
    private var currentBanner: BannerWindow?

    public var isAvailable: Bool { true }

    public init() {}

    public func requestPermission() async -> Bool { true }

    public func post(message: CodoMessage) async -> String? {
        await MainActor.run {
            showBanner(message: message)
        }
        return nil
    }

    @MainActor
    private func showBanner(message: CodoMessage) {
        if let existing = currentBanner {
            existing.dismissImmediately()
            currentBanner = nil
        }

        let banner = BannerWindow(message: message)
        currentBanner = banner
        banner.onDismiss = { [weak self] in
            self?.currentBanner = nil
        }
        banner.show()
    }
}

// MARK: - BannerWindow

final class BannerWindow: NSPanel {
    private var dismissTimer: Timer?
    private var remainingTime: TimeInterval = Banner.displayDuration
    private var timerStartDate: Date?
    private var slideOutOrigin: NSPoint = .zero
    var onDismiss: (() -> Void)?

    init(message: CodoMessage) {
        let frame = NSRect(x: 0, y: 0, width: Banner.maxWidth, height: Banner.minHeight)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow

        let content = BannerContentView(message: message)
        self.contentView = content
        content.wantsLayer = true
        content.layer?.masksToBounds = false

        content.onHoverChanged = { [weak self] hovering in
            if hovering {
                self?.pauseTimer()
            } else {
                self?.resumeTimer()
            }
        }
        content.onCloseClicked = { [weak self] in
            self?.dismissAnimated()
        }

        // Window includes shadow padding on all sides around the glass
        let shadowPad = Banner.shadowPadding
        let totalWidth = Banner.maxWidth + shadowPad * 2
        let targetSize = NSSize(width: totalWidth, height: 0)
        let fittingHeight = content.fittingSize(for: targetSize).height
        let finalHeight = max(fittingHeight, Banner.minHeight + shadowPad * 2)
        setContentSize(NSSize(width: totalWidth, height: finalHeight))
    }

    func show() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let size = frame.size
        let shadowPad = Banner.shadowPadding

        // Top-center of active screen (below menu bar / notch)
        // Offset by shadowPadding so the glass (not the shadow space) aligns with screen edge
        let targetX = visibleFrame.midX - size.width / 2
        let targetY = visibleFrame.maxY - size.height - Banner.screenMargin + shadowPad
        let targetOrigin = NSPoint(x: targetX, y: targetY)
        // Start position: above screen edge (hidden above menu bar)
        slideOutOrigin = NSPoint(x: targetX, y: screen.frame.maxY + 20)

        setFrameOrigin(slideOutOrigin)
        alphaValue = 1
        orderFrontRegardless()

        let targetFrame = NSRect(origin: targetOrigin, size: size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Banner.slideInDuration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        }
        setFrame(targetFrame, display: true, animate: true)

        remainingTime = Banner.displayDuration
        timerStartDate = Date()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: Banner.displayDuration,
            repeats: false
        ) { [weak self] _ in
            self?.dismissAnimated()
        }
    }

    // MARK: - Hover Pause / Resume

    private func pauseTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        if let start = timerStartDate {
            remainingTime -= Date().timeIntervalSince(start)
            remainingTime = max(remainingTime, 0.5)
        }
        timerStartDate = nil
    }

    private func resumeTimer() {
        timerStartDate = Date()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: remainingTime,
            repeats: false
        ) { [weak self] _ in
            self?.dismissAnimated()
        }
    }

    func dismissAnimated() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        let offFrame = NSRect(origin: slideOutOrigin, size: frame.size)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Banner.slideOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        setFrame(offFrame, display: true, animate: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + Banner.slideOutDuration + 0.05) { [weak self] in
            self?.close()
            self?.onDismiss?()
        }
    }

    func dismissImmediately() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        close()
        onDismiss?()
    }
}
