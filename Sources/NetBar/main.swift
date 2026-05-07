import AppKit
import NetBarCore
import UniformTypeIdentifiers

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController()
        controller?.start()
    }
}

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: MonitorModel
    private let dashboardController: DashboardViewController
    private let updateChecker = GitHubUpdateChecker(owner: "murongg", repository: "NetBar")
    private let releasesURL = URL(string: "https://github.com/murongg/NetBar/releases")!

    override init() {
        self.model = MonitorModel()
        self.dashboardController = DashboardViewController()
        super.init()

        dashboardController.onPeriodChange = { [weak self] period in
            self?.model.period = period
        }
        dashboardController.onRefresh = { [weak self] in
            self?.model.tick()
        }
        dashboardController.onOpenDataFolder = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.model.storeFileURL])
        }
        dashboardController.onCheckForUpdates = { [weak self] in
            self?.checkForUpdates()
        }
        dashboardController.onQuit = {
            NSApplication.shared.terminate(nil)
        }

        model.onChange = { [weak self] in
            self?.render()
        }
    }

    func start() {
        configureStatusItem()
        configurePopover()
        render()
        model.start()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        statusItem.length = 112
        let image = NSImage(systemSymbolName: "arrow.up.arrow.down.circle", accessibilityDescription: "NetBar")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "NetBar \(AppVersion.current.tagString)"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 400, height: 540)
        popover.contentViewController = dashboardController
        _ = dashboardController.view
    }

    private func render() {
        applyStatusTitle(model.statusTitle)
        dashboardController.update(
            dashboard: model.dashboard,
            period: model.period,
            lastUpdated: model.lastUpdated,
            lastError: model.lastError,
            downloadRate: model.lastDownloadBytesPerSecond,
            uploadRate: model.lastUploadBytesPerSecond
        )
    }

    private func applyStatusTitle(_ title: String) {
        guard let button = statusItem.button else {
            return
        }

        button.title = title
        button.toolTip = "NetBar \(AppVersion.current.tagString)  \(title)"
        button.setAccessibilityLabel(button.toolTip)
    }

    private func checkForUpdates() {
        Task {
            do {
                let status = try await updateChecker.check()
                await MainActor.run {
                    self.presentUpdateStatus(status)
                }
            } catch {
                await MainActor.run {
                    self.presentUpdateError(error)
                }
            }
        }
    }

    private func presentUpdateStatus(_ status: AppUpdateStatus) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational

        switch status {
        case let .updateAvailable(currentVersion, latestVersion, releaseURL):
            alert.messageText = "NetBar \(latestVersion.tagString) is available"
            alert.informativeText = "You are running \(currentVersion.tagString). Open the GitHub release page to download the latest build."
            alert.addButton(withTitle: "Open Release")
            alert.addButton(withTitle: "Later")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releaseURL)
            }
        case let .upToDate(currentVersion):
            alert.messageText = "NetBar is up to date"
            alert.informativeText = "You are running \(currentVersion.tagString)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case let .noPublishedRelease(currentVersion):
            alert.messageText = "No NetBar release has been published yet"
            alert.informativeText = "You are running \(currentVersion.tagString). Open GitHub Releases to publish or download builds."
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "OK")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releasesURL)
            }
        }
    }

    private func presentUpdateError(_ error: Error) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to check for updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasesURL)
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            render()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            dashboardController.view.window?.makeKey()
        }
    }
}

final class DashboardViewController: NSViewController {
    var onPeriodChange: ((StatisticsPeriod) -> Void)?
    var onRefresh: (() -> Void)?
    var onOpenDataFolder: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onQuit: (() -> Void)?

