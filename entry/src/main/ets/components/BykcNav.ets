/**
 * 博雅课程的跨页共享模型。
 *
 * ## 为什么需要它
 *
 * 课程列表页 → 课程详情页是**两次不同的路由跳转**（`AppRouter.push`），
 * `RouteBuilder` 的 `routeBuilder(name, param)` 虽然带 `param`，
 * 但 `HdsNavDestination` 的内容是通过 `DestShell` 渲染的，
 * **param 没法顺着传进子组件**（ArkUI 的路由参数只到 `NavDestination` 这一层）。
 *
 * 于是用**共享模型当桥** —— 与本工程 `ScheduleHeader.ScheduleHeaderModel`
 * 同一套做法（课表页与 MainPage 也不是父子关系，靠模型传状态）。
 *
 * 用法：
 * - 列表页点课程 → `BykcNav.shared.courseId = id; AppRouter.push(stack, RouteName.BYKC_DETAIL)`
 * - 详情页 `aboutToAppear` → 读 `BykcNav.shared.courseId`
 */
export class BykcNavModel {
  /** 要查看的课程 id（跳详情页前写入）。 */
  courseId: number = 0;
}

export class BykcNav {
  /** 全局唯一实例。 */
  static readonly shared: BykcNavModel = new BykcNavModel();
}
