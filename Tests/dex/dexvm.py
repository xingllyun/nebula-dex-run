#!/usr/bin/env python3
# Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
# Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
"""NebulaDex DEX 参考实现（Python）。

定位：SDRDexParser / SDRDexInterpreter（Swift）的独立对拍基准。
- 同一份 classes.dex，Python 参考实现与 Swift 实现必须得到一致的返回值；
- 同一份 vectors_dex.json 的期望值由本实现生成，Swift 侧复核。

职责：
1. Dex：DEX 结构解析（字符串/类型/原型/字段/方法/类定义/code_item）；
2. VM：Dalvik 指令级执行（常量 / 迁移 / 算术 / 位运算 / 比较 / 分支 / 开关表 /
   数组 / 静态字段 / 调用分派与递归解释）；
3. 汇编辅助：按官方 format 表机械编码指令，供生成指令级向量。
"""
import struct

# ---------------------------------------------------------------- 数值工具
MASK32 = 0xFFFFFFFF
MASK64 = 0xFFFFFFFFFFFFFFFF


def s8(v):
    v &= 0xFF
    return v - 0x100 if v & 0x80 else v


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def s32(v):
    v &= MASK32
    return v - 0x100000000 if v & 0x80000000 else v


def s64(v):
    v &= MASK64
    return v - 0x10000000000000000 if v & 0x8000000000000000 else v


class DexFault(Exception):
    """错误码与 Swift 侧 SDRCode 一一对应"""

    def __init__(self, code, detail=""):
        super().__init__("%s %s" % (code, detail))
        self.code = code
        self.detail = detail


# ---------------------------------------------------------------- DEX 解析
def _uleb(buf, off):
    result = 0
    shift = 0
    while True:
        b = buf[off]
        off += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, off
        shift += 7


def _mutf8(buf, off):
    _, off = _uleb(buf, off)          # utf16_size
    out = []
    while True:
        b = buf[off]
        off += 1
        if b == 0:
            break
        if b < 0x80:
            out.append(chr(b))
        elif b & 0xE0 == 0xC0:
            out.append(chr(((b & 0x1F) << 6) | (buf[off] & 0x3F)))
            off += 1
        else:
            out.append(chr(((b & 0x0F) << 12) | ((buf[off] & 0x3F) << 6) | (buf[off + 1] & 0x3F)))
            off += 2
    return "".join(out), off


class MethodDef:
    def __init__(self, idx, klass, name, proto, access, code_off):
        self.idx = idx
        self.klass = klass
        self.name = name
        self.proto = proto
        self.access = access
        self.code_off = code_off
        self.registers = 0
        self.ins = 0
        self.outs = 0
        self.units = []

    @property
    def desc(self):
        return "%s->%s%s" % (self.klass, self.name, self.proto)


