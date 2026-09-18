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
import Darwin
import os

/// 侧载证书相关权限的探测结论
public enum SDRCapabilityStatus: String {
    case active
    case inactive
    case unknown

    public var displayName: String {
        switch self {
        case .active:
            return "已生效"
        case .inactive:
            return "未生效"
        case .unknown:
            return "无法判定"
        }
    }
}

/// 设备运行时能力报告（iOS 26 机型适配的基座数据）
public struct SDRDeviceCapabilityReport {
    public var systemVersion: String
    public var machineIdentifier: String
    public var physicalMemoryBytes: UInt64
    public var availableMemoryBytes: UInt64
    public var residentFootprintBytes: UInt64
    public var virtualSizeBytes: UInt64
    public var maxContiguousMapBytes: UInt64
    public var increasedMemoryLimit: SDRCapabilityStatus
    public var extendedVirtualAddressing: SDRCapabilityStatus
    public var probedAt: Date

    public var physicalMemoryDescription: String {
        String(format: "%.1f GB", Double(physicalMemoryBytes) / 1073741824.0)
    }

    public var availableMemoryDescription: String {
        String(format: "%.0f MB", Double(availableMemoryBytes) / 1048576.0)
    }

    public var footprintDescription: String {
        String(format: "%.0f MB", Double(residentFootprintBytes) / 1048576.0)
    }

    public var maxContiguousMapDescription: String {
        if maxContiguousMapBytes == 0 {
            return "未探测"
        }
        return String(format: "%.1f GB", Double(maxContiguousMapBytes) / 1073741824.0)
    }

    public var entitlementSummary: String {
        return "大内存权限 \(increasedMemoryLimit.displayName) / 大地址空间权限 \(extendedVirtualAddressing.displayName)"
    }
}

/// 设备与内存能力探测
///
/// 对应侧载重签（全能签 / 轻松签 / PlumeImpactor + GetMoreRam）注入的两项 entitlement：
///   - com.apple.developer.kernel.increased-memory-limit      提升常驻内存上限（大内存），iOS 15.0+
///   - com.apple.developer.kernel.extended-virtual-addressing 扩展进程虚拟地址空间（大地址空间），iOS 14.0+
///
/// 说明：iOS 未提供“查询本进程是否符合某项 entitlement”的公开接口，本模块采用
/// 可观测指标做启发式判定，结论标为“无法判定”时按最保守档位分配预算。
public enum SDRSystemProbe {
    private static let gigabyte: UInt64 = 1073741824

    public static func report(performAddressProbe: Bool = true) -> SDRDeviceCapabilityReport {
        let physical = ProcessInfo.processInfo.physicalMemory
        let vm = taskVMInfo()
        let available = availableMemoryBytes()
        let maxMap = performAddressProbe ? probeMaxContiguousMap() : 0

        return SDRDeviceCapabilityReport(
            systemVersion: operatingSystemVersion(),
            machineIdentifier: machineIdentifier(),
            physicalMemoryBytes: physical,
            availableMemoryBytes: available,
            residentFootprintBytes: vm.resident,
            virtualSizeBytes: vm.virtualSize,
            maxContiguousMapBytes: maxMap,
            increasedMemoryLimit: statusForIncreasedMemoryLimit(physical: physical, available: available),
            extendedVirtualAddressing: statusForExtendedVirtualAddressing(maxContiguousMap: maxMap),
            probedAt: Date())
    }

    /// os_proc_available_memory()：当前进程在触发内存上限前还可分配的字节数
    /// 说明：该接口为 iOS 专属；非 iOS 平台（如 CI 上的 macOS 命令行测试）退回物理内存的一半作为估计值，
    /// 保证解释器核心可在 macOS 上编译并完成指令级验收。
    public static func availableMemoryBytes() -> UInt64 {
        #if os(iOS)
        return UInt64(os_proc_available_memory())
        #else
        return ProcessInfo.processInfo.physicalMemory / 2
        #endif
    }

    /// task_info(TASK_VM_INFO)：常驻占用与虚拟地址空间用量
    public static func taskVMInfo() -> (resident: UInt64, virtualSize: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (0, 0)
        }
        return (UInt64(info.phys_footprint), UInt64(info.virtual_size))
    }

    /// 逐档尝试 PROT_NONE 匿名映射，探测单块可连续映射的地址空间上限。
    /// 探测只占地址空间、不占物理内存（MAP_NORESERVE），且立即释放，无副作用。
    public static func probeMaxContiguousMap() -> UInt64 {
        let protection = PROT_NONE
        let flags = MAP_PRIVATE | MAP_ANON | MAP_NORESERVE
        var best: UInt64 = 0
        var candidate: UInt64 = 1 * gigabyte
        let ceiling: UInt64 = 64 * gigabyte

        while candidate <= ceiling {
            let pointer = mmap(nil, Int(candidate), protection, flags, -1, 0)
            if pointer == nil || pointer == MAP_FAILED {
                break
            }
            munmap(pointer, Int(candidate))
            best = candidate
            candidate = candidate * 2
        }
        return best
    }

    public static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    public static func operatingSystemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    // MARK: - 判定

    /// 大内存：默认档位约可用物理内存的一半，开启 entitlement 后放宽到约四分之三。
    /// 启动早期 footprint 很小，故用 available / physical 比值做参考判定。
    private static func statusForIncreasedMemoryLimit(physical: UInt64, available: UInt64) -> SDRCapabilityStatus {
        guard physical > 0, available > 0 else {
            return .unknown
        }
        // Apple 文档明确：iPhone 11 及更早（4GB 物理内存）即使开启也不会提升上限
        if physical <= 4 * gigabyte {
            return .unknown
        }
        let ratio = Double(available) / Double(physical)
        if ratio > 0.55 {
            return .active
        }
        if ratio < 0.48 {
            return .inactive
        }
        return .unknown
    }

    /// 大地址空间：单块连续映射稳定超过 16GB 视为已扩展，其余记为无法判定。
    private static func statusForExtendedVirtualAddressing(maxContiguousMap: UInt64) -> SDRCapabilityStatus {
        guard maxContiguousMap > 0 else {
            return .unknown
        }
        if maxContiguousMap >= 16 * gigabyte {
            return .active
        }
        return .unknown
    }
}
