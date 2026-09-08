import Foundation
import SwiftUI
import ServiceManagement
import WidgetKit

public enum RangeKind: String, CaseIterable {
    case today = "today"
    case week = "week"
    case month = "month"

    public var label: String {
        switch self {
        case .today: return "今日"
        case .week: return "近7天"
        case .month: return "本月"
        }
    }
}

public enum MonthView: String {
    case line = "line"
    case weeks = "weeks"
}

public enum MenuMetric: String {
    case tokens = "tokens"
    case cost = "cost"
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var snapshot: ScanSnapshot?
    @Published public var lastSuccessAt: Date?
    @Published public var lastError: String?
    @Published public var storageError: String?
    @Published public var isScanning = false
    @Published public var hasPendingScan = false

    @Published public var range: RangeKind = .today
    @Published public var monthView: MonthView = .line
    @Published public var clientFilter: String? = nil
    @Published public var expandedClients: Set<String> = ["codex"]
    @Published public var selectedModel: SelectedModel? = nil
    @Published public var selectedDayIndex: Int = -1
    @Published public var trendMetric: MenuMetric = .tokens

    @Published public var hasOnboarded: Bool {
        didSet { UserDefaults.standard.set(hasOnboarded, forKey: "hasOnboarded") }
    }
    @Published public var enabledClients: Set<String> {
        didSet { persistEnabled() }
    }
    @Published public var interval: TimeInterval {
        didSet { UserDefaults.standard.set(interval, forKey: "scanInterval"); rescheduleTimer() }
    }
    @Published public var menuMetric: MenuMetric {
        didSet { UserDefaults.standard.set(menuMetric.rawValue, forKey: "menuMetric") }
    }
    @Published public var widgetShowCost: Bool {
        didSet { UserDefaults.standard.set(widgetShowCost, forKey: "widgetShowCost"); republishWidget() }
    }
    @Published public var timeZoneID: String
    @Published public var loginEnabled: Bool = false
    @Published public var loginError: String? = nil
    @Published public var priceStatus: String? = nil

    public struct SelectedModel: Identifiable, Equatable {
        public var id: String
        public var clientId: String
        public var modelId: String
        public var range: RangeKind
    }

    private let coalescer = ScanCoalescer()
    private let scanRunner = CollectorRunner()
    private let priceRunner = CollectorRunner()
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var priceTask: Task<Void, Never>?
    private var priceInFlight = false
    private var isQuitting = false
    private var currentGeneration: UInt64 = 0
    private var lastPriceAttempt: Date? {
        didSet {
            if let d = lastPriceAttempt {
                UserDefaults.standard.set(d.timeIntervalSince1970, forKey: "lastPriceAttempt")
            }
        }
    }

    public init() {
        let defaults = UserDefaults.standard
        self.hasOnboarded = defaults.object(forKey: "hasOnboarded") as? Bool ?? false
        if defaults.object(forKey: "enabledClients") != nil {
            self.enabledClients = Set(defaults.array(forKey: "enabledClients") as? [String] ?? [])
        } else {
            self.enabledClients = Set(["codex", "claude", "opencode"])
        }
        let iv = defaults.double(forKey: "scanInterval")
        self.interval = (iv == 300 || iv == 600) ? iv : 600
        self.menuMetric = MenuMetric(rawValue: defaults.string(forKey: "menuMetric") ?? "tokens") ?? .tokens
        self.widgetShowCost = defaults.object(forKey: "widgetShowCost") as? Bool ?? true
        self.timeZoneID = defaults.string(forKey: "statsTimeZone") ?? TimeZone.current.identifier
        if TimeZone(identifier: self.timeZoneID) == nil {
            self.timeZoneID = "Asia/Shanghai"
        }
        let ts = defaults.double(forKey: "lastPriceAttempt")
        self.lastPriceAttempt = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        refreshLoginStatus()
        loadPersistedSnapshot()
        rescheduleTimer()
        observeSystemEvents()
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? TimeZone.current }

