import SwiftUI
import UIKit

extension View {
    func authFieldStyle() -> some View {
        ledgerField()
    }
}

struct AuthPrimaryButton: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool
    let isEnabled: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button {
            // An error appears below the fields. The keyboard would cover it.
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
            action()
        } label: {
            HStack(spacing: 8) {
                if isBusy { ProgressView().tint(Theme.onAccent) }
                Text(isBusy ? busyTitle : title)
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!isEnabled || isBusy)
        .accessibilityIdentifier(identifier)
    }
}

/// Shared rules for choosing a password. The server has the final word; this only
/// avoids a round trip for the two mistakes it can see locally.
enum NewPasswordRule {
    static let minimumCharacters = 12
    static let maximumCharacters = 128
    static let hint = "Use 12 to 128 characters. Spaces and password managers are supported."

    /// Counts what the server counts: Unicode characters after normalizing to NFC.
    static func isLongEnough(_ password: String) -> Bool {
        let count = password.precomposedStringWithCanonicalMapping.unicodeScalars.count
        return count >= minimumCharacters && count <= maximumCharacters
    }

    static func problem(password: String, confirmation: String) -> String? {
        guard isLongEnough(password) else { return "Use a password of 12 to 128 characters." }
        guard password == confirmation else { return "The passwords do not match." }
        return nil
    }
}

struct NewPasswordFields: View {
    let label: String
    let idPrefix: String
    @Binding var password: String
    @Binding var confirmation: String
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(label, text: $password)
                .textContentType(.newPassword)
                .authFieldStyle()
                .accessibilityIdentifier("\(idPrefix).password")
            SecureField("Confirm password", text: $confirmation)
                .textContentType(.newPassword)
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .authFieldStyle()
                .accessibilityIdentifier("\(idPrefix).confirm-password")
            Text(NewPasswordRule.hint)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EmailCodeField: View {
    let idPrefix: String
    @Binding var code: String

    var body: some View {
        TextField("6-digit code", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.system(.body, design: .monospaced))
            .authFieldStyle()
            .accessibilityIdentifier("\(idPrefix).code")
    }
}

/// The server spaces out resends and answers every request the same way, so
/// tapping sooner cannot help. Waiting here keeps the receipt honest.
struct ResendCodeButton: View {
    let isBusy: Bool
    let idPrefix: String
    /// True only when a code was actually sent.
    let onResend: () async -> Bool
    @State private var secondsLeft = Self.cooldownSeconds

    static let cooldownSeconds = 60

    /// A failed send put no code in the inbox, so it must not lock out a retry.
    static func secondsLeft(afterSend sent: Bool, current: Int) -> Int {
        sent ? cooldownSeconds : current
    }

