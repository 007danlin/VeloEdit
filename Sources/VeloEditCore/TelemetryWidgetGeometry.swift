import CoreGraphics

/// The same non-overlapping regions are used at thumbnail and delivery sizes.
struct TelemetryWidgetGeometry {
    let label: CGRect
    let value: CGRect
    let graphic: CGRect

    init(rect: CGRect, presentation: TelemetryWidgetPresentation, showsLabel: Bool) {
        let content = rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.10)
        let gap = rect.height * 0.06
        let labelHeight = showsLabel ? rect.height * 0.15 : 0
        label = CGRect(x: content.minX, y: content.maxY - labelHeight, width: content.width, height: labelHeight)
        let body = CGRect(x: content.minX, y: content.minY, width: content.width,
                          height: content.height - labelHeight - (showsLabel ? gap : 0))
        switch presentation {
        case .linear, .linearSegmented:
            let barHeight = rect.height * 0.08
            graphic = CGRect(x: body.minX, y: body.minY, width: body.width, height: barHeight)
            value = CGRect(x: body.minX, y: graphic.maxY + gap, width: body.width,
                           height: body.height - barHeight - gap)
        case .arc, .arcReverse, .arcSegmented, .arcSegmentedDense, .corner, .gForce, .leanAngle:
            if rect.width >= rect.height * 1.5 {
                let side = min(body.height, body.width * 0.40)
                graphic = CGRect(x: body.maxX - side, y: body.midY - side / 2, width: side, height: side)
                value = CGRect(x: body.minX, y: body.minY, width: body.width - side - gap, height: body.height)
            } else {
                let valueHeight = body.height * 0.30
                value = CGRect(x: body.minX, y: body.minY, width: body.width, height: valueHeight)
                graphic = CGRect(x: body.minX, y: value.maxY + gap, width: body.width,
                                 height: body.height - valueHeight - gap)
            }
        case .routePlot, .elevationPlot, .headingTape:
            graphic = body
            value = .zero
        default:
            graphic = .zero
            value = body
        }
    }
}
