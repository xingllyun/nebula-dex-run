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
