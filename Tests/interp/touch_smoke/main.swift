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

// 触控路由冒烟（阶段四 §4.4）：UIKit 触点流 → Android MotionEvent 合成的离线验收。

var passed = 0
var failed = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        passed += 1
        print("  ok   - \(name)")
    } else {
        failed += 1
        print("  FAIL - \(name)")
    }
}

func c(_ id: Int, _ x: Double, _ y: Double, _ pressure: Double = 1.0) -> SDRTouchContact {
    SDRTouchContact(id: id, x: x, y: y, pressure: pressure)
}

// MARK: - 单指链路：DOWN → MOVE（含抖动抑制）→ UP

var events: [SDRTouchEvent] = []
let router = SDRTouchRouter(contentsScale: 2.0)
router.onDispatch = { events.append($0) }

router.handle(phase: .began, contacts: [c(0, 10, 20)], timestampMillis: 1000)
check(events.count == 1 && events[0].action == .down, "单指按下合成 ACTION_DOWN")
check(events[0].primary?.x == 20 && events[0].primary?.y == 40, "坐标按 contentsScale 折算为 guest 像素")

router.handle(phase: .moved, contacts: [c(0, 12, 20)], timestampMillis: 1010)
check(events.count == 1, "未越过 touch slop 的位移不派发 MOVE")
check(router.statisticsSnapshot().droppedBySlop == 1, "抖动抑制计数递增")

router.handle(phase: .moved, contacts: [c(0, 30, 40)], timestampMillis: 1020)
check(events.count == 2 && events[1].action == .move, "越过 slop 后派发 ACTION_MOVE")
check(events[1].pointerCount == 1, "MOVE 携带单个指针")

// MARK: - 多指链路：POINTER_DOWN / POINTER_UP / UP

router.handle(phase: .began, contacts: [c(0, 30, 40), c(1, 50, 60)], timestampMillis: 1030)
check(events.count == 3 && events[2].action == .pointerDown, "第二触点按下合成 ACTION_POINTER_DOWN")
check(events[2].actionIndex == 1, "POINTER_DOWN 的 actionIndex 指向新增触点")
check(events[2].pointerCount == 2, "POINTER_DOWN 一并携带全部指针坐标")

router.handle(phase: .ended, contacts: [c(1, 50, 60)], timestampMillis: 1040)
check(events.count == 4 && events[3].action == .pointerUp, "次触点抬起合成 ACTION_POINTER_UP")
check(events[3].actionIndex == 1 && events[3].pointerCount == 2, "POINTER_UP 保留被抬起指针序号与坐标")

router.handle(phase: .ended, contacts: [c(0, 30, 40)], timestampMillis: 1050)
check(events.count == 5 && events[4].action == .up, "最后一指抬起合成 ACTION_UP")
check(router.pointerCount == 0 && router.activeContacts.isEmpty, "抬手后活动触点清空")

// MARK: - 速度估算（fling 初速度来源）

let velocityRouter = SDRTouchRouter(contentsScale: 1.0)
velocityRouter.handle(phase: .began, contacts: [c(0, 0, 0)], timestampMillis: 2000)
velocityRouter.handle(phase: .moved, contacts: [c(0, 20, 0)], timestampMillis: 2010)
velocityRouter.handle(phase: .moved, contacts: [c(0, 50, 0)], timestampMillis: 2020)
let velocity = velocityRouter.velocity
check(velocity.x > 0 && velocity.y == 0, "MOVE 采样后可估算主触点速度")

// MARK: - 长按判定

let longPressRouter = SDRTouchRouter(contentsScale: 1.0)
var longPressHit = false
longPressRouter.onLongPress = { _ in longPressHit = true }
longPressRouter.handle(phase: .began, contacts: [c(0, 0, 0)], timestampMillis: 3000)
longPressRouter.handle(phase: .moved, contacts: [c(0, 2, 2)], timestampMillis: 3550)
check(longPressHit && longPressRouter.statisticsSnapshot().longPressCount == 1, "静止按住超过 500ms 判定长按")

// MARK: - 双击判定

let doubleTapRouter = SDRTouchRouter(contentsScale: 1.0)
var doubleTapHit = 0
doubleTapRouter.onDoubleTap = { _ in doubleTapHit += 1 }
doubleTapRouter.handle(phase: .began, contacts: [c(0, 100, 100)], timestampMillis: 4000)
doubleTapRouter.handle(phase: .ended, contacts: [c(0, 100, 100)], timestampMillis: 4080)
doubleTapRouter.handle(phase: .began, contacts: [c(0, 102, 100)], timestampMillis: 4200)
doubleTapRouter.handle(phase: .ended, contacts: [c(0, 102, 100)], timestampMillis: 4260)
check(doubleTapHit == 1 && doubleTapRouter.statisticsSnapshot().doubleTapCount == 1, "两次快速轻点判定双击")
check(!doubleTapRouter.statisticsJSON().isEmpty && doubleTapRouter.statisticsJSON().contains("dispatched"),
      "统计快照可序列化为 JSON")

// MARK: - 取消与上限

let cancelRouter = SDRTouchRouter(contentsScale: 1.0)
cancelRouter.handle(phase: .began, contacts: [c(0, 0, 0)], timestampMillis: 5000)
cancelRouter.handle(phase: .cancelled, contacts: [c(0, 0, 0)], timestampMillis: 5010)
check(cancelRouter.statisticsSnapshot().cancelCount == 1, "取消事件计入统计")
check(cancelRouter.pointerCount == 0 && cancelRouter.activeContacts.isEmpty, "取消后清空活动触点")

let limitRouter = SDRTouchRouter(contentsScale: 1.0)
limitRouter.handle(phase: .began, contacts: (0..<15).map { c($0, Double($0), 0) }, timestampMillis: 6000)
check(limitRouter.statisticsSnapshot().maxPointerCount == SDRTouchRouter.maxContacts,
      "超量触点按上限 \(SDRTouchRouter.maxContacts) 截断")

print("touch-smoke: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
