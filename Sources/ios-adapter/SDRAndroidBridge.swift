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

/// 软件侧 Android 桥：把 Java 层调用翻译为解释器入口
public final class SDRAndroidBridge {

    public static let shared = SDRAndroidBridge()

    private var images: [String: SDRLoadedImage] = [:]
    private var interpreters: [String: SDRArmInterpreter] = [:]
    private let queue = DispatchQueue(label: "com.xingyun.NebulaDex.bridge")

    private init() {}

    public func register(image: SDRLoadedImage, interpreter: SDRArmInterpreter) {
        queue.sync {
            images[image.path] = image
            interpreters[image.path] = interpreter
        }
    }

    public func callStatic(soPath: String, symbol: String, args: [UInt64]) throws -> UInt64 {
        let snapshot = queue.sync { (images[soPath], interpreters[soPath]) }
        guard let image = snapshot.0, let interp = snapshot.1 else {
            throw SDRAppError(.soSymbolMissing, "未装载的 SO：\(soPath)")
        }
        guard let entry = image.jniExports[symbol] ?? (symbol == "JNI_OnLoad" ? image.loadBase + image.header.entry : nil) else {
            throw SDRAppError(.soSymbolMissing, "符号未找到：\(symbol)")
        }
        SDRLogger.i("bridge", "调用 \(symbol) @0x\(String(entry, radix: 16))")
        return try interp.run(entry: entry, args: args)
    }

    public func callJNIOnLoad(soPath: String, vmPointer: UInt64) throws -> UInt64 {
        try callStatic(soPath: soPath, symbol: "JNI_OnLoad", args: [vmPointer, 0])
    }

    public func unload(soPath: String) {
        queue.sync {
            images.removeValue(forKey: soPath)
            interpreters.removeValue(forKey: soPath)
        }
    }

    public func loadedPaths() -> [String] {
        queue.sync { Array(images.keys) }
    }
}
