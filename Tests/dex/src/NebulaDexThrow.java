// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// DEX 异常模型验证样本（try / catch / finally / move-exception / 跨帧传播 / 类型判定）
// 由 CI 使用 d8 编译为 classes.dex，供 dex-smoke 与 JVM 原生输出逐行对拍。
// 采样原则：每个方法只承载一族异常语义，方法名即语义标签，便于按方法定位失败点；
//           返回值用 4 位段码区分「哪个 catch 分支被命中」，避免依赖异常对象自身的可变状态。

public class NebulaDexThrow {

    /** finally 真实执行计数：跨用例累积，用于验证 finally 不是被静默跳过 */
    static int finallyCount = 0;

    /** 自定义异常基类（继承 RuntimeException，验证内建层次兜底） */
    public static class NebulaDexError extends RuntimeException {
    }

    /** 自定义异常子类（验证 class_defs 父类链上行匹配） */
    public static class NebulaDexSubError extends NebulaDexError {
    }

    // ---------- 显式异常：精确类型捕获 ----------

    /** try 正常路径：不发生异常，返回 try 分支段码 */
    public static int catchArith(int a, int b) {
        try {
            return 1000 + (a / b);
        } catch (ArithmeticException e) {
            return 2000;
        }
    }

    /** 自定义异常精确捕获：new + throw + move-exception */
    public static int catchExact() {
        try {
            throw new NebulaDexError();
        } catch (NebulaDexError e) {
            return 5000;
        }
    }

    // ---------- 隐式异常：虚拟机内抛点 ----------

    /** 隐式 NPE：null 数组取 length */
    public static int nullArrayLength() {
        int[] arr = null;
        try {
            return arr.length;
        } catch (NullPointerException e) {
            return 3000;
        }
    }

    /** 隐式越界：数组读越界，catch 分支带回下标便于定位 */
    public static int outOfRange(int index) {
        int[] arr = new int[3];
        try {
            return arr[index];
        } catch (ArrayIndexOutOfBoundsException e) {
            return 4000 + index;
        }
    }

    // ---------- 类型匹配：父类上行与多 catch 顺序 ----------

    /** 子类对象被父类型 catch 捕获（类层次上行） */
    public static int catchSuper() {
        try {
            throw new NebulaDexSubError();
        } catch (RuntimeException e) {
            return 6000;
        }
    }

    /** 多 catch 顺序敏感：子类分支在前必须优先命中 */
    public static int catchOrdered() {
        try {
            throw new NebulaDexSubError();
        } catch (NebulaDexSubError e) {
            return 7000;
        } catch (NebulaDexError e) {
            return 8000;
        }
    }

    /** move-exception 取回的句柄需保留对象身份：instance-of 判定子类型 */
    public static int catchType() {
        try {
            throw new NebulaDexSubError();
        } catch (NebulaDexError e) {
            return (e instanceof NebulaDexSubError) ? 13000 : 14000;
        }
    }

    // ---------- finally 语义 ----------

    /** finally 正常路径：finally 必须执行并返回 try 值 */
    public static int finallyNormal() {
        try {
            return 9000;
        } finally {
            finallyCount += 1;
        }
    }

    /** finally 异常路径：catch 返回前 finally 必须执行 */
    public static int finallyOnThrow() {
        try {
            throw new NebulaDexError();
        } catch (NebulaDexError e) {
            return 10000;
        } finally {
            finallyCount += 1;
        }
    }

    /** 读取 finally 执行次数（验证上面两次 finally 真实落地） */
    public static int finallyCount() {
        return finallyCount;
    }

    // ---------- 跨帧传播 ----------

    /** 抛出者：本帧无 try，异常必须向调用帧冒泡 */
    static void thrower() {
        throw new NebulaDexError();
    }

    /** 调用帧捕获：跨帧异常传播（冒泡到上层 do-catch 再匹配） */
    public static int crossFrame() {
        try {
            thrower();
            return 11000;
        } catch (NebulaDexError e) {
            return 12000;
        }
    }

    /** 无 catch 但有 finally：异常经 finally 后继续向调用帧冒泡 */
    static int rethrowWithFinally() {
        try {
            throw new NebulaDexError();
        } finally {
            finallyCount += 1;
        }
    }

    public static int crossFrameFinally() {
        try {
            rethrowWithFinally();
            return 15000;
        } catch (NebulaDexError e) {
            return 16000;
        }
    }

    // ---------- 顶层未捕获 ----------

    /** 顶层未捕获：JVM 与解释器均应以异常终止（期望值 <ERROR>） */
    public static int uncaught() {
        throw new NebulaDexError();
    }
}
