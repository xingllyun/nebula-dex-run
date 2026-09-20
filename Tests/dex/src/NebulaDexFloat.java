// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// DEX 浮点指令族验证样本（float/double 二元、/2addr、neg、类型转换、cmp）。
// 采样原则：所有运算一律以方法参数参与，避免 javac / d8 在编译期把浮点指令常量折叠掉；
// 方法名即语义标签，便于按方法定位失败点。

public class NebulaDexFloat {

    // ---------- float 二元（0xA6-0xAA）----------

    public static float addF(float a, float b) { return a + b; }

    public static float subF(float a, float b) { return a - b; }

    public static float mulF(float a, float b) { return a * b; }

    public static float divF(float a, float b) { return a / b; }

    public static float remF(float a, float b) { return a % b; }

    // ---------- double 二元（0xAB-0xAF）----------

    public static double addD(double a, double b) { return a + b; }

    public static double subD(double a, double b) { return a - b; }

    public static double mulD(double a, double b) { return a * b; }

    public static double divD(double a, double b) { return a / b; }

    public static double remD(double a, double b) { return a % b; }

    // ---------- 浮点 /2addr（0xC6-0xCF）----------

    /** 同一寄存器连续自运算，强制造出 /2addr 形态 */
    public static float chainF(float a, float b) {
        float r = a;
        r += b;
        r -= b;
        r *= b;
        r /= b;
        r %= b;
        return r;
    }

    public static double chainD(double a, double b) {
        double r = a;
        r += b;
        r -= b;
        r *= b;
        r /= b;
        return r;
    }

    // ---------- 三寄存器编码（23x）----------
    // d8 在寄存器分配阶段偏爱 /2addr 形态，此处让 a/b 全程存活、五个中间结果各自独立，
    // 迫使 d8 保留 23x 三寄存器编码，否则 0xA6-0xAF / 0xAB-0xAF 在 CI 中不会被真实执行。

    public static float mixF(float a, float b) {
        float s = a + b;
        float d = a - b;
        float p = a * b;
        float q = a / b;
        float r = a % b;
        return s + d - p + q - r + a - b;
    }

    public static double mixD(double a, double b) {
        double s = a + b;
        double d = a - b;
        double p = a * b;
        double q = a / b;
        double r = a % b;
        return s + d - p + q - r + a - b;
    }

    // ---------- neg（0x7F-0x80）----------

    public static float negF(float a) { return -a; }

    public static double negD(double a) { return -a; }

    // ---------- 类型转换（0x82-0x8C）----------

    public static float i2f(int a) { return a; }

    public static double i2d(int a) { return a; }

    public static float l2f(long a) { return a; }

    public static double l2d(long a) { return a; }

    public static int f2i(float a) { return (int) a; }

    public static long f2l(float a) { return (long) a; }

    public static double f2d(float a) { return a; }

    public static int d2i(double a) { return (int) a; }

    public static long d2l(double a) { return (long) a; }

    public static float d2f(double a) { return (float) a; }

    // ---------- 比较（0x2D-0x30）----------
    // javac 口径：a < b 用 cmpg、a > b 用 cmpl，NaN 一律落「假」分支

    public static int lessF(float a, float b) { return a < b ? 1 : 0; }

    public static int greaterF(float a, float b) { return a > b ? 1 : 0; }

    public static int lessD(double a, double b) { return a < b ? 1 : 0; }

    public static int greaterD(double a, double b) { return a > b ? 1 : 0; }
}
