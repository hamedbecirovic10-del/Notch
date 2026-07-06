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

            content
                .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
                .clipShape(NotchShape(bottomRadius: bottomRadius))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Always solid black — blends seamlessly with the physical notch in every
    /// state. No border, no material.
    @ViewBuilder
    private var background: some View {
        NotchShape(bottomRadius: bottomRadius).fill(.black)
    }

    @ViewBuilder
    private var content: some View {
        if state.presentation == .files {
            if open { FileShelf(state: state, notchH: notchH, onClear: onClear) }
            else { FilesBar(state: state, notchW: notchW) }
        } else if open {
            WidgetCarousel(state: state, notchH: notchH)
        } else {
            switch state.presentation {
            case .coding: CodingBar(state: state, notchW: notchW)
            case .media:  MediaBar(state: state, notchW: notchW)
            default:      Color.clear
            }
        }
    }
}

// MARK: - Widget carousel (session · clock · timer · media)

private struct WidgetCarousel: View {
    @ObservedObject var state: NotchState
    let notchH: CGFloat

    private enum Page: Equatable { case session, clock, timer, media }

    private var pages: [Page] {
        var p: [Page] = []
        if state.presentation == .coding { p.append(.session) }
        p.append(.clock)
        p.append(.timer)
        if state.media != nil { p.append(.media) }
        return p
    }

    var body: some View {
        let pgs = pages
        let idx = min(max(state.widgetPage, 0), pgs.count - 1)
        ZStack {
            page(pgs[idx])
                .padding(.horizontal, pgs.count > 1 ? 36 : 0)
                .transition(.opacity)
                .id(pgs[idx])

            if pgs.count > 1 {
                HStack {
                    arrow("chevron.left")  { move(-1, pgs.count) }
                    Spacer()
                    arrow("chevron.right") { move(1, pgs.count) }
                }
                .padding(.horizontal, 16)
                .padding(.top, notchH)

                VStack {
                    Spacer()
                    HStack(spacing: 5) {
                        ForEach(0..<pgs.count, id: \.self) { i in
                            Circle().fill(.white.opacity(i == idx ? 0.85 : 0.25))
                                .frame(width: 4, height: 4)
                        }
                    }.padding(.bottom, 7)
                }
            }
        }
        .onAppear { if state.widgetPage >= pgs.count { state.widgetPage = 0 } }
    }

    @ViewBuilder private func page(_ p: Page) -> some View {
        switch p {
        case .session: SessionPage(state: state, notchH: notchH)
        case .clock:   CalendarPage(cal: state.calendar, notchH: notchH)
        case .timer:   TimerPage(state: state, notchH: notchH)
        case .media:   MediaPage(state: state, notchH: notchH)
        }
    }

    private func move(_ d: Int, _ count: Int) {
        withAnimation(.smooth(duration: 0.3)) {
            state.widgetPage = ((state.widgetPage + d) % count + count) % count
        }
    }

    private func arrow(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6)).frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.08)))
        }.buttonStyle(.plain)
    }
}

// MARK: - Calendar page (whole month + real macOS Calendar events)

