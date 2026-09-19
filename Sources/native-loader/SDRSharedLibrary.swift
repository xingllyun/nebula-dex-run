/*
 Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
 Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
*/

import Foundation

/// 跨模块符号绑定结果
public struct SDRSymbolBinding {
    public let symbol: String
    public let address: UInt64
    public let libraryPath: String

    public init(symbol: String, address: UInt64, libraryPath: String) {
        self.symbol = symbol
        self.address = address
        self.libraryPath = libraryPath
    }
}

/// 共享库注册表：DT_NEEDED 依赖递归装载 + 跨模块符号解析（dlopen/dlsym 语义）
///
/// 设计边界：
/// - 只负责“哪些库已装载、某符号落在哪个镜像的哪个地址”，不做字节读取；
///   字节由调用方通过 resolver 提供（APK 内 lib/arm64-v8a/*.so、沙盒文件等）。
/// - 系统库（libc/liblog/libm/libz/...）由宿主桩提供实现，不参与软件装载，
///   其符号走 SDRLibc 桥接，故此处直接标记为 hostProvided 并跳过。
public final class SDRSharedLibraryTable {

    public static let shared = SDRSharedLibraryTable()

    /// 由宿主桩提供实现的系统库（规范化后名称）
    private static let hostProvided: Set<String> = [
        "libc.so", "libdl.so", "libm.so", "libz.so", "liblog.so", "libandroid.so",
        "libstdc++.so", "libc++_shared.so", "libc++abi.so", "libutils.so", "libcutils.so",
        "libpthread.so", "librt.so", "libnativehelper.so", "libui.so", "libgui.so",
        "ld-android.so", "ld-linux-aarch64.so", "linker64"
    ]

    /// 宿主桩符号的来源标识（非软件镜像）
    public static let hostLibraryPath = "<host>"

    /// 宿主桩桥：符号名 → guest 侧桩地址。
    /// 软件镜像群解析不到的外部符号（libc/libm/liblog 等）由此回落到宿主实现；
    /// 装配方（stub 区映射器）负责把 `SDRHostCall` 的符号索引翻译成 guest 地址。
    /// 未装配时保持 nil：未定义符号槽保留原值，绝不写入伪地址。
    public var hostSymbolResolver: ((String) -> UInt64?)?

    private let lock = NSLock()
    private var order: [SDRLoadedImage] = []
    private var byName: [String: SDRLoadedImage] = [:]
    private var expanding: Set<String> = []

    public init() {}

    // MARK: - 名称规范化

    /// 取 basename 并剥掉版本后缀：/system/lib64/libz.so.1 → libz.so
    public static func normalize(_ raw: String) -> String {
        let name = raw.split(separator: "/").last.map(String.init) ?? raw
        if let range = name.range(of: ".so") {
            return String(name[name.startIndex..<range.upperBound])
        }
        return name
    }

    /// 是否由宿主桩提供（无需软件装载）
    public static func isHostProvided(_ raw: String) -> Bool {
        hostProvided.contains(raw) || hostProvided.contains(normalize(raw))
    }

    // MARK: - 注册与查询

    /// 已装载镜像（按装载顺序）
    public var loadedImages: [SDRLoadedImage] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    public func register(_ image: SDRLoadedImage) {
        lock.lock()
        if byName[Self.normalize(image.path)] == nil {
            order.append(image)
        }
        byName[Self.normalize(image.path)] = image
        byName[image.path] = image
        lock.unlock()
    }

    public func isLoaded(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return byName[Self.normalize(name)] != nil || byName[name] != nil
    }

    public func image(named name: String) -> SDRLoadedImage? {
        lock.lock()
        defer { lock.unlock() }
        return byName[Self.normalize(name)] ?? byName[name]
    }

    /// 镜像声明但尚未装载、且需要软件装载的依赖（宿主桩库与已装载库被过滤）
    public func pendingDependencies(of image: SDRLoadedImage) -> [String] {
        image.dependencies.filter { !Self.isHostProvided($0) && !isLoaded($0) }
    }

    // MARK: - dlopen 语义