    var body: some View {
        Button {
            Task {
                let sent = await onResend()
                secondsLeft = Self.secondsLeft(afterSend: sent, current: secondsLeft)
            }
        } label: {
            Text(secondsLeft > 0 ? "Send a new code in \(secondsLeft)s" : "Send a new code")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(secondsLeft > 0 ? Theme.textSecondary : Theme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(secondsLeft > 0 || isBusy)
        .accessibilityIdentifier("\(idPrefix).resend")
        .task(id: secondsLeft) {
            guard secondsLeft > 0 else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            secondsLeft -= 1
        }
    }
}

/// Create account and Forgot password are the same two steps: an email, then the
/// code from it along with a password. Both end signed in.
struct EmailPasswordFlowView: View {
    enum Purpose {
        case createAccount
        case resetPassword

        var title: String { self == .createAccount ? "Create your account" : "Reset your password" }
        var idPrefix: String { self == .createAccount ? "sign-up" : "reset" }
        var passwordLabel: String { self == .createAccount ? "Choose a password" : "New password" }
        var emailDetail: String {
            self == .createAccount
                ? "We will email you a code to confirm the address."
                : "Enter your account email and we will send you a code. This also works if you have never set a password. Resetting signs out your other devices."
        }
    }

    let purpose: Purpose
    let service: FirstPartyAuthService
    /// The password was accepted but signing in failed. Sign in by hand from here.
    let onSignInNeeded: (String) -> Void
    let onCancel: () -> Void
    @State private var email: String
    @State private var name = ""
    @State private var code = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isAwaitingCode = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    init(
        purpose: Purpose,
        service: FirstPartyAuthService = .shared,
        initialEmail: String = "",
        onSignInNeeded: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.purpose = purpose
        self.service = service
        self.onSignInNeeded = onSignInNeeded
        self.onCancel = onCancel
        _email = State(initialValue: initialEmail)
    }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(purpose.title)
                        .font(.ledgerTitle2)
                        .foregroundStyle(Theme.text)
                    if isAwaitingCode {
                        codeStep
                    } else {
                        emailStep
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.disabled(isBusy)
                }
            }
        }
    }

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(purpose.emailDetail)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .authFieldStyle()
                .accessibilityIdentifier("\(purpose.idPrefix).email")
            if purpose == .createAccount {
                TextField("Name (optional)", text: $name)
                    .textContentType(.name)
                    .authFieldStyle()
                    .accessibilityIdentifier("sign-up.name")
            }
            errorText
            AuthPrimaryButton(
                title: "Send code",
                busyTitle: "Sending…",
                isBusy: isBusy,
                isEnabled: trimmedEmail.contains("@"),
                identifier: "\(purpose.idPrefix).send-code"
            ) {
                Task { await sendCode() }
            }
        }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(AuthCopy.emailReceipt + ". Enter the code it contains.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(purpose.idPrefix).receipt")
            // Read-only, but password managers pair the new password with it.
            TextField("Email", text: .constant(trimmedEmail))
                .textContentType(.username)
                .disabled(true)
                .foregroundStyle(Theme.textSecondary)
                .authFieldStyle()
            EmailCodeField(idPrefix: purpose.idPrefix, code: $code)
            NewPasswordFields(
                label: purpose.passwordLabel,
                idPrefix: purpose.idPrefix,
                password: $password,
                confirmation: $confirmation,
                onSubmit: { Task { await submit() } }
            )
            errorText
            AuthPrimaryButton(
                title: purpose == .createAccount ? "Create account" : "Reset password",
                busyTitle: "Saving…",
                isBusy: isBusy,
                isEnabled: !code.isEmpty && !password.isEmpty && !confirmation.isEmpty,
                identifier: "\(purpose.idPrefix).submit"
            ) {
                Task { await submit() }
            }
            ResendCodeButton(isBusy: isBusy, idPrefix: purpose.idPrefix) {
                await sendCode()
            }
            Button("Use a different email") {
                isAwaitingCode = false
                code = ""
                errorMessage = nil
            }
            .buttonStyle(QuietButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage {
            InlineError(errorMessage, identifier: "\(purpose.idPrefix).error")
        }
    }

    @discardableResult
    private func sendCode() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            switch purpose {
            case .createAccount:
                try await service.beginSignUp(email: trimmedEmail, name: name)
            case .resetPassword:
                try await service.beginPasswordReset(email: trimmedEmail)
            }
            isAwaitingCode = true
            return true
        } catch {
            errorMessage = AuthCopy.message(
                for: error,
                fallback: "Could not send a code. Please try again."
            )
        }
        return false
    }

    private func submit() async {
        guard !isBusy, !code.isEmpty else { return }
        if let problem = NewPasswordRule.problem(password: password, confirmation: confirmation) {
            errorMessage = problem
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            switch purpose {
            case .createAccount:
                try await service.finishSignUp(email: trimmedEmail, code: code, password: password)
            case .resetPassword:
                try await service.finishPasswordReset(email: trimmedEmail, code: code, password: password)
            }
            // The new session replaces this screen with the workspace.
            password = ""
            confirmation = ""
        } catch FirstPartyAuthError.signInNeededAfterProof {
            password = ""
            confirmation = ""
            onSignInNeeded(trimmedEmail)
        } catch {
            errorMessage = AuthCopy.message(
                for: error,
                fallback: "Could not finish. Please try again."
            )
        }
    }
}
