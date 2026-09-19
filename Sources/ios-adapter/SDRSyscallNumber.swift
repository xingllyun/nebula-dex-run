/*
Copyright © 2026 星云云络科技 (Xingyun Cloud Tech)
Project: NebulaDex - iOS APK Runtime

Licensed under the MIT License (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://opensource.org/licenses/MIT

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import Foundation

/// Linux/AArch64（Android arm64-v8a）系统调用号。
///
/// Android 的 SO 在 `svc #0` 前把系统调用号放进 x8，编号与 Linux 内核 ABI 一致，
/// 因此代理层的分派键必须是**真实号**。此前使用的 0x1001 一类自增号仅是占位，
/// 无法承载真实 SO，现统一改为真实号并在表中显式声明。
///
/// 说明：只覆盖 AArch64。ARM32（armeabi-v7a）号表与 AArch64 差异较大，
/// 待解释器补 ARM32 执行单元后另行建表，当前不做混用。
public enum SDRSyscallNumber {

    // MARK: - 文件与目录

    public static let faccessat: UInt32 = 48
    public static let openat: UInt32 = 56
    public static let close: UInt32 = 57
    public static let getdents64: UInt32 = 61
    public static let lseek: UInt32 = 62
    public static let read: UInt32 = 63
    public static let write: UInt32 = 64
    public static let readv: UInt32 = 65
    public static let writev: UInt32 = 66
    public static let pread64: UInt32 = 67
    public static let pwrite64: UInt32 = 68
    public static let readlinkat: UInt32 = 78
    public static let newfstatat: UInt32 = 79
    public static let fstat: UInt32 = 80
    public static let fsync: UInt32 = 82
    public static let fdatasync: UInt32 = 83
    public static let ftruncate: UInt32 = 46
    public static let mkdirat: UInt32 = 34
    public static let unlinkat: UInt32 = 35
    public static let statx: UInt32 = 291

    // MARK: - 内存

    public static let brk: UInt32 = 214
    public static let munmap: UInt32 = 215
    public static let mremap: UInt32 = 216
    public static let mmap: UInt32 = 222
    public static let mprotect: UInt32 = 226
    public static let msync: UInt32 = 227
    public static let mlock: UInt32 = 228
    public static let munlock: UInt32 = 229
    public static let madvise: UInt32 = 233

    // MARK: - 进程与线程

    public static let getpid: UInt32 = 172
    public static let getppid: UInt32 = 173
    public static let getuid: UInt32 = 174
    public static let geteuid: UInt32 = 175
    public static let getgid: UInt32 = 176
    public static let getegid: UInt32 = 177
    public static let gettid: UInt32 = 178
    public static let set_tid_address: UInt32 = 96
    public static let set_robust_list: UInt32 = 99
    public static let rt_sigaction: UInt32 = 134
    public static let rt_sigprocmask: UInt32 = 135
    public static let rt_sigreturn: UInt32 = 139
    public static let tgkill: UInt32 = 131
    public static let futex: UInt32 = 98
    public static let sched_yield: UInt32 = 124
    public static let prctl: UInt32 = 167
    public static let prlimit64: UInt32 = 261
    public static let exit: UInt32 = 93
    public static let exit_group: UInt32 = 94
    public static let wait4: UInt32 = 260

    // MARK: - 时间

    public static let clock_gettime: UInt32 = 113
    public static let clock_getres: UInt32 = 114
    public static let clock_nanosleep: UInt32 = 115
    public static let gettimeofday: UInt32 = 169
    public static let nanosleep: UInt32 = 101

    // MARK: - 设备与杂项

    public static let ioctl: UInt32 = 29
    public static let uname: UInt32 = 160
    public static let getrandom: UInt32 = 278
    public static let memfd_create: UInt32 = 279
    public static let epoll_create1: UInt32 = 20
    public static let epoll_ctl: UInt32 = 21
    public static let eventfd2: UInt32 = 19
    public static let pipe2: UInt32 = 59
    public static let dup: UInt32 = 23
    public static let fcntl: UInt32 = 25

    // MARK: - 常用常量

    /// 打开位置的相对基准（`openat` 的 dirfd 取该值表示按当前工作目录解析）
    public static let atFdcwd: Int32 = -100

    public enum OpenFlag {
        public static let rdonly: Int32 = 0
        public static let wronly: Int32 = 1
        public static let rdwr: Int32 = 2
        public static let creat: Int32 = 0x40
        public static let excl: Int32 = 0x80
        public static let trunc: Int32 = 0x200
        public static let append: Int32 = 0x400
        public static let nonblock: Int32 = 0x800
        public static let directory: Int32 = 0x10000
        public static let cloexec: Int32 = 0x80000
    }

    public enum SeekWhence: Int32 {
        case set = 0
        case cur = 1
        case end = 2
    }

    public enum MMapProt {
        public static let none: Int32 = 0
        public static let read: Int32 = 1
        public static let write: Int32 = 2
        public static let exec: Int32 = 4
    }

    public enum MMapFlag {
        public static let shared: Int32 = 0x01
        public static let `private`: Int32 = 0x02
        public static let fixed: Int32 = 0x10
        public static let anonymous: Int32 = 0x20
    }

    /// Linux 通用错误码（与 Android bionic 一致）
    public enum Errno {
        public static let eperm: Int32 = 1
        public static let enoent: Int32 = 2
        public static let eintr: Int32 = 4
        public static let eio: Int32 = 5
        public static let ebadf: Int32 = 9
        public static let echild: Int32 = 10
        public static let eagain: Int32 = 11
        public static let enomem: Int32 = 12
        public static let eacces: Int32 = 13
        public static let efault: Int32 = 14
        public static let eexist: Int32 = 17
        public static let enotdir: Int32 = 20
        public static let eisdir: Int32 = 21
        public static let einval: Int32 = 22
        public static let emfile: Int32 = 24
        public static let enotty: Int32 = 25
        public static let enospc: Int32 = 28
        public static let espipe: Int32 = 29
        public static let erofs: Int32 = 30
        public static let epipe: Int32 = 32
        public static let erange: Int32 = 34
        public static let enosys: Int32 = 38
        public static let enametoolong: Int32 = 36
        public static let enotempty: Int32 = 39
        public static let eloop: Int32 = 40
        public static let eopnotsupp: Int32 = 95
    }

    /// AArch64 页大小（软件内存模型的最小映射粒度）
    public static let pageSize: UInt64 = 4096

    /// 把 Linux 风格的负数返回值解码为 errno 文本，便于日志与故障定位
    public static func errnoText(_ raw: Int64) -> String {
        switch raw {
        case 0: return "OK"
        case -1: return "EPERM"
        case -2: return "ENOENT"
        case -4: return "EINTR"
        case -5: return "EIO"
        case -9: return "EBADF"
        case -11: return "EAGAIN"
        case -12: return "ENOMEM"
        case -13: return "EACCES"
        case -14: return "EFAULT"
        case -17: return "EEXIST"
        case -21: return "EISDIR"
        case -22: return "EINVAL"
        case -25: return "ENOTTY"
        case -28: return "ENOSPC"
        case -29: return "ESPIPE"
        case -34: return "ERANGE"
        case -38: return "ENOSYS"
        case -95: return "EOPNOTSUPP"
        default: return "unknown(\(raw))"
        }
    }
}
