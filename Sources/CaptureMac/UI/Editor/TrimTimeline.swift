import SwiftUI

struct TrimTimeline: View {
    @Bindable var model: EditorModel

    private let handleWidth: CGFloat = 12
    private let minimumLength = 0.5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width - handleWidth * 2
            let startX = handleWidth + x(model.trimStart, width)
            let endX = handleWidth + x(model.trimEnd, width)

            ZStack(alignment: .leading) {
                filmstrip
                    .padding(.horizontal, handleWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { value in
                                model.seek(to: time(value.location.x - handleWidth, width))
                            }
                            .onEnded { value in
                                if abs(value.translation.width) < 3 {
                                    model.selectedSegment = model.segment(at: time(value.location.x - handleWidth, width))
                                }
                            }
                    )

                ForEach(Array(model.segments.enumerated()), id: \.offset) { index, segment in
                    let left = handleWidth + x(segment.start, width)
                    let right = handleWidth + x(segment.end, width)
                    ZStack {
                        if model.removed.contains(index) {
                            Rectangle().fill(Brand.record.opacity(0.35))
                            Rectangle().fill(.black.opacity(0.35))
                            Image(systemName: "scissors")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        if model.selectedSegment == index && model.segments.count > 1 {
                            Rectangle()
                                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        }
                    }
                    .frame(width: max(0, right - left))
                    .offset(x: left)
                    .allowsHitTesting(false)
                }

                ForEach(model.splits, id: \.self) { split in
                    Capsule()
                        .fill(.white)
                        .frame(width: 2, height: proxy.size.height - 10)
                        .offset(x: handleWidth + x(split, width) - 1)
                        .allowsHitTesting(false)
                }

                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, startX - handleWidth))
                    .offset(x: handleWidth)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .frame(width: max(0, width + handleWidth - endX))
                    .offset(x: endX)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Brand.blue, lineWidth: 3)
                    .frame(width: endX - startX + handleWidth * 2)
                    .offset(x: startX - handleWidth)
                    .allowsHitTesting(false)

                handle(edge: .leading)
                    .offset(x: startX - handleWidth)
                    .gesture(
                        DragGesture(coordinateSpace: .named("timeline")).onChanged { value in
                            model.trimStart = min(max(0, time(value.location.x - handleWidth, width)), model.trimEnd - minimumLength)
                            model.seek(to: model.trimStart)
                        }
                    )

                handle(edge: .trailing)
                    .offset(x: endX)
                    .gesture(
                        DragGesture(coordinateSpace: .named("timeline")).onChanged { value in
                            model.trimEnd = max(min(model.duration, time(value.location.x - handleWidth, width)), model.trimStart + minimumLength)
                            model.seek(to: model.trimEnd)
                        }
                    )

                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: proxy.size.height + 8)
                    .shadow(radius: 2)
                    .offset(x: handleWidth + x(model.currentTime, width) - 1.5)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "timeline")
        }
    }

    private var filmstrip: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(model.filmstrip.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width / CGFloat(max(model.filmstrip.count, 1)), height: proxy.size.height)
                        .clipped()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func handle(edge: HorizontalEdge) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 6 : 0,
            bottomLeadingRadius: edge == .leading ? 6 : 0,
            bottomTrailingRadius: edge == .trailing ? 6 : 0,
            topTrailingRadius: edge == .trailing ? 6 : 0,
            style: .continuous
        )
        .fill(Brand.blue)
        .frame(width: handleWidth)
        .overlay {
            Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 16)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(time / model.duration) * width
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width) * model.duration), model.duration)
    }
}
