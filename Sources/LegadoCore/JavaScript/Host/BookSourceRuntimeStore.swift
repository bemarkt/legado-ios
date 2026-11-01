import Foundation

/// 书源运行期变量存储（`source.get/put` 的落点）。
///
/// 它曾经定义在 `JavaScriptRuleEvaluator.swift` 尾部，只因为历史上和 JSC 宿主绑定
/// 住在同一个文件里。evaluator 整文件重写时必须把它独立出来：它与引擎无关，
/// 而现在有 11 处在用它（实体宿主、Java 宿主的 androidId、登录请求头解析）。
///
/// 两层结构缺一不可：
/// - 内存字典：单次执行内的快速读写；
/// - `PersistentRuntimeCache`（SQLite `caches` 表）：跨启动持久化，登录态靠它。
///
/// 键格式必须与旧实现逐字一致（`loginHeader_<sourceID>` / `v_<sourceID>_<key>`）。
/// 改一个字符，老用户已保存的登录态与书源变量就全部读不出来，
/// 书源侧表现为「请重新登录」——这类数据兼容问题比编译错误更难被发现。
public final class BookSourceRuntimeStore: @unchecked Sendable {
    public static let shared = BookSourceRuntimeStore()

    private let lock = NSLock()
    private var values: [String: [String: String]] = [:]
    private let persistent: PersistentRuntimeCache

    public init(persistent: PersistentRuntimeCache = .shared) {
        self.persistent = persistent
    }

    public func get(sourceID: String, key: String) -> String {
        lock.lock()
        if let value = values[sourceID]?[key] {
            lock.unlock()
            return value
        }
        lock.unlock()

        guard let stored = persistent.get(persistentKey(sourceID: sourceID, key: key)) else { return "" }
        // 回填内存：同一次执行里书源常对同一个 key 反复取值，
        // 每次都走 SQLite 会让规则求值出现可观测的卡顿。
        lock.lock()
        values[sourceID, default: [:]][key] = stored
        lock.unlock()
        return stored
    }

    public func put(sourceID: String, key: String, value: String) {
        lock.lock()
        values[sourceID, default: [:]][key] = value
        lock.unlock()
        persistent.put(persistentKey(sourceID: sourceID, key: key), value: value)
    }

    /// 登录请求头。存的是 JSON 字符串，取出来要摊平成 `[String: String]`：
    /// 调用方（`BookSourceHeaderResolver` 与 `source.getHeaderMap(true)`）都按字典合并，
    /// 返回 `Any` 会在合并处产生类型不匹配。
    public func loginHeaders(sourceID: String) -> [String: String] {
        let value = get(sourceID: sourceID, key: "loginHeader")
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    private func persistentKey(sourceID: String, key: String) -> String {
        key == "loginHeader" ? "loginHeader_\(sourceID)" : "v_\(sourceID)_\(key)"
    }
}
