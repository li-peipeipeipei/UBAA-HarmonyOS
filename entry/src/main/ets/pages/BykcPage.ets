import { BykcHomePage } from './BykcHomePage';

/**
 * 博雅课程 · 入口页。
 *
 * 对齐原版 `BykcHomeScreen.kt`：一个首页 + 四个子页
 * （选择课程 / 我的课程 / 课程统计 / 课程详情）。
 *
 * ## 为什么子页走 `RouteBuilder` 而不是本页内切换
 *
 * 本页是**页签栈里的二级页**（由 `RouteBuilder` 用 `HdsNavDestination` 承载），
 * `HdsNavDestination` 会铺满整个屏幕并自带标题栏。
 * 若在本页内部再用 `@State` 切子页并自绘标题栏，就会出现
 * **两条标题栏叠在一起**（HDS 的「博雅课程」+ 自绘的「选择课程」）——
 * 用户实机截图实锤。
 *
 * 正确做法：子页各自注册成路由（`RouteName.BYKC_COURSES` 等），
 * 由 `RouteBuilder` 用 `HdsNavDestination` 渲染 —— 标题栏、返回按钮、沉浸光感
 * 全部由 HDS 统一提供，**只有一条标题栏**。
 *
 * `stack` 由父组件（`FeaturePage` → `MainPage`）传入，与其它二级页同一套写法。
 */
@Component
export struct BykcPage {
  stack: NavPathStack = new NavPathStack();

  build() {
    BykcHomePage({ stack: this.stack })
  }
}
