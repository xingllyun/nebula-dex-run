import Foundation

/// AArch64 算术与位运算辅助
public enum SDRAlu {

    public static func add(_ a: UInt64, _ b: UInt64, is64: Bool) -> (UInt64, Bool) {
        let (r, o) = a.addingReportingOverflow(b)
        let carry = o || (!is64 && (r & 0xFFFF_FFFF) < (a & 0xFFFF_FFFF))
        return (is64 ? r : (r & 0xFFFF_FFFF), carry)
    }

    public static func sub(_ a: UInt64, _ b: UInt64, is64: Bool) -> (UInt64, Bool) {
        let (r, o) = a.subtractingReportingOverflow(b)
        return (is64 ? r : (r & 0xFFFF_FFFF), !o && a >= b)
    }

    public static func addOverflow(_ a: UInt64, _ b: UInt64, result: UInt64, is64: Bool) -> Bool {
        let sign: UInt64 = is64 ? 0x8000_0000_0000_0000 : 0x8000_0000
        return (~(a ^ b) & (a ^ result) & sign) != 0
    }

    public static func subOverflow(_ a: UInt64, _ b: UInt64, result: UInt64, is64: Bool) -> Bool {
        let sign: UInt64 = is64 ? 0x8000_0000_0000_0000 : 0x8000_0000
        return ((a ^ b) & (a ^ result) & sign) != 0
    }

    /// 解码 AArch64 逻辑立即数（位掩码编码，BitMasks()）
    public static func decodeBitmask(n: UInt64, immr: UInt64, imms: UInt64, width: Int) -> UInt64 {
        let combined: UInt64 = (n << 6) | (~imms & 0x3F)   // 7 位有效
        guard combined != 0 else { return 0 }
        let len = 63 - combined.leadingZeroBitCount        // HighestSetBit
        let esize: Int = 1 << len
        let levels = UInt64(esize - 1)
        let s = Int(imms & levels)
        let r = Int(immr & levels)

        let welem: UInt64 = (s + 1 >= 64) ? UInt64.max : ((UInt64(1) << UInt64(s + 1)) - 1)
        let esizeMask: UInt64 = (esize >= 64) ? UInt64.max : ((UInt64(1) << UInt64(esize)) - 1)
        var elem = welem & esizeMask

        let rot = r % esize
        if rot > 0 {
            elem = ((elem >> UInt64(rot)) | (elem << UInt64(esize - rot))) & esizeMask
        }

        var wmask: UInt64 = 0
        var p = 0
        while p + esize <= 64 {
            wmask |= elem << UInt64(p)
            p += esize
        }
        return width >= 64 ? wmask : (wmask & ((UInt64(1) << UInt64(width)) - 1))
    }

    /// 条件码判定；cond: 0=EQ 1=NE 2=CS 3=CC 4=MI 5=PL 6=VS 7=VC
    /// 8=HI 9=LS 10=GE 11=LT 12=GT 13=LE 14=AL 15=NV
    public static func conditionHolds(_ cond: UInt32, nzcv: UInt32) -> Bool {
        let n = nzcv & 0x8 != 0
        let z = nzcv & 0x4 != 0
        let c = nzcv & 0x2 != 0
        let v = nzcv & 0x1 != 0

        switch cond {
        case 0: return z
        case 1: return !z
        case 2: return c
        case 3: return !c
        case 4: return n
        case 5: return !n
        case 6: return v
        case 7: return !v
        case 8: return c && !z
        case 9: return !c || z
        case 10: return n == v
        case 11: return n != v
        case 12: return !z && n == v
        case 13: return z || n != v
        default: return true
        }
    }
}