class Dex:
    """紧凑 DEX 解析器（仅覆盖解释器所需结构）"""

    def __init__(self, data, until=None):
        self.data = data
        magic = data[:8]
        if magic[:4] != b"dex\n":
            raise DexFault("DEX_BAD_MAGIC", "魔数不匹配")
        self.version = magic[4:7].decode("ascii", "replace")
        (self.file_size, self.header_size, self.endian) = struct.unpack_from("<III", data, 32)
        (self.string_ids_size, self.string_ids_off) = struct.unpack_from("<II", data, 56)
        (self.type_ids_size, self.type_ids_off) = struct.unpack_from("<II", data, 64)
        (self.proto_ids_size, self.proto_ids_off) = struct.unpack_from("<II", data, 72)
        (self.field_ids_size, self.field_ids_off) = struct.unpack_from("<II", data, 80)
        (self.method_ids_size, self.method_ids_off) = struct.unpack_from("<II", data, 88)
        (self.class_defs_size, self.class_defs_off) = struct.unpack_from("<II", data, 96)
        self._load_strings()
        self._load_types()
        self._load_protos()
        self._load_fields()
        self._load_methods()
        self._load_classes(until)

    # ---- 基础表 ----
    def _load_strings(self):
        self.strings = []
        for i in range(self.string_ids_size):
            (off,) = struct.unpack_from("<I", self.data, self.string_ids_off + i * 4)
            text, _ = _mutf8(self.data, off)
            self.strings.append(text)

    def _load_types(self):
        self.types = []
        for i in range(self.type_ids_size):
            (idx,) = struct.unpack_from("<I", self.data, self.type_ids_off + i * 4)
            self.types.append(self.strings[idx])

    def _load_protos(self):
        self.protos = []
        for i in range(self.proto_ids_size):
            shorty, ret, params_off = struct.unpack_from("<III", self.data, self.proto_ids_off + i * 12)
            params = []
            if params_off:
                (n,) = struct.unpack_from("<I", self.data, params_off)
                for k in range(n):
                    (t,) = struct.unpack_from("<H", self.data, params_off + 4 + k * 2)
                    params.append(self.types[t])
            self.protos.append("(%s)%s" % ("".join(params), self.types[ret]))

    def _load_fields(self):
        self.fields = []
        for i in range(self.field_ids_size):
            cls, typ, name = struct.unpack_from("<HHI", self.data, self.field_ids_off + i * 8)
            self.fields.append((self.types[cls], self.types[typ], self.strings[name]))

    def _load_methods(self):
        self.methods = []
        for i in range(self.method_ids_size):
            cls, proto, name = struct.unpack_from("<HHI", self.data, self.method_ids_off + i * 8)
            self.methods.append((self.types[cls], self.protos[proto], self.strings[name]))

    # ---- 类定义与 code_item ----
    def _load_classes(self, until):
        self.methods_by_desc = {}
        self.classes = []
        if not self.class_defs_size:
            return
        for i in range(self.class_defs_size):
            base = self.class_defs_off + i * 32
            (cls, access, sup, ifaces, src, anno, cdata, svalues) = struct.unpack_from("<IIIIIIII", self.data, base)
            desc = self.types[cls]
            self.classes.append(desc)
            if until and desc not in until:
                continue
            if cdata:
                self._load_class_data(desc, cdata)

    def _load_class_data(self, desc, off):
        buf = self.data
        sfields, off = _uleb(buf, off)
        ifields, off = _uleb(buf, off)
        smethods, off = _uleb(buf, off)
        imethods, off = _uleb(buf, off)
        idx = 0
        for _ in range(sfields):
            idx, acc, off = self._field_entry(off, idx)
        idx = 0
        for _ in range(ifields):
            idx, acc, off = self._field_entry(off, idx)
        idx = 0
        for _ in range(smethods):
            idx, acc, off = self._method_entry(desc, idx, off)
        idx = 0
        for _ in range(imethods):
            idx, acc, off = self._method_entry(desc, idx, off)

    def _field_entry(self, off, idx):
        diff, off = _uleb(self.data, off)
        acc, off = _uleb(self.data, off)
        return idx + diff, acc, off

    def _method_entry(self, desc, idx, off):
        diff, off = _uleb(self.data, off)
        acc, off = _uleb(self.data, off)
        code_off, off = _uleb(self.data, off)
        idx += diff
        cls, proto, name = self.methods[idx]
        m = MethodDef(idx, desc, name, proto, acc, code_off)
        if code_off:
            self._load_code(m)
        self.methods_by_desc.setdefault(desc, {})["%s%s" % (name, proto)] = m
        return idx, acc, off

    def _load_code(self, m):
        buf = self.data
        regs, ins, outs, tries, dbg, n = struct.unpack_from("<HHHHII", buf, m.code_off)
        m.registers, m.ins, m.outs = regs, ins, outs
        base = m.code_off + 16
        m.units = list(struct.unpack_from("<%dH" % n, buf, base))

    def find(self, desc):
        """desc 形如 LCls;->name(I)I"""
        cls, _, rest = desc.partition("->")
        return self.methods_by_desc.get(cls, {}).get(rest)


# ---------------------------------------------------------------- 托管对象
class SdrArray:
    def __init__(self, elem_width, length):
        self.elem_width = elem_width
        self.values = [0] * length

    def __len__(self):
        return len(self.values)

    def load(self, i):
        if i < 0 or i >= len(self.values):
            raise DexFault("DEX_ARRAY_INDEX", "数组越界 %d" % i)
        return self.values[i]

    def store(self, i, v):
        if i < 0 or i >= len(self.values):
            raise DexFault("DEX_ARRAY_INDEX", "数组越界 %d" % i)
        self.values[i] = v & (MASK64 if self.elem_width == 8 else MASK32)


class SdrObject:
    def __init__(self, klass="Ljava/lang/Object;"):
        self.klass = klass
        self.fields = {}


class SdrString:
    def __init__(self, text):
        self.text = text


# ---------------------------------------------------------------- 汇编辅助
def e12x(op, a, b):
    return [((b & 0xF) << 12) | ((a & 0xF) << 8) | op]


def e11n(op, a, lit):
    return [((lit & 0xF) << 12) | ((a & 0xF) << 8) | op]


def e11x(op, a):
    return [((a & 0xFF) << 8) | op]


def e10t(op, off):
    return [((off & 0xFF) << 8) | op]


def e22x(op, a, b):
    return [((a & 0xFF) << 8) | op, b & 0xFFFF]


def e21s(op, a, lit):
    return [((a & 0xFF) << 8) | op, lit & 0xFFFF]


def e21h(op, a, lit16):
    return e21s(op, a, lit16)


def e21c(op, a, idx):
    return [((a & 0xFF) << 8) | op, idx & 0xFFFF]


def e21t(op, a, off):
    return [((a & 0xFF) << 8) | op, off & 0xFFFF]


def e22t(op, a, b, off):
    return [((b & 0xF) << 12) | ((a & 0xF) << 8) | op, off & 0xFFFF]


def e22s(op, a, b, lit):
    return [((b & 0xF) << 12) | ((a & 0xF) << 8) | op, lit & 0xFFFF]


def e22b(op, a, b, lit):
    return [((a & 0xFF) << 8) | op, ((lit & 0xFF) << 8) | (b & 0xFF)]


