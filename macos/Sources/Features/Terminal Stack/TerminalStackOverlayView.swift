#if os(macOS)
import AppKit
import SwiftUI

struct TerminalStackOverlayView: View {
    @ObservedObject var model: TerminalStackModel
    var onToggleExpanded: () -> Void
    var onHover: (UUID?) -> Void
    var onSelect: (UUID) -> Void

    @Namespace private var cardNamespace

    private let thumbnailSize = CGSize(width: 226, height: 142)
    private let railInset: CGFloat = 22
    private let railWidth: CGFloat = 262
    private let previewGap: CGFloat = 38

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if model.isExpanded, let card = model.activePreviewCard {
                    preview(for: card, in: proxy.size)
                        .position(
                            x: previewCenterX(in: proxy.size, card: card),
                            y: proxy.size.height / 2
                        )
                        .zIndex(10)
                        .transition(.opacity)
                }

                rail(in: proxy.size)
                    .frame(width: railWidth, height: railHeight(in: proxy.size), alignment: .center)
                    .position(
                        x: railInset + railWidth / 2,
                        y: proxy.size.height / 2
                    )
                    .zIndex(20)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .animation(.interactiveSpring(response: 0.48, dampingFraction: 0.86, blendDuration: 0.06), value: model.isExpanded)
        .animation(.easeOut(duration: 0.10), value: model.activePreviewID)
        .animation(.easeOut(duration: 0.10), value: model.selectedID)
    }

    @ViewBuilder
    private func rail(in available: CGSize) -> some View {
        if model.isExpanded {
            expandedList(in: available)
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .leading)))
        } else {
            collapsedStack
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
        }
    }

    private func expandedList(in available: CGSize) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(model.cards) { card in
                    TerminalStackCardView(
                        card: card,
                        isSelected: model.activePreviewID == card.id,
                        size: thumbnailSize
                    )
                    .matchedGeometryEffect(id: card.id, in: cardNamespace)
                    .onHover { hovering in
                        onHover(hovering ? card.id : nil)
                    }
                    .onTapGesture {
                        onSelect(card.id)
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.leading, 4)
            .padding(.trailing, 22)
        }
        .frame(
            width: railWidth,
            height: min(available.height - 128, max(178, CGFloat(model.cards.count) * 156 + 24)),
            alignment: .center
        )
    }

    private var collapsedStack: some View {
        Button(action: onToggleExpanded) {
            ZStack(alignment: .center) {
                ForEach(Array(model.cards.prefix(6).enumerated()), id: \.element.id) { index, card in
                    let depth = CGFloat(index)
                    TerminalStackCardView(
                        card: card,
                        isSelected: index == 0,
                        size: thumbnailSize
                    )
                    .matchedGeometryEffect(id: card.id, in: cardNamespace)
                    .scaleEffect(1 - depth * 0.042)
                    .rotationEffect(.degrees(Double(depth) * -2.2))
                    .offset(x: depth * 10, y: depth * -8)
                    .opacity(index < 5 ? 1 : 0)
                    .zIndex(Double(10 - index))
                    .allowsHitTesting(false)
                }

                if model.cards.count > 1 {
                    VStack {
                        HStack {
                            Spacer()
                            countBadge
                                .offset(x: 14, y: -18)
                        }
                        Spacer()
                    }
                    .frame(width: thumbnailSize.width + 52, height: thumbnailSize.height + 58)
                }
            }
            .frame(width: railWidth, height: thumbnailSize.height + 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var countBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 11, weight: .bold))
            Text("\(model.cards.count)")
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.38), radius: 12, y: 6)
    }

    private func preview(for card: TerminalStackCard, in available: CGSize) -> some View {
        let size = previewSize(in: available, card: card)

        return ZStack {
            if model.selectedID == card.id {
                TerminalLiveHostView(cardID: card.id)
                    .frame(width: size.width, height: size.height)
            } else {
                TerminalSnapshotView(card: card, contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .onTapGesture {
                        onSelect(card.id)
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.64), radius: 44, x: 0, y: 24)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onHover { hovering in
            onHover(hovering ? card.id : nil)
        }
    }

    private func railHeight(in available: CGSize) -> CGFloat {
        if model.isExpanded {
            return min(available.height - 128, max(178, CGFloat(model.cards.count) * 156 + 24))
        }
        return thumbnailSize.height + 72
    }

    private func previewOriginX() -> CGFloat {
        railInset + railWidth + previewGap
    }

    private func previewCenterX(in available: CGSize, card: TerminalStackCard) -> CGFloat {
        previewOriginX() + previewSize(in: available, card: card).width / 2
    }

    private func previewSize(in available: CGSize, card: TerminalStackCard) -> CGSize {
        let originX = previewOriginX()
        let horizontalPadding: CGFloat = 52
        let maxWidth = max(560, min(available.width - originX - horizontalPadding, available.width * 0.74))
        let maxHeight = max(420, min(available.height - 118, available.height * 0.80))

        let imageSize = card.snapshot?.size ?? CGSize(width: 16, height: 10)
        let aspect = max(1.05, min(2.2, imageSize.width / max(imageSize.height, 1)))

        if maxWidth / maxHeight > aspect {
            return CGSize(width: floor(maxHeight * aspect), height: floor(maxHeight))
        }

        return CGSize(width: floor(maxWidth), height: floor(maxWidth / aspect))
    }
}

private struct TerminalLiveHostView: NSViewRepresentable {
    let cardID: UUID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = 26
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            TerminalStackManager.shared.attachLiveTerminal(cardID: cardID, to: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        TerminalStackManager.shared.detachLiveTerminal(from: nsView)
    }
}

private struct TerminalStackCardView: View {
    let card: TerminalStackCard
    let isSelected: Bool
    let size: CGSize

    var body: some View {
        TerminalSnapshotView(card: card, contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .compositingGroup()
            .shadow(
                color: .black.opacity(isSelected ? 0.52 : 0.34),
                radius: isSelected ? 22 : 15,
                x: 0,
                y: isSelected ? 12 : 8
            )
            .scaleEffect(isSelected ? 1.035 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}

private struct TerminalSnapshotView: View {
    let card: TerminalStackCard
    var contentMode: ContentMode

    var body: some View {
        ZStack {
            if let snapshot = card.snapshot {
                Image(nsImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.035, green: 0.038, blue: 0.043),
                        Color(red: 0.10, green: 0.105, blue: 0.115)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<7, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.white.opacity(index == 0 ? 0.42 : 0.16))
                            .frame(width: CGFloat(96 + index * 28), height: 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
            }
        }
        .clipped()
        .background(Color.black)
    }
}
#endif