private struct CalendarPage: View {
    @ObservedObject var cal: CalendarStore
    let notchH: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MonthGrid(eventDays: cal.eventDays)
                .frame(width: 176)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let img = Assets.image("calendar") {
                        Image(nsImage: img).resizable().frame(width: 16, height: 16)
                    }
                    Text(Date(), format: .dateTime.weekday(.wide).month().day())
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                if !cal.granted {
                    Text("Enable Calendar access").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                } else if cal.todaysEvents.isEmpty {
                    Text("No events today").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                } else {
                    ForEach(cal.todaysEvents.prefix(3)) { ev in
                        HStack(spacing: 6) {
                            Circle().fill(ev.color).frame(width: 5, height: 5)
                            Text(ev.allDay ? "all-day" : ev.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                                .frame(width: 46, alignment: .leading)
                            Text(ev.title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.top, notchH).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { cal.loadIfNeeded() }
    }
}

/// A compact month grid with today highlighted and dots on days that have events.
private struct MonthGrid: View {
    let eventDays: Set<Int>
    private let cal = Calendar.current

    var body: some View {
        let now = Date()
        let today = cal.component(.day, from: now)
        let comps = cal.dateComponents([.year, .month], from: now)
        let first = cal.date(from: comps) ?? now
        let daysInMonth = cal.range(of: .day, in: .month, for: now)?.count ?? 30
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7

        VStack(spacing: 2) {
            Text(now, format: .dateTime.month(.wide).year())
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    Text(weekdaySymbol(i)).font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
                ForEach(0..<(leading + daysInMonth), id: \.self) { idx in
                    if idx < leading {
                        Color.clear.frame(height: 15)
                    } else {
                        let day = idx - leading + 1
                        DayCell(day: day, isToday: day == today, hasEvent: eventDays.contains(day))
                    }
                }
            }
        }
    }

    private func weekdaySymbol(_ i: Int) -> String {
        let s = cal.veryShortWeekdaySymbols
        return s[(i + cal.firstWeekday - 1) % 7]
    }
}

private struct DayCell: View {
    let day: Int
    let isToday: Bool
    let hasEvent: Bool
    var body: some View {
        ZStack {
            if isToday { Circle().fill(Color(red: 0.9, green: 0.3, blue: 0.25)).frame(width: 15, height: 15) }
            Text("\(day)").font(.system(size: 8, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? .white : .white.opacity(0.75))
        }
        .frame(height: 15)
        .overlay(alignment: .bottom) {
            if hasEvent && !isToday {
                Circle().fill(.white.opacity(0.5)).frame(width: 2.5, height: 2.5).offset(y: 1)
            }
        }
    }
}

// MARK: - Timer page

private struct TimerPage: View {
    @ObservedObject var state: NotchState
    let notchH: CGFloat
    private let orange = Color(red: 0.95, green: 0.6, blue: 0.2)

    var body: some View {
        // While running, drive everything off the clock so the ruler line
        // slides as it counts down; while idle, follow the selected minutes.
        TimelineView(.periodic(from: .now, by: state.timerRunning ? 0.1 : 1)) { ctx in
            let remaining = state.timerRunning
                ? max(0, state.timerEndDate?.timeIntervalSince(ctx.date) ?? 0)
                : Double(state.timerMinutes * 60)
            let dial = remaining / 60.0                       // fractional minutes
            VStack(spacing: 9) {
                MinuteRuler(value: dial, live: state.timerRunning, tint: orange) { newMinutes in
                    state.timerMinutes = newMinutes
                }
                .frame(height: 30)

                HStack {
                    Button(action: toggle) {
                        Text(state.timerRunning ? "Stop" : "Start Timer")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(orange)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(orange.opacity(0.16)))
                    }.buttonStyle(.plain)

                    Spacer()

                    Text(String(format: "%d:%02d", Int(remaining) / 60, Int(remaining) % 60))
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .foregroundStyle(orange).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 4).padding(.top, notchH - 2).padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func toggle() {
        withAnimation(.smooth(duration: 0.25)) {
            state.timerRunning ? state.stopTimer() : state.startTimer()
        }
    }
}

/// Horizontal minute ruler centered on `value` (fractional minutes). When idle
/// you drag it to pick a duration (unlimited); when live it slides as the timer
/// counts down.
private struct MinuteRuler: View {
    var value: Double
    var live: Bool
    var tint: Color
    var onChange: (Int) -> Void
    @State private var dragBase: Double? = nil
    private let pxPerMinute: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, mid = w / 2
            Canvas { ctx, _ in
                let lo = Int(floor(value)) - 30, hi = Int(ceil(value)) + 30
                for m in max(0, lo)...max(0, hi) {
                    let x = mid + (CGFloat(m) - CGFloat(value)) * pxPerMinute
                    guard x >= 0, x <= w else { continue }
                    let major = m % 5 == 0
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 4)); p.addLine(to: CGPoint(x: x, y: 4 + (major ? 16 : 9)))
                    ctx.stroke(p, with: .color(.white.opacity(major ? 0.5 : 0.22)), lineWidth: major ? 1.5 : 1)
                    if major {
                        ctx.draw(Text("\(m)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.4)),
                                 at: CGPoint(x: x, y: 26))
                    }
                }
                ctx.fill(Path(CGRect(x: mid - 0.75, y: 2, width: 1.5, height: 22)), with: .color(tint))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard !live else { return }
                if dragBase == nil { dragBase = value }
                let delta = Double(-v.translation.width / pxPerMinute)
                onChange(max(1, Int(((dragBase ?? value) + delta).rounded())))
            }.onEnded { _ in dragBase = nil })
        }
    }
}

// MARK: - Media page (with controls)

private struct MediaPage: View {
    @ObservedObject var state: NotchState
    let notchH: CGFloat
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                MediaIcon(state: state, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.media?.title ?? "")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(state.media?.artist ?? "")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 26) {
                ctrl("backward.fill") { MediaControls.previous(state.media) }
                ctrl(state.media?.isPlaying == true ? "pause.fill" : "play.fill") { MediaControls.playPause(state.media) }
                ctrl("forward.fill") { MediaControls.next(state.media) }
            }
        }
        .padding(.horizontal, 8).padding(.top, notchH - 2).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    private func ctrl(_ s: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: s).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }.buttonStyle(.plain)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
            if state.media?.isPlaying == true {
                Equalizer(animated: true)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.5))
                    .frame(width: 14, height: 14)
            }
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

private struct SessionPage: View {
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
