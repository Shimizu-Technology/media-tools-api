import SwiftUI

/// Sets a first password, or replaces one. A first password also needs proof of
/// the account email, because nothing else shows this person controls it.
struct PasswordManagementSheet: View {
    let configured: Bool
    let email: String
    let emailVerified: Bool
    var service: FirstPartyAuthService = .shared
    let onSaved: (PasswordStatus) -> Void
    let onEmailVerified: () -> Void
    let onCancel: () -> Void

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var code = ""
    @State private var needsEmailProof = false
    @State private var codeSent = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(configured ? "Change password" : "Create a password")
                        .font(.displayTitle2)
                        .foregroundStyle(Theme.text)
                    if needsEmailProof {
                        proofStep
                    } else {
                        passwordStep
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.disabled(isBusy)
                }
            }
            .onAppear { needsEmailProof = !configured && !emailVerified }
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(configured
                 ? "Changing your password signs out your other devices. This iPhone stays signed in."
                 : "Use this password with your account email on iPhone and web.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Read-only, but password managers pair the new password with it.
            TextField("Email", text: .constant(email))
                .textContentType(.username)
                .disabled(true)
                .foregroundStyle(Theme.textSecondary)
                .authFieldStyle()
            if configured {
                SecureField("Current password", text: $currentPassword)
                    .textContentType(.password)
                    .authFieldStyle()
                    .accessibilityIdentifier("password-setup.current")
            }
            NewPasswordFields(
                label: "New password",
                idPrefix: "password-setup",
                password: $newPassword,
                confirmation: $confirmation,
                onSubmit: { Task { await save() } }
            )
            errorText
            AuthPrimaryButton(
                title: configured ? "Change password" : "Create password",
                busyTitle: "Saving…",
                isBusy: isBusy,
                isEnabled: !newPassword.isEmpty && !confirmation.isEmpty
                    && (!configured || !currentPassword.isEmpty),
                identifier: "password-setup.save"
            ) {
                Task { await save() }
            }
        }
    }

    private var proofStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(codeSent
                 ? AuthCopy.emailReceipt + ". Enter the code it contains."
                 : "First, confirm that \(email) is yours. We will email you a code.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if codeSent {
                EmailCodeField(idPrefix: "verify-email", code: $code)
            }
            errorText
            if codeSent {
                AuthPrimaryButton(
                    title: "Confirm email",
                    busyTitle: "Checking…",
                    isBusy: isBusy,
                    isEnabled: !code.isEmpty,
                    identifier: "verify-email.submit"
                ) {
                    Task { await confirmEmail() }
                }
                ResendCodeButton(isBusy: isBusy, idPrefix: "verify-email") {
                    await sendCode()
                }
            } else {
                AuthPrimaryButton(
                    title: "Send code",
                    busyTitle: "Sending…",
                    isBusy: isBusy,
                    isEnabled: true,
                    identifier: "verify-email.send-code"
                ) {
                    Task { await sendCode() }
                }
            }
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage {
            InlineError(errorMessage, identifier: "password-setup.error")
        }
    }

    private func save() async {
        guard !isBusy else { return }
        if let problem = NewPasswordRule.problem(password: newPassword, confirmation: confirmation) {
            errorMessage = problem
            return
        }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            onSaved(try await service.setPassword(
                newPassword,
                currentPassword: configured ? currentPassword : nil
            ))
        } catch APIError.httpError(_, "email_verification_required", _) {
            needsEmailProof = true
        } catch {
            errorMessage = AuthCopy.message(
                for: error,
                fallback: "Could not save the password. Please try again."
            )
        }
    }

    @discardableResult
    private func sendCode() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.beginEmailVerification(email: email)
            codeSent = true
            return true
        } catch {
            errorMessage = AuthCopy.message(for: error, fallback: "Could not send a code. Please try again.")
        }
        return false
    }

    private func confirmEmail() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.confirmEmailVerification(email: email, code: code)
            code = ""
            needsEmailProof = false
            onEmailVerified()
        } catch {
            errorMessage = AuthCopy.message(for: error, fallback: "Could not confirm your email. Please try again.")
        }
    }
}

/// Moves the account to a new email. The server revokes every session and key when
/// this finishes, so this also signs back in. The account ID never changes, which
/// is why recordings and uploads on this iPhone carry on under the same owner.
struct ChangeEmailSheet: View {
    let currentEmail: String
    var service: FirstPartyAuthService = .shared
    let onFinished: () -> Void
    let onCancel: () -> Void

    @State private var newEmail = ""
    @State private var currentPassword = ""
    @State private var code = ""
    @State private var isAwaitingCode = false
    @State private var isBusy = false
    @State private var errorMessage: String?

    private var trimmedEmail: String {
        newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Change email")
                        .font(.displayTitle2)
                        .foregroundStyle(Theme.text)
                    if isAwaitingCode {
                        Text(AuthCopy.emailReceipt + ". Enter the code sent to \(trimmedEmail).")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        EmailCodeField(idPrefix: "change-email", code: $code)
                        errorText
                        AuthPrimaryButton(
                            title: "Change email",
                            busyTitle: "Changing…",
                            isBusy: isBusy,
                            isEnabled: !code.isEmpty,
                            identifier: "change-email.submit"
                        ) {
                            Task { await finish() }
                        }
                        ResendCodeButton(isBusy: isBusy, idPrefix: "change-email") {
                            await sendCode()
                        }
                    } else {
                        Text("Currently \(currentEmail). Changing it signs out your other devices and removes your developer keys.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("New email", text: $newEmail)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .authFieldStyle()
                            .accessibilityIdentifier("change-email.email")
                        SecureField("Current password", text: $currentPassword)
                            .textContentType(.password)
                            .authFieldStyle()
                            .accessibilityIdentifier("change-email.password")
                        errorText
                        AuthPrimaryButton(
                            title: "Send code",
                            busyTitle: "Sending…",
                            isBusy: isBusy,
                            isEnabled: trimmedEmail.contains("@") && !currentPassword.isEmpty,
                            identifier: "change-email.send-code"
                        ) {
                            Task { await sendCode() }
                        }
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }.disabled(isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let errorMessage {
            InlineError(errorMessage, identifier: "change-email.error")
        }
    }

    @discardableResult
    private func sendCode() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.beginEmailChange(newEmail: trimmedEmail, currentPassword: currentPassword)
            isAwaitingCode = true
            return true
        } catch {
            errorMessage = AuthCopy.message(for: error, fallback: "Could not send a code. Please try again.")
        }
        return false
    }

