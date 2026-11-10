# UBAA-HarmonyOS

> 智慧北航（UBAA）的 HarmonyOS 原生客户端，复用现有 Kotlin Multiplatform 后端，
> UI 完全基于 ArkUI / ArkTS 重写，并接入 HDS（UI Design Kit）的**悬浮底栏**与**沉浸光感**。

| 项 | 值 |
| --- | --- |
| 目标平台 | HarmonyOS 6.1.0(23) 及以上 |
| 语言 / 框架 | ArkTS + ArkUI（Stage 模型） |
| 构建 | DevEco Studio + Hvigor |
| 默认后端 | `https://ubaa.mofrp.top`（API 前缀 `/api/v1`） |
| 版本 | 0.1.0 |

---

## 1. 与 UBAA 的关系

| 维度 | 说明 |
| --- | --- |
| 后端 | **完全复用**，不改动一行服务端代码。Android / iOS / 鸿蒙三端共用同一套 `/api/v1` 契约 |
| 业务模型 | 按 `shared/src/commonMain/kotlin/cn/edu/ubaa/model/dto/*` 逐字段对齐（见 `ets/model/ApiTypes.ets`） |
| 品牌资产 | 应用图标沿用 UBAA 的 `app_icon.png`（品牌蓝 `#1976D2`），页签/功能图标沿用 Material 图标风格 |
| UI 实现 | 不复用 Compose 代码，按鸿蒙设计规范重写 |

---

## 2. 鸿蒙设计规范适配

### 2.1 悬浮底栏（主页适配）

`MainPage.ets` 使用官方 `HdsTabs`，严格满足指南的三条前置约束：

```ts
HdsTabs({ controller: this.controller }) { /* 4 个 TabContent */ }
  .barOverlap(true)              // ① TabBar 叠加在 TabContent 之上
  .barPosition(BarPosition.End)  // ② 页签位于容器底部
  .vertical(false)               // ③ 横向排布
  .barFloatingStyle({
    barBottomMargin: this.bottomSafeHeight + 12,   // 跟随手势导航条高度
    gradientMask: { maskColor: '#66F1F3F5', maskHeight: 92 },
    systemMaterialEffect: { materialType: ADAPTIVE, materialLevel: ADAPTIVE }
  })
```

- 底栏距底距离 = 导航条避让高度 + 12vp，避免与系统手势条重叠
- 内容区统一预留 `AppSize.contentBottomInset`（96vp）底部留白

### 2.2 沉浸光感（所有页面）

| 位置 | 载体 | 参数 |
| --- | --- | --- |
| 标题栏 | `HdsNavigation.titleBar.style` | `scrollEffectType: GRADIENT_BLUR` + `systemMaterialEffect: ADAPTIVE` |
| 底部页签 | `HdsTabs.barFloatingStyle` | `systemMaterialEffect: ADAPTIVE` |

`ADAPTIVE` 为系统自适应档位：旗舰机启用完整材质，低端机自动降级，无需开发者分档判断。
两项能力均自 **6.1.0(23)** 起提供，故 `compatibleSdkVersion` 固定为 `6.1.0(23)`。

### 2.3 沉浸式全屏

`ImmersiveUtil.apply()` 在 `EntryAbility.onWindowStageCreate` 中：

1. `setWindowLayoutFullScreen(true)` —— 内容延伸到状态栏 / 导航条之下
2. 读取 `TYPE_SYSTEM` 与 `TYPE_NAVIGATION_INDICATOR` 避让区，写入 `AppStorage`
3. 监听 `avoidAreaChange`，旋转 / 折叠屏展开时自动刷新
4. 状态栏内容色跟随深浅色模式，避免「白底白字」

页面通过 `@StorageProp(KEY_TOP_SAFE_HEIGHT)` 读取安全区高度做顶部避让。

### 2.4 其他

