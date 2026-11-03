import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// What a shelf card holds. Files ride along as-is; links go over as real web
/// URLs so the receiver gets something tappable; typed messages are written to
/// a .txt at send time because AirDrop refuses a bare string
/// (`canPerform(withItems: [NSString])` == false, while file/URL mixes are fine).
enum ShelfPayload: Equatable {
    case file(URL)
    case link(URL)
    case text(String)
}

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    /// Mutable so editing a message rewrites the card in place instead of
    /// dropping it to the end of the strip.
    var payload: ShelfPayload

    init(_ payload: ShelfPayload) { self.payload = payload }

    var fileURL: URL? {
        if case .file(let url) = payload { return url }
        return nil
    }

    var name: String {
        switch payload {
        case .file(let url): return url.lastPathComponent
        case .link(let url): return url.host ?? url.absoluteString
        case .text(let text): return text
        }
    }

    /// Full value, shown as the card tooltip.
    var detail: String {
        switch payload {
        case .file(let url): return url.path
        case .link(let url): return url.absoluteString
        case .text(let text): return text
        }
    }

    /// Cached: SwiftUI asks for this on every redraw of every card, and
    /// `NSWorkspace.icon(forFile:)` hits the disk each time it is asked.
    private static let iconCache = NSCache<NSString, NSImage>()

    var fileIcon: NSImage? {
        guard case .file(let url) = payload else { return nil }
        let key = url.path as NSString
        if let cached = Self.iconCache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        Self.iconCache.setObject(icon, forKey: key)
        return icon
    }
}

@MainActor
final class DropShelfModel: ObservableObject {
    private static let defaultsKey = "DropShelfItems"

    @Published private(set) var items: [ShelfItem] = [] {
        didSet {
            badgeHandler?(items.count)
            UserDefaults.standard.set(encoded, forKey: Self.defaultsKey)
        }
    }

    /// Lets the status item swap its icon when the shelf has files.
    var badgeHandler: ((Int) -> Void)?

    init() {
        items = Self.decode(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    // MARK: - Persistence

    private var encoded: [String] {
        items.map { item in
            switch item.payload {
            case .file(let url): return "file\t\(url.path)"
            case .link(let url): return "link\t\(url.absoluteString)"
            case .text(let text): return "text\t\(text)"
            }
        }
    }

    private static func decode(_ strings: [String]) -> [ShelfItem] {
        strings.compactMap { raw in
            let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                // Pre-links format: the entry was a bare file path.
                return fileItem(path: raw)
            }
            let value = String(parts[1])
            switch parts[0] {
            case "file": return fileItem(path: value)
            case "link": return URL(string: value).map { ShelfItem(.link($0)) }
            case "text": return value.isEmpty ? nil : ShelfItem(.text(value))
            default: return nil
            }
        }
    }

    private static func fileItem(path: String) -> ShelfItem? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return ShelfItem(.file(URL(fileURLWithPath: path)))
    }

    // MARK: - Adding

    private func add(_ payload: ShelfPayload) {
        guard !items.contains(where: { $0.payload == payload }) else { return }
        items.append(ShelfItem(payload))
    }

    func add(urls: [URL]) {
        for url in urls { add(.file(url)) }
    }

    /// Pasted, typed, or dragged-in text: a bare URL becomes a link card (sent
    /// as a real link), anything else becomes a message card.
    func addRaw(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = Self.soleLink(in: trimmed) {
            add(.link(url))
        } else {
            add(.text(trimmed))
        }
    }

