# MouseFix

macOS 菜单栏小工具：让外接鼠标更顺手。单文件 Swift 实现，无依赖，无沙箱。

A tiny macOS menu bar utility that makes external mice feel right. Single-file Swift, zero dependencies.

## 功能

### 🖱 鼠标滚轮反转 + 惯性滚动
- 仅反转**鼠标**滚轮方向，触摸板不受影响（按 `scrollWheelEventIsContinuous` 区分）
- 模拟触摸板的动量滚动：速度指数衰减、亚像素累积、反向立即响应

### ⌨️ Windows 风格 Ctrl 快捷键
- `Ctrl+C` / `Ctrl+V` / `Ctrl+X` / `Ctrl+A` → 自动改写为 `Cmd+C/V/X/A`（复制 / 粘贴 / 剪切 / 全选）
- `Ctrl+Q` → 改写为 `Ctrl+A`，保留 macOS 原生的「移到行首」
- 其他修饰键原样保留（`Ctrl+Shift+V` 同样生效）
- **终端类 app 自动跳过**（Terminal、iTerm2、Warp、kitty、WezTerm、Alacritty、Hyper、Ghostty）——终端里 `Ctrl+C` 是 SIGINT，不能动

两个功能都可在菜单栏独立开关。

## 构建

```bash
./build.sh
open MouseFix.app
```

需要 Xcode Command Line Tools（`swiftc`）。产物为 ad-hoc 签名的 `MouseFix.app`。

## 授权

首次运行（以及每次重新构建后，因签名变化）需要授予辅助功能权限：

系统设置 → 隐私与安全性 → 辅助功能 → 勾选 MouseFix

## 原理

单个 `CGEvent` tap（`.cgSessionEventTap` + `.headInsertEventTap`）同时拦截滚轮和键盘事件：

- 滚轮：吞掉原始离散滚动，按帧注入带惯性的像素级合成事件（synthetic 事件打标防递归）
- 键盘：原地改写事件的修饰键 / 键码，不注入新事件，无递归风险

## License

MIT
