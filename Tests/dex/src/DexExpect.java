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
    }
}
