import AppKit
import SwiftUI

struct ShelfView: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject private var thumbs = Thumbnails.shared
    @State private var pileHover = false

    var body: some View {
        ZStack {
            if shelf.expanded {
                DetailView(shelf: shelf)
                    .transition(.opacity)
            } else {
                compact
                    .transition(.opacity)
            }
            if shelf.isTargeted {
                RoundedRectangle(cornerRadius: ShelfContainerView.cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: shelf.expanded)
        .animation(.easeOut(duration: 0.12), value: shelf.isTargeted)
    }

    // MARK: Compact shelf

    private var compact: some View {
        VStack(spacing: 0) {
            TopBar(shelf: shelf, leading: .close)
            ZStack {
                if shelf.showInstantActions {
                    InstantActionsGrid(shelf: shelf)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                } else if shelf.items.isEmpty {
                    Text("Drop files here")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(WindowDragArea())
                } else {
                    pile
                }
                if let busy = shelf.busy {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                        .help(busy)
                }
            }
            .animation(.easeOut(duration: 0.15), value: shelf.showInstantActions)
            bottomBar
        }
    }

    private var pile: some View {
        Pile(items: Array(shelf.items.suffix(pileHover ? 5 : 3)), thumbs: thumbs, fanned: pileHover)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onPanelHover { pileHover = $0 && shelf.items.count > 1 }
            .overlay(
                DragSource(
                    items: { shelf.items },
                    onClick: { _ in shelf.expanded = true },
                    onDoubleClick: { shelf.controller?.quickLook() },
                    menu: { shelf.controller?.actionsMenu() },
                    onDragEnded: { shelf.controller?.dragEnded($0, operation: $1) })
            )
            .help("Drag to move everything · click for details")
    }

    @ViewBuilder private var bottomBar: some View {
        ZStack {
            if shelf.showInstantActions {
                Pill(text: "Instant Actions")
            } else if !shelf.items.isEmpty {
                Button {
                    shelf.expanded = true
                } label: {
                    Pill(
                        text: Metadata.title(for: shelf.items),
                        dot: shelf.colorIndex == 0 ? nil : ShelfColor.color(shelf.colorIndex),
                        trailingSymbol: "chevron.down.circle.fill")
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                if shelf.items.isEmpty && !shelf.showInstantActions {
                    BoltButton(shelf: shelf)
                }
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    enum Leading { case close, back }
    @ObservedObject var shelf: Shelf
    let leading: Leading
    var title: String? = nil

    var body: some View {
        ZStack {
            WindowDragArea(
                onDoubleClick: { shelf.controller?.renameShelf() },
                menu: { shelf.controller?.actionsMenu() })
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 44)
                    .allowsHitTesting(false)
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 28, height: 4)
                    .allowsHitTesting(false)
            }
            HStack {
                switch leading {
                case .close:
                    CircleButton(symbol: "xmark", help: "Close shelf") { shelf.controller?.closeShelf() }
                case .back:
                    CircleButton(symbol: "chevron.left", help: "Back") { shelf.expanded = false }
                }
                Spacer()
                CircleButton(symbol: "ellipsis", help: "Actions") { shelf.controller?.showActionsMenu() }
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 9)
        .padding(.top, 9)
        .padding(.bottom, 4)
    }
}

private struct CircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onPanelHover { hover = $0 }
        .help(help)
    }
}

private struct Pill: View {
    let text: String
    var dot: Color? = nil
    var trailingSymbol: String? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, dot == nil ? 9 : 7)
        .padding(.trailing, trailingSymbol == nil ? 9 : 4)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(hover ? 0.16 : 0.1)))
        .frame(maxWidth: 150)
        .onPanelHover { hover = $0 }
    }
}

// MARK: - Pile of thumbnails

private struct Pile: View {
    let items: [ShelfItem]
    let thumbs: Thumbnails
    var fanned = false

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Card(item: item, image: thumbs.image(for: item), framed: item.isImage && thumbs.hasPreview(for: item))
                    .scaleEffect(fanned ? 0.72 : 1 - CGFloat(depth(index)) * 0.04)
                    .rotationEffect(.degrees(angle(index)), anchor: fanned ? .bottom : .center)
                    .offset(offset(index))
                    .zIndex(Double(index))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: fanned)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: items.map(\.id))
    }

    private func depth(_ index: Int) -> Int { items.count - 1 - index }  // 0 = top card
    /// Position relative to the middle of the fan, from -2 to 2.
    private func spread(_ index: Int) -> CGFloat { CGFloat(index) - CGFloat(items.count - 1) / 2 }

    private func angle(_ index: Int) -> Double {
        if fanned { return Double(spread(index)) * 9 }
        switch depth(index) {
        case 0: return 0
        case 1: return -7
        default: return 6
        }
    }

    private func offset(_ index: Int) -> CGSize {
        if fanned {
            let s = spread(index)
            return CGSize(width: s * 30, height: abs(s) * 5)
        }
        switch depth(index) {
        case 0: return .zero
        case 1: return CGSize(width: -5, height: -2)
        default: return CGSize(width: 6, height: -4)
        }
    }
}

private struct Card: View {
    let item: ShelfItem
    let image: NSImage
    let framed: Bool

    var body: some View {
        Group {
            if framed {
                // Photo-print look: white border and a soft shadow.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(3)
                    .background(Color.white)
                    .frame(maxWidth: 104, maxHeight: 92)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
            } else if item.kind == .text {
                Text(item.text ?? "")
                    .font(.system(size: 6.5))
                    .foregroundStyle(.black.opacity(0.75))
                    .frame(width: 66, height: 84, alignment: .topLeading)
                    .padding(6)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
            } else {
                Image(nsImage: item.kind == .link ? AppIcons.browser : image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 92, height: 92)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1.5)
            }
        }
        .opacity(item.exists ? 1 : 0.4)
    }
}