def e22c(op, a, b, idx):
    return [((b & 0xF) << 12) | ((a & 0xF) << 8) | op, idx & 0xFFFF]


def e23x(op, a, b, c):
    return [((a & 0xFF) << 8) | op, ((c & 0xFF) << 8) | (b & 0xFF)]


def e31i(op, a, lit):
    return [((a & 0xFF) << 8) | op, lit & 0xFFFF, (lit >> 16) & 0xFFFF]


def e31t(op, a, off):
    return [((a & 0xFF) << 8) | op, off & 0xFFFF, (off >> 16) & 0xFFFF]


def e32x(op, a, b):
    return [op, a & 0xFFFF, b & 0xFFFF]


def e35c(op, idx, regs):
    count = len(regs)
    r = list(regs) + [0] * (5 - count)
    return [((count & 0xF) << 12) | ((r[4] & 0xF) << 8) | op, idx & 0xFFFF,
            ((r[3] & 0xF) << 12) | ((r[2] & 0xF) << 8) | ((r[1] & 0xF) << 4) | (r[0] & 0xF)]


def e3rc(op, idx, first, count):
    return [((count & 0xFF) << 8) | op, idx & 0xFFFF, first & 0xFFFF]


def e51l(op, a, lit):
    u = lit & MASK64
    return [((a & 0xFF) << 8) | op, u & 0xFFFF, (u >> 16) & 0xFFFF,
            (u >> 32) & 0xFFFF, (u >> 48) & 0xFFFF]


def payload_packed(first_key, targets):
    out = [0x0100, len(targets), first_key & 0xFFFF, (first_key >> 16) & 0xFFFF]
    for t in targets:
        out += [t & 0xFFFF, (t >> 16) & 0xFFFF]
    return out


def payload_sparse(keys, targets):
    out = [0x0200, len(keys)]
    for k in keys:
        out += [k & 0xFFFF, (k >> 16) & 0xFFFF]
    for t in targets:
        out += [t & 0xFFFF, (t >> 16) & 0xFFFF]
    return out


# ---------------------------------------------------------------- 指令格式
FORMAT = {}


def _load_format():
    """从 dexop.py 复用权威格式表；不可用时回退到内置最小表"""
    try:
        import dexop
        FORMAT.update(dexop.FORMAT)
        return
    except Exception:
        pass
    FORMAT.update({0x00: "10x", 0x0E: "10x"})


_load_format()

WIDTH_OF = {
    "10x": 1, "12x": 1, "11n": 1, "11x": 1, "10t": 1,
    "20t": 2, "22x": 2, "21s": 2, "21h": 2, "21c": 2, "21t": 2,
    "22t": 2, "22s": 2, "22b": 2, "22c": 2, "23x": 2,
    "30t": 3, "31i": 3, "31c": 3, "31t": 3, "32x": 3, "35c": 3, "3rc": 3,
    "45cc": 4, "4rcc": 4, "51l": 5,
}


def param_types(proto):
    """从原型串（如 "(IJLjava/lang/String;)V"）解析参数类型列表。

    J / D 占两个寄存器槽，其余（含数组与引用）各占一槽。
    """
    inner = proto[1:proto.index(")")]
    types, i = [], 0
    while i < len(inner):
        if inner[i] == "[":
            while inner[i] == "[":
                i += 1
            if inner[i] == "L":
                i = inner.index(";", i) + 1
            else:
                i += 1
            types.append("[")
        elif inner[i] == "L":
            i = inner.index(";", i) + 1
            types.append("L")
        else:
            types.append(inner[i])
            i += 1
    return types


