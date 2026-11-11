import AppKit
import SwiftUI

/// An annular sector (one wheel segment), centred in its rect, 0° at the top.
struct Sector: Shape {
    var index: Int
    var count: Int
    var inner: CGFloat
    var outer: CGFloat
    var gap: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        guard count > 0 else { return Path() }
        if count == 1 {
            var p = Path()
            p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
            return p.normalized(eoFill: true)
        }
        let span = 360.0 / Double(count)
        let mid = -90 + span * Double(index)
        // Constant-width gaps: convert the gap in points to an angle at each radius.
        let go = Double(gap / outer) * 180 / .pi, gi = Double(gap / inner) * 180 / .pi
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .degrees(mid - span / 2 + go),
                 endAngle: .degrees(mid + span / 2 - go), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .degrees(mid + span / 2 - gi),
                 endAngle: .degrees(mid - span / 2 + gi), clockwise: true)
        p.closeSubpath()
        return p
    }
}

struct WheelView: View {
    var model: WheelModel

    var body: some View {
        let wheelMidY = (model.barOnTop ? Geo.hintHeight + Geo.wheelSize / 2 : Geo.wheelSize / 2) / Geo.panelSize.height
        VStack(spacing: 0) {
            if model.barOnTop {
                modeBar.frame(width: Geo.wheelSize, height: Geo.hintHeight)
            }
            wheel
                .frame(width: Geo.wheelSize, height: Geo.wheelSize)
            if !model.barOnTop {
                modeBar.frame(width: Geo.wheelSize, height: Geo.hintHeight)
            }
        }
        .scaleEffect(model.shown ? 1 : 0.82, anchor: .init(x: 0.5, y: wheelMidY))
        .opacity(model.shown ? 1 : 0)
    }

    private var wheel: some View {
        let n = model.items.count
        let d = Geo.outer * 2
        return ZStack {
            GlassEffectContainer(spacing: 10) {
                ZStack {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, _ in
                        let on = model.selected == i
                        let shape = Sector(index: i, count: n, inner: Geo.inner, outer: Geo.outer, gap: 3.5)
                        Color.clear
                            .frame(width: d, height: d)
                            .contentShape(shape)
                            .echoGlass(shape, tint: on ? GlassTint.picked : GlassTint.clear, interactive: on)
                            .scaleEffect(on ? 1.06 : 1)
                    }
                    Color.clear
                        .frame(width: Geo.inner * 2 - 14, height: Geo.inner * 2 - 14)
                        .echoGlass(Circle(), tint: GlassTint.dense)
                }
            }

            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                let on = model.selected == i
                let span = 2 * Double.pi / Double(max(n, 1))
                let a = -Double.pi / 2 + span * Double(i)
                let r = (Geo.inner + Geo.outer) / 2 + 2
                VStack(spacing: 5) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 18, weight: .semibold))
                    Text(item.title)
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .tracking(0.5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(on ? Color.onPick : Color.ink)
                .shadow(color: on ? .clear : Color.labelShadow, radius: 2, y: 1)
                .frame(width: 76)
                .offset(x: n == 1 ? 0 : cos(a) * r, y: n == 1 ? -r : sin(a) * r)
                .scaleEffect(on ? 1.08 : 1)
                .allowsHitTesting(false)
            }

            centre
        }
    }

    private var centre: some View {
        let item = model.selected.flatMap { model.items.indices.contains($0) ? model.items[$0] : nil }
        return VStack(spacing: 4) {
            if let item {
                Image(systemName: item.symbol).font(.system(size: 19, weight: .semibold))
                Text(item.detail)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else {
                Text(model.mode.key)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.onPick)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.pick))
                Text(model.items.isEmpty ? "Nothing here" : model.mode.title.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded)).tracking(1)
                Text(model.subject)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .foregroundStyle(Color.ink)
        .shadow(color: Color.labelShadow, radius: 2, y: 1)
        .frame(width: Geo.inner * 2 - 26)
        .allowsHitTesting(false)
    }

    /// One glass capsule with the three wheels; the current one sits on a mint pill.
    private var modeBar: some View {
        HStack(spacing: 2) {
            ForEach(WheelMode.allCases, id: \.self) { mode in
                let on = model.mode == mode
                HStack(spacing: 6) {
                    Text(mode.key).font(.system(size: 13.5, weight: .bold, design: .rounded))
                    Text(mode.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(on ? Color.onPick : Color.ink)
                .frame(width: 112, height: 32)
                .background {
                    if on { Capsule().fill(Color.pick).shadow(color: .black.opacity(0.2), radius: 3, y: 1) }
                }
            }
        }
        .padding(4)
        .echoGlass(Capsule(), tint: GlassTint.clear)
        .animation(.snappy(duration: 0.22), value: model.mode)
    }
}

// MARK: - Toast (errors and the word count only)

@MainActor
final class Toast {
    static let shared = Toast()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, detail: String, symbol: String, at point: CGPoint?,
              duration: TimeInterval = 2.4, sticky: Bool = false) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let view = ToastView(title: title, detail: detail, symbol: symbol)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = host

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let anchor = point ?? CGPoint(x: screen.midX, y: screen.maxY - 120)
        var origin = CGPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        p.setFrameOrigin(origin)
        p.orderFrontRegardless()
        panel = p

        guard !sticky else { return }
        let work = DispatchWorkItem { [weak self, weak p] in
            p?.orderOut(nil)
            if self?.panel === p { self?.panel = nil }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

struct ToastView: View {
    let title: String
    let detail: String
    let symbol: String

    /// Failures use the brand error colours (error container #93000A, error #FFB4AB).
    private var isError: Bool { symbol.hasPrefix("exclamationmark") }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isError ? Color.errorInk : Color.onPick)
                .frame(width: 34, height: 34)
                .background(Circle().fill(isError ? Color.errorFill : Color.pick))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                Text(detail)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.inkSecondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
        .padding(.leading, 10).padding(.trailing, 20)
        .padding(.vertical, 10)
        .echoGlass(Capsule(), tint: GlassTint.dense)
        .padding(10)
        .fixedSize()
    }
}