    private let iconProvider = AppIconProvider()
    private let titleLabel = Label(style: .title)
    private let statusLabel = Label(style: .caption)
    private let rateLabel = Label(style: .caption)
    private let totalValueLabel = Label(style: .headline)
    private let totalCaptionLabel = Label(style: .caption)
    private let proxyMetric = MetricPillView(title: "Proxy", symbolName: "point.topleft.down.curvedto.point.bottomright.up")
    private let directMetric = MetricPillView(title: "Direct", symbolName: "arrow.triangle.branch")
    private let loopbackMetric = MetricPillView(title: "Local", symbolName: "desktopcomputer")
    private let periodControl = NSSegmentedControl(labels: StatisticsPeriod.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let rowStack = NSStackView()
    private let emptyState = Label(style: .body)
    private let scrollView = NSScrollView()
    private var rowWidthConstraints: [NSLayoutConstraint] = []

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 400, height: 540)))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(effectView)

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(rootStack)

        rootStack.addArrangedSubview(headerView())
        rootStack.addArrangedSubview(totalBand())
        rootStack.addArrangedSubview(periodView())
        rootStack.addArrangedSubview(listView())
        rootStack.addArrangedSubview(footerView())

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: view.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            rootStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: effectView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),

            headerViewWidthConstraint(rootStack),
            totalBandWidthConstraint(rootStack),
            periodViewWidthConstraint(rootStack),
            scrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36),
            scrollView.heightAnchor.constraint(equalToConstant: 255),
            footerWidthConstraint(rootStack)
        ])
    }

    func update(
        dashboard: TrafficDashboardPresentation,
        period: StatisticsPeriod,
        lastUpdated: Date?,
        lastError: String?,
        downloadRate: Double,
        uploadRate: Double
    ) {
        titleLabel.stringValue = "NetBar"
        rateLabel.stringValue = TrafficPresentation.rateLabel(
            downloadBytesPerSecond: downloadRate,
            uploadBytesPerSecond: uploadRate
        )
        totalValueLabel.stringValue = dashboard.totalLabel
        totalCaptionLabel.stringValue = "\(dashboard.periodTitle) traffic"
        proxyMetric.value = dashboard.proxyLabel
        directMetric.value = dashboard.directLabel
        loopbackMetric.value = dashboard.loopbackLabel

        if let lastError {
            statusLabel.stringValue = "Sampling failed: \(lastError)"
            statusLabel.textColor = .systemRed
        } else if let lastUpdated {
            statusLabel.stringValue = "Updated \(Self.timeFormatter.string(from: lastUpdated))"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "Building sampling baseline"
            statusLabel.textColor = .secondaryLabelColor
        }

        if let index = StatisticsPeriod.allCases.firstIndex(of: period) {
            periodControl.selectedSegment = index
        }

        rebuildRows(with: dashboard.items)
    }

    private func headerView() -> NSView {
        let icon = SymbolBadgeView(symbolName: "arrow.up.arrow.down.circle.fill", tintColor: .controlAccentColor)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 3
        titleStack.alignment = .leading
        titleStack.addArrangedSubview(titleLabel)
        titleStack.addArrangedSubview(statusLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let ratePill = InlinePillView(symbolName: "speedometer", label: rateLabel)

        let stack = NSStackView(views: [icon, titleStack, spacer, ratePill])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.identifier = NSUserInterfaceItemIdentifier("header")
        return stack
    }

    private func totalBand() -> NSView {
        let totalStack = NSStackView()
        totalStack.orientation = .vertical
        totalStack.alignment = .leading
        totalStack.spacing = 2
        totalStack.addArrangedSubview(totalCaptionLabel)
        totalStack.addArrangedSubview(totalValueLabel)

        let routeStack = NSStackView(views: [proxyMetric, directMetric, loopbackMetric])
        routeStack.orientation = .horizontal
        routeStack.alignment = .centerY
        routeStack.distribution = .fillEqually
        routeStack.spacing = 8

        let stack = NSStackView(views: [totalStack, routeStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.identifier = NSUserInterfaceItemIdentifier("totalBand")
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 12
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.78).cgColor
        stack.layer?.borderWidth = 1
        stack.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        NSLayoutConstraint.activate([
            routeStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28)
        ])
        return stack
    }

    private func periodView() -> NSView {
        periodControl.segmentStyle = .rounded
        periodControl.target = self
        periodControl.action = #selector(periodChanged(_:))
        periodControl.translatesAutoresizingMaskIntoConstraints = false
        periodControl.identifier = NSUserInterfaceItemIdentifier("period")

        let stack = NSStackView(views: [periodControl])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.identifier = NSUserInterfaceItemIdentifier("periodWrap")

        NSLayoutConstraint.activate([
            periodControl.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return stack
    }

    private func listView() -> NSView {
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 9
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        emptyState.stringValue = "No traffic deltas yet. Keep NetBar running for a few seconds."
        emptyState.alignment = .center
        emptyState.textColor = .secondaryLabelColor

        let clipView = NSClipView()
        clipView.documentView = rowStack
        scrollView.contentView = clipView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.identifier = NSUserInterfaceItemIdentifier("list")

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: clipView.topAnchor),
            rowStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -12)
        ])

        return scrollView
    }

    private func footerView() -> NSView {
        let updates = iconButton(symbolName: "arrow.down.circle", tooltip: "Check for Updates", action: #selector(checkForUpdates(_:)))
        let refresh = iconButton(symbolName: "arrow.clockwise", tooltip: "Refresh now", action: #selector(refresh(_:)))
        let folder = iconButton(symbolName: "folder", tooltip: "Open data folder", action: #selector(openDataFolder(_:)))
        let quit = iconButton(symbolName: "power", tooltip: "Quit", action: #selector(quit(_:)))

        let left = Label(style: .caption)
        left.stringValue = "NetBar \(AppVersion.current.tagString)"
        left.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [left, spacer, updates, refresh, folder, quit])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.identifier = NSUserInterfaceItemIdentifier("footer")
        return stack
    }

    private func rebuildRows(with items: [TrafficAppPresentation]) {
        NSLayoutConstraint.deactivate(rowWidthConstraints)
        rowWidthConstraints.removeAll()
        rowStack.removeAllArrangedSubviews()

        if items.isEmpty {
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(emptyState)
            emptyState.translatesAutoresizingMaskIntoConstraints = false
            rowStack.addArrangedSubview(wrapper)

            let widthConstraint = wrapper.widthAnchor.constraint(equalTo: rowStack.widthAnchor)
            rowWidthConstraints.append(widthConstraint)

            NSLayoutConstraint.activate([
                widthConstraint,
                wrapper.heightAnchor.constraint(equalToConstant: 150),
                emptyState.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 18),
                emptyState.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -18),
                emptyState.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor)
            ])
            return
        }

        for item in items {
            let row = AppTrafficRowView(item: item, icon: iconProvider.icon(for: item.appName))
            rowStack.addArrangedSubview(row)
            let widthConstraint = row.widthAnchor.constraint(equalTo: rowStack.widthAnchor)
            rowWidthConstraints.append(widthConstraint)
            widthConstraint.isActive = true
        }
    }

    private func iconButton(symbolName: String, tooltip: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
        return button
    }

    @objc private func periodChanged(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard StatisticsPeriod.allCases.indices.contains(index) else {
            return
        }
        onPeriodChange?(StatisticsPeriod.allCases[index])
    }

    @objc private func refresh(_ sender: NSButton) {
        onRefresh?()
    }

    @objc private func openDataFolder(_ sender: NSButton) {
        onOpenDataFolder?()
    }

    @objc private func checkForUpdates(_ sender: NSButton) {
        onCheckForUpdates?()
    }

    @objc private func quit(_ sender: NSButton) {
        onQuit?()
    }

    private func headerViewWidthConstraint(_ rootStack: NSStackView) -> NSLayoutConstraint {
        guard let header = rootStack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "header" }) else {
            return view.widthAnchor.constraint(equalToConstant: 400)
        }
        return header.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36)
    }

    private func totalBandWidthConstraint(_ rootStack: NSStackView) -> NSLayoutConstraint {
        guard let band = rootStack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "totalBand" }) else {
            return view.widthAnchor.constraint(equalToConstant: 400)
        }
        return band.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36)
    }

    private func periodViewWidthConstraint(_ rootStack: NSStackView) -> NSLayoutConstraint {
        guard let period = rootStack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "periodWrap" }) else {
            return view.widthAnchor.constraint(equalToConstant: 400)
        }
        return period.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36)
    }

    private func footerWidthConstraint(_ rootStack: NSStackView) -> NSLayoutConstraint {
        guard let footer = rootStack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "footer" }) else {
            return view.widthAnchor.constraint(equalToConstant: 400)
        }
        return footer.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

