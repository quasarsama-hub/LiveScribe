import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Prefer on-device recognition", isOn: $model.preferOnDevice)
                } footer: {
                    Text("On-device works offline, has no time limit and keeps audio on your iPhone. Turn it off only if a language isn't available on-device; Apple's servers then need internet.")
                }

                Section("Status") {
                    StatusRow(title: "Speech recognition",
                              ok: model.speechAuth == .authorized,
                              detail: speechDetail)
                    StatusRow(title: "On-device 한국어",
                              ok: model.onDeviceSupported(.korean),
                              detail: model.onDeviceSupported(.korean) ? "Available" : "Uses Apple servers")
                    StatusRow(title: "On-device English",
                              ok: model.onDeviceSupported(.english),
                              detail: model.onDeviceSupported(.english) ? "Available" : "Uses Apple servers")
                    StatusRow(title: "Shared storage",
                              ok: model.sharedStorageOK,
                              detail: model.sharedStorageOK ? "Ready" : "Unavailable — system audio can't reach the app")
                    StatusRow(title: "Broadcast extension",
                              ok: model.broadcastExtensionID != nil,
                              detail: model.broadcastExtensionID != nil ? "Installed" : "Missing")
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section("System audio") {
                    Text("Tap System audio, then Start Broadcast. iOS captures the sound of every app (YouTube, podcasts, calls in apps, games) and LiveScribe transcribes it in the background. Nothing is recorded or saved except the text.")
                    Text("You can also start it from Control Center: long-press Screen Recording and pick LiveScribe. Stop with the red status-bar pill or the Stop card.")
                    Text("Some apps block capture (Netflix, Apple TV, some music apps) and come through silent.")
                }
                .font(.footnote)
                .foregroundColor(.secondary)

                Section("Tips") {
                    Text("Pick the language being spoken before or during a session — switching is instant. Korean mode still catches common English words.")
                    Text("If recognition fails with a Siri/Dictation error, turn on Dictation in Settings › General › Keyboard.")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var speechDetail: String {
        switch model.speechAuth {
        case .authorized: return "Allowed"
        case .denied: return "Denied — allow in iOS Settings"
        case .restricted: return "Restricted on this device"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }
}

private struct StatusRow: View {
    let title: String
    let ok: Bool
    let detail: String

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(ok ? .green : .orange)
            Text(title)
            Spacer()
            Text(detail)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
