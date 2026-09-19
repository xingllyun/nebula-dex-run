/*
Copyright © 2026 星云云络科技 (Xingyun Cloud Tech)
Project: NebulaDex - iOS APK Runtime

Licensed under the MIT License (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://opensource.org/licenses/MIT

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import Foundation

/// 已装载的软件镜像（代码段仅作为数据存在，不申请可执行内存）
public final class SDRLoadedImage {
    public let path: String
    public let header: SDRElfHeader
    public let memory: SDRMemoryGuard
    public let loadBase: UInt64
    public let textRange: Range<UInt64>
    public let dataRange: Range<UInt64>

    public private(set) var jniExports: [String: UInt64] = [:]
    public private(set) var initialized = false
    /// DT_NEEDED 声明的依赖库（供后续依赖树加载使用）
    public private(set) var dependencies: [String] = []
    /// .dynsym 解析出的动态符号
    public private(set) var dynamicSymbols: [SDRElfSymbol] = []
    /// 完整动态段解析结果：依赖装载完成后按此表补绑外部符号
    public private(set) var dynamic: SDRElfDynamicInfo?

    init(path: String, header: SDRElfHeader, memory: SDRMemoryGuard,
         loadBase: UInt64, textRange: Range<UInt64>, dataRange: Range<UInt64>) {
        self.path = path
        self.header = header
        self.memory = memory
        self.loadBase = loadBase
        self.textRange = textRange
        self.dataRange = dataRange
    }

    func recordJNI(symbol: String, address: UInt64) { jniExports[symbol] = address }
    func recordDependencies(_ list: [String]) { dependencies = list }
    func recordDynamicSymbols(_ list: [SDRElfSymbol]) { dynamicSymbols = list }
    func markInitialized() { initialized = true }
}

/// SO 装载：解析 ELF → 建立软件镜像 → 重定位 → 注册 JNI
public final class SDRImageLoader {

    public init() {}

    // MARK: - 装载基址分配

    /// 多库共用一个基址会互相踩踏（后装库覆盖先装库的段），故按固定步长递增分配。
    /// 步长 4 GiB，远大于单库镜像尺寸，保证相邻镜像的段区间不重叠。
    private static let baseLock = NSLock()
    private static var nextBase: UInt64 = 0x1_0000_0000
    private static let baseStride: UInt64 = 0x1_0000_0000

    static func allocateLoadBase() -> UInt64 {
        baseLock.lock()
        defer { baseLock.unlock() }
        let base = nextBase
        nextBase &+= baseStride
        return base
    }

    public func load(bytes: [UInt8], path: String, preferredABI: String?,
                     symbolTable: SDRSharedLibraryTable? = nil) throws -> SDRLoadedImage {
        let header = try SDRElfParser.parse(bytes)

        if let want = preferredABI, !want.isEmpty, header.abiName != want {
            SDRLogger.w("native", "ABI 不一致，尝试继续解释执行")
        }

        let memory = SDRMemoryGuard()
        let base = SDRImageLoader.allocateLoadBase()
        var textLo = UInt64.max
        var textHi: UInt64 = 0
        var dataLo = UInt64.max
        var dataHi: UInt64 = 0

        for ph in header.programHeaders where ph.isLoad {
            guard ph.memsz >= ph.filesz else {
                throw SDRAppError(.soImageInvalid, "段尺寸非法：memsz < filesz")
            }
            let vaddr = base + ph.vaddr
            // 先以可写建段并灌入初始镜像，再按 ELF 声明权限收权：
            // 只读段（.text/.rodata 所在的 R 段）若一开始即不可写，初始字节无从写入，
            // 会让任何含只读 PT_LOAD 的真实 .so 装载即报“非法写”。
            guard memory.map(name: "seg@\(String(vaddr, radix: 16))",
                             base: vaddr, size: ph.memsz,
                             readable: true,
                             writable: true,
                             executable: false) else {
                throw SDRAppError(.soImageInvalid, "段映射失败：vaddr=0x\(String(vaddr, radix: 16)) size=\(ph.memsz)")
            }

            let fileEnd = Int(ph.offset + ph.filesz)
            if fileEnd <= bytes.count, ph.filesz > 0 {
                let payload = Array(bytes[Int(ph.offset)..<fileEnd])
                try memory.write(vaddr, bytes: payload)
            }

            // 收权到真实段权限：此后对只读段的写入会被沙盒拒绝（重定位只允许落在可写段）
            memory.protect(address: vaddr, size: ph.memsz,
                           readable: true, writable: ph.writable, executable: false)

            // 段范围统计：可执行段与可写段各自独立判定，避免 RWX 段被 else 分支漏计
            if ph.executable {
                textLo = min(textLo, vaddr); textHi = max(textHi, vaddr + ph.memsz)
            }
            if ph.writable {
                dataLo = min(dataLo, vaddr); dataHi = max(dataHi, vaddr + ph.memsz)
            }
        }

        let image = SDRLoadedImage(path: path, header: header, memory: memory, loadBase: base,
                                   textRange: (textLo == UInt64.max ? 0..<0 : textLo..<textHi),
                                   dataRange: (dataLo == UInt64.max ? 0..<0 : dataLo..<dataHi))

        let dynamicInfo = SDRElfDynamic.parse(bytes, header: header)
        try SDRRelocator.apply(image: image, dynamic: dynamicInfo, table: symbolTable)
        registerJNISymbols(image: image, dynamic: dynamicInfo)
        image.recordDynamic(dynamicInfo)
        image.recordDependencies(dynamicInfo.needed)
        image.recordDynamicSymbols(dynamicInfo.symbols)
        image.markInitialized()

        SDRLogger.i("native", "SO 镜像装载完成：\(path) abi=\(header.abiName) 符号 \(dynamicInfo.symbols.count) 重定位 \(dynamicInfo.relocations.count) 依赖 \(dynamicInfo.needed.count)")
        return image
    }

    /// 从 .dynsym 提取 JNI 导出（Java_* 与 JNI_OnLoad）：只登记真实定义过的符号
    private func registerJNISymbols(image: SDRLoadedImage, dynamic: SDRElfDynamicInfo) {
        var registered = 0
        for symbol in dynamic.symbols where !symbol.isUndefined && symbol.value != 0 {
            guard symbol.name == "JNI_OnLoad"
                || symbol.name == "JNI_OnUnload"
                || symbol.name.hasPrefix("Java_") else { continue }
            image.recordJNI(symbol: symbol.name, address: image.loadBase + symbol.value)
            registered += 1
        }
        if registered == 0 {
            SDRLogger.w("native", "未在 .dynsym 找到 JNI 导出（符号表 \(dynamic.symbols.count) 项）：\(image.path)")
        } else {
            SDRLogger.d("native", "JNI 导出登记 \(registered) 项：\(image.path)")
        }
    }
}
