import SwiftUI

/// Header chip: appears when an update is waiting (or after a manual check)
/// and shows download progress as a filling ring.
struct UpdateChip: View {
  @EnvironmentObject private var updates: UpdateController
  @State private var showsDetails = false

  var body: some View {
    Group {
      switch updates.state {
      case let .available(update):
        Button { showsDetails = true } label: {
          chip(L("update.chip.available", "Update %@", update.version), systemImage: "arrow.down.circle.fill", prominent: true)
        }
      case let .downloading(progress):
        chip(L("update.chip.downloading", "Downloading %d%%", Int(progress * 100)), progress: progress, prominent: true)
      case .installing:
        chip(L("update.chip.installing", "Installing…"), progress: nil, prominent: true)
      case .checking where updates.lastCheckWasManual:
        chip(L("update.chip.checking", "Checking…"), progress: nil, prominent: false)
      case .upToDate where updates.lastCheckWasManual:
        chip(L("update.chip.up_to_date", "Up to date"), systemImage: "checkmark.circle.fill", prominent: false)
          .task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation { updates.dismissResult() }
          }
      case let .failed(message) where updates.lastCheckWasManual:
        Button { showsDetails = true } label: {
          chip(L("update.chip.failed", "Update failed"), systemImage: "exclamationmark.triangle.fill", prominent: false)
        }
        .help(message)
      default:
        EmptyView()
      }
    }
    .buttonStyle(.plain)
    .transition(.scale(scale: 0.8).combined(with: .opacity))
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: updates.state)
    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
      UpdateDetails { showsDetails = false }
        .environmentObject(updates)
        .frame(width: 340)
    }
  }

  private func chip(_ title: String, systemImage: String? = nil, progress: Double? = 0, prominent: Bool) -> some View {
    HStack(spacing: 6) {
      if let systemImage {
        Image(systemName: systemImage)
      } else if let progress, progress > 0 {
        ProgressRing(progress: progress).frame(width: 12, height: 12)
      } else {
        ProgressView().controlSize(.mini).tint(prominent ? .white : nil)
      }
      Text(title).monospacedDigit()
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(prominent ? .white : .secondary)
    .padding(.horizontal, 11)
    .frame(height: 30)
    .background {
      Capsule().fill(prominent ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.05)))
    }
    .shadow(color: prominent ? Brand.indigo.opacity(0.3) : .clear, radius: 6, y: 2)
    .contentShape(Capsule())
  }
}

private struct ProgressRing: View {
  let progress: Double

  var body: some View {
    ZStack {
      Circle().stroke(.white.opacity(0.35), lineWidth: 2)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.easeOut(duration: 0.2), value: progress)
    }
  }
}

private struct UpdateDetails: View {
  @EnvironmentObject private var updates: UpdateController
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch updates.state {
      case let .available(update):
        HStack(spacing: 10) {
          IconTile(systemImage: "arrow.down", size: 34)
          VStack(alignment: .leading, spacing: 1) {
            Text(L("update.banner.title", "MACDancer %@ is available", update.version)).font(.headline)
            Text(L("update.current", "Installed version: %@", updates.currentVersion)).font(.caption).foregroundStyle(.secondary)
          }
        }
        if !update.notes.isEmpty {
          ScrollView {
            Text(update.notes)
              .font(.callout)
              .frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          .frame(maxHeight: 160)
        }
        if let reason = updates.installBlockedReason {
          Text(reason).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Link(L("update.release_notes", "Release notes"), destination: update.pageURL).font(.callout)
          Spacer()
          Button(L("update.install", "Install and Relaunch")) {
            close()
            updates.install(update)
          }
          .buttonStyle(GradientButtonStyle())
          .disabled(updates.installBlockedReason != nil)
        }
        Text(L("update.banner.detail", "You have %@. The update installs in place and MACDancer restarts.", updates.currentVersion))
          .font(.caption)
          .foregroundStyle(.tertiary)
      case let .failed(message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button(L("update.check", "Check Now")) {
            close()
            updates.check(userInitiated: true)
          }
          .buttonStyle(SoftButtonStyle())
        }
      default:
        EmptyView()
      }
    }
    .padding(16)
  }
}

/// The Updates section in Settings.
struct UpdateSettingsSection: View {
  @EnvironmentObject private var updates: UpdateController

  var body: some View {
    Section(L("update.title", "Updates")) {
      LabeledContent(L("update.installed", "Installed version"), value: updates.currentVersion)
      Toggle(L("update.auto", "Check for updates automatically once a day"), isOn: $updates.automaticallyChecks)
      HStack {
        status
        Spacer()
        Button(L("update.check", "Check Now")) { updates.check(userInitiated: true) }
          .disabled(updates.isBusy)
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    switch updates.state {
    case .idle:
      Text(L("update.status.idle", "Updates come from the project’s GitHub releases and are verified before installing."))
        .font(.caption)
        .foregroundStyle(.secondary)
    case .checking:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(L("update.checking", "Checking GitHub for a newer release…")).foregroundStyle(.secondary)
      }
    case .upToDate:
      Label(L("update.up_to_date", "MACDancer is up to date."), systemImage: "checkmark.circle.fill")
        .foregroundStyle(Brand.mintInk)
    case let .available(update):
      HStack(spacing: 8) {
        Text(L("update.available", "Version %@ is available.", update.version))
        Button(L("update.install", "Install and Relaunch")) { updates.install(update) }
          .buttonStyle(GradientButtonStyle())
          .disabled(updates.installBlockedReason != nil)
      }
    case let .downloading(progress):
      ProgressView(value: progress) { Text(L("update.downloading", "Downloading the update…")).font(.caption) }
        .frame(maxWidth: 220)
    case .installing:
      HStack(spacing: 6) {
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
