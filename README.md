# UBAA-HarmonyOS

![HarmonyOS](https://img.shields.io/badge/HarmonyOS-6.1.0%2823%29%2B-green.svg?style=flat)
![ArkTS](https://img.shields.io/badge/ArkTS-ArkUI-blue.svg?style=flat)
![HDS](https://img.shields.io/badge/UI_Design_Kit-HDS-purple.svg?style=flat)
![License](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat)

**UBAA-HarmonyOS** 是 [智慧北航（UBAA）](https://github.com/BUAASubnet/UBAA) 的 HarmonyOS 原生客户端。

它**不依赖自建服务端**：登录与取数全部由客户端直连校内上游系统（统一认证、教务、博雅、
SPOC、图书馆等），ArkTS 侧完成请求编排与页面解析。UI 按鸿蒙设计规范重写，
接入 HDS（UI Design Kit）的**悬浮底栏**与**沉浸光感**，手机与平板两套布局。

## 入口

- 上游项目：[BUAASubnet/UBAA](https://github.com/BUAASubnet/UBAA)（Kotlin Multiplatform · Android / iOS / Desktop / Web）
- 开发文档：[项目文档](docs/index.md)
- 问题反馈：[Issues](https://github.com/li-peipeipeipei/UBAA-HarmonyOS/issues)

## 已实现功能

| 模块 | 能力 |
| --- | --- |
| 登录 / 会话 | 统一身份认证（CAS 四跳）+ 图形验证码，登录态加密持久化、启动自动恢复 |
| 课表 | 周网格、跟手翻周、同时段多课合并、教学周胶囊 |
| 考试 / 成绩 | 按学期查询，学分与绩点汇总 |
| 空闲教室 | 按教学楼与日期查询占用 |
| 博雅课程 | 列表 / 详情 / 已选 / 统计，选课与退课 |
| SPOC | 作业列表与详情，站内网页提交 |
| 图书馆座位 | 楼馆 → 分区 → 座位 → 预约 / 取消 / 我的预约 |
| 课堂签到 | 今日课堂列表与一键签到 |
| 阳光打卡 | 学期打卡次数与历史记录 |
| iHome | 诉求列表、详情与处理进度 |
| 自动评教 | 一键完成待评课程 |
| 个人资料 / 设置 | 学籍信息、连接模式（校内直连 / WebVPN）、演示模式、缓存清理 |

**未接入**：希冀作业（上游已改版为 SPA，旧 HTML 解析失效，代码保留但不挂入口）、
研讨室预约（需滑块验证码方案）。理由与现状见[功能总览](docs/features/index.md)。

## UI 设计

- **悬浮底栏**：`HdsTabs` + `barOverlap` / `barPosition(End)` / `barFloatingStyle`，
  底栏距底 = 导航条高度 + 12vp，内容区预留 104vp。
- **沉浸光感**：标题栏 `GRADIENT_BLUR` + `ADAPTIVE` 系统材质，底栏同档；
  自绘卡片用 `MaterialCardLayer`（不可交互 `ToggleType.Button` 当画布）。
- **沉浸式全屏**：内容延伸到状态栏与导航条之下，只靠安全区避让，跟随旋转与折叠屏刷新。
- **一套令牌**：`AppColor` / `AppSize` / `AppFont` / `AppMaterial`，颜色走
  `resources/*/element/color.json`，原生支持深色模式。
- **平板分栏**：600 / 840 / 1200vp 断点（sm / md / lg / xxl），手机走底部页签，
  平板走侧栏 + 双栏 `NavigationMode.Split`，手机分支代码零改动。

细节与踩坑（材质不渲染、半模态高度、跟手翻周阈值、动效回环）见
[UI 设计](docs/tech/ui-design.md)。

## 开发文档

文档统一维护在仓库 `docs/` 中。

- 总览入口：[项目文档](docs/index.md)
- 功能说明：[功能总览](docs/features/index.md) / [登录与连接模式](docs/features/auth-and-connection.md)
- 技术文档：[架构总览](docs/tech/architecture.md) / [UI 设计](docs/tech/ui-design.md)
- 构建与排障：[构建与签名](docs/tech/build.md) / [排障指南](docs/tech/troubleshooting.md)

## 仓库概览

```text
UBAA-HarmonyOS/
├── AppScope/                 应用级配置与图标
├── entry/src/main/ets/
│   ├── common/               配置、路由、日期、日志、沉浸式、断点
│   ├── model/                数据契约（对齐上游 DTO）
│   ├── network/              上游直连：CAS / 教务 / 博雅 / SPOC / 图书馆 / iHome …
│   ├── components/           通用组件、设计令牌、材质层、功能注册表
│   ├── entryability/         UIAbility 入口
│   └── pages/                页面与全局路由表
├── docs/                     开发文档
└── build-profile.example.json5
```

## 构建

1. 复制 `build-profile.example.json5` 为 `build-profile.json5`（真实签名配置不入库）
2. DevEco Studio 打开仓库根目录，等 Hvigor 同步完成
3. `File > Project Structure > Signing Configs` 勾选自动签名
4. 连接 HarmonyOS 6.1.0(23) 及以上设备或模拟器，Run `entry`

`compatibleSdkVersion` 固定 `6.1.0(23)`（HDS 悬浮底栏与沉浸光感的最低版本），
**不要显式配置 `compileSdkVersion`**。更多说明见[构建与签名](docs/tech/build.md)。

## 声明

非官方客户端，与北京航空航天大学无隶属关系。数据来自校内系统，仅作学习与技术交流使用，
请遵守学校相关管理规定。代码以 [MIT](LICENSE) 协议开源，与上游 UBAA 一致。