    /// True only when the whole string *is* one link, so "ห้องเรียนวันนี้
    /// https://…" stays a message instead of losing its wording.
    private static func soleLink(in string: String) -> URL? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        let matches = detector.matches(in: string, range: range)
        guard matches.count == 1, matches[0].range == range else { return nil }
        return matches[0].url
    }

    /// Grabs whatever is on the clipboard — handy for a room link you just
    /// copied out of Meet/Zoom/Discord.
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            add(urls: urls)
            return
        }
        if let string = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string) {
            addRaw(string)
            return
        }
        if let data = pasteboard.data(forType: .png) {
            add(imageData: data, type: .png)
        } else if let data = pasteboard.data(forType: .tiff) {
            add(imageData: data, type: .tiff)
        }
    }

    /// ⌘V handler for the shelf panel: grabs copied files or a bitmap (e.g. a
    /// ⌃⇧⌘4 screenshot, which lands on the clipboard as PNG/TIFF only). Returns
    /// false when the clipboard holds plain text, so the compose field pastes it.
    @discardableResult
    func pasteFilesOrImageFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            add(urls: urls)
            return true
        }
        if let data = pasteboard.data(forType: .png) {
            add(imageData: data, type: .png)
            return true
        }
        if let data = pasteboard.data(forType: .tiff) {
            add(imageData: data, type: .tiff)
            return true
        }
        return false
    }

    /// Staging area for images dropped as raw data (web images, pasteboard
    /// bitmaps) and for promised files from apps like Photos. AirDrop can only
    /// send file URLs, so everything gets materialized here first. Lives in
    /// Application Support (not tmp) so shelf items survive relaunch/reboot.
    static let stagingDirectory: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("DropShelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Message cards are turned into .txt files here right before each send.
    private static let messageDirectory = stagingDirectory
        .appendingPathComponent("Messages", isDirectory: true)

    func add(imageData: Data, type: UTType, suggestedName: String? = nil) {
        var data = imageData
        var type = type
        // TIFF is what most apps put on the pasteboard; convert to PNG so the
        // receiving device gets a file it can actually open.
        if type == .tiff,
           let rep = NSBitmapImageRep(data: data),
           let png = rep.representation(using: .png, properties: [:]) {
            data = png
            type = .png
        }
        let ext = type.preferredFilenameExtension ?? "png"

        var base = (suggestedName as NSString?)?.deletingPathExtension ?? ""
        if base.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            base = "Image \(formatter.string(from: Date()))"
        }

        guard let url = Self.uniqueURL(in: Self.stagingDirectory, base: base, ext: ext),
              (try? data.write(to: url)) != nil
        else { return }
        add(urls: [url])
    }

    private static func uniqueURL(in dir: URL, base: String, ext: String) -> URL? {
        var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }

    /// Rewrites a message card after an inline edit. Clearing the text drops
    /// the card; pasting a bare link turns it into a link card, matching what
    /// `addRaw` would have done with the same string.
    func updateText(id: UUID, to newText: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            items.remove(at: index)
            return
        }
        if let url = Self.soleLink(in: trimmed) {
            items[index].payload = .link(url)
        } else {
            items[index].payload = .text(trimmed)
        }
    }

    // MARK: - Removing

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        item.fileURL.map(deleteStagedCopy)
    }

    func clear() {
        let urls = items.compactMap(\.fileURL)
        items.removeAll()
        urls.forEach(deleteStagedCopy)
    }

    /// Staged images are our own copies; remove them from disk when they
    /// leave the shelf. Files the user dragged in from elsewhere are untouched.
    private func deleteStagedCopy(_ url: URL) {
        guard url.path.hasPrefix(Self.stagingDirectory.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Sending

    /// Handed over by the controller: the shelf panel the AirDrop picker should
    /// anchor to, and a hook that tells the shelf when the picker is up.
    var sharingWindowProvider: (() -> NSWindow?)?
    var sharingStateHandler: ((Bool) -> Void)?
    /// `NSSharingService` holds its delegate unowned, so the send keeps it
    /// alive — losing it mid-share is what leaves the picker with no owner.
    private var sharingDelegate: ShelfSharingDelegate?

    var isSharing: Bool { sharingDelegate != nil }

    func airdrop() {
        guard !items.isEmpty,
              sharingDelegate == nil, // a picker is already up
              let service = NSSharingService(named: .sendViaAirDrop)
        else { return }

        // Last send's .txt files are safe to drop now (AirDrop has long since
        // read them); rebuilding the folder keeps stale messages from piling up.
        try? FileManager.default.removeItem(at: Self.messageDirectory)
        try? FileManager.default.createDirectory(
            at: Self.messageDirectory, withIntermediateDirectories: true
        )

        var payload: [Any] = []
        for item in items {
            switch item.payload {
            case .file(let url), .link(let url):
                payload.append(url)
            case .text(let text):
                if let url = Self.writeMessageFile(text) { payload.append(url) }
            }
        }

        guard !payload.isEmpty else { return }

        // `canPerform(withItems:)` used to gate this. It walks every item
        // synchronously on the main thread and stalls the UI before the picker
        // ever appears — and it can only answer "no" for payloads this shelf
        // never builds: file and web URLs are always sendable.

        let delegate = ShelfSharingDelegate(
            window: sharingWindowProvider?(),
            onFinish: { [weak self] in
                MainActor.assumeIsolated {
                    self?.sharingDelegate = nil
                    self?.sharingStateHandler?(false)
                }
            }
        )
        sharingDelegate = delegate
        service.delegate = delegate

        // Drop Shelf is an accessory app and the shelf floats at status-bar
        // level. Calling perform() straight from there opened AirDrop's own
        // window *behind* the shelf and without key focus, so clicks went
        // nowhere and the send looked frozen. Activate first, then let the
        // controller step the shelf out of the picker's way.
        sharingStateHandler?(true)
        NSApp.activate()
        service.perform(withItems: payload)
    }

    private static func writeMessageFile(_ text: String) -> URL? {
        // Name the file after its first line so the receiver can tell messages
        // apart in the AirDrop banner.
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var base = String(firstLine.prefix(40))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "ข้อความ" }

        guard let url = uniqueURL(in: messageDirectory, base: base, ext: "txt"),
              (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return url
    }
}

/// Anchors the AirDrop picker to the shelf window and reports when it closes so
/// the shelf can float back on top. Cancelling counts as closing: AppKit
/// reports that through `didFailToShareItems` with a cancellation error.
private final class ShelfSharingDelegate: NSObject, NSSharingServiceDelegate {
    private weak var window: NSWindow?
    private let onFinish: () -> Void
    private var finished = false

    init(window: NSWindow?, onFinish: @escaping () -> Void) {
        self.window = window
        self.onFinish = onFinish
    }

    func sharingService(
        _ service: NSSharingService,
        sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        sharingContentScope.pointee = .item
        return window
    }

    func sharingService(_ service: NSSharingService, didShareItems items: [Any]) {
        finish()
    }

    func sharingService(
        _ service: NSSharingService, didFailToShareItems items: [Any], error: Error
    ) {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }
}

/// Floating glass shelf: drop files in, add a link or a note, fire the whole
/// batch off via AirDrop.
struct DropShelfView: View {
    @ObservedObject var model: DropShelfModel
    var onClose: () -> Void
    /// Reports the laid-out size so the panel can shrink-wrap the shelf.
    var onMeasure: (CGSize) -> Void = { _ in }

    private struct SizeKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
            value = nextValue()
        }
    }

    @State private var isDropTargeted = false
    @AppStorage("DropShelfComposeDraft") private var draft = ""
    @AppStorage("DropShelfEditDrafts") private var storedEditDrafts = "{}"
    @State private var editingOriginal = ""
    @FocusState private var draftFocused: Bool
    /// Which message card the inline editor below the strip is showing.
    @State private var editingID: UUID?
    @State private var editingText = ""
    @FocusState private var editorFocused: Bool

    /// Drop zone first (it's what the shelf is for), composer and send below —
    /// the order the hand moves: drop, add a note, send.
    var body: some View {
        VStack(spacing: 14) {
            header

            if model.items.isEmpty {
                emptyDropZone
            } else {
                itemStrip
                messageEditor
            }

            if editingID == nil {
                composeRow
            } else {
                Button { closeEditor() } label: {
                    Label(draft.isEmpty ? "เขียนโน้ตใหม่" : "กลับไปฉบับร่างโน้ตใหม่", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .shelfButton()
            }

            if !model.items.isEmpty {
                actionBar
            }
        }
        .onChange(of: model.items) { _, items in
            // Removed, cleared, or turned into a link — nothing left to edit.
            if let editingID, !items.contains(where: {
                if case .text = $0.payload { return $0.id == editingID }
                return false
            }) {
                closeEditor()
            }
        }
        .animation(.spring(duration: 0.3, bounce: 0.15), value: editingID)
        .animation(.spring(duration: 0.35, bounce: 0.2), value: model.items.isEmpty)
        .animation(.spring(duration: 0.25, bounce: 0.3), value: isDropTargeted)
        .padding(18)
        .frame(width: 440)
        .shelfGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(14)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(SizeKey.self) { size in
            onMeasure(size)
        }
        .onDrop(of: [.fileURL, .image, .url, .plainText], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .font(.system(size: 14, weight: .medium))
        .controlSize(.large)
    }

    /// Files come in as file URLs; images dragged from a browser or another
    /// app arrive as raw image data and get staged to disk by the model; a
    /// dragged address bar or selected text becomes a link/message card.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add(urls: [url]) }
                }
            } else if let type = provider.registeredTypeIdentifiers
                .compactMap({ UTType($0) })
                .first(where: { $0.conforms(to: .image) }) {
                handled = true
                let name = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in model.add(imageData: data, type: type, suggestedName: name) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.addRaw(url.absoluteString) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string else { return }
                    Task { @MainActor in model.addRaw(string) }
                }
            }
        }
        return handled
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    LinearGradient(colors: [Color(red: 0.35, green: 0.68, blue: 1.0), Color(red: 0.0, green: 0.42, blue: 0.96)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 0) {
                Text("Drop Shelf")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.items.isEmpty ? "พักไฟล์ไว้ก่อน แล้วส่งทีเดียว" : "\(model.items.count) รายการ พร้อมส่ง")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .shelfGlass(Circle(), interactive: true)
            .help("ปิด Shelf — ฉบับร่างยังอยู่ (Esc)")
            .accessibilityLabel("ปิด Drop Shelf")
        }
    }

    /// Link / message composer — the shelf's answer to "ส่งลิงก์ห้องไปด้วย".
    /// One quiet line, Messages-style: paste on the left, send-arrow on the
    /// right. It grows with the text instead of reserving a big empty box.
    private var composeRow: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button {
                if model.pasteFilesOrImageFromClipboard() {
                    // copied files / screenshot went straight onto the shelf
                } else if let text = NSPasteboard.general.string(forType: .string),
                   !text.isEmpty {
                    draft += (draft.isEmpty ? "" : "\n") + text
                    draftFocused = true
                } else {
                    model.pasteFromClipboard()
                }
            } label: {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("วางลิงก์/ข้อความจากคลิปบอร์ด")
            .accessibilityLabel("วางจากคลิปบอร์ด")

            TextField("เพิ่มลิงก์ หรือโน้ต…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .focused($draftFocused)
                .padding(.vertical, 6)

            let canAdd = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: commitDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, canAdd ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: editingID == nil ? .command : [.command, .shift])
            .disabled(!canAdd)
            .help("เพิ่มลง Shelf (⌘↩) — ฉบับร่างเก็บไว้ให้อัตโนมัติ")
            .accessibilityLabel("เพิ่ม")
        }
        .padding(.leading, 4)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(draftFocused ? 0.07 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(draftFocused ? 0.14 : 0.07), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: draftFocused)
    }

    private func commitDraft() {
        model.addRaw(draft)
        draft = ""
        draftFocused = true
    }

    /// The shelf's hero: a big, calm target that lights up and lifts its icon
    /// the moment something is dragged over it.
    private var emptyDropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isDropTargeted)
                .frame(width: 64, height: 64)
                .shelfGlass(Circle(), tint: isDropTargeted ? Color.accentColor.opacity(0.25) : nil)
                .offset(y: isDropTargeted ? -3 : 0)
            VStack(spacing: 3) {
                Text(isDropTargeted ? "ปล่อยเพื่อพักไว้ตรงนี้" : "ลากไฟล์ รูป หรือลิงก์มาวาง")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("เขย่าเมาส์ตอนลาก Shelf จะตามมาหา · ⌃⌥⌘D")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 168)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.14),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.2, dash: isDropTargeted ? [] : [6, 5])
                )
        )
        .scaleEffect(isDropTargeted ? 1.015 : 1)
    }

    private var itemStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.items) { item in
                    ShelfItemCard(
                        item: item,
                        isEditing: item.id == editingID,
                        hasDraft: editDrafts[item.name] != nil,
                        onRemove: {
                            var drafts = editDrafts
                            drafts.removeValue(forKey: item.name)
                            persistEditDrafts(drafts)
                            model.remove(item)
                        },
                        onEdit: { beginEditing(item) }
                    )
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .frame(height: 118)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.8 : 0), lineWidth: 2)
                .padding(-4)
        )
    }

    /// Full text of the tapped message card, editable in place — a one-line
    /// truncated chip was no way to check what you were about to send.
    @ViewBuilder
    private var messageEditor: some View {
        if let id = editingID {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .foregroundStyle(.teal)
                    Text("แก้ไขข้อความ")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(editingText.count) ตัวอักษร")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                TextField("ข้อความ", text: Binding(
                    get: { editingText },
                    set: { value in
                        editingText = value
                        var drafts = editDrafts
                        drafts[editingOriginal] = value == editingOriginal ? nil : value
                        persistEditDrafts(drafts)
                    }
                ), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(3...8)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .focused($editorFocused)

                Text("เก็บฉบับร่างอัตโนมัติ · กดบันทึกเพื่อใช้ข้อความใหม่")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Button("คืนข้อความเดิม") {
                    editingText = editingOriginal
                    var drafts = editDrafts
                    drafts.removeValue(forKey: editingOriginal)
                    persistEditDrafts(drafts)
                }
                .buttonStyle(.borderless)
                .disabled(editingText == editingOriginal)

                HStack(spacing: 12) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(editingText, forType: .string)
                    } label: {
                        Label("คัดลอก", systemImage: "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("พักไว้") { closeEditor() }
                        .buttonStyle(.bordered)
                        .help("ปิดช่องแก้ไขและเก็บฉบับร่างไว้")

                    Button {
                        var drafts = editDrafts
                        drafts.removeValue(forKey: editingOriginal)
                        persistEditDrafts(drafts)
                        model.updateText(id: id, to: editingText)
                        closeEditor()
                    } label: {
                        Text("บันทึก")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("บันทึก (⌘⏎)")
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.teal.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private func beginEditing(_ item: ShelfItem) {
        guard case .text(let text) = item.payload else { return }
        if editingID == item.id {
            closeEditor()
            return
        }
        // Switching cards must not write the next note into the previous draft.
        editingID = nil
        editingOriginal = text
        editingText = editDrafts[text] ?? text
        editingID = item.id
        editorFocused = true
    }

    private var editDrafts: [String: String] {
        guard let data = storedEditDrafts.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    private func persistEditDrafts(_ drafts: [String: String]) {
        guard let data = try? JSONEncoder().encode(drafts), let value = String(data: data, encoding: .utf8) else { return }
        storedEditDrafts = value
    }

    private func closeEditor() {
        editingID = nil
        editingText = ""
        draftFocused = true
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
        if model.items.contains(where: { editDrafts[$0.name] != nil }) {
            Label("มีฉบับร่างที่ยังไม่บันทึก — เปิดการ์ดเพื่อแก้ต่อ", systemImage: "pencil.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        HStack(spacing: 10) {
            Button {
                persistEditDrafts([:])
                model.clear()
            } label: {
                Label("ล้าง", systemImage: "trash")
                    .font(.system(size: 13, weight: .semibold))
            }
            .shelfButton()

            Spacer()

            Button {
                model.airdrop()
            } label: {
                Label("ส่งผ่าน AirDrop", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 6)
            }
            .shelfButton(prominent: true)
            .disabled(model.items.contains(where: { editDrafts[$0.name] != nil }))
            .help("บันทึกหรือคืนข้อความเดิมของฉบับร่างก่อนส่ง")
        }
        }
    }
}

private struct ShelfItemCard: View {
    let item: ShelfItem
    var isEditing = false
    var hasDraft = false
    var onRemove: () -> Void
    var onEdit: () -> Void = {}

    @State private var hovering = false

    private var messageText: String? {
        if case .text(let text) = item.payload { return text }
        return nil
    }

    var body: some View {
        Group {
            if let messageText {
                Button(action: onEdit) { messageCard(messageText) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("แก้ไขโน้ต \(messageText)")
            } else {
                standardCard
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isEditing ? Color.teal : Color.primary.opacity(0.06), lineWidth: isEditing ? 1.5 : 1)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(4)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("เอาออกจาก Shelf")
            }
        }
        .scaleEffect(hovering ? 1.03 : 1)
        .help(messageText == nil ? item.detail : "คลิกเพื่อดู/แก้ไขข้อความ")
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.22, bounce: 0.25), value: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private var standardCard: some View {
        VStack(spacing: 5) {
            thumbnail
                .frame(width: 56, height: 56)
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80)
        }
    }

    /// Messages show their opening lines instead of one middle-truncated chip,
    /// so the shelf is readable before you tap into the editor.
    private func messageCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.teal)
                if hasDraft {
                    Text("ฉบับร่าง").font(.system(size: 11, weight: .semibold))
                }
                Spacer(minLength: 0)
                Image(systemName: isEditing ? "pencil.circle.fill" : "pencil")
                    .font(.caption2)
                    .foregroundStyle(isEditing ? Color.teal : Color.secondary)
                    .opacity(1)
            }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .frame(width: 160, height: 78, alignment: .topLeading)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.payload {
        case .file(let url):
            FileThumbnail(url: url, fallback: item.fileIcon)
        case .link:
            Image(systemName: "link")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    LinearGradient(colors: [Color(red: 0.35, green: 0.68, blue: 1.0), Color(red: 0.0, green: 0.42, blue: 0.96)],
                                   startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        case .text:
            EmptyView()
        }
    }
}

/// Real preview for photos, PDFs and documents (Quick Look), the Finder icon
/// until it arrives or when there is none.
private struct FileThumbnail: View {
    let url: URL
    let fallback: NSImage?
    @State private var preview: NSImage?

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            } else if let fallback {
                Image(nsImage: fallback).resizable()
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 112, height: 112),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                preview = rep.nsImage
            }
        }
    }
}

extension View {
    /// Liquid Glass on macOS 26+, frosted material before it.
    @ViewBuilder
    func shelfGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            self.glassEffect(interactive ? base.interactive() : base, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func shelfButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
        }
    }
}
