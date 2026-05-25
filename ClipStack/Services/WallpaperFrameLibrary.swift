import Foundation

/// Built-in set of wallpaper frames. Real macOS wallpapers shipped in the
/// app bundle plus a couple of solid color options.
enum WallpaperFrameLibrary {
    static let all: [WallpaperFrame] = [
        WallpaperFrame(
            id: "tahoe-light",
            name: "Tahoe Light",
            style: .image(resourceName: "tahoe-light", swatchTint: .hex(0x4A90E2))
        ),
        WallpaperFrame(
            id: "tahoe-beach-day",
            name: "Tahoe Beach Day",
            style: .image(resourceName: "tahoe-beach-day", swatchTint: .hex(0x2E8FB4))
        ),
        WallpaperFrame(
            id: "sequoia-sunrise",
            name: "Sequoia Sunrise",
            style: .image(resourceName: "sequoia-sunrise", swatchTint: .hex(0xF2994A))
        ),
        WallpaperFrame(
            id: "sequoia-light",
            name: "Sequoia Light",
            style: .image(resourceName: "sequoia-light", swatchTint: .hex(0x4D7CFE))
        ),
        WallpaperFrame(
            id: "ventura",
            name: "Ventura",
            style: .image(resourceName: "ventura", swatchTint: .hex(0xF2994A))
        ),
        WallpaperFrame(
            id: "tiger",
            name: "Tiger",
            style: .image(resourceName: "tiger", swatchTint: .hex(0x3C6CB4))
        ),
        WallpaperFrame(
            id: "cheetah",
            name: "Cheetah",
            style: .image(resourceName: "cheetah", swatchTint: .hex(0x4B7DC4))
        ),
        WallpaperFrame(
            id: "graphite",
            name: "Graphite",
            style: .solid(.hex(0x2E2E2E))
        ),
    ]
}
