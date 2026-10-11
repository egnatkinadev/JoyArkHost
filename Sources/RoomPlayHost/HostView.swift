import SwiftUI

struct HostView: View {
    @ObservedObject var model: HostModel
    @State private var confirmingRotation = false

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.hostName).font(.title2.bold())
                        Label(model.status, systemImage: model.streaming ? "dot.radiowaves.left.and.right" : model.listenerReady ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(model.listenerReady ? Color.green : Color.secondary)
                        Text("Run your game on this Mac, then connect from JoyArk on an iPhone in the same local network.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    if model.listenerReady || model.listenerStarting {
                        Button("Stop Host", role: .destructive) { model.stopHost() }
                    } else {
                        Button("Start Host") { model.startHost() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.pairingToken.isEmpty)
                    }
                    if model.listenerStarting { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("Local network · encrypted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Display and access") {
                Picker("Display to share", selection: $model.selectedDisplayID) {
                    ForEach(model.displays) { display in Text(display.label).tag(display.id) }
                }
                .disabled(model.displaySelectionLocked || model.displays.isEmpty)
                if model.displays.isEmpty { Text("No display is available. Connect a display and refresh.").foregroundStyle(.secondary) }
                Toggle("Allow streaming", isOn: $model.allowStreaming)
                Toggle("Allow keyboard and mouse control", isOn: $model.allowControl)
                Text("A phone with your pairing key can view the selected display and, when enabled, control your Mac. Close private windows before streaming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permissions") {
                permissionRow(title: "Screen Recording", granted: model.screenPermission,
                              description: "Required for video and system audio.", action: model.requestScreenPermission)
                permissionRow(title: "Accessibility", granted: model.controlPermission,
                              description: "Required for remote keyboard and mouse input.", action: model.requestControlPermission)
                Text("After granting Screen Recording, quit and reopen JoyArk Host if macOS asks you to restart it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Pair your iPhone") {
                HostAutomaticPairingView(pairing: model.automaticPairing)
                DisclosureGroup("Advanced pairing") {
                    HStack(alignment: .top, spacing: 20) {
                        if let image = model.qrImage {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 160, height: 160)
                                .padding(8)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("JoyArk pairing QR code")
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("If automatic pairing is unavailable, scan this code with the iPhone Camera or use the address and key below.")
                                .fixedSize(horizontal: false, vertical: true)
                            Text(model.hostAddress).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            ForEach(model.localAddresses, id: \.self) { address in
                                Text(address).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                            Button("Copy Pairing Link") { model.copyPairingLink() }.disabled(model.pairingURL.isEmpty)
                            Text("Keep this code private. Anyone with it can connect while the host is running.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(model.pairingToken)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy Key") { model.copyToken() }.disabled(model.pairingToken.isEmpty)
                }
                Button("Replace Pairing Key…", role: .destructive) { confirmingRotation = true }
            }

            if let clientName = model.clientName {
                Section("Connected iPhone") {
                    LabeledContent("Device", value: clientName)
                    LabeledContent("Control", value: model.controlsAvailable ? "Keyboard and mouse available" : "View only")
                    HStack {
                        if model.streaming || model.sessionStarting {
                            Button("Stop Session") { model.stopSession() }
                        }
                        if model.sessionStarting || model.sessionStopping { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Disconnect iPhone", role: .destructive) { model.disconnectPhone() }
                    }
                }
            }

            Section("Game controls") {
                Text("The iPhone sends keyboard and mouse input, including mappings from a paired controller. Games must support keyboard/mouse controls. JoyArk Host does not create a virtual macOS gamepad.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 680, minHeight: 600)
        .toolbar {
            Button {
                model.refreshDisplays()
                model.refreshPermissions()
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
        .confirmationDialog("Replace the pairing key?", isPresented: $confirmingRotation) {
            Button("Replace Key", role: .destructive) { model.rotatePairingKey() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops the host and disconnects the iPhone. Previously paired phones will need the new key.")
        }
        .alert("JoyArk Host", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private func permissionRow(title: String, granted: Bool, description: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(granted ? Color.green : Color.primary)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "Open Settings" : "Allow…", action: action)
        }
    }
}
