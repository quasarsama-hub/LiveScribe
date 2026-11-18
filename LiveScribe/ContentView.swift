import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Language", selection: $model.language) {
                        ForEach(TranscriptLanguage.allCases) { language in
                            Text(language.label).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                    HStack(spacing: 12) {
                        systemCard
                        micCard
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }

                if let live = liveContent {
                    Section {
                        LivePanel(
                            source: live.source,
                            language: model.language.label,
                            status: live.status,
                            committed: live.committed,
                            volatile: live.volatile,
                            level: live.level,
                            tint: live.tint,
                            onCopy: { UIPasteboard.general.string = model.liveFullText() })
                    }
                }

                Section {
                    if model.visibleSessions.isEmpty {
                        Text("Transcripts you record show up here. Tap one to edit or copy it.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 6)
                    }
                    ForEach(model.visibleSessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                    .onDelete { offsets in
                        let visible = model.visibleSessions
                        model.delete(ids: offsets.map { visible[$0].id })
                    }
                } header: {
                    Text("Transcripts")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("LiveScribe")
            .navigationDestination(for: UUID.self) { id in
                SessionDetailView(sessionID: id)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
            .alert("LiveScribe", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .tint(Theme.accent)
    }

    // MARK: Capture cards

    @ViewBuilder
    private var systemCard: some View {
        if model.systemLive != nil {
            Button {
                model.stopSystem()
            } label: {
                CaptureCard(
                    title: "System audio",
                    subtitle: model.systemStopRequested ? "Stopping…" : "Live · tap to stop",
                    symbol: "stop.fill",
                    active: true,
                    tint: Theme.system)
            }
            .buttonStyle(.plain)
            .disabled(model.systemStopRequested)
        } else {
            let blocked = model.micPhase != .idle
            CaptureCard(
                title: "System audio",
                subtitle: "Sound from other apps",
                symbol: "speaker.wave.2.fill",
                active: false,
                tint: Theme.system)
                .overlay(
                    Group {
                        if !blocked {
                            BroadcastPickerOverlay(extensionID: model.broadcastExtensionID)
                        }
                    }
                )
                .opacity(blocked ? 0.4 : 1)
        }
    }

    private var micCard: some View {
        Button {
            model.toggleMic()
        } label: {
            CaptureCard(
                title: "Microphone",
                subtitle: micSubtitle,
                symbol: model.micPhase == .idle ? "mic.fill" : "stop.fill",
                active: model.micPhase != .idle,
                tint: Theme.mic)
        }
        .buttonStyle(.plain)
        .disabled(model.systemLive != nil || model.micPhase == .finishing)
        .opacity(model.systemLive != nil ? 0.4 : 1)
    }

    private var micSubtitle: String {
        switch model.micPhase {
        case .idle: return "Room, calls on speaker"
        case .running: return "Live · tap to stop"
        case .finishing: return "Saving…"
        }
    }

    // MARK: Live panel content

    private struct LiveContent {
        let source: String
        let status: String
        let committed: String
        let volatile: String
        let level: Float
        let tint: Color
    }

    private var liveContent: LiveContent? {
        if model.micPhase != .idle {
            let status: String
            if model.micPhase == .finishing {
                status = "Saving…"
            } else if !model.micNotice.isEmpty {
                status = model.micNotice
            } else {
                status = model.micStatus
            }
            return LiveContent(
                source: "Microphone",
                status: status,
                committed: String(model.micText.suffix(4000)),
                volatile: model.micVolatile,
                level: model.micLevel,
                tint: Theme.mic)
        }
        if let live = model.systemLive {
            let hearing = live.lastAudio.map { live.heartbeat.timeIntervalSince($0) < 3 } ?? false
            let status: String
            if model.systemStopRequested {
                status = "Stopping…"
            } else if hearing {
                status = live.status
            } else {
                status = "No sound yet — play something in another app"
            }
            return LiveContent(
                source: "System audio",
                status: status,
                committed: live.committedTail,
                volatile: live.volatile,
                level: live.level,
                tint: Theme.system)
        }
        return nil
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
    }
}
