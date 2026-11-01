import Foundation
import Testing
@testable import LegadoCore

/// 书源 Cookie 的持久化回归测试。
///
/// 背景：`SourceNetworkPolicy` 是 actor，`cookies` 原先只是内存字典，
/// 进程重建后直接归零，用户看到的是「每次更新书源 Cookie 就丢」。
/// 这三条用例分别钉住：重建实例后仍可读、清空时内存与磁盘一起清、
/// 以及合并写入不会覆盖磁盘上的其它会话。
struct SourceCookiePersistenceTests {

    private func makeCache() -> PersistentRuntimeCache {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legado-cookie-\(UUID().uuidString).sqlite")
        return PersistentRuntimeCache(url: url)
    }

    @Test func cookiesSurvivePolicyRecreation() async {
        let cache = makeCache()
        let target = URL(string: "https://persist.test/chapter/1")!
        let policy = SourceNetworkPolicy(persistent: cache)
        await policy.setCookieHeader("session=abc; Path=/", sourceID: "src-1", url: target)

        let before = await policy.cookieHeader(sourceID: "src-1", url: target)
        #expect(before.contains("session=abc"))

        // 关键断言：换一个实例（等价于进程重建）后仍读得到。
        let recreated = SourceNetworkPolicy(persistent: cache)
        let after = await recreated.cookieHeader(sourceID: "src-1", url: target)
        #expect(after.contains("session=abc"))
    }

    @Test func clearingCookiesAlsoClearsPersistedCopy() async {
        let cache = makeCache()
        let target = URL(string: "https://persist.test/chapter/1")!
        let policy = SourceNetworkPolicy(persistent: cache)
        await policy.setCookieHeader("session=abc; Path=/", sourceID: "src-1", url: target)
        await policy.removeCookies(sourceID: "src-1")

        let cleared = await policy.cookieHeader(sourceID: "src-1", url: target)
        #expect(cleared.isEmpty)

        // 只清内存而不清磁盘时，这里会把刚删掉的会话读回来。
        let recreated = SourceNetworkPolicy(persistent: cache)
        let restored = await recreated.cookieHeader(sourceID: "src-1", url: target)
        #expect(restored.isEmpty)
    }

    @Test func mergingOneCookieKeepsEarlierOnes() async {
        let cache = makeCache()
        let target = URL(string: "https://persist.test/chapter/1")!
        let policy = SourceNetworkPolicy(persistent: cache)
        await policy.setCookieHeader("first=1; Path=/", sourceID: "src-1", url: target)

        // 新实例先写第二个：若 upsert 不先恢复磁盘值，会把 first=1 覆盖掉。
        let second = SourceNetworkPolicy(persistent: cache)
        await second.setCookieHeader("second=2; Path=/", sourceID: "src-1", url: target)

        let header = await second.cookieHeader(sourceID: "src-1", url: target)
        #expect(header.contains("first=1"))
        #expect(header.contains("second=2"))
    }
}
