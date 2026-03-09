//
//  OnboardingView.swift
//  Ejectify
//
//  Created by Codex on 09/03/2026.
//

import SwiftUI

/// SwiftUI content rendered inside the onboarding window controller.
struct OnboardingView: View {

    /// Observable onboarding state and actions owned by the window controller.
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Approve elevated access")
                .font(.title2.weight(.semibold))

            Text("Ejectify can use a privileged helper for more reliable mount and unmount operations. Approve the helper in System Settings to enable this.")
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isPollingForApproval {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for approval in System Settings...")
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button("Open Settings") {
                    viewModel.openSettingsClicked()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isPollingForApproval)

                Button("Skip") {
                    viewModel.skipClicked()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            "Ejectify will fall back to local mount and unmount attempts.",
            isPresented: $viewModel.isSkipConfirmationPresented
        ) {
            Button("Yes", role: .destructive) {
                viewModel.confirmSkip()
            }
            Button("No", role: .cancel) {}
        } message: {
            Text("This may reduce reliability. Are you sure?")
        }
    }
}
