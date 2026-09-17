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

#if canImport(ActivityKit)
import ActivityKit
#endif

/// Live Activity 桥接：把软运行时的前台任务状态同步到锁屏/灵动岛
public final class SDRLiveActivityBridge {

    public struct Payload: Codable, Hashable {
        public var packageName: String
        public var label: String
        public var phase: String
        public var detail: String
        public var updatedAt: Date
    }

    public private(set) var current: Payload?
    private let queue = DispatchQueue(label: "com.xingyun.NebulaDex.liveactivity")

    public init() {}

    public func update(packageName: String, label: String, phase: String, detail: String) {
        let payload = Payload(packageName: packageName, label: label, phase: phase,
                              detail: detail, updatedAt: Date())
        queue.sync { current = payload }
        SDRLogger.i("live", "活动更新：\(label) / \(phase)")
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            // ActivityKit 真实更新逻辑在 app 目标内实现，此处仅做状态缓存与广播
        }
        #endif
        SDREventBus.shared.emit("live.activity.updated", payload: payload)
    }

    public func end(packageName: String) {
        queue.sync {
            if current?.packageName == packageName { current = nil }
        }
        SDRLogger.i("live", "活动结束：\(packageName)")
    }
}