    private func finish() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.finishEmailChange(
                newEmail: trimmedEmail,
                code: code,
                currentPassword: currentPassword
            )
            currentPassword = ""
            onFinished()
        } catch {
            errorMessage = AuthCopy.message(for: error, fallback: "Could not change your email. Please try again.")
        }
    }
}

struct UsageSummaryView: View {
    let usage: AccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if usage.exempt {
                Text("This account has no monthly limit.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("usage.exempt")
            }
            meter(
                title: "This month",
                detail: usage.exempt
                    ? "\(minutes(usage.transcriptionSeconds)) min"
                    : "\(minutes(usage.transcriptionSeconds)) of \(minutes(usage.transcriptionLimitSeconds)) min",
                fraction: usage.exempt ? nil : fraction(usage.transcriptionSeconds, of: usage.transcriptionLimitSeconds)
            )
            meter(
                title: "Summaries and chat",
                detail: usage.exempt
                    ? "\(usage.aiRequests) requests"
                    : "\(usage.aiRequests) of \(usage.aiRequestLimit) requests",
                fraction: usage.exempt ? nil : fraction(usage.aiRequests, of: usage.aiRequestLimit)
            )
            if !usage.exempt, let resetDate {
                Text("Resets \(resetDate).")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityIdentifier("usage.summary")
    }

    private func meter(title: String, detail: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(detail)
                    .font(.number)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            if let fraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule()
                            .fill(Theme.heroGradient)
                            .frame(width: max(6, geometry.size.width * fraction))
                    }
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func minutes(_ seconds: Int) -> Int {
        Int((Double(seconds) / 60).rounded(.up))
    }

    private func fraction(_ value: Int, of limit: Int) -> Double {
        guard limit > 0 else { return 1 }
        return min(Double(value) / Double(limit), 1)
    }

    /// Months turn over at the UTC calendar boundary, not local midnight.
    private var resetDate: String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let next = calendar.date(byAdding: .month, value: 1, to: usage.month) else { return nil }
        return next.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Every device signed in to this account. Revoking one ends that session on its
/// next request. This iPhone is listed but not revocable here; Sign out does that.
struct DevicesListView: View {
    var service: FirstPartyAuthService = .shared
    let currentSessionID: String?

    @State private var sessions: [DeviceSessionSummary]?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var revoking: DeviceSessionSummary?
    @State private var revokeError: String?

    var body: some View {
        List {
            if let sessions {
                ForEach(sessions) { session in
                    row(session)
                }
                if sessions.isEmpty {
                    Text("No signed-in devices.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .listRowBackground(Color.clear)
                }
            } else if isLoading {
                ProgressView("Loading devices…")
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            if let errorMessage {
                VStack(alignment: .leading, spacing: 0) {
                    InlineError(errorMessage)
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(QuietButtonStyle())
                }
                .listRowBackground(Color.clear)
            }
            if let revokeError {
                InlineError(revokeError)
                    .listRowBackground(Color.clear)
            }
        }
        .themedListBackground()
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(
            "Sign out this device?",
            isPresented: Binding(
                get: { revoking != nil },
                set: { if !$0 { revoking = nil } }
            ),
            titleVisibility: .visible,
            presenting: revoking
        ) { session in
            Button("Sign out device", role: .destructive) {
                Task { await revoke(session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("\(displayName(session)) will need to sign in again. Recordings saved on it stay there.")
        }
    }

    private func row(_ session: DeviceSessionSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(session))
                    .font(.body)
                    .foregroundStyle(Theme.text)
                Text(detail(session))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if session.id == currentSessionID {
                Text("This iPhone")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button("Sign out") { revoking = session }
                    .buttonStyle(QuietButtonStyle(color: Theme.danger))
                    .accessibilityIdentifier("devices.revoke.\(session.id)")
            }
        }
        .frame(minHeight: 44)
        .listRowBackground(Theme.surface)
    }

    private func displayName(_ session: DeviceSessionSummary) -> String {
        if let name = session.deviceName, !name.isEmpty { return name }
        return session.clientType == "web" ? "Web browser" : "Device"
    }

    private func detail(_ session: DeviceSessionSummary) -> String {
        let date = session.lastUsedAt ?? session.createdAt
        return "Last used \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            sessions = try await service.deviceSessions().filter(\.isUsable)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = AuthCopy.message(for: error, fallback: "Could not load your devices.")
        }
    }

    private func revoke(_ session: DeviceSessionSummary) async {
        revokeError = nil
        do {
            try await service.revokeDeviceSession(id: session.id)
            sessions?.removeAll { $0.id == session.id }
        } catch {
            revokeError = AuthCopy.message(for: error, fallback: "Could not sign out that device.")
        }
    }
}