final class AppTrafficRowView: NSView {
    private let barView: RouteBarView

    init(item: TrafficAppPresentation, icon: NSImage) {
        self.barView = RouteBarView(routes: item.routes, share: item.share)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.36).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        let nameLabel = Label(style: .bodyStrong)
        nameLabel.stringValue = item.appName
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let totalLabel = Label(style: .bodyStrong)
        totalLabel.stringValue = item.totalLabel
        totalLabel.alignment = .right
        totalLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let detailLabel = Label(style: .caption)
        detailLabel.stringValue = item.detailLabel
        detailLabel.textColor = .secondaryLabelColor

        let topLine = NSStackView(views: [nameLabel, NSView(), totalLabel])
        topLine.orientation = .horizontal
        topLine.alignment = .firstBaseline
        topLine.spacing = 8

        let chipStack = NSStackView()
        chipStack.orientation = .horizontal
        chipStack.alignment = .centerY
        chipStack.spacing = 6
        for route in item.routes {
            chipStack.addArrangedSubview(RouteChipView(route: route))
        }

        let body = NSStackView(views: [topLine, detailLabel, barView, chipStack])
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 7

        let iconView = AppIconView(image: icon)
        let content = NSStackView(views: [iconView, body])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -62),
            topLine.widthAnchor.constraint(equalTo: body.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
            barView.widthAnchor.constraint(equalTo: body.widthAnchor),
            barView.heightAnchor.constraint(equalToConstant: 6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class AppIconView: NSView {
    init(image: NSImage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.65).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class AppIconProvider {
    private var cache: [String: NSImage] = [:]
    private lazy var applicationURLsByName = buildApplicationIndex()

    func icon(for appName: String) -> NSImage {
        if let cached = cache[appName] {
            return cached
        }

        let resolved = resolveIcon(for: appName) ?? NSWorkspace.shared.icon(for: UTType.applicationBundle)
        resolved.size = NSSize(width: 28, height: 28)
        cache[appName] = resolved
        return resolved
    }

    private func resolveIcon(for appName: String) -> NSImage? {
        let candidates = TrafficPresentation.appIconSearchNames(for: appName)
        guard !candidates.isEmpty else {
            return nil
        }

        if let runningIcon = iconFromRunningApplications(matching: candidates) {
            return runningIcon
        }

        for candidate in candidates {
            if let url = applicationURLsByName[candidate.lowercased()] {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        return nil
    }

    private func iconFromRunningApplications(matching candidates: [String]) -> NSImage? {
        let loweredCandidates = Set(candidates.map { $0.lowercased() })

        for application in NSWorkspace.shared.runningApplications {
            let names = [
                application.localizedName,
                application.bundleURL?.deletingPathExtension().lastPathComponent,
                application.executableURL?.deletingPathExtension().lastPathComponent
            ].compactMap { $0?.lowercased() }

            guard names.contains(where: { loweredCandidates.contains($0) }),
                  let bundleURL = application.bundleURL else {
                continue
            }

            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        return nil
    }

    private func buildApplicationIndex() -> [String: URL] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var index: [String: URL] = [:]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                indexApp(url, into: &index)
                enumerator.skipDescendants()
            }
        }

        return index
    }

    private func indexApp(_ url: URL, into index: inout [String: URL]) {
        let fileName = url.deletingPathExtension().lastPathComponent
        insert(fileName, url: url, into: &index)

        guard let bundle = Bundle(url: url) else {
            return
        }

        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        insert(info["CFBundleDisplayName"] as? String, url: url, into: &index)
        insert(info["CFBundleName"] as? String, url: url, into: &index)
    }

    private func insert(_ name: String?, url: URL, into index: inout [String: URL]) {
        guard let name,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        index[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = url
    }
}

final class MetricPillView: NSView {
    private let valueLabel = Label(style: .bodyStrong)

    var value: String {
        get { valueLabel.stringValue }
        set { valueLabel.stringValue = newValue }
    }

    init(title: String, symbolName: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.38).cgColor

        let symbol = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: title) ?? NSImage())
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        symbol.contentTintColor = .secondaryLabelColor
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = Label(style: .caption)
        titleLabel.stringValue = title
        titleLabel.textColor = .secondaryLabelColor

        valueLabel.stringValue = "0 B"

        let textStack = NSStackView(views: [titleLabel, valueLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let stack = NSStackView(views: [symbol, textStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 14),
            symbol.heightAnchor.constraint(equalToConstant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class InlinePillView: NSView {
    init(symbolName: String, label: NSTextField) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 999
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor

        let symbol = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        symbol.contentTintColor = .controlAccentColor

        label.textColor = .controlAccentColor

        let stack = NSStackView(views: [symbol, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 12),
            symbol.heightAnchor.constraint(equalToConstant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class SymbolBadgeView: NSView {
    init(symbolName: String, tintColor: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = tintColor.withAlphaComponent(0.14).cgColor

        let imageView = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage())
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        imageView.contentTintColor = tintColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 36),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class RouteChipView: NSView {
    init(route: TrafficRoutePresentation) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 999
        layer?.backgroundColor = route.route.displayColor.withAlphaComponent(0.13).cgColor

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = route.route.displayColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = Label(style: .caption)
        label.stringValue = "\(route.title) \(route.totalLabel)"
        label.textColor = route.route.displayColor

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 7, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class RouteBarView: NSView {
    private let routes: [TrafficRoutePresentation]
    private let share: Double

    init(routes: [TrafficRoutePresentation], share: Double) {
        self.routes = routes
        self.share = max(0, min(share, 1))
        super.init(frame: .zero)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let background = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor.separatorColor.withAlphaComponent(0.34).setFill()
        background.fill()

        let filledWidth = bounds.width * share
        guard filledWidth > 0 else {
            return
        }

        var cursor = CGFloat(0)
        for route in routes {
            let segmentWidth = max(1, filledWidth * route.fraction)
            let segmentRect = NSRect(x: cursor, y: 0, width: min(segmentWidth, filledWidth - cursor), height: bounds.height)
            route.route.displayColor.setFill()
            NSBezierPath(roundedRect: segmentRect, xRadius: radius, yRadius: radius).fill()
            cursor += segmentWidth
            if cursor >= filledWidth {
                break
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class Label: NSTextField {
    enum Style {
        case title
        case headline
        case body
        case bodyStrong
        case caption
    }

    init(style: Style) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        translatesAutoresizingMaskIntoConstraints = false
        textColor = .labelColor

        switch style {
        case .title:
            font = .systemFont(ofSize: 15, weight: .semibold)
        case .headline:
            font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        case .body:
            font = .systemFont(ofSize: 13, weight: .regular)
        case .bodyStrong:
            font = .systemFont(ofSize: 13, weight: .semibold)
        case .caption:
            font = .systemFont(ofSize: 11, weight: .medium)
            textColor = .secondaryLabelColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MonitorModel {
    var onChange: (() -> Void)?
    private(set) var summaries: [AppTrafficSummary] = []
    private(set) var lastUpdated: Date?
    private(set) var lastError: String?
    private(set) var lastDownloadBytesPerSecond: Double = 0
    private(set) var lastUploadBytesPerSecond: Double = 0

    private let collector: NetworkSnapshotCollecting
    private let proxyProvider: ProxySettingsProviding
    private let queue = DispatchQueue(label: "netbar.monitor")
    private let sampleInterval: TimeInterval
    private let store: JSONLinesTrafficStore
    private var timer: Timer?
    private var accumulator = TrafficAccumulator()
    private var lastSampleDate: Date?

    var period: StatisticsPeriod = .day {
        didSet {
            recalculate()
        }
    }

    var dashboard: TrafficDashboardPresentation {
        TrafficPresentation.dashboard(summaries: summaries, period: period)
    }

    var storeFileURL: URL {
        store.fileURL
    }

    var statusTitle: String {
        if lastError != nil {
            return "!"
        }

        if lastUpdated == nil {
            return "..."
        }

        return TrafficPresentation.inlineStatusBarRateLabel(
            downloadBytesPerSecond: lastDownloadBytesPerSecond,
            uploadBytesPerSecond: lastUploadBytesPerSecond
        )
    }

    init(
        collector: NetworkSnapshotCollecting = NettopCollector(),
        proxyProvider: ProxySettingsProviding = SystemProxySettingsProvider(),
        sampleInterval: TimeInterval = 5,
        storeDirectoryURL: URL = JSONLinesTrafficStore.defaultDirectoryURL()
    ) {
        self.collector = collector
        self.proxyProvider = proxyProvider
        self.sampleInterval = sampleInterval
        self.store = (try? JSONLinesTrafficStore(directoryURL: storeDirectoryURL)) ?? (try! JSONLinesTrafficStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("NetBar", isDirectory: true), legacyFileURL: nil))
        self.summaries = TrafficStatistics.aggregate(store.deltas, period: .day)
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func tick() {
        let period = self.period
        queue.async { [weak self] in
            guard let self else {
                return
            }

            do {
                let proxySettings = self.proxyProvider.currentSettings()
                let snapshot = try self.collector.collect()
                let deltas = self.accumulator.ingest(snapshot, proxySettings: proxySettings)
                try self.store.append(deltas)

                let downloadBytes = deltas.reduce(UInt64(0)) { $0 + $1.bytesIn }
                let uploadBytes = deltas.reduce(UInt64(0)) { $0 + $1.bytesOut }
                let elapsed = self.lastSampleDate.map { snapshot.timestamp.timeIntervalSince($0) } ?? self.sampleInterval
                let downloadRate = elapsed > 0 ? Double(downloadBytes) / elapsed : 0
                let uploadRate = elapsed > 0 ? Double(uploadBytes) / elapsed : 0
                self.lastSampleDate = snapshot.timestamp

                let summaries = TrafficStatistics.aggregate(self.store.deltas, period: period, now: Date())

                DispatchQueue.main.async {
                    self.lastError = nil
                    self.lastUpdated = snapshot.timestamp
                    self.lastDownloadBytesPerSecond = downloadRate
                    self.lastUploadBytesPerSecond = uploadRate
                    self.summaries = summaries
                    self.onChange?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastError = Self.shortError(error)
                    self.onChange?()
                }
            }
        }
    }

    private func recalculate() {
        let period = self.period
        queue.async { [weak self] in
            guard let self else {
                return
            }

            let summaries = TrafficStatistics.aggregate(self.store.deltas, period: period, now: Date())
            DispatchQueue.main.async {
                self.summaries = summaries
                self.onChange?()
            }
        }
    }

    private static func shortError(_ error: Error) -> String {
        if error as? CommandRunnerError == .timedOut {
            return "nettop timed out"
        }

        let text = String(describing: error)
        if text.count <= 80 {
            return text
        }
        return String(text.prefix(77)) + "..."
    }
}

private extension NSStackView {
    func removeAllArrangedSubviews() {
        for subview in arrangedSubviews {
            removeArrangedSubview(subview)
            subview.deactivateConstraintsRecursively()
            subview.removeFromSuperview()
        }
    }
}

private extension NSView {
    func deactivateConstraintsRecursively() {
        NSLayoutConstraint.deactivate(constraints)
        subviews.forEach { $0.deactivateConstraintsRecursively() }
    }
}

private extension TrafficRoute {
    var displayColor: NSColor {
        switch self {
        case .proxy:
            return NSColor.systemGreen
        case .direct:
            return NSColor.controlAccentColor
        case .loopback:
            return NSColor.systemOrange
        case .unknown:
            return NSColor.secondaryLabelColor
        }
    }
}