- **深色模式**：所有颜色走 `$r('app.color.*')`，`resources/dark/element/color.json` 提供深色色板
- **路由**：`Navigation` + `NavPathStack`，四个页签各持一个栈，二级页在当前页签内跳转（底栏保持可见）
- **图标**：优先使用 `app.media.ic_*`（沿用 UBAA 的 Material 图标），辅助性图标使用 HarmonyOS 系统符号

---

## 3. 目录结构

```
UBAA-HarmonyOS/
├── AppScope/                      应用级配置与图标
└── entry/src/main/
    ├── ets/
    │   ├── common/                基础设施
    │   │   ├── AppConfig.ets      网关地址、连接模式、版本
    │   │   ├── AppRouter.ets      路由名 + 加载状态机
    │   │   ├── DateUtil.ets       日期 / 倒计时
    │   │   ├── ImmersiveUtil.ets  全屏 + 安全区 + 系统栏配色
    │   │   ├── GlobalContext.ets  UIAbilityContext 持有
    │   │   └── Logger.ets         分级日志
    │   ├── model/ApiTypes.ets     服务端数据契约（1:1 对齐 Kotlin DTO）
    │   ├── network/
    │   │   ├── HttpEngine.ets     HTTP + Bearer + 401 自动刷新重试
    │   │   ├── TokenStore.ets     Preferences 持久化（Token / 偏好）
    │   │   ├── ApiService.ets     业务 API 门面
    │   │   ├── Local*.ets         各模块本地直连实现（教务 / 博雅 / SPOC / 希冀 / iHome / 评教 …）
    │   │   └── ApiError.ets       错误契约 → 用户可读文案
    │   ├── components/
    │   │   ├── AppTheme.ets       设计令牌（间距 / 圆角 / 字号 / 色板）
    │   │   ├── CommonViews.ets    Loading / Error / Empty / 卡片 / 磁贴
    │   │   └── FeatureRegistry.ets 校园功能入口清单
    │   ├── entryability/
    │   └── pages/
    │       ├── Index.ets          启动分发（登录态判定）
    │       ├── LoginPage.ets      统一身份认证 + 验证码挑战
    │       ├── MainPage.ets       HdsTabs 悬浮底栏容器
    │       ├── HomePage.ets       主页（考试倒计时 / 今日课程 / 快捷入口）
    │       ├── SchedulePage.ets   周课表网格
    │       ├── FeaturePage.ets    功能聚合（普通 / 高级）
    │       ├── MinePage.ets       我的
    │       ├── ExamPage.ets       考试安排
    │       ├── GradePage.ets      成绩查询
    │       ├── ClassroomPage.ets  空闲教室
    │       ├── JudgePage.ets      希冀作业列表
    │       ├── JudgeDetailPage.ets 希冀作业详情
    │       ├── IhomePage.ets      iHome（五视图）
    │       ├── IhomeDetailPage.ets iHome 诉求详情
    │       ├── EvaluationPage.ets 自动评教（一键评教）
    │       ├── SettingsPage.ets   服务地址 / 连接模式
    │       ├── UserInfoPage.ets   个人资料
    │       ├── AboutPage.ets      关于
    │       └── RouteBuilder.ets   全局路由表
    └── resources/                 base / dark / en_US 三套资源
```

---

## 4. 后端接口对照

| 方法 | 路径 | 客户端入口 |
| --- | --- | --- |
| POST | `/api/v1/auth/preload` | 登录预探测 / 会话恢复 |
| POST | `/api/v1/auth/login` | `ApiService.login()` |
| POST | `/api/v1/auth/refresh` | `HttpEngine` 401 自动刷新 |
| POST | `/api/v1/auth/logout` | `ApiService.logout()` |
| GET | `/api/v1/auth/status` | `Index` 首帧会话恢复 |
| GET | `/api/v1/auth/captcha/{id}` | 验证码图片 |
| GET | `/api/v1/user/info` | `UserInfoPage` |
| GET | `/api/v1/schedule/terms` | 学期列表 |
| GET | `/api/v1/schedule/weeks?termCode=` | 教学周列表 |
| GET | `/api/v1/schedule/week?termCode=&week=` | 周课表 |
| GET | `/api/v1/schedule/today` | 主页今日课程 |
| GET | `/api/v1/exam/list?termCode=` | `ExamPage` |
| GET | `/api/v1/grade/list?termCode=` | `GradePage` |
| GET | `/api/v1/classroom/query?xqid=&date=` | `ClassroomPage` |
| GET | `/api/v1/app/version?clientVersion=` | 设置页检查更新 |

