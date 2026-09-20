// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// DEX 分支表与迁移指令验证样本
// dense()  触发 packed-switch（31t，变长指令，payload 伪指令需跳过）
// sparse() 触发 sparse-switch 或 if 链回退（取决于 d8 的开关表选择策略）

class NebulaDexSwitch {

    /** 10 个连续 case：d8 倾向生成 packed-switch */
    static int dense(int x) {
        switch (x) {
            case 0: return 100;
            case 1: return 101;
            case 2: return 102;
            case 3: return 103;
            case 4: return 104;
            case 5: return 105;
            case 6: return 106;
            case 7: return 107;
            case 8: return 108;
            case 9: return 109;
            default: return -1;
        }
    }

    /** 稀疏 case：d8 倾向生成 sparse-switch */
    static int sparse(int x) {
        switch (x) {
            case 0: return 1;
            case 100: return 2;
            case 10000: return 3;
            case 1000000: return 4;
            default: return -1;
        }
    }

    /** 长整型迁移与比较：覆盖 int-to-long / long 比较 / long 返回 */
    static long pick(long a, long b) {
        if (a < b) return a;
        return b;
    }
}
