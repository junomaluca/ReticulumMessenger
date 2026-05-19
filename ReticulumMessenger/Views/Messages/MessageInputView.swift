// SPDX-License-Identifier: MIT
// ReticulumMessenger — MessageInputView.swift

import SwiftUI

struct MessageInputView: View {
    @Binding var text: String
    var isSending: Bool
    var isFocused: FocusState<Bool>.Binding
    var onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused(isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20))

            Button(action: onSend) {
                Group {
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.body.bold())
                    }
                }
                .frame(width: 20, height: 20)
                .padding(8)
                .foregroundStyle(.white)
                .background(
                    canSend ? Color.accentColor : Color.gray,
                    in: Circle()
                )
            }
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.15), value: canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }
}
