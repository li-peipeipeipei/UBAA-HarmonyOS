# 架构总览

## 一句话

页面 → 本地服务 → 上游客户端 → 校内系统。没有中间层服务端，ArkTS 侧承担全部编排。

```text
pages/*Page.ets          视图与交互（ArkUI）
   │
components/              通用组件、设计令牌、材质层
   │
network/Local*Service    业务编排：拼参数、解析 HTML/JSON、错误归一
   │
network/UpstreamClient   统一请求出口：Cookie 罐、WebVPN 改写、重定向策略
   │
network/LocalWebVpn      逻辑地址 ↔ 网关加密地址
   │
@kit.RemoteCommunicationKit (RCP)  →  sso / uc / byxt / bykc / SPOC / 图书馆 …
```

## 分层职责

| 层 | 目录 | 职责 | 不该做的事 |
| --- | --- | --- | --- |
| 视图 | `pages/` | 布局、状态、路由参数 | 不直接发请求、不解析 HTML |
| 组件 | `components/` | 可复用 UI、设计令牌、功能注册表 | 不持有业务状态 |
| 业务 | `network/Local*Service.ets` | 一个系统一个文件，接口语义化 | 不碰 UI、不写 AppStorage 之外的全局态 |
| 传输 | `network/UpstreamClient.ets` | 请求发送、Cookie、重定向、超时 | 不含任何业务字段 |
| 存储 | `network/TokenStore.ets` | Cookie 罐、偏好、缓存（Preferences） | 不判断业务有效性 |
| 基础 | `common/` | 配置、路由、日期、日志、沉浸式、断点 | 不依赖上层 |

## 关键模块

| 文件 | 作用 |
| --- | --- |
| `common/AppConfig.ets` | 上游主机、连接模式枚举、版本、超时 |
| `common/AppRouter.ets` | 路由名常量 + 加载状态机 |
| `common/ImmersiveUtil.ets` | 全屏、安全区、系统栏配色、断点广播 |
| `common/Breakpoint.ets` | 600 / 840 / 1200vp 三档断点 |
| `network/TokenStore.ets` | 按模式隔离的 Cookie 罐与加密凭据 |
| `network/ScheduleCache.ets` | 课表按周缓存，翻周不重复请求 |
| `network/NetworkDiagnostics.ets` | 连接诊断（可达 / 被拦截 / 上游异常） |
| `network/MockData.ets` | 演示模式数据源 |
| `components/AppTheme.ets` | 设计令牌：`AppColor` / `AppSize` / `AppFont` / `AppMaterial` |
| `components/FeatureRegistry.ets` | 功能入口清单与首页快捷入口排序 |

## 数据契约

`model/ApiTypes.ets` 按上游 UBAA 的 `shared/.../model/dto/*` 逐字段对齐，
字段名与可空性一致，减少「Android 能取到、鸿蒙取不到」这类差异排查。

## 约定

- **业务代码只用逻辑地址**（真实域名），WebVPN 改写由传输层统一处理。
- **一个上游系统一个 `Local*Service`**，不要在页面里混着调两个系统。
- **错误归一**：所有失败在服务层转成 `ApiError`（带用户可读文案与错误码），
  页面只处理 `ApiError`，不处理 `BusinessError` 原文。
- **缓存写清失效条件**：课表按 `termCode + week`，成绩按学期，避免跨学期串数据。
