import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// ⌃⌥⌘F or the menu row: a Spotlight-style box in the middle of the screen
/// with every project's next step. Replaces the old floating panel, which
/// hid behind Settings and never got used.
///
/// The panel takes key focus without activating StampLab, so the app the
/// user was in stays frontmost and typing goes straight into the search
/// field. It goes away on Esc, on a click anywhere else (losing key), or
/// once ทำต่อ has opened the AI app.
@MainActor
final class FinishEngineSpotlight: NSObject, NSWindowDelegate {
    let model: FinishEngineModel
    let state: FinishEngineSpotlightState
    private var panel: SpotlightPanel?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    /// Last app other than StampLab to come to the front: opened from the
    /// menu row, StampLab itself may be frontmost by then.
    private var lastOtherApp: NSRunningApplication?
    private var isShown = false
    private var hideCount = 0

    /// Card size from mockups.html#C: 58 search + 300 columns + 38 footer.
    static let size = NSSize(width: 700, height: 396)

    override init() {
        let model = FinishEngineModel()
        self.model = model
        state = FinishEngineSpotlightState(model: model)
        super.init()
        state.onClose = { [weak self] in self?.hide() }
        model.start()

        let own = Bundle.main.bundleIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != own {
            lastOtherApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app.bundleIdentifier != own else { return }
                self?.lastOtherApp = app
            }
        }
    }

    var isVisible: Bool { isShown }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        guard !isShown else { return }
        // Read what the user is looking at before anything of ours appears.
        let guess = guessProject()
        model.refreshIfStale()
        state.prepareForShow(guess: guess)

        let panel = ensurePanel()
        panel.setFrame(frameOnMouseScreen(), display: false)
        panel.alphaValue = 0
        isShown = true
        panel.orderFrontRegardless()
        panel.makeKey()
        installKeyMonitor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown else { return }
            self.state.markAppeared()
            self.state.requestFocus(.search)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.focusSearchFieldIfNeeded()
        }
        // The window shadow follows the card's shape; recompute it once the
        // scale-in has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.panel?.invalidateShadow()
        }
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        removeKeyMonitor()
        hideCount += 1
        let count = hideCount
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Reopened during the fade: leave it up.
                guard let self, self.hideCount == count, !self.isShown else { return }
                panel.orderOut(nil)
            }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // MARK: Window

    private func ensurePanel() -> SpotlightPanel {
        if let panel { return panel }
        let panel = SpotlightPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Native window shadow: it follows the rounded card (transparent corners).
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        // We decide when it goes away (Esc / click elsewhere / ทำต่อ).
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.state.escape() }

        let host = NSHostingView(rootView: FinishEngineSpotlightView(model: model, state: state))
        // Fixed-size card; don't let SwiftUI's preferred size fight the frame.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Centred on the screen with the pointer, top edge ~22% down (where
    /// Spotlight sits), kept inside the visible area.
    private func frameOnMouseScreen() -> NSRect {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(origin: .zero, size: Self.size)
        }
        let full = screen.frame
        let visible = screen.visibleFrame
        var origin = NSPoint(x: full.midX - Self.size.width / 2,
                             y: full.maxY - full.height * 0.22 - Self.size.height)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - Self.size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - Self.size.height - 8)
        return NSRect(origin: origin, size: Self.size)
    }

    /// SwiftUI's focus request normally lands; if the field still isn't
    /// first responder (first show of a fresh panel), hand it focus directly.
    private func focusSearchFieldIfNeeded() {
        guard isShown, let panel, !(panel.firstResponder is NSTextView),
              let field = Self.firstTextField(in: panel.contentView) else { return }
        panel.makeFirstResponder(field)
    }

    private static func firstTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) { return field }
        }
        return nil
    }

    // MARK: Keyboard

    /// ↑/↓, ⏎ and Esc are caught before the text field sees them, so they
    /// work while typing; ⌘N / ⌘D / ⌘Z before the menu bar does. Keys go by
    /// key code, so a Thai keyboard layout behaves the same.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isShown, let panel = self.panel, event.window === panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        // An input method mid-composition (e.g. Japanese) needs these keys.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let inStepField = state.focusedField == .step
        switch Int(event.keyCode) {
        case kVK_UpArrow where modifiers.isEmpty && !inStepField:
            state.move(-1)
        case kVK_DownArrow where modifiers.isEmpty && !inStepField:
            state.move(1)
        case kVK_Return where modifiers.isEmpty, kVK_ANSI_KeypadEnter where modifiers.isEmpty:
            state.primary()
        case kVK_Escape:
            state.escape()
        case kVK_ANSI_N where modifiers == .command:
            state.startCreate()
        case kVK_ANSI_D where modifiers == .command:
            state.markDone()
        case kVK_ANSI_Z where modifiers == .command && state.undo != nil:
            state.undoDone()
        default:
            return false
        }
        return true
    }

    // MARK: Guess

    /// The one smart touch: preselect the project named in the chat or
    /// window the user was just in.
    private func guessProject() -> FinishEngineSpotlightState.Guess? {
        var app = NSWorkspace.shared.frontmostApplication
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { app = lastOtherApp }
        guard let app else { return nil }
        let source: FinishEngineSpotlightState.Guess.Source
        let title: String?
        if app.bundleIdentifier == FinishEngineContext.claudeBundleID {
            source = .chat
            title = FinishEngineContext.latestClaudeChatTitle()
        } else {
            source = .window
            title = FinishEngineContext.focusedWindowTitle(of: app)
        }
        guard let title, let project = FinishEngineBoard.guess(in: title, among: model.projects) else { return nil }
        return .init(project: project.name, source: source, title: title)
    }
}

