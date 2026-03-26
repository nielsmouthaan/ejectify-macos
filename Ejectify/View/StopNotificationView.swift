//
//  StopNotificationView.swift
//  Ejectify
//
//  Created by Codex on 10/03/2026.
//

import SwiftUI

/// Banner that mimics the Finder "Disk Not Ejected Properly" warning style.
struct StopNotificationView: View {

    @State private var isAnimatingHandSymbol = false
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(nsColor: .controlBackgroundColor))
                .stroke(.primary.opacity(0.2), lineWidth: colorScheme == .dark ? 1 : 0)
                .shadow(color: .primary.opacity(colorScheme == .dark ? 0.05 : 0.1), radius: 24, x: 0, y: 10)
            HStack(alignment: .center, spacing: 16) {
                Image(.finderIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .shadow(color: .primary.opacity(0.3), radius: 1, x: 0, y: 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Disk Not Ejected Properly")
                        .fontWeight(.semibold)
                    Text(
                        String(
                            format: String(localized: "Eject \"%@\" before disconnecting or turning it off."),
                            String(localized: "USB Drive")
                        )
                    )
                }
                .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16)
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.red)
                .shadow(color: .primary.opacity(0.2), radius: 1, x: 0, y: 1)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.5)
                }
                .rotationEffect(.degrees(isAnimatingHandSymbol ? 10 : 15))
                .scaleEffect(isAnimatingHandSymbol ? 0.95 : 1.04)
                .offset(x: 164, y: -32)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        isAnimatingHandSymbol = true
                    }
                }
        }
        .frame(width: 350, height: 75)
    }
}

#Preview("English") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "en"))
}

#Preview("Spanish") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "es"))
}

#Preview("French") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "fr"))
}

#Preview("German") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "de"))
}

#Preview("Portuguese (Brazil)") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "pt-BR"))
}

#Preview("Japanese") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "ja"))
}

#Preview("Chinese (Simplified)") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "zh-Hans"))
}

#Preview("Arabic") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "ar"))
}

#Preview("Hindi") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "hi"))
}

#Preview("Russian") {
    OnboardingView()
        .environment(\.locale, Locale(identifier: "ru"))
}
