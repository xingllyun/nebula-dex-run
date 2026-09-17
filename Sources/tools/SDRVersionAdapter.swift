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
import UIKit

/// 系统版本与能力适配层：iOS 26 机型适配与未来版本扩展集中在此
public enum SDRVersionAdapter {
    public static var systemVersion: String { UIDevice.current.systemVersion }

    public static var versionComponents: [Int] {
        systemVersion.split(separator: ".").map { Int($0) ?? 0 }
    }

    public static var majorVersion: Int {
        versionComponents.first ?? 16
    }

    public static var minorVersion: Int {
        versionComponents.count > 1 ? versionComponents[1] : 0
    }

    /// 当前是否 iOS 26 系列（目标机型）
    public static var isIOS26Family: Bool { majorVersion == 26 }
    public static var isIOS26OrLater: Bool { majorVersion >= 26 }
    public static var isIOS27OrLater: Bool { majorVersion >= 27 }

    /// 语义化版本比较，避免仅比较主版本号带来的误判（如 26.2 / 26.4）
    public static func isAtLeast(major: Int, minor: Int = 0) -> Bool {
        if majorVersion != major {
            return majorVersion > major
        }
        return minorVersion >= minor
    }

    /// iOS 26 起系统默认采用 Liquid Glass 新外观；
    /// 仅当 Info.plist 显式声明兼容模式（UIDesignRequiresCompatibility = YES）时才退回旧外观。
    public static var prefersLegacyDesign: Bool {
        return (Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") as? Bool) ?? false
    }

    /// 是否已采用 iOS 26 的 Liquid Glass 外观
    public static var usesLiquidGlassDesign: Bool {
        guard #available(iOS 26.0, *) else {
            return false
        }
        return !prefersLegacyDesign
    }

    /// 是否可直接使用 iOS 26 的玻璃材质 API
    public static var supportsGlassEffectAPI: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    /// 是否支持 iOS 26 的 BGContinuedProcessingTask
    public static var supportsContinuedProcessing: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    /// 是否支持 ProMotion（120Hz）
    public static var supportsProMotion: Bool {
        UIScreen.main.maximumFramesPerSecond > 60
    }

    public static func availableRefreshRates() -> [Int] {
        supportsProMotion ? [30, 60, 120] : [30, 60]
    }

    /// 设备物理内存档位（大内存 entitlement 的实际收益随档位不同）
    public static var deviceMemoryTierLabel: String {
        let physical = ProcessInfo.processInfo.physicalMemory
        if physical <= 4 * 1073741824 {
            return "4 GB 及以下（开启大内存也不提升上限）"
        }
        if physical <= 6 * 1073741824 {
            return "6 GB（开启后约可到 4.5 GB）"
        }
        if physical <= 8 * 1073741824 {
            return "8 GB（开启后约可到 6 GB）"
        }
        return "8 GB 以上"
    }
}