> 登录是 `POST /api/v1/auth/login`。若出现 `405 Method Not Allowed`，先确认路径带了 `/api/v1` 前缀、
> 且没有被 CAS / WebVPN 的 302 重定向改成 GET。

### 4.1 连接模式

仅保留两种，登录页与「我的 → 连接设置」共用 `allConnectionModes()`：

| 模式 | 枚举 | 默认地址 | 适用场景 |
| --- | --- | --- | --- |
| 内网直连 | `ConnectionMode.DIRECT` | `https://ubaa.mofrp.top:2021` | 连着校园网 / 校园 VPN |
| WebVPN | `ConnectionMode.WEBVPN` | `https://e1.buaa.edu.cn` | 校外，经学校 WebVPN 网关（需统一认证） |

要点：

- **端口必须是 2021**。UBAA 仓库 `.env.sample` 写着 `API_ENDPOINT=https://ubaa.mofrp.top:2021`
  （frp 隧道对外 2021，服务端自身监听 5432，`build.gradle.kts` 里的无端口默认值只是编译兜底）。
  写 443 不会立刻报错，而是 SYN 无响应 → 一直转圈 → 超时。
- **每个模式各存一份服务地址**，键为 `api_base_url_<MODE>`，切换模式不会互相覆盖。
  读优先级：模式自定义值 →（仅 DIRECT）旧版全局键 `api_base_url` → 模式出厂默认值。
- WebVPN 默认值只是门户根域占位。北航 WebVPN 实际用「`<内网主机名>-<端口>.e1.buaa.edu.cn`」
  代理内网主机，**需要在设置页填成完整资源地址**才能用。只填网关根域时 `/api/v1/*` 必然 404，
  设置页会识别这种情况并给出提示（`AppConfig.isWebVpnPlaceholder`）。
- 切换模式后需重新登录（会话绑定在客户端标识与网关上）。

### 4.2 连不上时的排查顺序

「我的 → 连接设置 → 连接诊断」会依次探测 `/health/ready` 与 `/`，并把结论分成四类：
服务器可达 / 被登录页拦截 / 地址可达但接口异常 / 服务器不可达。

2026-09-20 在 Mate 70 Pro（校园网）上实测的结论，排查时可直接对照：

| 现象 | 实测结果 | 结论 |
| --- | --- | --- |
| `ping ubaa.mofrp.top` 100% 丢包 | 域名同时有 A `114.249.117.208` 与 AAAA `2408:8207:7878:2922::88d`，校园网内 **IPv6 不通、IPv4 通** | 域名解析走 IPv6 时会一直超时；换网络或改用可解析到 IPv4 的地址 |
| `openssl s_client -connect 114.249.117.208:2021` | TLS 1.3 握手成功，nginx 响应 | 端口 2021 正确，链路本身没问题 |
| `GET /health/ready`、`GET /api/v1/announcement` | **502 / 504**（nginx 网关） | frp 隧道在，但**上游 UBAA 服务没起来**——客户端改不出花来，得服务端先活 |
| `openssl s_client -connect e1.buaa.edu.cn:443` | 握手成功，网关返回 400 HTML | WebVPN 网关可达，但必须填完整资源域名 |

手机 shell 里可用的探测命令（DevEco 自带 hdc）：

