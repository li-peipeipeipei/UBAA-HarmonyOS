import { Term } from '../model/ApiTypes';
import { AppColor, AppFont } from './AppTheme';

/**
 * 成绩页顶栏的共享状态（学期名 + 上一/下一学期）。
 *
 * ## 为什么单独抽一个模型
 *
 * 顶栏渲染在 `HdsNavDestination` 的标题栏里，而数据在 `GradePage` 里 —— 两边不是父子关系，
 * 没法直接传 props（跟课表页的 `ScheduleHeaderModel` 一个套路）：用同一个 @Observed 实例当桥。
 */
@Observed
export class GradeHeaderModel {
  /** 当前学期显示名（顶栏正中）。 */
  termName: string = '';
  /** 当前学期代码。 */
  termCode: string = '';
  /** 可选学期列表（上游顺序）。 */
  terms: Term[] = [];
  /** 当前学期在 terms 里的下标（-1 = 还没有）。 */
  termIndex: number = -1;
  /** 点「上一学期」。 */
  onPrevTerm: () => void = () => {
  };
  /** 点「下一学期」。 */
  onNextTerm: () => void = () => {
  };

  /** 还有更早的学期吗（决定左箭头是否置灰）。 */
  canPrev(): boolean {
    return this.termIndex > 0;
  }

  /** 还有更晚的学期吗（决定右箭头是否置灰）。 */
  canNext(): boolean {
    return this.termIndex >= 0 && this.termIndex < this.terms.length - 1;
  }
}

/**
 * 成绩页顶栏主区：**学期名（居中） + 上一/下一学期箭头**。
 *
 * ## 为什么不用 HDS 的 menu 槽位放箭头
 *
 * `HdsNavigationTitleBarOptions` 建好之后就是**静态对象**：`menu.value` 里的
 * `isEnabled`（箭头置灰）不会跟着学期变化刷新；`mainTitle` 也只能是静态字符串。
 * 放进 `stackBuilder` 里才能跟着 @Observed 模型实时变。
 *
 * ## ⚠️ 箭头必须**内联**，不能再抽成带参数的 @Builder
 *
 * 真机踩过：`this.arrow(symbol, this.model.canPrev(), …)` 里布尔值是**按值**传进
 * @Builder 的，@Builder 的普通参数不参与状态刷新 —— 首帧（terms 还是空、termIndex=-1）
 * 算出的 `enabled=false` 会一直留着，后来学期列表加载完，箭头看着在、却永远点不动
 * （ui dump 里两个 Button 都是 `enabled:false`）。内联后 `.enabled(this.model.canPrev())`
 * 直接绑在组件属性上，才会随模型更新。
 */
@Component
export struct GradeTermTitle {
  @ObjectLink model: GradeHeaderModel;

  build() {
    Row({ space: 4 }) {
      // 左：页面标题，字号 / 字重与「考试安排」那页的原生标题栏一致
      Text('成绩查询')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)

      Blank()

      // 右侧：学期名紧贴上一 / 下一学期箭头（同一字号）
      Text(this.model.termName.length > 0 ? this.model.termName : '—')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 160 })

      Button() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor([this.model.canPrev() ? AppColor.textPrimary : AppColor.textTertiary])
      }
      .type(ButtonType.Normal)
      .width(32)
      .height(36)
      .borderRadius(16)
      .backgroundColor(Color.Transparent)
      .enabled(this.model.canPrev())
      .stateEffect(this.model.canPrev())
      .onClick(() => {
        if (this.model.canPrev()) {
          this.model.onPrevTerm();
        }
      })

      Button() {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(20)
          .fontColor([this.model.canNext() ? AppColor.textPrimary : AppColor.textTertiary])
      }
      .type(ButtonType.Normal)
      .width(32)
      .height(36)
      .borderRadius(16)
      .backgroundColor(Color.Transparent)
      .enabled(this.model.canNext())
      .stateEffect(this.model.canNext())
      .onClick(() => {
        if (this.model.canNext()) {
          this.model.onNextTerm();
        }
      })
    }
    .width('100%')
    .height(44)
    // 让开左侧原生返回按钮（40vp 圆 + 16vp 边距）
    .padding({ left: 64, right: 8 })
    .alignItems(VerticalAlign.Center)
  }
}
