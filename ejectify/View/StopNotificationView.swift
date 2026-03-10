//
//  StopNotificationView.swift
//  Ejectify
//
//  Created by Codex on 10/03/2026.
//

import SwiftUI

/// Banner that mimics the Finder "Disk Not Ejected Properly" warning style.
struct StopNotificationView: View {

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(.white)
                .stroke(.white, lineWidth: 2)
                .shadow(color: .black.opacity(0.1), radius: 24, x: 0, y: 10)
            HStack(alignment: .center, spacing: 16) {
                Image(.finderIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Disk Not Ejected Properly")
                        .fontWeight(.semibold)
                    Text("Eject \"USB Drive\" before disconnecting or turning it off.")
                }
            }
            .padding(.horizontal, 16)
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(.red)
                .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.5)
                }
            .rotationEffect(.degrees(10))
            .offset(x: 164, y: -32)
        }
        .frame(width: 350, height: 75)
        
    }
}

#Preview {
    StopNotificationView()
        .padding(100)
}
