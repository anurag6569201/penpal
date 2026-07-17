//
//  PenpalSettingsView.swift
//  penpal
//
//  Former ContentView settings — now opened from the Notes ⋯ menu.
//

import SwiftUI

struct PenpalSettingsView: View {
    @ObservedObject var settings: HandwritingSettings
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .style
    var onStatus: (String) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case style = "Style"
        case page = "Page"
        case behavior = "Behavior"
        var id: String { rawValue }
    }

    static let replyFonts: [(name: String, display: String)] = [
        ("SnellRoundhand", "Snell Roundhand"),
        ("BradleyHandITCTT-Bold", "Bradley Hand"),
        ("Noteworthy-Light", "Noteworthy"),
        ("MarkerFelt-Thin", "Marker Felt"),
        ("Georgia-Italic", "Georgia Italic"),
        ("AmericanTypewriter", "Typewriter"),
    ]

    private var fontSelection: Binding<String> {
        Binding(
            get: { settings.replyStyle == "hand" ? "hand" : settings.replyFontName },
            set: { value in
                if value == "hand" {
                    settings.replyStyle = "hand"
                } else {
                    settings.replyStyle = "font"
                    settings.replyFontName = value
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Form {
                    switch tab {
                    case .style: styleSettings
                    case .page: pageSettings
                    case .behavior: behaviorSettings
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Penpal Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private var styleSettings: some View {
        Section {
            fontRow(tag: "hand", title: "My handwriting", preview: nil)
            ForEach(Self.replyFonts, id: \.name) { font in
                fontRow(tag: font.name, title: font.display,
                        preview: .custom(font.name, size: 20))
            }
        } header: {
            Label("Reply font", systemImage: "textformat")
        } footer: {
            Text("Only applies when the Penpal pen is selected and it writes a reply.")
        }

        Section {
            HStack(spacing: 14) {
                ForEach([("indigo", Color.indigo), ("blue", Color.blue),
                         ("black", Color.primary), ("green", Color.green),
                         ("purple", Color.purple)], id: \.0) { name, color in
                    Button {
                        settings.inkColorName = name
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 30, height: 30)
                            .overlay {
                                if settings.inkColorName == name {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .overlay {
                                Circle().stroke(
                                    settings.inkColorName == name
                                        ? Color.accentColor : .clear, lineWidth: 2.5)
                                    .padding(-4)
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.vertical, 4)

            LabeledContent("Pen width",
                           value: String(format: "%.1f×", settings.penWidthScale))
            Slider(value: $settings.penWidthScale, in: 0.55...1.8, step: 0.05)
            LabeledContent("Smoothness",
                           value: settings.smoothness < 0.02 ? "Off"
                               : "\(Int((settings.smoothness * 100).rounded()))%")
            Slider(value: $settings.smoothness, in: 0...1, step: 0.05)
            LabeledContent("Speed", value: "\(Int(settings.speedLevel))")
            Slider(value: $settings.speedLevel, in: 1...10, step: 1)
            LabeledContent("Variation", value: "\(Int(settings.variation))")
            Slider(value: $settings.variation, in: 0...10, step: 1)
            Toggle("Apple Pencil only", isOn: $settings.pencilOnly)
        } header: {
            Label("Pen & ink", systemImage: "applepencil.tip")
        }
    }

    private func fontRow(tag: String, title: String, preview: Font?) -> some View {
        Button {
            fontSelection.wrappedValue = tag
        } label: {
            HStack {
                if tag == "hand" {
                    Label(title, systemImage: "signature")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                } else {
                    Text(title)
                        .font(preview ?? .body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Spacer()
                if fontSelection.wrappedValue == tag {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder private var pageSettings: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)],
                      spacing: 12) {
                ForEach([("ruled", "Ruled"), ("grid", "Grid"),
                         ("dots", "Dots"), ("blank", "Blank")], id: \.0) { tag, name in
                    Button {
                        settings.paperStyle = tag
                    } label: {
                        VStack(spacing: 6) {
                            paperPreview(tag)
                                .frame(height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(settings.paperStyle == tag
                                                ? Color.accentColor : Color.secondary.opacity(0.25),
                                                lineWidth: settings.paperStyle == tag ? 2.5 : 1)
                                }
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(settings.paperStyle == tag
                                                 ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("Paper", systemImage: "doc.plaintext")
        }

        Section {
            Picker("Size", selection: $settings.sizeMode) {
                ForEach(HandwritingSizeMode.allCases) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            if settings.sizeMode == .manual {
                LabeledContent("Size", value: "\(Int(settings.manualSize)) pt")
                Slider(value: $settings.manualSize, in: 10...42, step: 1)
            }
        } header: {
            Label("Writing size", systemImage: "textformat.size")
        }

        Section {
            LabeledContent("Letters",
                           value: String(format: "%.1f×", settings.letterSpacingScale))
            Slider(value: $settings.letterSpacingScale, in: 0.7...1.5, step: 0.05)
            LabeledContent("Words",
                           value: String(format: "%.1f×", settings.wordSpacingScale))
            Slider(value: $settings.wordSpacingScale, in: 0.7...1.6, step: 0.05)
            LabeledContent("Lines",
                           value: String(format: "%.1f×", settings.lineSpacingScale))
            Slider(value: $settings.lineSpacingScale, in: 0.8...1.8, step: 0.05)
        } header: {
            Label("Spacing", systemImage: "arrow.left.and.right.text.vertical")
        }
    }

    private func paperPreview(_ style: String) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(.secondarySystemGroupedBackground)))
            let line = Color.secondary.opacity(0.45)
            switch style {
            case "grid":
                var x: CGFloat = 8
                while x < size.width {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 4))
                                      $0.addLine(to: CGPoint(x: x, y: size.height - 4)) },
                               with: .color(line.opacity(0.6)), lineWidth: 0.6)
                    x += 12
                }
                var gy: CGFloat = 10
                while gy < size.height {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 4, y: gy))
                                      $0.addLine(to: CGPoint(x: size.width - 4, y: gy)) },
                               with: .color(line.opacity(0.6)), lineWidth: 0.6)
                    gy += 12
                }
            case "dots":
                var dy: CGFloat = 10
                while dy < size.height {
                    var dx: CGFloat = 10
                    while dx < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: dx - 1, y: dy - 1,
                                                        width: 2, height: 2)),
                                 with: .color(line))
                        dx += 12
                    }
                    dy += 12
                }
            case "blank":
                break
            default:
                var ry: CGFloat = 14
                while ry < size.height {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: 4, y: ry))
                                      $0.addLine(to: CGPoint(x: size.width - 4, y: ry)) },
                               with: .color(line), lineWidth: 0.8)
                    ry += 12
                }
            }
        }
    }

    @ViewBuilder private var behaviorSettings: some View {
        Section {
            Toggle("Gemini brain", isOn: $settings.useBrain)
            TextField("API base URL", text: $settings.apiBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Reset conversation") {
                ConversationStore.shared.reset()
                onStatus("Conversation cleared.")
            }
        } header: {
            Label("Brain", systemImage: "brain.head.profile")
        } footer: {
            Text("Penpal pen reads handwriting on-device, then sends text to Django → Gemini.")
        }

        Section {
            Toggle("Auto reply (Penpal pen)", isOn: $settings.autoReply)
        } header: {
            Label("Replies", systemImage: "arrowshape.turn.up.left")
        } footer: {
            Text("Only runs when the Penpal pen is selected in the markup tray. Normal pens never trigger a reply.")
        }

        Section {
            Toggle("Diagnostics", isOn: $settings.diagnostics)
        } header: {
            Label("Debug", systemImage: "waveform.path.ecg")
        }
    }
}
