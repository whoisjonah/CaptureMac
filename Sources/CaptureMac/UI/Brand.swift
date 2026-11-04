import AppKit
import SwiftUI

enum Brand {
    static let slogan = "Clipping on Mac, made easy."

    static let blue = Color(nsColor: .dynamic(light: 0x1F5EF0, dark: 0x4C8DFF))
    static let blueTop = Color(nsColor: NSColor(hex: 0x4C8DFF))
    static let blueBottom = Color(nsColor: NSColor(hex: 0x1F5EF0))
    static let ink = Color(nsColor: .dynamic(light: 0x0E0F12, dark: 0xF4F4F2))
    static let paper = Color(nsColor: .dynamic(light: 0xF4F4F2, dark: 0x111318))
    static let record = Color(nsColor: NSColor(hex: 0xFF3B30))

    static let gradient = LinearGradient(colors: [blueTop, blueBottom], startPoint: .top, endPoint: .bottom)

    static func viewfinder(in rect: CGRect) -> CGPath {
        let scale = min(rect.width, rect.height) / 120
        let originX = rect.midX - 60 * scale
        let originY = rect.midY - 60 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }
        let radius = 10 * scale
        let path = CGMutablePath()
        path.move(to: point(20, 44))
        path.addLine(to: point(20, 30))
        path.addArc(tangent1End: point(20, 20), tangent2End: point(30, 20), radius: radius)
        path.addLine(to: point(44, 20))
        path.move(to: point(76, 20))
        path.addLine(to: point(90, 20))
        path.addArc(tangent1End: point(100, 20), tangent2End: point(100, 30), radius: radius)
        path.addLine(to: point(100, 44))
        path.move(to: point(100, 76))
        path.addLine(to: point(100, 90))
        path.addArc(tangent1End: point(100, 100), tangent2End: point(90, 100), radius: radius)
        path.addLine(to: point(76, 100))
        path.move(to: point(44, 100))
        path.addLine(to: point(30, 100))
        path.addArc(tangent1End: point(20, 100), tangent2End: point(20, 90), radius: radius)
        path.addLine(to: point(20, 76))
        return path
    }

    enum MenuBarState {
        case idle, buffering, recording
    }

    static func menuBarImage(_ state: MenuBarState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(viewfinder(in: rect))
            context.setLineWidth(11 * rect.width / 120)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(NSColor.black.cgColor)
            context.strokePath()

            let dot = CGRect(x: rect.midX - rect.width * 16 / 120, y: rect.midY - rect.height * 16 / 120, width: rect.width * 32 / 120, height: rect.height * 32 / 120)
            switch state {
            case .idle:
                context.setLineWidth(1.4)
                context.strokeEllipse(in: dot.insetBy(dx: 0.7, dy: 0.7))
            case .buffering:
                context.setFillColor(NSColor.black.cgColor)
                context.fillEllipse(in: dot)
            case .recording:
                context.setFillColor(NSColor.systemRed.cgColor)
                context.fillEllipse(in: dot.insetBy(dx: -1, dy: -1))
            }
            return true
        }
        image.isTemplate = state != .recording
        return image
    }
}

struct ViewfinderFrame: Shape {
    func path(in rect: CGRect) -> Path {
        Path(Brand.viewfinder(in: rect))
    }
}

struct ViewfinderMark: View {
    var frameColor: Color = Brand.ink
    var dotColor: Color = Brand.blue

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 120
            ZStack {
                ViewfinderFrame()
                    .stroke(frameColor, style: StrokeStyle(lineWidth: 9 * scale, lineCap: .round, lineJoin: .round))
                Circle()
                    .fill(dotColor)
                    .frame(width: 30 * scale, height: 30 * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct CaptureMacWordmark: View {
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: size * 0.29) {
            ViewfinderMark()
                .frame(width: size * 1.14, height: size * 1.14)
            (Text("Capture").fontWeight(.bold).foregroundColor(Brand.ink) + Text("Mac").fontWeight(.light).foregroundColor(.secondary))
                .font(.system(size: size))
                .tracking(-size * 0.025)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CaptureMac")
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}
