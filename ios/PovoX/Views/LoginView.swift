import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var email = ""
    @State private var phone = ""
    @State private var otp = ""
    @State private var useSMS = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StatusBanners()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if let flow = model.status?.login {
                    Section {
                        Text("\(flow.current ?? "認証コード")を入力してください")
                        if let id = flow.identifier { Text(id).font(.caption).foregroundStyle(.secondary) }
                        TextField("6桁のコード", text: $otp)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .font(.title2.monospacedDigit())
                        Button {
                            Task {
                                await model.loginOTP(otp)
                                otp = ""
                            }
                        } label: {
                            Text("ログイン").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(otp.count < 4 || model.busy)
                    } header: {
                        Text("認証コード")
                    } footer: {
                        Text("入れ直しは3回まで(povo のロックを避けるため)。")
                    }
                    Section {
                        Button("コードを送り直す") { Task { await model.loginResend() } }
                            .disabled((model.status?.otpCooldownS ?? 0) > 0 || model.busy)
                        if let s = model.status?.otpCooldownS { Text("あと\(s)秒で送り直せます").font(.caption) }
                        Button("やめる", role: .destructive) { Task { await model.loginCancel() } }
                    }
                } else {
                    Section {
                        Picker("受け取り方", selection: $useSMS) {
                            Text("メール").tag(false)
                            Text("SMS").tag(true)
                        }
                        .pickerStyle(.segmented)
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
                        }
                        Button {
                            Task { _ = await model.loginStart(email: useSMS ? "" : email, phone: useSMS ? phone : "") }
                        } label: {
                            Text("認証コードを送る").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || (useSMS ? phone.count < 10 : !email.contains("@")))
                    } header: {
                        Text("povo アカウント")
                    } footer: {
                        Text("povo の公式アプリと同じ方法(認証コード)でログインします。ログイン情報はこの iPhone のキーチェーンにだけ保存します。\(model.status?.mock == true ? "\nモックの認証コードは 000000 です。" : "")")
                    }
                    Section {
                        Toggle("モック(povo に通信しない練習用)", isOn: Binding(
                            get: { model.status?.mock ?? false },
                            set: { on in Task { await model.setMock(on) } }
                        ))
                    } footer: {
                        Text("非公式アプリです。KDDI・povo とは関係ありません。")
                    }
                }
            }
            .navigationTitle("povoX")
            .overlay { if model.busy { ProgressView() } }
        }
    }
}