    public var todayString: String {
        Aggregation.todayString(now: Date(), timeZone: timeZone)
    }

    // MARK: - Persistence

    private func persistEnabled() {
        UserDefaults.standard.set(Array(enabledClients), forKey: "enabledClients")
    }

    private func loadPersistedSnapshot() {
        do {
            let snap = try SnapshotStore.loadPrivate()
            snapshot = snap
            lastSuccessAt = snap.generatedAt
            if !configMatches(snap) {
                do {
                    try SnapshotStore.invalidateWidget()
                } catch {
                    storageError = error.localizedDescription
                }
            }
        } catch {
            snapshot = nil
        }
    }

    private func configMatches(_ snap: ScanSnapshot) -> Bool {
        ScanScheduler.isDisplayValid(
            snapshotClients: Set(snap.sources.map { $0.clientId }),
            snapshotTimeZone: snap.timezone,
            enabledClients: enabledClients,
            timeZoneID: timeZoneID)
    }

    // MARK: - Config-scoped display

    public var displayValid: Bool {
        guard let snap = snapshot else { return true }
        return configMatches(snap)
    }

    public var configStaleNotice: String? {
        guard snapshot != nil, !displayValid else { return nil }
        return "来源选择已更改，上次统计属于旧配置，等待重新采集（旧数据已保留，不显示）"
    }

    private var visibleSnapshot: ScanSnapshot? {
        guard displayValid else { return nil }
        return snapshot
    }

    public func filteredSnapshot() -> ScanSnapshot? {
        guard let snap = visibleSnapshot else { return nil }
        return RangeProjection.filteredSnapshot(snap, enabled: enabledClients, filter: filterSet())
    }

    public func todayFiltered() -> AggregatedUsage? {
        Aggregation.todayUsage(filteredSnapshot(), today: todayString, clientIds: nil)
    }

    public func todayUnfiltered() -> AggregatedUsage? {
        guard let snap = visibleSnapshot else { return nil }
        return Aggregation.todayUsage(snap, today: todayString, clientIds: nil)
    }

    public func filterSet() -> Set<String>? {
        guard let f = clientFilter, enabledClients.contains(f) else { return nil }
        return [f]
    }

    public func rangeDays() -> [String] {
        let today = todayString
        switch range {
        case .today: return [today]
        case .week:
            return Aggregation.trailing7Days(now: Date(), timeZone: timeZone)
        case .month:
            let start = Aggregation.monthStartString(containing: today)
            return Aggregation.datesBetween(since: start, until: today)
        }
    }

    public func rangeClients() -> [RangeClientEntry] {
        guard let snap = visibleSnapshot else { return [] }
        return RangeProjection.clients(
            snapshot: snap, days: Set(rangeDays()),
            enabled: enabledClients, filter: filterSet())
    }

    public func rangeTotal() -> AggregatedUsage? {
        guard let snap = visibleSnapshot else { return nil }
        return RangeProjection.rangeTotal(
            snapshot: snap, days: rangeDays(), today: todayString,
            enabled: enabledClients, filter: filterSet())
    }

    public func categoryBreakdown() -> [(String, Int64)]? {
        guard let t = rangeTotal()?.tokens else { return nil }
        return [("输入", t.input), ("输出", t.output), ("缓存读取", t.cacheRead), ("缓存写入", t.cacheWrite), ("推理", t.reasoning)]
    }

    public var isExpiredSnapshot: Bool {
        guard let snap = visibleSnapshot else { return false }
        return snap.range.until != todayString
    }

    public var expiredLabel: String? {
        guard isExpiredSnapshot, let snap = visibleSnapshot else { return nil }
        return "\(Format.dayLabel(snap.range.until))的数据 · 今日暂无覆盖"
    }

    // MARK: - Navigation intents

