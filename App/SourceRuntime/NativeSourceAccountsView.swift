import SwiftUI

struct NativeSourceCredentialContext: Identifiable {
    let id = UUID()
    let installation: SourceInstallation
    let session: SourceCredentialSession
    let changeGate: SourceCommitGate
}
struct NativeSourceLoginRequest: Identifiable {
    let id = UUID()
    let context: NativeSourceCredentialContext
    let origin: String
    var webRequest: URLRequest? = nil
}

@MainActor
final class NativeSourceAccountPresentation: ObservableObject {
    @Published var settings: SourceAccountSettings?
    @Published var status: SourceCredentialStatus?
}

struct NativeSourceAccountsView: View {
    @ObservedObject var model: NativeSourceLibrary
    let initialInstallation: SourceInstallation
    private var installation: SourceInstallation { model.installations.first { $0.id == initialInstallation.id } ?? initialInstallation }
    @StateObject private var presentation: NativeSourceAccountPresentation
    private var settings: SourceAccountSettings? { presentation.settings }
    private var status: SourceCredentialStatus? { presentation.status }
    init(model: NativeSourceLibrary, initialInstallation: SourceInstallation, presentation: NativeSourceAccountPresentation = .init()) {
        self.model = model; self.initialInstallation = initialInstallation
        _presentation = StateObject(wrappedValue: presentation)
    }
    @State private var selectedOrigin = ""
    @State private var busy = false
    @State private var feedback: String?
    @State private var login: NativeSourceLoginRequest?
    @State private var token: NativeSourceLoginRequest?
    @State private var clearing: NativeSourceCredentialContext?
    private var accountID: String { model.activeAccounts[installation.id]?.id ?? "guest" }
    private var origins: [String] { installation.origins.filter { URL(string: $0)?.scheme == "https" } }

    var body: some View {
        Form {
            if let settings {
                Section {
                    if !origins.isEmpty {
                        Picker("登录网站", selection: $selectedOrigin) {
                            ForEach(origins, id: \.self) { Text($0).tag($0) }
                        }
                        Button("打开网站登录或验证", systemImage: "globe") { prepareLogin(isToken: false) }.frame(minHeight: 44)
                    }
                } header: { Text("书源网站账号") } footer: {
                    Text("直接在书源网站登录。更换网站账号时，重新打开网页退出并登录新账号，再保存登录。书架、下载和阅读位置始终保留。")
                }
                Section {
                    if let status {
                        LabeledContent("本机保存的 Cookie", value: "\(status.cookieCount) 个")
                        LabeledContent("本机保存的令牌", value: "\(status.bearerOrigins.count) 个网站")
                    }
                    Button("清除此书源的登录凭据", role: .destructive) {
                        perform { clearing = try await model.credentialContext(installation, accountID: settings.selectedID) }
                    }.frame(minHeight: 44)
                } header: { Text("已保存的登录信息") } footer: {
                    Text("凭据保存在本机系统钥匙串。已保存 Cookie 不代表网站确认登录成功；登录状态以网页显示为准。")
                }
                if !origins.isEmpty {
                    Section("其他登录方式") {
                        Button("输入访问令牌") { prepareLogin(isToken: true) }.frame(minHeight: 44)
                    }
                }
                if settings.accounts.count > 1 {
                    Section {
                        DisclosureGroup("恢复旧版保存的登录") {
                            ForEach(settings.accounts) { account in
                                Button {
                                    perform { try await model.selectAccount(account.id, installation: installation); try await load() }
                                } label: {
                                    HStack {
                                        Text(account.id == "guest" ? "默认网站会话" : account.name)
                                        Spacer()
                                        if account.id == settings.selectedID { Image(systemName: "checkmark") }
                                    }.frame(minHeight: 44)
                                }
                            }
                        }
                    } footer: { Text("保留旧版登录记录及其书源选项，方便恢复；所有旧书架内容已统一显示，切换记录不会隐藏书籍。") }
                }
            } else { Section { ProgressView("正在载入网站登录…") } }
            if busy { Section { ProgressView("正在处理…") } }
            if let feedback { Section { Text(feedback).font(.footnote) } }
        }
        .disabled(busy)
        .navigationTitle("网站登录").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task(id: installation.digest + ":" + accountID) {
            do { try await load() }
            catch is CancellationError { }
            catch { if !Task.isCancelled { feedback = error.localizedDescription } }
        }
        .sheet(item: $login, onDismiss: refresh) { request in NativeSourceLoginView(model: model, request: request) }
        .sheet(item: $token, onDismiss: refresh) { request in
            NativeSourceTokenView(model: model, request: request, hasToken: status?.bearerOrigins.contains(request.origin) == true)
        }
        .confirmationDialog("清除此书源已保存的登录凭据？", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), titleVisibility: .visible) {
            if let clearing {
                Button("清除登录凭据", role: .destructive) {
                    self.clearing = nil
                    perform { try await model.clearLogin(context: clearing); try await load(); feedback = "登录凭据已清除" }
                }
            }
            Button("取消", role: .cancel) { clearing = nil }
        } message: { Text("正在使用旧登录状态的操作将失效。此操作只清除本机凭据，不会注销网站账号。") }
    }
    private func load() async throws {
        let source = installation
        let next = try await model.services().0.accountSettings(installationID: source.id)
        let status = try await model.credentials.status(scope: .init(installationID: source.id, accountID: next.selectedID))
        try Task.checkCancellation()
        guard try await model.services().0.accountSettings(installationID: source.id).selectedID == next.selectedID else { return }
        try Task.checkCancellation()
        presentation.settings = next; presentation.status = status
        if !origins.contains(selectedOrigin) { selectedOrigin = origins.first ?? "" }
    }
    private func prepareLogin(isToken: Bool) {
        guard let settings, origins.contains(selectedOrigin) else { return }
        let origin = selectedOrigin, installation = installation
        perform {
            let context = try await model.credentialContext(installation, accountID: settings.selectedID)
            let webRequest = isToken ? nil : try model.websiteLoginRequest(installation, fallbackOrigin: origin)
            let request = NativeSourceLoginRequest(context: context, origin: webRequest?.url.flatMap(SourceHostHTTPPolicy.origin) ?? origin, webRequest: webRequest)
            if isToken { token = request } else { login = request }
        }
    }
    private func refresh() { perform { try await load() } }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; feedback = nil
        Task {
            defer { busy = false }
            do { try await operation() }
            catch { feedback = error.localizedDescription }
        }
    }
}

