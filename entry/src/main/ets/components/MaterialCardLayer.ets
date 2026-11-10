import { applyMaterialCarrier } from '../common/SystemMaterial';

/**
 * 沉浸材质承载层：一块**不可交互的画布**，只负责让系统把材质画出来。
 *
 * ## 为什么需要它
 *
 * 普通 `Column` / `Row` 在内容区挂 `systemMaterial` 是**静默不渲染**的 —— 官方生效范围限制：
 * 只有「按钮与选择类」组件（`Button` / `Select` / `Toggle` / `Slider` / `ChipGroup` /
 * `SegmentButton`）能在页面内全部区域生效，其余组件只在标题栏与底部 TabBar 生效。
 * 详见 `common/SystemMaterial.ets` 的文件头。
 *
 * 所以卡片的做法是：`ToggleType.Button` 铺满整块当材质画布，真实内容作为兄弟节点叠在它之上。
 * （不用 `Button` 承载：真机实测普通 `Button` 挂材质不渲染，同尺寸的 `ToggleType.Button` 正常。）
 *
 * ## 五条属性缺一不可
 *
 * | # | 属性 | 少了会怎样 |
 * | --- | --- | --- |
 * | 1 | `LayoutPolicy.matchParent` | 尺寸塌成 0，材质画不出来；也不能写百分比 —— Stack 子节点的百分比按父级**可用**尺寸解析，会把卡片一起顶大 |
 * | 2 | `borderRadius` | Toggle 会画自己的按钮图形（自带小圆角 + 描边），卡片里出现内嵌边框 |
 * | 3 | `backgroundColor(Color.Transparent)` | 底色垫在材质之下，叠出灰感甚至完全遮住材质 |
 * | 4 | `enabled(false)` / `focusable(false)` / `accessibilityLevel('no')` | 承载层抢走焦点与点击，上面的内容点不动 |
 * | 5 | `attributeModifier` 放末尾 | 材质被后面的样式属性覆盖 |
 */
@Component
export struct MaterialCardLayer {
  /** 圆角半径，与外壳保持一致（否则会出现内嵌的小圆角边框）。 */
  @Prop layerRadius: number = 20;
  /**
   * 下两角是否也切圆角。
   *
   * 半模态面板贴着屏幕下沿，下两角要**切平**。两种做法里选了这个：
   * 让承载层自己画成「上圆下方」，而不是画成四角圆、再靠外层 `clip(true)` 把下两角裁掉 ——
   * 那个 clip 会把材质自带的**边缘高光在圆角处一刀切断**，拐角上出现一条断掉的亮边
   * （真机反馈的「圆角处边缘光效有问题」）。不裁就没有这个断口。
   */
  @Prop layerSquareBottom: boolean = false;
  /**
   * 是否让材质自带投影。
   *
   * 材质的 `applyShadow` 默认为 true。大卡片上这层投影是加分项；
   * 小尺寸芯片（筛选、排序这类）会显得像「按钮背后顶了一层影子」，那种场合传 false。
   */
  @Prop layerShadow: boolean = true;

  build() {
    Toggle({ type: ToggleType.Button, isOn: false })
      .width(LayoutPolicy.matchParent)
      .height(LayoutPolicy.matchParent)
      .borderRadius({
        topLeft: this.layerRadius,
        topRight: this.layerRadius,
        bottomLeft: this.layerSquareBottom ? 0 : this.layerRadius,
        bottomRight: this.layerSquareBottom ? 0 : this.layerRadius
      })
      // 必须显式透明：不透明背景色会盖在材质层之上
      .backgroundColor(Color.Transparent)
      .enabled(false)
      .focusable(false)
      .accessibilityLevel('no')
      .hitTestBehavior(HitTestMode.None)
      // systemMaterial 必须放在所有样式属性之后 —— 用 attributeModifier 挂在属性链最末
      .attributeModifier({
        applyNormalAttribute: (instance: ToggleAttribute): void => {
          applyMaterialCarrier(instance, false, this.layerShadow);
        }
      })
  }
}
