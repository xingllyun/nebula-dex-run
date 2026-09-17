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

/// 加固 / 加壳检测
public enum SDRHardeningDetector {

    public struct Result {
        public var isHardened: Bool
        public var vendor: String?
        public var evidence: [String]
    }

    private static let signatures: [(name: String, markers: [String])] = [
        ("360 加固",  ["libjiagu.so", "libjiagu_art.so", "libjiagu_x86.so"]),
        ("腾讯乐固",  ["libshell.so", "libshella.so", "libtosprotection", "tencent.StubShell"]),
        ("梆梆安全",  ["libDexHelper.so", "libSecShell.so", "libbangcle"]),
        ("爱加密",    ["libexec.so", "libexecmain.so", "ijiami"]),
        ("阿里聚安全", ["libmobisec.so", "aliprotect"]),
        ("娜迦",      ["libchaosvmp.so", "libddog.so", "libfdog.so"]),
        ("网秦",      ["libnqshield.so"]),
        ("顶象",      ["libDingx"]),
    ]

    public static func detect(meta: SDRAPKMeta, archive: SDRZipArchive) -> Result {
        var evidence: [String] = []
        var vendor: String?

        for (name, markers) in signatures {
            for marker in markers {
                let hit = archive.entries.contains {
                    $0.name.lowercased().contains(marker.lowercased())
                }
                if hit {
                    vendor = name
                    evidence.append("命中特征文件：\(marker)")
                    break
                }
            }
            if vendor != nil { break }
        }

        // 附加判断：DEX 数量异常少但体积大、classes.dex 头部特征
        if meta.dexFiles.count == 1, meta.soFiles.isEmpty, !evidence.isEmpty {
            evidence.append("仅单个 DEX 且含加固特征库")
        }

        return Result(isHardened: vendor != nil, vendor: vendor, evidence: evidence)
    }
}
