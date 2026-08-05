import SwiftUI

struct InteractivePermissionView: View {
    let prompt: InteractivePermissionPrompt
    let onDecision: (InteractivePermissionDecision) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label(prompt.target.title, systemImage: "lock.shield")
                    .font(.title3.weight(.semibold))

                Text("“\(prompt.blockTitle)” is requesting access.")
                    .foregroundStyle(Pen.inkPrimary)

                Text(prompt.target.reason)
                    .foregroundStyle(Pen.inkFaded)

                Text("This permission applies only to this block. It cannot read your notes, Penpal credentials, or another block’s storage.")
                    .font(.footnote)
                    .foregroundStyle(Pen.inkFaded)

                Spacer()

                VStack(spacing: 10) {
                    Button("Allow Once") {
                        onDecision(.allowOnce)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button("Always Allow for This Block") {
                        onDecision(.alwaysAllow)
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button("Don’t Allow", role: .cancel) {
                        onDecision(.deny)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
            .navigationTitle("Block Permission")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
    }
}
