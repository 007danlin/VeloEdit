import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct BackgroundColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    fileprivate var cgColor: CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: 1)
    }
}

public enum BackgroundDecoration: String, Sendable {
    case none, curtain, parchment, bubbles, underwater, technical, stripes, stars
    case retro, paper, silk, triangles, checkerboard, rings, cubes, diagonals, dots, mosaic
}

public enum BackgroundAnimationStyle: String, CaseIterable, Sendable {
    case cinematic, atmospheric, water, rain, snow, stars, dust, confetti, petals, floating, analog
    case fire, aurora, clouds, smoke, bokeh, fog, leaves
}

public enum BackgroundCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case nature, atmospheric, abstract, titles, universal, colors

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .nature: return "Природа"
        case .atmospheric: return "Атмосфера"
        case .abstract: return "Абстракции"
        case .titles: return "Для титров"
        case .universal: return "Праздник"
        case .colors: return "Цвета"
        }
    }
}

/// Built-in, resolution-independent backgrounds inspired by iMovie's background browser.
/// A selected preset is materialized inside the project package as a PNG, so the normal
/// photo pipeline can preview, edit, render and export it without special render paths.
public enum BackgroundPreset: String, CaseIterable, Identifiable, Sendable {
    case curtain, parchment, bubbles, underwater, midnightGradient, technical, stripes, stars
    case retro, paper, orangeSilk, beigeSilk, abstractShapes, checkerboard, rings, cubes
    case diagonals, dots, mosaic, triangles
    case whiteGradient, grayGradient, blueGradient, greenGradient, yellowGradient
    case redGradient, purpleGradient, pinkGradient
    case black, white, green, blue, gray, brown, orange, red
    case sunset, clouds, forest, rain, snow
    case fire, particles, smoke, fog, lensFlare, aurora
    case smoothGradient, liquidAbstract, inkInWater, glowingLines, bokeh, energy
    case film, vhs, noise, lightTexture
    case confetti, balloons, hearts, snowflakes, petals, raindropsGlass

    public var id: String { rawValue }

    /// Keeps older projects compatible while presenting a curated browser
    /// instead of carrying every early experimental pattern into the UI.
    public var isVisibleInCatalog: Bool {
        switch self {
        case .stripes, .orangeSilk, .beigeSilk, .abstractShapes, .checkerboard, .rings,
             .cubes, .diagonals, .dots, .mosaic, .triangles, .whiteGradient,
             .grayGradient, .blueGradient, .greenGradient, .yellowGradient,
             .redGradient, .purpleGradient, .pinkGradient, .energy, .glowingLines,
             .bubbles, .fire, .smoke, .bokeh:
            return false
        default:
            return true
        }
    }

    public static var catalogPresets: [BackgroundPreset] {
        allCases.filter(\.isVisibleInCatalog)
    }

    public var localizedTitle: String {
        switch self {
        case .curtain: return "Занавес"
        case .parchment: return "Органический"
        case .bubbles: return "Пузыри"
        case .underwater: return "Под водой"
        case .midnightGradient: return "Киношный тёмный градиент"
        case .technical: return "Техническая"
        case .stripes: return "Полосы"
        case .stars: return "Звёздное небо"
        case .retro: return "Ретро"
        case .paper: return "Бумага"
        case .orangeSilk: return "Оранжевый шёлк"
        case .beigeSilk: return "Бежевый шёлк"
        case .abstractShapes: return "Абстрактные формы"
        case .checkerboard: return "Шахматная доска"
        case .rings: return "Круги"
        case .cubes: return "Кубы"
        case .diagonals: return "Диагонали"
        case .dots: return "Точки"
        case .mosaic: return "Мозаика"
        case .triangles: return "Треугольники"
        case .whiteGradient: return "Белый градиент"
        case .grayGradient: return "Серый градиент"
        case .blueGradient: return "Синий градиент"
        case .greenGradient: return "Зелёный градиент"
        case .yellowGradient: return "Жёлтый градиент"
        case .redGradient: return "Красный градиент"
        case .purpleGradient: return "Лиловый градиент"
        case .pinkGradient: return "Розовый градиент"
        case .black: return "Чёрный"
        case .white: return "Белый"
        case .green: return "Зелёный"
        case .blue: return "Синий"
        case .gray: return "Серый"
        case .brown: return "Коричневый"
        case .orange: return "Оранжевый"
        case .red: return "Красный"
        case .sunset: return "Закат"
        case .clouds: return "Облака"
        case .forest: return "Лес"
        case .rain: return "Дождь"
        case .snow: return "Снег"
        case .fire: return "Огонь"
        case .particles: return "Частицы / пыль"
        case .smoke: return "Дым"
        case .fog: return "Туман"
        case .lensFlare: return "Световые блики"
        case .aurora: return "Северное сияние"
        case .smoothGradient: return "Плавный градиент"
        case .liquidAbstract: return "Жидкая абстракция"
        case .inkInWater: return "Чернила в воде"
        case .glowingLines: return "Светящиеся линии"
        case .bokeh: return "Bokeh"
        case .energy: return "Электричество"
        case .film: return "Плёнка"
        case .vhs: return "Старый телевизор / VHS"
        case .noise: return "Шум / зерно"
        case .lightTexture: return "Светлая текстура"
        case .confetti: return "Конфетти"
        case .balloons: return "Воздушные шарики"
        case .hearts: return "Сердца"
        case .snowflakes: return "Снежинки"
        case .petals: return "Лепестки"
        case .raindropsGlass: return "Капли на стекле"
        }
    }

