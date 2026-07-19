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
    @State private var tab: Tab = .capability
    @State private var health: PenpalAPI.VerificationHealth?
    @State private var accessToken = PenpalAPI.accessToken
    @StateObject private var hands = HandProfiles.shared
    @State private var newHandName = ""
    @State private var showInsights = false
    var onStatus: (String) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case capability = "Penpal"
        case style = "Style"
        case page = "Page"
        case behavior = "Behavior"
        var id: String { rawValue }
    }

    /// (tag, title, icon, blurb) for the capability cards.
    static let capabilities: [(tag: String, title: String, icon: String, blurb: String)] = [
        ("companion", "Companion", "heart.text.square",
         "A friend on the page. Talks with you in the mood you pick."),
        ("mathematician", "Mathematician", "x.squareroot",
         "Any math, school to university — algebra, calculus, proofs, olympiad. Every answer independently verified."),
    ]

    static let moods: [(tag: String, title: String, icon: String)] = [
        ("warm", "Warm friend", "cup.and.saucer"),
        ("playful", "Playful", "party.popper"),
        ("thoughtful", "Thoughtful", "moon.stars"),
        ("coach", "Coach", "figure.run"),
        ("custom", "Custom…", "wand.and.stars"),
    ]

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
                    case .capability: capabilitySettings
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

    // MARK: - Capability (what Penpal IS)

    @ViewBuilder private var capabilitySettings: some View {
        Section {
            ForEach(Self.capabilities, id: \.tag) { cap in
                Button {
                    settings.capability = cap.tag
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: cap.icon)
                            .font(.title3)
                            .frame(width: 34, height: 34)
                            .foregroundStyle(settings.capability == cap.tag ? .white : .primary)
                            .background(
                                settings.capability == cap.tag
                                    ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(Color.secondary.opacity(0.15)),
                                in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cap.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(cap.blurb)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.capability == cap.tag {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Label("Capability", systemImage: "sparkles")
        } footer: {
            Text("Who Penpal is when it replies. Switch anytime — also from the Penpal banner on the page.\n\nAlways on, in any capability: write a calculation ending in \"=\" (like 5+5=) and the answer appears instantly — solved on device, no AI. Draw a box or circle around any problem to send exactly that to Penpal.")
        }

        if settings.capability == "companion" {
            Section {
                ForEach(Self.moods, id: \.tag) { mood in
                    Button {
                        settings.companionMood = mood.tag
                    } label: {
                        HStack {
                            Label(mood.title, systemImage: mood.icon)
                                .foregroundStyle(.primary)
                            Spacer()
                            if settings.companionMood == mood.tag {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if settings.companionMood == "custom" {
                    TextField("Describe the persona — e.g. \"a wise old sailor, salty but kind\"",
                              text: $settings.customMoodText, axis: .vertical)
                        .lineLimit(2...4)
                }
            } header: {
                Label("Mood", systemImage: "theatermasks")
            } footer: {
                Text(settings.companionMood == "custom"
                     ? "Your words become Penpal's personality. Keep it short and vivid."
                     : "How your companion talks to you.")
            }
        }

        Section {
            Toggle("Confirm before solving", isOn: $settings.confirmBeforeSolving)
        } header: {
            Label("Calculator", systemImage: "equal.circle")
        } footer: {
            Text(settings.confirmBeforeSolving
                 ? "After you write an expression ending in \"=\", Penpal shows how it read your ink with a Solve button — tap the expression to correct it first. Nothing is calculated until you tap Solve."
                 : "Expressions ending in \"=\" are solved and written immediately.")
        }

        if settings.capability == "mathematician" {
            Section {
                Picker("Detail", selection: $settings.mathDetail) {
                    Text("Answer").tag("answer")
                    Text("Compact").tag("compact")
                    Text("Full").tag("full")
                    Text("Proof").tag("proof")
                }
                .pickerStyle(.segmented)
            } header: {
                Label("Solution detail", systemImage: "list.number")
            } footer: {
                Text("Compact shows key steps ending in \"Ans:\". Full adds a reason for every step. Proof gives complete rigor ending in QED.\n\nAfter any solution, write (or tap): \"explain\" for a deeper walkthrough, \"another way\" for a second method, \"harder\" for a practice problem — or \"check\" above your own working to find your first wrong line.\n\nBehind the scenes each answer is computed with an exact math engine where possible and re-checked by an independent verifier before it's written.")
            }
        }
    }

    @ViewBuilder private var styleSettings: some View {
        // PEN-20 — a shared iPad is the normal case. Without this, the second
        // person to train writes over the first person's hand.
        Section {
            ForEach(hands.profiles) { profile in
                Button {
                    hands.activate(profile.id)
                } label: {
                    HStack {
                        Label(profile.name, systemImage: "hand.draw")
                            .foregroundStyle(.primary)
                        Spacer()
                        if hands.active?.id == profile.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                TextField("New hand's name", text: $newHandName)
                    .textInputAutocapitalization(.words)
                Button("Add") {
                    let created = hands.addProfile(named: newHandName)
                    hands.activate(created.id)
                    newHandName = ""
                    onStatus("Switched to a fresh hand — train it from Teach it your hand.")
                }
                .disabled(newHandName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Label("Whose handwriting", systemImage: "person.2")
        } footer: {
            Text("Each hand keeps its own training. Notes are shared — the hand is who's writing, not whose notebook this is.")
        }

        // PEN-24 — observation, not correction. Opt-in behind a disclosure so
        // it is never pushed at anyone; an app that critiques your handwriting
        // unprompted is unpleasant.
        Section {
            DisclosureGroup("About your handwriting", isExpanded: $showInsights) {
                if HandwritingInsights.hasEnoughData {
                    ForEach(HandwritingInsights.current()) { insight in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: insight.systemImage)
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(insight.title)
                                    .font(.subheadline.weight(.medium))
                                Text(insight.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                } else {
                    Text(HandwritingInsights.notEnoughDataMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("What Penpal has learned from your training. It's a description, not a score — every hand is different and that's the point.")
        }

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
                    inkSwatchButton(name: name, fill: AnyShapeStyle(color))
                }

                // "Active" — always mirrors whatever color the user currently
                // has selected in the pen tray, instead of a fixed color.
                Button {
                    settings.inkColorName = "active"
                } label: {
                    Circle()
                        .fill(AnyShapeStyle(AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center)))
                        .frame(width: 30, height: 30)
                        .overlay {
                            Image(systemName: settings.inkColorName == "active"
                                  ? "checkmark" : "applepencil.tip")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .overlay {
                            Circle().stroke(
                                settings.inkColorName == "active"
                                    ? Color.accentColor : .clear, lineWidth: 2.5)
                                .padding(-4)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Active — match my pen color")

                // Full color picker — any color, not just the presets.
                ColorPicker("", selection: Binding(
                    get: { Color(UIColor(hex: settings.customColorHex) ?? .systemIndigo) },
                    set: { newColor in
                        settings.customColorHex = UIColor(newColor).hexString
                        settings.inkColorName = "custom"
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30, height: 30)
                .overlay {
                    Circle().stroke(
                        settings.inkColorName == "custom"
                            ? Color.accentColor : .clear, lineWidth: 2.5)
                        .padding(-4)
                        .allowsHitTesting(false)
                }

                Spacer()
            }
            .padding(.vertical, 4)

            if settings.inkColorName == "active" {
                Text("Replies write in whatever color your pen is currently set to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

    private func inkSwatchButton(name: String, fill: AnyShapeStyle) -> some View {
        Button {
            settings.inkColorName = name
        } label: {
            Circle()
                .fill(fill)
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
        // PEN-04 — verification health, stated plainly. If answers are going
        // out unchecked the user should hear it from us, not discover it.
        Section {
            HStack(spacing: 10) {
                Image(systemName: health.map { $0.isHealthy ? "checkmark.seal.fill"
                                                            : "exclamationmark.triangle.fill" }
                      ?? "questionmark.circle")
                    .foregroundStyle(health.map { $0.isHealthy ? Color.green : Color.orange }
                                     ?? .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(health?.summary ?? "Checking…")
                        .font(.subheadline)
                    if let health, health.solves > 0 {
                        Text("\(health.solves) solved · \(health.cas_hits) computed exactly"
                             + (health.corrections_applied > 0
                                ? " · \(health.corrections_applied) rewritten" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
        } header: {
            Label("Answer checking", systemImage: "checkmark.shield")
        } footer: {
            Text("Every solution is re-derived by a second, independent pass before it's written. Exact results come from a computer-algebra engine where possible.")
        }
        .task { health = await PenpalAPI.verificationHealth(baseURL: settings.apiBaseURL) }

        Section {
            Toggle("Gemini brain", isOn: $settings.useBrain)
            TextField("API base URL", text: $settings.apiBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("Access token (optional)", text: $accessToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: accessToken) { _, value in
                    PenpalAPI.accessToken = value
                }
            Button("Reset conversation") {
                ConversationStore.shared.reset()
                onStatus("Conversation cleared.")
            }
        } header: {
            Label("Brain", systemImage: "brain.head.profile")
        } footer: {
            Text("Penpal pen reads handwriting on-device, then sends text to Django → Gemini.\n\nLeave the token blank when running the brain locally. A deployed brain requires one (it matches PENPAL_TOKENS on the server).")
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
            Button("Show gesture tips again") {
                GestureOnboarding.shared.reset()
                onStatus("Gesture tips will show next time you turn Penpal on.")
            }
        } header: {
            Label("Debug", systemImage: "waveform.path.ecg")
        } footer: {
            Text("Gestures: box a problem to solve it · double-underline your working to have it checked · strike through ink to delete it.")
        }
    }
}
