import AppKit
import SwiftUI

private let refreshInterval: TimeInterval = 2
private let tolerance: TimeInterval = 2

struct CronJob: Identifiable, Equatable {
    let id: String
    let title: String
    let schedule: String
    let command: String
    let matchTerms: [String]
    let logPath: String?
}

struct ProcessMatch: Identifiable, Equatable {
    let id = UUID()
    let pid: Int
    let elapsed: String
    let command: String
}

struct JobStatus: Identifiable, Equatable {
    let id: String
    let title: String
    let schedule: String
    let active: Bool
    let runningNow: Bool
    let lastLogUpdate: Date?
    let processes: [ProcessMatch]
}

struct StatusSnapshot: Equatable {
    var generatedAt = Date()
    var jobs: [JobStatus] = []
    var error: String?

    var activeCount: Int {
        jobs.filter(\.active).count
    }
}

@MainActor
final class CronMonitorModel: ObservableObject {
    @Published var snapshot = StatusSnapshot()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isRefreshing = false
    private var lastSeenByJobID: [String: Date] = [:]

    func start() {
        loadBundledSnapshot()
        refresh()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAfterWake()
                }
            }
        )

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    func refresh() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true

        Task {
            defer {
                isRefreshing = false
            }

            let now = Date()

            do {
                let liveCrontab = try await Shell.run("/usr/bin/crontab", ["-l"], allowExitOne: true)
                let crontab = liveCrontab.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? bundledCrontab()
                    : liveCrontab
                let cronJobs = crontab
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .compactMap { parseCronLine(String($0.element), index: $0.offset) }

                do {
                    let psOutput = try await Shell.run("/bin/ps", ["-axo", "pid,ppid,stat,etime,command"])
                    let processes = parseProcesses(psOutput)
                    snapshot = StatusSnapshot(
                        generatedAt: now,
                        jobs: statuses(for: cronJobs, processes: processes, now: now),
                        error: nil
                    )
                } catch {
                    snapshot = StatusSnapshot(
                        generatedAt: now,
                        jobs: statuses(for: cronJobs, processes: [], now: now),
                        error: "Process check failed"
                    )
                }
            } catch {
                let crontab = bundledCrontab()
                let cronJobs = crontab
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .compactMap { parseCronLine(String($0.element), index: $0.offset) }

                snapshot = StatusSnapshot(
                    generatedAt: Date(),
                    jobs: statuses(for: cronJobs, processes: [], now: now),
                    error: cronJobs.isEmpty ? error.localizedDescription : "Using bundled crontab"
                )
            }
        }
    }

    private func refreshAfterWake() {
        loadBundledSnapshot()
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func loadBundledSnapshot() {
        let now = Date()
        let cronJobs = bundledCrontab()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { parseCronLine(String($0.element), index: $0.offset) }

        if !cronJobs.isEmpty {
            snapshot = StatusSnapshot(
                generatedAt: now,
                jobs: statuses(for: cronJobs, processes: [], now: now),
                error: nil
            )
        }
    }

    private func statuses(for cronJobs: [CronJob], processes: [ProcessMatch], now: Date) -> [JobStatus] {
        cronJobs.map { job in
            let matches = matchingProcesses(for: job, in: processes)
            if !matches.isEmpty {
                lastSeenByJobID[job.id] = now
            }

            let lastSeen = lastSeenByJobID[job.id]
            let active = !matches.isEmpty || lastSeen.map { now.timeIntervalSince($0) <= tolerance } == true

            return JobStatus(
                id: job.id,
                title: job.title,
                schedule: job.schedule,
                active: active,
                runningNow: !matches.isEmpty,
                lastLogUpdate: lastModifiedDate(at: job.logPath),
                processes: matches
            )
        }
    }
}

func bundledCrontab() -> String {
    let embedded = embeddedCrontab()
    if !embedded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return embedded
    }

    let urls = [
        Bundle.main.url(forResource: "crontab", withExtension: "txt"),
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/crontab.txt"),
        CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/crontab.txt")
        },
    ]

    for url in urls.compactMap({ $0 }) {
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
            return text
        }
    }

    return ""
}

