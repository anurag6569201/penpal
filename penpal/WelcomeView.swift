// Penpal — Ink Studio welcome. A direct, account-free path to the page.

import Combine
import SwiftUI

// MARK: - Auth stub (PENDING real Google SDK)

/// Placeholder for Google Sign-In. Holds exactly the state the real SDK will
/// manage, so swapping it in later touches this file only.
@MainActor
final class AuthStub: ObservableObject {
    static let shared = AuthStub()

    @Published private(set) var isSignedIn: Bool =
        UserDefaults.standard.bool(forKey: "penpal.auth.stub.signedIn")
    @Published private(set) var displayName: String? =
        UserDefaults.standard.string(forKey: "penpal.auth.stub.name")

    /// Pretends to sign in. The real implementation replaces the body.
    func signInWithGoogle() {
        isSignedIn = true
        displayName = "Penpal user"
        UserDefaults.standard.set(true, forKey: "penpal.auth.stub.signedIn")
        UserDefaults.standard.set(displayName, forKey: "penpal.auth.stub.name")
    }

    func signOut() {
        isSignedIn = false
        displayName = nil
        UserDefaults.standard.removeObject(forKey: "penpal.auth.stub.signedIn")
        UserDefaults.standard.removeObject(forKey: "penpal.auth.stub.name")
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var isOpeningNotebook = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    HStack(spacing: 10) {
                        PenBrandSignature()
                        Spacer()
                        Text("A SPACE TO THINK")
                            .font(.caption2.weight(.semibold)).tracking(2)
                            .foregroundStyle(Pen.inkFaded)
                    }
                    .padding(.bottom, 16)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Your thoughts.\nRoom to grow.")
                            .font(.system(.largeTitle, design: .serif, weight: .medium))
                            .accessibilityAddTraits(.isHeader)
                        Text("A notebook that meets you on the page. Write freely, work through a problem, or explore an idea together.")
                            .font(Pen.body).foregroundStyle(Pen.inkFaded)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Label("ON YOUR PAGE", systemImage: "pencil.and.outline")
                                .font(.caption.weight(.semibold)).tracking(1.5)
                            Spacer()
                            Image(systemName: "sparkle")
                        }
                        .foregroundStyle(Pen.inkAccent)
                        Text("What if a notebook could\nthink alongside you?")
                            .font(.system(.title2, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                        Rectangle().fill(Pen.rule).frame(height: 1)
                        Label("Your handwriting. A little help. New possibilities.", systemImage: "arrow.turn.down.right")
                            .font(Pen.sub).foregroundStyle(Pen.inkFaded)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperCard()

                    VStack(alignment: .leading, spacing: 20) {
                        promise("01", title: "Stay with your thought", detail: "Write, sketch, and ask for help without leaving your page.")
                        promise("02", title: "Make it unmistakably yours", detail: "Teach Penpal your handwriting, then see replies in your own style.")
                        promise("03", title: "Go a little further", detail: "Explore maths, illustrations, languages, and ideas when you need them.")
                    }

                    VStack(spacing: 12) {
                        Button {
                            guard !isOpeningNotebook else { return }
                            Pen.tapHaptic()
                            isOpeningNotebook = true
                            onFinished()
                        } label: {
                            HStack(spacing: 10) {
                                if isOpeningNotebook {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(Pen.onAccent)
                                    Text("Opening notebook…")
                                } else {
                                    Text("Open my notebook")
                                    Image(systemName: "arrow.right")
                                }
                            }
                        }
                        .buttonStyle(PenPrimaryButtonStyle())
                        .disabled(isOpeningNotebook)
                        .accessibilityLabel(isOpeningNotebook ? "Opening notebook" : "Open my notebook")
                        Text("Start without an account. Notes are saved on this device.")
                            .font(Pen.caption).foregroundStyle(Pen.inkFaded)
                            .multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(Pen.inkPrimary)
                .padding(28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared || reduceMotion ? 0 : 10)
            }
            .background(Pen.paper.ignoresSafeArea())
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { appeared = true }
        }
    }

    private func promise(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.caption.monospacedDigit()).foregroundStyle(Pen.inkAccent)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Pen.headline)
                Text(detail).font(Pen.sub).foregroundStyle(Pen.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview { WelcomeView(onFinished: {}) }
