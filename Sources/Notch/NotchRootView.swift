import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    let geometry: NotchGeometry
    var onClear: () -> Void = {}

    private var shapeSize: CGSize {
        geometry.shapeSize(presentation: state.presentation,
                          expanded: state.isExpanded, dragOver: state.isDragOver)
    }
    private var open: Bool { state.isExpanded || state.isDragOver }
    private var bottomRadius: CGFloat { open ? 22 : (geometry.hasNotch ? 9 : 13) }
    private var notchH: CGFloat { geometry.notchSize.height }
    private var notchW: CGFloat { geometry.notchSize.width }

    var body: some View {
        ZStack(alignment: .top) {
            background
                .frame(width: shapeSize.width, height: shapeSize.height)
                .shadow(color: .black.opacity(open ? 0.5 : 0), radius: 16, y: 9)

            content
                .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
                .clipShape(NotchShape(bottomRadius: bottomRadius))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Collapsed states stay solid black to blend with the physical notch;
    /// the expanded drawer uses Liquid Glass.
    @ViewBuilder
    private var background: some View {
        let shape = NotchShape(bottomRadius: bottomRadius)
        if open {
            if #available(macOS 26.0, *) {
                shape.fill(.black.opacity(0.4))
                    .glassEffect(.regular.tint(.black.opacity(0.55)), in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(.black.opacity(0.55)))
                    .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            }
        } else {
            shape.fill(.black)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.presentation {
        case .files:
            if open { FileShelf(state: state, notchH: notchH, onClear: onClear) }
            else { FilesBar(state: state, notchW: notchW) }
        case .coding:
            if state.isExpanded { CodingExpanded(state: state, notchH: notchH) }
            else { CodingBar(state: state, notchW: notchW) }
        case .media:
            if state.isExpanded { MediaExpanded(state: state, notchH: notchH) }
            else { MediaBar(state: state, notchW: notchW) }
        case .idle:
            if state.isExpanded { IdleExpanded(notchH: notchH) } else { Color.clear }
        }
    }
}

// MARK: - Collapsed islands (flush with the menu bar, content in the aux areas)

/// Lays out left/right clusters in the menu-bar strips either side of the
/// physical notch, leaving an exact centered gap so nothing hides behind it.
private struct FlankLayout<L: View, R: View>: View {
    let notchW: CGFloat
    @ViewBuilder var left: L
    @ViewBuilder var right: R
    var body: some View {
        HStack(spacing: 0) {
            left.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
            Spacer(minLength: notchW + 26)
            right.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 15)
        }
    }
}

private struct CodingBar: View {
    @ObservedObject var state: NotchState
    let notchW: CGFloat
    var body: some View {
        FlankLayout(notchW: notchW) {
            HStack(spacing: 6) {
                Logo(provider: state.provider, size: 16)
                StatusDot(status: state.status)
            }
        } right: {
            Text(state.tokenString)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92)).monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

private struct MediaBar: View {
    @ObservedObject var state: NotchState
    let notchW: CGFloat
    var body: some View {
        FlankLayout(notchW: notchW) {
            HStack(spacing: 6) {
                MediaIcon(state: state, size: 15)
                Text(state.media?.title ?? "")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
        } right: {
            Equalizer(animated: false)
        }
    }
}

private struct FilesBar: View {
    @ObservedObject var state: NotchState
    let notchW: CGFloat
    var body: some View {
        FlankLayout(notchW: notchW) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("\(state.droppedFiles.count)")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        } right: {
            if let first = state.droppedFiles.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                    .resizable().frame(width: 18, height: 18)
            }
        }
    }
}

// MARK: - Expanded drawer (content starts below the physical notch)

private struct CodingExpanded: View {
    @ObservedObject var state: NotchState
    let notchH: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Logo(provider: state.provider, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.provider?.displayName ?? "Idle")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Text(state.modelName)
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                StatusPill(status: state.status)
            }

            HStack(spacing: 6) {
                Image(systemName: state.status.symbol)
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(state.status.tint)
                Text(actionText)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack(spacing: 9) {
                    Stat(title: "Tokens", value: state.tokenString)
                    Stat(title: "Duration", value: state.durationString)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, notchH + 6).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            SuccessBurst(trigger: state.successPulse).padding(.top, notchH)
        }
    }

    private var actionText: String {
        if state.status == .finished { return state.task.isEmpty ? "Finished" : state.task }
        return state.currentAction.isEmpty ? "Working…" : state.currentAction
    }
}