    public func openToday() {
        range = .today
        clientFilter = nil
        selectedModel = nil
        selectedDayIndex = -1
    }

    public func todayMenuTitle() -> String {
        guard let u = todayUnfiltered() else { return "—" }
        switch menuMetric {
        case .tokens:
            return Format.compact(u.tokens.total)
        case .cost:
            if u.tokens.total > 0, u.cost.amountUsd == nil { return "—" }
            return Format.costText(tokensTotal: u.tokens.total, cost: u.cost)
        }
    }

    // MARK: - Scanning

    public func requestScan(userInitiated: Bool = false) {
        guard hasOnboarded, !enabledClients.isEmpty, !isQuitting else { return }
        switch coalescer.requestScan() {
        case .start:
            startScan()
        case .queued:
            hasPendingScan = true
        }
        if userInitiated { lastError = nil }
    }

    public func handleTrigger() {
        let now = Date()
        let covered = snapshot?.range.until
        if ScanScheduler.shouldTrigger(
            lastSuccess: lastSuccessAt, lastCoveredDate: covered,
            today: todayString, interval: interval, now: now) {
            requestScan()
        }
    }

    private func startScan() {
        isScanning = true
        hasPendingScan = coalescer.hasPending
        let tag = coalescer.generation
        currentGeneration = tag
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rangeReq = ScanScheduler.scanRange(now: Date(), timeZone: timeZone)
        let clients = Array(enabledClients)
        let tzID = timeZoneID
        scanTask?.cancel()
        scanTask = Task { await self.performScan(home: home, rangeReq: rangeReq, clients: clients, timeZoneID: tzID, tag: tag) }
    }

    private func performScan(home: String, rangeReq: ScanRangeRequest, clients: [String], timeZoneID: String, tag: UInt64) async {
        defer {
            Task { @MainActor in
                if self.isQuitting {
                    self.coalescer.cancelAll()
                    self.isScanning = false
                    self.hasPendingScan = false
                } else {
                    self.isScanning = false
                    if self.coalescer.finishScan() {
                        self.hasPendingScan = false
                        self.startScan()
                    } else {
                        self.hasPendingScan = false
                    }
                }
            }
        }
        let configDir: String
        do { configDir = try SnapshotStore.configDirectory().path } catch { return }
        let requestSet = Set(clients.map { $0.lowercased() })
        let args: [String]
        do {
            args = try ScanScheduler.buildScanArguments(
                home: home, configDir: configDir, timeZoneID: timeZoneID,
                range: rangeReq, clients: clients)
        } catch {
            setErrorIfCurrent("参数错误：\(error.localizedDescription)", tag: tag)
            return
        }
        guard let helper = CollectorRunner.helperURL() else {
            setErrorIfCurrent(RunnerError.helperMissing.errorDescription ?? "未找到内置采集程序", tag: tag)
            return
        }
        if Task.isCancelled { return }
        do {
            let (data, _) = try await scanRunner.run(
                executableURL: helper, arguments: args,
                environment: ["TOKENS_CONFIG_DIR": configDir])
            if Task.isCancelled { return }
            let snap = try ScanSnapshot.decodeValidated(from: data)
            guard ScanScheduler.isResponseMatching(
                requestClients: requestSet, requestTimeZone: timeZoneID,
                responseSources: snap.sources.map({ $0.clientId }),
                responseTimeZone: snap.timezone) else {
                setErrorIfCurrent("返回与请求不一致，已保留上次成功统计", tag: tag)
                return
            }
            self.applySuccess(snap, tag: tag)
        } catch let e as RunnerError {
            switch e {
            case .cancelled: return
            default: setErrorIfCurrent(e.errorDescription ?? "采集失败", tag: tag)
            }
        } catch {
            setErrorIfCurrent("采集结果异常（已保留上次成功统计）", tag: tag)
        }
    }

