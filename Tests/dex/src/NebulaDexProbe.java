// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// DEX 指令族验证样本（常量 / 算术 / 位运算 / 返回）
// 由 CI 使用 Android build-tools 的 d8 编译为 classes.dex，供 dex-smoke 做端到端验收。
// 采样原则：每个方法只承载一族语义，方法名即语义标签，便于按方法定位失败点。

public class NebulaDexProbe {

    // ---------- const 族 ----------

    /** const/4：4 位有符号立即数，正数 */
    public static int c4() { return 7; }

    /** const/4：4 位有符号立即数，负数（验证符号扩展） */
    public static int c4neg() { return -3; }

    /** const/16：16 位有符号立即数 */
    public static int c16() { return 300; }

    /** const/16：16 位负数 */
    public static int c16neg() { return -1234; }

    /** const：32 位立即数（低位非零，无法用 high16 装载） */
    public static int c32() { return 0x12345678; }

    /** const/high16：低 16 位为零的 32 位立即数 */
    public static int chigh16() { return 0x7A000000; }

    /** const-wide/16：16 位宽立即数 */
    public static long w16() { return 1234L; }

    /** const-wide/32：32 位宽立即数 */
    public static long w32() { return 123456789L; }

    /** const-wide：64 位宽立即数 */
    public static long wlong() { return 0x1122334455667788L; }

    /** const-string：字符串常量装载 */
    public static String str() { return "NebulaDex"; }

    /** const-class：类对象常量装载 */
    public static Class<?> cls() { return NebulaDexProbe.class; }

    // ---------- 算术族 ----------

    public static int addI(int a, int b) { return a + b; }

    public static int subI(int a, int b) { return a - b; }

    public static int mulI(int a, int b) { return a * b; }

    public static int divI(int a, int b) { return a / b; }

    public static int remI(int a, int b) { return a % b; }

    // ---------- 位运算族 ----------

    public static int andI(int a, int b) { return a & b; }

    public static int orI(int a, int b) { return a | b; }

    public static int xorI(int a, int b) { return a ^ b; }

    /** 移位：Java 的 << 对 int 只需低 5 位，d8 会保留 shl-int 语义 */
    public static int shlI(int a, int b) { return a << b; }

    public static int shrI(int a, int b) { return a >> b; }

    public static int ushrI(int a, int b) { return a >>> b; }

    // ---------- /2addr 变体（同一寄存器读写，d8 分配寄存器时高频使用） ----------

    public static int chain2addr(int a, int b) {
        int r = a;
        r += b;          // add-int/2addr
        r -= 3;          // add-int/lit8（负数常量）
        r *= 2;          // mul-int/lit8
        r /= 3;          // div-int/lit8
        r %= 5;          // rem-int/lit8
        r &= 0xFF;       // and-int/lit16
        r |= 0x10;       // or-int/lit8
        r ^= 3;          // xor-int/lit8
        r <<= 1;         // shl-int/lit8
        r >>= 1;         // shr-int/lit8
        r >>>= 1;        // ushr-int/lit8
        return r;
    }

    /** 二元 /2addr：两个参数已各自在寄存器中，强制造出 reg-reg 形态 */
    public static int pair2addr(int a, int b) {
        int r = a;
        r = r + b;
        r = r * b;
        r = r - b;
        return r;
    }

    // ---------- return 族 ----------

    /** return-void */
    public static void retVoid() { }

    /** return：int */
    public static int retInt(int a) { return a; }

    /** return-wide：long */
    public static long retWide(long a) { return a; }

    /** return-object：引用 */
    public static Object retObject(Object a) { return a; }

    // ---------- 组合语义：常量 + 算术 + 返回 ----------

    /** 常量折叠对照：同一表达式用不同常量触发不同装载宽度 */
    public static long mixConstArith() {
        int a = 300;          // const/16
        long b = 123456789L;  // const-wide/32
        long c = 0x1122334455667788L; // const-wide
        return (long) a + b + c;
    }
}
