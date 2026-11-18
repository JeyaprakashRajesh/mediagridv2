import Foundation

struct Track: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var size: Int64
    var ext: String
    var added: Int64
    var track: Int
    var year: Int
    var has_art: Bool
    // audio analysis from the PC (nil until it has reached this song) and the label derived from it
    var bpm: Double? = nil
    var energy: Double? = nil
    var punch: Double? = nil
    var rank: Int? = nil          // internet popularity (Deezer rank), only when the PC has looked it up
    var genre: String? = nil

    var addedDate: Date { Date(timeIntervalSince1970: TimeInterval(added) / 1000) }
}

struct MediaItem: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var kind: String // photo | video
    var size: Int64
    var modified: Int64
    var folder: String
    var from_iphone: Bool

    var isVideo: Bool { kind == "video" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(modified) / 1000) }
}

struct FileEntry: Codable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let dir: Bool
    var size: Int64?
    var modified: Int64?
    var ext: String?
    var place: Bool?
    var drive: Bool?

    var lowerExt: String { (ext ?? (name as NSString).pathExtension).lowercased() }
    var isImage: Bool { ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tif", "tiff"].contains(lowerExt) }
    var isVideo: Bool { ["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp"].contains(lowerExt) }
    var isAudio: Bool { ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "alac"].contains(lowerExt) }
}

struct FileListing: Codable {
    let path: String
    let parent: String?
    let entries: [FileEntry]
}

struct SharedItem: Codable, Identifiable, Hashable {
    let id: String
    let kind: String // text | file | clipboard
    var text: String?
    var name: String?
    var size: Int64?
    var from: String
    var at: Int64

    var date: Date { Date(timeIntervalSince1970: TimeInterval(at) / 1000) }
    var isFile: Bool { kind == "file" }
}

struct ServerInfo: Codable {
    let app: String
    let name: String
    let version: String
    let account: Bool
}

struct DiscoveredPC: Identifiable, Hashable {
    var id: String { "\(host):\(port)" }
    let name: String
    let host: String
    let port: Int
}

struct UserPlaylist: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var trackIDs: [String]
    var created = Date()
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Double {
    var mmss: String {
        guard isFinite, self > 0 else { return "0:00" }
        let s = Int(self)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
