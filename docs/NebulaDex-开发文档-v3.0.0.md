# NebulaDex 开发文档 v3.0.0

> 文档归属：星云云络科技 ｜ 项目：NebulaDex（星云 Dex，仓库 nebula-dex-run）
> 说明：本文件为 docx 版开发文档的纯文本镜像，排版以 docx 原稿为准。

```text
NebulaDex 开发文档（V2 详细版）
文档归属：星云云络科技
项目
内容
项目名称
NebulaDex（星云 Dex）
仓库名称
nebula-dex-run（单仓库）
文档版本
v2.0.0
更新日期
2026-09-17
适用平台
iOS（侧载安装）
核心能力
iOS 上运行 Android APK：APK 解析、DEX 字节码解释执行、SO 原生库加载（32/64 位）、安卓 API/Java 调用映射、可显示的应用界面、云打包自动发布
本版相对 v1 的重点修订：① 说清应用界面“靠什么方式显示”（渲染管线），解决“只有启动页、不显示界面”的问题；② 扩写 SO 库兼容（ELF 加载细节、32/64 位差异、诊断表）；③ 扩写 安卓 API / Java 调用；④ 重写 APK 签名（v1/v2/v3、重签流程、常见故障修复）；⑤ 增加 后台持久化 / 每应用独立目录 / 实时日志 / 赞赏码 章节。
1. 平台与系统适配
项
要求
最低系统
iOS 16.0（IPHONEOS_DEPLOYMENT_TARGET = 16.0）
适配范围
iOS 16.0 ~ 26.x（iOS 27 以下），当前明确不做 iOS 27 适配
优先适配
开发者本人设备：iOS 26、大屏 + 大存储空间机型
设备类型
iPhone + iPad（TARGETED_DEVICE_FAMILY = "1,2"）
安装方式
侧载：无签名 IPA + 全能签/轻松签重签
证书要求
大内存（increased-memory-limit）+ 大地址空间（extended-virtual-addressing）权限，否则渲染缓冲与 SO 内存分配会失败（表现为黑屏/闪退）
2. UI：页面结构与“显示靠什么方式显示”（核心章节）
2.1 页面清单（共 6 页 + 顶栏）
页面
文件
职责
应用列表页
RunStateView.swift
已安装 APK 列表、导入 APK、运行入口、各应用占用空间
运行显示页
AppDisplayView.swift（新增）
加载中 / 运行中 / 错误 三态合一，承载安卓应用的实际画面（核心页面，见 2.3）
签名工具页
SignToolView.swift
导入 APK → 选择/生成证书 → 重签名 → 导出
日志页
LogView.swift / LogStore.swift
实时日志查看（见第 11 章）
设置页
SettingsView.swift
沙盒管理、网络、数据清理、刷新率（30/60/120）、赞赏入口等
关于页
AboutView.swift
版本号、文档、开源协议、赞赏码
自定义顶栏
NebulaDexTopBar.swift
自绘状态行 + 大标题 + 分隔线，隐藏系统导航栏，五页复用
2.2 核心结论：应用界面是靠“渲染管线”显示的
安卓应用窗口不是模拟出来的假窗口，而是把安卓 View 树真正画到 iOS 屏幕上的。 完整链路如下：
APK 启动  → 解释器执行 Activity 代码（setContentView / LayoutInflater）  → 生成 View 树（内存对象：TextView、Button、ImageView…）  → 解释器调用 onMeasure / onLayout / onDraw  → onDraw 里的 Canvas 绘制指令被逐条解释执行      ├─ 路径 A（位图缓冲）：指令绘制进 CGBitmapContext 位图      │     → 整帧或“脏矩形”区域转成 UIImage/CALayer 内容      │     → 挂到运行显示页的 UIImageView 上，主线程刷新      └─ 路径 B（原生控件映射）：常见控件直接创建 UIKit 控件            TextView  → UILabel            Button    → UIButton            ImageView → UIImageView            EditText  → UITextField/UITextView            ScrollView→ UIScrollView            ListView  → UITableView            → 直接放进 iOS 视图层级，事件走 UIKit  → 触摸事件：iOS 层 hitTest → 坐标转换 → 派发 onTouchEvent 到对应 View  → 帧刷新：CADisplayLink 按设置页所选刷新率（30 / 60 / 120）驱动，脏矩形局部重绘，后台暂停渲染
两条路径的选择策略（混合模式）：
路径
适用
优点
代价
原生控件映射（路径 B）
常用标准控件、可滚动列表
交互流畅、文字可选中、性能好
需逐个控件实现映射，覆盖不全
位图缓冲（路径 A）
自定义 View、Canvas 绘制、图表、游戏画面
覆盖任意绘制代码，通用兜底
帧率受限、内存占用高
实现原则：优先路径 B，未覆盖的一律回退路径 A；同一个 View 树可以混合（外层容器用位图、内层列表用 UITableView 等）。
2.3 运行显示页三态（加载页与显示页合并）
运行显示页是一个容器，内部按状态切换内容，用户从“导入 APK”到“看到界面”之间不再有黑屏：
状态
界面内容
触发
退出条件
加载中
进度指示 + 步骤文案（解析中 → 校验中 → 沙盒装载中 → 启动中）
点击运行 / 导入 APK
首帧渲染成功
运行中
渲染管线挂载的 UIImageView / UIKit 控件层（真正的安卓界面）
首帧提交
应用退出 / 崩溃
错误
错误图标 + 可读原因 + “查看日志 / 重试”按钮
加载或运行失败
用户操作
状态切换由 AppState 驱动，加载步骤日志同步写入实时日志（第 11 章），失败时用户能直接看到是哪一步挂的。
2.4 “启动后必须显示界面”的自检清单（解决黑屏）
任何 APK 启动后 3 秒内必须出现首帧画面。若黑屏/只有启动页，按下表逐项自检：
序号
检查项
打点/证据
失败原因
1
View 树是否生成
日志输出 onCreate → setContentView → view 树节点数
布局解析失败、Activity 未创建
2
首帧是否绘制完成
帧计数器 frame#1 committed
onDraw 崩溃、绘制指令未解释
3
缓冲是否挂到显示层
renderer attached w=.. h=..
渲染线程未把位图交到主线程
4
内存是否分配成功
entitlement 检测 + 分配结果
大内存 entitlement 未生效 → 分配失败黑屏
5
主线程是否阻塞
主线程卡顿监控
解释器/绘制占用主线程过长
验收标准：以上 5 项全过且 3 秒内出首帧，才算“能显示”。任何一项不满足必须能通过日志页定位。
2.5 刷新率设置（设置页自选 30 / 60 / 120）
项
说明
位置
设置页 → 显示设置 → 刷新率（不在关于页）
选项
30 / 60 / 120，默认 60
作用对象
运行显示页渲染管线的帧驱动（CADisplayLink）
120 档
仅 ProMotion（120Hz）设备生效，非 ProMotion 设备自动封顶 60
60 档
默认档，绝大多数设备流畅
30 档
省电档，位图缓冲模式重绘减半，适合静态界面
低电量
可开启“低电量自动降 30”（设置页开关，默认关）
后台
无论哪一档，进入后台一律暂停渲染
生效方式
切换立即生效，无需重启应用；日志打点 frame rate = 30/60/120
验收
切档后帧计数器显示实际帧率；120 档需在 ProMotion 设备上验证
实现要点：
CADisplayLink.preferredFrameRateRange = CAFrameRateRange(min, max, preferred)  30 → 固定 30 fps；60 → 60；120 → 120（设备不支持自动封顶 60）脏矩形合并按帧间隔节流；位图缓冲路径按所选帧率重绘；原生控件映射路径（列表滚动等）跟随 UIKit 系统帧率，不受此档位限制。
3. SO 库兼容（重点扩写）
3.1 ABI 支持矩阵
ABI 目录
架构
位数
ELF 类别
设备覆盖
armeabi-v7a
ARMv7
32 位
ELFCLASS32
32 位安卓设备、兼容层设备
arm64-v8a
ARMv8
64 位
ELFCLASS64
近 5 年主流机型（必需）
x86
Intel
32 位
ELFCLASS32
调试/模拟器
x86_64
Intel
64 位
ELFCLASS64
调试/模拟器
硬性要求： 1. 所有 APK 内 .so 必须同时具备 armeabi-v7a 与 arm64-v8a 两套（Google Play 64 位要求同理：支持的所有 32 位架构必须配套 64 位）。 2. 发布前真机验证两个架构各跑一遍（见 3.8 验收清单）。 3. 单一架构的 APK：按设备实际架构匹配，匹配不到给明确错误日志，不静默崩溃。
3.2 ELF 解析细节（SDRElfParser）
解析对象
ELF32 字段
ELF64 字段
说明
文件头
Elf32_Ehdr
Elf64_Ehdr
魔数 0x7F &#39;E&#39; &#39;L&#39; &#39;F&#39;、e_class（1=32 位，2=64 位）、e_machine（0x28=ARM，0xB7=AArch64）、数据编码（LSB/MSB）、e_type（2=共享对象）
程序头表
Elf32_Phdr
Elf64_Phdr
PT_LOAD 段（代码段/数据段）、p_vaddr、p_offset、p_filesz、p_memsz、p_flags（R/W/X）
段节（可选）
.text .data .rodata .bss .dynamic .dynsym .dynstr
同左
动态链接必需：.dynamic、.dynsym、.dynstr、.rel.dyn、.rel.plt（32 位）/ .rela.*（64 位）
重定位
REL（Elf32_Rel）
RELA（Elf64_Rela，含 addend）
32 位用 REL 居多，64 位用 RELA，解析时必须区分
校验规则：魔数错误、e_class 不支持、e_machine 不匹配、PT_LOAD 缺失 → 直接拒绝加载并记录错误码（见 3.8）。
3.3 SO 库加载完整流程（SDRSoLoader）
1. 解压 APK，按设备 ABI 选择 lib/<abi>/ 目录2. 读取 .so 文件 → 校验 ELF 头（魔数/类别/机器码）3. 解析程序头表，收集所有 PT_LOAD 段4. 在沙盒内存中分配段空间：   - 代码段（R+X）与数据段（R/W）分开映射   - 执行严格 W^X：可执行内存不可写，可写内存不可执行5. 按 p_vaddr 把段内容拷入内存，bss 段清零6. 解析 .dynamic，定位 .dynsym/.dynstr/重定位表7. 执行重定位（REL/RELA）：本地符号、GOT/PLT、全局偏移8. 符号解析（SDRSymbolResolver）：   - 本 SO 内部符号   - 已加载其他 SO 的导出符号（依赖库）   - JNI 导出函数（Java_ 前缀 / JNI_OnLoad）   - 系统调用桥接（SDRSyscallBridge 白名单）9. 调用构造函数（.init_array / DT_INIT）10. 暴露 JNI 接口给解释器（RegisterNatives）11. 进入沙盒受控执行12. 失败任一环 → 回滚已分配内存 → 报错误码
3.4 架构识别与回退规则
设备 CPU 架构探测（arm64 / armv7 / x86_64 / x86）  → 优先加载与设备一致的 ABI  → 64 位设备（arm64）若没有 arm64-v8a：      可回退加载 armeabi-v7a（32 位库兼容运行）  → 32 位设备：只认 armeabi-v7a  → 都没有 → 报错“缺少当前设备架构的 SO 库（期望 arm64-v8a / armeabi-v7a）”
3.5 32 位 / 64 位差异对照表（SDRElfParser 必须分别处理）
维度
32 位（armeabi-v7a）
64 位（arm64-v8a）
指针宽度
4 字节
8 字节
ELF 头结构
Elf32_Ehdr
Elf64_Ehdr
重定位结构
REL（无 addend，运行时计算）
RELA（带 addend）
重定位类型
R_ARM_*（如 R_ARM_GLOB_DAT、R_ARM_JUMP_SLOT、R_ARM_RELATIVE）
R_AARCH64_*（如 R_AARCH64_GLOB_DAT、R_AARCH64_JUMP_SLOT、R_AARCH64_RELATIVE、R_AARCH64_ABS64）
JNI jlong
4 字节对齐
8 字节对齐
结构体对齐
4 字节
8 字节
调用约定
AAPCS32
AAPCS64（前 8 个参数走寄存器 x0-x7）
页大小
4KB
4KB（AArch64 支持 4KB/16KB/64KB，按实际）
代码里所有 ELF 结构体必须“双套实现 + 按 e_class 分发”，禁止把 32 位结构直接当 64 位读。
3.6 JNI 绑定
绑定方式
说明
静态导出
Java_<包名>_<类名>_<方法名> 命名符号，解释器按命名规则查 .dynsym
动态注册
SO 实现 JNI_OnLoad，调用 RegisterNatives 注册函数表，NebulaDex 提供模拟的 JNIEnv
调用约定
解释器构造 JNI 参数（jobject/jstring/jintArray…）→ 调函数指针 → 回收返回值
3.7 沙盒执行与内存保护
W^X 强制：代码段只读可执行，数据段可写不可执行；任何“写后执行”操作必须经显式内存重映射。
系统调用桥（SDRSyscallBridge）白名单：内存映射（mmap/mprotect）、文件（open/read/write/close/fstat）、时间、随机数、线程基础操作等按白名单放行；网络、socket 走 iOS 能力代理；越权调用直接拦截并记日志。
地址空间：SO 加载在独立地址区域，避免与解释器/UIKit 冲突；大地址空间 entitlement 保证 64 位寻址可用。
3.8 兼容性验收清单与错误诊断表
验收清单： - [ ] armeabi-v7a 与 arm64-v8a 的 .so 在真机各加载成功一次（打点 so loaded abi=arm64-v8a） - [ ] JNI_OnLoad 正常执行，RegisterNatives 注册成功 - [ ] 带 SO 的典型 APK 完整跑通：Java 调用 native 方法 → 返回值正确 - [ ] 缺 ABI 时给出可读错误，不崩溃
错误诊断表：
错误码
现象
原因
处理
SO_ELF_BAD_MAGIC
加载失败
文件损坏/非 ELF
重新解压/检查 APK
SO_ABI_MISMATCH
缺当前架构
APK 只有单一 ABI
换双架构包；64 位设备可回退 32 位
SO_RELOC_FAILED
重定位失败
REL/RELA 解析错误、符号缺失
查 .dynamic；补符号解析
SO_SYMBOL_MISSING
符号缺失
依赖系统库未桥接
在 SyscallBridge/SymbolResolver 补映射
SO_MEM_PROTECT
段权限冲突
W^X 违规
按日志定位代码段/数据段映射
SO_JNI_FAILED
JNI 绑定失败
JNI_OnLoad 未导出/注册失败
检查符号命名与导出表
4. 安卓 API 调用（扩写）
4.1 调用链
DEX 字节码（解释器执行）  → 命中 java.* / android.* API  → SDRNativeBridge 查注册表（类名 + 方法签名）  → framework 层 iOS 实现（视图/存储/网络/多媒体…）  → 结果回传解释器未命中 → 记录日志“API 未支持：<类>.<方法>” → 返回默认值或模拟异常
4.2 API 覆盖矩阵
类别
代表 API
iOS 实现
覆盖情况
组件生命周期
Activity / Service / BroadcastReceiver
SDRAppComponents / SDRAppRuntime
生命周期状态机完整映射
视图
View / ViewGroup / TextView / Button / ImageView / ScrollView / ListView
SDRViewSystem（原生映射 + 位图兜底）
常用控件已覆盖，自定义 View 走位图
资源
Resources / getString / getDrawable / asset
SDRViewSystem + apk-tool 资源解析
字符串/图片/布局资源
存储
SharedPreferences / 内部存储 / SQLite
SDRDataStorage（每应用独立目录，见第 10 章）
完整
网络
HttpURLConnection / URL / Socket / JSON
SDRNetworking（NSURLSession / 原生 socket）
常用完整
多媒体
MediaPlayer / AudioTrack / 相机基础
SDRMultimedia（AVFoundation）
播放/录音基础能力
系统服务
Notification / Vibrator / 系统信息 / PackageManager 简版
SDRSystemServices
通知、设备信息已覆盖
工具类
java.util / java.io / java.text / java.lang.reflect
dex-core 类库支撑（见第 5 章）
常用子集
并发
Thread / Handler / Looper / AsyncTask
解释器线程模型（见 4.4）
基础完整
4.3 生命周期映射表（Activity ↔ iOS）
安卓回调
触发时机
iOS 侧动作
onCreate
应用启动
创建运行时实例、加载布局（生成 View 树）
onStart / onResume
界面可见/获得焦点
运行显示页切到“运行中”、渲染管线启动（CADisplayLink 开）
onPause / onStop
界面失焦/不可见
渲染暂停、状态实时保存（见第 10 章）
onDestroy
应用退出
释放运行时、清理渲染缓冲
onSaveInstanceState
后台/配置变更
写入实时快照，恢复时读取
4.4 线程模型
安卓线程
iOS 映射
说明
主线程（UI）
主队列（Main Queue）
View 操作、绘制、生命周期必须回主线程
Handler/Looper
主队列 + 消息循环模拟
Looper.loop 由解释器在对应线程跑
后台线程
GCD 后台队列
网络/存储耗时操作异步执行，回调回主线程
synchronized
NSLock / os_unfair_lock
Java 同步块映射到 iOS 锁
4.5 不支持 API 的策略
返回“安全默认值”（数字返回 0、对象返回 null、布尔返回 false）；
日志页标记 API_UNSUPPORTED，级别 WARN，可过滤；
需要真实能力的（如相机/定位）由设置页开关控制是否放行。
4.6 实时功能转换至 iOS（重点）
核心结论：APK 里的“实时”机制（实时通知、后台任务、传感器、实时界面刷新、实时状态展示）不能照搬安卓，必须映射到 iOS 原生能力。iOS 对后台执行有严格限制（没有安卓式“无限后台”），映射后的行为与安卓存在差异，本文逐项写明映射关系与限制，避免“安卓能跑、iOS 不跑”的误判。
映射总表（安卓实时能力 → iOS 转换）：
安卓实时能力
iOS 转换实现
限制与差异
NotificationManager 通知
UNUserNotificationCenter 本地通知
需用户授权；侧载环境无 APNs 推送，全部走本地通知
前台服务（持续后台运行）
无等价物：前台正常跑；退后台转 BGTaskScheduler 有限窗口 + 实时活动兜底
iOS 不允许无限后台，退后台后约 30 秒内需收尾或转快照
WorkManager / JobScheduler 定时任务
BGTaskScheduler（BGAppRefreshTask ≈ 30 秒窗口；BGProcessingTask 低活跃期）
执行时机由系统决定，无“保证执行”；周期不得小于 15 分钟
AlarmManager 闹钟
UNCalendarNotificationTrigger / UNTimeIntervalNotificationTrigger
到点弹通知，不唤醒执行代码
实时界面刷新（LiveData / 自绘动画）
渲染管线脏矩形局部重绘 + 刷新率设置（30/60/120，见 2.5）
进入后台暂停渲染
实时状态展示（灵动岛 / 锁屏）
ActivityKit Live Activities（iOS 16.1+）
需工程增加 Widget Extension target；侧载可用 ActivityKit 本地更新
SensorManager 传感器
CoreMotion（加速度计 / 陀螺仪 / 设备运动 / 活动识别）
后台传感器受限，与 iOS 后台策略一致
LocationManager 定位
CoreLocation（前台 / 后台定位分级授权）
后台定位需 location background mode + 用途说明
FCM 推送
本地通知模拟（侧载无推送证书，不接 APNs）
由 NebulaDex 宿主统一转发为本地通知
实现要点：
通知：NebulaDex 首次运行即申请通知权限（UNUserNotificationCenter requestAuthorization）；安卓应用调用 notify() → 桥接层转成本地通知，标题带应用名（如 [应用名] 消息内容），点击可回到该应用运行页。
后台任务：安卓注册的任务（WorkManager / JobScheduler）在桥接层映射为 BGTaskScheduler 注册；系统在空闲窗口唤醒时，执行对应安卓回调；任务必须在窗口内结束（超时由系统终止）。
实时活动（可选增强）：对“倒计时 / 进度 / 状态跟踪”类应用，把运行状态桥接到 ActivityKit Live Activity，在灵动岛 / 锁屏 / 待机显示实时信息（如 APK 内下载进度、计时器）；工程需加 Widget Extension 并在 Info.plist 开启 Supports Live Activities。
传感器 / 定位：设置页权限开关控制（默认关）；打开后映射 CoreMotion / CoreLocation，前台实时回调，后台按 iOS 策略受限。
限制声明：iOS 与安卓后台哲学不同（安卓保证执行、iOS 由系统决定），映射后任务可能被延迟或跳过；文档与设置页均需提示用户，避免误解为故障。
依据：Apple Developer 官方文档（BackgroundTasks、ActivityKit / Live Activities、UserNotifications、CoreLocation / CoreMotion）与移动端后台执行机制对比资料（2026 年更新）。
5. 安卓 Java 调用（扩写）
5.1 Java 执行模型
APK → classes.dex / classesN.dex  → SDRDexParser 解析（头、字符串池、类型池、方法池、代码段）  → SDRClassLoader 按需加载类（懒加载）  → SDRInterpreter 逐条解释字节码（纯解释、无 JIT）      - 指令分派：invoke / new / getfield / putfield / if / goto / return…      - 方法调用栈、局部变量表、操作数栈  → 遇到 native 方法 → 走 JNI 绑定（3.6）→ 原生桥
5.2 支持的 Java 特性
特性
支持度
说明
类/继承/接口
✅
单继承 + 多接口，方法分派表
静态/实例方法
✅
完整
字符串/数组/装箱
✅
String 池、int[]/Object[]、自动装箱
异常处理
✅
try/catch/finally 指令流
反射
部分
Class.forName、getMethod/invoke 常用子集
泛型
✅（运行时擦除）
类型擦除后按 Object 处理
匿名内部类
✅
编译器生成的类照常加载
lambda
✅（desugar 后）
转静态方法 + invokedynamic 兜底
多线程
基础
Thread/Runnable/Handler 可用，锁映射见 4.4
注解
存储级
注解可读取，不参与逻辑
5.3 Java 类库支撑清单（dex-core 内置）
包
已实现类（代表）
java.lang
Object、String、StringBuilder、Math、System、Integer/Long/Boolean、Thread、Exception 体系、Class 基础
java.util
ArrayList、HashMap、HashSet、LinkedList、Date、Random、Collections
java.io
File、InputStream/OutputStream、ByteArrayStream、BufferedReader/Writer
java.net
URL、URLConnection、Socket（映射 iOS 网络）
java.text
SimpleDateFormat、NumberFormat
java.nio
ByteBuffer（基础子集）
android.*
见第 4 章 API 矩阵
5.4 Java ↔ 原生桥衔接
Java 侧的 native 方法声明 → 解释器在方法表标记 native；
调用时按 JNI 命名规则查 SO 导出符号，或查已注册的 JNI 函数表；
参数/返回值按 JNI 类型转换（jstring ↔ NSString、jintArray ↔ NSArray/缓冲）；
异常沿调用栈向上抛，日志页记录原生栈信息。
5.5 常见不兼容点与规避
不兼容点
表现
规避
GC 语义差异
弱引用/SoftReference 行为不同
强引用兜底，文档标注
System.loadLibrary 路径
库路径与安卓不同
统一走 NebulaDex 的 lib 解析
加密/安全 API（如 javax.crypto）
未实现
返回明确错误，推荐换实现
多线程重度并发
锁竞争性能
优化锁映射，日志标记
6. APK 签名（扩写，解决“签名有问题”）
6.1 签名体系
版本
适用安卓
位置
说明
v1（JAR 签名）
Android 7.0 以下
META-INF/MANIFEST.MF + CERT.SF + CERT.RSA
逐个文件摘要
v2
Android 7.0+
APK Signing Block（ZIP 条目间）
整包摘要，防篡改更强
v3
Android 9.0+
APK Signing Block
支持密钥轮换
NebulaDex 需要 识别并校验 v1/v2/v3，重签时默认产出 v1 + v2（兼容最广）。
6.2 签名校验流程（SDRSignatureVerifier）
1. 校验 v1：读 META-INF/MANIFEST.MF（文件→SHA-256 摘要）   → 校验 CERT.SF 签名块 → 校验 CERT.RSA 的 PKCS#7 签名与证书链2. 校验 v2：定位 APK Signing Block（ZIP 尾注释 → Central Directory → 签名块 magic）   → 校验签名块中的摘要与整包内容3. 校验 v3（存在时）：校验轮换密钥链4. 输出：签名者证书指纹、签名算法、有效期、是否可信
6.3 重签名完整流程（SDRApkSigner）
1. 解压 APK 到工作目录2. 删除原 META-INF/*.SF、*.RSA、*.MF3. 生成/加载密钥对（RSA 2048 或 ECC P-256，PKCS#8）4. 遍历文件计算 SHA-256 → 写 MANIFEST.MF5. 签名清单 → CERT.SF（含清单摘要与文件摘要）6. PKCS#7 签名（CERT.RSA / CERT.EC）：签名者证书 + 私钥签名7. 写 v2 签名块：整包哈希 → 构造 APK Signing Block → 插回 ZIP（更新 Central Directory 偏移）8. 重新打包 ZIP（压缩、条目对齐）9. 自校验：用 6.2 流程重跑一遍，必须通过10. 输出重签后 APK
6.4 常见问题与修复（“签名有问题”对照表）
现象
根因
修复
重签后安装报“签名不一致”
只改了 v1 没动 v2，或 v2 块未正确更新
重签必须 v1+v2 一起重做；删干净旧签名块
加固 APK 重签后无法运行
加固壳校验自身签名
先加固检测（SDRHardeningDetector），提示“加固包请先脱壳再重签”
v2 块定位失败
ZIP 尾注释/Central Directory 解析错
严格按 EOCD → CD → APK Signing Block 顺序定位；注意 64 位 ZIP 与 zip64
摘要不匹配
MANIFEST.MF 文件列表与实际不符
重签时全量重建清单，不增量
证书格式错
密钥/证书编码问题
统一 PKCS#8 私钥 + X.509 证书；自签证书有效期 ≥ 重签安装时间
ZIP 对齐问题
未做 4 字节对齐
重打包时对未压缩条目做 alignment
6.5 签名验收标准
☐ 重签 APK 能被 NebulaDex 安装并运行；
☐ SDRApkSigner 自校验通过（v1 + v2）；
☐ 签名页显示：证书指纹、算法、有效期；
☐ 安装失败时给出具体原因（不是笼统报错）。
7. 后台持久化与每应用独立目录（重点扩写）
7.1 沙盒目录结构（每个 APK 一个独立目录）
sandbox/└── apps/    └── <包名>（如 com.example.app）/        ├── files/            # 安卓内部存储（Context.getFilesDir()）        ├── cache/            # 缓存（可清理）        ├── shared_prefs/     # SharedPreferences（.xml 实时落盘）        ├── databases/        # SQLite（WAL 模式）        ├── lib/              # 该应用的 SO 库缓存（可选）        └── state.json        # 运行状态快照（实时更新）
隔离原则：应用 A 无法访问应用 B 的目录（SDRSandboxPermission 校验）；跨应用访问（如 ContentProvider 场景）暂不支持并记录日志。
应用列表页显示每个应用的数据占用，设置页支持“清除单个应用数据”。
7.2 后台不丢数据（App 退出后台后应用文件仍在）
时机
动作
运行中每次状态变更
实时写盘（见 7.3），不攒批
应用进入后台（sceneDidEnterBackground）
立即触发全量快照：SharedPreferences flush、SQLite checkpoint、state.json 落盘
App 被杀
数据已全部落盘，下次启动直接恢复
重新启动 NebulaDex
扫描 sandbox/apps/，恢复已安装应用列表 + 最近打开记录
7.3 实时保存策略（“保存都要实时记录”）
原子写：先写临时文件 → fsync → rename 覆盖，杜绝半截文件；
SharedPreferences：每次 put 立即序列化落盘（可配置 100ms 节流，但退出/后台必须 flush）；
SQLite：开启 WAL，事务提交即持久；后台触发 checkpoint；
运行状态：state.json（当前 Activity、栈、时间戳）每次生命周期切换即更新；
崩溃恢复：启动时检测上次 state.json 与日志，若上次异常退出，恢复最近可用状态并提示。
7.4 重启恢复流程
启动 NebulaDex  → 扫描 sandbox/apps/（恢复已安装应用）  → 读 state.json（恢复“最近打开”）  → 用户点开某应用 → 加载其目录 → 恢复上次运行状态（可选：从上次 Activity 继续）
8. 实时日志（扩写）
8.1 日志架构
各模块写入（解释器 / 加载器 / 原生桥 / UI / 沙盒 / 签名）  → 内存环形缓冲（最近 2000 条，主线程无锁读）  → 实时追加写文件（logs/nebuladex.log，按天滚动）  → NotificationCenter 推送 → 日志页 UI 实时刷新（滚动到底部）
实时性要求：日志写入到日志页可见的延迟 < 200ms；
日志文件保留最近 7 天，设置页可一键导出/分享日志文件（排障必备）。
8.2 分级与字段
级别
用途
DEBUG
解释器指令、绘制打点、加载细节
INFO
生命周期、应用启动/退出、SO 加载成功、签名完成
WARN
API_UNSUPPORTED、ABI 回退、资源缺失
ERROR
加载失败、崩溃、签名失败（带错误码）
每条日志固定字段：时间 | 级别 | 模块 | 应用包名 | 内容。
8.3 日志页功能
实时滚动（新日志自动滚到底）；
过滤：按级别 / 按模块 / 按关键词 / 按应用；
搜索；一键清空；导出日志文件；
错误高亮（ERROR 红、WARN 黄），点击可看详情（含错误码与建议）。
8.4 崩溃日志
解释器/原生桥未捕获异常统一捕获 → 写 ERROR 日志 + 崩溃时间点上下文；
App 级崩溃由 iOS 侧记录到日志文件，下次启动提示“上次异常退出，已恢复”。
9. 赞赏码
项
说明
入口
设置页“赞赏支持”行 + 关于页底部赞赏卡片
展示
微信收款码 / 支付宝收款码两张图片（Assets 中 DonateWechat / DonateAlipay），点击全屏查看、可保存到相册
文案
“如果 NebulaDex 帮到你，欢迎赞赏支持开发～”
配置
图片放 ui/Assets.xcassets/Donate.imageset/，替换即生效；未放图片时自动隐藏入口
隐私
赞赏不收集用户信息，纯本地展示
10. 云打包（保留完整流程）
沿用 .github/workflows/ios-build.yml：
push main / 手动触发 → macos-latest  → checkout → brew install xcodegen → xcodegen generate  → xcodebuild 无签名 Release（CODE_SIGNING_ALLOWED=NO）  → 收集 .app → Payload → NebulaDex-unsigned.ipa  → upload-artifact（30 天）  → softprops/action-gh-release：tag build-N + Release 附 IPA下载 → 全能签/轻松签重签（需大内存+大地址空间证书）→ 安装
注意点：产物名/路径与 PRODUCT_NAME 同步；entitlements 必须被重签工具读取；构建号 build-<run_number> 自动递增。
11. 版本号与发布规范
应用版本：语义化 vX.Y.Z（主.次.修订），写入 ui/Info.plist 的 CFBundleShortVersionString；
构建号：build-<run_number> 自动递增，作为 Release tag；
每次 push main 自动构建 → 自动发布 Release（附 IPA + 提交 SHA + 变更说明）→ 版本号与仓库同步；
发布节奏：日常修复靠 build-N 累积，可交付点提升 vX.Y.Z。
12. 安全与隐私
项
要求
凭据
GitHub Secrets 管理，禁止 token 写入代码/文档/Release；曾泄露的 token 立即吊销
沙盒
应用目录隔离、内存 W^X、系统调用白名单
签名
重签自校验强制开启；加固包先检测
日志
日志文件仅本地保存，导出需用户主动操作
13. 本地开发与调试
brew install xcodegenxcodegen generateopen NebulaDex.xcodeproj   # 真机运行，配合日志页排障
tools 脚本：apk_peek.py（查包名/版本/ABI 列表）、axml_check.py（查 Manifest）。
14. 常见问题 FAQ
问题
解答
启动后只有启动页/黑屏
走 2.4 自检清单，日志页看是第几步挂的
SO 加载失败
查 3.8 错误表；先确认 APK 是否有 arm64-v8a
重签后装不上
查 6.4 表；v1+v2 必须一起重做
后台后数据没了
确认 7.2/7.3 已实现（进入后台立即 flush + 原子写）
日志不实时
确认 NotificationCenter 推送链路（8.1）
15. 附：文档归属与维护
本文档由 星云云络科技 维护，随仓库同步更新；
与 v1 的差异：本版为“可落地实现版”，渲染、签名、持久化、日志均含验收标准；
单仓库结构，后续如需第二个仓库另行新建并在此登记。
```

---

Copyright © 2026 星云云络科技 | NebulaDex 项目 | 基于 MIT 开源协议发布
