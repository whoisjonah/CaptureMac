import Testing
@testable import CaptureMac

struct ExportPlanTests {
    @Test func targetSizeFitsBudget() {
        for megabytes in ExportPreset.sizes {
            for duration in [10.0, 30, 60, 120] {
                let plan = ExportPlan.make(
                    preset: .targetSize(megabytes), duration: duration, width: 2560, height: 1440,
                    frameRate: 60, sourceBitrate: 30_000_000, audioChanged: false
                )
                #expect(plan.estimatedBytes(duration: duration) <= Int64(megabytes) * 1_000_000)
            }
        }
    }

    @Test func smallClipsPassThrough() {
        let plan = ExportPlan.make(
            preset: .targetSize(25), duration: 10, width: 1920, height: 1080,
            frameRate: 60, sourceBitrate: 8_000_000, audioChanged: false
        )
        #expect(plan.passthrough)
    }

    @Test func lowBudgetsDropResolutionAndFrameRate() {
        let plan = ExportPlan.make(
            preset: .targetSize(10), duration: 120, width: 2560, height: 1440,
            frameRate: 60, sourceBitrate: 30_000_000, audioChanged: false
        )
        #expect(plan.height <= 360)
        #expect(plan.frameRate == 30)
        #expect(plan.width.isMultiple(of: 2) && plan.height.isMultiple(of: 2))
    }

    @Test func qualityPresetsNeverUpscale() {
        let plan = ExportPlan.make(
            preset: .quality(.p1080), duration: 30, width: 1280, height: 720,
            frameRate: 60, sourceBitrate: 6_000_000, audioChanged: false
        )
        #expect(plan.width == 1280 && plan.height == 720)
    }

    @Test func portraitScalesByShortSide() {
        let size = ExportPlan.scaled(width: 1440, height: 2560, toShortSide: 720)
        #expect(size.width == 720 && size.height == 1280)
    }

    @Test func originalWithRemixReencodes() {
        let plan = ExportPlan.make(
            preset: .original, duration: 30, width: 1920, height: 1080,
            frameRate: 60, sourceBitrate: 12_000_000, audioChanged: true
        )
        #expect(!plan.passthrough)
        #expect(plan.width == 1920)
    }
}