private struct MediaExpanded: View {
    @ObservedObject var state: NotchState
    let notchH: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MediaIcon(state: state, size: 18)
                Text(state.media?.appName ?? "Now Playing")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Equalizer(animated: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.media?.title ?? "")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(state.media?.artist ?? "")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, notchH + 6).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FileShelf: View {
    @ObservedObject var state: NotchState
    let notchH: CGFloat
    var onClear: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tray.full.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                Text(state.isDragOver ? "Drop to add" : "Shelf")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text("\(state.droppedFiles.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if !state.droppedFiles.isEmpty {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.45))
                    }.buttonStyle(.plain)
                }
            }
            if state.droppedFiles.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(.white.opacity(0.3))
                    .overlay(VStack(spacing: 4) {
                        Image(systemName: "arrow.down.doc.fill").font(.system(size: 20))
                        Text("Drop files here").font(.system(size: 11))
                    }.foregroundStyle(.white.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) { ForEach(state.droppedFiles, id: \.self) { FileThumb(url: $0) } }
                        .padding(.horizontal, 2)
                }
            }
        }
        .padding(.horizontal, 15).padding(.top, notchH + 6).padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct FileThumb: View {
    let url: URL
    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 44, height: 44)
            Text(url.lastPathComponent).font(.system(size: 9)).foregroundStyle(.white.opacity(0.65))
                .lineLimit(1).frame(width: 60)
        }
        .onDrag { NSItemProvider(object: url as NSURL) }
    }
}

private struct IdleExpanded: View {
    let notchH: CGFloat
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            Text("No active session").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.top, notchH * 0.4)
    }
}

// MARK: - Shared pieces

private struct Logo: View {
    let provider: Provider?
    var size: CGFloat
    var body: some View {
        if let provider, let img = ProviderLogos.image(for: provider) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle").font(.system(size: size * 0.8))
                .foregroundStyle(.white.opacity(0.8)).frame(width: size, height: size)
        }
    }
}

private struct MediaIcon: View {
    @ObservedObject var state: NotchState
    var size: CGFloat
    var body: some View {
        if let id = state.media?.bundleID, let img = AppIcons.image(bundleID: id) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: "music.note").font(.system(size: size * 0.8, weight: .bold))
                .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5)).frame(width: size, height: size)
        }
    }
}

private struct StatusDot: View {
    let status: WorkStatus
    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 9.5, weight: .bold)).foregroundStyle(status.tint)
            .contentTransition(.symbolEffect(.replace))
    }
}

private struct StatusPill: View {
    let status: WorkStatus
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol).font(.system(size: 9.5, weight: .bold))
            Text(status.label).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(status.tint.opacity(0.18)))
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.white.opacity(0.42))
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white).monospacedDigit().contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

private struct Equalizer: View {
    var animated: Bool
    @State private var animating = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule().fill(Color(red: 0.4, green: 0.85, blue: 0.5))
                    .frame(width: 2.5, height: (animated && animating) ? [9.0, 14.0, 7.0][i] : [6.0, 11.0, 5.0][i])
                    .animation(animated ? .easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.12) : nil, value: animating)
            }
        }
        .frame(height: 14)
        .onAppear { if animated { animating = true } }
    }
}

private struct SuccessBurst: View {
    let trigger: Int
    @State private var scale: CGFloat = 0.2
    @State private var opacity: Double = 0
    @State private var ring: CGFloat = 0.2
    var body: some View {
        ZStack {
            Circle().stroke(Color(red: 0.36, green: 0.86, blue: 0.52), lineWidth: 2)
                .frame(width: 46, height: 46).scaleEffect(ring).opacity(opacity * 0.6)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color(red: 0.36, green: 0.86, blue: 0.52)).scaleEffect(scale).opacity(opacity)
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fire() }
    }
    private func fire() {
        scale = 0.2; opacity = 0; ring = 0.2
        withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { scale = 1; opacity = 1 }
        withAnimation(.easeOut(duration: 0.8)) { ring = 1.8 }
        withAnimation(.easeIn(duration: 0.5).delay(1.0)) { opacity = 0 }
    }
}
