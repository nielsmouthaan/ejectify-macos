//
//  OnboardingView.swift
//  Ejectify
//
//  Created by Codex on 09/03/2026.
//

import AppKit
import SwiftUI
import ServiceManagement

/// SwiftUI content rendered inside the onboarding window controller.
struct OnboardingView: View {

    /// Current Service Management status for the privileged helper daemon.
    @State private var daemonStatus = PrivilegedHelperLifecycleManager.shared.daemonStatus

    /// Polling task used to periodically check helper approval status.
    @State private var approvalPollingTask: Task<Void, Never>?

    /// Measured rendered width of the localized title text.
    @State private var titleWidth: CGFloat = 0

    /// Action that closes the onboarding window.
    private let closeAction: () -> Void

    /// Creates onboarding view with an injected close action.
    init(closeAction: @escaping () -> Void = {}) {
        self.closeAction = closeAction
    }

    var body: some View {
        VStack(spacing: 24) {
            StopNotificationView()
                .padding(.vertical, 32)
            titleText
                .font(.title2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: TitleWidthPreferenceKey.self, value: geometry.size.width)
                    }
                }
            
            Text("Ejectify automatically attempts to unmount volumes when your Mac goes to sleep and mounts them again after it wakes.")
                .frame(width: titleWidth == 0 ? nil : titleWidth)
                .fixedSize(horizontal: false, vertical: true)

            Text("Grant Ejectify elevated permissions in System Settings, or approve it from the system notification, so it can mount and unmount disks more reliably.")
                .frame(width: titleWidth == 0 ? nil : titleWidth)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openSettingsClicked()
            } label: {
                Text("Open System Settings")
            }
            .buttonStyle(.borderedProminent)

            permissionsStatusView

            Button(permissionStatus.isGranted ? "Close" : "Skip") {
                closeClicked()
            }
            .buttonStyle(.link)
        }
        .multilineTextAlignment(.center)
        .frame(width: titleWidth == 0 ? nil : titleWidth)
        .padding(24)
        .background {
            OnboardingGlassBackground()
        }
        .onPreferenceChange(TitleWidthPreferenceKey.self) { width in
            titleWidth = width
        }
        .onAppear {
            Preference.hasSeenOnboarding = true
            startDaemonStatusMonitoring()
        }
        .onDisappear {
            stopDaemonStatusMonitoring()
        }
    }

    /// Opens System Settings to guide users to the elevated-permissions approval UI.
    private func openSettingsClicked() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Handles the secondary action by skipping approval or closing after approval.
    private func closeClicked() {
        closeAction()
    }

    /// Localized title with the localized system warning phrase highlighted.
    private var titleText: Text {
        let warningPhrase = String(localized: "Disk Not Ejected Properly")
        let title = String(format: String(localized: "No more %@ notifications"), warningPhrase)

        guard let range = title.range(of: warningPhrase) else {
            return Text(title)
        }

        let prefix = String(title[..<range.lowerBound])
        let suffix = String(title[range.upperBound...])
        return Text(prefix) + Text(warningPhrase).fontWeight(.semibold) + Text(suffix)
    }

    /// Current onboarding presentation state for privileged helper approval.
    private var permissionStatus: PermissionStatus {
        PermissionStatus(daemonStatus: daemonStatus)
    }

    /// Status row shown beneath the primary action while onboarding is displayed.
    private var permissionsStatusView: some View {
        HStack(spacing: 8) {
            statusIndicator
                .frame(width: 14, height: 14)

            statusLabel
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 20)
        .accessibilityElement(children: .combine)
    }

    /// Indicator shown for the current permission status with a stable layout footprint.
    @ViewBuilder
    private var statusIndicator: some View {
        switch permissionStatus {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .waitingForApproval:
            ProgressView()
                .controlSize(.small)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    /// Localized label paired with the current permission-status indicator.
    private var statusLabel: Text {
        switch permissionStatus {
        case .granted:
            Text("Permissions granted")
        case .waitingForApproval:
            Text("Waiting for approval")
        case .denied:
            Text("Permissions denied")
        }
    }

    /// Starts periodic daemon-status monitoring if not already active.
    private func startDaemonStatusMonitoring() {
        guard approvalPollingTask == nil else {
            return
        }

        approvalPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else {
                    return
                }
                let daemonStatus = PrivilegedHelperLifecycleManager.shared.daemonStatus
                await MainActor.run {
                    self.daemonStatus = daemonStatus
                }
            }
        }
    }

    /// Stops daemon-status monitoring and clears associated in-memory state.
    private func stopDaemonStatusMonitoring() {
        approvalPollingTask?.cancel()
        approvalPollingTask = nil
    }

    /// Preference key used to pass measured title width up the view hierarchy.
    private struct TitleWidthPreferenceKey: PreferenceKey {

        static let defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// Maps the daemon registration status to the onboarding status presentation.
    private enum PermissionStatus {
        case granted
        case waitingForApproval
        case denied

        /// Whether the helper is fully approved and available for privileged routing.
        var isGranted: Bool {
            self == .granted
        }

        /// Creates the onboarding status from the current Service Management status.
        init(daemonStatus: SMAppService.Status) {
            switch daemonStatus {
            case .enabled:
                self = .granted
            case .requiresApproval:
                self = .waitingForApproval
            case .notRegistered, .notFound:
                self = .denied
            @unknown default:
                self = .denied
            }
        }
    }

    /// Applies a Liquid Glass-style onboarding background with a material fallback.
    private struct OnboardingGlassBackground: View {
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            shape
                .fill(.ultraThinMaterial)
                .overlay(
                    shape.fill(.background.opacity(0.8))
                )
        }
    }
}

#Preview {
    OnboardingView()
}
