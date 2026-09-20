// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// dex-smoke 期望值驱动：在 JVM 上原生执行样本方法，输出「签名=值」逐行清单。
// 与 Tests/dex/cases.json 的用例顺序必须严格一致（静态字段会跨用例累积）。
// 用法：javac --release 8 -d build/dex-classes Tests/dex/src/*.java
//       java -cp build/dex-classes DexExpect > build/expect.txt

public class DexExpect {

    private static void p(String signature, long value) {
        System.out.println(signature + "=" + value);
    }

    /** float 返回值：按 IEEE 位模式（有符号 32 位）打印，与解释器 return 语义对齐 */
    private static void p(String signature, float value) {
        System.out.println(signature + "=" + (long) (int) Float.floatToRawIntBits(value));
    }

    /** double 返回值：按 IEEE 位模式（64 位）打印，与解释器 return-wide 语义对齐 */
    private static void p(String signature, double value) {
        System.out.println(signature + "=" + Double.doubleToRawLongBits(value));
    }

    public static void main(String[] args) {
        // ---------- NebulaDexProbe：常量装载 ----------
        p("LNebulaDexProbe;->c4()I", NebulaDexProbe.c4());
        p("LNebulaDexProbe;->c4neg()I", NebulaDexProbe.c4neg());
        p("LNebulaDexProbe;->c16()I", NebulaDexProbe.c16());
        p("LNebulaDexProbe;->c16neg()I", NebulaDexProbe.c16neg());
        p("LNebulaDexProbe;->c32()I", NebulaDexProbe.c32());
        p("LNebulaDexProbe;->chigh16()I", NebulaDexProbe.chigh16());
        p("LNebulaDexProbe;->w16()J", NebulaDexProbe.w16());
        p("LNebulaDexProbe;->w32()J", NebulaDexProbe.w32());
        p("LNebulaDexProbe;->wlong()J", NebulaDexProbe.wlong());

        // ---------- NebulaDexProbe：int 二元 ----------
        p("LNebulaDexProbe;->addI(II)I", NebulaDexProbe.addI(7, 11));
        p("LNebulaDexProbe;->subI(II)I", NebulaDexProbe.subI(7, 11));
        p("LNebulaDexProbe;->mulI(II)I", NebulaDexProbe.mulI(65536, 65536));
        p("LNebulaDexProbe;->divI(II)I", NebulaDexProbe.divI(100, 7));
        p("LNebulaDexProbe;->remI(II)I", NebulaDexProbe.remI(-100, 7));
        p("LNebulaDexProbe;->andI(II)I", NebulaDexProbe.andI(0xF0F0, 0x0FF0));
        p("LNebulaDexProbe;->orI(II)I", NebulaDexProbe.orI(0xF0F0, 0x0FF0));
        p("LNebulaDexProbe;->xorI(II)I", NebulaDexProbe.xorI(0xF0F0, 0x0FF0));
        p("LNebulaDexProbe;->shlI(II)I", NebulaDexProbe.shlI(1, 31));
        p("LNebulaDexProbe;->shrI(II)I", NebulaDexProbe.shrI(-16, 2));
        p("LNebulaDexProbe;->ushrI(II)I", NebulaDexProbe.ushrI(-16, 2));
        p("LNebulaDexProbe;->chain2addr(II)I", NebulaDexProbe.chain2addr(10, 5));
        p("LNebulaDexProbe;->pair2addr(II)I", NebulaDexProbe.pair2addr(6, 7));

        // ---------- NebulaDexProbe：return 族与组合语义 ----------
        p("LNebulaDexProbe;->retInt(I)I", NebulaDexProbe.retInt(42));
        p("LNebulaDexProbe;->retWide(J)J", NebulaDexProbe.retWide(1234567890123L));
        p("LNebulaDexProbe;->mixConstArith()J", NebulaDexProbe.mixConstArith());

        // ---------- NebulaDexFlow：控制流 / 数组 / 静态字段 / 跨类调用 ----------
        p("LNebulaDexFlow;->loop(I)I", NebulaDexFlow.loop(10));
        p("LNebulaDexFlow;->branch(I)I", NebulaDexFlow.branch(5));
        p("LNebulaDexFlow;->branch(I)I", NebulaDexFlow.branch(-5));
        p("LNebulaDexFlow;->branch(I)I", NebulaDexFlow.branch(0));
        p("LNebulaDexFlow;->packed(I)I", NebulaDexFlow.packed(2));
        p("LNebulaDexFlow;->packed(I)I", NebulaDexFlow.packed(9));
        p("LNebulaDexFlow;->arr([I)I", NebulaDexFlow.arr(new int[] { 7, 9 }));
        p("LNebulaDexFlow;->bump()I", NebulaDexFlow.bump());
        p("LNebulaDexFlow;->call(I)I", NebulaDexFlow.call(3));

        // ---------- NebulaDexSwitch：分支表 ----------
        p("LNebulaDexSwitch;->dense(I)I", NebulaDexSwitch.dense(7));
        p("LNebulaDexSwitch;->dense(I)I", NebulaDexSwitch.dense(3));
        p("LNebulaDexSwitch;->sparse(I)I", NebulaDexSwitch.sparse(10000));
        p("LNebulaDexSwitch;->sparse(I)I", NebulaDexSwitch.sparse(5));
        p("LNebulaDexSwitch;->pick(JJ)J", NebulaDexSwitch.pick(3L, 9L));
        p("LNebulaDexSwitch;->pick(JJ)J", NebulaDexSwitch.pick(9L, 3L));

        // ---------- NebulaDexWide：long 族与整数域类型转换 ----------
        p("LNebulaDexWide;->addL(JJ)J", NebulaDexWide.addL(7L, 11L));
        p("LNebulaDexWide;->subL(JJ)J", NebulaDexWide.subL(7L, 11L));
        p("LNebulaDexWide;->mulL(JJ)J", NebulaDexWide.mulL(123456789L, 987654321L));
        p("LNebulaDexWide;->divL(JJ)J", NebulaDexWide.divL(1000000007L, 7L));
        p("LNebulaDexWide;->remL(JJ)J", NebulaDexWide.remL(-100L, 7L));
        p("LNebulaDexWide;->andL(JJ)J", NebulaDexWide.andL(0x00FF00FF00FF00FFL, 0x0F0F0F0F0F0F0F0FL));
        p("LNebulaDexWide;->orL(JJ)J", NebulaDexWide.orL(0x00FF00FF00FF00FFL, 0x0F0F0F0F0F0F0F0FL));
        p("LNebulaDexWide;->xorL(JJ)J", NebulaDexWide.xorL(0x00FF00FF00FF00FFL, 0x0F0F0F0F0F0F0F0FL));
        p("LNebulaDexWide;->shlL(JI)J", NebulaDexWide.shlL(1L, 40));
        p("LNebulaDexWide;->shrL(JI)J", NebulaDexWide.shrL(-16L, 2));
        p("LNebulaDexWide;->ushrL(JI)J", NebulaDexWide.ushrL(-16L, 2));
        p("LNebulaDexWide;->cmpL(JJ)I", NebulaDexWide.cmpL(3L, 9L));
        p("LNebulaDexWide;->cmpL(JJ)I", NebulaDexWide.cmpL(9L, 3L));
        p("LNebulaDexWide;->cmpL(JJ)I", NebulaDexWide.cmpL(5L, 5L));
        p("LNebulaDexWide;->widen(I)J", NebulaDexWide.widen(-7));
        p("LNebulaDexWide;->narrow(J)I", NebulaDexWide.narrow(0x1122334455667788L));
        p("LNebulaDexWide;->wideHigh16()J", NebulaDexWide.wideHigh16());

        // ---------- NebulaDexFloat：浮点二元 / 2addr / neg / 转换 / cmp ----------
        p("LNebulaDexFloat;->addF(FF)F", NebulaDexFloat.addF(Float.intBitsToFloat(1069547520), Float.intBitsToFloat(1074790400)));
        p("LNebulaDexFloat;->subF(FF)F", NebulaDexFloat.subF(Float.intBitsToFloat(1069547520), Float.intBitsToFloat(1074790400)));
        p("LNebulaDexFloat;->mulF(FF)F", NebulaDexFloat.mulF(Float.intBitsToFloat(-1067450368), Float.intBitsToFloat(1073741824)));
        p("LNebulaDexFloat;->divF(FF)F", NebulaDexFloat.divF(Float.intBitsToFloat(1065353216), Float.intBitsToFloat(0)));
        p("LNebulaDexFloat;->divF(FF)F", NebulaDexFloat.divF(Float.intBitsToFloat(0), Float.intBitsToFloat(0)));
        p("LNebulaDexFloat;->divF(FF)F", NebulaDexFloat.divF(Float.intBitsToFloat(-1082130432), Float.intBitsToFloat(0)));
        p("LNebulaDexFloat;->remF(FF)F", NebulaDexFloat.remF(Float.intBitsToFloat(-1058013184), Float.intBitsToFloat(1073741824)));
        p("LNebulaDexFloat;->remF(FF)F", NebulaDexFloat.remF(Float.intBitsToFloat(1089470464), Float.intBitsToFloat(0)));
        p("LNebulaDexFloat;->addF(FF)F", NebulaDexFloat.addF(Float.intBitsToFloat(2139095039), Float.intBitsToFloat(2139095039)));
        p("LNebulaDexFloat;->addD(DD)D", NebulaDexFloat.addD(Double.longBitsToDouble(4609434218613702656L), Double.longBitsToDouble(4612248968380809216L)));
        p("LNebulaDexFloat;->subD(DD)D", NebulaDexFloat.subD(Double.longBitsToDouble(-4620693217682128896L), Double.longBitsToDouble(4598175219545276416L)));
        p("LNebulaDexFloat;->mulD(DD)D", NebulaDexFloat.mulD(Double.longBitsToDouble(-4608308318706860032L), Double.longBitsToDouble(4611686018427387904L)));
        p("LNebulaDexFloat;->divD(DD)D", NebulaDexFloat.divD(Double.longBitsToDouble(4607182418800017408L), Double.longBitsToDouble(0L)));
        p("LNebulaDexFloat;->divD(DD)D", NebulaDexFloat.divD(Double.longBitsToDouble(-4616189618054758400L), Double.longBitsToDouble(0L)));
        p("LNebulaDexFloat;->remD(DD)D", NebulaDexFloat.remD(Double.longBitsToDouble(4620130267728707584L), Double.longBitsToDouble(-4611686018427387904L)));
        p("LNebulaDexFloat;->remD(DD)D", NebulaDexFloat.remD(Double.longBitsToDouble(4620130267728707584L), Double.longBitsToDouble(0L)));
        p("LNebulaDexFloat;->addD(DD)D", NebulaDexFloat.addD(Double.longBitsToDouble(9218868437227405311L), Double.longBitsToDouble(9218868437227405311L)));
        p("LNebulaDexFloat;->chainF(FF)F", NebulaDexFloat.chainF(Float.intBitsToFloat(1069547520), Float.intBitsToFloat(1073741824)));
        p("LNebulaDexFloat;->chainF(FF)F", NebulaDexFloat.chainF(Float.intBitsToFloat(-1058013184), Float.intBitsToFloat(1073741824)));
        p("LNebulaDexFloat;->chainD(DD)D", NebulaDexFloat.chainD(Double.longBitsToDouble(4613937818241073152L), Double.longBitsToDouble(4616189618054758400L)));
        p("LNebulaDexFloat;->mixF(FF)F", NebulaDexFloat.mixF(Float.intBitsToFloat(1077936128), Float.intBitsToFloat(1073741824)));
        p("LNebulaDexFloat;->mixF(FF)F", NebulaDexFloat.mixF(Float.intBitsToFloat(-1058013184), Float.intBitsToFloat(1073741824)));
        p("LNebulaDexFloat;->mixD(DD)D", NebulaDexFloat.mixD(Double.longBitsToDouble(4613937818241073152L), Double.longBitsToDouble(4611686018427387904L)));
        p("LNebulaDexFloat;->mixD(DD)D", NebulaDexFloat.mixD(Double.longBitsToDouble(4609434218613702656L), Double.longBitsToDouble(4602678819172646912L)));
        p("LNebulaDexFloat;->negF(F)F", NebulaDexFloat.negF(Float.intBitsToFloat(-1071644672)));
        p("LNebulaDexFloat;->negF(F)F", NebulaDexFloat.negF(Float.intBitsToFloat(2143289344)));
        p("LNebulaDexFloat;->negD(D)D", NebulaDexFloat.negD(Double.longBitsToDouble(4614500768194494464L)));
        p("LNebulaDexFloat;->negD(D)D", NebulaDexFloat.negD(Double.longBitsToDouble(-9223372036854775808L)));
        p("LNebulaDexFloat;->i2f(I)F", NebulaDexFloat.i2f(16777217));
        p("LNebulaDexFloat;->i2f(I)F", NebulaDexFloat.i2f(-2147483648));
        p("LNebulaDexFloat;->i2d(I)D", NebulaDexFloat.i2d(-2147483648));
        p("LNebulaDexFloat;->l2f(J)F", NebulaDexFloat.l2f(1234567890123456789L));
        p("LNebulaDexFloat;->l2d(J)D", NebulaDexFloat.l2d(-9223372036854775808L));
        p("LNebulaDexFloat;->f2i(F)I", (long) (NebulaDexFloat.f2i(Float.intBitsToFloat(1082088489))));
        p("LNebulaDexFloat;->f2i(F)I", (long) (NebulaDexFloat.f2i(Float.intBitsToFloat(2143289344))));
        p("LNebulaDexFloat;->f2i(F)I", (long) (NebulaDexFloat.f2i(Float.intBitsToFloat(1621981420))));
        p("LNebulaDexFloat;->f2i(F)I", (long) (NebulaDexFloat.f2i(Float.intBitsToFloat(-525502228))));
        p("LNebulaDexFloat;->f2l(F)J", NebulaDexFloat.f2l(Float.intBitsToFloat(1621981420)));
        p("LNebulaDexFloat;->f2l(F)J", NebulaDexFloat.f2l(Float.intBitsToFloat(-525502228)));
        p("LNebulaDexFloat;->f2l(F)J", NebulaDexFloat.f2l(Float.intBitsToFloat(2143289344)));
        p("LNebulaDexFloat;->f2d(F)D", NebulaDexFloat.f2d(Float.intBitsToFloat(1069547520)));
        p("LNebulaDexFloat;->d2i(D)I", (long) (NebulaDexFloat.d2i(Double.longBitsToDouble(4613262278296967578L))));
        p("LNebulaDexFloat;->d2i(D)I", (long) (NebulaDexFloat.d2i(Double.longBitsToDouble(9221120237041090560L))));
        p("LNebulaDexFloat;->d2i(D)I", (long) (NebulaDexFloat.d2i(Double.longBitsToDouble(-4472713992753643520L))));
        p("LNebulaDexFloat;->d2l(D)J", NebulaDexFloat.d2l(Double.longBitsToDouble(4906019910204099648L)));
        p("LNebulaDexFloat;->d2l(D)J", NebulaDexFloat.d2l(Double.longBitsToDouble(9221120237041090560L)));
        p("LNebulaDexFloat;->d2f(D)F", NebulaDexFloat.d2f(Double.longBitsToDouble(9094988921128908188L)));
        p("LNebulaDexFloat;->d2f(D)F", NebulaDexFloat.d2f(Double.longBitsToDouble(4609434218613702656L)));
        p("LNebulaDexFloat;->lessF(FF)I", (long) (NebulaDexFloat.lessF(Float.intBitsToFloat(1065353216), Float.intBitsToFloat(1073741824))));
        p("LNebulaDexFloat;->lessF(FF)I", (long) (NebulaDexFloat.lessF(Float.intBitsToFloat(1073741824), Float.intBitsToFloat(1065353216))));
        p("LNebulaDexFloat;->lessF(FF)I", (long) (NebulaDexFloat.lessF(Float.intBitsToFloat(2143289344), Float.intBitsToFloat(1065353216))));
        p("LNebulaDexFloat;->greaterF(FF)I", (long) (NebulaDexFloat.greaterF(Float.intBitsToFloat(1073741824), Float.intBitsToFloat(1065353216))));
        p("LNebulaDexFloat;->greaterF(FF)I", (long) (NebulaDexFloat.greaterF(Float.intBitsToFloat(1065353216), Float.intBitsToFloat(1073741824))));
        p("LNebulaDexFloat;->greaterF(FF)I", (long) (NebulaDexFloat.greaterF(Float.intBitsToFloat(2143289344), Float.intBitsToFloat(1065353216))));
        p("LNebulaDexFloat;->lessD(DD)I", (long) (NebulaDexFloat.lessD(Double.longBitsToDouble(4607182418800017408L), Double.longBitsToDouble(4611686018427387904L))));
        p("LNebulaDexFloat;->lessD(DD)I", (long) (NebulaDexFloat.lessD(Double.longBitsToDouble(9221120237041090560L), Double.longBitsToDouble(4607182418800017408L))));
        p("LNebulaDexFloat;->greaterD(DD)I", (long) (NebulaDexFloat.greaterD(Double.longBitsToDouble(4611686018427387904L), Double.longBitsToDouble(4607182418800017408L))));
        p("LNebulaDexFloat;->greaterD(DD)I", (long) (NebulaDexFloat.greaterD(Double.longBitsToDouble(4607182418800017408L), Double.longBitsToDouble(9221120237041090560L))));

        // ---------- NebulaDexVirtual：虚方法分派（覆写 / invoke-super / 接口） ----------
        p("LNebulaDexVirtual;->polySquareArea(I)I", NebulaDexVirtual.polySquareArea(6));
        p("LNebulaDexVirtual;->polyCubeDescribe(I)I", NebulaDexVirtual.polyCubeDescribe(3));
        p("LNebulaDexVirtual;->cubeSuperArea(I)I", NebulaDexVirtual.cubeSuperArea(3));
        p("LNebulaDexVirtual;->baseDescribe(I)I", NebulaDexVirtual.baseDescribe(4));
        p("LNebulaDexVirtual;->ifaceCount(I)I", NebulaDexVirtual.ifaceCount(5));
        p("LNebulaDexVirtual;->mixed(I)I", NebulaDexVirtual.mixed(7));

        // ---------- NebulaDexThrow：异常模型（try / catch / finally / 跨帧） ----------
        p("LNebulaDexThrow;->catchArith(II)I", NebulaDexThrow.catchArith(9, 3));
        p("LNebulaDexThrow;->catchArith(II)I", NebulaDexThrow.catchArith(9, 0));
        p("LNebulaDexThrow;->nullArrayLength()I", NebulaDexThrow.nullArrayLength());
        p("LNebulaDexThrow;->outOfRange(I)I", NebulaDexThrow.outOfRange(1));
        p("LNebulaDexThrow;->outOfRange(I)I", NebulaDexThrow.outOfRange(5));
        p("LNebulaDexThrow;->catchExact()I", NebulaDexThrow.catchExact());
        p("LNebulaDexThrow;->catchSuper()I", NebulaDexThrow.catchSuper());
        p("LNebulaDexThrow;->catchOrdered()I", NebulaDexThrow.catchOrdered());
        p("LNebulaDexThrow;->finallyNormal()I", NebulaDexThrow.finallyNormal());
        p("LNebulaDexThrow;->finallyOnThrow()I", NebulaDexThrow.finallyOnThrow());
        p("LNebulaDexThrow;->finallyCount()I", NebulaDexThrow.finallyCount());
        p("LNebulaDexThrow;->crossFrame()I", NebulaDexThrow.crossFrame());
        p("LNebulaDexThrow;->catchType()I", NebulaDexThrow.catchType());
        p("LNebulaDexThrow;->crossFrameFinally()I", NebulaDexThrow.crossFrameFinally());

        // 顶层未捕获：JVM 侧同样以异常终止，期望行固定为 <ERROR>（与解释器 expectError 口径一致）
        try {
            p("LNebulaDexThrow;->uncaught()I", NebulaDexThrow.uncaught());
        } catch (Throwable t) {
            System.out.println("LNebulaDexThrow;->uncaught()I=<ERROR>");
        }
    }
}
