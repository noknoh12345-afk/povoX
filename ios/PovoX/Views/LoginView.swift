import SwiftUI

struct LoginView: View {
    @EnvironmentObject var store: AppStore
    @State private var email = ""
    @State private var phone = ""
    @State private var otp = ""
    @State private var useSMS = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StatusBanners()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("povo にログイン").font(.largeTitle.weight(.bold))
                        Text("公式アプリと同じ認証コードでログインします。ログイン情報はこの iPhone のキーチェーンにだけ保存します。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let flow = store.status?.login {
                        codeCard(flow)
                    } else {
                        startCard
                    }
                    Card {
                        Toggle(isOn: Binding(get: { store.mock }, set: { on in Task { await store.setMock(on) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("モックで試す").font(.subheadline.weight(.semibold))
                                Text("povo に通信しない練習用。認証コードは 000000").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("login.mock")
                    }
                    Text("非公式アプリです。KDDI・povo・Circles.life とは関係ありません。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var startCard: some View {
        Card {
            Picker("受け取り方", selection: $useSMS) {
                Text("メール").tag(false)
                Text("SMS").tag(true)
            }
            .pickerStyle(.segmented)
            Group {
                if useSMS {
                    TextField("電話番号(090…)", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                } else {
                    TextField("メールアドレス", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .onSubmit { send() }
                        .accessibilityIdentifier("login.email")
                }
            }
            .padding(12)
            .background(Theme.groove, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .focused($focused)
            Button {
                send()
            } label: {
                if store.isBusy("login") { ProgressView() } else { Text("認証コードを送る") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSend)
            .accessibilityIdentifier("login.send")
        }
    }

    private var canSend: Bool {
        !store.isBusy("login") && (useSMS ? phone.count >= 10 : email.contains("@"))
    }

    private func send() {
        guard canSend else { return }
        focused = false
        let e = useSMS ? "" : email
        let p = useSMS ? phone : ""
        Task { _ = await store.loginStart(email: e, phone: p) }
    }

    private func codeCard(_ flow: LoginState) -> some View {
        Card {
            Text("\(flow.current ?? "認証コード")を入力").font(.headline)
            if let id = flow.identifier { Text(id).font(.caption).foregroundStyle(.secondary) }
            TextField("6桁のコード", text: $otp)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(Theme.groove, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .focused($focused)
                .accessibilityIdentifier("login.code")
            Button {
                focused = false
                let code = otp
                Task {
                    await store.loginOTP(code)
                    otp = ""
                }
            } label: {
                if store.isBusy("login") { ProgressView() } else { Text("ログイン") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(otp.count < 4 || store.isBusy("login"))
            .accessibilityIdentifier("login.submit")
            HStack {
                Button("コードを送り直す") { Task { await store.loginResend() } }
                    .disabled((store.status?.otpCooldownS ?? 0) > 0)
                if let s = store.status?.otpCooldownS { Text("(あと\(s)秒)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("やめる", role: .destructive) { Task { await store.loginCancel() } }
            }
            .font(.subheadline)
            Text("入れ直しは3回まで(povo のロックを避けるため)。").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
