import CommonCrypto
import CryptoKit
import Foundation

/// 宿主加密与编码桥：把 Swift 原生实现暴露给 QuickJS 宿主函数层。
///
/// 这里刻意全部用 `Data` 进出、由调用方负责 JS 数组 ↔ `Data` 的转换，
/// 原因是 `Java byte[]` 的有符号语义只在 `JavaScriptByteCoding` 一处收口；
/// 加密层再碰一次符号问题，就会让「负数字节」这条老坑重新出现。
enum JavaScriptCryptoBridge {

    /// AES/CBC/PKCS5Padding。`operation` 沿用 Rhino 侧
    /// `Cipher.ENCRYPT_MODE == 1` / `DECRYPT_MODE == 2` 的取值，
    /// 内部再显式映射成 CommonCrypto 的 `kCCEncrypt` / `kCCDecrypt`。
    ///
    /// 失败一律返回 `nil`，由宿主函数层转成 JS 异常——
    /// 迁移指南明确要求禁止把异常静默转换成 `null`。
    static func aesCBC(operation: Int32, key: Data, iv: Data, input: Data, limit: Int) -> Data? {
        // ⚠️ 这里的 `operation` 是 **Java/Rhino 语义**：`Cipher.ENCRYPT_MODE == 1`、
        // `Cipher.DECRYPT_MODE == 2`；而 CommonCrypto 是 `kCCEncrypt == 0`、
        // `kCCDecrypt == 1`。三者取值不同，必须显式映射，不能直接透传。
        //
        // CI 三轮 signal 11 的真正根因就在这里（不是缓冲区写法）：
        // 旧代码用 `UInt32(bitPattern: operation)` 把 2（DECRYPT_MODE）直接
        // 交给 CCCrypt，而 2 不是合法的 `CCOperation`，libcommonCrypto 内部
        // 拿不到对应的实现表，随后解引用空指针，崩在 `ldr x24, [x23, #8]`、
        // 地址 `0x8`——所以三轮改写缓冲区只是让崩溃行号跟着调用点平移。
        let ccOperation: CCOperation
        switch operation {
        case 1: ccOperation = CCOperation(kCCEncrypt)
        case 2: ccOperation = CCOperation(kCCDecrypt)
        default: return nil
        }
        guard [16, 24, 32].contains(key.count),
              iv.count == kCCBlockSizeAES128,
              input.count <= limit else { return nil }
        let inputCount = input.count
        let capacity = inputCount + kCCBlockSizeAES128

        // 零嵌套闭包：所有缓冲区都是显式分配的真实内存，CCCrypt 只在最外层被调用一次。
        //
        // 前两轮 CI 的教训写在这里，避免第三次重犯：
        //   * 第一版把 `&output` / `&written` 写在三层 `withUnsafeBytes` 内部，
        //     等于对闭包捕获变量做 inout→指针转换；
        //   * 第二版把 inout 提到顶层，但那五层嵌套闭包本身还在。
        // 两次都在 `CCCrypt` 那一行炸 `Bad pointer dereference at 0x8`（signal 11），
        // 只是行号从 28 平移到 42——故障点跟着调用点走，说明问题不在缓冲区怎么传，
        // 而在「嵌套闭包 + reabstraction thunk」这条调用链上。所以这次一个闭包都不留。
        let keyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: key.count)
        keyBuffer.initialize(repeating: 0, count: key.count)
        defer {
            keyBuffer.deinitialize(count: key.count)
            keyBuffer.deallocate()
        }
        key.copyBytes(to: keyBuffer, count: key.count)

        let ivBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: kCCBlockSizeAES128)
        ivBuffer.initialize(repeating: 0, count: kCCBlockSizeAES128)
        defer {
            ivBuffer.deinitialize(count: kCCBlockSizeAES128)
            ivBuffer.deallocate()
        }
        iv.copyBytes(to: ivBuffer, count: kCCBlockSizeAES128)

        // 空输入的 `baseAddress` 是 nil，而 CCCrypt 对「nil dataIn + 0 长度」的处理
        // 在不同 SDK 上并不一致；分配 1 字节占位，但 dataInLength 仍按真实长度传。
        let inputCapacity = max(inputCount, 1)
        let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        inputBuffer.initialize(repeating: 0, count: inputCapacity)
        defer {
            inputBuffer.deinitialize(count: inputCapacity)
            inputBuffer.deallocate()
        }
        if inputCount > 0 { input.copyBytes(to: inputBuffer, count: inputCount) }

        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        outputBuffer.initialize(repeating: 0, count: capacity)
        defer {
            outputBuffer.deinitialize(count: capacity)
            outputBuffer.deallocate()
        }

        var written = 0
        let status = CCCrypt(
            ccOperation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            keyBuffer,
            key.count,
            ivBuffer,
            inputBuffer,
            inputCount,
            outputBuffer,
            capacity,
            &written
        )
        guard status == kCCSuccess, written >= 0, written <= capacity else { return nil }
        return Data(bytes: outputBuffer, count: written)
    }

    static func base64Encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    static func base64Decode(_ text: String) -> Data? {
        Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 大小写由调用方决定：`java.hexEncodeToString` 用小写，
    /// `DatatypeConverter.printHexBinary` 用大写，两处行为不同，不能合并成一个格式。
    static func hexEncode(_ data: Data, uppercase: Bool) -> String {
        data.map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined()
    }

    /// 奇数字符或非法十六进制返回空 `Data`（与既有 `hexBytes` 行为一致）。
    static func hexDecode(_ text: String) -> Data {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard characters.count.isMultiple(of: 2) else { return Data() }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let value = UInt8(String(characters[index ... index + 1]), radix: 16) else {
                return Data()
            }
            bytes.append(value)
        }
        return Data(bytes)
    }

    static func hmacSHA1(key: Data, message: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 与 Legado / Rhino 侧 form 编码一致：空格变 `+`，保留 `A-Za-z0-9-._*`，
    /// 其余按 UTF-8 逐字节百分号编码。
    static func formURLEncode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
        return value.unicodeScalars.map { scalar in
            if scalar == " " { return "+" }
            if scalar.isASCII, allowed.contains(scalar) { return String(scalar) }
            return String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
        }.joined()
    }
}