    @MainActor
    private func applySuccess(_ snap: ScanSnapshot, tag: UInt64) {
        guard !coalescer.isStale(tag: tag) else { return }
        snapshot = snap
        lastSuccessAt = snap.generatedAt
        lastError = nil
        do {
            try SnapshotStore.saveSuccess(snap, today: todayString)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
        maybePriceRefresh()
    }

    @MainActor
    private func setErrorIfCurrent(_ msg: String, tag: UInt64) {
        guard !coalescer.isStale(tag: tag) else { return }
        lastError = msg
    }

    public func prepareForQuit() async {
        isQuitting = true
        timer?.invalidate()
        coalescer.cancelAll()
        scanRunner.cancel()
        priceRunner.cancel()
        scanTask?.cancel()
        priceTask?.cancel()
        let scan = scanTask
        let price = priceTask
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await scan?.result }
            group.addTask { _ = await price?.result }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            await group.next()
            group.cancelAll()
        }
    }

    public func retry() { requestScan(userInitiated: true) }

    // MARK: - Source selection

    public func setEnabled(_ id: String, on: Bool) {
        if on { enabledClients.insert(id) } else { enabledClients.remove(id) }
        if enabledClients.isEmpty { clientFilter = nil }
        if let f = clientFilter, !enabledClients.contains(f) { clientFilter = nil }
        coalescer.noteSourcesChanged()
        lastError = nil
        do {
            try SnapshotStore.invalidateWidget()
        } catch {
            storageError = error.localizedDescription
        }
        if hasOnboarded && !enabledClients.isEmpty {
            requestScan()
        }
    }

    public func completeOnboarding() {
        guard !enabledClients.isEmpty else { return }
        hasOnboarded = true
        openToday()
        requestScan(userInitiated: true)
    }

    // MARK: - Timer / wake / day-change (single composed trigger)

    private func rescheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handleTrigger() }
        }
    }

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleTrigger() }
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleTrigger() }
        }
    }

    public func onAppear() {
        handleTrigger()
        maybePriceRefresh()
    }

    // MARK: - Price refresh (daily attempt cap, never blocks display)

    public func maybePriceRefresh() {
        guard hasOnboarded, !isQuitting, !priceInFlight else { return }
        guard ScanScheduler.isPriceAttemptDue(
            lastAttempt: lastPriceAttempt, now: Date(), timeZone: timeZone) else { return }
        guard let helper = CollectorRunner.helperURL() else { return }
        priceInFlight = true
        lastPriceAttempt = Date()
        priceTask = Task { await self.performPriceRefresh(helper: helper) }
    }

    private func performPriceRefresh(helper: URL) async {
        defer { self.priceInFlight = false }
        let configDir: String
        do { configDir = try SnapshotStore.configDirectory().path } catch { return }
        let args: [String]
        do {
            args = try ScanScheduler.buildPricesArguments(configDir: configDir)
        } catch { return }
        if Task.isCancelled { return }
        do {
            _ = try await priceRunner.run(
                executableURL: helper, arguments: args,
                environment: ["TOKENS_CONFIG_DIR": configDir], timeout: 120)
            if Task.isCancelled { return }
            self.recordPriceStatus(success: true)
        } catch RunnerError.cancelled {
            return
        } catch is CancellationError {
            return
        } catch {
            self.recordPriceStatus(success: false)
        }
    }

    @MainActor
    private func recordPriceStatus(success: Bool) {
        priceStatus = success ? nil : "价格更新失败，已保留缓存（Token 统计不受影响）"
        if success { requestScan() }
    }

    private func republishWidget() {
        guard let snap = visibleSnapshot else { return }
        do {
            try SnapshotStore.saveSuccess(snap, today: todayString)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Login launch (SMAppService only on explicit user toggle)

    public func refreshLoginStatus() {
        loginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    public func setLoginEnabled(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = (SMAppService.mainApp.status == .enabled)
        } catch {
            loginError = error.localizedDescription
            refreshLoginStatus()
        }
    }
}
