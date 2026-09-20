// Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
// Copyright © 2026 Xingyun Cloud Tech | NebulaDex Project | Released under the MIT License
//
// DEX 虚方法分派验证样本（invoke-virtual / invoke-interface / invoke-super / 类层次覆写）
// 由 CI 使用 d8 编译为 classes.dex，供 dex-smoke 与 JVM 原生输出逐行对拍。
// 采样原则：入口方法一律 static（由 cases.json 驱动），对象在方法体内 new 出来，
//           使「receiver 实际类型 → 覆写方法体」这条链路成为唯一的变量来源；
//           返回值全部为 int 段码，便于按方法定位失败点。
//
// 覆盖点：
//   1. 基类引用指向子类实例（Shape s = new Square(...)）→ 必须执行 Square.area
//   2. 基类方法体内部的虚调用（describe 内调 area/tag）→ this 的实际类型同样生效
//   3. invoke-super（Cube.area 内 super.area()）→ 必须执行 Square.area，不得再向上或向下滑
//   4. 接口分派（Counter c = new Twice(...)）→ invoke-interface 命中实现类方法
//   5. 同一调用点先后接收两类 receiver（mixed）→ 索引缓存必须按实际类型分桶

public class NebulaDexVirtual {

    static class Shape {
        int base;

        Shape(int b) {
            this.base = b;
        }

        int area() {
            return base * 2;
        }

        int tag() {
            return 1;
        }

        /** 基类方法体内的两次虚调用：均应按 this 的实际类型分派 */
        int describe() {
            return area() + tag();
        }
    }

    static class Square extends Shape {
        Square(int b) {
            super(b);
        }

        @Override
        int area() {
            return base * base;
        }

        @Override
        int tag() {
            return 2;
        }
    }

    static class Cube extends Square {
        Cube(int b) {
            super(b);
        }

        /** invoke-super：固定调用 Square.area，与 receiver 的实际类型无关 */
        @Override
        int area() {
            return super.area() * base;
        }

        @Override
        int tag() {
            return 3;
        }
    }

    interface Counter {
        int count();
    }

    static class Twice implements Counter {
        int n;

        Twice(int n) {
            this.n = n;
        }

        @Override
        public int count() {
            return n * 2;
        }
    }

    // ---------- 对拍入口（全 static） ----------

    /** 基类引用 → 子类实例：Square.area = n * n */
    public static int polySquareArea(int n) {
        Shape s = new Square(n);
        return s.area();
    }

    /** 基类方法体内虚调用：Cube.area + Cube.tag = n^3 + 3 */
    public static int polyCubeDescribe(int n) {
        Shape s = new Cube(n);
        return s.describe();
    }

    /** invoke-super：Cube.area = Square.area * n */
    public static int cubeSuperArea(int n) {
        Shape s = new Cube(n);
        return s.area();
    }

    /** 无覆写：Shape.describe = n * 2 + 1 */
    public static int baseDescribe(int n) {
        Shape s = new Shape(n);
        return s.describe();
    }

    /** 接口分派：Twice.count = n * 2 */
    public static int ifaceCount(int n) {
        Counter c = new Twice(n);
        return c.count();
    }

    /** 同一调用点两种 receiver：a 走 Shape 实现、b 走 Cube 实现 */
    public static int mixed(int n) {
        Shape a = new Shape(n);
        Shape b = new Cube(n);
        return a.describe() + b.describe();
    }
}
