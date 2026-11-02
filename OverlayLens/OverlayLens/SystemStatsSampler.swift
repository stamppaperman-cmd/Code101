import AppKit
import Darwin

// Private IOKit HID symbols used to read the SMC temperature sensors on
// Apple Silicon (same technique as the open-source Stats app). No sudo or
// special entitlement needed; if the symbols ever vanish the sampler just
// reports no temperature and the UI hides the number.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef?, _ matching: CFDictionary?) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef?) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef?, _ key: CFString?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef?, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef?, _ field: Int32) -> Double

private let kHIDEventTypeTemperature: Int64 = 15

struct AppUsage: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage?
    /// Root pid of the owning GUI app; nil for bare processes.
    let pid: pid_t?
    let isQuittable: Bool
    /// True for real Dock apps (activationPolicy .regular); false for menu
    /// bar agents and system accessories like Window Manager or Tips.
    let isRegularApp: Bool
    /// True when the app has been burning ≥90% of a core for 30+ seconds —
    /// the classic beachball pattern. The row turns red and offers an
    /// immediate force quit.
    let isStuck: Bool
    /// Fraction of one core (1.0 = 100% in Activity Monitor terms).
    let cpu: Double
    let ramBytes: UInt64

    static func == (lhs: AppUsage, rhs: AppUsage) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.icon === rhs.icon
            && lhs.pid == rhs.pid && lhs.isQuittable == rhs.isQuittable
            && lhs.isRegularApp == rhs.isRegularApp && lhs.isStuck == rhs.isStuck
            && lhs.cpu == rhs.cpu && lhs.ramBytes == rhs.ramBytes
    }
}

struct SystemStatsSnapshot: Equatable {
    enum PressureLevel { case normal, warning, critical }

    var cpuUsage: Double          // 0…1 across all cores
    var coreCount: Int
    var ramUsedBytes: UInt64
    var ramTotalBytes: UInt64
    var memoryPressure: PressureLevel
    var thermalState: ProcessInfo.ThermalState
    var cpuTemperature: Double?   // °C; nil when no readable CPU sensor
    var apps: [AppUsage]          // unsorted; view sorts by mode
}

/// Reads everything the widget shows. All data comes from local system APIs
/// (mach, libproc, IOKit HID) — no network, no extra permissions. Not
/// thread-safe; call from a single serial queue.
final class SystemStatsSampler {
    struct GUIApp {
        let name: String
        let icon: NSImage?
        let isSelf: Bool
        let isRegular: Bool
    }

    private struct RawSample {
        var time: UInt64 = mach_absolute_time()
        var busyTicks: UInt64 = 0
        var totalTicks: UInt64 = 0
        var procCpuNs: [pid_t: UInt64] = [:]
        var procFootprint: [pid_t: UInt64] = [:]
    }

    private struct Group {
        var name: String
        var icon: NSImage?
        var pid: pid_t?
        var quittable: Bool
        var regular: Bool
        var cpuNs: UInt64 = 0
        var ram: UInt64 = 0
    }

    private var previous: RawSample?

