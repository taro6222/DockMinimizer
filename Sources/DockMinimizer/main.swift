// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 changhun

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// LSUIElement와 짝을 이룬다. Dock 아이콘도 메뉴바 앱 메뉴도 갖지 않는다.
app.setActivationPolicy(.accessory)
app.run()