private struct NativeSourceTokenView: View {
    @ObservedObject var model: NativeSourceLibrary
    let request: NativeSourceLoginRequest
    let hasToken: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var busy = false
    @State private var feedback: String?
    @State private var discarding = false
    @State private var removing = false
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.origin).font(.footnote).textSelection(.enabled)
                    SecureField("访问令牌", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused).privacySensitive().frame(minHeight: 44)
                } header: { Text("Bearer 访问令牌") } footer: {
                    Text("仅用于支持此登录方式的网站。直接粘贴令牌内容，无需填写 Bearer 前缀。保存后会替换此网站已有的令牌。")
                }
                if hasToken {
                    Section { Button("移除此网站的令牌", role: .destructive) { removing = true }.frame(minHeight: 44) }
                }
                if let feedback { Section { Text(feedback).font(.footnote) } }
            }
            .disabled(busy).scrollDismissesKeyboard(.interactively)
            .navigationTitle("访问令牌").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if token.isEmpty { dismiss() } else { discarding = true } }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(token) }.disabled(busy || token.isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { focused = false } }
            }
            .interactiveDismissDisabled(busy || !token.isEmpty)
            .confirmationDialog("放弃尚未保存的令牌？", isPresented: $discarding, titleVisibility: .visible) {
                Button("放弃", role: .destructive) { token = ""; dismiss() }
                Button("继续输入", role: .cancel) { }
            }
            .confirmationDialog("移除此网站已保存的令牌？", isPresented: $removing, titleVisibility: .visible) {
                Button("移除令牌", role: .destructive) { save(nil) }
                Button("取消", role: .cancel) { }
            }
            .onDisappear { token = "" }
        }
    }
    private func save(_ value: String?) {
        focused = false; busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                try await model.saveBearer(value, origin: request.origin, context: request.context)
                token = ""; dismiss()
            } catch { feedback = error.localizedDescription }
        }
    }
}
