import SwiftUI

/// Placeholder shown in the main chat area when the hermes backend CLI isn't
/// installed, so the user gets a clear reason instead of a chat that silently
/// fails to send.
struct HermesNotInstalledView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Hermes Not Installed")
                .font(.title3.weight(.semibold))

            Text("The Hermes agent backend wasn't found at ~/.hermes/hermes-agent. Install Hermes to start chatting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
