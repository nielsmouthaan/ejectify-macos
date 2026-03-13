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
    
    /// Whether the user has already requested approval via the Open Settings action.
    @State private var didRequestApproval = false
    
    /// Whether privileged helper permissions are currently granted.
    @State private var isPermissionsGranted = VolumeOperationRouter.shared.isDaemonEnabled
    
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
        VStack(spacing: 32) {
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
            
            Text(.init("Grant Ejectify elevated permissions in [System Settings](x-apple.systempreferences:com.apple.LoginItems-Settings.extension), or approve it from the system notification, so it can mount and unmount disks more reliably."))
                .frame(width: titleWidth == 0 ? nil : titleWidth)
                .fixedSize(horizontal: false, vertical: true)
            
            Button {
                openSettingsClicked()
            } label: {
                if isPermissionsGranted {
                    Label("Permissions granted", systemImage: "checkmark.circle.fill")
                } else if didRequestApproval {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for approval")
                    }
                } else {
                    Text("Open Settings")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPermissionsGranted || didRequestApproval)
            Button(isPermissionsGranted ? "Close" : "Skip") {
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
            startDaemonStatusMonitoring()
        }
        .onDisappear {
            stopDaemonStatusMonitoring()
        }
    }
    
    /// Opens System Settings to guide users to the elevated-permissions approval UI.
    private func openSettingsClicked() {
        didRequestApproval = true
        SMAppService.openSystemSettingsLoginItems()
    }
    
    /// Handles the secondary action by skipping approval or closing after approval.
    private func closeClicked() {
        Preference.hasCompletedOnboarding = true
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
                let isDaemonEnabled = VolumeOperationRouter.shared.isDaemonEnabled
                await MainActor.run {
                    isPermissionsGranted = isDaemonEnabled
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
