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

/// 内存压力监听：iOS 26 下系统回收更激进，收到压力信号时上层主动收缩缓存
public final class SDRMemoryPressureMonitor {

    public enum Level: String {
        case normal
        case warning
        case critical
    }

    public static let shared = SDRMemoryPressureMonitor()

    public private(set) var level: Level = .normal

    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "com.xingyun.NebulaDex.memorypressure")
    private let lock = NSLock()

    private init() {}

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else {
            return
        }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            guard let strongSelf = self, let activeSource = strongSelf.source else {
                return
            }
            let event = activeSource.data
            let level: Level
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .normal
            }
            strongSelf.update(level)
        }
        source = src
        src.resume()
        SDRLogger.i("memory", "内存压力监听已启动")
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        source?.cancel()
        source = nil
    }

    public var isUnderPressure: Bool {
        return level != .normal
    }

    private func update(_ level: Level) {
        lock.lock()
        self.level = level
        lock.unlock()
        SDRLogger.w("memory", "内存压力等级：\(level.rawValue)")
        SDREventBus.shared.emit("memory.pressure", payload: level.rawValue)
    }
}
