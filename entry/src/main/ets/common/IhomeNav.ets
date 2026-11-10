/**
 * iHome 详情页入参。
 *
 * 同 JudgeNav：routeBuilder 的 param 是 object，ArkTS 不允许把它断言成具体接口
 * 再绑定给组件的强类型属性，所以用一次性静态中转。
 */
export class IhomeNav {
  static id: number = 0;
  static mine: boolean = false;

  static set(id: number, mine: boolean): void {
    IhomeNav.id = id;
    IhomeNav.mine = mine;
  }
}