enum Shell {
    static func run(_ launchPath: String, _ arguments: [String], allowExitOne: Bool = false, timeout: TimeInterval = 1.5) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let errorOutput = Pipe()

            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errorOutput

            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            if process.isRunning {
                process.terminate()
                throw NSError(
                    domain: "CronMonitorDesktopWidget.Shell",
                    code: 124,
                    userInfo: [NSLocalizedDescriptionKey: "Command timed out: \(launchPath)"]
                )
            }

            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: errorOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            if process.terminationStatus != 0 && !(allowExitOne && process.terminationStatus == 1) {
                throw NSError(
                    domain: "CronMonitorDesktopWidget.Shell",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? "Command failed: \(launchPath)" : stderr]
                )
            }

            return stdout
        }.value
    }
}

func parseCronLine(_ line: String, index: Int) -> CronJob? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        return nil
    }

    if trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\s*="#, options: .regularExpression) != nil {
        return nil
    }

    let schedule: String
    let command: String

    if trimmed.hasPrefix("@") {
        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.count == 2 else {
            return nil
        }

        schedule = String(parts[0])
        command = String(parts[1])
    } else {
        let parts = trimmed.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 6 else {
            return nil
        }

        schedule = parts.prefix(5).joined(separator: " ")
        command = trimmed.dropFirst(schedule.count).trimmingCharacters(in: .whitespaces)
    }

    return CronJob(
        id: String("\(index):\(schedule):\(command)".hash, radix: 16),
        title: title(from: command),
        schedule: schedule,
        command: command,
        matchTerms: matchTerms(from: command),
        logPath: logPath(from: command)
    )
}

func title(from command: String) -> String {
    let scriptPattern = #"/[^\s;&|<>]+\.(?:py|sh|js|rb|pl|php|R|command|bash)"#
    if let range = command.range(of: scriptPattern, options: .regularExpression) {
        return URL(fileURLWithPath: String(command[range])).lastPathComponent
    }

    let redirectFree = command.components(separatedBy: ">>").first?
        .components(separatedBy: ">").first?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return redirectFree?.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? command
}