    public var category: BackgroundCategory {
        switch self {
        case .stars, .sunset, .clouds, .underwater, .forest, .rain, .snow:
            return .nature
        case .fire, .particles, .smoke, .fog, .lensFlare, .bubbles, .aurora:
            return .atmospheric
        case .abstractShapes, .checkerboard, .rings, .cubes, .diagonals, .dots, .mosaic, .triangles,
             .whiteGradient, .grayGradient, .blueGradient, .greenGradient, .yellowGradient,
             .redGradient, .purpleGradient, .pinkGradient, .smoothGradient, .liquidAbstract, .inkInWater,
             .glowingLines, .bokeh, .energy:
            return .abstract
        case .curtain, .parchment, .midnightGradient, .technical, .stripes, .retro, .paper,
             .orangeSilk, .beigeSilk, .film, .vhs, .noise, .lightTexture:
            return .titles
        case .confetti, .balloons, .hearts, .snowflakes, .petals, .raindropsGlass:
            return .universal
        case .black, .white, .green, .blue, .gray, .brown, .orange, .red:
            return .colors
        }
    }

    /// Only true flat colors remain still. Every textured, photographic or
    /// patterned preset gets a subtle motion pass during playback and export.
    public var isSolid: Bool {
        switch self {
        case .black, .white, .green, .blue, .gray, .brown, .orange, .red: return true
        default: return false
        }
    }

    public var animationMotion: ClipEffect? {
        guard !isSolid else { return nil }
        return .kenBurns
    }

    /// All non-solid backgrounds use the same simple push-in renderer. The
    /// style token only selects that path; it no longer enables particles or
    /// preset-specific movement.
    public var animationStyle: BackgroundAnimationStyle? {
        isSolid ? nil : .cinematic
    }