def decode(code, pc):
    """返回 (opcode, format, width, fields)；fields 使用统一键名"""
    unit = code[pc]
    op = unit & 0xFF
    fmt = FORMAT.get(op, "10x")
    w = WIDTH_OF.get(fmt, 1)
    f = {"fmt": fmt}

    def u(i):
        return code[pc + i] if pc + i < len(code) else 0

    if fmt == "12x":
        f["a"], f["b"] = (unit >> 8) & 0xF, (unit >> 12) & 0xF
    elif fmt == "11n":
        lit4 = (unit >> 12) & 0xF
        f["a"], f["lit"] = (unit >> 8) & 0xF, (lit4 - 0x10 if lit4 & 0x8 else lit4)
    elif fmt == "11x":
        f["a"] = (unit >> 8) & 0xFF
    elif fmt == "10t":
        f["off"] = s8(unit >> 8)
    elif fmt == "20t":
        f["off"] = s16(u(1))
    elif fmt in ("21s", "21h"):
        # 21h 的 lit16 在此保持原值：const/high16 由 op_15 左移 16，
        # const-wide/high16 由 op_19 左移 48，两者共用同一 21h 解码路径。
        f["a"], f["lit"] = (unit >> 8) & 0xFF, s16(u(1))
    elif fmt == "21c":
        f["a"], f["idx"] = (unit >> 8) & 0xFF, u(1)
    elif fmt == "21t":
        f["a"], f["off"] = (unit >> 8) & 0xFF, s16(u(1))
    elif fmt in ("22t", "22s"):
        f["a"], f["b"] = (unit >> 8) & 0xF, (unit >> 12) & 0xF
        f["off" if fmt == "22t" else "lit"] = s16(u(1))
    elif fmt == "22b":
        f["a"] = (unit >> 8) & 0xFF
        f["b"], f["lit"] = u(1) & 0xFF, s8(u(1) >> 8)
    elif fmt == "22c":
        f["a"], f["b"], f["idx"] = (unit >> 8) & 0xF, (unit >> 12) & 0xF, u(1)
    elif fmt == "22x":
        f["a"], f["b"] = (unit >> 8) & 0xFF, u(1)
    elif fmt == "23x":
        f["a"], f["b"], f["c"] = (unit >> 8) & 0xFF, u(1) & 0xFF, (u(1) >> 8) & 0xFF
    elif fmt == "30t":
        f["off"] = s32(u(1) | (u(2) << 16))
    elif fmt == "31i":
        f["a"], f["lit"] = (unit >> 8) & 0xFF, s32(u(1) | (u(2) << 16))
    elif fmt == "31c":
        f["a"], f["idx"] = (unit >> 8) & 0xFF, u(1) | (u(2) << 16)
    elif fmt == "31t":
        f["a"], f["off"] = (unit >> 8) & 0xFF, s32(u(1) | (u(2) << 16))
    elif fmt == "32x":
        f["a"], f["b"] = u(1), u(2)
    elif fmt == "35c":
        count = (unit >> 12) & 0xF
        g = (unit >> 8) & 0xF
        u2 = u(2)
        regs = [u2 & 0xF, (u2 >> 4) & 0xF, (u2 >> 8) & 0xF, (u2 >> 12) & 0xF, g]
        f["idx"], f["regs"], f["count"] = u(1), regs[:count], count
    elif fmt == "3rc":
        count = (unit >> 8) & 0xFF
        f["idx"], f["count"], f["first"] = u(1), count, u(2)
    elif fmt in ("45cc", "4rcc"):
        u2 = u(2)
        if fmt == "45cc":
            count = (unit >> 12) & 0xF
            g = (unit >> 8) & 0xF
            f["regs"] = [u2 & 0xF, (u2 >> 4) & 0xF, (u2 >> 8) & 0xF, (u2 >> 12) & 0xF, g][:count]
        else:
            count = (unit >> 8) & 0xFF
            f["first"] = u2
        f["count"], f["idx"], f["proto"] = count, u(1), u(3)
    elif fmt == "51l":
        f["a"] = (unit >> 8) & 0xFF
        f["lit"] = s64(u(1) | (u(2) << 16) | (u(3) << 32) | (u(4) << 48))
    return op, fmt, w, f


