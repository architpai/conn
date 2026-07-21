import Foundation
import ConnAppCore

enum Phase115CompactShelfMotionTestCases {
    static func run(into suite: inout TestSuite) {
        testCountdown(into: &suite)
        testWaveform(into: &suite)
        testReduceMotion(into: &suite)
    }

    private static func testCountdown(into suite: inout TestSuite) {
        suite.checkEqual(
            ShellCompactShelfMotionPolicy.countdownProgress(elapsed: -1, reduceMotion: false),
            1,
            "compact shelf countdown clamps pre-appearance time to a full ring"
        )
        suite.checkEqual(
            ShellCompactShelfMotionPolicy.countdownProgress(elapsed: 2.5, reduceMotion: false),
            0.5,
            "compact shelf countdown reaches half at half of its activity lifetime"
        )
        suite.checkEqual(
            ShellCompactShelfMotionPolicy.countdownProgress(elapsed: 5, reduceMotion: false),
            0,
            "compact shelf countdown drains when the default notification expires"
        )
        suite.checkEqual(
            ShellCompactShelfMotionPolicy.countdownProgress(elapsed: 20, reduceMotion: false),
            0,
            "compact shelf countdown never renders a negative trim"
        )
    }

    private static func testWaveform(into suite: inout TestSuite) {
        let initial = ShellCompactShelfMotionPolicy.waveformHeight(
            barIndex: 0,
            elapsed: 0,
            reduceMotion: false
        )
        let quarterCycle = ShellCompactShelfMotionPolicy.waveformHeight(
            barIndex: 0,
            elapsed: ShellCompactShelfMotionPolicy.waveformCycleDuration / 4,
            reduceMotion: false
        )
        suite.check(
            quarterCycle > initial,
            "compact shelf waveform visibly changes height during its cycle"
        )

        for index in 0..<5 {
            let height = ShellCompactShelfMotionPolicy.waveformHeight(
                barIndex: index,
                elapsed: 0.31,
                reduceMotion: false
            )
            suite.check(
                (6...14).contains(height),
                "compact shelf waveform bar \(index) remains within its stable visual bounds"
            )
        }
    }

    private static func testReduceMotion(into suite: inout TestSuite) {
        suite.checkEqual(
            ShellCompactShelfMotionPolicy.countdownProgress(elapsed: 1.8, reduceMotion: true),
            1,
            "Reduce Motion freezes the compact shelf timer ring"
        )
        for index in 0..<5 {
            let initial = ShellCompactShelfMotionPolicy.waveformHeight(
                barIndex: index,
                elapsed: 0,
                reduceMotion: true
            )
            let later = ShellCompactShelfMotionPolicy.waveformHeight(
                barIndex: index,
                elapsed: 10,
                reduceMotion: true
            )
            suite.checkEqual(
                later,
                initial,
                "Reduce Motion keeps compact shelf waveform bar \(index) stable"
            )
        }
    }
}
