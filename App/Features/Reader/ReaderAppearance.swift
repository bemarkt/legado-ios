import CoreText
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ReaderPositionPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReaderStylePreset: Identifiable {
    let id: String
    let name: String
    let background: UIColor
    let foreground: UIColor

    static let legadoDefaults: [ReaderStylePreset] = [
        .init(id: "wechat", name: "微信读书", background: UIColor(hex: 0xC0EDC6), foreground: UIColor(hex: 0x0B0B0B)),
        .init(id: "preset1", name: "预设1", background: UIColor(hex: 0xFFFFFF), foreground: UIColor(hex: 0x000000)),
        .init(id: "preset2", name: "预设2", background: UIColor(hex: 0xDDC090), foreground: UIColor(hex: 0x3E3422)),
        .init(id: "preset3", name: "预设3", background: UIColor(hex: 0xC2D8AA), foreground: UIColor(hex: 0x596C44)),
        .init(id: "preset4", name: "预设4", background: UIColor(hex: 0xDBB8E2), foreground: UIColor(hex: 0x68516C)),
        .init(id: "preset5", name: "预设5", background: UIColor(hex: 0xABCEE0), foreground: UIColor(hex: 0x3D4C54)),
        .init(id: "night", name: "夜间", background: UIColor(hex: 0x000000), foreground: UIColor(hex: 0xADADAD))
    ]
    static let eInk = ReaderStylePreset(
        id: "eink",
        name: "E-Ink",
        background: UIColor(hex: 0xFFFFFF),
        foreground: UIColor(hex: 0x000000)
    )

    static func resolve(_ id: String) -> ReaderStylePreset {
        let migratedID = switch id {
        case "dark": "night"
        case "light": "preset1"
        case "paper": "preset2"
        default: id
        }
        return legadoDefaults.first(where: { $0.id == migratedID }) ?? legadoDefaults[0]
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

enum ReaderBackgroundStore {
    static let maximumPixelSize = 2560

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/reader-background.jpg")
    }

    static func load(from source: URL = url) -> UIImage? {
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        return try? downsample(data)
    }

    static func save(_ data: Data, to target: URL = url) throws -> UIImage {
        let image = try downsample(data)
        guard let encoded = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: target, options: .atomic)
        return image
    }

    private static func downsample(_ data: Data) throws -> UIImage {
        // Decode only the size used by the reader, including backgrounds saved
        // by older versions. Full-resolution camera photos can exhaust memory.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
              ] as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return UIImage(cgImage: image)
    }

    static func remove() { try? FileManager.default.removeItem(at: url) }
}

enum ReaderFontStore {
    struct Face: Codable, Hashable {
        var path: String
        var postScriptName: String
        var displayName: String
    }

