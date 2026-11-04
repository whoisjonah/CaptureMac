import Testing
@testable import CaptureMac

struct UpdaterTests {
    @Test func comparesEachPart() {
        #expect(Updater.isNewer("1.0.1", than: "1.0.0"))
        #expect(Updater.isNewer("1.10.0", than: "1.9.0"))
        #expect(Updater.isNewer("2.0.0", than: "1.99.99"))
    }

    @Test func sameOrOlderIsNotNewer() {
        #expect(!Updater.isNewer("1.0.0", than: "1.0.0"))
        #expect(!Updater.isNewer("1.0.0", than: "1.0.1"))
        #expect(!Updater.isNewer("1.0", than: "1.0.0"))
    }
}