    /// When each quittable app first crossed the sustained-high-CPU line;
    /// cleared the moment it drops back under (with a little hysteresis).
    private var highCpuSince: [String: Date] = [:]
    private static let stuckThreshold = 0.9
    private static let stuckReleaseThreshold = 0.7
    private static let stuckAfterSeconds: TimeInterval = 30

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func machToNs(_ t: UInt64) -> UInt64 {
        t * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// XPC helpers (Safari web content, extensions) are children of launchd,
    /// not of their app, so the ppid walk misses them; the "responsible pid"
    /// maps them back. Private symbol, resolved dynamically so a missing
    /// symbol degrades to the ppid walk instead of failing to link.
    private static let responsiblePid: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    // MARK: - Public

    func sample(guiApps: [pid_t: GUIApp], pressure: SystemStatsSnapshot.PressureLevel) -> SystemStatsSnapshot {
        let prev: RawSample
        if let existing = previous {
            prev = existing
        } else {
            // First call has no delta baseline; take one and wait briefly so
            // the very first snapshot shows real numbers instead of zeros.
            let baseline = readRaw()
            usleep(600_000)
            prev = baseline
        }
        let cur = readRaw()
        previous = cur

        let elapsedNs = Double(Self.machToNs(cur.time &- prev.time))
        let busyDelta = Double(cur.busyTicks >= prev.busyTicks ? cur.busyTicks - prev.busyTicks : 0)
        let totalDelta = Double(cur.totalTicks >= prev.totalTicks ? cur.totalTicks - prev.totalTicks : 0)

        let (ramUsed, ramTotal) = readMemory()

        var groups: [String: Group] = [:]
        for (pid, footprint) in cur.procFootprint {
            var cpuDelta: UInt64 = 0
            if let before = prev.procCpuNs[pid], let after = cur.procCpuNs[pid], after >= before {
                cpuDelta = after - before
            }
            let identity = groupIdentity(for: pid, guiApps: guiApps)
            var group = groups[identity.key] ?? Group(
                name: identity.name, icon: identity.icon,
                pid: identity.rootPid, quittable: identity.quittable,
                regular: identity.regular
            )
            group.cpuNs += cpuDelta
            group.ram += footprint
            groups[identity.key] = group
        }

        // Everything is rounded to display precision so consecutive
        // snapshots compare equal when nothing visibly changed — the model
        // then skips publishing and SwiftUI does zero work that tick.
        let now = Date()
        let apps = groups.map { key, group in
            let cpu = elapsedNs > 0 ? (Double(group.cpuNs) / elapsedNs * 100).rounded() / 100 : 0
            var stuck = false
            if group.quittable {
                if cpu >= Self.stuckThreshold {
                    let since = highCpuSince[key] ?? now
                    highCpuSince[key] = since
                    stuck = now.timeIntervalSince(since) >= Self.stuckAfterSeconds
                } else if cpu < Self.stuckReleaseThreshold {
                    highCpuSince[key] = nil
                } else if let since = highCpuSince[key] {
                    // Hysteresis band: keep the streak alive, don't extend it.
                    stuck = now.timeIntervalSince(since) >= Self.stuckAfterSeconds
                }
            }
            return AppUsage(
                id: key, name: group.name, icon: group.icon,
                pid: group.pid, isQuittable: group.quittable,
                isRegularApp: group.regular,
                isStuck: stuck,
                cpu: cpu,
                ramBytes: Self.round(bytes: group.ram, to: 16 << 20)
            )
        }
        highCpuSince = highCpuSince.filter { groups[$0.key] != nil }

        return SystemStatsSnapshot(
            cpuUsage: totalDelta > 0 ? (busyDelta / totalDelta * 100).rounded() / 100 : 0,
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            ramUsedBytes: Self.round(bytes: ramUsed, to: 64 << 20),
            ramTotalBytes: ramTotal,
            memoryPressure: pressure,
            thermalState: ProcessInfo.processInfo.thermalState,
            cpuTemperature: readCPUTemperature().map { $0.rounded() },
            apps: apps
        )
    }

    private static func round(bytes: UInt64, to step: UInt64) -> UInt64 {
        (bytes + step / 2) / step * step
    }

    // MARK: - Raw readings

    private func readRaw() -> RawSample {
        var raw = RawSample()

        var cpuCount: natural_t = 0
        var infoPtr: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &infoPtr, &infoCount) == KERN_SUCCESS,
           let info = infoPtr {
            for cpu in 0..<Int(cpuCount) {
                let base = cpu * Int(CPU_STATE_MAX)
                let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
                let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
                let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
                let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
                raw.busyTicks += user + system + nice
                raw.totalTicks += user + system + nice + idle
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(UInt(infoCount) * UInt(MemoryLayout<integer_t>.size))
            )
        }

        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return raw }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for index in 0..<Int(max(filled, 0)) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            // Other users' processes fail with EPERM — skip them silently.
            guard status == 0 else { continue }
            raw.procCpuNs[pid] = Self.machToNs(usage.ri_user_time &+ usage.ri_system_time)
            // phys_footprint matches Activity Monitor's Memory column; plain
            // RSS over-counts shared pages.
            raw.procFootprint[pid] = usage.ri_phys_footprint
        }
        return raw
    }

    private func readMemory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total) }
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count))
            * UInt64(pageSize)
        return (used, total)
    }

    // MARK: - Process → app grouping

    private func groupIdentity(
        for pid: pid_t, guiApps: [pid_t: GUIApp]
    ) -> (key: String, name: String, icon: NSImage?, rootPid: pid_t?, quittable: Bool, regular: Bool) {
        if let (ownerPid, app) = owningApp(of: pid, guiApps: guiApps) {
            return ("app-\(ownerPid)", app.name, app.icon, ownerPid, !app.isSelf, app.isRegular)
        }
        let name = processName(pid) ?? "pid \(pid)"
        return ("proc-\(name)", name, nil, nil, false, false)
    }

    private func owningApp(of pid: pid_t, guiApps: [pid_t: GUIApp]) -> (pid_t, GUIApp)? {
        if let app = guiApps[pid] { return (pid, app) }
        if let lookup = Self.responsiblePid {
            let responsible = lookup(pid)
            if responsible > 0, responsible != pid, let app = guiApps[responsible] {
                return (responsible, app)
            }
        }
        var current = pid
        for _ in 0..<12 {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            if let app = guiApps[parent] { return (parent, app) }
            current = parent
        }
        return nil
    }

    private func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Temperature

    /// CPU die sensors, discovered once. Sensor names differ per chip
    /// generation (pACC/eACC on M-series); when none match we report nil and
    /// the UI falls back to thermal state only.
    private lazy var temperatureSensors: (client: CFTypeRef, services: [CFTypeRef])? = {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = IOHIDEventSystemClientSetMatching(client, matching)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() else { return nil }

        var cpuSensors: [CFTypeRef] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard let nameRef = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue(),
                  let name = nameRef as? String else { continue }
            // Sensor names differ per chip family: M1-era exposes
            // "pACC/eACC MTR Temp Sensor*", newer chips "PMU tdie*"
            // (die temperature; tcal/tdev are calibration/device sensors
            // and tdev1 reads a bogus negative value).
            let isCPUDie = name.contains("MTR Temp") && (name.hasPrefix("pACC") || name.hasPrefix("eACC"))
            let isSOC = name.hasPrefix("SOC MTR Temp")
            let isPMUDie = name.contains("tdie")
            if isCPUDie || isSOC || isPMUDie {
                cpuSensors.append(service)
            }
        }
        guard !cpuSensors.isEmpty else { return nil }
        // The services array owns the sensor refs; keep client + array alive.
        return (client, cpuSensors)
    }()

    private func readCPUTemperature() -> Double? {
        guard let sensors = temperatureSensors else { return nil }
        var readings: [Double] = []
        for service in sensors.services {
            guard let event = IOHIDServiceClientCopyEvent(service, kHIDEventTypeTemperature, 0, 0)?
                .takeRetainedValue() else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(kHIDEventTypeTemperature << 16))
            if value > 0, value < 130 {
                readings.append(value)
            }
        }
        guard !readings.isEmpty else { return nil }
        return readings.reduce(0, +) / Double(readings.count)
    }
}

