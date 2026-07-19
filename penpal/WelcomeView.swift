//
//  WelcomeView.swift
//  penpal
//
//  The landing page. Its one job: make clear in three seconds that this is
//  NOT another AI chat app — so it IS a page. Cream paper, ruled lines, and
//  the brand written on in script as if a hand just finished it.
//
//  Product decisions (see DESIGN.md):
//   * Copy leads with the promise, not a feature list.
//   * Google sign-in is a styled STUB (AuthStub) — the real SDK drops in
//     behind the same button with zero layout work.
//   * "Use without an account" is a first-class quiet button, always visible,
//     never shrunk or greyed. A student in a hurry must never be blocked by
//     auth, and declining must cost nothing.
//   * Shown once; a choice dismisses it forever.
//

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

    /// Called when the user has made a choice, either way.
    var onFinished: () -> Void

    @StateObject private var auth = AuthStub.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Staged entrance: brand writes on, then the rest settles in beneath it.
    @State private var brandVisible = false
    @State private var contentVisible = false

    var body: some View {
        ZStack {
            RuledPaperBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 40)

                // The brand, written on the top line like a signature.
                VStack(spacing: 6) {
                    Text("penpal")
                        .font(Pen.brand(56))
                        .foregroundStyle(Pen.inkAccent)
                        .opacity(brandVisible ? 1 : 0)
                        .offset(y: brandVisible ? 0 : 8)
                        .accessibilityAddTraits(.isHeader)

                    Text("paper that thinks back")
                        .font(Pen.titleSerif)
                        .foregroundStyle(Pen.inkPrimary)
                        .opacity(contentVisible ? 1 : 0)
                }
                .padding(.bottom, 44)

                // Three proof moments — the product in one glance each.
                VStack(alignment: .leading, spacing: 22) {
                    promise(icon: "pencil.and.outline",
                            title: "Write it, box it, it's solved",
                            detail: "Draw a box around any problem. Every answer is checked twice before it's written.")
                    promise(icon: "signature",
                            title: "Replies in your handwriting",
                            detail: "Penpal learns your hand and writes back in it — your page stays yours.")
                    promise(icon: "repeat",
                            title: "Your mistakes become practice",
                            detail: "Anything you get wrong quietly comes back a few days later, until it doesn't.")
                }
                .padding(26)
                .frame(maxWidth: 430)
                .paperCard()
                .opacity(contentVisible ? 1 : 0)
                .offset(y: contentVisible ? 0 : 12)

                Spacer(minLength: 28)

                // Auth. Google is a dummy; declining is a first-class path.
                VStack(spacing: 14) {
                    Button {
                        Pen.tapHaptic()
                        auth.signInWithGoogle()
                        onFinished()
                    } label: {
                        HStack(spacing: 10) {
                            // Placeholder mark — the branded asset arrives
                            // with the real SDK.
                            Text("G")
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .foregroundStyle(Pen.inkAccent)
                                .frame(width: 26, height: 26)
                                .background(.white, in: Circle())
                            Text("Continue with Google")
                        }
                    }
                    .buttonStyle(PenPrimaryButtonStyle())
                    .accessibilityHint("Signs in with your Google account")

                    Button("Use without an account") {
                        Pen.tapHaptic()
                        onFinished()
                    }
                    .buttonStyle(PenQuietButtonStyle())

                    // One privacy line: the audience includes minors and
                    // their parents, and this is the question they have.
                    Text("Your notes stay on this iPad.")
                        .font(Pen.caption)
                        .foregroundStyle(Pen.inkFaded)
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 26)
                .padding(.bottom, 40)
                .opacity(contentVisible ? 1 : 0)
            }
            .padding(.horizontal, 24)
        }
        .onAppear(perform: enter)
    }

    private func promise(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Pen.inkAccent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Pen.headline)
                    .foregroundStyle(Pen.inkPrimary)
                Text(detail)
                    .font(Pen.sub)
                    .foregroundStyle(Pen.inkFaded)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func enter() {
        guard !reduceMotion else {
            brandVisible = true
            contentVisible = true
            return
        }
        withAnimation(.easeOut(duration: 0.6)) { brandVisible = true }
        withAnimation(Pen.spring.delay(0.45)) { contentVisible = true }
    }
}

#Preview {
    WelcomeView(onFinished: {})
}
