# 功能总览

所有数据均来自校内上游系统，客户端只做请求编排与渲染。服务端（上游 UBAA 的 Ktor 网关）
**已停止部署**，本项目不依赖它。

## 已实现

| 模块 | 能力 | 数据来源 | 实现 |
| --- | --- | --- | --- |
| 登录 | 统一身份认证（CAS）+ 图形验证码，登录态加密持久化 | `sso.buaa.edu.cn` | `network/LocalAuthService.ets` |
| 会话恢复 | 启动时校验上游会话，失效则回登录页 | `uc.buaa.edu.cn` | `pages/Index.ets` |
| 课表 | 周网格、跟手翻周、同时段多课合并、教学周胶囊 | 教务系统 | `pages/SchedulePage.ets` |
| 考试安排 | 按学期查询时间 / 地点 / 座位 | 教务系统 | `pages/ExamPage.ets` |
| 成绩查询 | 按学期查询，学分与绩点汇总 | 教务系统 | `pages/GradePage.ets` |
| 空闲教室 | 按教学楼 + 日期查询占用情况 | 教务系统 | `pages/ClassroomPage.ets` |
| 博雅课程 | 课程列表 / 详情 / 已选 / 统计 / 选课退课 | 博雅系统 | `pages/Bykc*.ets` |
| SPOC | 作业列表与详情，站内网页提交 | SPOC 站 | `pages/SpocPage.ets` |
| 图书馆座位 | 楼馆 → 分区 → 座位 → 预约 / 取消 | `booking.lib.buaa.edu.cn` | `pages/LibBook*.ets` |
| 课堂签到 | 今日课堂列表与一键签到 | 签到服务 | `pages/SigninPage.ets` |
| 阳光打卡 | 学期打卡次数与历史记录 | `ygdk.buaa.edu.cn` | `pages/YgdkPage.ets` |
| iHome | 诉求列表、详情与处理进度 | iHome 平台 | `pages/IhomePage.ets` |
| 自动评教 | 一键完成待评课程 | 评教系统 | `pages/EvaluationPage.ets` |
| 个人信息 / 设置 | 学籍信息、连接模式、演示模式、缓存清理 | `uc.buaa.edu.cn` | `pages/UserInfoPage.ets`、`SettingsPage.ets` |

覆盖的教务能力（课表 / 考试 / 成绩 / 教室）统一在 `network/LocalAcademicService.ets`。

## 未接入

| 模块 | 原因 | 现状 |
| --- | --- | --- |
| 希冀作业 | 2026-10-26 真机实测上游已改版为 SPA，`courselist.jsp` 被 302 回 `main.jsp`，旧 HTML 解析拿不到课程列表 | 代码与路由保留（`LocalJudgeService.ets`、`Judge*Page.ets`），**不挂功能入口** |
| 研讨室预约 | 需识别滑块验证码（图片解码 + 模板匹配 + AES-ECB）并完成全链路写入 | 未开始 |
| 图书馆分区平面图 | 29 张楼馆平面图为硬编码位图，尚未整理 | 只做列表式选座 |

> 原则：**半成品入口比没有入口更伤体验**。没打通的能力不挂名字，避免用户点进去看到空页面。

## 演示模式

服务端不可用时，设置页可打开「演示模式」：所有 `ApiService` 方法短路到 `network/MockData.ets`，
返回本地示例数据（登录 / 会话 / 课表 / 考试 / 成绩 / 教室 / 版本），带 420ms 假延迟，
**不发起任何网络请求**，用于 UI 验收。真实使用前请关闭。
