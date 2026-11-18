import WidgetKit
import SwiftUI
import ActivityKit

@main
struct MediaGridWidgets: WidgetBundle {
    var body: some Widget {
        MediaGridLiveActivity()
    }
}

private extension MediaGridActivity.ContentState {
    var tint: Color { accent.count == 3 ? Color(red: accent[0], green: accent[1], blue: accent[2]) : .blue }
    var fraction: Double { min(1, Double(done) / Double(max(total, 1))) }
    var percent: Int { Int((fraction * 100).rounded()) }
    var icon: String { finished ? "checkmark" : label.localizedCaseInsensitiveContains("music") ? "music.note"
                       : label.localizedCaseInsensitiveContains("photo") || label.localizedCaseInsensitiveContains("media") ? "photo.on.rectangle" : "arrow.down" }
    var headline: String { finished ? "\(label) · Done" : label }
    var detail: String { finished ? "\(total) item\(total == 1 ? "" : "s") transferred" : "\(done) of \(total)" }
}

struct MediaGridLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MediaGridActivity.self) { ctx in
            LockScreenView(state: ctx.state, pc: ctx.attributes.pcName)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let s = ctx.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Ring(state: s, size: 46).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.finished ? "Done" : "\(s.percent)%")
                        .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(s.tint)
                        .contentTransition(.numericText()).padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.label).font(.headline).lineLimit(1)
                        Text(s.detail).font(.subheadline).foregroundStyle(.secondary).contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Bar(state: s).padding(.horizontal, 6).padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: s.icon).foregroundStyle(s.tint).symbolEffect(.pulse, isActive: !s.finished)
            } compactTrailing: {
                Ring(state: s, size: 20, showIcon: false)
            } minimal: {
                Ring(state: s, size: 20, showIcon: false)
            }
            .keylineTint(s.tint)
        }
    }
}

/// Circular progress with the activity icon inside.
struct Ring: View {
    let state: MediaGridActivity.ContentState
    let size: CGFloat
    var showIcon = true
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: size * 0.11)
            Circle().trim(from: 0, to: state.fraction)
                .stroke(state.tint, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: state.fraction)
            if showIcon {
                Image(systemName: state.icon).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(state.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: size, height: size)
    }
}

struct Bar: View {
    let state: MediaGridActivity.ContentState
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(state.tint).frame(width: max(8, g.size.width * state.fraction))
                    .animation(.smooth, value: state.fraction)
            }
        }
        .frame(height: 8)
    }
}

struct LockScreenView: View {
    let state: MediaGridActivity.ContentState
    let pc: String
    var body: some View {
        HStack(spacing: 14) {
            Ring(state: state, size: 54)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.headline).font(.headline).lineLimit(1)
                    Spacer()
                    Text("\(state.percent)%").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(state.tint)
                        .contentTransition(.numericText())
                }
                Bar(state: state)
                HStack {
                    Text(state.detail).contentTransition(.numericText())
                    Spacer()
                    Text(pc).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}