/// Borderless panel that can take key focus (borderless windows can't by
/// default) but never becomes main.
final class SpotlightPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Backstop for Esc if the key monitor didn't take it.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// What the box shows and does: search, selection, create, ✓ with undo.
/// Shared by the SwiftUI view and the panel's keyboard handling.
@MainActor
final class FinishEngineSpotlightState: ObservableObject {
    enum Row: Hashable {
        case project(String)
        case create
    }

    enum Field: Hashable {
        case search, step
    }

    struct Guess: Equatable {
        enum Source { case chat, window }
        let project: String
        let source: Source
        let title: String
    }

    struct Undo: Equatable {
        let id = UUID()
        let task: FinishEngineTask
        let previous: String
    }

    /// A first step Notion refused to save, kept so it isn't lost.
    struct UnsavedStep: Equatable {
        let step: String
        let message: String
    }

    let model: FinishEngineModel
    var onClose: () -> Void = {}

    @Published private(set) var query = ""
    @Published private(set) var selection: Row?
    @Published private(set) var createMode = false
    @Published var stepText = ""
    @Published private(set) var guess: Guess?
    @Published private(set) var undo: Undo?
    @Published private(set) var isCreating = false
    @Published private(set) var createProblem: String?
    @Published private(set) var isLaunching = false
    @Published private(set) var unsavedSteps: [String: UnsavedStep] = [:]
    @Published private(set) var appeared = false
    @Published private(set) var focusToken = 0
    private(set) var focusTarget: Field = .search
    /// Mirrored from the view's focus, for the keyboard handler.
    var focusedField: Field?

    /// Selection from before the user started typing, restored when the
    /// search is cleared.
    private var stashedSelection: Row?
    private var undoTimer: Task<Void, Never>?
    private var launchTimer: Task<Void, Never>?

    init(model: FinishEngineModel) {
        self.model = model
    }

    // MARK: Derived

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var visibleProjects: [FinishEngineProject] {
        FinishEngineBoard.filter(model.projects, query: query)
    }

    /// "＋ สร้างโปรเจกต์ …" when the search names no existing project (or
    /// after ⌘N).
    var showsCreateRow: Bool {
        (createMode || !trimmedQuery.isEmpty) && !FinishEngineBoard.hasExactName(model.projects, trimmedQuery)
    }

