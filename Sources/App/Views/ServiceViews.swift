import SwiftUI

/// How the background helper looks to the user. "Starting" covers the first
/// seconds of a restart (after an update, say) so nobody is asked to repair
/// something that is about to fix itself.
enum HelperLook: Equatable {
  case checking, starting, ready, needsSetup, needsApproval, notResponding, conflict

  @MainActor init(_ model: AppModel) {
    if model.legacyServiceDetected {
      self = .conflict
      return
    }
    switch model.status {
    case .checking: self = .checking
    case .connecting: self = .starting
    case .ready: self = .ready
    case .notInstalled: self = .needsSetup
    case .awaitingApproval: self = .needsApproval
    case .unreachable, .incompatible: self = model.serviceProblemPersists ? .notResponding : .starting
    }
  }

  var title: String {
    switch self {
    case .checking: L("helper.chip.checking", "Checking")
    case .starting: L("helper.chip.starting", "Starting…")
    case .ready: L("helper.chip.ready", "Ready")
    case .needsSetup: L("helper.chip.setup", "Setup needed")
    case .needsApproval: L("helper.chip.approval", "Approval needed")
    case .notResponding: L("helper.chip.not_responding", "Not responding")
    case .conflict: L("helper.chip.conflict", "Conflict")
    }
  }

  var tint: Color {
    switch self {
    case .ready: Brand.mintInk
    case .checking, .starting: .secondary
    case .needsSetup, .needsApproval: .orange
    case .notResponding, .conflict: .red
    }
  }
}

/// The header chip. Click for details and Repair.
struct HelperChip: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsDetails = false

  var body: some View {
    let look = HelperLook(model)
    Button { showsDetails.toggle() } label: {
      HStack(spacing: 6) {
        if look == .starting || look == .checking || model.isChangingService {
          ProgressView().controlSize(.mini)
        } else {
          Circle().fill(look.tint).frame(width: 7, height: 7)
            .shadow(color: look.tint.opacity(0.6), radius: look == .ready ? 3 : 0)
        }
        Text(look.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      }
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(Color.primary.opacity(0.05), in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(L("helper.chip.help", "Background helper"))
    .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
      HelperDetails().environmentObject(model).frame(width: 320)
    }
    .animation(.easeInOut(duration: 0.2), value: look)
  }
}

private struct HelperDetails: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        IconTile(systemImage: "lock.shield.fill", active: model.isReady, size: 34)
        VStack(alignment: .leading, spacing: 1) {
          Text(L("daemon.card.title", "Background service")).font(.headline)
          Text(HelperLook(model).title).font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(helperMessage(model)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let version = model.daemonSnapshot?.daemonVersion {
        LabeledContent(L("settings.diagnostics.daemon_version", "Background service version"), value: version)
          .font(.caption)
      }
      HStack {
        HelperPrimaryButton()
        Spacer()
        SettingsLink { Text(L("helper.more", "More…")) }
          .buttonStyle(.link)
      }
    }
    .padding(16)
  }
}

/// The one button that moves the helper forward from its current state.
struct HelperPrimaryButton: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Group {
      switch model.status {
      case .notInstalled:
        Button(L("helper.action.install", "Set Up Helper")) { model.installService() }
          .buttonStyle(GradientButtonStyle())
      case .awaitingApproval:
        Button(L("daemon.action.open_settings", "Open System Settings")) { model.openApprovalSettings() }
          .buttonStyle(GradientButtonStyle())
      case .unreachable, .incompatible, .ready:
        Button(L("daemon.action.repair", "Repair connection")) { model.repairService() }
          .buttonStyle(model.status == .ready ? AnyButtonStyle(SoftButtonStyle()) : AnyButtonStyle(GradientButtonStyle()))
          .help(L("daemon.action.repair_help", "Reload the background service, e.g. after building a new version."))
      case .checking, .connecting:
        EmptyView()
      }
    }
    .disabled(model.isChangingService || model.isUninstalling)
  }
}

struct AnyButtonStyle: ButtonStyle {
  private let make: (Configuration) -> AnyView
  init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
  func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

@MainActor
func helperMessage(_ model: AppModel) -> String {
  if model.legacyServiceDetected { return MACDancerError.legacyServiceConflict.localizedMessage }
  switch model.status {
  case .checking:
    return L("daemon.message.checking", "Checking the background service…")
  case .notInstalled:
    return L("helper.message.setup", "MACDancer reads addresses on its own. To change them it uses a small background helper with administrator rights, which you approve once.")
  case .awaitingApproval:
    return L("daemon.message.awaiting_approval", "Allow MACDancer in System Settings › General › Login Items & Extensions, then come back.")
  case .connecting:
    return L("daemon.message.connecting", "Connecting to the background service…")
  case .ready:
    return L("daemon.message.ready", "Changes are applied by the background service and verified by reading the address back.")
  case let .unreachable(reason):
    return model.serviceProblemPersists
      ? L("daemon.message.unavailable", "The service is installed but not answering (%@). Repair connection reloads it.", reason)
      : L("helper.message.restarting", "The helper is restarting, for example after an update. This takes a few seconds.")
  case let .incompatible(version):
    return model.serviceProblemPersists
      ? L(
        "daemon.message.incompatible",
        "The running service is from another build (protocol %1$d, this app uses %2$d). Repair connection loads the one inside this app.",
        version, MACDancerConstants.protocolVersion
      )
      : L("helper.message.restarting", "The helper is restarting, for example after an update. This takes a few seconds.")
  }
}

/// Shown above the adapters only while the helper needs the user.
struct HelperSetupCard: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    let look = HelperLook(model)
    if [.needsSetup, .needsApproval, .notResponding, .conflict].contains(look) {
      HStack(alignment: .center, spacing: 16) {
        IconTile(
          systemImage: look == .conflict ? "exclamationmark.octagon.fill" : "lock.shield.fill",
          active: look != .conflict,
          size: 48
        )
        VStack(alignment: .leading, spacing: 4) {
          Text(title(look)).font(.headline)
          Text(helperMessage(model))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        if look != .conflict { HelperPrimaryButton() }
      }
      .card(emphasized: look != .conflict)
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  private func title(_ look: HelperLook) -> String {
    switch look {
    case .needsSetup: L("helper.setup.title", "One-time setup")
    case .needsApproval: L("helper.approval.title", "Approve the helper in System Settings")
    case .notResponding: L("helper.broken.title", "The helper is not responding")
    case .conflict: L("helper.conflict.title", "LinkLiar is installed")
    default: ""
    }
  }
}
