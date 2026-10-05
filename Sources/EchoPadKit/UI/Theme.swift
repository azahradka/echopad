import SwiftUI

/// Shared metrics. Colors come from the system accent, like Apple's own apps.
enum Theme {
    static let pagePadding: CGFloat = 24
    static let rowCornerRadius: CGFloat = 10
}

/// A large symbol in the accent color, used as the hero of a setup step or an empty state.
struct HeroSymbol: View {
    let name: String
    var size: CGFloat = 56

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .frame(height: size * 1.4)
    }
}

/// Keeps re-running `onChange` whenever something read in `track` changes.
@MainActor
func observeContinuously(_ track: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
    withObservationTracking {
        track()
    } onChange: {
        Task { @MainActor in
            onChange()
            observeContinuously(track, onChange: onChange)
        }
    }
}

/// Wording and color for the current state, shared by the sidebar, the menu bar panel and the pill.
@MainActor
enum StatusText {
    static func title(_ state: AppState) -> String {
        switch state.phase {
        case .recording: return "Recording"
        case .processing(let step): return step.title
        case .saved: return "Saved"
        case .error: return "Something went wrong"
        case .idle:
            switch state.model {
            case .loading(let fraction, _):
                return fraction.map { "Getting ready · \(Int($0 * 100))%" } ?? "Getting ready…"
            case .failed: return "Speech model unavailable"
            default: return "Ready to record"
            }
        }
    }

    static func color(_ state: AppState) -> Color {
        switch state.phase {
        case .recording: return .red
        case .processing: return .orange
        case .saved: return .green
        case .error: return .yellow
        case .idle:
            switch state.model {
            case .failed: return .red
            case .loading: return .orange
            // Not loaded: the external transcriber is in use.
            case .ready, .notLoaded: return .green
            }
        }
    }
}

/// `12:05` or `1:02:05`.
func clockText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// `30 s`, `47 min`, `1 h 05 min`.
func durationText(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded()))
    if total < 60 { return "\(total) s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes) min" }
    return String(format: "%d h %02d min", minutes / 60, minutes % 60)
}
