# HiSleep — 设计文档

> 让 MacBook「该睡就睡」。合盖时无视流氓 App 的电源声明,强制摁进睡眠。
> 模式:Builder(自用 + 练手) · 日期:2026-06-15

---

## 1. 问题

MacBook Pro 合盖后本应立刻睡眠,但有些 App 持有 macOS 的 **power assertion(电源保持声明)**,
让系统认为「现在不能睡」。结果:笔记本在包里继续运行、发烫、耗电,你往往等到电掉光或机身发烫
才发现。

**当前工作流(状态现状):** 事后手动跑 `pmset -g assertions` 揪出真凶。
问题在于这是滞后的——合盖之后你根本看不到任何东西。

**为什么这个题目值得做:** 市面上出名的同类工具(Amphetamine、InsomniaZ、SleepSleuth)
几乎全是反方向的——「让 Mac 别睡」。而「让 Mac 该睡就睡、别被流氓拦着」这个方向几乎没人正经做。
这是一个被忽视的真实缝隙。

---

## 2. 核心行为(已锁定)

**合盖 → 强制睡,不商量。**

- 不需要白名单(用户「几乎从不」故意让笔记本合盖后继续干活)。
- 不需要弹窗征求意见(合盖后你也看不到弹窗)。
- 默认铁腕,配置越少越好。

这是最简、最不易出 bug 的版本。

---

## 3. 关键技术事实(已用真实数据修正)

**实测观察(2026-06-13,用户机器):** `PreventSystemSleep` = 0,拦睡的都是
`PreventUserIdleSystemSleep`(ToDesk + coreaudiod 代持的音频);关掉这些 App 后合盖就正常睡。

> ⚠️ **归因要谨慎(经 Codex 审核修正):** 「关掉这些 App 就睡」只能说明它们**相关**,
> 不能断定 idle assertion 是唯一原因。Apple 语义上 `PreventUserIdleSystemSleep` 只挡
> 「空闲睡眠」,理论上不挡「合盖睡眠」。合盖不睡的真正系统级判定是
> **`AppleClamshellCausesSleep`**(IOPMrootDomain 属性):它为 false 时,系统就认为
> 「这次合盖不该睡」(典型:接电源 + 外接显示器 + 外接键鼠的 clamshell 模式)。
> 远程桌面/音频链路也可能同时改变显示、网络、HID、外接屏状态,不止一个 assertion。

技术要点:

- 合盖 → 睡眠的决策在内核的 **IOPMrootDomain**;关键属性是 `AppleClamshellState`(盖子开/关)
  和 `AppleClamshellCausesSleep`(这次合盖该不该睡)。
- **`pmset sleepnow` 能绕过 idle assertion(它是显式 sleep request),通常无需 sudo。**
  但**不要假设它能绕过 `PreventSystemSleep`** —— 那种声明下成功与否取决于当下 powerd 决策。
  本机目前没有 `PreventSystemSleep`,所以日常够用,但代码不该写死。
- `IOPMSleepSystem` 是 API 级显式睡眠请求,少一层 shell 依赖,更适合 App;但和 `pmset sleepnow`
  一样都走 power management 路径,**都不是「内核强制断电级别」的万能锤**。
- `sudo pmset -a disablesleep 1` 是**反向**的(禁止睡眠),不是我们要的。

> ✅ **v1 简化成立:不用杀进程、不用 root helper。** 但必须加 clamshell 守卫(见第 6 节),
> 否则接外接显示器合盖时会被误睡。遇到真正的 `PreventSystemSleep` 流氓再考虑「杀进程」兜底。

---

## 4. 选定方案:C — 菜单栏 App + 实时看门口

