# Atypical.Aegisub.Startup.Boost

一个 Aegisub 自动化脚本：**把 MoonScript 脚本预编译成 Lua，跳过每次启动时的现编译。**

放进 `automation/autoload/` 就会被加载，从此每次启动自动维护缓存，不需要任何手工步骤。

---

## 它解决什么问题

Aegisub 的自动化系统在启动时会扫描 `automation/autoload/`，逐个加载脚本。其中相当一部分脚本是
用 MoonScript 写的，需要**每次启动现编译一遍**。更麻烦的是：

- 每个 autoload 脚本使用**独立的 lua_State**，同一个被 `require` 的模块会被重复编译 N 次；
- Aegisub 自身**没有编译缓存**。

于是模块越多，启动越慢，而且这部分开销是纯粹的重复劳动。

本脚本在启动时把这些 `.moon` 编译成 `.lua` 放在一旁，**下次**启动直接读成品。
它对 Aegisub 的改动只有一处，而且是可逆的：在 `autoload/` 下建若干**无扩展名**的符号链接，
指向编译产物目录 —— Aegisub 把"脚本自身目录"放在模块搜索路径首位，于是所有 `require` 都命中成品。

---

## 安装

1. 把 `Atypical.Aegisub.Startup.Boost.lua` 放进你的 `automation/autoload/` 目录：

   | 平台 | 目录 |
   |---|---|
   | macOS | `~/Library/Application Support/Aegisub/automation/autoload/` |
   | Windows | `%APPDATA%\Aegisub\automation\autoload\` |
   | Linux | `~/.aegisub/automation/autoload/` |

   脚本会在**首次运行时自己推导**这些路径，不依赖任何写死的常量。

2. 重启 Aegisub。第一次启动会建立全部缓存（略慢，属正常），之后每次启动都走成品。

3. 想确认真在工作，看日志：

   ```
   cache/Atypical.Aegisub.Startup.Boost/build.log
   ```

   正常的首几行长这样：

   ```
   ---- 2026-01-01 12:00:00 ----
   12:00:00  路径：ROOT=<你的用户目录>   源=<用户目录>/automation/include | <安装目录>/automation/include
   12:00:00  完成：新编译 0 / 已最新 123 / 失败 0 ...
   ```

   `源=` 后面应该有两个目录。只有一个说明没找到 Aegisub 自带的 include（脚本会照常工作，只是少一处加速）。

---

## 它会创建什么

全部位于你的 Aegisub 用户目录下：

| 路径 | 内容 | 能删吗 |
|---|---|---|
| `automation/include.boost.lua/` | 编译成品 + `include/` 的镜像 | 能，下次启动重建 |
| `automation/autoload.boost.moon/` | autoload 脚本的 `.moon` 母本 | ❌ 见下 |
| `automation/autoload.boost.disabled/` | 停用脚本的停放区（自带说明） | ❌ 见下 |
| `cache/Atypical.Aegisub.Startup.Boost/` | 日志、产物清单、自检指纹 | **能整包删**，全是日志 |
| `cache/Atypical.Aegisub.Startup.Boost.Backup/` | 源文件副本 + 三本变更账 | ❌ **不可再生** |

**原文件一个都不会被修改。** 它只做三件事：编译、复制、以及在产物目录里清理"源已经不在了"的文件。

### 清理的安全边界

- 清理**只**发生在 `include.boost.lua/` 里，即本脚本自己的产物目录。
- 手放进去、找不到对应源的文件**一律保留**并记日志，不会被误删。
- 每次删除前先确认**Backup 里有对应源**；找不到就不删。
- 源目录不齐（比如 Aegisub 被移动或卸载）时，整轮跳过清理。

### `Backup/` —— 源文件副本

它保存 `autoload/` 与 `include/` 里**出现过**的所有文件，**只增不删** —— 所以删掉的脚本永远能从这里拷回去。
同一目录下还有三本账：`changes.log`（变更流水）、`audit.tsv`（现状 vs Backup 总账）、`state.tsv`（上轮指纹）。

---

## 停用 / 卸载

**临时停用**：删除 `Atypical.Aegisub.Startup.Boost.lua` 即可，Aegisub 下次启动就不再加载它。
已生成的缓存会留着继续生效（不影响正确性，只是不再更新）。

**彻底还原**：在上一句的基础上，再删除 `automation/include.boost.lua/`，
以及 `autoload/` 下那些**无扩展名**的符号链接。之后 Aegisub 就回到了完全没有本脚本的状态。

### 停用某个脚本（顺便加快启动）

把不想用的脚本从 `automation/autoload/` 挪到 `automation/autoload.boost.disabled/`，
Aegisub 就不会加载它了。该目录里有一份自动生成的说明，会告诉你每个停用的脚本该恢复到哪。

**建议把它的 `.moon` 母本一起挪走**（如果有的话，母本在 `automation/autoload.boost.moon/`）。
只挪 `.lua` 其实**也能停用成功**：下一次启动时，脚本会把那个"没有宿主的母本"先存进 Backup、
再从 `autoload.boost.moon/` 移走。区别只在**源归谁保管**：

- 成对挪走 → 源在你手上，想恢复直接放回；
- 只挪成品 → 源被收进 `cache/Atypical.Aegisub.Startup.Boost.Backup/autoload/`，要去那里拷回来。

### 启用 / 恢复某个脚本

**放回 `automation/autoload/` 就对了**：`.lua` 直接可用；只放 `.moon` 的话，下次启动会自动编译出成品。

⚠️ `automation/autoload.boost.moon/` **不是**启用入口 —— 它是脚本自己的母本档案区。往那里放一个
"在 `autoload/` 里没有对应成品"的 `.moon`，会被当成已停用脚本的残留：收进 Backup 后移走（不会丢，
但不等于启用）。

> 反过来的情形脚本也会主动提示：某个脚本**正在用、但现场找不到它的母本**（源只在 Backup 里）时，
> 启动日志里会出现一行 `提醒 … 正在用，但现场没有它的源（.moon）`，并告诉你从哪儿拷回来。
> 典型来路是"只把 `.lua` 从停放区拷回 `autoload/` 直接启用"。

---

## 已知限制

- **需要 Aegisub 自带 `moonscript` 模块**。取不到时脚本会静默退出，不做任何事（不会报错，也不会影响启动）。
- **只处理 `autoload/` 顶层**，与 Aegisub 自身的扫描范围一致（不递归）。
- 顶层**单文件模块**（如 `include/Yutils.lua`）拿不到加速链接 —— 因为它本来就是原生 Lua，
  `require` 直接命中，零编译成本，不需要加速。这也是链接名必须**无扩展名**的原因：
  任何以 `.lua`/`.moon` 结尾的条目都会被 autoload 的扫描当成脚本加载。
- **不要手工在 `autoload/` 里制造同名的 `.lua` 与 `.moon`。** Aegisub 是**并发**加载该目录的
  （`std::async`），两个同名脚本的宏全名也一样（只取文件名、不含扩展名），而宏注册是
  **先到先得、后来者静默丢弃**（`std::map::emplace`，不覆盖也不报警）。
  实测通常只会加载一个（本脚本的 ④ 会把 `.moon` 先搬走），但那是**竞态**、不保证 ——
  换个文件系统或系统负载变化都可能翻盘。**别依赖它，也别主动制造这种状态。**

  > 顺带：要给一个**已在用**的脚本换源（更新 `.moon`），放进 `automation/autoload.boost.moon/`
  > 覆盖旧母本即可 —— 那里不会与 `autoload/` 里的成品撞名。
- 脚本自己不会注册任何宏，也不会弹窗。

---

## 兼容性

在 arch1t3cht 的 Aegisub 分支（macOS arm64 构建）上开发与验证。用到的都是 Aegisub 的公开 Lua API
（`aegisub.decode_path`、`lfs`、`moonscript`），按理在其它分支上同样可用；未逐一实测。

代码里有若干处针对特定 `lfs` 实现的兼容处理（该 fork 不导出 `symlinkattributes` / `link`，
且 `lfs.attributes(p)` 不带字段时对目录返回 nil），注释里都写明了原因。

---

## 许可证

MIT —— 见 [LICENSE](LICENSE)。可自由使用、修改、再分发（含商用），只需保留版权声明。

---

## 关于名字里的 `Atypical`

`Atypical` 是本项目的作者署名，脚本文件名与缓存目录名都沿用它。
代码本身与任何特定的 Aegisub 安装无关，路径全部在运行时推导。