    var rows: [Row] {
        visibleProjects.map { .project($0.name) } + (showsCreateRow ? [.create] : [])
    }

    /// The highlighted row; falls back to the first one when the selection
    /// is filtered out or gone after a refresh.
    var current: Row? {
        let rows = rows
        if let selection, rows.contains(selection) { return selection }
        return rows.first
    }

    var currentProject: FinishEngineProject? {
        guard case .project(let name)? = current else { return nil }
        return model.projects.first { $0.name == name }
    }

    // MARK: Opening

    func prepareForShow(guess: Guess?) {
        query = ""
        createMode = false
        stepText = ""
        createProblem = nil
        isLaunching = false
        undo = nil
        stashedSelection = nil
        appeared = false
        self.guess = guess
        if let guess {
            selection = .project(guess.project)
        } else if let saved = UserDefaults.standard.string(forKey: FinishEngineModel.selectedKey),
                  model.projects.contains(where: { $0.name == saved }) {
            selection = .project(saved)
        } else {
            selection = nil
        }
    }

    func markAppeared() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { appeared = true }
    }

    func requestFocus(_ field: Field) {
        focusTarget = field
        focusToken += 1
    }

    // MARK: Search and selection

    func setQuery(_ new: String) {
        guard new != query else { return }
        if query.isEmpty, !new.isEmpty { stashedSelection = selection }
        query = new
        createProblem = nil
        if createMode {
            selection = .create
        } else {
            // Typing re-selects the top match; clearing brings back the pick.
            selection = new.isEmpty ? stashedSelection : nil
        }
    }

    func select(_ row: Row) {
        selection = row
        if case .project(let name) = row { remember(name) }
    }

    /// Mouse: one click selects; typing keeps going in the right field.
    func click(_ row: Row) {
        select(row)
        guard row == .create else {
            requestFocus(.search)
            return
        }
        // The first-step field only exists once the create form is drawn.
        DispatchQueue.main.async { [weak self] in self?.requestFocus(.step) }
    }

    func move(_ delta: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let index = current.flatMap { rows.firstIndex(of: $0) } ?? 0
        select(rows[min(max(index + delta, 0), rows.count - 1)])
    }

    /// First Esc leaves create mode / clears the search; the next one closes.
    func escape() {
        if createMode || current == .create || !query.isEmpty {
            createMode = false
            stepText = ""
            createProblem = nil
            query = ""
            selection = stashedSelection
            requestFocus(.search)
            return
        }
        onClose()
    }

    // MARK: Actions

    /// ⏎: ทำต่อ on the next step, plan a project with nothing open, or —
    /// on the create row — go to the first-step field, then create. Two
    /// presses on purpose: a single ⏎ on a typo must not add a project.
    func primary() {
        switch current {
        case .create?:
            if focusedField != .step && !trimmedQuery.isEmpty {
                requestFocus(.step)
            } else {
                create()
            }
        case .project(_)?:
            guard let project = currentProject else { return }
            if let task = project.nextTask {
                continueWork(project, task)
            } else {
                planFirstSteps(project)
            }
        case nil:
            NSSound.beep()
        }
    }

    func continueWork(_ project: FinishEngineProject, _ task: FinishEngineTask) {
        guard !isLaunching else { return }
        remember(project.name)
        isLaunching = true
        launchTimer?.cancel()
        // claimAndContinue doesn't call back when it stops early (another AI
        // holds the task and the user cancels, or the task turned out Done).
        launchTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.isLaunching = false
        }
        model.claimAndContinue(project: project.name, ai: project.ai, task: task) { [weak self] in
            self?.isLaunching = false
            self?.onClose()
        }
    }

    /// Nothing open: copy a planning prompt (3–5 first steps with DoD,
    /// recorded in Finish Engine) and open the project's AI.
    func planFirstSteps(_ project: FinishEngineProject) {
        remember(project.name)
        let prompt = FinishEngineBoard.planningPrompt(for: project, idea: unsavedSteps[project.name]?.step)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        FinishEngineModel.continueInChat(project: project.name, ai: project.ai)
        onClose()
    }

    /// ✓ / ⌘D on the selected project's next step, undoable for 5 seconds.
    func markDone() {
        guard let project = currentProject, let task = project.nextTask else {
            NSSound.beep()
            return
        }
        remember(project.name)
        model.setStatus(task, to: "Done")
        let item = Undo(task: task, previous: task.status)
        undo = item
        undoTimer?.cancel()
        undoTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.undo?.id == item.id else { return }
            self?.undo = nil
        }
    }

    func undoDone() {
        guard let item = undo else { return }
        undo = nil
        undoTimer?.cancel()
        model.setStatus(item.task, to: item.previous)
    }

    func startCreate() {
        createMode = true
        createProblem = nil
        if query.isEmpty { stashedSelection = selection }
        selection = .create
        requestFocus(.search)
    }

    func create() {
        guard !isCreating else { return }
        let name = trimmedQuery
        if let problem = FinishEngineBoard.problem(withNewName: name, existing: model.projects) {
            createProblem = problem
            requestFocus(.search)
            return
        }
        let step = stepText.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreating = true
        createProblem = nil
        Task {
            let outcome = await model.createProject(name: name, firstStep: step)
            isCreating = false
            switch outcome {
            case .failed(let message):
                createProblem = message
            case .created, .stepNotSaved:
                if case .stepNotSaved(let message) = outcome {
                    unsavedSteps[name] = UnsavedStep(step: step, message: message)
                }
                createMode = false
                stepText = ""
                query = ""
                stashedSelection = nil
                select(.project(name))
                requestFocus(.search)
            }
        }
    }

    /// "บันทึกอีกครั้ง" after the integration got Insert content.
    func retryStep(for project: String) {
        guard let unsaved = unsavedSteps[project], !isCreating else { return }
        isCreating = true
        Task {
            let code = await model.addTask(unsaved.step, to: project)
            isCreating = false
            if let code {
                unsavedSteps[project] = UnsavedStep(step: unsaved.step, message: FinishEngineModel.message(for: code))
            } else {
                unsavedSteps[project] = nil
            }
        }
    }

    private func remember(_ name: String) {
        UserDefaults.standard.set(name, forKey: FinishEngineModel.selectedKey)
    }
}

