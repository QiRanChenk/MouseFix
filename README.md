# MouseFix

macOS 菜单栏小工具：让外接鼠标更顺手。单文件 Swift 实现，无依赖，无沙箱。

A tiny macOS menu bar utility that makes external mice feel right. Single-file Swift, zero dependencies.

## 功能

### 🖱 鼠标滚轮反转 + 惯性滚动
- 仅反转**鼠标**滚轮方向，触摸板不受影响（按 `scrollWheelEventIsContinuous` 区分）
- 模拟触摸板的动量滚动：速度指数衰减、亚像素累积、反向立即响应

### ⌨️ Windows 风格 Ctrl 快捷键

| 按键 | 改写为 | 作用 |
|------|--------|------|
| `Ctrl+C` / `Ctrl+V` / `Ctrl+X` / `Ctrl+A` | `Cmd+C/V/X/A` | 复制 / 粘贴 / 剪切 / 全选 |
| `Ctrl+S` | `Cmd+S` | 保存 |
| `Ctrl+Z` | `Cmd+Z` | 撤销 |
| `Ctrl+Y` | `Cmd+Shift+Z` | 重做（macOS 标准，兼容性优于 `Cmd+Y`） |
| `Ctrl+Q` | `Ctrl+A` | 保留 macOS 原生的「移到行首」 |

- 其他修饰键原样保留（`Ctrl+Shift+V` 同样生效）
- **终端类 app 自动跳过**（Terminal、iTerm2、Warp、kitty、WezTerm、Alacritty、Hyper、Ghostty）——终端里 `Ctrl+C` 是 SIGINT、`Ctrl+Z` 是 SIGTSTP、`Ctrl+S` 是流控冻结，不能动

两个功能都可在菜单栏独立开关。

## 系统要求

- macOS 12 (Monterey) 及以上
- Apple Silicon（arm64）。Intel 机器需自行修改 `build.sh` 中的 `-target` 后重新编译

## 使用

1. 从 [Releases](../../releases) 下载 `MouseFix.app.zip`，解压后拖入「应用程序」文件夹（或任意位置）
2. 首次打开：右键 `MouseFix.app` → 打开（ad-hoc 签名，需绕过 Gatekeeper 提示）
3. 按提示授予**辅助功能**权限：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 MouseFix
4. 授权后自动生效，无需重启 app；菜单栏出现 `MouseFix`，点击可独立开关两项功能
5. 退出：菜单栏 → 退出

日志位于 `~/Library/Logs/MouseFix.log`，排查问题时可查看。

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

MIT — 见 [LICENSE](LICENSE)。