```
hdc shell "timeout 12 openssl s_client -connect <主机>:<端口> -brief"
hdc shell "printf 'GET /health/ready HTTP/1.1\r\nHost: <域名>\r\nConnection: close\r\n\r\n' | timeout 12 openssl s_client -connect <IP>:<端口> -servername <域名> -quiet"
```

本地开发时想绕开公网隧道，可直接把地址填成自己跑的服务端（`http://<校园网内网 IP>:5432`）；
`http` 明文若被系统拦，需要在 `module.json5` 里配置网络安全策略允许明文。

### 4.1 故障分类：先分清「服务端挂了」还是「被登录页拦了」

接口返回 HTML 时，**必须按 HTTP 状态码区分**，否则会把两类方向完全相反的故障混为一谈：

| 状态码 | 真实性质 | 客户端该做什么 |
| --- | --- | --- |
| **5xx + HTML** | nginx 等反向代理自产的错误页 → **上游 UBAA 服务没起来** | 什么都做不了，等后端恢复 |
| 404 + HTML | 地址或路径不对，打到别的站点去了 | 改地址 |
| 2xx + HTML | 接口位置对，但内容被 WebVPN / CAS 登录门户替换 | 先在浏览器完成统一身份认证 |
| 3xx 循环 | CAS / WebVPN 反复跳转 | 检查 WebVPN 地址是否为完整资源域名 |

> 教训：早期版本只判断「响应体是不是 HTML」就一律报「被 CAS 拦截」，
> 结果 `502 Bad Gateway` 的 nginx 错误页也被报成登录拦截，排查方向被彻底带偏。
> 现在由 `ApiError.fromHtmlResponse()` 按状态码分流，并顺带提取错误页 `<title>` 作为线索。

同理，`HttpEngine.rawRequest()` 的 `catch` 必须**放行已经是 `ApiError` 的异常**，
否则主动抛出的业务异常会被二次包装成网络错误，错误码变成 `错误码 portal_page` 这种噪音。

### 4.2 演示模式（服务端不可用时的 UI 验收通道）

后端挂掉时不必干等——「我的 → 连接设置 → 演示模式」打开开关后，
`ApiService` 的每个方法都会短路到 `network/MockData.ets`，返回一套本地示例数据：

- 覆盖：登录 / 会话 / 个人信息 / 学期 / 教学周 / 周课表 / 今日课程 / 考试 / 成绩 / 空闲教室 / 版本
- 任意学号 + 密码即可登录；有 420ms 假延迟，加载态可见
- 所有日期相对「今天」动态推导，倒计时不会失效
- **不发起任何网络请求**，真实联调前请关闭

登录页在服务端故障（`upstream_down`）时会直接给出「开启演示模式」按钮，不用自己翻设置。

### 4.3 WebVPN 地址助手

北航 WebVPN 以**域名**方式代理内网资源，格式不直观：

```
内网 10.30.1.5:5432  →  https://10.30.1.5-5432.e1.buaa.edu.cn
内网 ubaserver:80    →  https://ubaserver.e1.buaa.edu.cn
```

设置页在 WebVPN 模式下提供「地址助手」：填内网主机 + 端口，实时预览拼出的地址，一键填入并保存。
只填网关根域 `e1.buaa.edu.cn` 会命中 `AppConfig.isWebVpnPlaceholder()` 提示，
因为该地址下 `/api/v1/*` 必然 404。

---

## 5. 编译与运行

仓库不含 `build-profile.json5`（内含本机调试签名凭据，已在 `.gitignore` 排除）。
首次构建请复制 `build-profile.example.json5` 为 `build-profile.json5`，再按 §5.3 配置自动签名。

1. DevEco Studio 打开 `UBAA-HarmonyOS` 目录
2. 等待 Hvigor 同步完成
3. 连接 **HarmonyOS 6.1.0(23) 及以上** 的设备或模拟器
4. Run `entry`

真机需要签名：`File > Project Structure > Signing Configs` 勾选自动签名。

