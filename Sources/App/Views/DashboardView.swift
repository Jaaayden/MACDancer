import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    Page(
      title: L("dashboard.title", "Dashboard"),
      subtitle: L("dashboard.subtitle", "See the MAC address your network interfaces are using right now.")
    ) {
      UpdateBanner()
      ServiceCard()
      WarningBanner(messages: model.warnings)
      metrics

      HStack {
        Text(L("dashboard.interfaces.title", "Interfaces")).font(.title2.weight(.semibold))
        Spacer()
        Button(L("dashboard.interfaces.show_all", "Show all")) { model.selection = .interfaces }
      }
      if model.visibleInterfaces.isEmpty {
        ContentUnavailableView(
          L("dashboard.interfaces.empty.title", "No Wi-Fi or Ethernet interfaces"),
          systemImage: "network.slash",
          description: Text(L("dashboard.interfaces.empty.detail", "Connect an Ethernet adapter or turn on Wi-Fi, then refresh."))
        )
      } else {
        ForEach(model.visibleInterfaces) { interface in
          InterfaceCard(interface: interface, compact: true)
        }
      }
    }
  }

  private var metrics: some View {
    let interfaces = model.visibleInterfaces
    return HStack(spacing: 12) {
      Metric(
        title: L("dashboard.metric.interfaces", "Interfaces"),
        value: interfaces.count,
        detail: L("dashboard.metric.interfaces.detail", "Wi-Fi and Ethernet adapters")
      )
      Metric(
        title: L("dashboard.metric.active", "In use"),
        value: interfaces.filter(\.isInUse).count,
        detail: L("dashboard.metric.active.detail", "Connected or carrying traffic")
      )
      Metric(
        title: L("dashboard.metric.hardware", "Using hardware MAC"),
        value: interfaces.filter(\.usesHardwareMAC).count,
        detail: L("dashboard.metric.hardware.detail", "Visible to every network you join")
      )
    }
  }
}

private struct Metric: View {
  let title: String
  let value: Int
  let detail: String

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.subheadline).foregroundStyle(.secondary)
        Text("\(value)").font(.system(size: 30, weight: .semibold, design: .rounded))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(4)
    }
  }
}

/// Install, approve, repair or remove the privileged background service.
struct ServiceCard: View {
  @EnvironmentObject private var model: AppModel
  @State private var confirmsUninstall = false

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(tint)
            .frame(width: 28)
          VStack(alignment: .leading, spacing: 4) {
            Text(L("daemon.card.title", "Background service")).font(.headline)
            Text(message)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          StatusPill(title: title, systemImage: symbol, tint: tint)
        }

        if model.legacyServiceDetected {
          Label(MACDancerError.legacyServiceConflict.localizedMessage, systemImage: "exclamationmark.octagon.fill")
            .font(.callout)
            .foregroundStyle(.red)
        }

        HStack(spacing: 10) {
          primaryButton
          if model.registration == .enabled || model.registration == .requiresApproval {
            Button(L("daemon.action.uninstall", "Uninstall…"), role: .destructive) { confirmsUninstall = true }
          }
          if model.isChangingService { ProgressView().controlSize(.small) }
          Spacer()
        }
        .disabled(model.isChangingService)
      }
      .padding(4)
    }
    .alert(L("daemon.uninstall.title", "Uninstall the background service?"), isPresented: $confirmsUninstall) {
      Button(L("daemon.action.uninstall_confirm", "Uninstall"), role: .destructive) { model.uninstallService() }
      Button(L("common.cancel", "Cancel"), role: .cancel) {}
    } message: {
      Text(L(
        "daemon.uninstall.message",
        "Automatic rotation stops. Current MAC addresses, policies and history are kept, and no address is restored."
      ))
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    switch model.status {
    case .checking, .connecting:
      EmptyView()
    case .notInstalled:
      Button(L("daemon.action.install", "Install background service")) { model.installService() }
        .buttonStyle(.borderedProminent)
    case .awaitingApproval:
      Button(L("daemon.action.open_settings", "Open System Settings")) { model.openApprovalSettings() }
        .buttonStyle(.borderedProminent)
    case .unreachable, .incompatible:
      Button(L("daemon.action.repair", "Repair connection")) { model.repairService() }
        .buttonStyle(.borderedProminent)
    case .ready:
      Button(L("daemon.action.repair", "Repair connection")) { model.repairService() }
        .help(L("daemon.action.repair_help", "Reload the background service, e.g. after building a new version."))
    }
  }

  private var title: String {
    switch model.status {
    case .checking: L("daemon.status.checking", "Checking")
    case .notInstalled: L("daemon.status.not_installed", "Not installed")
    case .awaitingApproval: L("daemon.status.awaiting_approval", "Approval required")
    case .connecting: L("daemon.status.connecting", "Connecting")
    case .ready: L("daemon.status.ready", "Ready")
    case .unreachable: L("daemon.status.unavailable", "Unavailable")
    case .incompatible: L("daemon.status.incompatible", "Version mismatch")
    }
  }

  private var message: String {
    switch model.status {
    case .checking:
      L("daemon.message.checking", "Checking the background service…")
    case .notInstalled:
      L("daemon.message.not_installed", "MACDancer needs its background service to change MAC addresses. Reading addresses works without it.")
    case .awaitingApproval:
      L("daemon.message.awaiting_approval", "Allow MACDancer in System Settings › General › Login Items & Extensions, then come back.")
    case .connecting:
      L("daemon.message.connecting", "Connecting to the background service…")
    case .ready:
      L("daemon.message.ready", "Changes are applied by the background service and verified by reading the address back.")
    case let .unreachable(reason):
      L("daemon.message.unavailable", "The service is installed but not answering (%@). Repair connection reloads it.", reason)
    case let .incompatible(version):
      L(
        "daemon.message.incompatible",
        "The running service is from another build (protocol %1$d, this app uses %2$d). Repair connection loads the one inside this app.",
        version, MACDancerConstants.protocolVersion
      )
    }
  }

  private var symbol: String {
    switch model.status {
    case .ready: "checkmark.shield.fill"
    case .notInstalled: "arrow.down.app"
    case .awaitingApproval: "lock.shield"
    case .checking, .connecting: "hourglass"
    case .unreachable, .incompatible: "exclamationmark.triangle.fill"
    }
  }

  private var tint: Color {
    switch model.status {
    case .ready: .green
    case .notInstalled, .awaitingApproval, .checking, .connecting: .orange
    case .unreachable, .incompatible: .red
    }
  }
}
