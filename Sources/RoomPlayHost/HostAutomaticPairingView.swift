import SwiftUI

struct HostAutomaticPairingView: View {
    @ObservedObject var pairing: HostAutomaticPairing

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open JoyArk on your iPhone and select this Mac in Nearby Macs. Confirm the matching code here to allow the connection. No address or pairing key entry is needed.")
                .fixedSize(horizontal: false, vertical: true)
            Label(pairing.status, systemImage: pairing.isReady ? "iphone.and.arrow.forward" : "network")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: Binding(get: { pairing.request }, set: { value in
            if value == nil, let request = pairing.request { pairing.reject(request.id) }
        })) { request in
            VStack(alignment: .leading, spacing: 20) {
                Label("Allow this iPhone?", systemImage: "iphone")
                    .font(.title2.bold())
                Text(request.clientName)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Compare this code with the code shown in JoyArk on your iPhone.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(request.verificationCode)
                    .font(.system(size: 36, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Verification code \(request.verificationCode.map(String.init).joined(separator: " "))")
                Text("Allow only when both codes match. Then return to your game on the Mac so keyboard and mouse controls reach it. Streaming begins separately when you start it on your iPhone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reject", role: .cancel) { pairing.reject(request.id) }
                    Spacer()
                    Button("Allow iPhone") { pairing.approve(request.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 460)
            .interactiveDismissDisabled()
        }
    }
}