### 5.1 构建环境说明（已验证）

| 项 | 值 |
| --- | --- |
| DevEco Studio | 26.0.0（自带 HarmonyOS SDK 26.0.0(26)） |
| `compileSdkVersion` | **不配置**（跟随 DevEco 自带 SDK） |
| `compatibleSdkVersion` | `6.1.0(23)` |
| 构建结果 | `entry-default-unsigned.hap`，BUILD SUCCESSFUL |

**不要显式写 `compileSdkVersion`。** 写死成低版本会触发
`hvigor ERROR 00303313 Configuration Error: compileSdkVersion is incompatible with the current DevEco Studio version`。

### 5.2 适配 API 26 SDK 的几处关键点

在 SDK 26 上实测编译后，以下写法是必须的（已修正）：

| 问题 | 原因 | 修法 |
| --- | --- | --- |
| `import { NavPathStack } from '@kit.ArkUI'` | `NavPathStack` 是**全局声明类**，不在 `@kit.ArkUI` 导出表内 | 去掉 import，直接使用 |
| `onConfigurationUpdate(newConfig: ConfigurationConstant.Configuration)` | `ConfigurationConstant` 只导出 `ColorMode/Direction/ScreenDensity` | 从 `@kit.AbilityKit` 导入 `Configuration` |
| `this.context.config.colorMode` 传给 `ColorMode` 参数 | 该字段类型是 `ColorMode \| undefined` | 显式判空，回退 `COLOR_MODE_LIGHT` |
| `@Builder toolbar()` | `toolbar` 与 `CommonAttribute` 内置属性同名，类型冲突 | 重命名为 `termBar()` |
| `sys.symbol.info` | 系统资源表中无 `info` 这一项 | 改用 `sys.symbol.info_circle` |
| `promptAction.showToast` | 已废弃 | 统一走 `common/Toast.ets`（内部用 `openToast`） |
| `px2vp()` 全局函数 | 已废弃 | 改为 `window.getUIContext().px2vp()` |

**查询系统符号的权威方式**：符号清单在 SDK 的
`sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js` 的 `sys.symbol` 段（共 4000+ 项）。
引用了不存在的符号会报 `10903329 Unknown resource name 'xxx'`。

### 5.3 真机调试（有线 / 无线）

**可以，有线直连是最稳的方式。** 已在本机验证通过。

hdc 工具路径（DevEco 自带，无需额外安装）：

```
C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe
```

**已验证的调试设备**

| 项 | 值 |
| --- | --- |
| 型号 | HUAWEI Mate 70 Pro（`PLR-AL50`） |
| 系统 | `7.0.0.105(SP10C00E105R7P3)` / OpenHarmony-7.0.0.105 |
| **API 版本** | **26**（项目要求 ≥ 23，满足） |
| SN | `5BH0225225059892` |
| UDID | `3555239F9BFEDD3646E8A1BC2D9EB88247A4BCAF6819EEF5DD91255D593CD85D` |

**有线连接步骤**

1. 手机「设置 → 关于本机」连续点击**版本号** 7 次，开启开发者模式
2. 「设置 → 系统和更新 → 开发人员选项」打开 **USB 调试**
3. USB 线连接电脑，手机上把 USB 用途选成 **传输文件**
4. 手机弹出「是否允许 USB 调试」→ 点**允许**（可勾选"始终允许"）
5. 验证连接：

```
hdc list targets          # 应输出设备 SN，而不是 [Empty]
hdc shell bm get --udid   # 能返回 UDID 说明 shell 通道已通
```

6. DevEco Studio 里直接 Run `entry`

**无线调试（可选，免插线）**

手机与电脑连同一 WiFi → 开发人员选项里打开**无线调试**，记下页面显示的 `IP:端口`：

```
hdc tconn 192.168.x.x:5555
hdc list targets
```