func matchTerms(from command: String) -> [String] {
    let tokens = shellishTokens(command)
    let scriptPattern = #"\.(?:py|sh|js|rb|pl|php|R|command|bash)$"#
    let scriptTerms = tokens.filter { token in
        token.range(of: scriptPattern, options: .regularExpression) != nil
    }

    if !scriptTerms.isEmpty {
        return scriptTerms.sorted { $0.count > $1.count }
    }

    let redirectFree = command
        .replacingOccurrences(of: #"\s(?:>{1,2}|2>|&>)\s+\S+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s2>&1\b"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return redirectFree.count >= 8 ? [redirectFree] : []
}

func logPath(from command: String) -> String? {
    guard let range = command.range(of: #"(?:>>|>|&>)\s*('[^']+'|"[^"]+"|[^\s]+)"#, options: .regularExpression) else {
        return nil
    }

    let fragment = String(command[range])
    guard let path = fragment.split(whereSeparator: \.isWhitespace).dropFirst().first else {
        return nil
    }

    return String(path).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
}

func lastModifiedDate(at path: String?) -> Date? {
    guard let path else {
        return nil
    }

    return (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
}

func shellishTokens(_ input: String) -> [String] {
    let pattern = #""([^"]*)"|'([^']*)'|([^\s]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return input.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    let nsInput = input as NSString
    let range = NSRange(location: 0, length: nsInput.length)

    return regex.matches(in: input, range: range).compactMap { match in
        for index in 1...3 {
            if match.range(at: index).location != NSNotFound {
                return nsInput.substring(with: match.range(at: index))
            }
        }

        return nil
    }
}

func parseProcesses(_ output: String) -> [ProcessMatch] {
    output
        .split(separator: "\n")
        .dropFirst()
        .compactMap { line in
            let pattern = #"^\s*(\d+)\s+\d+\s+\S+\s+(\S+)\s+(.+)$"#
            let lineText = String(line)
            guard
                let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: lineText, range: NSRange(location: 0, length: lineText.utf16.count)),
                match.numberOfRanges == 4
            else {
                return nil
            }

            let nsLine = lineText as NSString
            return ProcessMatch(
                pid: Int(nsLine.substring(with: match.range(at: 1))) ?? 0,
                elapsed: nsLine.substring(with: match.range(at: 2)),
                command: nsLine.substring(with: match.range(at: 3))
            )
        }
}

func matchingProcesses(for job: CronJob, in processes: [ProcessMatch]) -> [ProcessMatch] {
    processes.filter { process in
        !process.command.contains("ps -axo pid,ppid,stat,etime,command")
            && job.matchTerms.contains { process.command.contains($0) }
    }
}

struct ContentView: View {
    @ObservedObject var model: CronMonitorModel
    @State private var isHoveringHeader = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.22),
                    Color.white.opacity(0.07),
                    Color.black.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            VStack(spacing: 12) {
                header
                jobList
            }
            .padding(16)
        }
        .frame(width: 360, height: 360)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 28, y: 14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Cron Jobs")
                    .font(.system(size: 16, weight: .semibold))
                Text("Updated \(model.snapshot.generatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(model.snapshot.error == nil ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: (model.snapshot.error == nil ? Color.green : Color.red).opacity(0.45), radius: 4)

                Text("\(model.snapshot.activeCount)/\(model.snapshot.jobs.count) running")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .clipShape(Capsule())

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHoveringHeader ? 0.72 : 0)
            .help("Quit")
        }
        .onHover { isHoveringHeader = $0 }
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if model.snapshot.jobs.isEmpty {
                    Text(model.snapshot.error ?? "No cron jobs found.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                } else {
                    ForEach(model.snapshot.jobs) { job in
                        JobRow(job: job)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct JobRow: View {
    let job: JobStatus

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: job.active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(job.active ? Color.green : Color.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(job.schedule)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(lastLogText)
                        .font(.system(size: 11, weight: .medium))
                }
                .lineLimit(1)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(job.runningNow ? "Running" : job.active ? "Recent" : "Idle")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((job.active ? Color.green : Color.secondary).opacity(0.12))
                .foregroundStyle(job.active ? Color.green : Color.secondary)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var lastLogText: String {
        guard let date = job.lastLogUpdate else {
            return "no log"
        }

        return "log \(date.formatted(date: .omitted, time: .shortened))"
    }
}

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = CronMonitorModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView(model: model)
        let hostingView = NSHostingView(rootView: contentView)
        let window = WidgetWindow(
            contentRect: NSRect(x: 80, y: 140, width: 360, height: 360),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        window.contentView = hostingView
        window.title = "Cron Jobs"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.level = .normal
        window.setFrameAutosaveName("CronMonitorDesktopWidgetGlass")
        window.makeKeyAndOrderFront(nil)

        self.window = window
        model.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

if CommandLine.arguments.contains("--dump-cron") {
    let crontab = bundledCrontab()
    let cronJobs = crontab
        .split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
        .compactMap { parseCronLine(String($0.element), index: $0.offset) }

    print("crontabCharacters=\(crontab.count)")
    print("cronJobs=\(cronJobs.count)")
    for job in cronJobs {
        print("\(job.schedule) \(job.title)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--dump-status") {
    let crontab = bundledCrontab()
    let cronJobs = crontab
        .split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
        .compactMap { parseCronLine(String($0.element), index: $0.offset) }
    let psOutput = (try? await Shell.run("/bin/ps", ["-axo", "pid,ppid,stat,etime,command"], timeout: 3)) ?? ""
    let processes = parseProcesses(psOutput)

    print("cronJobs=\(cronJobs.count)")
    for job in cronJobs {
        let matches = matchingProcesses(for: job, in: processes)
        print("\(job.title): matches=\(matches.count)")
        for match in matches.prefix(3) {
            print("  PID \(match.pid) \(match.elapsed) \(match.command)")
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
