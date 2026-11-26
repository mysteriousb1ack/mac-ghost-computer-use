import Foundation
import Darwin

func pluginRoot() throws -> URL {
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .standardizedFileURL.resolvingSymlinksInPath()
    let dir = exe.deletingLastPathComponent()
    if dir.lastPathComponent == "bin" { return dir.deletingLastPathComponent() }
    // A SwiftPM product in this checkout also supports direct CLI invocation.
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    guard exe.path.hasPrefix(source.path + "/.build/") else { throw Failure("POLICY_UNAVAILABLE", "Unknown plugin root.") }
    return source
}

struct CaptureFile {
    let root: URL, filename: String
    var path: String { root.appendingPathComponent(".local/captures").appendingPathComponent(filename).path }

    init(root: URL, requested: String) throws {
        let name = (requested as NSString).lastPathComponent
        let directory = root.appendingPathComponent(".local/captures")
        guard !name.hasPrefix("."), name.utf8.count <= 255, name.lowercased().hasSuffix(".png"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              requested == name || requested == directory.appendingPathComponent(name).path
        else { throw Failure("INVALID_ARGUMENT", "Use a fresh PNG filename inside .local/captures.") }
        self.root = root
        filename = name
    }

    func save(_ data: Data) throws {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        func child(_ parent: Int32, _ name: String) throws -> Int32 {
            guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw Failure("OUTPUT_ERROR", "Cannot create capture directory.") }
            let fd = openat(parent, name, flags)
            guard fd >= 0 else { throw Failure("OUTPUT_ERROR", "Unsafe or unavailable capture directory.") }
            return fd
        }
        let base = open(root.path, flags)
        guard base >= 0 else { throw Failure("OUTPUT_ERROR", "Cannot open plugin directory.") }
        defer { close(base) }
        let state = try child(base, ".local")
        defer { close(state) }
        let dir = try child(state, "captures")
        defer { close(dir) }
        let temp = ".capture-" + UUID().uuidString
        let fd = openat(dir, temp, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, 0o600)
        guard fd >= 0 else { throw Failure("OUTPUT_ERROR", "Cannot stage PNG.") }
        defer { unlinkat(dir, temp, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { throw Failure("OUTPUT_ERROR", "Cannot write PNG.") }
        guard linkat(dir, temp, dir, filename, 0) == 0 else { throw Failure("OUTPUT_ERROR", "Use a new PNG filename in the capture directory.") }
    }
}
