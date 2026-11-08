import SwiftUI

/// Shown on the Dashboard only while a newer release is waiting.
struct UpdateBanner: View {
  @EnvironmentObject private var updates: UpdateController

  var body: some View {
    if case let .available(update) = updates.state {
      HStack(spacing: 12) {
        Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 2) {
          Text(L("update.banner.title", "MACDancer %@ is available", update.version)).font(.headline)
          Text(L("update.banner.detail", "You have %@. The update installs in place and MACDancer restarts.", updates.currentVersion))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Link(L("update.release_notes", "Release notes"), destination: update.pageURL)
        Button(L("update.install", "Install and Relaunch")) { updates.install(update) }
          .buttonStyle(.borderedProminent)
          .disabled(updates.installBlockedReason != nil)
      }
      .padding(12)
      .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

/// The Updates box in Settings.
struct UpdateSettings: View {
  @EnvironmentObject private var updates: UpdateController

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SettingRow(
        symbol: "arrow.triangle.2.circlepath.circle",
        title: L("update.title", "Updates"),
        detail: L("update.current", "Installed version: %@", updates.currentVersion)
      ) {
        Button(L("update.check", "Check Now")) { updates.check(userInitiated: true) }
          .disabled(updates.isBusy)
      }
      Toggle(L("update.auto", "Check for updates automatically once a day"), isOn: $updates.automaticallyChecks)
        .toggleStyle(.checkbox)
      status
    }
  }

  @ViewBuilder
  private var status: some View {
    switch updates.state {
    case .idle:
      EmptyView()
    case .checking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(L("update.checking", "Checking GitHub for a newer release…")).foregroundStyle(.secondary)
      }
    case .upToDate:
      Label(L("update.up_to_date", "MACDancer is up to date."), systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case let .available(update):
      VStack(alignment: .leading, spacing: 8) {
        Text(L("update.available", "Version %@ is available.", update.version)).font(.headline)
        if !update.notes.isEmpty {
          ScrollView {
            Text(update.notes)
              .font(.callout)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          .frame(maxHeight: 140)
        }
        HStack {
          Button(L("update.install", "Install and Relaunch")) { updates.install(update) }
            .buttonStyle(.borderedProminent)
            .disabled(updates.installBlockedReason != nil)
          Link(L("update.release_notes", "Release notes"), destination: update.pageURL)
        }
        if let reason = updates.installBlockedReason {
          Text(reason).font(.caption).foregroundStyle(.secondary)
        }
      }
    case let .downloading(progress):
      VStack(alignment: .leading, spacing: 4) {
        Text(L("update.downloading", "Downloading the update…")).foregroundStyle(.secondary)
        ProgressView(value: progress)
      }
    case .installing:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(L("update.installing", "Verifying the signature and installing…")).foregroundStyle(.secondary)
      }
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
