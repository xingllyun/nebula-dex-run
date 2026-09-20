// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// DEX 宽整型（long）指令族验证样本
// 每个方法只承载一条 long 语义，便于 dex-smoke 按方法名定位失败点。

class NebulaDexWide {

    static long addL(long a, long b) { return a + b; }

    static long subL(long a, long b) { return a - b; }

    static long mulL(long a, long b) { return a * b; }

    static long divL(long a, long b) { return a / b; }

    static long remL(long a, long b) { return a % b; }

    static long andL(long a, long b) { return a & b; }

    static long orL(long a, long b) { return a | b; }

    static long xorL(long a, long b) { return a ^ b; }

    static long shlL(long a, int b) { return a << b; }

    static long shrL(long a, int b) { return a >> b; }

    static long ushrL(long a, int b) { return a >>> b; }

    /** cmp-long：三态比较，d8 后续会用 if-ltz 归约 */
    static int cmpL(long a, long b) {
        if (a < b) return -1;
        if (a > b) return 1;
        return 0;
    }

    /** 窄化与拓宽迁移 */
    static long widen(int a) { return (long) a; }

    static int narrow(long a) { return (int) a; }

    /** 常量与宽整型混合：const-wide/high16 触发路径 */
    static long wideHigh16() { return 0x0001000000000000L; }
}