    public var colors: [BackgroundColor] {
        switch self {
        case .curtain: return [.init(0.08, 0.01, 0), .init(0.62, 0.03, 0), .init(0.12, 0.01, 0)]
        case .parchment: return [.init(0.88, 0.84, 0.72), .init(0.57, 0.49, 0.36)]
        case .bubbles: return [.init(0.82, 0.02, 0.28), .init(1, 0.34, 0.12), .init(0.92, 0.02, 0.20)]
        case .underwater: return [.init(0.03, 0.75, 0.90), .init(0.00, 0.23, 0.38)]
        case .midnightGradient: return [.init(0, 0, 0.01), .init(0.23, 0.23, 0.36)]
        case .technical: return [.init(0.02, 0.05, 0.07), .init(0.00, 0.01, 0.02)]
        case .stripes: return [.init(0.70, 0.80, 0.79), .init(0.35, 0.48, 0.48)]
        case .stars: return [.init(0, 0.02, 0.025), .init(0, 0, 0)]
        case .retro: return [.init(0.97, 0.76, 0.42), .init(0.94, 0.58, 0.25)]
        case .paper: return [.init(0.90, 0.89, 0.77), .init(0.70, 0.69, 0.58)]
        case .orangeSilk: return [.init(0.98, 0.68, 0.20), .init(0.63, 0.30, 0.06)]
        case .beigeSilk: return [.init(0.96, 0.94, 0.77), .init(0.74, 0.69, 0.52)]
        case .abstractShapes: return [.init(1, 0.00, 0.22), .init(1, 0.35, 0.55)]
        case .checkerboard: return [.init(0.05, 0.82, 0.72), .init(1, 0.58, 0.75)]
        case .rings: return [.init(0.92, 0.00, 0.80), .init(0.20, 0.00, 0.24)]
        case .cubes: return [.init(0.00, 0.92, 0.85), .init(1, 0.94, 0.00)]
        case .diagonals: return [.init(0.66, 0.00, 0.12), .init(0.30, 0.00, 0.08)]
        case .dots: return [.init(1, 0.00, 0.28), .init(1, 0.45, 0.54)]
        case .mosaic: return [.init(1, 0.70, 0.00), .init(0.92, 0.27, 0.00)]
        case .triangles: return [.init(0.00, 0.56, 0.95), .init(0.00, 0.82, 0.80)]
        case .whiteGradient: return [.init(0.92, 0.92, 0.92), .init(0.47, 0.47, 0.47)]
        case .grayGradient: return [.init(0.35, 0.35, 0.35), .init(0.08, 0.08, 0.08)]
        case .blueGradient: return [.init(0.18, 0.38, 0.88), .init(0.62, 0.82, 0.96)]
        case .greenGradient: return [.init(0.76, 1.00, 0.20), .init(0.26, 0.90, 0.82)]
        case .yellowGradient: return [.init(1.00, 0.78, 0.20), .init(0.88, 0.40, 0.04)]
        case .redGradient: return [.init(0.95, 0.06, 0.12), .init(0.98, 0.16, 0.42)]
        case .purpleGradient: return [.init(0.25, 0.00, 0.38), .init(0.50, 0.03, 0.92)]
        case .pinkGradient: return [.init(0.90, 0.08, 0.60), .init(0.75, 0.38, 0.72)]
        case .black: return [.init(0, 0, 0)]
        case .white: return [.init(0.98, 0.98, 0.98)]
        case .green: return [.init(0.12, 0.66, 0.22)]
        case .blue: return [.init(0.18, 0.34, 0.62)]
        case .gray: return [.init(0.24, 0.28, 0.34)]
        case .brown: return [.init(0.60, 0.42, 0.23)]
        case .orange: return [.init(1.00, 0.28, 0.08)]
        case .red: return [.init(0.72, 0.02, 0.08)]
        case .sunset: return [.init(0.98, 0.32, 0.18), .init(0.30, 0.08, 0.42)]
        case .clouds: return [.init(0.30, 0.68, 0.96), .init(0.90, 0.96, 1.00)]
        case .forest: return [.init(0.03, 0.18, 0.10), .init(0.20, 0.44, 0.25)]
        case .rain: return [.init(0.05, 0.10, 0.16), .init(0.20, 0.30, 0.38)]
        case .snow: return [.init(0.82, 0.90, 0.96), .init(0.48, 0.63, 0.72)]
        case .fire: return [.init(0.95, 0.18, 0.01), .init(0.06, 0.01, 0.00)]
        case .particles: return [.init(0.02, 0.01, 0.00), .init(0.75, 0.47, 0.08)]
        case .smoke: return [.init(0.05, 0.05, 0.06), .init(0.48, 0.50, 0.54)]
        case .fog: return [.init(0.12, 0.18, 0.22), .init(0.56, 0.62, 0.66)]
        case .lensFlare: return [.init(0.00, 0.02, 0.08), .init(0.12, 0.42, 0.95)]
        case .aurora: return [.init(0.00, 0.08, 0.15), .init(0.12, 0.90, 0.55), .init(0.25, 0.16, 0.60)]
        case .smoothGradient: return [.init(0.05, 0.72, 0.92), .init(0.44, 0.16, 0.86), .init(0.94, 0.20, 0.62)]
        case .liquidAbstract: return [.init(0.00, 0.70, 0.90), .init(0.92, 0.05, 0.62), .init(0.22, 0.04, 0.55)]
        case .inkInWater: return [.init(0.02, 0.02, 0.08), .init(0.06, 0.70, 0.85), .init(0.76, 0.04, 0.62)]
        case .glowingLines: return [.init(0.00, 0.02, 0.08), .init(0.10, 0.82, 1.00), .init(0.50, 0.10, 0.90)]
        case .bokeh: return [.init(0.02, 0.03, 0.08), .init(0.86, 0.50, 0.12)]
        case .energy: return [.init(0.00, 0.02, 0.10), .init(0.18, 0.40, 1.00), .init(0.60, 0.08, 0.90)]
        case .film: return [.init(0.04, 0.04, 0.04), .init(0.20, 0.16, 0.12)]
        case .vhs: return [.init(0.02, 0.02, 0.06), .init(0.12, 0.24, 0.35)]
        case .noise: return [.init(0.12, 0.12, 0.12), .init(0.32, 0.32, 0.32)]
        case .lightTexture: return [.init(0.98, 0.96, 0.89), .init(0.82, 0.80, 0.72)]
        case .confetti: return [.init(0.02, 0.04, 0.12), .init(0.40, 0.12, 0.60)]
        case .balloons: return [.init(0.68, 0.86, 0.98), .init(0.96, 0.76, 0.84)]
        case .hearts: return [.init(0.18, 0.01, 0.06), .init(0.80, 0.08, 0.30)]
        case .snowflakes: return [.init(0.01, 0.12, 0.30), .init(0.30, 0.72, 0.94)]
        case .petals: return [.init(0.98, 0.88, 0.90), .init(0.90, 0.52, 0.68)]
        case .raindropsGlass: return [.init(0.02, 0.14, 0.28), .init(0.70, 0.40, 0.10)]
        }
    }

