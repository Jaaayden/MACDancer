import Foundation

/// A dotted numeric version such as `2.0.1`; a leading `v` is ignored.
struct AppVersion: Comparable, CustomStringConvertible, Sendable {
  let components: [Int]

  init?(_ text: String) {
    var value = text.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
    components = parts.map { $0! }
  }

  var description: String { components.map(String.init).joined(separator: ".") }

  static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
    let count = max(lhs.components.count, rhs.components.count)
    for index in 0..<count {
      let left = index < lhs.components.count ? lhs.components[index] : 0
      let right = index < rhs.components.count ? rhs.components[index] : 0
      if left != right { return left < right }
    }
    return false
  }

  static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The subset of GitHub's release JSON the updater needs.
struct GitHubRelease: Decodable, Sendable {
  struct Asset: Decodable, Sendable {
    let name: String
    let browserDownloadURL: URL
    let size: Int

    enum CodingKeys: String, CodingKey {
      case name, size
      case browserDownloadURL = "browser_download_url"
    }
  }

  let tagName: String
  let name: String?
  let body: String?
  let htmlURL: URL
  let draft: Bool
  let prerelease: Bool
  let assets: [Asset]

  enum CodingKeys: String, CodingKey {
    case name, body, draft, prerelease, assets
    case tagName = "tag_name"
    case htmlURL = "html_url"
  }
}

struct AvailableUpdate: Equatable, Sendable {
  let version: String
  let notes: String
  let pageURL: URL
  let downloadURL: URL
  let size: Int
}

enum UpdateState: Equatable, Sendable {
  case idle
  case checking
  case upToDate
  case available(AvailableUpdate)
  /// Download progress from 0 to 1.
  case downloading(Double)
  case installing
  case failed(String)
}

enum UpdatePlanner {
  static let repository = "Jaaayden/MACDancer"
  static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

  /// The update to offer, or nil when `release` is not newer or has no app archive.
  static func update(from release: GitHubRelease, current: String) -> AvailableUpdate? {
    guard !release.draft, !release.prerelease,
          let latest = AppVersion(release.tagName),
          let installed = AppVersion(current),
          installed < latest else { return nil }
    // Release archives are named MACDancer-<version>.zip by bin/make-release.
    let expected = "MACDancer-\(latest).zip"
    guard let asset = release.assets.first(where: { $0.name == expected })
      ?? release.assets.first(where: { $0.name.hasPrefix("MACDancer") && $0.name.hasSuffix(".zip") }),
      asset.browserDownloadURL.scheme == "https" else { return nil }
    return AvailableUpdate(
      version: latest.description,
      notes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      pageURL: release.htmlURL,
      downloadURL: asset.browserDownloadURL,
      size: asset.size
    )
  }

  /// Only one automatic check a day.
  static func isCheckDue(lastCheck: Date?, now: Date = Date()) -> Bool {
    guard let lastCheck else { return true }
    return now.timeIntervalSince(lastCheck) >= 24 * 60 * 60 || now < lastCheck
  }

  /// The signature an update must carry: same bundle identifier and the same
  /// developer team as the app that is running now.
  static func codeRequirement(teamIdentifier: String) -> String {
    "anchor apple generic and identifier \"\(MACDancerConstants.appIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
  }
}