// MARK: - Instant Actions

enum AppIcons {
    private static func icon(path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
    private static func icon(bundle: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static let airDrop = icon(path: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
    static let messages = icon(bundle: "com.apple.MobileSMS")
    static let mail = icon(bundle: "com.apple.mail")
    static let archive = icon(path: "/System/Library/CoreServices/Applications/Archive Utility.app")
    static let browser: NSImage = {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://apple.com")!) else { return NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()
}

private struct InstantActionsGrid: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Tile(icon: AppIcons.messages, title: "Messages") { shelf.controller?.instant(.messages, $0) }
                Tile(icon: AppIcons.airDrop, title: "AirDrop") { shelf.controller?.instant(.airDrop, $0) }
            }
            GridRow {
                Tile(icon: AppIcons.mail, title: "Mail") { shelf.controller?.instant(.mail, $0) }
                Tile(icon: AppIcons.archive, title: "Compress") { shelf.controller?.instant(.zip, $0) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private struct Tile: View {
        let icon: NSImage
        let title: String
        let action: ([ShelfItem]) -> Void
        @State private var hovering = false

        var body: some View {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(hovering ? Color.accentColor : Color.primary.opacity(0.08))
                )
                .overlay(DropZone(onHover: { hovering = $0 }, onDrop: action))
                .help(title)
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

/// Small lightning button; dragging over (or clicking) it reveals Instant Actions.
private struct BoltButton: View {
    @ObservedObject var shelf: Shelf
    @State private var hovering = false

    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovering ? Color.white : Color.secondary)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.accentColor : Color.primary.opacity(0.1))
            )
            .overlay(
                DropZone(
                    onHover: { inside in
                        hovering = inside
                        if inside { shelf.showInstantActions = true }
                    }, onDrop: { shelf.add($0) })
            )
            .onTapGesture { shelf.showInstantActions = true }
            .help("Instant Actions")
    }
}

// MARK: - Detail view

private struct DetailView: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject private var thumbs = Thumbnails.shared

    var body: some View {
        VStack(spacing: 0) {
            TopBar(shelf: shelf, leading: .back, title: shelf.name.isEmpty ? Metadata.title(for: shelf.items) : shelf.name)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(shelf.items.enumerated()), id: \.element.id) { index, item in
                        let renaming = shelf.renamingID == item.id
                        Row(
                            item: item,
                            image: item.kind == .link ? AppIcons.browser : thumbs.image(for: item),
                            selected: shelf.selection.contains(item.id),
                            renaming: renaming,
                            onCommit: { shelf.controller?.commitRename(item, to: $0) },
                            onCancel: { shelf.renamingID = nil }
                        )
                        .overlay {
                            if !renaming {
                                DragSource(
                                    items: { shelf.controller?.itemsForDrag(startingAt: item) ?? [item] },
                                    onClick: { shelf.controller?.click(item, modifiers: $0) },
                                    onDoubleClick: { shelf.controller?.open(item) },
                                    menu: { shelf.controller?.menu(for: item) },
                                    onDragEnded: { shelf.controller?.dragEnded($0, operation: $1) })
                            }
                        }
                        .overlay(alignment: .top) {
                            if shelf.dropIndex == index { InsertionLine().offset(y: -1.5) }
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: RowFramesKey.self, value: [item.id: geo.frame(in: .global)])
                            })
                    }
                    if shelf.dropIndex == shelf.items.count { InsertionLine() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .onPreferenceChange(RowFramesKey.self) { shelf.rowFrames = $0 }
                .animation(.spring(duration: 0.3), value: shelf.items.map(\.id))
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { shelf.selection = [] })
            Divider().opacity(0.5)
            HStack {
                Text(
                    shelf.selection.isEmpty
                        ? "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")"
                        : "\(shelf.selection.count) of \(shelf.items.count) selected"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer()
                if let busy = shelf.busy {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
    }

    private struct Row: View {
        let item: ShelfItem
        let image: NSImage
        let selected: Bool
        var renaming = false
        var onCommit: (String) -> Void = { _ in }
        var onCancel: () -> Void = {}
        @State private var hover = false
        @State private var draft = ""
        @FocusState private var fieldFocused: Bool

        var body: some View {
            HStack(spacing: 10) {
                thumbnail
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    if renaming {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 3)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor)))
                            .focused($fieldFocused)
                            .onSubmit { onCommit(draft) }
                            .onExitCommand { onCancel() }
                            .onAppear {
                                draft = item.displayName
                                fieldFocused = true
                            }
                            .onChange(of: fieldFocused) { _, focused in if !focused { onCommit(draft) } }
                    } else {
                        Text(item.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(Metadata.summary(for: item))
                        .font(.system(size: 10.5))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(hover ? 0.06 : 0))
            )
            .opacity(item.exists ? 1 : 0.5)
            .onPanelHover { hover = $0 }
            .help(item.path ?? item.text ?? "")
        }

        @ViewBuilder private var thumbnail: some View {
            if item.kind == .text {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 13))
                    .foregroundStyle(.black.opacity(0.6))
                    .frame(width: 26, height: 30)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            } else if item.isImage && Thumbnails.shared.hasPreview(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(1.5)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            } else {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            }
        }
    }
}

private struct RowFramesKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct InsertionLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle().strokeBorder(Color.accentColor, lineWidth: 2).frame(width: 7, height: 7)
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .frame(height: 7)
        .allowsHitTesting(false)
    }
}
