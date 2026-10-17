import SwiftUI

final class SwitcherModel: ObservableObject {
    @Published var items: [SwitcherItem] = []
    @Published var selection = 0
    var onClick: ((Int) -> Void)?

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
    }
}

enum SwitcherLayout {
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 4
    static let padding: CGFloat = 8
    static let cornerRadius: CGFloat = 22
    static let rowCornerRadius: CGFloat = cornerRadius - padding
    static let width: CGFloat = 560
    static let maxVisibleRows = 14

    static func height(for count: Int) -> CGFloat {
        let rows = CGFloat(min(max(count, 1), maxVisibleRows))
        return rows * rowHeight + (rows - 1) * rowSpacing + padding * 2
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassSwitcherView(model: model)
        } else {
            LegacySwitcherView(model: model)
        }
    }
}

@available(macOS 26.0, *)
private struct GlassSwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @Namespace private var highlight

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: SwitcherLayout.rowSpacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        Row(item: item, selected: index == model.selection)
                            .background {
                                if index == model.selection {
                                    SelectionHighlight()
                                        .matchedGeometryEffect(id: "selection", in: highlight)
                                }
                            }
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { model.onClick?(index) }
                    }
                }
                .padding(SwitcherLayout.padding)
            }
            .onChange(of: model.selection) { _, sel in proxy.scrollTo(sel) }
        }
        .animation(.smooth(duration: 0.2), value: model.selection)
        .frame(width: SwitcherLayout.width, height: SwitcherLayout.height(for: model.items.count))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SwitcherLayout.cornerRadius, style: .continuous))
    }
}

/// A single accent pill that slides between rows, with a soft sheen and edge highlight to sit well on the glass.
private struct SelectionHighlight: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SwitcherLayout.rowCornerRadius, style: .continuous)
        shape
            .fill(Color.accentColor)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .accentColor.opacity(0.35), radius: 6, y: 2)
    }
}

private struct LegacySwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: SwitcherLayout.rowSpacing) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        let selected = index == model.selection
                        Row(item: item, selected: selected)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.05))
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { model.onClick?(index) }
                    }
                }
                .padding(SwitcherLayout.padding)
            }
            .onChange(of: model.selection) { _, sel in proxy.scrollTo(sel) }
        }
        .frame(width: SwitcherLayout.width, height: SwitcherLayout.height(for: model.items.count))
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

private struct Row: View {
    let item: SwitcherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.app.icon ?? NSImage())
                .resizable()
                .frame(width: 22, height: 22)
            Text(item.displayTitle)
                .font(.system(size: 14, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(titleStyle)
            Spacer(minLength: 8)
            StatusIcons(item: item, selected: selected)
        }
        .padding(.horizontal, 10)
        .frame(height: SwitcherLayout.rowHeight)
        // Swap text colors instantly; only the selection highlight should animate.
        .transaction { $0.animation = nil }
    }

    private var titleStyle: AnyShapeStyle {
        let dimmed = item.isMinimized || item.isHidden
        if selected { return AnyShapeStyle(Color.white.opacity(dimmed ? 0.75 : 1)) }
        return dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }
}

private struct StatusIcons: View {
    let item: SwitcherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            if item.isHidden { Image(systemName: "eye.slash") }
            if item.isMinimized { Image(systemName: "minus.circle") }
            if item.isFullscreen { Image(systemName: "arrow.up.left.and.arrow.down.right.circle") }
            if let space = item.spaceIndex, space <= 50 { Image(systemName: "\(space).circle") }
        }
        .font(.system(size: 15))
        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