    enum ImportError: LocalizedError {
        case unsupportedExtension(String)
        case emptyFile
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .unsupportedExtension(let ext):
                if ext.isEmpty { return "请选择 .ttf、.otf 或 .ttc 字体文件。" }
                return "暂不支持 .\(ext) 字体，请选择 .ttf、.otf 或 .ttc 文件。"
            case .emptyFile:
                return "字体文件为空，请重新选择。"
            case .unreadableFile:
                return "无法解析这个字体文件。如果它还在 iCloud 里没有下载完，请先在“文件”里下载后再导入。"
            }
        }
    }

    static let supportedExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    /// `.font` alone does not reliably match third-party `.ttf`/`.otf`/`.ttc`
    /// exports, so the concrete extension types are declared too. `public.data`
    /// stays last so a file with an unknown dynamic UTI can still be picked and
    /// rejected by `install(from:)` with a readable message.
    static var importableContentTypes: [UTType] {
        var types: [UTType] = [.font]
        for ext in supportedExtensions.sorted() {
            guard let type = UTType(filenameExtension: ext), !types.contains(type) else { continue }
            types.append(type)
        }
        types.append(.data)
        return types
    }

    /// 「文件」App 里可见的字体目录：Documents/fonts。
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fonts", isDirectory: true)
    }

    /// 旧版本把字体放在 Application Support，首次启动时搬过来。
    private static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/fonts", isDirectory: true)
    }

    /// 启动时调用：建目录、迁移旧字体、登记手动放进「文件」App 的字体。
    static func bootstrap() {
        loadManifestIfNeeded()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        migrateLegacyFonts()
        registerFontsInDirectory()
        saveManifest()
    }

    /// 已安装且文件仍在的字体，按显示名排序。
    static func installedFaces() -> [Face] {
        loadManifestIfNeeded()
        return manifest.values
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func migrateLegacyFonts() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where supportedExtensions.contains(entry.pathExtension.lowercased()) {
            let target = directory.appendingPathComponent(entry.lastPathComponent)
            guard !manager.fileExists(atPath: target.path) else { continue }
            try? manager.copyItem(at: entry, to: target)
        }
    }

    /// 扫描字体目录：手动拖进「文件」App 的字体在这里注册进 manifest。
    private static func registerFontsInDirectory() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where supportedExtensions.contains(entry.pathExtension.lowercased()) {
            if let known = manifest[entry.path], UIFont(name: known.postScriptName, size: 12) != nil { continue }
            guard let face = (try? faces(in: entry))?.first else { continue }
            manifest[entry.path] = face
        }
        fontCache.removeAll()
    }

    private static var manifestURL: URL {
        directory.appendingPathComponent("manifest.json")
    }

    // 进程级字体状态：仅在一次性导入与同步取字体路径上读写。
    nonisolated(unsafe) private static var manifest: [String: Face] = [:]
    nonisolated(unsafe) private static var manifestLoaded = false
    nonisolated(unsafe) private static var fontCache: [String: UIFont] = [:]

    /// Imports a font picked in the document picker. The picker hands back a
    /// security-scoped URL that may still be an iCloud placeholder, so the
    /// bytes are read through a file coordinator, copied into the container and
    /// registered for the lifetime of the process.
    static func install(from source: URL) throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupportedExtension(ext) }
        let data = coordinatedRead(from: source)
        guard !data.isEmpty else { throw ImportError.emptyFile }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try data.write(to: target, options: .atomic)
        do {
            guard let installed = try faces(in: target).first else { throw ImportError.unreadableFile }
            loadManifestIfNeeded()
            manifest[target.path] = installed
            saveManifest()
            fontCache.removeAll()
            return target.path
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    static func font(at path: String, size: CGFloat, weight: Int) -> UIFont? {
        guard !path.isEmpty, size > 0 else { return nil }
        let key = "\(path)|\(Int(size))|\(weight)"
        if let cached = fontCache[key] { return cached }
        guard let base = baseFont(at: path, size: size) else { return nil }
        let font: UIFont
        if weight == 1 {
            font = base.fontDescriptor.withSymbolicTraits(.traitBold)
                .map { UIFont(descriptor: $0, size: size) } ?? base
        } else if weight == 2 {
            let descriptor = base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.light.rawValue]
            ])
            font = UIFont(descriptor: descriptor, size: size)
        } else {
            font = base
        }
        if fontCache.count > 64 { fontCache.removeAll() }
        fontCache[key] = font
        return font
    }

    static func displayName(for path: String) -> String? {
        loadManifestIfNeeded()
        return manifest[path]?.displayName
    }

    static func isInstalled(_ path: String) -> Bool {
        !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    static func removeAll() {
        fontCache.removeAll()
        manifest.removeAll()
        manifestLoaded = true
        try? FileManager.default.removeItem(at: directory)
    }

    private static func baseFont(at path: String, size: CGFloat) -> UIFont? {
        loadManifestIfNeeded()
        if let face = manifest[path], let font = UIFont(name: face.postScriptName, size: size) {
            return font
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let face = (try? faces(in: url))?.first else { return nil }
        manifest[path] = face
        saveManifest()
        return UIFont(name: face.postScriptName, size: size)
    }

    /// Registers a font file in the current process and returns every usable
    /// face. `CTFontManagerRegisterFontsForURL` covers `.ttc` collections and
    /// CFF-flavoured `.otf` files that `CGFont` cannot describe by itself.
    private static func faces(in url: URL) throws -> [Face] {
        var registrationError: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &registrationError)
        let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
        var faces: [Face] = []
        for descriptor in descriptors {
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  !name.isEmpty,
                  UIFont(name: name, size: 12) != nil else { continue }
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
            faces.append(Face(path: url.path, postScriptName: name, displayName: family ?? name))
        }
        if faces.isEmpty,
           let provider = CGDataProvider(url: url as CFURL),
           let graphicsFont = CGFont(provider),
           let graphicsName = graphicsFont.postScriptName as String? {
            _ = CTFontManagerRegisterGraphicsFont(graphicsFont, nil)
            if UIFont(name: graphicsName, size: 12) != nil {
                faces.append(Face(path: url.path, postScriptName: graphicsName, displayName: graphicsName))
            }
        }
        return faces
    }

    private static func coordinatedRead(from url: URL) -> Data {
        var coordinationError: NSError?
        var readFailed = false
        var data = Data()
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                data = try Data(contentsOf: readable, options: .mappedIfSafe)
            } catch {
                readFailed = true
            }
        }
        if data.isEmpty || readFailed {
            return (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        }
        return data
    }

    private static func loadManifestIfNeeded() {
        guard !manifestLoaded else { return }
        manifestLoaded = true
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([String: Face].self, from: data) else { return }
        manifest = decoded
    }

    private static func saveManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }
}
