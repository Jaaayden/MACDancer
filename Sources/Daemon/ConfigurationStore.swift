import Darwin
import Foundation

/// Everything the daemon remembers between launches.
struct ConfigurationDocument: Codable, Equatable, Sendable {
  /// Keyed by `InterfaceSnapshot.deviceKey`.
  var policies: [String: InterfacePolicy] = [:]
  var histories: [String: HistoryLedger] = [:]
  var pendingRotations: [String: PendingRotation] = [:]
  var automation = AutomationSettings()

  init(
    policies: [String: InterfacePolicy] = [:],
    histories: [String: HistoryLedger] = [:],
    pendingRotations: [String: PendingRotation] = [:],
    automation: AutomationSettings = AutomationSettings()
  ) {
    self.policies = policies
    self.histories = histories
    self.pendingRotations = pendingRotations
    self.automation = automation
  }

  // Missing keys default, so files written by older builds still load. (Their
  // `pendingOperations` key is ignored; that work is simply re-queued later.)
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    policies = try container.decodeIfPresent([String: InterfacePolicy].self, forKey: .policies) ?? [:]
    histories = try container.decodeIfPresent([String: HistoryLedger].self, forKey: .histories) ?? [:]
    pendingRotations = try container.decodeIfPresent([String: PendingRotation].self, forKey: .pendingRotations) ?? [:]
    automation = try container.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? AutomationSettings()
  }
}

protocol ConfigurationStoring: AnyObject {
  /// Never throws: a missing file gives defaults; an unreadable one is moved
  /// aside and reported through `warning`.
  func load() -> (document: ConfigurationDocument, warning: String?)
  func save(_ document: ConfigurationDocument) throws
}

/// Stores the document as JSON in a root-only directory, replaced atomically.
final class ConfigurationStore: ConfigurationStoring {
  static let defaultFileURL = URL(
    fileURLWithPath: "/Library/Application Support/local.macdancer.MACDancer/configuration.json"
  )
  static let schemaVersion = 1

  let fileURL: URL
  private var directoryPath: String { fileURL.deletingLastPathComponent().path }
  private let enforceRootOwnership: Bool

  init(fileURL: URL = ConfigurationStore.defaultFileURL) {
    self.fileURL = fileURL
    enforceRootOwnership = fileURL == Self.defaultFileURL
  }

  private struct Envelope: Codable {
    let schemaVersion: Int
    let configuration: ConfigurationDocument
  }

  func load() -> (document: ConfigurationDocument, warning: String?) {
    let path = fileURL.path
    // O_NOFOLLOW: never read configuration through a planted symlink.
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 {
      if errno == ENOENT { return (ConfigurationDocument(), nil) }
      let reason = String(cString: strerror(errno))
      return (ConfigurationDocument(), quarantine(reason: "could not open (\(reason))"))
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let data = (try? handle.readToEnd()) ?? Data()
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
          envelope.schemaVersion == Self.schemaVersion else {
      return (ConfigurationDocument(), quarantine(reason: "unreadable or from an unknown version"))
    }
    return (envelope.configuration, nil)
  }

  func save(_ document: ConfigurationDocument) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, configuration: document))
    try prepareDirectory()

    let temporary = "\(directoryPath)/.configuration.\(UUID().uuidString).tmp"
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw posixError("create temporary file") }
    var committed = false
    defer { if !committed { unlink(temporary) } }

    let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    let synced = fsync(descriptor) == 0
    close(descriptor)
    guard written == data.count, synced else { throw posixError("write temporary file") }

    // rename() replaces the directory entry itself, so even a symlink at the
    // destination is replaced rather than followed.
    guard rename(temporary, fileURL.path) == 0 else { throw posixError("replace configuration") }
    committed = true

    let directory = open(directoryPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if directory >= 0 {
      fsync(directory)
      close(directory)
    }
  }

  /// Creates the directory, or repairs its owner and mode. A symlink is refused.
  private func prepareDirectory() throws {
    var info = stat()
    if lstat(directoryPath, &info) != 0 {
      guard errno == ENOENT else { throw posixError("inspect directory") }
      guard mkdir(directoryPath, 0o700) == 0 || errno == EEXIST else { throw posixError("create directory") }
      guard lstat(directoryPath, &info) == 0 else { throw posixError("inspect directory") }
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw MACDancerError.persistence("\(directoryPath) is not a directory.")
    }
    if enforceRootOwnership && (info.st_uid != 0 || info.st_gid != 0) {
      guard chown(directoryPath, 0, 0) == 0 else { throw posixError("set directory owner") }
    }
    if info.st_mode & 0o777 != 0o700 {
      guard chmod(directoryPath, 0o700) == 0 else { throw posixError("set directory permissions") }
    }
  }

  /// Moves an unusable file aside so a fresh one can be written, and keeps it
  /// for inspection instead of silently overwriting it.
  private func quarantine(reason: String) -> String {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let destination = "\(fileURL.path).invalid-\(stamp)"
    let moved = rename(fileURL.path, destination) == 0
    return moved
      ? "Settings file was \(reason); it was moved to \(destination) and defaults are in use."
      : "Settings file was \(reason); defaults are in use."
  }

  private func posixError(_ operation: String) -> MACDancerError {
    .persistence("\(operation): \(String(cString: strerror(errno)))")
  }
}