```
┌─────────────────────────────────────────────────────────┐
│ 菜单栏图标                                                │
│   · 绿色 = 没人拦睡,合盖会乖乖睡                          │
│   · 红色 = 有人正持有 PreventSystemSleep                  │
│ 点开下拉:                                                 │
│   现在谁在拦睡:                                           │
│     • zoom.us        PreventSystemSleep                   │
│     • some-daemon    PreventUserIdleSystemSleep           │
│   [✓] 合盖时强制睡眠   (主开关)                            │
│   本周拦睡榜:zoom 12 次 · backupd 3 次                    │
│   退出                                                     │
└─────────────────────────────────────────────────────────┘
```

把你手动 `pmset -g assertions` 的仪式,变成菜单栏上随时一瞥就懂的东西,顺手把合盖强制睡办了。

### 技术架构

| 模块 | 做法 |
|------|------|
| App 类型 | Swift,菜单栏应用。`LSUIElement=true`(无 Dock 图标)。可用 SwiftUI `MenuBarExtra`(macOS 13+,最现代) |
| 合盖检测 | 对 `IOPMrootDomain` 注册 interest(`IOServiceAddInterestNotification` / `kIOGeneralInterest`),处理 **`kIOPMMessageClamshellStateChange`** 消息;回调里读 `AppleClamshellState`(盖子是否关)+ `AppleClamshellCausesSleep`(这次该不该睡)。`IORegisterForSystemPower` 是睡/醒通知,不是可靠的合盖事件源,别拿它当唯一来源 |
| 强制睡眠 | 合盖且 `AppleClamshellState==true && AppleClamshellCausesSleep==true` → `pmset sleepnow`(无需 sudo,绕得过 idle 声明)。跑通后可换 `IOPMSleepSystem`。**不要假设能绕过 `PreventSystemSleep`** |
| 揪出拦睡者 | `IOPMCopyAssertionsByProcess()` → 每条 assertion 字典(真机 dump 确认字段):`AssertType`(过滤 Prevent*)、`AssertPID`(持有者)、`Process Name`、`AssertLevel`(0=已释放跳过)、**`AssertionOnBehalfOfPID`(代持时的真凶 PID)**。穿透代持:真凶 PID = `OnBehalfOfPID ?? AssertPID` |
| 显示真实 App + 图标 | 用真凶 PID 查 `NSRunningApplication(processIdentifier:)` → `localizedName` + `icon`(GUI App 可得,实测 Finder→「访达」+32x32 图标)。CLI/daemon(afplay/caffeinate)查不到则退回 `proc_pidpath` 进程名、无图标。**比早先判断乐观:`AssertionOnBehalfOfPID` 是真机验证过的可用字段,不是只能解析 pmset 文本** |
| 持久化 | 主开关 + 拦睡榜计数存 `UserDefaults`,够了 |

---

## 5. 备选方案(留档)

**A — 纯菜单栏铁腕版**:菜单栏 App,只有一个开关 + 合盖强制睡,不做「看门口」面板。
比 C 简单,但丢掉了把你现有 pmset 工作流可视化的最大价值。

**B — 极简后台服务**:无 UI,一个 launchd agent + 小 CLI,静静监听合盖并摁睡。
最快跑起来、最贴近你现在的终端习惯。**适合先拿来当第 8 节作业里的技术验证脚手架。**

---

## 6. 边界情况(别忘了处理)

- **⚠️ 接外接显示器 / 蛤壳模式(clamshell)—— 头号致命风险**:合盖接显示器时系统本就该保持唤醒,
  无脑摁睡会毁掉用户的外接屏工作流。**必须**在睡之前判断 `AppleClamshellCausesSleep == true`
  (或至少判断「无外接显示器 / 在用电池」)。这是 v1 不能省的守卫。
- **正在睡 / 已经睡**:别重复触发睡眠。
- **杀进程失败 / 没权限**:降级处理,菜单栏给出提示而不是静默失败。
- **声明在合盖瞬间才出现**:检测要在合盖事件触发后再查一次最新 assertion 列表。
- **App 自己被系统休眠**:确保唤醒后重新注册回调。

---

## 7. 分发(自用足够,先别过度工程)

