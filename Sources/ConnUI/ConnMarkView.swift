import SwiftUI

public enum ConnMarkMotionPolicy {
    public static let orbitDuration: TimeInterval = 7

    public static func rotationDegrees(
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion else { return 0 }
        let phase = elapsed.truncatingRemainder(dividingBy: orbitDuration)
        return max(phase, 0) / orbitDuration * 360
    }
}

struct ConnMarkView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appearedAt = Date()

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: reduceMotion
        )) { context in
            let elapsed = context.date.timeIntervalSince(appearedAt)
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                ZStack {
                    Circle()
                        .stroke(accent, lineWidth: size * 0.069)
                        .frame(width: size * 0.75, height: size * 0.75)

                    VStack(spacing: 0) {
                        Circle()
                        Spacer(minLength: 0)
                        Circle()
                    }
                    .foregroundStyle(accent)
                    .frame(width: size * 0.1875, height: size * 0.625)
                    .rotationEffect(.degrees(
                        ConnMarkMotionPolicy.rotationDegrees(
                            elapsed: elapsed,
                            reduceMotion: reduceMotion
                        )
                    ))
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .onAppear {
            appearedAt = Date()
        }
    }

    private var accent: Color {
        Color(
            red: 45.0 / 255.0,
            green: 212.0 / 255.0,
            blue: 191.0 / 255.0
        )
    }
}
