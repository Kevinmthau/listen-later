import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LocalMediaInspection: Sendable {
    let title: String
    let duration: TimeInterval
    let pixelWidth: Double
    let pixelHeight: Double
    let posterJPEGData: Data?
}

struct ImportedLocalMedia: Sendable {
    let mediaID: UUID
    let filename: String
    let posterFilename: String?
    let title: String
    let duration: TimeInterval
    let pixelWidth: Double
    let pixelHeight: Double
}

struct TrashedLocalMedia: Sendable, Equatable {
    let token: String
    let mediaID: UUID
}

enum LocalMediaLibraryError: LocalizedError, Equatable {
    case invalidMovie
    case symbolicLink
    case invalidIdentifier
    case missingMedia
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .invalidMovie:
            "The selected file is not a playable movie with a video track."
        case .symbolicLink:
            "Symbolic links can’t be imported. Select the original movie file."
        case .invalidIdentifier:
            "The local media identifier is invalid."
        case .missingMedia:
            "This video is not available on this Mac."
        case .destinationExists:
            "A local media item with this identifier already exists."
        }
    }
}

/// Owns every byte imported from Finder. Paths are derived from UUIDs and
/// sanitized filenames; no caller-provided path is ever used for deletion.
actor LocalMediaLibrary {
    typealias Inspector = @Sendable (URL) async throws -> LocalMediaInspection

    let root: URL
    private let fileManager: FileManager
    private let inspector: Inspector

    private var mediaRoot: URL { root.appending(path: "Media", directoryHint: .isDirectory) }
    private var stagingRoot: URL { root.appending(path: "Staging", directoryHint: .isDirectory) }
    private var trashRoot: URL { root.appending(path: "Trash", directoryHint: .isDirectory) }

    init(
        root: URL,
        fileManager: FileManager = .default,
        inspector: @escaping Inspector = { url in
            try await LocalMediaLibrary.inspectMovie(at: url)
        }
    ) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.inspector = inspector
    }

    func prepare() throws {
        try createOwnedDirectories()
    }

    func importVideo(from sourceURL: URL, mediaID: UUID = UUID()) async throws
        -> ImportedLocalMedia
    {
        try createOwnedDirectories()
        let filename = sanitizedFilename(sourceURL.lastPathComponent)
        let partial = stagingRoot.appending(
            path: ".partial-\(mediaID.uuidString)",
            directoryHint: .isDirectory
        )
        let stagedMovie = partial.appending(path: filename, directoryHint: .notDirectory)
        let finalDirectory = mediaDirectory(for: mediaID)
        guard !fileManager.fileExists(atPath: finalDirectory.path) else {
            throw LocalMediaLibraryError.destinationExists
        }

        try? fileManager.removeItem(at: partial)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: false)
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: partial)
            }
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try Task.checkCancellation()
        let sourceValues = try sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard sourceValues.isSymbolicLink != true else {
            throw LocalMediaLibraryError.symbolicLink
        }
        try fileManager.copyItem(at: sourceURL, to: stagedMovie)
        let stagedValues = try stagedMovie.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard stagedValues.isSymbolicLink != true else {
            throw LocalMediaLibraryError.symbolicLink
        }
        try Task.checkCancellation()
        let inspection = try await inspector(stagedMovie)
        try Task.checkCancellation()

        let posterFilename: String?
        if let posterData = inspection.posterJPEGData {
            let name = "poster.jpg"
            try posterData.write(
                to: partial.appending(path: name, directoryHint: .notDirectory),
                options: .atomic
            )
            posterFilename = name
        } else {
            posterFilename = nil
        }

        // The staging and final directories share a volume. moveItem maps to
        // an atomic rename, so a queue row never points at a partial copy.
        try fileManager.moveItem(at: partial, to: finalDirectory)
        committed = true
        return ImportedLocalMedia(
            mediaID: mediaID,
            filename: filename,
            posterFilename: posterFilename,
            title: inspection.title,
            duration: inspection.duration,
            pixelWidth: inspection.pixelWidth,
            pixelHeight: inspection.pixelHeight
        )
    }

    func playbackURL(mediaID: UUID, filename: String?) -> URL? {
        guard let filename, isSafeFilename(filename) else { return nil }
        let candidate = mediaDirectory(for: mediaID)
            .appending(path: filename, directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    func posterURL(mediaID: UUID, filename: String?) -> URL? {
        playbackURL(mediaID: mediaID, filename: filename)
    }

    func contains(mediaID: UUID, filename: String?) -> Bool {
        playbackURL(mediaID: mediaID, filename: filename) != nil
    }

    func moveToTrash(mediaID: UUID) throws -> TrashedLocalMedia? {
        try createOwnedDirectories()
        let source = mediaDirectory(for: mediaID)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let token = "\(mediaID.uuidString)-\(UUID().uuidString)"
        let destination = trashRoot.appending(path: token, directoryHint: .isDirectory)
        // A move preserves the directory's old modification date. Stamp the
        // app-owned source first so retention starts when it is deleted, not
        // when the media was originally imported.
        try fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: source.path
        )
        try fileManager.moveItem(at: source, to: destination)
        return TrashedLocalMedia(token: token, mediaID: mediaID)
    }

    @discardableResult
    func restoreFromTrash(_ trashed: TrashedLocalMedia) throws -> Bool {
        guard isSafeTrashToken(trashed.token) else {
            throw LocalMediaLibraryError.invalidIdentifier
        }
        try createOwnedDirectories()
        let source = trashRoot.appending(path: trashed.token, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: source.path) else { return false }
        let destination = mediaDirectory(for: trashed.mediaID)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw LocalMediaLibraryError.destinationExists
        }
        try fileManager.moveItem(at: source, to: destination)
        return true
    }

    func reconcile(referencedMediaIDs: Set<UUID>) throws {
        try createOwnedDirectories()
        for directory in try ownedDirectoryContents(at: mediaRoot) {
            guard let mediaID = UUID(uuidString: directory.lastPathComponent) else {
                continue
            }
            if !referencedMediaIDs.contains(mediaID) {
                _ = try moveToTrash(mediaID: mediaID)
            }
        }
    }

    func cleanStalePartials(
        olderThan cutoff: Date = Date().addingTimeInterval(-24 * 60 * 60)
    ) throws {
        try createOwnedDirectories()
        for url in try ownedDirectoryContents(at: stagingRoot)
        where url.lastPathComponent.hasPrefix(".partial-") {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if (values.contentModificationDate ?? .distantPast) < cutoff {
                try fileManager.removeItem(at: url)
            }
        }
    }

    func cleanTrash(
        olderThan cutoff: Date = Date().addingTimeInterval(-7 * 24 * 60 * 60)
    ) throws {
        try createOwnedDirectories()
        for url in try ownedDirectoryContents(at: trashRoot) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if (values.contentModificationDate ?? .distantPast) < cutoff {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func createOwnedDirectories() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for directory in [mediaRoot, stagingRoot, trashRoot] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func mediaDirectory(for mediaID: UUID) -> URL {
        mediaRoot.appending(path: mediaID.uuidString, directoryHint: .isDirectory)
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let candidate = URL(fileURLWithPath: filename).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
        return candidate.isEmpty ? "movie.mov" : candidate
    }

    private func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename == URL(fileURLWithPath: filename).lastPathComponent
            && !filename.contains("/")
            && !filename.contains(":")
    }

    private func isSafeTrashToken(_ token: String) -> Bool {
        !token.isEmpty
            && token == URL(fileURLWithPath: token).lastPathComponent
            && !token.contains("/")
            && !token.contains(":")
    }

    private func ownedDirectoryContents(at directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: []
        )
    }

    nonisolated static func inspectMovie(at url: URL) async throws -> LocalMediaInspection {
        let asset = AVURLAsset(url: url)
        let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard isPlayable, let track = tracks.first else {
            throw LocalMediaLibraryError.invalidMovie
        }
        let (naturalSize, preferredTransform) = try await track.load(
            .naturalSize,
            .preferredTransform
        )
        let transformed = naturalSize.applying(preferredTransform)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw LocalMediaLibraryError.invalidMovie
        }
        let title = url.deletingPathExtension().lastPathComponent
        return LocalMediaInspection(
            title: title.isEmpty ? "Local video" : title,
            duration: seconds,
            pixelWidth: abs(transformed.width),
            pixelHeight: abs(transformed.height),
            posterJPEGData: await posterJPEG(for: asset, duration: seconds)
        )
    }

    nonisolated private static func posterJPEG(
        for asset: AVAsset,
        duration: TimeInterval
    ) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1_280, height: 1_280)
        do {
            let requested = CMTime(
                seconds: min(max(duration * 0.1, 0), 5),
                preferredTimescale: 600
            )
            let (image, _) = try await generator.image(at: requested)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else { return nil }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { return nil }
            return data as Data
        } catch {
            return nil
        }
    }
}
