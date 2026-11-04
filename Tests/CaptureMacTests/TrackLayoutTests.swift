import Testing
@testable import CaptureMac

struct TrackLayoutTests {
    private let sources: [(AudioRole, [Float])] = [(.game, [0.5, 0.5]), (.microphone, [0.75, 0.75])]

    @Test func mixedAndSeparateEnablesOnlyTheMix() {
        let tracks = Recorder.tracks(from: sources, layout: .mixedAndSeparate)
        #expect(tracks.map(\.name) == ["Mixed", "Game", "Microphone"])
        #expect(tracks.map(\.enabled) == [true, false, false])
        #expect(tracks[0].samples == [1, 1])
    }

    @Test func separateEnablesEverySource() {
        let tracks = Recorder.tracks(from: sources, layout: .separate)
        #expect(tracks.map(\.name) == ["Game", "Microphone"])
        #expect(tracks.filter(\.enabled).count == tracks.count)
    }

    @Test func singleSourceIsOneTrack() {
        let tracks = Recorder.tracks(from: [(.system, [0.1, 0.1])], layout: .mixedAndSeparate)
        #expect(tracks.count == 1)
        #expect(tracks[0].name == "System")
    }
}