    public var decoration: BackgroundDecoration {
        switch self {
        case .curtain: return .curtain
        case .parchment: return .parchment
        case .bubbles: return .bubbles
        case .underwater: return .underwater
        case .technical: return .technical
        case .stripes: return .stripes
        case .stars: return .stars
        case .retro: return .retro
        case .paper: return .paper
        case .orangeSilk, .beigeSilk: return .silk
        case .abstractShapes: return .triangles
        case .checkerboard: return .checkerboard
        case .rings: return .rings
        case .cubes: return .cubes
        case .diagonals: return .diagonals
        case .dots: return .dots
        case .mosaic: return .mosaic
        case .triangles: return .triangles
        default: return .none
        }
    }

    public var bundledResourceFileName: String? {
        switch self {
        case .curtain: return "curtain"
        case .underwater: return "underwater"
        case .stars: return "stars"
        case .sunset: return "sunset"
        case .clouds: return "clouds"
        case .forest: return "forest"
        case .rain: return "rain"
        case .snow: return "snow"
        case .particles: return "particles"
        case .fog: return "fog"
        case .lensFlare: return "lensflare"
        case .aurora: return "aurora"
        case .liquidAbstract: return "liquid"
        case .inkInWater: return "ink"
        case .film: return "film"
        case .vhs: return "vhs"
        case .noise: return "noise"
        case .lightTexture: return "lighttexture"
        case .confetti: return "confetti"
        case .balloons: return "balloons"
        case .hearts: return "hearts"
        case .snowflakes: return "snowflakes"
        case .petals: return "petals"
        case .raindropsGlass: return "raindrops"
        default: return nil
        }
    }

    public func bundledImageURL(in bundle: Bundle = .main) -> URL? {
        guard let bundledResourceFileName else { return nil }
        return bundle.url(forResource: bundledResourceFileName, withExtension: "png", subdirectory: "Backgrounds")
    }

    /// Version 3 adds the categorized illustrated catalogue and invalidates
    /// any earlier procedural copies already cached inside projects.
    public var contentHashPrefix: String { "veloedit-background-v3-\(rawValue)-" }

    public static func preset(for asset: MediaAsset) -> BackgroundPreset? {
        guard asset.contentHash.hasPrefix("veloedit-background-v1-") ||
                asset.contentHash.hasPrefix("veloedit-background-v2-") ||
                asset.contentHash.hasPrefix("veloedit-background-v3-") else { return nil }
        return allCases.first { preset in
            asset.contentHash.contains("-\(preset.rawValue)-")
        }
    }
}