# ---------------------------------------------------------------- 执行模型
class VM:
    """Dalvik 指令级执行；invoke 优先解释 DEX 内部方法，再查原生注册表"""

    def __init__(self, dex=None, natives=None, max_steps=2_000_000, trace=None):
        self.dex = dex
        self.natives = natives or {}
        self.static_fields = {}
        self.heap = []
        self.max_steps = max_steps
        self.steps = 0
        self.trace = trace or []

    # ---- 堆 ----
    def alloc(self, obj):
        self.heap.append(obj)
        return 0x4000000000000000 | (len(self.heap) - 1)

    def deref(self, handle):
        if handle >> 60 != 4 or (handle & 0x0FFFFFFFFFFFFFFF) >= len(self.heap):
            raise DexFault("DEX_NULL_OBJECT", "非法对象句柄")
        return self.heap[handle & 0x0FFFFFFFFFFFFFFF]

    # ---- 方法执行 ----
    def run_method(self, desc, args=()):
        m = self.dex.find(desc) if self.dex else None
        if m is None or not m.units:
            raise DexFault("DEX_METHOD_UNRESOLVED", "DEX 内无此方法体 %s" % desc)
        code, regs = m.units, [0] * max(m.registers, 1)
        base = m.registers - m.ins
        slot = base
        for t, v in zip(param_types(m.proto), args):
            if t in ("J", "D"):
                # 宽类型占两个寄存器槽：低 32 位在低编号寄存器（little-endian）
                regs[slot] = v & MASK64
                regs[slot + 1] = (v >> 32) & MASK32
                slot += 2
            else:
                regs[slot] = v & MASK64
                slot += 1
        return self.execute(code, regs)

    def execute(self, code, regs, ins_size=0):
        pc = 0
        last = 0
        while pc < len(code):
            self.steps += 1
            if self.steps > self.max_steps:
                raise DexFault("DEX_OP_UNSUPPORTED", "步数超限")
            op, fmt, w, f = decode(code, pc)
            if code[pc] in (0x0100, 0x0200, 0x0300):
                pc += 1
                continue
            fn = getattr(self, "op_%02x" % op, None)
            if fn is None:
                raise DexFault("DEX_OP_UNSUPPORTED", "未实现指令 0x%02X @%d" % (op, pc))
            pc, last = fn(code, pc, f, w, regs, last)
        return s64(last)

    # ---- 常量族 ----
    def op_00(self, code, pc, f, w, r, last):
        return pc + w, last

    def op_12(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(f["lit"])
        return pc + w, last

    def op_13(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(f["lit"])
        return pc + w, last

    def op_14(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(f["lit"])
        return pc + w, last

    def op_15(self, code, pc, f, w, r, last):           # const/high16：lit16 << 16
        r[f["a"]] = s64(s32(f["lit"] << 16))
        return pc + w, last

    def op_16(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(f["lit"])
        return pc + w, last

    def op_17(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(f["lit"])
        return pc + w, last

    def op_18(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(f["lit"])
        return pc + w, last

    def op_19(self, code, pc, f, w, r, last):           # const-wide/high16：lit16 << 48
        r[f["a"]] = s64(f["lit"] << 48)
        return pc + w, last

    def op_1a(self, code, pc, f, w, r, last):
        text = self.dex.strings[f["idx"]] if self.dex and f["idx"] < self.dex.string_ids_size else ""
        r[f["a"]] = self.alloc(SdrString(text))
        return pc + w, last

    def op_1c(self, code, pc, f, w, r, last):
        desc = self.dex.types[f["idx"]] if self.dex else ""
        r[f["a"]] = self.alloc(SdrObject(desc))
        return pc + w, last

    # ---- 迁移族 ----
    def _move(self, r, dst, src):
        r[dst] = r[src]

    def op_01(self, code, pc, f, w, r, last):
        self._move(r, f["a"], f["b"])
        return pc + w, last

    def op_02(self, code, pc, f, w, r, last):
        r[f["a"]] = r[f["b"]]
        return pc + w, last

    def op_03(self, code, pc, f, w, r, last):
        r[f["a"]] = r[f["b"]]
        return pc + w, last

    def op_04(self, code, pc, f, w, r, last):
        r[f["a"]], r[f["a"] + 1] = r[f["b"]], r[f["b"] + 1]
        return pc + w, last

    def op_05(self, code, pc, f, w, r, last):
        r[f["a"]], r[f["a"] + 1] = r[f["b"]], r[f["b"] + 1]
        return pc + w, last

    def op_06(self, code, pc, f, w, r, last):
        r[f["a"]], r[f["a"] + 1] = r[f["b"]], r[f["b"] + 1]
        return pc + w, last

    def op_07(self, code, pc, f, w, r, last):
        r[f["a"]] = r[f["b"]]
        return pc + w, last

    def op_08(self, code, pc, f, w, r, last):
        r[f["a"]] = r[f["b"]]
        return pc + w, last

    def op_09(self, code, pc, f, w, r, last):
        r[f["a"]] = r[f["b"]]
        return pc + w, last

    def op_0a(self, code, pc, f, w, r, last):
        r[f["a"]] = last
        return pc + w, last

    def op_0b(self, code, pc, f, w, r, last):
        r[f["a"]] = last
        return pc + w, last

    def op_0c(self, code, pc, f, w, r, last):
        r[f["a"]] = last
        return pc + w, last

    # ---- 返回族 ----
    def op_0e(self, code, pc, f, w, r, last):
        return len(code), 0

    def op_0f(self, code, pc, f, w, r, last):
        return len(code), r[f["a"]]

    op_10 = op_0f
    op_11 = op_0f

    # ---- 控制流 ----
    def op_28(self, code, pc, f, w, r, last):
        return pc + f["off"], last

    def op_29(self, code, pc, f, w, r, last):
        return pc + f["off"], last

    def op_2a(self, code, pc, f, w, r, last):
        return pc + f["off"], last

    def _if(self, code, pc, f, w, r, cond, last):
        if cond:
            return pc + f["off"], last
        return pc + w, last

    def op_32(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) == s64(r[f["b"]]), last)

    def op_33(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) != s64(r[f["b"]]), last)

    def op_34(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) < s64(r[f["b"]]), last)

    def op_35(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) >= s64(r[f["b"]]), last)

    def op_36(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) > s64(r[f["b"]]), last)

    def op_37(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) <= s64(r[f["b"]]), last)

    def op_38(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) == 0, last)

    def op_39(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) != 0, last)

    def op_3a(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) < 0, last)

    def op_3b(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) >= 0, last)

    def op_3c(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) > 0, last)

    def op_3d(self, code, pc, f, w, r, last):
        return self._if(code, pc, f, w, r, s64(r[f["a"]]) <= 0, last)

    def op_2b(self, code, pc, f, w, r, last):
        base = pc + f["off"]
        if code[base] != 0x0100:
            raise DexFault("DEX_BAD_FORMAT", "packed-switch payload 缺失")
        size = code[base + 1]
        first = s32(code[base + 2] | (code[base + 3] << 16))
        key = s32(r[f["a"]])
        if first <= key < first + size:
            ent = base + 4 + (key - first) * 2
            return pc + s32(code[ent] | (code[ent + 1] << 16)), last
        return pc + w, last

    def op_2c(self, code, pc, f, w, r, last):
        base = pc + f["off"]
        if code[base] != 0x0200:
            raise DexFault("DEX_BAD_FORMAT", "sparse-switch payload 缺失")
        size = code[base + 1]
        key = s32(r[f["a"]])
        for i in range(size):
            kb = base + 2 + i * 2
            if s32(code[kb] | (code[kb + 1] << 16)) == key:
                ent = base + 2 + size * 2 + i * 2
                return pc + s32(code[ent] | (code[ent + 1] << 16)), last
        return pc + w, last

    # ---- 一元 / 转换 ----
    def _un(self, f, r, fn):
        r[f["a"]] = s64(fn(s64(r[f["b"]])))

    def op_7b(self, code, pc, f, w, r, last):
        self._un(f, r, lambda v: s32(-v))
        return pc + w, last

    def op_7c(self, code, pc, f, w, r, last):
        self._un(f, r, lambda v: s32(~v))
        return pc + w, last

    def op_7d(self, code, pc, f, w, r, last):
        self._un(f, r, lambda v: s64(-v))
        return pc + w, last

    def op_7e(self, code, pc, f, w, r, last):
        self._un(f, r, lambda v: s64(~v))
        return pc + w, last

    # ---- 类型转换族（0x81-0x8F，12x）----
    # 仅实现整数域转换；int/long 与 float/double 的互转（0x82/0x83/0x85-0x8C）
    # 依赖浮点运行时，留待阶段五——不注册即由 execute 抛 DEX_OP_UNSUPPORTED。
    def op_81(self, code, pc, f, w, r, last):           # int-to-long：符号扩展
        self._un(f, r, lambda v: s64(s32(v)))
        return pc + w, last

    def op_84(self, code, pc, f, w, r, last):           # long-to-int：截取低 32 位
        self._un(f, r, lambda v: s64(s32(v)))
        return pc + w, last

    def op_8e(self, code, pc, f, w, r, last):
        self._un(f, r, lambda v: v & 0xFFFF)
        return pc + w, last

    def op_8f(self, code, pc, f, w, r, last):
        self._un(f, r, lambda v: s64(s16(v)))
        return pc + w, last

    # ---- 二元运算统一实现 ----
    def _div(self, x, y):
        if y == 0:
            raise DexFault("DEX_ARITHMETIC", "除数为零")
        q = abs(x) // abs(y)
        return -q if (x < 0) != (y < 0) else q

    def _rem(self, x, y):
        if y == 0:
            raise DexFault("DEX_ARITHMETIC", "除数为零")
        return -(abs(x) % abs(y)) if x < 0 else abs(x) % abs(y)

    BIN32 = {
        0x90: lambda x, y: s32(x + y), 0x91: lambda x, y: s32(x - y),
        0x92: lambda x, y: s32(x * y),
        0x95: lambda x, y: s32(x & y), 0x96: lambda x, y: s32(x | y),
        0x97: lambda x, y: s32(x ^ y),
        0x98: lambda x, y: s32(x << (y & 0x1F)),
        0x99: lambda x, y: s32(s32(x) >> (y & 0x1F)),
        0x9A: lambda x, y: s32((x & MASK32) >> (y & 0x1F)),
    }
    BIN64 = {
        0x9B: lambda x, y: s64(x + y), 0x9C: lambda x, y: s64(x - y),
        0x9D: lambda x, y: s64(x * y),
        0xA0: lambda x, y: s64(x & y), 0xA1: lambda x, y: s64(x | y),
        0xA2: lambda x, y: s64(x ^ y),
        0xA3: lambda x, y: s64(x << (y & 0x3F)),
        0xA4: lambda x, y: s64(x >> (y & 0x3F)),
        0xA5: lambda x, y: s64((x & MASK64) >> (y & 0x3F)),
    }

    def _bin23(self, code, pc, f, w, r, last, fn):
        r[f["a"]] = s64(fn(s64(r[f["b"]]), s64(r[f["c"]])))
        return pc + w, last

    def _acc12(self, code, pc, f, w, r, last, fn):
        r[f["a"]] = s64(fn(s64(r[f["a"]]), s64(r[f["b"]])))
        return pc + w, last

    def op_31(self, code, pc, f, w, r, last):
        x, y = s64(r[f["b"]]), s64(r[f["c"]])
        r[f["a"]] = -1 if x < y else (1 if x > y else 0)
        return pc + w, last

    def op_93(self, code, pc, f, w, r, last):
        return self._bin23(code, pc, f, w, r, last, lambda x, y: s32(self._div(s32(x), s32(y))))

    def op_94(self, code, pc, f, w, r, last):
        return self._bin23(code, pc, f, w, r, last, lambda x, y: s32(self._rem(s32(x), s32(y))))

    def op_9e(self, code, pc, f, w, r, last):
        return self._bin23(code, pc, f, w, r, last, lambda x, y: s64(self._div(x, y)))

    def op_9f(self, code, pc, f, w, r, last):
        return self._bin23(code, pc, f, w, r, last, lambda x, y: s64(self._rem(x, y)))

    def op_b3(self, code, pc, f, w, r, last):
        return self._acc12(code, pc, f, w, r, last, lambda x, y: s32(self._div(s32(x), s32(y))))

    def op_b4(self, code, pc, f, w, r, last):
        return self._acc12(code, pc, f, w, r, last, lambda x, y: s32(self._rem(s32(x), s32(y))))

    def op_be(self, code, pc, f, w, r, last):
        return self._acc12(code, pc, f, w, r, last, lambda x, y: s64(self._div(x, y)))

    def op_bf(self, code, pc, f, w, r, last):
        return self._acc12(code, pc, f, w, r, last, lambda x, y: s64(self._rem(x, y)))

    # ---- lit16 / lit8 ----
    def op_d0(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["b"]]) + f["lit"]))
        return pc + w, last

    def op_d1(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(f["lit"] - s32(r[f["b"]])))
        return pc + w, last

    def op_d2(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["b"]]) * f["lit"]))
        return pc + w, last

    def op_d3(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(self._div(s32(r[f["b"]]), f["lit"])))
        return pc + w, last

    def op_d4(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(self._rem(s32(r[f["b"]]), f["lit"])))
        return pc + w, last

    def op_d5(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["b"]]) & f["lit"]))
        return pc + w, last

    def op_d6(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["b"]]) | f["lit"]))
        return pc + w, last

    def op_d7(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["b"]]) ^ f["lit"]))
        return pc + w, last

    def op_d8(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["a"]]) + f["lit"]))
        return pc + w, last

    def op_d9(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(f["lit"] - s32(r[f["a"]])))
        return pc + w, last

    def op_da(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["a"]]) * f["lit"]))
        return pc + w, last

    def op_db(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(self._div(s32(r[f["a"]]), f["lit"])))
        return pc + w, last

    def op_dc(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(self._rem(s32(r[f["a"]]), f["lit"])))
        return pc + w, last

    def op_dd(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["a"]]) & f["lit"]))
        return pc + w, last

    def op_de(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["a"]]) | f["lit"]))
        return pc + w, last

    def op_df(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["a"]]) ^ f["lit"]))
        return pc + w, last

    def op_e0(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s64(r[f["a"]]) << (f["lit"] & 0x1F)))
        return pc + w, last

    def op_e1(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32(s32(r[f["a"]]) >> (f["lit"] & 0x1F)))
        return pc + w, last

    def op_e2(self, code, pc, f, w, r, last):
        r[f["a"]] = s64(s32((s64(r[f["a"]]) & MASK32) >> (f["lit"] & 0x1F)))
        return pc + w, last

    # ---- 数组 ----
    def op_21(self, code, pc, f, w, r, last):
        arr = self.deref(r[f["b"]])
        r[f["a"]] = len(arr)
        return pc + w, last

    def op_22(self, code, pc, f, w, r, last):
        desc = self.dex.types[f["idx"]] if self.dex else "Ljava/lang/Object;"
        r[f["a"]] = self.alloc(SdrObject(desc))
        return pc + w, last

    def _filled_new_array(self, code, pc, f, w, r, last, regs):
        desc = self.dex.types[f["idx"]] if self.dex else "[I"
        width = 8 if desc in ("[J", "[D") else (4 if desc in ("[I", "[F") else 1)
        arr = SdrArray(width, len(regs))
        for i, reg in enumerate(regs):
            arr.store(i, s64(r[reg]))
        return pc + w, self.alloc(arr)

    def op_24(self, code, pc, f, w, r, last):
        return self._filled_new_array(code, pc, f, w, r, last, list(f["regs"]))

    def op_25(self, code, pc, f, w, r, last):
        regs = [f["first"] + i for i in range(f["count"])]
        return self._filled_new_array(code, pc, f, w, r, last, regs)

    def op_23(self, code, pc, f, w, r, last):
        n = s32(r[f["b"]])
        desc = self.dex.types[f["idx"]] if self.dex else "[I"
        width = 8 if desc in ("[J", "[D") else (4 if desc in ("[I", "[F") else 1)
        if n < 0:
            raise DexFault("DEX_ARRAY_INDEX", "负长度数组")
        r[f["a"]] = self.alloc(SdrArray(width, n))
        return pc + w, last

    def op_26(self, code, pc, f, w, r, last):
        base = pc + f["off"]
        if code[base] != 0x0300:
            raise DexFault("DEX_BAD_FORMAT", "fill-array-data payload 缺失")
        elem_width = code[base + 1]
        count = code[base + 2] | (code[base + 3] << 16)
        arr = self.deref(r[f["a"]])
        for i in range(count):
            v = 0
            for k in range(elem_width):
                byte_index = i * elem_width + k
                unit = code[base + 4 + byte_index // 2]
                byte = unit & 0xFF if byte_index % 2 == 0 else (unit >> 8) & 0xFF
                v |= byte << (8 * k)
            if elem_width == 4:
                v = s32(v)
            elif elem_width == 8:
                v = s64(v)
            arr.store(i, v)
        return pc + w, last

    AGET = {0x44: ("I", 4), 0x45: ("J", 8), 0x46: ("L", 4), 0x47: ("Z", 1),
            0x48: ("B", 1), 0x49: ("C", 2), 0x4A: ("S", 2)}
    APUT = {0x4B: 4, 0x4C: 8, 0x4D: 4, 0x4E: 1, 0x4F: 1, 0x50: 2, 0x51: 2}

    def _aget(self, code, pc, f, w, r, last):
        arr = self.deref(r[f["b"]])
        r[f["a"]] = arr.load(s32(r[f["c"]]))
        return pc + w, last

    def _aput(self, code, pc, f, w, r, last):
        arr = self.deref(r[f["b"]])
        arr.store(s32(r[f["c"]]), s64(r[f["a"]]))
        return pc + w, last

    # ---- 字段 ----
    def op_60(self, code, pc, f, w, r, last):
        r[f["a"]] = self.static_fields.get(f["idx"], 0)
        return pc + w, last

    def op_67(self, code, pc, f, w, r, last):
        self.static_fields[f["idx"]] = s64(r[f["a"]])
        return pc + w, last

    def op_52(self, code, pc, f, w, r, last):
        obj = self.deref(r[f["b"]])
        r[f["a"]] = obj.fields.get(f["idx"], 0)
        return pc + w, last

    def op_59(self, code, pc, f, w, r, last):
        obj = self.deref(r[f["b"]])
        obj.fields[f["idx"]] = s64(r[f["a"]])
        return pc + w, last

    # ---- 调用 ----
    def _invoke(self, code, pc, f, w, r, last, static):
        idx = f["idx"]
        if "regs" in f:
            arg_regs = f["regs"]
        else:
            arg_regs = [f["first"] + k for k in range(f["count"])]
        args = [r[x] for x in arg_regs]
        cls, proto, name = self.dex.methods[idx] if self.dex else ("?", "?", "?")
        desc = "%s->%s%s" % (cls, name, proto)
        result = self.invoke(desc, args, klass=cls, name=name)
        return pc + w, last if result is None else s64(result)

    def op_6e(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, False)

    def op_6f(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, False)

    def op_70(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, False)

    def op_71(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, True)

    def op_72(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, False)

    def op_74(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, False)

    def op_75(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, False)

    def op_76(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, False)

    def op_77(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, True)

    def op_78(self, code, pc, f, w, r, last):
        return self._invoke(code, pc, f, w, r, last, False)

    def invoke(self, desc, args, klass="", name=""):
        """解析顺序：DEX 内部方法 → 原生注册表 → 未解析错误"""
        m = self.dex.find(desc) if self.dex else None
        if m is not None and m.units:
            return self.run_method(desc, args)
        native = self.natives.get(desc)
        if native is not None:
            return native(self, list(args))
        raise DexFault("DEX_METHOD_UNRESOLVED", "未注册且 DEX 内无方法体 %s" % desc)


# 统一挂载数组/对象/字段指令的别名实现
for _op in VM.AGET:
    setattr(VM, "op_%02x" % _op, VM._aget)
for _op in VM.APUT:
    setattr(VM, "op_%02x" % _op, VM._aput)
del _op


def _install_table():
    for op, fn in VM.BIN32.items():
        setattr(VM, "op_%02x" % op, lambda self, code, pc, f, w, r, last, _fn=fn:
                self._bin23(code, pc, f, w, r, last, _fn))
    for op, fn in VM.BIN64.items():
        setattr(VM, "op_%02x" % op, lambda self, code, pc, f, w, r, last, _fn=fn:
                self._bin23(code, pc, f, w, r, last, _fn))
    pairs = {0xB0: ("32", "+"), 0xB1: ("32", "-"), 0xB2: ("32", "*"),
             0xB5: ("32", "&"), 0xB6: ("32", "|"), 0xB7: ("32", "^"),
             0xB8: ("32", "<<"), 0xB9: ("32", ">>"), 0xBA: ("32", ">>>"),
             0xBB: ("64", "+"), 0xBC: ("64", "-"), 0xBD: ("64", "*"),
             0xC0: ("64", "&"), 0xC1: ("64", "|"), 0xC2: ("64", "^"),
             0xC3: ("64", "<<"), 0xC4: ("64", ">>"), 0xC5: ("64", ">>>")}
    for op, (width, sym) in pairs.items():
        def make(width=width, sym=sym):
            def run(self, code, pc, f, w, r, last):
                x, y = s64(r[f["a"]]), s64(r[f["b"]])
                m = 0x1F if width == "32" else 0x3F
                if sym == "+":
                    v = x + y
                elif sym == "-":
                    v = x - y
                elif sym == "*":
                    v = x * y
                elif sym == "&":
                    v = x & y
                elif sym == "|":
                    v = x | y
                elif sym == "^":
                    v = x ^ y
                elif sym == "<<":
                    v = x << (y & m)
                elif sym == ">>":
                    v = s64(x) >> (y & m)
                elif sym == ">>>":
                    # 逻辑右移必须按声明宽度先截断再移位：32 位取低 32 位后 >>，
                    # 否则负数会按 64 位无符号右移，结果退化为 -1。
                    v = (x & (MASK32 if width == "32" else MASK64)) >> (y & m)
                r[f["a"]] = s64(s32(v)) if width == "32" else s64(v)
                return pc + w, last
            return run
        setattr(VM, "op_%02x" % op, make())
    del pairs


_install_table()