    /// 打开（必要时装载）一个共享库，并递归装载其 DT_NEEDED 依赖
    /// - Returns: 已装载镜像；系统桩库或字节缺失时返回 nil（不抛错，交由调用方决定降级策略）
    @discardableResult
    public func open(name: String, loader: SDRImageLoader,
                     resolver: (String) throws -> [UInt8]?) throws -> SDRLoadedImage? {
        let key = Self.normalize(name)
        if let existing = image(named: key) { return existing }
        if Self.isHostProvided(key) {
            SDRLogger.d("dl", "系统库由宿主桩提供，跳过装载：\(key)")
            return nil
        }
        guard let bytes = try resolver(key) else {
            SDRLogger.w("dl", "依赖缺失，无法装载：\(key)")
            return nil
        }

        let image = try loader.load(bytes: bytes, path: key, preferredABI: nil, symbolTable: self)
        register(image)
        try loadDependencies(of: image, loader: loader, resolver: resolver)
        // 依赖就位后补绑此前推迟的外部符号（跨模块解析）
        SDRRelocator.rebind(image: image, table: self)
        return image
    }

    /// 递归装载 DT_NEEDED（深度优先；环依赖与自依赖只装载一次）
    @discardableResult
    public func loadDependencies(of image: SDRLoadedImage, loader: SDRImageLoader,
                                 resolver: (String) throws -> [UInt8]?) throws -> [SDRLoadedImage] {
        var loaded: [SDRLoadedImage] = []
        let key = Self.normalize(image.path)
        lock.lock()
        if expanding.contains(key) {
            lock.unlock()
            return loaded
        }
        expanding.insert(key)
        lock.unlock()

        for needed in image.dependencies {
            let depKey = Self.normalize(needed)
            if Self.isHostProvided(depKey) {
                SDRLogger.d("dl", "依赖由宿主桩提供，跳过软件装载：\(depKey)")
                continue
            }
            if let existing = self.image(named: depKey) {
                loaded.append(existing)
                continue
            }
            do {
                if let dep = try open(name: depKey, loader: loader, resolver: resolver) {
                    loaded.append(dep)
                }
            } catch {
                // 单个依赖失败不阻断主库：保留缺口，其余依赖继续装载
                SDRLogger.w("dl", "依赖装载失败，保留缺口：\(depKey)：\(error)")
            }
        }

        lock.lock()
        expanding.remove(key)
        lock.unlock()
        return loaded
    }

    // MARK: - dlsym 语义

    /// 跨模块符号解析：先发起方镜像自身，再按装载顺序查其它镜像的导出
    public func resolveSymbol(_ raw: String, in image: SDRLoadedImage? = nil) -> SDRSymbolBinding? {
        guard !raw.isEmpty else { return nil }
        if let image = image, let address = Self.export(of: raw, in: image) {
            return SDRSymbolBinding(symbol: raw, address: address, libraryPath: image.path)
        }
        lock.lock()
        let candidates = order
        let hostResolver = hostSymbolResolver
        lock.unlock()
        for candidate in candidates where candidate !== image {
            if let address = Self.export(of: raw, in: candidate) {
                return SDRSymbolBinding(symbol: raw, address: address, libraryPath: candidate.path)
            }
        }
        // 软件镜像群无此符号：回落到宿主桩（libc/libm/liblog 桥）
        if let resolver = hostResolver, let address = resolver(raw) {
            return SDRSymbolBinding(symbol: raw, address: address, libraryPath: Self.hostLibraryPath)
        }
        return nil
    }

    /// 单镜像导出查找：JNI 导出优先，其次 .dynsym 中“已定义且非零”的符号
    public static func export(of name: String, in image: SDRLoadedImage) -> UInt64? {
        if let address = image.jniExports[name] { return address }
        for symbol in image.dynamicSymbols where symbol.name == name {
            if symbol.isUndefined || symbol.value == 0 { continue }
            return image.loadBase &+ symbol.value
        }
        return nil
    }

    // MARK: - 卸载

    /// 释放全部镜像的软件内存并清空注册表
    public func closeAll() {
        lock.lock()
        let images = order
        order.removeAll()
        byName.removeAll()
        expanding.removeAll()
        lock.unlock()
        for image in images {
            image.memory.releaseAll()
        }
    }
}