/// Owns the 2-second sampling loop and publishes snapshots to the view.
/// Sampling runs on a serial utility queue so the widget never blocks the
/// main thread; the goal is for the sampler itself to stay under 1% CPU.
@MainActor
final class SystemStatsModel: ObservableObject {
    enum SortMode { case cpu, ram }

    @Published private(set) var snapshot: SystemStatsSnapshot?
    @Published var sortMode: SortMode = .cpu

    private let sampler = SystemStatsSampler()
    private let queue = DispatchQueue(label: "com.overlaylens.systemstats", qos: .utility)
    private var timer: Timer?
    private var pressure: SystemStatsSnapshot.PressureLevel = .normal
    private var pressureSource: DispatchSourceMemoryPressure?

    // Fetching NSRunningApplication.icon is surprisingly expensive; rebuild
    // the app table only when the set of running pids actually changes, so
    // icon object identity also stays stable across ticks (which lets
    // snapshots compare equal).
    private var cachedGUIApps: [pid_t: SystemStatsSampler.GUIApp] = [:]
    private var cachedPids: Set<pid_t> = []

    var isRunning: Bool { timer != nil }

    /// While the widget is fully covered by other windows nobody sees it,
    /// but stuck-app detection still needs data — so instead of stopping we
    /// drop to a lazy 10-second pace (rendering is skipped anyway whenever
    /// the snapshot compares equal).
    private var isSlowPace = false

    func start() {
        guard timer == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, let source = self.pressureSource else { return }
            let event = source.data
            if event.contains(.critical) {
                self.pressure = .critical
            } else if event.contains(.warning) {
                self.pressure = .warning
            } else {
                self.pressure = .normal
            }
        }
        source.resume()
        pressureSource = source

        tick()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    func setSlowPace(_ slow: Bool) {
        guard isSlowPace != slow else { return }
        isSlowPace = slow
        guard timer != nil else { return }
        timer?.invalidate()
        if !slow {
            // Coming back into view: refresh right away, don't wait a beat.
            tick()
        }
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(
            withTimeInterval: isSlowPace ? 10 : 2, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // NSWorkspace must be read on the main thread; hand the sampler a
        // plain snapshot of the GUI apps instead.
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited
        }
        let pids = Set(running.map(\.processIdentifier))
        if pids != cachedPids {
            let ownPid = ProcessInfo.processInfo.processIdentifier
            var apps: [pid_t: SystemStatsSampler.GUIApp] = [:]
            for app in running {
                let pid = app.processIdentifier
                apps[pid] = cachedGUIApps[pid] ?? SystemStatsSampler.GUIApp(
                    name: app.localizedName ?? "App",
                    icon: app.icon,
                    isSelf: pid == ownPid,
                    isRegular: app.activationPolicy == .regular
                )
            }
            cachedGUIApps = apps
            cachedPids = pids
        }
        let guiApps = cachedGUIApps
        let pressure = self.pressure
        queue.async { [weak self] in
            guard let self else { return }
            let snap = self.sampler.sample(guiApps: guiApps, pressure: pressure)
            Task { @MainActor in
                if self.snapshot != snap {
                    self.snapshot = snap
                }
            }
        }
    }
}
