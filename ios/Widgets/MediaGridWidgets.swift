import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents

@main
struct MediaGridWidgets: WidgetBundle {
    var body: some Widget {
        MediaGridLiveActivity()
    }
}

private let pink = Color(red: 1, green: 0.37, blue: 0.64)
private let violet = Color(red: 0.56, green: 0.42, blue: 1)
private let cyan = Color(red: 0.18, green: 0.83, blue: 1)
private let brand = LinearGradient(colors: [pink, violet, cyan], startPoint: .topLeading, endPoint: .bottomTrailing)

struct MediaGridLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MediaGridActivity.self) { ctx in
            LockScreenView(state: ctx.state, pc: ctx.attributes.pcName)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Badge(state: s, size: 52).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.mode == "music" {
                        Button(intent: PlayPauseIntent()) {
                            Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.title2)
                        }
                        .buttonStyle(.plain).padding(.trailing, 6)
                    } else {
                        Text("\(s.syncDone)/\(s.syncTotal)").font(.headline.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.mode == "music" ? s.title : s.syncLabel).font(.headline).lineLimit(1)
                        Text(s.mode == "music" ? s.subtitle : "MediaGrid").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        ActivityProgress(state: s)
                        if s.mode == "music" {
                            HStack(spacing: 44) {
                                Button(intent: PreviousTrackIntent()) { Image(systemName: "backward.fill") }
                                Button(intent: PlayPauseIntent()) { Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.title2) }
                                Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill") }
                            }
                            .buttonStyle(.plain).font(.title3)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Badge(state: s, size: 22)
            } compactTrailing: {
                if s.mode == "music" {
                    Bars(playing: s.playing)
                } else {
                    ProgressRing(value: Double(s.syncDone) / Double(max(s.syncTotal, 1))).frame(width: 18, height: 18)
                }
            } minimal: {
                if s.mode == "music" { Bars(playing: s.playing) }
                else { ProgressRing(value: Double(s.syncDone) / Double(max(s.syncTotal, 1))).frame(width: 18, height: 18) }
            }
            .keylineTint(violet)
        }
    }
}

struct Badge: View {
    let state: MediaGridActivity.ContentState
    let size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(brand)
            Image(systemName: state.mode == "music" ? "music.note" : "arrow.triangle.2.circlepath")
                .font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

struct Bars: View {
    let playing: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach([0.5, 1.0, 0.7], id: \.self) { h in
                Capsule().fill(brand).frame(width: 3, height: playing ? 14 * h : 4)
            }
        }
        .frame(height: 14)
    }
}

struct ProgressRing: View {
    let value: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 3)
            Circle().trim(from: 0, to: value).stroke(brand, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
        }
    }
}

struct ActivityProgress: View {
    let state: MediaGridActivity.ContentState
    var body: some View {
        if state.mode == "music" {
            if state.playing && state.end > Date() {
                ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(violet)
            } else {
                ProgressView(value: min(max(state.progress, 0), 1)).tint(violet)
            }
        } else {
            ProgressView(value: Double(state.syncDone), total: Double(max(state.syncTotal, 1))).tint(pink)
        }
    }
}

struct LockScreenView: View {
    let state: MediaGridActivity.ContentState
    let pc: String
    var body: some View {
        HStack(spacing: 14) {
            Badge(state: state, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.mode == "music" ? state.title : state.syncLabel).font(.headline).lineLimit(1)
                Text(state.mode == "music" ? state.subtitle : "\(state.syncDone) of \(state.syncTotal) · \(pc)").font(.subheadline)
                    .foregroundStyle(.secondary).lineLimit(1)
                ActivityProgress(state: state)
            }
            if state.mode == "music" {
                HStack(spacing: 14) {
                    Button(intent: PlayPauseIntent()) { Image(systemName: state.playing ? "pause.fill" : "play.fill").font(.title2) }
                    Button(intent: NextTrackIntent()) { Image(systemName: "forward.fill").font(.title3) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}