/// Reads what the user was looking at when the box opened.
@MainActor
enum FinishEngineContext {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// The Claude app's window title is only "Claude", so the chat comes from
    /// StampLab's own session files (written by its Claude Code hooks): the
    /// most recently updated session, titled by the last custom-title line
    /// of its transcript.
    static func latestClaudeChatTitle() -> String? {
        let fm = FileManager.default
        let sessions = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StampLab/claude-sessions", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var latest: (id: String, updated: Double)?
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            var updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            if let data = try? Data(contentsOf: file),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let stamp = json["updated"] as? Double {
                updated = stamp
            }
            if latest.map({ updated > $0.updated }) ?? true { latest = (id, updated) }
        }
        guard let id = latest?.id else { return nil }

        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        guard let folders = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for folder in folders {
            let transcript = folder.appendingPathComponent("\(id).jsonl")
            guard fm.fileExists(atPath: transcript.path) else { continue }
            // The title line is re-written near the end; look further back
            // only if it isn't in the last 512 KB.
            for bytes in [512 * 1024, 4 * 1024 * 1024] {
                guard let (tail, isWholeFile) = readTail(of: transcript, bytes: bytes) else { break }
                if let title = FinishEngineBoard.customTitle(inTranscriptTail: tail) { return title }
                if isWholeFile { break }
            }
            return nil
        }
        return nil
    }

    private static func readTail(of url: URL, bytes: Int) -> (Data, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (data, start == 0)
    }

    /// Focused window's title through Accessibility. Quietly nil when
    /// StampLab isn't trusted (the box never asks for the permission).
    static func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not hold the box up.
        AXUIElementSetMessagingTimeout(element, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
              let text = title as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
