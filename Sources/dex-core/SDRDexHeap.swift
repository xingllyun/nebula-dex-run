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

/// DEX 解释器托管堆：数组 / 实例 / 字符串 / 类引用。
///
/// 句柄统一编码为 `tag << 28 | index`：tag 与 index 均落在 32 位以内，
/// 保证句柄经 DEX 32 位寄存器（wr32/rd32 走 Int32 截断）传递时高位不丢失。
/// 0 表示 null。宽字段与宽数组元素统一以 Int64 存放，高 32 位按 DEX 语义截断。
public final class SDRDexHeap {

    public struct ArrayObject {
        public var descriptor: String
        public var length: Int
        public var slots: [Int64]
    }

    public struct InstanceObject {
        public var descriptor: String
        public var fields: [String: Int64]
    }

    public private(set) var arrays: [ArrayObject] = []
    public private(set) var instances: [InstanceObject] = []
    public private(set) var stringPool: [String] = []

    public static let tagMask: Int64 = 0xF << 28
    public static let arrayTag: Int64 = 1 << 28
    public static let instanceTag: Int64 = 2 << 28
    public static let stringTag: Int64 = 3 << 28
    public static let classTag: Int64 = 4 << 28

    public init() {}

    // MARK: - 分配

    public func newArray(descriptor: String, length: Int) -> Int64 {
        let n = max(0, length)
        arrays.append(ArrayObject(descriptor: descriptor, length: n,
                                  slots: [Int64](repeating: 0, count: n)))
        return SDRDexHeap.arrayTag | Int64(arrays.count - 1)
    }

    public func newInstance(descriptor: String) -> Int64 {
        instances.append(InstanceObject(descriptor: descriptor, fields: [:]))
        return SDRDexHeap.instanceTag | Int64(instances.count - 1)
    }

    /// 字符串常量入堆；相同内容复用同一句柄，便于引用相等比较
    public func newString(_ value: String) -> Int64 {
        if let i = stringPool.firstIndex(of: value) { return SDRDexHeap.stringTag | Int64(i) }
        stringPool.append(value)
        return SDRDexHeap.stringTag | Int64(stringPool.count - 1)
    }

    public func string(at handle: Int64) -> String? {
        guard handle & SDRDexHeap.tagMask == SDRDexHeap.stringTag else { return nil }
        let i = Int(handle & ~SDRDexHeap.tagMask)
        guard i >= 0 && i < stringPool.count else { return nil }
        return stringPool[i]
    }

    // MARK: - 数组

    public func arrayLength(_ handle: Int64) -> Int {
        guard let obj = arrays[safe: index(of: handle, tag: SDRDexHeap.arrayTag)] else { return 0 }
        return obj.length
    }

    public func element(_ handle: Int64, _ index: Int) -> Int64 {
        guard let obj = arrays[safe: self.index(of: handle, tag: SDRDexHeap.arrayTag)],
              index >= 0, index < obj.length else { return 0 }
        return obj.slots[index]
    }

    public func setElement(_ handle: Int64, _ index: Int, _ value: Int64) {
        let i = self.index(of: handle, tag: SDRDexHeap.arrayTag)
        guard i >= 0 && i < arrays.count, index >= 0, index < arrays[i].length else { return }
        arrays[i].slots[index] = value
    }

    // MARK: - 实例字段

    public func instanceDescriptor(_ handle: Int64) -> String? {
        guard let obj = instances[safe: index(of: handle, tag: SDRDexHeap.instanceTag)] else { return nil }
        return obj.descriptor
    }

    public func field(_ handle: Int64, _ key: String) -> Int64 {
        guard let obj = instances[safe: index(of: handle, tag: SDRDexHeap.instanceTag)] else { return 0 }
        return obj.fields[key] ?? 0
    }

    public func setField(_ handle: Int64, _ key: String, _ value: Int64) {
        let i = index(of: handle, tag: SDRDexHeap.instanceTag)
        guard i >= 0 && i < instances.count else { return }
        instances[i].fields[key] = value
    }

    /// instance-of 的简化判定：同描述符、目标为 java.lang.Object 或其数组形态视为成立。
    /// 完整类层次（含接口）在阶段四引入 Java 运行时时补齐。
    public func isInstance(_ handle: Int64, of target: String) -> Bool {
        if handle == 0 { return false }
        if target == "Ljava/lang/Object;" { return true }
        if let d = instanceDescriptor(handle) { return d == target }
        if handle & SDRDexHeap.tagMask == SDRDexHeap.arrayTag {
            return target.hasPrefix("[")
        }
        if handle & SDRDexHeap.tagMask == SDRDexHeap.stringTag {
            return target == "Ljava/lang/String;"
        }
        return false
    }

    // MARK: - 内部

    private func index(of handle: Int64, tag: Int64) -> Int {
        guard handle & SDRDexHeap.tagMask == tag else { return -1 }
        return Int(handle & ~SDRDexHeap.tagMask)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        (index >= 0 && index < count) ? self[index] : nil
    }
}