- **v1 自用**:Xcode 直接 build → 加入「登录项」开机自启。无需公证。
- **若以后想分享**:notarize + DMG,或做成 Homebrew Cask。这是后话,先别管。

---

## 8. 作业(下一步具体动作)

**技术假设已验证(2026-06-13):** 真凶是 `PreventUserIdleSystemSleep`(ToDesk + 音频),
关掉后正常睡。推论:`pmset sleepnow` 能摁睡且无需 sudo。**架构确定,可以直接动手。**

**剩下唯一要验证的一点(5 分钟):** 不关 ToDesk,直接在终端跑 `pmset sleepnow`,
确认它真的立刻睡(验证「显式命令绕过 idle 声明」)。通过后,v1 的核心就是把这一行接到合盖事件上。

**v1 最小可用清单(已按 Codex 审核收紧):**
1. 菜单栏空壳(`MenuBarExtra` / `NSStatusItem`,`LSUIElement=true`)。
2. 对 `IOPMrootDomain` 注册 interest,监听 `kIOPMMessageClamshellStateChange`。
3. 合盖回调里**先判断守卫**:`AppleClamshellState==true && AppleClamshellCausesSleep==true`
   才执行 `pmset sleepnow`(先 `Process` 调命令,跑通再换 `IOPMSleepSystem`)。
   —— 这一步守卫是不被外接显示器场景误杀的关键。
4. 加入登录项,自用跑几天。
5. (后置)再补「看门口」面板:`IOPMCopyAssertionsByProcess()` 列出 owning process;
   「真实 App 归因」做 best-effort,不作为核心依赖。

---

## 8.5 v1 加固(Codex challenge 后)

对真实 Swift 代码做了一轮对抗审查,已修:

- **[P1] 唤醒即重睡循环**:延迟任务跨睡眠保留 → 睡前排的 block 在唤醒后执行又把机器睡回去。
  修法:`generation` 计数器作废过期任务 + 每次合盖只睡一次(`firedThisClose`,开盖才复位)+
  监听 `NSWorkspace.didWakeNotification`,唤醒时仍合盖视为外因唤醒、不自动睡回。
- **[P1] 合盖→开→合 竞态 / 漏掉开盖通知导致 lastClosed 错乱**:同上的 generation + 复位逻辑解决。
- **[P1] 外接屏守卫在合盖瞬间拿到过渡态误睡 clamshell 桌面**:守卫加**电源判断**——
  clamshell 桌面必然「外接屏 + 接电源」;电池供电下合盖本就该睡。`shouldForceSleep` 现为:
  `causesSleep==false` 不睡 / `外接屏 && 接电源` 不睡 / 否则睡。再配 1.5s 防抖让状态稳定。
- **[P2] forceSleep 不看结果**:改为 `waitUntilExit` + 检查退出码。
- **[P2] blocker 解析脆弱**:顶层改 `[AnyHashable: Any]` 容错,level 用 `NSNumber` 桥接。
- **[P2] 菜单打开重复调 IOKit**:每次打开只调一次,图标复用结果。
- **[P3] start() 幂等、缺属性记日志**。

**已知残留(v1 自用可接受,后续再说):**
- powerd 极端卡顿时,菜单打开的 IOKit 调用仍在主线程(未挪后台),可能短暂卡 UI。
- 守卫忽略 Time Machine/备份类 assertion(设计如此:铁腕睡,APFS 层能安全处理睡眠)。
- 未处理 IOPMrootDomain service terminate / 通知端口失效后的重注册(罕见)。
- 「立即睡眠」菜单项故意绕过所有守卫(手动按钮)。

## 9. 我观察到的(builder 信号)

- 你会跑 `pmset -g assertions` 精确归因——对系统底层有感觉,IOKit 路线对你不是负担。
- 痛点是你**自己每天**遇到的真问题,反馈闭环最短,这是最好的副项目。
- 一句话就锁定了「几乎从不需要例外」,决断干脆,设计因此能砍到最简。

**状态:DONE —— 设计已确认(C 方案)。**
