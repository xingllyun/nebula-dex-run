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

/// DEX 启动入口点：launch() 串联「DEX 加载 → 类解析 → 入口方法定位 → 解释执行」的产物。
public struct SDRDexEntryPoint {
    /// 入口方法所属类描述符（"Lcls;"）
    public var classDescriptor: String
    /// 入口方法完整签名（"Lcls;->name(proto)ret"）
    public var methodSignature: String
    /// 入口方法在 method_ids 中的下标
    public var methodIndex: UInt32
    /// 入口执行前需先完成的类初始化方法（<clinit>）下标
    public var classInitializers: [UInt32]
    /// 入口是否接收 String[]（main([Ljava/lang/String;)V 由宿主注入空串数组）
    public var usesStringArrayArgument: Bool
}

/// 入口方法定位：按可用性降级挑选，保证「装载即可执行」的最小闭环。
public enum SDRDexLaunchPlan {

    /// main 方法的参数描述符
    public static let mainProto = "([Ljava/lang/String;)V"

    /// String[] 描述符（宿主注入空数组时使用）
    public static let stringArrayDescriptor = "[Ljava/lang/String;"

    /// 选择入口方法：
    /// 1. `main([Ljava/lang/String;)V`（标准 Java 入口）
    /// 2. 任意类的 `<clinit>`（无 main 时以类初始化验证链路）
    /// 3. 任意含方法体的普通方法（排除 `<init>` / `<clinit>`）
    public static func select(file: SDRDexFile) -> SDRDexEntryPoint? {
        var main: (String, UInt32)?
        var clinit: (String, UInt32)?
        var fallback: (String, UInt32)?

        for def in file.classDefs {
            let descriptor = file.typeDescriptor(at: def.classIdx)
            let methods = file.methods(ofClass: descriptor)
            for method in methods where method.codeOff != 0 {
                let parts = file.methodParts(at: method.methodIdx)
                if parts.name == "main", parts.proto == mainProto, main == nil {
                    main = (descriptor, method.methodIdx)
                }
                if parts.name == "<clinit>", clinit == nil {
                    clinit = (descriptor, method.methodIdx)
                }
                if parts.name != "<init>", parts.name != "<clinit>", fallback == nil {
                    fallback = (descriptor, method.methodIdx)
                }
            }
        }

        guard let entry = main ?? clinit ?? fallback else { return nil }

        // 入口执行前先跑类初始化；入口自身就是 <clinit> 时不重复执行
        var initializers: [UInt32] = []
        if let initMethod = clinit, initMethod.1 != entry.1 { initializers.append(initMethod.1) }

        var isMain = false
        if let mainEntry = main, mainEntry.1 == entry.1 { isMain = true }

        return SDRDexEntryPoint(classDescriptor: entry.0,
                                methodSignature: file.methodSignature(at: entry.1),
                                methodIndex: entry.1,
                                classInitializers: initializers,
                                usesStringArrayArgument: isMain)
    }

    /// 指定类的 `<clinit>` 下标（无则 nil），供按类初始化（对拍/多类场景）使用
    public static func initializerIndex(file: SDRDexFile, classDescriptor: String) -> UInt32? {
        let methods = file.methods(ofClass: classDescriptor)
        for method in methods where method.codeOff != 0 {
            if file.methodParts(at: method.methodIdx).name == "<clinit>" { return method.methodIdx }
        }
        return nil
    }
}
