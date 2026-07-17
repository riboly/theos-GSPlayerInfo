# GSPlayerInfo（正确做法：Theos / 正规 iOS 工具链）

## 为什么之前完全没显示（对照 DYYY）

已对照可工作的项目 [Wtrwx/DYYY](https://github.com/Wtrwx/DYYY) 与你本机可用的 `FLEX_Pro.dylib`：

| 项目 | DYYY / FLEX（能注入） | 之前 Zig 版（无效） |
|------|----------------------|---------------------|
| 编译器 | **Xcode clang + iPhoneOS SDK**（Theos） | Windows 上 Zig `aarch64-macos-none` |
| 链接 | 正常链接 UIKit/Foundation/objc | `dynamic_lookup` / 手工补 LC_LOAD_DYLIB |
| 重定位 | **LC_DYLD_CHAINED_FIXUPS** 或完整 dyld bind | 残缺 DYLD_INFO |
| flags | `0x100085`（含 MH_NOUNDEFS） | `0x100084` |
| 语言 | Objective-C / Logos | 手写 C + 伪造 objc 调用 |
| 结果 | 真机 dyld 正常加载 | **加载失败或 constructor 不跑** → 零 UI |

**结论：不是注入路径选错那么简单（路径要对，但核心是 dylib 本身不合法）。**  
在 Windows 用 Zig 交叉“伪 iOS dylib”**无法**替代 Theos/Xcode 产物。  
DYYY 的 `DYYY_*.dylib` 是 GitHub Actions 在 **macOS** 上用 Theos 编出来的。

---

## 注入方式（与 flex 一致）

```text
注入路径: @executable
注入目录: /
结果:     @executable_path/GSPlayerInfo.dylib
```

和 `flex.dylib` 一样放在 `xxx.app/` 根目录，**不要**放 `Frameworks/`。

---

## 如何得到可用 dylib

### 方法 A：本机 Mac + Theos

```bash
# 安装 Theos 后
export THEOS=~theos
cd theos-GSPlayerInfo
make clean all
# 产物
ls packages/GSPlayerInfo.dylib
# 或
find .theos -name 'GSPlayerInfo.dylib'
```

建议：

```bash
install_name_tool -id @executable_path/GSPlayerInfo.dylib packages/GSPlayerInfo.dylib
```

### 方法 B：GitHub Actions（推荐，无需本地 Mac）

1. 把 `theos-GSPlayerInfo` 整个目录推到一个 GitHub 仓库  
2. 打开 Actions → 跑 `build-dylib`  
3. 下载 Artifact：`GSPlayerInfo-dylib`  
4. 注入签名安装  

工作流文件：`.github/workflows/build.yml`

### 方法 C：有 Mac 的朋友 / 云 Mac 代编

把本目录发过去，执行 `make all` 即可。

---

## 生效时的表现（验证用）

- 顶部红条：`【GS注入成功】点右上角 i 查看播放信息`
- 右上角蓝色按钮 `i`
- 约 2.5 秒后自动弹框 `GS 注入成功`
- 进入播放页后再点 `i`：分辨率 / 标题 / URL

---

## 源码说明

- `Tweak.m`：纯 Objective-C（不依赖 Logos/Substrate）
- `constructor` 启动 → 主线程装 UI + swizzle  
  - `IJKFFMoviePlayerController`
  - `AVPlayer`
  - `NSJSONSerialization`（标题/URL 兜底）
- `Makefile`：`library.mk` 输出裸 dylib，适合 IPA 注入

---

## 不要再使用

桌面上此前的：

- `GSPlayerInfo.dylib` / `GSPlayerInfo_v3/v4/v5.dylib`（Zig 产物）

那些在结构上就与 DYYY/FLEX 不是一类文件，**继续注入也不会显示**。
