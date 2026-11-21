import DSCore
import Foundation
import JavaScriptCore

extension PluginRuntime {
    /// AUD-13：使用固定串行队列池执行 JS；超时立即返回错误给调用方，但槽位仅在执行块真正退出后释放
    internal func evaluateInSandbox(
        scriptBody: String,
        fixedOwnerID: String?,
        allowNetwork: Bool,
        timeoutSeconds: TimeInterval,
        command: SandboxCommand
    ) async throws -> String {
        let lease = try await pool.acquireLease()
        let prelude = preludeScript
        let client = httpClient
        let vault = cookieVault
        let root = cacheRoot
        let logStore = logger
        let wvService = webViewService
        let slotPool = pool
        let snapshotMeta = registeredScripts.mapValues(\.meta)
        let cancelToken = SandboxCancellationToken()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let gate = OneShotTimeoutGate(cont)
                let timeoutTask = Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(for: .seconds(timeoutSeconds))
                    guard !Task.isCancelled else { return }
                    gate.resume(throwing: PluginSecurityError.timeout(seconds: timeoutSeconds))
                    cancelToken.cancel()
                }
                cancelToken.onCancel {
                    timeoutTask.cancel()
                    gate.resume(throwing: CancellationError())
                }
                lease.queue.async {
                    defer {
                        timeoutTask.cancel()
                        Task { await slotPool.releaseLease(lease) }
                    }
                    guard !cancelToken.isCancelled else {
                        gate.resume(throwing: CancellationError())
                        return
                    }
                    guard let ctx = JSContext() else {
                        gate.resume(throwing: PluginSecurityError.scriptError("无法创建 JSContext"))
                        return
                    }
                    var jsException: String?
                    ctx.exceptionHandler = { _, exc in jsException = exc?.toString() }
                    let factory = HostBridgeFactoryJS(
                        fixedOwnerID: fixedOwnerID,
                        policyProvider: { owner in
                            if !allowNetwork {
                                return SourcePermissionPolicy(ownerID: owner, allowNetwork: false)
                            }
                            if let meta = snapshotMeta[owner] {
                                return SourcePermissionPolicy(
                                    ownerID: owner,
                                    isBuiltinParser: false,
                                    permissionMode: meta.permissionMode,
                                    declaredHosts: meta.declaredHosts,
                                    allowNetwork: true
                                )
                            }
                            return SourcePermissionPolicy(ownerID: owner, permissionMode: .declaredHosts, declaredHosts: [], allowNetwork: true)
                        },
                        httpClient: client,
                        cookieVault: vault,
                        cacheRoot: root,
                        logger: logStore,
                        webViewService: wvService,
                        cancellationToken: cancelToken
                    )
                    ctx.setObject(factory, forKeyedSubscript: "__bridge" as NSString)
                    ctx.evaluateScript(prelude)
                    // AUD-13：prelude 已在局部闭包捕获 __bridge，在执行用户脚本前即删除全局 __bridge
                    ctx.evaluateScript("delete this.__bridge;")
                    ctx.evaluateScript(scriptBody)
                    ctx.evaluateScript("for (var __k in this) { if (__k.indexOf('__n_') === 0) { delete this[__k]; } }")

                    if cancelToken.isCancelled {
                        gate.resume(throwing: CancellationError())
                        return
                    }
                    if let err = jsException {
                        gate.resume(throwing: PluginSecurityError.scriptError(err))
                        return
                    }
                    let output: String
                    switch command {
                    case .meta:
                        output = Self.jsStringValue(ctx.objectForKeyedSubscript("__meta")?.call(withArguments: []), default: "[]")
                    case .invoke(let method, let argsJSON):
                        if let owner = fixedOwnerID,
                           let invokeById = ctx.objectForKeyedSubscript("__invokeById"),
                           !invokeById.isUndefined {
                            output = Self.jsStringValue(invokeById.call(withArguments: [owner, method, argsJSON]))
                        } else if let invoke = ctx.objectForKeyedSubscript("__invoke"), !invoke.isUndefined {
                            output = Self.jsStringValue(invoke.call(withArguments: [0, method, argsJSON]))
                        } else {
                            output = ""
                        }
                    }
                    if cancelToken.isCancelled {
                        gate.resume(throwing: CancellationError())
                        return
                    }
                    if let err = jsException {
                        gate.resume(throwing: PluginSecurityError.scriptError(err))
                        return
                    }
                    gate.resume(returning: output)
                }
            }
        } onCancel: {
            cancelToken.cancel()
        }
    }

    internal static func jsStringValue(_ val: JSValue?, default fallback: String = "") -> String {
        guard let val, !val.isNull, !val.isUndefined else { return fallback }
        return val.toString() ?? fallback
    }

    internal static func decodeMetaList(_ json: String) -> [SourceMetaDTO] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { dict in
            guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
            let hosts = (dict["hosts"] as? [String]) ?? []
            let methods = (dict["methods"] as? [String]) ?? []
            let mode: SourcePermissionMode = hosts.isEmpty ? .compatApproved : .declaredHosts
            return SourceMetaDTO(
                id: id,
                name: name,
                version: (dict["version"] as? String) ?? "1.0.0",
                author: (dict["author"] as? String) ?? "",
                summary: (dict["description"] as? String) ?? (dict["summary"] as? String) ?? "",
                declaredHosts: hosts,
                permissionMode: mode,
                methods: methods,
                loginURL: dict["loginUrl"] as? String
            )
        }
    }

    internal static func encodeJSON(_ array: [Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: array)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
