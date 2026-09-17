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