public enum BackgroundPresetRenderer {
    public static func render(
        _ preset: BackgroundPreset,
        width: Int,
        height: Int,
        sourceImageURL: URL? = nil,
        to destination: URL
    ) throws {
        let image = try makeImage(preset, width: width, height: height, sourceImageURL: sourceImageURL)
        guard let imageDestination = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DerivedMediaError.cannotCreateDestination
        }
        CGImageDestinationAddImage(imageDestination, image, nil)
        guard CGImageDestinationFinalize(imageDestination) else { throw DerivedMediaError.cannotCreateDestination }
    }

    /// The browser and project materializer both call this method, which keeps
    /// the card artwork and final timeline media visually identical.
    public static func makeImage(
        _ preset: BackgroundPreset,
        width: Int,
        height: Int,
        sourceImageURL: URL? = nil
    ) throws -> CGImage {
        let width = max(16, width)
        let height = max(16, height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw DerivedMediaError.cannotCreateDestination }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let sourceImageURL,
           let source = CGImageSourceCreateWithURL(sourceImageURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            drawAspectFill(image, in: context, rect: rect)
        } else {
            drawGradient(preset.colors, in: context, rect: rect, colorSpace: colorSpace)
            drawDecoration(preset.decoration, colors: preset.colors, in: context, rect: rect)
        }
        guard let image = context.makeImage() else { throw DerivedMediaError.cannotCreateDestination }
        return image
    }

    private static func drawAspectFill(_ image: CGImage, in context: CGContext, rect: CGRect) {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let scale = max(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let target = CGRect(
            x: rect.midX - sourceSize.width * scale / 2,
            y: rect.midY - sourceSize.height * scale / 2,
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        context.interpolationQuality = .high
        context.draw(image, in: target)
    }

    private static func drawGradient(_ colors: [BackgroundColor], in context: CGContext, rect: CGRect, colorSpace: CGColorSpace) {
        if colors.count == 1 {
            context.setFillColor(colors[0].cgColor)
            context.fill(rect)
            return
        }
        let values = colors.map(\.cgColor) as CFArray
        let locations = colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: values, locations: locations) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }

    private static func drawDecoration(_ decoration: BackgroundDecoration, colors: [BackgroundColor], in context: CGContext, rect: CGRect) {
        let unit = min(rect.width, rect.height)
        context.saveGState()
        switch decoration {
        case .none:
            break
        case .curtain:
            for index in 0..<12 {
                let x = rect.width * CGFloat(index) / 12
                let shade = index.isMultiple(of: 2) ? 0.24 : 0.06
                context.setFillColor(CGColor(gray: 0, alpha: shade))
                context.fill(CGRect(x: x, y: 0, width: rect.width / 12, height: rect.height))
            }
        case .parchment, .paper:
            for index in 0..<180 {
                let x = pseudo(index * 17) * rect.width
                let y = pseudo(index * 31 + 7) * rect.height
                let size = 1 + pseudo(index * 47) * 5
                context.setFillColor(CGColor(gray: index.isMultiple(of: 2) ? 0 : 1, alpha: 0.035))
                context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
            }
            context.setStrokeColor(CGColor(gray: 0.25, alpha: decoration == .parchment ? 0.28 : 0.08))
            context.setLineWidth(unit * 0.015)
            context.stroke(rect.insetBy(dx: unit * 0.018, dy: unit * 0.018))
        case .bubbles:
            for index in 0..<18 {
                let radius = unit * (0.035 + pseudo(index * 13) * 0.10)
                let x = pseudo(index * 29 + 3) * rect.width
                let y = pseudo(index * 43 + 11) * rect.height
                context.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.20, alpha: 0.15))
                context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        case .underwater:
            context.setFillColor(CGColor(red: 0.65, green: 0.98, blue: 1, alpha: 0.12))
            for index in 0..<7 {
                let x = rect.width * (CGFloat(index) + 0.4) / 7
                context.move(to: CGPoint(x: x, y: rect.maxY))
                context.addLine(to: CGPoint(x: x + rect.width * 0.08, y: 0))
                context.addLine(to: CGPoint(x: x + rect.width * 0.22, y: 0))
                context.addLine(to: CGPoint(x: x + rect.width * 0.05, y: rect.maxY))
                context.closePath()
                context.fillPath()
            }
        case .technical:
            context.setStrokeColor(CGColor(red: 0.35, green: 0.65, blue: 0.78, alpha: 0.10))
            context.setLineWidth(1)
            let step = max(18, unit * 0.08)
            stride(from: CGFloat(0), through: rect.width, by: step).forEach { x in
                context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: rect.height))
            }
            stride(from: CGFloat(0), through: rect.height, by: step).forEach { y in
                context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: rect.width, y: y))
            }
            context.strokePath()
        case .stripes, .silk:
            let step = max(5, unit * 0.018)
            for (index, x) in stride(from: CGFloat(0), through: rect.width, by: step).enumerated() {
                context.setFillColor(CGColor(gray: index.isMultiple(of: 2) ? 1 : 0, alpha: decoration == .silk ? 0.035 : 0.07))
                context.fill(CGRect(x: x, y: 0, width: step * 0.55, height: rect.height))
            }
        case .stars:
            for index in 0..<170 {
                let size = 1 + pseudo(index * 23) * 3
                context.setFillColor(CGColor(gray: 1, alpha: 0.18 + pseudo(index * 41) * 0.70))
                context.fillEllipse(in: CGRect(x: pseudo(index * 17) * rect.width, y: pseudo(index * 37) * rect.height, width: size, height: size))
            }
        case .retro:
            context.setFillColor(CGColor(red: 1, green: 0.86, blue: 0.55, alpha: 0.38))
            context.fill(CGRect(x: rect.width * 0.06, y: rect.height * 0.08, width: rect.width * 0.88, height: rect.height * 0.84))
            context.setStrokeColor(CGColor(red: 0.58, green: 0.28, blue: 0.08, alpha: 0.32))
            context.setLineWidth(unit * 0.018)
            context.stroke(CGRect(x: rect.width * 0.08, y: rect.height * 0.11, width: rect.width * 0.84, height: rect.height * 0.78))
        case .checkerboard:
            let step = max(20, unit * 0.16)
            for row in 0...Int(rect.height / step) {
                for column in 0...Int(rect.width / step) where (row + column).isMultiple(of: 2) {
                    context.setFillColor(colors.last?.cgColor ?? CGColor(gray: 1, alpha: 1))
                    context.fill(CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: step, height: step))
                }
            }
        case .rings:
            let center = CGPoint(x: rect.midX, y: rect.midY)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.50))
            context.setLineWidth(max(2, unit * 0.012))
            for radius in stride(from: unit * 0.04, through: unit * 0.78, by: unit * 0.045) {
                context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        case .cubes, .triangles, .mosaic:
            let step = max(22, unit * 0.16)
            for row in 0...Int(rect.height / step) {
                for column in 0...Int(rect.width / step) {
                    let x = CGFloat(column) * step
                    let y = CGFloat(row) * step
                    context.setFillColor((row + column).isMultiple(of: 2) ? (colors.last?.cgColor ?? colors[0].cgColor) : colors[0].cgColor)
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x + step, y: y))
                    context.addLine(to: CGPoint(x: x + (decoration == .triangles ? step * 0.5 : step), y: y + step))
                    context.closePath(); context.fillPath()
                }
            }
        case .diagonals:
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.28))
            context.setLineWidth(max(5, unit * 0.04))
            let step = unit * 0.12
            for offset in stride(from: -rect.height, through: rect.width, by: step) {
                context.move(to: CGPoint(x: offset, y: 0)); context.addLine(to: CGPoint(x: offset + rect.height, y: rect.height))
            }
            context.strokePath()
        case .dots:
            let step = max(12, unit * 0.06)
            context.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.45, alpha: 0.62))
            for y in stride(from: step / 2, through: rect.height, by: step) {
                for x in stride(from: step / 2, through: rect.width, by: step) {
                    context.fillEllipse(in: CGRect(x: x, y: y, width: step * 0.14, height: step * 0.14))
                }
            }
        }
        context.restoreGState()
    }

    private static func pseudo(_ value: Int) -> CGFloat {
        let x = sin(Double(value) * 12.9898) * 43_758.5453
        return CGFloat(x - floor(x))
    }
}
