// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// DEX 控制流 / 数组 / 字段 / 调用验证样本
// 供 dex-smoke 验证 code_item 提取、try/catch 之外的常规流程与跨方法派发。

class NebulaDexFlow {

    static int field = 5;

    /** 循环：验证 goto / if-lt / add-int 组合与回边 pc 计算 */
    static int loop(int n) {
        int s = 0;
        for (int i = 0; i < n; i++) {
            s += i;
        }
        return s;
    }

    /** 多分支：验证 if-gtz / if-ltz / if-eqz 与常量返回 */
    static int branch(int a) {
        if (a > 0) return 1;
        if (a < 0) return -1;
        return 0;
    }

    /** packed-switch：验证变长 31t 指令的 pc 基准（相对当前指令，不是下一条） */
    static int packed(int x) {
        switch (x) {
            case 0: return 10;
            case 1: return 20;
            case 2: return 30;
            default: return -1;
        }
    }

    /** 数组：验证 aget / array-length 与对象头之外的内存访问路径 */
    static int arr(int[] a) {
        return a[0] + a.length;
    }

    /** 静态字段：验证 sget / sput */
    static int bump() {
        field = field + 1;
        return field;
    }

    /** 跨方法调用：验证 invoke-static 的 method 索引解析 */
    static int call(int x) {
        return NebulaDexProbe.addI(x, field);
    }

    /** 字符串拼接：验证 invoke-static 与 const-string 的联用 */
    static String cat(String a, String b) {
        return a + b;
    }
}
