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
    func markInitialized() { initialized = true }
}

/// SO 装载：解析 ELF → 建立软件镜像 → 重定位 → 注册 JNI
public final class SDRImageLoader {

    public init() {}

    public func load(bytes: [UInt8], path: String, preferredABI: String?) throws -> SDRLoadedImage {
        let header = try SDRElfParser.parse(bytes)

        if let want = preferredABI, !want.isEmpty, header.abiName != want {
            SDRLogger.w("native", "ABI 不一致，尝试继续解释执行")
        }

        let memory = SDRMemoryGuard()
        let base: UInt64 = 0x1_0000_0000
        var textLo = UInt64.max
        var textHi: UInt64 = 0
        var dataLo = UInt64.max
        var dataHi: UInt64 = 0

        for ph in header.programHeaders where ph.isLoad {
            guard ph.memsz >= ph.filesz else {
                throw SDRAppError(.soImageInvalid, "段尺寸非法：memsz < filesz")
            }
            let vaddr = base + ph.vaddr
            memory.map(name: "seg@\(String(vaddr, radix: 16))",
                       base: vaddr, size: ph.memsz,
                       readable: true,
                       writable: ph.writable,
                       executable: false)

            let fileEnd = Int(ph.offset + ph.filesz)
            if fileEnd <= bytes.count, ph.filesz > 0 {
                let payload = Array(bytes[Int(ph.offset)..<fileEnd])
                try memory.write(vaddr, bytes: payload)
            }

            if ph.executable {
                textLo = min(textLo, vaddr); textHi = max(textHi, vaddr + ph.memsz)
            } else if ph.writable {
                dataLo = min(dataLo, vaddr); dataHi = max(dataHi, vaddr + ph.memsz)
            }
        }

        let image = SDRLoadedImage(path: path, header: header, memory: memory, loadBase: base,
                                   textRange: (textLo == UInt64.max ? 0..<0 : textLo..<textHi),
                                   dataRange: (dataLo == UInt64.max ? 0..<0 : dataLo..<dataHi))

        try SDRRelocator.apply(image: image, originalBytes: bytes)
        registerJNISymbols(image: image)
        image.markInitialized()

        SDRLogger.i("native", "SO 镜像装载完成：\(path) abi=\(header.abiName)")
        return image
    }

    /// 从 .dynsym 提取 JNI 导出（Java_* 与 JNI_OnLoad）
    private func registerJNISymbols(image: SDRLoadedImage) {
        // TODO: 完整解析 .dynsym/.dynstr 后按符号值登记；当前以入口占位
        image.recordJNI(symbol: "JNI_OnLoad", address: image.loadBase + image.header.entry)
        SDRLogger.d("native", "JNI 导出登记：JNI_OnLoad")
    }
}
