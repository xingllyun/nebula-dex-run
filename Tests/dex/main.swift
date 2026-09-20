// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// dex-smoke：Swift 侧 DEX 解释器对拍入口。
// 读取 d8 产出的 classes.dex 与 Tests/dex/cases.json，逐用例执行并输出「签名=值」，
// 与 JVM 原生输出（DexExpect）逐行 diff；任一步骤失败即以非零码退出。
//
// 用法：./dex-smoke <classes.dex> <cases.json>

import Foundation

// MARK: - 用例模型

struct DexSmokeCaseFile: Decodable {
    let cases: [DexSmokeCase]
}

struct DexSmokeCase: Decodable {
    let signature: String
    let args: [DexSmokeArgument]
}

/// 参数形态：整数（int/long 统一按 64 位承载）或 int[]
enum DexSmokeArgument: Decodable {
    case scalar(Int64)
    case intArray([Int64])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .scalar(value)
            return
        }
        let map = try container.decode([String: [Int64]].self)
        guard let values = map["intarray"] else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "不支持的参数形态（仅支持整数或 {\"intarray\": [...]}）")
        }
        self = .intArray(values)
    }
}

// MARK: - 工具

func dexSmokeFail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("dex-smoke: " + message + "\n").utf8))
    exit(1)
}

func dexSmokeNote(_ message: String) {
    FileHandle.standardError.write(Data(("dex-smoke: " + message + "\n").utf8))
}

// MARK: - 入参

let arguments = CommandLine.arguments
let dexPath = arguments.count > 1 ? arguments[1] : "build/dex-out/classes.dex"
let casesPath = arguments.count > 2 ? arguments[2] : "Tests/dex/cases.json"

func loadData(_ path: String, _ what: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else {
        dexSmokeFail("无法读取\(what)：\(path)")
    }
    return data
}

func parseDex(_ data: Data) -> SDRDexFile {
    do {
        return try SDRDexFile(data: [UInt8](data))
    } catch {
        dexSmokeFail("DEX 解析失败：\(error.localizedDescription)")
    }
}

func parseCases(_ data: Data) -> DexSmokeCaseFile {
    do {
        return try JSONDecoder().decode(DexSmokeCaseFile.self, from: data)
    } catch {
        dexSmokeFail("用例解析失败：\(error)")
    }
}

let dexData = loadData(dexPath, "DEX 文件")
let caseData = loadData(casesPath, "用例文件")
let dexFile = parseDex(dexData)
let caseFile = parseCases(caseData)

dexSmokeNote("DEX 装载完成：\(dexPath)（方法 \(dexFile.methodIds.count) 个，类 \(dexFile.classDefs.count) 个）")

// MARK: - 执行

let interpreter = SDRDexInterpreter(file: dexFile)
var initializedClasses = Set<String>()
var passed = 0
var problems: [String] = []

for item in caseFile.cases {
    let classDescriptor = item.signature.components(separatedBy: "->").first ?? ""

    // 类初始化（<clinit> 每类仅执行一次，与 JVM 语义对齐）
    if !initializedClasses.contains(classDescriptor) {
        initializedClasses.insert(classDescriptor)
        if let index = SDRDexLaunchPlan.initializerIndex(file: dexFile, classDescriptor: classDescriptor) {
            do {
                _ = try interpreter.runMethod(methodIndex: index)
            } catch {
                problems.append("\(classDescriptor)-><clinit> 初始化失败：\(error.localizedDescription)")
            }
        }
    }

    var args: [Int64] = []
    for argument in item.args {
        switch argument {
        case .scalar(let value):
            args.append(value)
        case .intArray(let values):
            let handle = interpreter.heap.newArray(descriptor: "[I", length: values.count)
            for (index, value) in values.enumerated() {
                interpreter.heap.setElement(handle, index, value)
            }
            args.append(handle)
        }
    }

    do {
        let result = try interpreter.invokeMethod(item.signature, args: args)
        print("\(item.signature)=\(result)")
        passed += 1
    } catch {
        print("\(item.signature)=<ERROR>")
        problems.append("\(item.signature) 执行失败：\(error.localizedDescription)")
    }
}

if !problems.isEmpty {
    for problem in problems { dexSmokeNote(problem) }
    dexSmokeFail("\(problems.count) 个用例未通过（成功 \(passed) 个）")
}

dexSmokeNote("对拍清单输出完成，共 \(passed) 个用例")
