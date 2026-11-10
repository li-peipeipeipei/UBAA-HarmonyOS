/**
 * 希冀作业详情页的入参。
 *
 * 为什么用模块级静态字段而不是路由 param：本项目的 routeBuilder 只接收一个
 * `param: object`，而 ArkTS 不允许把 object 直接断言成具体接口再绑定给组件的
 * 强类型属性。详情页只需要「谁被点了」这一组字符串，用一次性静态中转最省事，
 * 也避免多引一层序列化。
 */
export class JudgeNav {
  static courseId: string = '';
  static assignmentId: string = '';
  static courseName: string = '';
  static title: string = '';

  static set(courseId: string, assignmentId: string, courseName: string, title: string): void {
    JudgeNav.courseId = courseId;
    JudgeNav.assignmentId = assignmentId;
    JudgeNav.courseName = courseName;
    JudgeNav.title = title;
  }
}