**必须先配签名**，否则 DevEco 会停在 `Will skip sign 'hos_hap'` 且真机安装失败：
`File > Project Structure > Signing Configs` → 登录华为账号 → 勾选 **Automatically generate signature**。
签名材料会生成到 `C:\Users\<用户名>\.ohos\config\`（本机目前尚无此目录，说明还没签过）。

签名后也可脱离 DevEco 手动安装：

```
hdc install entry\build\default\outputs\default\entry-default-signed.hap
```

---

## 6. 已知限制与后续路线

**当前状态**

- 已打通（与本仓库上游 UBAA 的功能对齐）：登录 / 会话恢复、课表、考试、成绩、空闲教室、
  个人信息、设置、课堂签到、博雅课程、SPOC、图书馆座位、阳光打卡、iHome、自动评教
- 暂缓：**希冀作业**。2026-10-26 真机实测 judge 已改版为 SPA——`courselist.jsp?courseID=0`
  会被 302 回 `main.jsp`，旧版 HTML 解析拿不到课程列表（上游 Kotlin 实现同样基于旧页面）。
  代码与路由保留在仓库里，但**不挂功能入口**，避免点进去显示成「没有作业」；等摸清新版接口再接回。
- 尚未接入：**研讨室预约（cgyy）**。它需要识别滑块验证码（图片解码 + 模板匹配 + AES-ECB 加密）
  并完成「场地 → 日期时段 → 预约表单 → 订单 / 取消 / 门锁码」全链路写入；为避免挂一个
  点进去就报错的空入口，本轮**没有**在功能页放占位名称，待验证码方案落地后再连同入口一起加

新增模块的本地实现都放在 `network/Local*.ets`，与上游 `shared/.../local/*.kt` 一一对应：

| 模块 | 本地服务 | 说明 |
| --- | --- | --- |
| 希冀作业 | `LocalJudgeService.ets` | 抓 HTML 表格 + 选课会话串行请求（**入口暂缓**，见上） |
| iHome | `LocalIhomeService.ets` | CAS 跳转链换 Bearer token；关注 / 支持按目标状态提交并回查 |
| 自动评教 | `LocalEvaluationService.ets` | `/pjxt/cas` 握手 → 任务 / 问卷 / 课程 → 逐门提交默认问卷 |

**外部阻塞（非客户端问题）**

`ubaa.mofrp.top:2021` 的 TLS 与 nginx 均正常，但 `GET /health/ready` 返回 **502**、
`GET /api/v1/announcement` 返回 **504**，即 frp 隧道后的 UBAA 服务本身没有运行。
在此之前无法做真实登录联调，可先用 §4.2 的演示模式推进 UI 工作。

**后续路线**

- [ ] 课表支持「课程详情」弹窗与按周次显示过滤
- [ ] 首页接入公告（`/api/v1/announcement`）
- [ ] Token 迁移到 `@kit.AssetStoreKit`，提升密钥存储等级
- [ ] 课表卡片桌面卡片（Form）与通知提醒
- [x] 平板 / 折叠屏分栏布局（`NavigationMode.Split`）—— 宽屏侧边导航 + 列表栏 + 详情栏，断点 600 / 840 / 1200vp

**本项目使用的系统符号**（均已对照 `sysResource.js` 校验存在）

```
sys.symbol.checkmark       sys.symbol.chevron_right   sys.symbol.chevron_down
sys.symbol.exclamationmark sys.symbol.doc             sys.symbol.arrow_clockwise
sys.symbol.person          sys.symbol.wifi            sys.symbol.info_circle
```

---

## 7. 参考

- [UI Design Kit · 页签栏悬浮样式](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-tabs-bar-floating)
- [UI Design Kit · 沉浸光感](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ui-design-hds-component-material)
- [ArkUI 开发指南](https://developer.huawei.com/consumer/cn/arkui/devstart/)
- [UBAA 原项目（Android / iOS）](https://github.com/BUAASubnet/UBAA)
