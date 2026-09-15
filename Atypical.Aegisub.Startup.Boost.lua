-- Atypical.Aegisub.Startup.Boost.lua
-- Aegisub 启动速度优化 —— MoonScript 预编译缓存生成器
--
-- 作用：用 Aegisub 自带的 moonscript 编译器把 .moon 预编译成 .lua，落到旁的
--       include.boost.lua/ 目录，启动时直接读成品，跳过 MoonScript 现编译。
--       背景：Aegisub 每个 autoload 脚本使用独立 lua_State（auto4_lua.cpp:429），
--       且没有编译缓存（script_reader.cpp:59），N 个脚本要各编译一遍同样的模块。
--
-- 两类源：
--   1) automation/include + 内置 include  —— 被 require 的模块目录
--   2) automation/autoload.boost.moon/*.moon —— autoload 脚本自身也是 MoonScript，
--      每次启动同样要现编译；编译品落成模块形式
--      a-mo.Aegisub-Motion.moon -> autoload/a-mo.Aegisub-Motion.lua
--
-- 涉及的目录（都在使用者的 Aegisub 用户目录下，绝对路径运行时推导，见下"路径推导"段）：
--   automation/autoload/                Aegisub 唯一扫描的脚本目录
--   automation/autoload.boost.moon/     autoload 脚本的 .moon 母本（本文件读取）
--   automation/include.boost.lua/       编译成品 + include 镜像（本文件写出）
--   automation/autoload.boost.disabled/ 已禁用的脚本
--   cache/Atypical.Aegisub.Startup.Boost/build.log   本脚本运行日志
--
-- 生效方式（不依赖 config.json —— 实测该配置每次启动会被 Aegisub 重置）：
--   autoload 目录下有若干符号链接指向 ../include.boost.lua/<同名目录>，
--   而 auto4_base.cpp:262 把"脚本自身目录"放在搜索路径首位，故优先命中缓存。
--   （链接名一律无扩展名，不会被 autoload 的 *.* 扫描当脚本加载。
--    现由 ⑤ 自动对账维护，不必手工建。）
--
--   ⚠️ 链接名必须**无扩展名**：autoload 的枚举会把任何以 .lua/.moon 结尾的条目当真脚本加载，
--      所以顶层单文件模块（如 include/Yutils.lua）拿不到链接 —— 它也没有必要有：
--      Yutils 本来就是原生 .lua，require 'Yutils' 直接命中 include/Yutils.lua，零编译成本。
--
--   ⚠️ 要把一个 .moon 变成脚本，请丢进 autoload/（④ 会自动收编）；
--      autoload.boost.moon/ 是本脚本的档案区，往里丢一个没有对应 autoload/<名>.lua 的母本，
--      会被 ⑤ 当"宿主已删除"移除（仓库 Backup/autoload/ 里留着副本，拷回来即可恢复）。
--
-- 本文件不带 !00_ 前缀：migration04 的 AutoloadScriptManager::Reload 对扫描到的条目
--   不作任何排序（std::async 提交顺序 = 纯文件系统枚举顺序），前缀从来保证不了
--   "最先加载"；而本文件的产物只供**下次**启动读取，与本次的加载顺序无关，故前缀已删。
--
-- 安全性：原 .moon 一个都不动；单个文件失败只记日志，不影响启动。
-- 停用方法：删除本文件即可；如需彻底还原，再删除 automation/include.boost.lua/
--   与 autoload/ 下的那些符号链接。
--
-- 镜像 pass：把**用户自己的** include/ 下非 .moon 的原生文件（各类纯 Lua 模块）
--   按 mtime 增量复制到 include.boost.lua/，使其成为 include/ 的完整镜像 ——
--   于是所有 require 都在 package.path 第 1 项（autoload 的符号链接）命中，不再落回 include/ 原件。
--   范围刻意**只限用户 include**，不含内置 include（那里的原生文件在 package.path
--   第 5 项且无链接遮蔽，复制过来既改变不了解析结果，又多一份随 app 升级漂移的副本）。
--   刻意**不镜像**三类：隐藏文件（.DS_Store）、备份（*.bak-*）、二进制
--   （.dylib/.so/.bundle/.dll）。后者是因为：复制一份体积可观的二进制会改变它的加载来源
--   （requireffi 靠 package.path 前缀替换找 dylib，见 requireffi.lua）。
--
-- 收编 pass ④：autoload/ 顶层新出现的 .moon 自动收编 ——
--   编译成功并写出 autoload/<同名>.lua **之后**，才把 .moon 移入 autoload.boost.moon/。
--   顺序不可颠倒：编译失败就原地不动，Aegisub 下次启动仍会现编译它，功能一点不减；
--   若先移后编译，一旦编译失败，autoload/ 里那个脚本就凭空消失了。
--   执行位置刻意放在 ② 之前：这样"新丢进来的母本"总是压过 MOONSRC 里的旧同名母本。
--
-- 对账清理 pass ⑤（cleanup）：删源即删产物，且**不依赖任何历史记录** ——
--   每次启动都用"源的当前状态"反推产物应有集合（expected_map），DST 里多出来的一律移除。
--   为什么不拿"清单文件"当判定依据：清单一旦丢失/过期就会误判，且产物早于本功能
--   存在时无从记录；推算式可自愈。清单仍然生成（manifest.tsv），但只作审计用，不参与判定。
--   移除前**先确认仓库里有对应的源**：include 侧的产物派生于 include/ 里的源，
--   源在仓库里就删掉、不在就保留报警；母本 .moon 同理。恢复 = 从 Backup/ 拷回 automation/。
--   另维护 autoload/ 下的包目录符号链接：目标消失即删链接，DST 顶层出现新的无扩展名目录即补链接。
--   ⚠️ 前提：include.boost.lua/ 归本脚本所有。手放进去的文件**不会**被清理误伤 ——
--      没有对应源的产物一律保留并记日志（见下"无源保留"），所以**不需要白名单**。
--      （原 keep.txt 白名单机制已取消，理由见下方取消该机制那段注释。）
--   保险丝：源目录不齐（app 被移动/卸载）时整轮跳过清理，绝不误删；CLEANUP_ENABLED=false 可整体关停。
--
-- [源对账 pass ⑤-c] automation/ 现场 ↔ Backup/ 仓库 —— 这一层的形态改过三次，把结论记下来：
--     第一版：给 autoload/ 顶层"无母本"的 .lua 留活副本（Backup/autoload/）。
--     第二版：扩成"两个源目录的 1:1 实时镜像"（Backup/current/）。
--     现在：镜像层**整个删掉**。理由是实测出来的 —— 那份实时镜像与仓库逐字节全同
--     （唯一差别是 Finder 写的 .DS_Store），每轮拷一份却零信息量。
--   所以 Backup/ 现在只有两样东西：
--     ① 仓库 Backup/{autoload,include} —— 源文件的完整副本，**只增不删**；
--     ② 账本 changes.log / state.tsv / audit.tsv —— 本脚本唯一会写的文件。
--   "现在长什么样"永远现读 automation/，不复制。state.tsv 是本项目唯一被允许的持久状态：
--   只用来**发现**变化，永不驱动删除/归档；它丢了最坏只是少记一轮变更，绝不会误删任何东西。

-- ===================== 路径推导（本脚本不写死任何绝对路径） =====================
-- 下面这些位置因平台、用户名、安装方式而异，所以一律推导，不写常量：
--   ROOT         用户目录（Aegisub 的配置/缓存所在）
--   SRCS[2]      Aegisub 自带的 include 目录
--   SELFNAME     本脚本自己的文件名
-- 推导失败就静默退出：第 ⑤ 步是唯一会删东西的地方，绝不拿一个没把握的路径去跑
-- （宁可这一轮什么都不做，也不能猜）。
local function strip_slash(p) return (p:gsub("/+$", "")) end

-- Aegisub 官方 API：把 ?user / ?data 这类路径说明符解成绝对路径。
-- 在 Aegisub 之外运行（例如单独的离线调试）时 aegisub 全局不存在，pcall 兜住，落到下一级。
local function decode_path(spec)
	if type(aegisub) ~= "table" or type(aegisub.decode_path) ~= "function" then return nil end
	local ok, p = pcall(aegisub.decode_path, spec)
	-- ⚠️ 必须**验形**，不能照单全收：说明符解不出来时（例如没有视频时的 ?video），
	--    官方文档说它返回的是"一个多半没用的字符串"而**不是** nil。收下它，ROOT 就变成一个
	--    凭空的怪串，后面所有目录都建在它下面，而且每一处失败都是静默的。
	--    筛子用两条：不得含 "?"（真实路径里基本不会出现，Windows 上更是非法字符），
	--    且必须是绝对路径。任一不过就当这一级失败，继续往下退。
	if not ok or type(p) ~= "string" or p == "" then return nil end
	if p:find("?", 1, true) then return nil end
	if p:sub(1, 1) ~= "/" and not p:match("^%a:[/\\]") and not p:match("^\\\\") then return nil end
	return strip_slash(p)
end

local function resolve_root()
	-- ① 环境变量：便携安装 / 回归测试注入用
	local env = os.getenv("AEGISUB_BOOST_ROOT")
	if env and env ~= "" and not env:find("?", 1, true) then return strip_slash(env) end
	-- ② ?user —— macOS: ~/Library/Application Support/Aegisub
	--             Windows: %APPDATA%\Aegisub
	--             Linux:   ~/.aegisub
	local d = decode_path("?user")
	if d then return d end
	-- ③ 从本脚本自身位置反推：它必定住在 <ROOT>/automation/autoload/ 下
	local info = debug and debug.getinfo and debug.getinfo(1, "S")
	local src = info and info.source
	if type(src) == "string" then
		local root = src:gsub("^@", ""):match("^(.*)[/\\]automation[/\\]autoload[/\\][^/\\]+$")
		if root and root ~= "" then return root end
	end
	return nil
end

local ROOT    = resolve_root() or ""
local ROOT_OK = (ROOT ~= "")

-- 本脚本自己的文件名：同样从执行位置推导，这样改个名也不会让自检指纹失效。
local function own_filename()
	local info = debug and debug.getinfo and debug.getinfo(1, "S")
	local src = info and info.source
	if type(src) == "string" then
		local n = src:gsub("^@", ""):match("([^/\\]+)$")
		if n and n:sub(-4) == ".lua" then return n end
	end
	return nil
end
local SELFNAME = own_filename()

-- Aegisub 自带 include 的位置随平台/打包方式而变，所以列几个候选，取第一个**真的存在**的。
-- 首选 ?data/automation/include（各平台常规打包都在这里）；后两个是"data 指到别的层级"时的兜底。
local function app_include_candidates()
	local out = {}
	local d = decode_path("?data")
	if d then
		out[#out + 1] = d .. "/automation/include"
		out[#out + 1] = d .. "/include"
		out[#out + 1] = d .. "/../SharedSupport/automation/include"
		out[#out + 1] = d .. "/../Resources/automation/include"
	end
	return out
end

local AUTOLOAD = ROOT .. "/automation/autoload"
local MOONSRC = ROOT .. "/automation/autoload.boost.moon"   -- autoload 脚本的 .moon 母本（不参与自动扫描）
local DST = ROOT .. "/automation/include.boost.lua"
-- 源目录在 run() 里按"实际存在"填充（那时 lfs 才可用）：
--   SRCS        ① 被 require 的模块目录 = 用户 include + 内置 include
--   MIRROR_SRCS ③ 镜像源 = **只有用户自己的** include
-- ③ 刻意不含内置 include —— 那里的原生文件位于 package.path 第 5 项，没有任何符号链接遮蔽它们，
-- 复制进 include.boost.lua/ 既改变不了解析结果，又平白多出一份会随 app 升级漂移的副本。
local SRCS = {}
local MIRROR_SRCS = {}
local LOGP = ROOT .. "/cache/Atypical.Aegisub.Startup.Boost/build.log"
local MAX_PER_RUN = 300

-- ④ 收编 / ⑤ 对账清理 相关
local CACHEDIR       = ROOT .. "/cache/Atypical.Aegisub.Startup.Boost"
local CLEANUP_ENABLED = true   -- false = 只生成不清理（排查用）
local LINK_RECONCILE = true    -- 自动维护 autoload/<无扩展名包目录> 符号链接
local LINKPREFIX     = "../include.boost.lua/"
local MANIFEST       = CACHEDIR .. "/manifest.tsv"   -- 产物清单（审计用，不参与清理判定）
-- 日志合并：`cleanup.log` 已取消：它的逐条动作行（删了哪个产物 / 收了哪个空目录 /
--   增删了哪个链接 / 移除或入库了哪个母本）现在直接写进 build.log；它原有的每轮汇总行与
--   build.log 的「清理：…」两行逐字段重复（后者还多出"隐藏 / 删除失败 / 现有链接数"）。
--   ⇒ 少一个文件，动作记录一条不少。
-- [仓库位置] 仓库（Backup/）装的是**不可再生**的东西，所以它不放在日志堆里，
--   而是作为 cache/ 主目录的**兄弟目录**存在：
--     cache/Atypical.Aegisub.Startup.Boost/         日志与可再生文件，**可以整包删**
--     cache/Atypical.Aegisub.Startup.Boost.Backup/  源文件仓库 + 账本，❗不可再生
--   （两者曾经放在一起，代价是"主目录可整包删"这条性质失效；分开之后才重新成立。）
local BACKUPDIR      = ROOT .. "/cache/Atypical.Aegisub.Startup.Boost.Backup"
local AUDITTSV       = BACKUPDIR .. "/audit.tsv"    -- 现场 vs 仓库 的总账
local BASESTATE      = BACKUPDIR .. "/state.tsv"    -- 上一轮指纹（唯一被本脚本写进 Backup/ 的数据文件）
local CHANGESLOG     = BACKUPDIR .. "/changes.log"  -- 变更流水（追加式）
local ZONES          = { "autoload", "include" }   -- Backup/ 下的仓库目录 = 对账范围
--   对账范围刻意**只管 autoload 和 include** 这两个用户真正会动的源目录。
--   automation/tests 之类的第三方测试夹具不在其中：启动全程不碰它（启动日志里零引用），
--   而且它与现场逐字节相同 —— 备份它只是存两遍。
-- ⚠️ 对账范围是"会变的口径"，所以历史指纹也必须按**当前**范围过滤 ——
--   否则每次收窄范围（例如 23:2x 去掉 tests）都会在下一轮冒出一串**假的「删除」**：
--   上一轮记在 state.tsv 里、这一轮已不在范围内的条目，会被当成"源被删了"。
local IN_ZONE = {}
for _, z in ipairs(ZONES) do IN_ZONE[z] = true end
local function rel_in_zone(rel)
	local z = rel:match("^([^/]+)/")
	return z ~= nil and IN_ZONE[z] == true
end
local DISABLEDDIR    = ROOT .. "/automation/autoload.boost.disabled"  -- 停放区：把暂时不用的脚本从
--   autoload/ 挪到这里，Aegisub 就不会加载它（省启动时间），而文件留着、随时能搬回去。
--   本目录由脚本在**首次运行**时自动建立（连同一份自述 README.txt）；
--      自述的第三项（"现在停放了哪些脚本、各自该恢复到哪里"）**每轮按实际内容重写** ——
--      往里加/删脚本后，下次启动那一段会自己更新。
--   ⚠️ 但脚本**从不碰里面停放的脚本文件本身**：只用 disabled_pool() 列一下文件名，
--      用来把对账里"本来有、现在没有"的脚本判成「已停用」而不是「已删除」。
--      （判据 = 去掉扩展名的文件名，且**只看 .lua / .moon**。）
--   为什么必须认得它：否则"把脚本停用掉"会被对账报成「已删除」，凭空吓人一跳
--      —— 一个明明还在磁盘上的脚本，不该在账本里显示成"丢了"。
local DISABLEDREADME = DISABLEDDIR .. "/README.txt"
-- **Trash 已取消**：它原本兜的是"删掉的东西的最后一份"，而 Backup/ 现在是"只增不删的完整仓库"，
--   删掉的东西本来就一直在仓库里 —— 两个地方都能恢复，就是冗余。
--   所以：⑤-a/⑤-b 改成"确认仓库里有副本才删"，恢复路径统一成"从 Backup/ 拷回 automation/"。
local MAINREADME     = CACHEDIR .. "/README.txt"
-- 取消 keep.txt：原白名单机制已整体删除。理由：
--   它唯一的判定点是"产物不在应有集合里、又不是隐藏文件、**且仓库里能找到对应源**"时生效；
--   而"仓库里找不到源就保留"（无源保留）这条默认规则，已经接管了它原本更广的用途
--   —— 手放进 include.boost.lua/ 的文件本来就删不掉，不需要用户再登记一遍。
--   剩下那个窄情形（"用户主动删了源，但想留下已成型的产物"）用"把源留在 include/"解决更好。
--   ⇒ 少一个需要用户记得它存在的控制文件。
local DIAG           = true    -- true = 每个脚本版本首次启动跑一遍环境自检（写/删/改名/建链接），落地到 build.log；同一版本不重复跑

local lfs, moonscript
local logf

local function log(s)
	if logf then
		logf:write(os.date("%H:%M:%S") .. "  " .. s .. "\n")
		logf:flush()
	end
end

local function mkdirp(path)
	local cur = ""
	for p in string.gmatch(path, "[^/]+") do
		cur = cur .. "/" .. p
		if not lfs.attributes(cur, "mode") then
			lfs.mkdir(cur)
		end
	end
end

local function collect(dir, out)
	local iter, obj = lfs.dir(dir)
	if not iter then return end
	for name in iter, obj do
		if name ~= "." and name ~= ".." then
			local full = dir .. "/" .. name
			local mode = lfs.attributes(full, "mode")
			if mode == "directory" then
				collect(full, out)
			elseif mode == "file" and name:sub(-5) == ".moon" then
				out[#out + 1] = full
			end
		end
	end
end

-- 与 Aegisub script_reader.cpp:41-45 保持一致：剥离 UTF-8 BOM，否则 moonscript 解析会失败
local function readall(p)
	local f = io.open(p, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	if s and s:sub(1, 3) == "\239\187\191" then
		s = s:sub(4)
	end
	return s
end

-- 镜像用：原样读取（不剥 BOM —— 保持字节完全一致）
local function readraw(p)
	local f = io.open(p, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local SKIP_EXT = { dylib = true, so = true, bundle = true, dll = true }

-- 判断某个文件名是否要参与镜像
local function should_mirror(name)
	if name:sub(1, 1) == "." then return false end          -- 隐藏文件
	if name:find("%.bak%-", 1, false) then return false end -- 备份
	if name:sub(-5) == ".moon" then return false end        -- .moon 走编译，不走镜像
	local ext = name:match("%.([%w]+)$")
	if ext and SKIP_EXT[ext:lower()] then return false end  -- 二进制
	return true
end

local function collect_all(dir, out)
	local iter, obj = lfs.dir(dir)
	if not iter then return end
	for name in iter, obj do
		if name ~= "." and name ~= ".." then
			local full = dir .. "/" .. name
			local mode = lfs.attributes(full, "mode")
			if mode == "directory" then
				collect_all(full, out)
			elseif mode == "file" then
				out[#out + 1] = full
			end
		end
	end
end

-- 按 mtime 增量复制；返回 "built" / "fresh" / "fail"
-- 无条件按字节复制（不看 mtime）。
-- ⚠️ copy_if_newer 在这里**不能**用：仓库里那份的 mtime 是"当初复制的那一刻"，
--    永远比源新，`dm >= sm` 恒成立 ⇒ 同步会永远被跳过。这是"补入"第一版埋点。
local function copy_raw(src, dst)
	local data = readraw(src)
	if not data then return false end
	local dd = dst:match("^(.*)/[^/]+$")
	if dd then mkdirp(dd) end
	local f = io.open(dst, "wb")
	if not f then return false end
	f:write(data)
	f:close()
	return true
end

local function copy_if_newer(src, dst)
	local sm = lfs.attributes(src, "modification")
	local dm = lfs.attributes(dst, "modification")
	if sm and dm and dm >= sm then return "fresh" end

	local data = readraw(src)
	if not data then return "fail" end

	local dd = dst:match("^(.*)/[^/]+$")
	if dd then mkdirp(dd) end
	local f = io.open(dst, "wb")
	if not f then return "fail" end
	f:write(data)
	f:close()
	return "built"
end

-- 编译单个 .moon -> dst；返回 "built" / "fresh" / "fail"
local function build(src, dst)
	local sm = lfs.attributes(src, "modification")
	local dm = lfs.attributes(dst, "modification")
	if sm and dm and dm >= sm then return "fresh", 0 end

	local text = readall(src)
	if not text then return "fail", 0 end

	local t = os.clock()
	local code, err = moonscript.to_lua(text)
	local cost = os.clock() - t
	if not code then return "fail", cost, err end

	local dd = dst:match("^(.*)/[^/]+$")
	if dd then mkdirp(dd) end
	local f = io.open(dst, "w")
	if not f then return "fail", cost, "write failed" end
	f:write(code)
	f:close()
	return "built", cost
end

-- ============================ ④ 收编 pass ============================
-- autoload/ 顶层新出现的 .moon：先编译出 .lua 并确认落盘，才移动母本。
-- 只扫顶层（Aegisub 的 *.* 枚举也不递归）；符号链接/目录一律跳过。
local function adopt()
	local adopted, conflict = 0, 0
	if lfs.attributes(AUTOLOAD, "mode") ~= "directory" then return adopted, conflict end

	local names = {}
	for name in lfs.dir(AUTOLOAD) do
		if name:sub(-5) == ".moon" and name:sub(1, 1) ~= "." and not name:find("%.bak%-", 1, false) then
			names[#names + 1] = name
		end
	end

	for _, name in ipairs(names) do
		local src = AUTOLOAD .. "/" .. name
		if lfs.attributes(src, "mode") == "file" then      -- 悬空链接/目录：跳过
			local dstname = name:sub(1, -6) .. ".lua"
			local dst = AUTOLOAD .. "/" .. dstname
			local r, _, err = build(src, dst)
			if r == "fail" then
				log("收编 FAIL（.moon 原地未动）" .. name .. " :: " .. tostring(err))
			else
				-- 编译品已就位（built 或 fresh），此时才允许移动母本
				mkdirp(MOONSRC)
				local target = MOONSRC .. "/" .. name
				local blocked = false
				if lfs.attributes(target, "mode") then
					local alt = target .. ".dup-" .. os.date("%Y%m%d-%H%M%S")
					if os.rename(target, alt) then
						conflict = conflict + 1
						log("收编：母本同名，旧本改存 " .. (alt:match("([^/]+)$") or alt))
					else
						blocked = true
						log("收编：旧同名母本另存失败，本轮不覆盖它 " .. name)
					end
				end
				if not blocked then
					local okm, errm = os.rename(src, target)
					if okm then
						adopted = adopted + 1
						log(string.format("收编 %-34s -> autoload/%s（母本移入 autoload.boost.moon/）", name, dstname))
					else
						log("收编：编译品已就位，但母本移动失败 " .. name .. " :: " .. tostring(errm) .. "（下次启动自动重试）")
					end
				end
			end
		end
	end
	return adopted, conflict
end

-- ========================== ⑤ 对账清理 pass ==========================

local changesf
-- changes.log 的开头一行是 "---- 时间 ----"，之后每条一行；
-- 每轮末尾必定还有一行「本轮：」汇总（没有变化也写）—— 否则时间戳会停在上次变化的时刻，
-- "没跑"和"跑了但没变化"长得一模一样。
local function changes_line(s)
	if not changesf then
		changesf = io.open(CHANGESLOG, "a")
		if changesf then changesf:write("---- " .. os.date("%Y-%m-%d %H:%M:%S") .. " ----\n") end
	end
	if changesf then
		changesf:write(os.date("%H:%M:%S") .. "  " .. s .. "\n")
		changesf:flush()
	end
end

-- 前置声明：walk_rel 要用它（本 fork 实测 lfs.symlinkattributes 为 nil，只能靠 readlink 兜底）
local link_info

-- 递归列目录，返回相对路径。符号链接当叶子且单独跳过（不做递归、不参与删除）
-- ⚠️ 静默失效的真根因，别改回去：
--    **必须** 用 lfs.attributes(p, "mode")（带字段）。本 fork 的 attributes 不带字段时，
--    对**目录**拿不到 .mode（返回的表里 mode 为 nil）→ 目录既不入 dirs 也不递归，
--    于是产物目录里的文件绝大多数扫不到，且**不报任何错**（⑤ 看起来跑了、其实什么都没删）。
--    同一个脚本里 collect()/collect_all() 一直用带字段写法，所以它们没事 —— 这就是对照。
local function walk_rel(dir, prefix, files, dirs)
	local iter, obj = lfs.dir(dir)
	if not iter then return end
	for name in iter, obj do
		if name ~= "." and name ~= ".." then
			local full = dir .. "/" .. name
			local rel = (prefix == "") and name or (prefix .. "/" .. name)
			local t = lfs.attributes(full, "mode")
			if t == nil and link_info then
				local isl = link_info(full)          -- 悬空链接：attributes 跟随失败 → nil
				if isl then t = "link" end
			end
			if t == "link" then
				-- 产物目录里不该有链接；真有，也不是本脚本建的，不碰
			elseif t == "directory" then
				dirs[#dirs + 1] = rel
				walk_rel(full, rel, files, dirs)
			elseif t then
				files[#files + 1] = rel
			end
		end
	end
end

local function dir_empty(p)
	local iter, obj = lfs.dir(p)
	if not iter then return false end
	for name in iter, obj do
		if name ~= "." and name ~= ".." then return false end
	end
	return true
end

-- 推算式：用源的当前状态算出"应有产物"集合  rel -> { kind, src }
local function expected_map()
	local exp = {}
	for _, base in ipairs(SRCS) do
		if lfs.attributes(base, "mode") == "directory" then
			local files = {}
			collect(base, files)                       -- 递归收集 .moon
			for _, src in ipairs(files) do
				exp[src:sub(#base + 2):gsub("%.moon$", ".lua")] = { kind = "compile", src = src }
			end
		end
	end
	for _, base in ipairs(MIRROR_SRCS) do
		if lfs.attributes(base, "mode") == "directory" then
			local files = {}
			collect_all(base, files)                   -- 递归收集全部
			for _, src in ipairs(files) do
				local nm = src:match("([^/]+)$") or src
				if should_mirror(nm) then
					exp[src:sub(#base + 2)] = { kind = "mirror", src = src }
				end
			end
		end
	end
	return exp
end

-- 读链接信息：返回 (是否符号链接, 目标)。
-- ⚠️ 本 fork 的 lfs 只导出 attributes/dir/mkdir/rmdir/chdir/currentdir/touch
--    （实证：app bundle 里 automation/include/aegisub/lfs.moon 的 return 表），
--    **没有 symlinkattributes、也没有 link**。所以原来那句
--    `if LINK_RECONCILE and lfs.symlinkattributes then` 在这个 fork 上是永远为假的死代码 ——
--    链接对账从来没跑过。这里做三级兜底：symlinkattributes → attributes 报 "link" → readlink。
link_info = function(p)
	if lfs.symlinkattributes then
		local a = lfs.symlinkattributes(p)
		if a and a.mode == "link" then return true, a.target end
		return false, nil
	end
	-- ⚠️ 这里也用带 field 的写法：不带 field 的 lfs.attributes(p) 在目录上返回 nil（见 walk_rel 注释）
	if lfs.attributes(p, "mode") == "link" then return true, nil end
	if not io.popen then return false, nil end
	local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
	local f = io.popen("readlink " .. q(p) .. " 2>/dev/null")
	if not f then return false, nil end
	local t = f:read("*a")
	f:close()
	t = (t or ""):gsub("%s+$", "")
	if t ~= "" then return true, t end
	return false, nil
end

-- 建符号链接：优先 lfs.link，失败退到 ln -s；返回是否真的建成了"符号链接"。
-- ⚠️ 返回值必须用 link_info 判定 —— 原来用 `lfs.symlinkattributes and ...`，
--    在本 fork 上 symlinkattributes 为 nil，于是**即使 ln -s 成功了也一律返回 false**
--    （会被记成"链接创建失败"，链接对账就成了哑炮）。
local function make_symlink(target, linkpath)
	if lfs.link then pcall(lfs.link, target, linkpath, true) end
	if not link_info(linkpath) then
		local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
		os.execute("ln -s " .. q(target) .. " " .. q(linkpath) .. " 2>/dev/null")
	end
	return link_info(linkpath)
end

-- 自述文件：只在缺失时写一次。
-- 起因：这些目录原本是"惰性创建"的（真要归档时才 mkdir），结果用户翻 cache 目录时找不到它，
-- 以为功能没生效。改成常驻创建 + 自带说明，目录一打开就自解释。
local function write_if_absent(p, lines)
	if lfs.attributes(p, "mode") == "file" then return end
	local f = io.open(p, "w")
	if not f then return end
	for _, s in ipairs(lines) do f:write(s .. "\n") end
	f:close()
end

local function ensure_readmes()
	write_if_absent(BACKUPDIR .. "/README.txt", {
		"Backup/ —— 你的 autoload/ 和 include/ 的副本仓库 + 变更账",
		"",
		"这个目录里分两类东西，别搞混：",
		"",
		"【仓库 · 脚本写】autoload/   include/",
		"  你这两个源目录里**出现过的所有文件**的副本 —— 首次运行时全量建立，之后每轮把新出现的补进来，",
		"  改过的同步更新。**只增不删**：你删掉的东西不会从仓库里消失，所以随时能从这里拷回去。",
		"  想恢复：把文件拷回 automation/ 对应目录即可（放回 .moon 或 .lua 都行，下次启动会自动编译）。",
		"",
		"【账本 · 脚本写】changes.log   state.tsv   audit.tsv",
		"  changes.log  源文件有增/删/改就记一行；每轮末尾还有「本轮：」「仓库：」两行汇总（没变也写）。",
		"  state.tsv    上一轮的文件指纹，脚本自己看，你不用管。",
		"  audit.tsv    现在 vs 仓库 的总账：一致 / 修改 / 新增 / 已删除 / 已停用。",
		"               「已删除」= 你删过的（**仓库里副本还在，不是丢失**）；它是累计的，会一直留着。",
		"",
		"这个目录【只管两个源目录】：autoload/ 和 include/ —— 就是你真正会动的两个。",
		"  automation/tests/ 不进这里：那是 DependencyControl / DepUnit 的单元测试夹具，",
		"  启动全程不碰它（启动日志里零引用），而且它和现场逐字节完全相同、备份它只是存两遍。",
		"",
		"两类东西【不入账】，免得天天误报：",
		"  · 名字带 .bak 的文件 —— 那是你自己留的备份，本就不参与镜像。",
		"  · 被停用的脚本（autoload/ 里没有、autoload.boost.disabled/ 里有）",
		"    -> 记「已停用」，**不是「丢失」**。停用脚本本来就该放那儿。",
		"",
		"没有「Trash」这个中间站：既然仓库只增不删，删除的东西本来就在里面 ——",
		"  两个地方都能恢复就是冗余。删掉一个脚本后想找回：直接从本目录拷回 automation/。",
	})
	write_if_absent(MAINREADME, {
		"这个目录**可以整包删** —— 里面全是日志，没有一样是删了找不回的。",
		"（仓库区不在本目录里，而是它的**兄弟目录**，见下。）",
		"（cleanup.log 已并入 build.log，本目录再少一个文件。）",
		"",
		"可安全删除（下次启动会重建）：",
		"  build.log      每轮一行分隔 + 各 pass 流水 + 「清理：…」动作明细",
		"  manifest.tsv   产物清单（只作审计）",
		"  .diag-stamp    自检指纹（删了只是多跑一次自检）",
		"  README.txt     本文件（删了自动重建）",
		"",
		"⚠️ 真正不能删的东西在**兄弟目录**里，不在本目录内：",
		"  ../Atypical.Aegisub.Startup.Boost.Backup/   源文件副本仓库（只增不删）+ 变更账  ❗不可再生",
	})
end

-- 停放区自述：**每轮按"里面现在有什么"重新生成**（第三项是动态内容）。
--   为什么必须动态：第三项要回答"现在停用了哪些脚本、各自该放回哪里" —— 那随用户操作变化。
--   只在内容真的变了时才写盘：静默轮次一个字都不动（与其它 pass 同一个原则）。
--   ⚠️ 它只读**文件名**，从不读停放脚本的内容、也从不动它们。
local function write_disabled_readme()
	local scripts, others = {}, {}
	if lfs.attributes(DISABLEDDIR, "mode") == "directory" then
		for name in lfs.dir(DISABLEDDIR) do
			if name:sub(1, 1) ~= "." and name ~= "README.txt" then
				local ext  = name:match("%.([^%.]+)$")
				local base = name:gsub("%.[^%.]*$", "")
				if ext == "lua" or ext == "moon" then
					scripts[base] = scripts[base] or {}
					scripts[base][ext] = name
				else
					others[#others + 1] = name
				end
			end
		end
	end
	table.sort(others)
	local names = {}
	for b in pairs(scripts) do names[#names + 1] = b end
	table.sort(names)

	local L = {}
	local function add(x) L[#L + 1] = x end
	add("autoload.boost.disabled/ —— 停用脚本的停放区")
	add("==============================================")
	add("（本文件由 Boost 脚本自动生成：每轮启动按\"这个文件夹里现在有什么\"重写，")
	add("  你在这里的手工修改会被下一次启动覆盖 —— 要改内容请改脚本里的模板。）")
	add("")
	add("【一】这个文件夹的作用")
	add("--------------------")
	add("Aegisub 只扫描 automation/autoload/ 这一个目录。一个脚本只要不在那里，就不会被加载")
	add("—— 也就不会占用启动时间。这个文件夹就是\"把暂时不想用的脚本挪出 autoload/、但不删掉\"的地方。")
	add("")
	add("它由 Boost 脚本在首次运行时自动建立（连同本文件），之后每轮保证它存在。")
	add("但脚本【从不碰里面停放的脚本文件】，只做两件事：")
	add("  · 列出里面的文件名，用来把对账结果里\"本来有、现在没有\"的脚本判成")
	add("    【已停用】而不是【已删除】（判据 = 去掉扩展名的文件名，只看 .lua / .moon）；")
	add("  · 按实际内容重写本文件。")
	add("")
	add("⚠️ 不要往这里放：autoload/ 里那些**无扩展名**的符号链接。它们不是脚本，是给 require")
	add("   用的路径桥，脚本每轮会自动重建它们 —— 删掉也会长回来，放进来没有任何\"停用\"效果。")
	add("")
	add("【二】怎么 disable 掉一个不想用的脚本")
	add("------------------------------------")
	add("先看它有没有\"母本\"。查法：")
	-- 用 ROOT 拼接，不写死平台路径：这样 README 里给出的是**本机真实路径**，
	-- 可直接复制粘贴，且在任何平台、任何安装位置都成立。
	add("  ls \"" .. ROOT .. "/automation/autoload.boost.moon/\"")
	add("")
	add("  情形 A —— 只有 autoload/xxx.lua，上面这个目录里没有同名 .moon")
	add("      搬 1 个文件：automation/autoload/xxx.lua  →  本文件夹")
	add("")
	add("  情形 B —— autoload/xxx.lua 存在，且 autoload.boost.moon/xxx.moon 也存在")
	add("      搬 2 个文件：automation/autoload/xxx.lua            →  本文件夹")
	add("                  automation/autoload.boost.moon/xxx.moon →  本文件夹")
	add("")
	add("⚠️ 情形 B 为什么必须把 .moon 一起搬走：")
	add("   .moon 是源，autoload/xxx.lua 是它编译出来的成品。只搬成品的话，下次启动会重新编译")
	add("   剩下的源，又生成一个新的 autoload/xxx.lua —— 脚本自己回来了。")
	add("   （脚本也会顺手处理这种\"没有宿主的母本\"：把它收进仓库、再从 autoload.boost.moon/ 删掉，")
	add("     所以结果同样是停用成功 —— 但母本就落到仓库里了，不如自己拿着清楚。）")
	add("")
	add("搬完不用做别的。下次启动 Aegisub 时 autoload/ 里没有它 → 不加载；下面第三项会自动更新。")
	add("")
	add("【三】现在停放在这里的脚本 —— 恢复时放回哪里")
	add("----------------------------------------------")
	add("  ★ 本段由脚本按文件夹内的实际内容生成；加进或拿走文件后，下次启动会重写这一段。")
	add("")
	if #names == 0 then
		add("  当前是空的 —— 没有停用任何脚本。")
	else
		for _, b in ipairs(names) do
			local e = scripts[b]
			add("  ● " .. b)
			if e.lua  then add(string.format("      %-46s ->  automation/autoload/", e.lua)) end
			if e.moon then add(string.format("      %-46s ->  automation/autoload.boost.moon/", e.moon)) end
			if not e.moon then add("      （这个脚本没有母本，只把 .lua 放回 automation/autoload/ 即可）") end
			if not e.lua  then add("      （没有 .lua：只放回母本，下次启动 ② 会自动编译出 autoload/" .. b .. ".lua）") end
		end
	end
	if #others > 0 then
		add("")
		add("  另外这里还有 " .. #others .. " 个非脚本文件（一般不用管）：" .. table.concat(others, " / "))
	end
	add("")
	add("规则（脚本按文件名推出来的，不必背）：")
	add("  · .lua  →  automation/autoload/               Aegisub 唯一会扫描的目录，放回即生效")
	add("  · .moon →  automation/autoload.boost.moon/    源；下次启动会自动收编并编译")
	add("恢复后重启一次 Aegisub（或 Automation ▸ Reload Automation scripts）即生效；")
	add("下一轮 audit.tsv 里它就不再是【已停用】，而是回到【一致】。")

	local text = table.concat(L, "\n") .. "\n"
	local old
	local f = io.open(DISABLEDREADME, "r")
	if f then old = f:read("a"); f:close() end
	if old == text then return end                      -- 内容没变就不写（静默轮次零写入）
	local w = io.open(DISABLEDREADME, "w")
	if w then
		w:write(text); w:close()
		log(string.format("停放区：README.txt 已按当前内容重写（停用脚本 %d 个）", #names))
	end
end


-- ============ ⑤-c 源对账 + 补入：automation/ 现场 ↔ Backup/ 仓库 ============
-- 形态改过三次，把结论记下来免得再退回去：
--   第一版：给 autoload/ 顶层"无母本"的 .lua 留活副本（Backup/autoload/）。
--   第二版：扩成"两个源目录的 1:1 实时镜像"（Backup/current/）。
--   现在：镜像层**整个删掉**。理由是实测出来的 —— 那份实时镜像与仓库逐字节全同
--     （唯一差别是系统写的 .DS_Store），每轮拷一份却零信息量。
--   ⇒ Backup/ 现在只有两样东西：
--       ① 仓库 Backup/{autoload,include} —— 源文件的完整副本，**只增不删**；
--       ② 账本 changes.log / state.tsv / audit.tsv —— 本脚本唯一会写的文件。
--   "现在长什么样"永远现读 automation/，不复制。
--   state.tsv 是本项目唯一被允许的持久状态：只用来**发现**变化，永不驱动删除/归档；
--   它丢了最坏只是少记一轮变更，绝不会误删任何东西。
local function has_master(base)
	return lfs.attributes(MOONSRC .. "/" .. base .. ".moon", "mode") == "file"
end

-- 你自己手做的 .bak 备份（X.bak / X.moon.bak-20260910-0210 / X.lua.bak-before-xxx）。
-- ③ 镜像本来就跳过它们（should_mirror 里有这条），对账也必须用同一个口径 —— 否则
-- "你删掉一个自己留的 .bak" 会被报成「丢失」，「新增」里也会混进一堆 booster 的脚本备份。
local function is_backup_name(nm)
	return nm:find("%.bak") ~= nil
end

-- 现场视图：{ 相对路径 -> { size, mtime, path } }
-- autoload/ 这一侧要看"虚拟视图"，否则每天误报：
--   · autoload.boost.moon/<名>.moon 是 ④ 从 autoload/ 搬走的东西，要还原成 autoload/<名>.moon；
--     不然用户丢一个 .moon 进来、被搬走，下一轮就会误报"源被删"。
--   · 有母本的 autoload/<名>.lua 是 ② 编译出来的产物，不是用户的源，排除。
local function scan_live()
	local view = {}
	if lfs.attributes(AUTOLOAD, "mode") == "directory" then
		local names = {}
		for name in lfs.dir(AUTOLOAD) do
			if name ~= "." and name ~= ".." and name:sub(1, 1) ~= "." and not is_backup_name(name) then
				names[#names + 1] = name
			end
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local full = AUTOLOAD .. "/" .. name
			if lfs.attributes(full, "mode") == "file" and not link_info(full) then
				local is_generated = (name:sub(-4) == ".lua") and has_master(name:sub(1, -5))
				if not is_generated then
					view["autoload/" .. name] = {
						size = lfs.attributes(full, "size") or 0,
						mtime = lfs.attributes(full, "modification") or 0,
						path = full,
					}
				end
			end
		end
	end
	if lfs.attributes(MOONSRC, "mode") == "directory" then
		for name in lfs.dir(MOONSRC) do
			-- 与 autoload/ 同一口径：母本目录里的 .bak 也不算源（今天没有，但规则要一致）
			if name:sub(-5) == ".moon" and not is_backup_name(name) then
				local full = MOONSRC .. "/" .. name
				if lfs.attributes(full, "mode") == "file" then
					view["autoload/" .. name] = {
						size = lfs.attributes(full, "size") or 0,
						mtime = lfs.attributes(full, "modification") or 0,
						path = full,
					}
				end
			end
		end
	end
	for _, zone in ipairs({ "include" }) do
		local root = ROOT .. "/automation/" .. zone
		if lfs.attributes(root, "mode") == "directory" then
			local files = {}
			collect_all(root, files)
			for _, f in ipairs(files) do
				local nm = f:match("([^/]+)$") or f
				if nm:sub(1, 1) ~= "." and not is_backup_name(nm) then
					view[zone .. "/" .. f:sub(#root + 2)] = {
						size = lfs.attributes(f, "size") or 0,
						mtime = lfs.attributes(f, "modification") or 0,
						path = f,
					}
				end
			end
		end
	end
	return view
end

-- 读上一轮指纹。文件不在 = 第一次跑，返回 nil。
local function read_state()
	local f = io.open(BASESTATE, "r")
	if not f then return nil end
	local map = {}
	for line in f:lines() do
		if line:sub(1, 1) ~= "#" then
			local rel, sz, mt = line:match("^(.-)\t(%d+)\t(%d+)$")
			-- 历史指纹要同时过两个过滤器：
			--   ① .bak 一律不算源；
			--   ② 第一段路径必须在**当前** ZONES 里（收窄范围时不会把被排除的条目误报成「删除」）。
			if rel and not is_backup_name(rel) and rel_in_zone(rel) then
				map[rel] = { size = tonumber(sz), mtime = tonumber(mt) }
			end
		end
	end
	f:close()
	return map
end

local function write_state(view)
	local f = io.open(BASESTATE, "w")
	if not f then return false end
	f:write("# Atypical.Aegisub.Startup.Boost —— 上一轮源目录指纹（脚本自动维护，不要手改）\n")
	f:write("# 格式：相对路径 <TAB> 字节数 <TAB> mtime。只用来发现变化，不驱动任何删除。\n")
	local rels = {}
	for rel in pairs(view) do rels[#rels + 1] = rel end
	table.sort(rels)
	for _, rel in ipairs(rels) do
		f:write(string.format("%s\t%d\t%d\n", rel, view[rel].size, view[rel].mtime))
	end
	f:close()
	return true
end

-- 逐字节比两个文件。比"只看 size"准，又不用引 md5 依赖。
local function same_bytes(a, b)
	local fa = io.open(a, "rb")
	if not fa then return false end
	local fb = io.open(b, "rb")
	if not fb then fa:close(); return false end
	local same = true
	while true do
		local xa = fa:read(65536)
		local xb = fb:read(65536)
		if xa ~= xb then same = false; break end
		if not xa then break end
	end
	fa:close(); fb:close()
	return same
end

-- 现场 vs 基线：只出"总账"，不改任何东西。
-- 停放区索引：autoload.boost.disabled/ 里的文件名（去扩展名）-> true。
-- 用"去扩展名"匹配，是为了让 .lua / .moon 两份都能对上同一个脚本。
local function disabled_pool()
	local pool = {}
	if lfs.attributes(DISABLEDDIR, "mode") == "directory" then
		for name in lfs.dir(DISABLEDDIR) do
			-- 只看脚本文件（.lua / .moon）：README.txt 之类的辅助文件不该参与「已停用」判定，
			-- 否则将来万一有源叫 README.moon，会被这份自述误判成「已停用」。
			local ext = name:match("%.([^%.]+)$")
			if name:sub(1, 1) ~= "." and (ext == "lua" or ext == "moon") then
				pool[(name:gsub("%.[^%.]*$", ""))] = true
			end
		end
	end
	return pool
end

-- 补入 / 同步：把现场的源文件收进仓库（Backup/）。
--   补入 = 现场有、仓库没有        -> 新出现的源，收进来（**空仓库时这一步就等于"自举"**）
--   同步 = 现场有、仓库里内容不同  -> 你改过，把副本更新成最新的
-- 仓库**只增不删**：现场删掉的东西不会从仓库里消失 —— 这正是"能恢复"的前提。
--   两处特别处理，别当成漏收：
--     · 母本以 `autoload/<名>.moon` 的身份入库（哪怕它已经被 ④ 搬进 autoload.boost.moon/）；
--     · ② 的编译产物 `.lua` 不入库（它不是你的源）。
--   代价（写在这里免得以后忘）：仓库只涨不落，"已删除"清单也会一直留着。
local function absorb(view, st)
	local added, synced, failed = 0, 0, 0
	for rel, meta in pairs(view) do
		local dst = BACKUPDIR .. "/" .. rel
		local exists = (lfs.attributes(dst, "mode") == "file")
		if (not exists) or (not same_bytes(meta.path, dst)) then
			if copy_raw(meta.path, dst) then
				if exists then synced = synced + 1 else added = added + 1 end
			else
				failed = failed + 1
				log("入库失败 " .. rel)
			end
		end
	end
	st.ab_add, st.ab_sync, st.ab_fail = added, synced, failed
	return true
end

local function write_audit(view)
	local pool = disabled_pool()
	local base = {}
	for _, zone in ipairs(ZONES) do
		local root = BACKUPDIR .. "/" .. zone
		if lfs.attributes(root, "mode") == "directory" then
			local files = {}
			collect_all(root, files)
			for _, f in ipairs(files) do
				local nm = f:match("([^/]+)$") or f
				-- 与 scan_live 同一个口径：.bak 不入账（否则它永远只能报「丢失」）
				if nm:sub(1, 1) ~= "." and not is_backup_name(nm) then
					base[zone .. "/" .. f:sub(#root + 2)] = f
				end
			end
		end
	end
	local rels = {}
	for rel in pairs(view) do rels[#rels + 1] = rel end
	for rel in pairs(base) do
		if not view[rel] then rels[#rels + 1] = rel end
	end
	table.sort(rels)
	local n_same, n_mod, n_add, n_del, n_off = 0, 0, 0, 0, 0
	local rows = {}
	for _, rel in ipairs(rels) do
		local v, b = view[rel], base[rel]
		if v and b then
			if same_bytes(v.path, b) then
				n_same = n_same + 1
				rows[#rows + 1] = "一致\t" .. rel .. "\t字节相同"
			else
				n_mod = n_mod + 1
				rows[#rows + 1] = "修改\t" .. rel .. "\t内容与基线不同"
			end
		elseif v then
			n_add = n_add + 1
			rows[#rows + 1] = "新增\t" .. rel .. "\t基线里没有"
		else
			-- 基线里有、现在 autoload/ 里没有 —— 还要再问一句：是不是你把它停用了？
			local nm = rel:match("([^/]+)$") or rel
			local stem = nm:gsub("%.[^%.]*$", "")
			if pool[stem] then
				n_off = n_off + 1
				rows[#rows + 1] = "已停用\t" .. rel .. "\t在 autoload.boost.disabled/ 里 —— 你有意停用的，不是丢了"
			else
				n_del = n_del + 1
				rows[#rows + 1] = "已删除\t" .. rel .. "\t源目录里没有了；仓库里还留着副本，可以恢复"
			end
		end
	end
	local f = io.open(AUDITTSV, "w")
	if f then
		f:write("# Atypical.Aegisub.Startup.Boost —— Backup/audit.tsv\n")
		f:write("# 现在（automation/） vs 仓库（Backup/autoload | include）\n")
		f:write("# 生成 " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
		f:write("# 仓库 = 你的源文件的完整副本（只增不删）。首次运行时自动建立，之后每轮把新出现的源补进来。\n")
		f:write("# 口径：「一致/修改/新增」说的是**本轮**；「已删除/已停用」是**累计**（删过的东西一直留在仓库里）。\n")
		f:write(string.format("# 汇总：一致 %d / 修改 %d / 新增 %d / 已删除 %d / 已停用 %d\n",
			n_same, n_mod, n_add, n_del, n_off))
		f:write("#\n# 状态\t相对路径\t说明\n")
		f:write("#   一致 —— 字节完全相同（正常态）\n")
		f:write("#   修改 —— 内容变了（你自己改过，或 boost 生成时与原始版本不同）\n")
		f:write("#   新增 —— 仓库里还没有、现场有了（含 ② 编译产物、④ 收编后的母本、新加的脚本）→ 本轮会补入仓库\n")
		f:write("#   已删除 —— 仓库里有、现场没有了。**不是丢失**：仓库里那份副本还在，拷回去就能恢复。\n")
		f:write("#   已停用 —— 「已删除」里的一种：在 autoload.boost.disabled/ 里找到了同名脚本。\n")
		f:write("#            这是你有意停用的（停用脚本就该放在那儿）。\n")
		f:write("#   注：名字带 .bak 的文件不入账 —— 那是你自己留的备份，本就不参与镜像与对账。\n")
		for _, r in ipairs(rows) do f:write(r .. "\n") end
		f:close()
	end
	return n_same, n_mod, n_add, n_del, n_off
end

-- 每轮：① 现场 vs 上轮指纹 -> changes.log；② 现场 vs 基线 -> audit.tsv（仅在真有变化时重算）
local function audit_sources(st)
	local view = scan_live()
	local n_total = 0
	for _ in pairs(view) do n_total = n_total + 1 end
	local prev = read_state()
	local audited = false

	if prev == nil then
		st.ch_same = n_total      -- 首轮没有"上一轮"可比，把整棵树记成"未变"，
		                          -- 这样"新增+修改+删除+未变"在首轮也等于文件总数，不会显示成 0
		changes_line(string.format("首次建立指纹：%d 个源文件（此后每轮只记增量）", n_total))
	else
		local rels = {}
		for rel in pairs(view) do rels[#rels + 1] = rel end
		for rel in pairs(prev) do
			if not view[rel] then rels[#rels + 1] = rel end
		end
		table.sort(rels)
		for _, rel in ipairs(rels) do
			local a, b = prev[rel], view[rel]
			if not b then
				st.ch_del = st.ch_del + 1
				changes_line(string.format("删除  %-56s （源目录里已不存在）", rel))
			elseif not a then
				st.ch_add = st.ch_add + 1
				changes_line(string.format("新增  %-56s （%d B）", rel, b.size))
			elseif a.size ~= b.size or a.mtime ~= b.mtime then
				st.ch_mod = st.ch_mod + 1
				changes_line(string.format("修改  %-56s （%d B -> %d B）", rel, a.size, b.size))
			else
				st.ch_same = st.ch_same + 1
			end
		end
	end
	-- 每轮都重算（去掉了原来的"只在源变了时才重算"门控）。
	-- 仓库模型下沿用旧结果会和事实不一致：补入之后本来该显示"一致"，却还挂着上一轮的「新增」。
	-- 代价是每轮把源逐字节比一遍（~130 个文件，几毫秒），换"文件里说的话永远是真的"，值。
	st.au_same, st.au_mod, st.au_add, st.au_del, st.au_off = write_audit(view)
	audited = true
	-- ⚠️ 顺序：**先对账、后补入**。
	--    反过来（先补入再对账）的话，本轮的变化会立刻被抹平 ——
	--    audit.tsv 里永远是"全一致"，"变了什么"这个信息就没了。
	absorb(view, st)
	write_state(view)
	return audited
end

-- 母本对账：autoload/<同名>.lua 不存在 = 该脚本已被删除 -> 归档母本。
-- ⚠️ 必须跑在 ② 之前。实测踩过的坑：② 会无差别编译 MOONSRC 里的每个 .moon，
--    若先跑 ②，一个没有宿主的母本会被重新编译成 autoload/<名>.lua ——
--    等于把用户刚删掉的脚本又复活了，而且复活后再也看不出它该被清理。
-- 归档前先"试编译"到临时文件：编不出来说明母本自己有问题（不是"被删除"），原样保留 ——
--    绝不用本脚本的编译能力去判定用户的源该不该留。
local function reap_mothers(st)
	if lfs.attributes(MOONSRC, "mode") ~= "directory" then return end
	local names = {}
	for name in lfs.dir(MOONSRC) do
		if name:sub(-5) == ".moon" then names[#names + 1] = name end
	end
	for _, name in ipairs(names) do
		local base = name:sub(1, -6)
		if lfs.attributes(AUTOLOAD .. "/" .. base .. ".lua", "mode") ~= "file" then
			local probe = CACHEDIR .. "/.reap-probe.lua"
			os.remove(probe)                                     -- 清掉上轮残留，避免"已最新"短路
			local r, _, err = build(MOONSRC .. "/" .. name, probe)
			os.remove(probe)
			if r == "fail" then
				log("母本保留（试编译失败，不归档）：" .. name .. " :: " .. tostring(err))
			else
				-- **不再归档进 Trash**（已取消）：改成直接删，但**先确认仓库里有副本**。
				--   仓库里那份来自"虚拟视图"—— 母本一直以 autoload/<名>.moon 的身份入库，
				--   所以正常情况下一定有；恢复 = 从 Backup/autoload/<名>.moon 拷回 autoload/。
				--   为什么必须删：不删的话 ② 下一轮就把它编回 autoload/<名>.lua —— **脚本复活**。
				--   没有副本时**绝不删**：宁可多留一个母本，也不要制造"唯一副本被删掉"。
				-- 先确保仓库里有这份母本，**再**删。多这一步是因为：
				--   ⑤-a 跑在 ⑤-c 的"补入"之前，所以"刚丢进 MOONSRC、还没进过 live 视图"的母本
				--   此刻仓库里还没有 —— 直接删就成"删掉唯一副本"了。先入库，删除就永远安全。
				local dst = BACKUPDIR .. "/autoload/" .. name
				local have = (lfs.attributes(dst, "mode") == "file")
				if not have then
					have = copy_raw(MOONSRC .. "/" .. name, dst)
					if have then
						log(string.format("入库 autoload/%-49s （无宿主的母本，先存进仓库再移除）", name))
					end
				end
				if have then
					local oka, erra = os.remove(MOONSRC .. "/" .. name)
					if oka then
						st.reaped = st.reaped + 1
						log(string.format("移除母本 autoload/%-49s （仓库里已有副本；autoload/%s 已不存在）", name, base .. ".lua"))
					else
						log("移除母本失败（原样保留）" .. name .. " :: " .. tostring(erra))
					end
				else
					log("母本保留（入库失败，不敢删）：" .. name)
				end
			end
		end
	end
end

-- 仓库里有没有这个产物对应的**源**？
--   产物的相对路径（相对 include.boost.lua/）与源（相对 include/）同构，只有扩展名可能不同：
--     include/pkg/a.moon  --编译-->  pkg/a.lua      候选：pkg/a.lua（镜像产物）/ pkg/a.moon（编译产物）
--     include/Top.lua     --镜像-->  Top.lua        候选：Top.lua
-- 找不到就**别删产物** —— 删了就真没了。这是"绝不硬删"这条老规矩的新落点：
-- 以前靠 archive 进 Trash 保命，现在靠"仓库里有源"来判定。
local function repo_has_source(rel)
	for _, c in ipairs({ rel, (rel:gsub("%.lua$", ".moon")) }) do
		if lfs.attributes(BACKUPDIR .. "/include/" .. c, "mode") == "file" then return true end
	end
	-- 兜底：老版本 pass ② 会把 autoload 的母本按**模块路径**写进产物树
	-- （`a-mo.Aegisub-Motion.moon` -> `a-mo/Aegisub-Motion.lua`）。这类产物的"源"不在 include 侧，
	-- 而在 autoload 侧。把斜杠换成点再找一次 —— 历史遗留的孤儿产物就是这个形状。
	local dotted = (rel:gsub("%.[^%.]*$", "")):gsub("/", ".")
	for _, z in ipairs({ "autoload", "include" }) do
		for _, ext in ipairs({ ".moon", ".lua" }) do
			if lfs.attributes(BACKUPDIR .. "/" .. z .. "/" .. dotted .. ext, "mode") == "file" then
				return true
			end
		end
	end
	return false
end

local function cleanup(exp, st)
	-- (1) 产物目录里没有对应源的文件
	-- st.scanned = 扫描到的产物文件个数；st.want = 判定该删的个数（删成没成另算）；
	-- st.rm_fail = 删除失败个数。三者一起看，就能区分"没扫到"和"删不掉"。
	st.scanned, st.hidden, st.rm_fail, st.want = 0, 0, 0, 0
	local files, dirs = {}, {}
	walk_rel(DST, "", files, dirs)
	st.scanned = #files
	for _, rel in ipairs(files) do
		local nm = rel:match("([^/]+)$") or rel
		if not exp[rel] then
			if nm:sub(1, 1) == "." then
				st.hidden = st.hidden + 1        -- 隐藏文件（.DS_Store 之类）不是本脚本产物，不碰
			elseif not repo_has_source(rel) then
				-- 仓库里找不到这个产物对应的源 ⇒ 它可能是那份内容**仅存的形式**，不删。
				-- （正常的历史孤儿产物，源都还在仓库里，所以会被正常删掉；这条只兜真正的例外。）
				st.nosrc = st.nosrc + 1
				log("产物保留（仓库里找不到对应源，删了就真没了）" .. rel)
			else
				st.want = st.want + 1
				-- 不再归档进 Trash：源在仓库里，删掉即可（要恢复就从仓库拷回 include/）。
				-- ⚠️ 失败时**保持原样**，绝不退回 rm 硬删 —— 宁可留着。
				local p = DST .. "/" .. rel
				local okr, errr = os.remove(p)
				if okr then
					st.removed = st.removed + 1
					log(string.format("删除产物 include/%-45s （源已不存在，仓库里有副本）", rel))
				else
					-- 失败绝不静默：曾经判定该删若干、结果一个都没动且无任何报错，白查了半天。
					st.rm_fail = st.rm_fail + 1
					log("删除产物失败（保持原样）" .. rel .. " :: " .. tostring(errr))
				end
			end
		end
	end

	-- (2) 顺手清掉被腾空的目录（自底向上：长的路径必然更深）
	table.sort(dirs, function(a, b) return #a > #b end)
	for _, rel in ipairs(dirs) do
		local p = DST .. "/" .. rel
		if dir_empty(p) then
			-- ⚠️ 本 fork 的 lfs.rmdir **返回值不可信**：它走 number_ret = tonumber(res)，
			--    成功时 res 可能是布尔 true → tonumber(true) = nil → 明明删掉了也报失败
			--    （自检里那句"删空目录 FAIL[rmdir 失败]"就是这个假象，不是真的删不掉）。
			--    所以这里一律以"路径还在不在"为准，不信返回值。
			local gone = false
			lfs.rmdir(p)
			if lfs.attributes(p, "mode") == nil then gone = true end
			if not gone then
				os.remove(p)                              -- POSIX remove() 对空目录等同 rmdir
				if lfs.attributes(p, "mode") == nil then gone = true end
			end
			if gone then
				st.rmdirs = st.rmdirs + 1
				log(string.format("收空目录 %-56s （产物已清空）", rel .. "/"))
			else
				log("清空目录失败 " .. rel .. "（lfs.rmdir 与 os.remove 都没删掉）")
			end
		end
	end

	-- (3) 母本归档不在这里做 —— 它必须在 ② 之前跑，见 reap_mothers()

	-- (4) 符号链接对账（只在确知是本脚本所建时才动手）
	if LINK_RECONCILE then
		local n_link_checked = 0
		for name in lfs.dir(AUTOLOAD) do
			if name ~= "." and name ~= ".." then
				local full = AUTOLOAD .. "/" .. name
				local isl, tg = link_info(full)
				if isl then
					n_link_checked = n_link_checked + 1
					if lfs.attributes(full, "mode") == nil then          -- 悬空
						if tg == nil or tg:sub(1, #LINKPREFIX) == LINKPREFIX then
							local okd, errd = os.remove(full)
							if okd then
								st.link_del = st.link_del + 1
								log("删链接   autoload/" .. name .. " -> " .. (tg or "?"))
							else
								log("删悬空链接失败 " .. name .. " :: " .. tostring(errd))
							end
						end
					end
				end
			end
		end
		local n_link_add = 0
		for name in lfs.dir(DST) do
			if name ~= "." and name ~= ".." and not name:find(".", 1, true) then   -- 带点的名字（Yutils.lua）不建链
				local dstp = DST .. "/" .. name
				local linkp = AUTOLOAD .. "/" .. name
				if lfs.attributes(dstp, "mode") == "directory" then
					local isl = link_info(linkp)
					if not isl and lfs.attributes(linkp, "mode") == nil then
						if make_symlink(LINKPREFIX .. name, linkp) then
							st.link_add = st.link_add + 1
							log("加链接   autoload/" .. name .. " -> " .. LINKPREFIX .. name)
						else
							log("链接创建失败 autoload/" .. name .. "（不影响功能，仅少一处加速）")
						end
					end
				end
			end
		end
		local n_link_have = 0
		for name in lfs.dir(AUTOLOAD) do
			if name ~= "." and name ~= ".." then
				if link_info(AUTOLOAD .. "/" .. name) then n_link_have = n_link_have + 1 end
			end
		end
		st.link_have = n_link_have
	end

end

-- 产物清单（每次启动覆盖重写）。纯审计用：清理判定走 expected_map，不读这个文件。
local function write_manifest(exp)
	local f = io.open(MANIFEST, "w")
	if not f then return 0, 0 end
	f:write("# Atypical.Aegisub.Startup.Boost —— 产物清单（每次启动重写；仅供审计，清理不依赖它）\n")
	f:write("# 生成 " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
	f:write("# 类型\t源（master）\t产物（artifact）\t状态\n")
	f:write("#\n")
	f:write("# ● 类型取值\n")
	f:write("#   compile —— .moon 预编译而来（源在 automation/include/）\n")
	f:write("#   mirror  —— 原生文件 1:1 复刻（不是 .moon，无编译，目标就是照搬整棵 include 树）\n")
	f:write("#   adopt   —— autoload 脚本的母本，住在 automation/autoload.boost.moon/\n")
	f:write("#   link    —— automation/autoload/ 里的包目录符号链接（借道加速，不是产物文件）\n")
	f:write("#\n")
	f:write("# ● 状态取值\n")
	f:write("#   已就位 N B —— 产物存在，占 N 字节。这是正常态。               （compile / mirror）\n")
	f:write("#   缺失       —— 源还在、产物却查不到，本应已生成。异常，看 build.log。（compile / mirror）\n")
	f:write("#   在岗       —— 母本有宿主 autoload/<名>.lua，脚本正在使用。       （adopt）\n")
	f:write("#   无宿主     —— 母本没有对应 autoload/<名>.lua，下次启动移除（仓库里有副本）。（adopt）\n")
	f:write("#   有效       —— 链接目标存在，可正常借道。                       （link）\n")
	f:write("#   悬空       —— 链接目标不存在，下次启动删除。                   （link）\n")
	f:write("#\n")
	f:write("# 规则：源消失 -> 下次启动删掉对应产物/母本，**但删之前先确认 Backup 仓库里有对应副本**；\n")
	f:write("#       仓库里找不到就保留并记日志（绝不制造「唯一副本被删掉」）。\n")
	f:write("#       恢复 = 从 Backup/ 拷回 automation/ 对应位置。账本见 Backup/changes.log 与 Backup/audit.tsv。\n")

	local have, missing = 0, 0
	if exp then
		local rels = {}
		for rel in pairs(exp) do rels[#rels + 1] = rel end
		table.sort(rels)
		for _, rel in ipairs(rels) do
			local e = exp[rel]
			local p = DST .. "/" .. rel
			local sz = lfs.attributes(p, "size")
			if sz then have = have + 1 else missing = missing + 1 end
			f:write(string.format("%s\t%s\t%s\t%s\n", e.kind, e.src, p,
				sz and ("已就位 " .. sz .. " B") or "缺失"))
		end
	else
		f:write("#（本次未算出应有集合：源目录不齐，已跳过清理）\n")
	end

	if lfs.attributes(MOONSRC, "mode") == "directory" then
		local ns = {}
		for name in lfs.dir(MOONSRC) do
			if name:sub(-5) == ".moon" then ns[#ns + 1] = name end
		end
		table.sort(ns)
		for _, name in ipairs(ns) do
			local base = name:sub(1, -6)
			local master = AUTOLOAD .. "/" .. base .. ".lua"
			f:write(string.format("adopt\t%s\t%s\t%s\n", master, MOONSRC .. "/" .. name,
				lfs.attributes(master, "mode") and "在岗" or "无宿主（下次归档）"))
		end
	end

	if lfs then
		local ls = {}
		for name in lfs.dir(AUTOLOAD) do
			if name ~= "." and name ~= ".." then
				local full = AUTOLOAD .. "/" .. name
				local isl, tg = link_info(full)
				if isl then
					ls[#ls + 1] = { name = name, tg = tg, ok = lfs.attributes(full, "mode") ~= nil }
				end
			end
		end
		table.sort(ls, function(a, b) return a.name < b.name end)
		for _, l in ipairs(ls) do
			f:write(string.format("link\t%s\tautoload/%s\t%s\n", l.tg or "?", l.name,
				l.ok and "有效" or "悬空（下次删除）"))
		end
	end
	f:close()
	return have, missing
end

-- ========================== 环境自检（DIAG=true 时跑一次） ==========================
-- 起因：第一次跑 ⑤ 时判定该删若干孤儿产物，日志却记"删产物 0"，且没有任何报错。
-- 静默失败最费时间，所以这里直接问环境：写/删/改名/建链接到底行不行、attributes 跟不跟随链接。
--
-- 改成**同一个脚本版本只跑一次**（用脚本自身的 size+mtime 当版本指纹，
-- 落在 cache/.diag-stamp）。这样 DIAG 可以一直留 true，不必为了关它多重启一轮。
local DIAG_STAMP = CACHEDIR .. "/.diag-stamp"

local function self_stamp()
	-- 认的是"Aegisub 会加载的那个位置"，不是"当前正在执行的这份文件"——
	-- 两者在 Aegisub 里是同一个文件；离线调试时执行的可能是副本，于是这里取不到（属正常）。
	-- 名字由 SELFNAME 从执行位置推导，所以改名/搬目录都不会让指纹失效。
	local me = SELFNAME and (AUTOLOAD .. "/" .. SELFNAME)
	if not me then return "unknown" end
	return tostring(lfs.attributes(me, "size")) .. "|" .. tostring(lfs.attributes(me, "modification"))
end

local function selftest_due()
	if not DIAG then return false end
	local w = self_stamp()
	local f = io.open(DIAG_STAMP, "r")
	if f then
		local s = f:read("*a")
		f:close()
		if s == w then return false end        -- 脚本没变过，不再重复自检
	end
	return true
end

local function selftest_done()
	local f = io.open(DIAG_STAMP, "w")
	if f then f:write(self_stamp()); f:close() end
end

local function selftest()
	mkdirp(CACHEDIR)
	local function rr(ok, err)
		return ok and "OK" or ("FAIL[" .. tostring(err) .. "]")
	end

	log("自检：os.remove=" .. type(os.remove) .. " os.rename=" .. type(os.rename)
		.. " os.execute=" .. type(os.execute) .. " io.popen=" .. type(io.popen))
	log("自检：lfs.symlinkattributes=" .. type(lfs.symlinkattributes) .. " lfs.link=" .. type(lfs.link)
		.. " lfs.mkdir=" .. type(lfs.mkdir) .. " lfs.rmdir=" .. type(lfs.rmdir))

	-- 1) 建 → 删
	local p1 = CACHEDIR .. "/.diag-write-remove.txt"
	local f1 = io.open(p1, "w")
	if f1 then f1:write("x"); f1:close() end
	local fr = io.open(p1, "r")
	local exists = (fr ~= nil)
	if fr then fr:close() end
	local r1, e1 = os.remove(p1)
	log("自检：建文件 " .. rr(exists, "创建失败") .. "；再删除 " .. rr(r1, e1))

	-- 2) 改名
	local p2 = CACHEDIR .. "/.diag-rn-a.txt"
	local p3 = CACHEDIR .. "/.diag-rn-b.txt"
	local f2 = io.open(p2, "w")
	if f2 then f2:write("a"); f2:close() end
	local r2, e2 = os.rename(p2, p3)
	log("自检：改名 " .. rr(r2, e2) .. "；清理 " .. rr(os.remove(p3), "无文件"))
	os.remove(p2)

	-- 3) 符号链接（决定 autoload/ 链接对账能不能自动跑）
	local dt = CACHEDIR .. "/.diag-target-dir"
	local dl = CACHEDIR .. "/.diag-link"
	local mk, mke = lfs.mkdir(dt)
	os.remove(dl)
	local r3 = make_symlink(dt, dl)
	local md = lfs.attributes(dl, "mode")
	log("自检：建目录 " .. rr(mk ~= nil or lfs.attributes(dt, "mode") == "directory", tostring(mke))
		.. "；建符号链接 " .. rr(r3, "ln -s 失败"))
	log("自检：lfs.attributes(链接,'mode') = " .. tostring(md)
		.. "   ← 若是 directory 说明 attributes 会跟随链接（symlinkattributes 缺失时需另想办法）")
	local r4, e4 = os.remove(dl)
	log("自检：删符号链接 " .. rr(r4, e4))

	-- 4) ★ walk_rel 的真根因取证：attributes 不带 field 时到底给出什么
	--    探针路径用"自己建的临时文件 + include 源目录"，两者在任何环境下都必然存在
	local dump
	dump = function(t)
		if type(t) ~= "table" then return "<" .. type(t) .. "=" .. tostring(t) .. ">" end
		local ks = {}
		for k, v in pairs(t) do ks[#ks + 1] = k .. "=" .. tostring(v) end
		table.sort(ks)
		return "{" .. table.concat(ks, ", ") .. "}"
	end
	local pf = CACHEDIR .. "/.diag-attr-probe.txt"
	local fh = io.open(pf, "w")
	if fh then fh:write("x"); fh:close() end
	local pdir = SRCS[1] or DST
	log("自检：attributes(普通文件) 带field=" .. tostring(lfs.attributes(pf, "mode"))
		.. " / 不带field=" .. dump(lfs.attributes(pf)))
	log("自检：attributes(目录 " .. pdir .. ") 带field=" .. tostring(lfs.attributes(pdir, "mode"))
		.. " / 不带field=" .. dump(lfs.attributes(pdir))
		.. "   ← 不带 field 若得到 nil，就是 walk_rel 当初失效的根因")
	os.remove(pf)

	-- 5) 二级目录能不能列举（walk_rel 递归的前提条件）
	local sub = nil
	for nm in lfs.dir(DST) do
		if nm ~= "." and nm ~= ".." and lfs.attributes(DST .. "/" .. nm, "mode") == "directory" then
			sub = nm
			break
		end
	end
	local ok2, n2 = pcall(function()
		local n = 0
		for nm in lfs.dir(DST .. "/" .. tostring(sub)) do
			if nm ~= "." and nm ~= ".." then n = n + 1 end
		end
		return n
	end)
	log("自检：二级 lfs.dir(第一个子目录 " .. tostring(sub) .. ") 条目数 = "
		.. (ok2 and tostring(n2) or ("出错 " .. tostring(n2))) .. "（0 或出错 = 递归不可能工作）")
	local ok3, n3 = pcall(function()
		local n = 0
		for nm in lfs.dir(DST) do if nm ~= "." and nm ~= ".." then n = n + 1 end end
		return n
	end)
	log("自检：一级 lfs.dir(include.boost.lua) 条目数 = " .. (ok3 and tostring(n3) or ("出错 " .. tostring(n3))))

	-- 6) 直接数一遍（走的就是 cleanup 用的那个 walk_rel）
	local wf, wd = {}, {}
	walk_rel(DST, "", wf, wd)
	local wh = 0
	for _, r in ipairs(wf) do
		if ((r:match("([^/]+)$") or r):sub(1, 1) == ".") then wh = wh + 1 end
	end
	-- 期望值按源现状实时推算（调的就是 ⑤ 用的 expected_map，口径绝对一致），不写死常量：
	-- 写死常量的话，源一增减它就变成假警报（"差"永远不为 0，看着像脚本坏了）。
	-- 注：自检跑在本轮编译之前，若刚加了源还没编译，差为负属正常。
	local exp_n = nil
	local ek, em = pcall(expected_map)
	if ek then
		exp_n = 0
		for _ in pairs(em) do exp_n = exp_n + 1 end
	end
	log("自检：walk_rel(DST) 扫到 " .. #wf .. " 个文件（隐藏 " .. wh .. "）/ " .. #wd .. " 个目录"
		.. "   ← 按源推算应有 " .. (exp_n and tostring(exp_n) or "?（推算失败）")
		.. " 个（差 " .. (exp_n and (#wf - wh - exp_n) or "-") .. "；差 0 为正常）")

	-- ⚠️ 判"删空目录成没成"要看路径在不在，不看返回值（见 cleanup 里的长注释）
	local rd = lfs.rmdir(dt)
	local gone = (lfs.attributes(dt, "mode") == nil)
	log("自检：删空目录 " .. (gone and "OK" or "FAIL[目录仍在]") .. "（返回值 rd=" .. tostring(rd) .. " 不可信，仅为留证）")
	log("自检：lfs.mkdir 返回值 mk=" .. tostring(mk) .. "（同上，成功也可能是 nil）")
end

local function run()
	if not ROOT_OK then return end          -- 路径推导失败：本轮什么都不做（见文件头"路径推导"段）
	local ok
	ok, lfs = pcall(require, "lfs")
	if not ok or not lfs then return end
	-- 最后一道：推导出来的 ROOT 必须**真的是个目录**。宁可这一轮什么都不做，
	-- 也不能把产物与仓库建到一个不存在的地方 —— 那会让 ⑤ 的每一条判断都落空，
	-- 而且表面上不会报任何错。（推导里已经挡掉了"解不出来的说明符"，这里挡的是"路径存在但不对"。）
	if lfs.attributes(ROOT, "mode") ~= "directory" then return end
	ok, moonscript = pcall(require, "moonscript")
	if not ok or not moonscript or not moonscript.to_lua then return end

	mkdirp(CACHEDIR)
	logf = io.open(LOGP, "a")
	if not logf then return end
	-- 每轮留一行分隔：否则"没跑"与"跑了但没动作"长得一模一样，日志反而制造歧义。
	-- （原先是 cleanup.log 开头那行的职责，合并日志后由 build.log 自己承担。）
	logf:write("---- " .. os.date("%Y-%m-%d %H:%M:%S") .. " ----\n")

	-- 源目录：用户自己的 include 一定在；内置 include 取第一个**真存在**的候选
	-- （它的位置随平台与打包方式变，所以不能写死，见文件头 app_include_candidates）。
	-- 这里记一行日志 —— 出问题时看这一行就知道脚本到底认了哪些目录。
	MIRROR_SRCS = { ROOT .. "/automation/include" }
	SRCS        = { ROOT .. "/automation/include" }
	for _, c in ipairs(app_include_candidates()) do
		if lfs.attributes(c, "mode") == "directory" then
			SRCS[#SRCS + 1] = c
			break
		end
	end
	log("路径：ROOT=" .. ROOT .. "   源=" .. table.concat(SRCS, " | "))

	-- Backup/ 常驻（含自述），主目录也放一份说明。惰性创建会让用户"找不到"，见函数上的注释。
	mkdirp(BACKUPDIR)
	ensure_readmes()
	-- 停放区也常驻 + 生成自述：首次运行就建出来，README 第三项随内容更新。
	mkdirp(DISABLEDDIR)
	write_disabled_readme()
	-- 仓库的首轮填充不需要单独一步：⑤-c 的"补入"在空仓库时就是把现场抄进来（= 自举）。

	if DIAG and selftest_due() then
		log("自检：---- 脚本版本已变化，跑一次环境自检 ----")
		local okd, errd = pcall(selftest)
		if not okd then log("自检本身出错（不影响后续）：" .. tostring(errd)) end
		selftest_done()          -- 无论成败都记账：同一版本不再重复自检
	end

	local built, skipped, failed = 0, 0, 0
	local total_cost = 0
	-- ⑤ 的统计：reap_mothers 跑在 ② 之前，所以在这里先声明
	local st = { removed = 0, rmdirs = 0, reaped = 0, link_add = 0, link_del = 0,
	             nosrc = 0, hidden = 0, scanned = 0, want = 0, rm_fail = 0,
	             link_have = 0,
	             ch_add = 0, ch_mod = 0, ch_del = 0, ch_same = 0,
	             au_same = 0, au_mod = 0, au_add = 0, au_del = 0, au_off = 0,
	             ab_add = 0, ab_sync = 0, ab_fail = 0 }

	-- ① 被 require 的模块目录
	for _, s in ipairs(SRCS) do
		if lfs.attributes(s, "mode") == "directory" then
			local files = {}
			collect(s, files)
			for _, src in ipairs(files) do
				if built >= MAX_PER_RUN then break end
				local rel
				for _, base in ipairs(SRCS) do
					if src:sub(1, #base) == base then
						rel = src:sub(#base + 2)
						break
					end
				end
				if not rel then rel = src:match("([^/]+)$") or src end
				local r, cost, err = build(src, DST .. "/" .. rel:gsub("%.moon$", ".lua"))
				if r == "built" then built = built + 1; total_cost = total_cost + cost
				elseif r == "fresh" then skipped = skipped + 1
				else failed = failed + 1; log("COMPILE FAIL " .. rel .. " :: " .. tostring(err)) end
			end
		end
	end

	-- ④ 收编：autoload/ 顶层新出现的 .moon
	--    刻意放在 ② 之前 —— 新丢进来的母本要压过 MOONSRC 里的旧同名母本，
	--    ② 随后读到它时只会判定为"已最新"，不会用旧母本覆盖刚写好的 .lua。
	local adopted, conflict = adopt()


	-- ⑤-a 母本对账（必须在 ② 之前：否则没宿主的母本会被 ② 复活）
	reap_mothers(st)

	-- ② autoload 脚本自身：母本 .moon 存于 autoload.boost.moon/，编译品直接落到 autoload/<同名>.lua
	--    这样 Aegisub 扫到的是纯 Lua，完全跳过 MoonScript 现编译。
	--    注意：autoload 扫描是 *.* 且不递归，两者不能同名共存（会双重加载、宏重复注册），
	--    所以 .moon 一旦移入 autoload.boost.moon/ 就不能再放回 autoload。
	local al_cost = 0
	if lfs.attributes(MOONSRC, "mode") == "directory" then
		for name in lfs.dir(MOONSRC) do
			if name:sub(-5) == ".moon" then
				local dstname = name:sub(1, -6) .. ".lua"   -- phos.EditTags.moon -> phos.EditTags.lua
				local r, cost, err = build(MOONSRC .. "/" .. name, AUTOLOAD .. "/" .. dstname)
				if r == "built" then
					built = built + 1; al_cost = al_cost + cost
					log(string.format("autoload 编译 %-38s (-> %s)", name, dstname))
				elseif r == "fresh" then
					skipped = skipped + 1
				else
					failed = failed + 1
					log("AUTOLOAD FAIL " .. name .. " :: " .. tostring(err))
				end
			end
		end
	end

	-- ③ 镜像 include/ 下非 .moon 的原生文件 —— 让 include.boost.lua/ 成为 include/ 的完整镜像，
	--    所有 require 都在 package.path 第 1 项命中，不再落回 include/ 原件。
	local mirrored, m_fresh, m_fail = 0, 0, 0
	for _, s in ipairs(MIRROR_SRCS) do
		if lfs.attributes(s, "mode") == "directory" then
			local files = {}
			collect_all(s, files)
			for _, src in ipairs(files) do
				local name = src:match("([^/]+)$") or src
				if should_mirror(name) then
					local rel
					for _, base in ipairs(SRCS) do
						if src:sub(1, #base) == base then
							rel = src:sub(#base + 2)
							break
						end
					end
					if rel then
						local r = copy_if_newer(src, DST .. "/" .. rel)
						if r == "built" then
							mirrored = mirrored + 1
							log("镜像 " .. rel)
						elseif r == "fresh" then
							m_fresh = m_fresh + 1
						else
							m_fail = m_fail + 1
							log("MIRROR FAIL " .. rel)
						end
					end
				end
			end
		end
	end

	-- ⑤-b 对账清理：删源即删产物（推算式，不读历史记录）
	local exp, srcs_ok = nil, true
	for _, s in ipairs(SRCS) do
		if lfs.attributes(s, "mode") ~= "directory" then srcs_ok = false end
	end
	if srcs_ok then
		exp = expected_map()
		if CLEANUP_ENABLED then cleanup(exp, st) end
	else
		log("清理跳过：源目录不齐（app 被移动/卸载？），本轮不做任何删除。")
	end
	-- ⑤-c 源对账：拿 automation/ 的现场去比 Backup/ 的基线，把变化写进变更账。
	--    放在所有 pass 之后跑，读到的是本轮**安定后**的现场（② 编译出的 .lua、④ 搬走的 .moon 都已就位）。
	local au_done = audit_sources(st)

	local n_have, n_missing = write_manifest(exp)

	log(string.format("完成：新编译 %d / 已最新 %d / 失败 %d / 编译耗时 模块%.1fs + autoload%.1fs",
		built, skipped, failed, total_cost, al_cost))
	log(string.format("镜像：新复制 %d / 已最新 %d / 失败 %d", mirrored, m_fresh, m_fail))
	log(string.format("收编：新收 %d 个 .moon（旧同名母本另存 %d）", adopted, conflict))
	if au_done then
		log(string.format("对账：一致 %d / 修改 %d / 新增 %d / 已删除 %d / 已停用 %d  -> Backup/audit.tsv",
			st.au_same, st.au_mod, st.au_add, st.au_del, st.au_off))
		log(string.format("仓库：补入 %d / 同步 %d / 失败 %d（Backup 只增不删）",
			st.ab_add, st.ab_sync, st.ab_fail))
	else
		log("对账：源目录本轮无变化，audit.tsv 沿用上次")
	end
	log(string.format("变更：新增 %d / 修改 %d / 删除 %d / 未变 %d  -> Backup/changes.log",
		st.ch_add, st.ch_mod, st.ch_del, st.ch_same))
	if exp and CLEANUP_ENABLED then
		log(string.format("清理：扫描 %d 个产物文件（隐藏 %d）/ 判定该清 %d / 已删除 %d / 删除失败 %d",
			st.scanned, st.hidden, st.want, st.removed, st.rm_fail))
		log(string.format("清理：清空目录 %d / 移除母本 %d / 链接 现有%d (+%d -%d) / 无源保留 %d",
			st.rmdirs, st.reaped, st.link_have, st.link_add, st.link_del, st.nosrc))
	elseif exp then
		log("清理：已关闭（CLEANUP_ENABLED=false），本轮只审计不删除。")
	else
		log("清理：已跳过（源目录不齐）。")
	end
	log(string.format("清单：应有产物 %d / 已就位 %d / 缺失 %d -> manifest.tsv", n_have + n_missing, n_have, n_missing))
	if failed > 0 then
		log("注意：失败文件仍走原 .moon 路径，功能不受影响。")
	end

	-- 原先这里往 cleanup.log 写一行「本轮：…」汇总。该文件并入 build.log 后删掉：
	-- 它逐字段与上面两行「清理：…」重复，而"每轮留痕"由本函数开头的 "---- 时间 ----" 承担。
	changes_line(string.format("本轮：新增 %d / 修改 %d / 删除 %d / 未变 %d",
		st.ch_add, st.ch_mod, st.ch_del, st.ch_same))
	changes_line(string.format("仓库：补入 %d / 同步 %d（Backup 只增不删，删掉的还在仓库里）",
		st.ab_add, st.ab_sync))

	logf:close()
	if changesf then changesf:close(); changesf = nil end
end

local ok, err = pcall(run)
if not ok and logf then
	log("脚本异常: " .. tostring(err))
	logf:close()
end

-- 不注册任何宏，静默返回
