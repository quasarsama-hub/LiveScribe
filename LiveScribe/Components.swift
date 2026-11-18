import SwiftUI

struct CaptureCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let active: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundColor(active ? Color.white : tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(active ? tint : tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(active ? tint : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct PulseDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

struct LevelMeter: View {
    let level: Float
    let tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(Float(index) < level * 6 ? tint : Color.secondary.opacity(0.25))
                    .frame(width: 3, height: CGFloat(5 + index * 2))
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}

struct LivePanel: View {
    let source: String
    let language: String
    let status: String
    let committed: String
    let volatile: String
    let level: Float
    let tint: Color
    let onCopy: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PulseDot()
                Text("LIVE")
                    .font(.caption.weight(.heavy))
                    .foregroundColor(.red)
                Text("\(source) · \(language)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                LevelMeter(level: level, tint: tint)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if committed.isEmpty && volatile.isEmpty {
                            Text("Waiting for speech…")
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                        if !committed.isEmpty {
                            Text(committed)
                        }
                        if !volatile.isEmpty {
                            Text(volatile)
                                .foregroundColor(.secondary)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(height: 230)
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: committed.count + volatile.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("end", anchor: .bottom)
                    }
                }
            }

            HStack(alignment: .center) {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    onCopy()
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy all", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }
}

struct SessionRow: View {
    let session: TranscriptSession

    private var tint: Color { session.source == .system ? Theme.system : Theme.mic }

    private var preview: String {
        let text = session.text.replacingOccurrences(of: "\n", with: " ")
        return text.isEmpty ? "No text" : String(text.prefix(140))
    }

    private var meta: String {
        "\(session.language.label) · \(session.text.count) chars"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.source == .system ? "speaker.wave.2.fill" : "mic.fill")
                .font(.footnote.weight(.semibold))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(preview)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text(meta)
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
            }
        }
        .padding(.vertical, 3)
    }
}
