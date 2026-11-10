import { AppColor, AppFont, AppMaterial, AppSize } from './AppTheme';
import { Week } from '../model/ApiTypes';
import { DateUtil } from '../common/DateUtil';

/**
 * 课表页顶部「学期 / 周次」选择器的共享状态。
 *
 * 为什么单独抽一个 @Observed 模型：这两个选择器渲染在 **HdsNavigation 的悬浮标题栏**里
 * （见 MainPage.scheduleTitleBar），而标题栏配置挂在 MainPage 上、数据却由 SchedulePage
 * 加载 —— 两边不是父子关系，没法直接传 props。用一个 @Observed 实例当桥：
 * MainPage 持有它、把它交给标题栏里的两个小组件（@ObjectLink 订阅），
 * SchedulePage 拿到**同一个实例**负责写数据、挂回调。
 *
 * 好处：选择器常驻标题栏（永远贴在状态栏下方），课表网格少让开一整块，
 * 而且它在标题栏的布局盒里 —— 不会被「标题栏吃触摸」的问题挡住。
 */
@Observed
export class ScheduleHeaderModel {
  /** 当前学期名（学期胶囊上的文字）。 */
  termName: string = '选择学期';
  /** 当前教学周序号。 */
  currentWeek: number = 1;
  /** 可选周次列表。 */
  weeks: Week[] = [];
  /** 点击学期胶囊 → 打开学期选择半模态（由 SchedulePage 实现）。 */
  onOpenTerm: () => void = () => {
  };
  /** 点击某个周次胶囊 → 切换该周（由 SchedulePage 实现）。 */
  onSelectWeek: (week: number) => void = () => {
  };
  /** 点击「回本周」→ 跳回当前教学周（由 SchedulePage 实现）。 */
  onBackToCurrentWeek: () => void = () => {
  };
  /**
   * 「课表页重新可见」→ 刷新当前周（由 SchedulePage 实现，MainPage 在页签切换时触发）。
   *
   * 走共享模型而不是组件属性传递，是因为 `SchedulePage` 与 `MainPage`
   * 不是父子关系的直接传参通路 —— 两边本来就靠这个模型当桥。
   */
  onRefresh: () => void = () => {
  };
  /**
   * 「当前周变了 → 把周次胶囊条滚到那一颗」的请求通道。
   *
   * ## 为什么需要它
   *
   * 课表页是**横向翻页**的（第 1 周 … 第 19 周，Swiper 跟手翻），
   * 而周次胶囊条是标题栏里一条独立的横向 Scroll —— 两边不联动的话，
   * 滑到第 13 周时胶囊条还停在第 1~6 周，**一颗都没高亮**，用户完全不知道自己在第几周。
   *
   * 由 `ScheduleWeekChips` 组件自己注册这个回调（它才有 ScrollController），
   * `SchedulePage` 在 currentWeek 变化时调用。
   */
  onScrollWeekIntoView: (week: number) => void = () => {
  };
}

/**
 * 标题栏主区：学期胶囊 + 「第 N 周」。
 *
 * 视觉沿用原 SchedulePage.termBar 的第一行，保证观感一致。
 */
@Component
export struct ScheduleTermChip {
  @ObjectLink model: ScheduleHeaderModel;

  /** 当前选中的这一周是不是「本周」（教学周列表里带 curWeek 标记的那一周）。 */
  private isCurrentWeek(): boolean {
    for (let i = 0; i < this.model.weeks.length; i++) {
      const item: Week = this.model.weeks[i];
      if (item.serialNumber === this.model.currentWeek) {
        return item.curWeek === true;
      }
    }
    return false;
  }

  build() {
    Row({ space: AppSize.gap }) {
      Row({ space: 4 }) {
        Text(this.model.termName)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([AppColor.textTertiary])
      }
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(999)
      // 普通高斯模糊 + 半透明底色（原先的系统材质每帧要自适应取色，滚动掉帧）。
      .backdropBlur(AppMaterial.blurSmall)
      .backgroundColor(AppColor.glassSurface)
      .onClick(() => {
        this.model.onOpenTerm();
      })

      Blank()

      // 右上角：本周只显示两个字；翻到别的周时给一个「回本周」快捷按钮。
      if (this.isCurrentWeek()) {
        Text('本周')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
      } else {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(12)
            .fontColor([AppColor.brand])
          Text('回本周')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.brand)
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(999)
        .backgroundColor(AppColor.brandContainer)
        .onClick(() => {
          this.model.onBackToCurrentWeek();
        })
      }
    }
    .width('100%')
  }
}

/**
 * 标题栏下沿：周次横向选择。
 *
 * 挂在 titleBar.content.bottomBuilder 上 —— 属于标题栏的布局盒，
 * 所以这些胶囊照样可点（不会落进标题栏的「触摸死区」）。
 */
@Component
export struct ScheduleWeekChips {
  @ObjectLink model: ScheduleHeaderModel;
  /** 横向滚动控制器：把「当前周」那颗胶囊滚到视野中间。 */
  private scroller: Scroller = new Scroller();
  /**
   * 每颗胶囊的宽度（**vp**）。
   *
   * ⚠️ `onAreaChange` 给的 `Area.width` 是 **vp**（ArkUI 里裸数字的 Length 就是 vp），
   * 不是 px —— 跟 `Scroll.scrollTo` 的 `xOffset`（vp）同单位，可以直接加减，
   * **千万别再乘除密度**（踩过：vp 的宽度配 px 的间距，间距算成 28 而不是 8，
   * 累积下来整条偏移量完全对不上，胶囊条只滚到第 8 周就卡住了）。
   */
  private chipW: Map<number, number> = new Map<number, number>();
  /** Scroll 的可视宽度（vp）。 */
  private viewportWidth: number = 0;
  /** 首帧时尺寸还没量出来，重试的次数上限（避免无限递归）。 */
  private retryCount: number = 0;
  /** 最近一次要滚到哪一周（换周时重置重试预算）。 */
  private pendingWeek: number = -1;

  /**
   * `Area` 的宽高 / 坐标都是 `Length`（number | string | Resource），
   * 这里取其中的数值部分（拿不到就当 0）。
   */
  private toNumber(value: Length | undefined): number {
    if (typeof value === 'number') {
      return value;
    }
    return 0;
  }

  aboutToAppear(): void {
    // 注册「当前周变了 → 胶囊条滚过去」的回调（课表页在 currentWeek 变化时调用）。
    this.model.onScrollWeekIntoView = (week: number) => {
      this.scrollWeekIntoView(week);
    };
    // 自己先对齐一次（注册之前课表页可能已经切过周了）
    this.scrollWeekIntoView(this.model.currentWeek);
  }

  aboutToDisappear(): void {
    this.model.onScrollWeekIntoView = () => {
    };
  }

  /**
   * 某颗胶囊在内容行里的横向偏移（vp，相对 Scroll 内容起点）。
   *
   * ⚠️ **不能用 `onAreaChange` 的 `position.x`** —— 那是相对**视口**的，
   * 一滚动就变，拿它算目标偏移会自己跟自己较劲（滚过去 → 位置变了 → 再滚回来）。
   *
   * 这里的偏移是「算」出来的：左侧留白 + 前面每颗胶囊的宽度 + 间距。
   * 宽度由 `onAreaChange` 实测（**宽度与滚动无关**，可以放心用）——
   * 「第10周」比「第1周」宽，字宽不一样，只能实测。
   *
   * 返回 -1 表示前面的宽度还没量出来（首帧）。
   */
  private chipOffsetVp(index: number): number {
    let x: number = AppSize.pagePadding;
    for (let i = 0; i < index; i++) {
      const serial: number = this.model.weeks[i].serialNumber;
      const w: number | undefined = this.chipW.get(serial);
      if (w === undefined) {
        return -1;
      }
      x += w + AppSize.gapSmall;
    }
    return x;
  }

  /**
   * 把指定教学周的胶囊滚到视野中间。
   *
   * ⚠️ 用**像素偏移**而不是 `scrollToIndex` —— `scrollToIndex` 只认「带 item 分组的
   * List / Scroll」（`align` 参数明确写了只支持 List / Grid / WaterFlow），
   * 而这里 Scroll 的子节点只有一个 Row（里面才是 ForEach 的胶囊），索引对不上。
   */
  private scrollWeekIntoView(week: number): void {
    // 换了一周 → 重置重试预算（否则首帧没量到尺寸会把预算耗光，后面再也滚不动）
    if (week !== this.pendingWeek) {
      this.pendingWeek = week;
      this.retryCount = 0;
    }
    let index: number = -1;
    for (let i = 0; i < this.model.weeks.length; i++) {
      if (this.model.weeks[i].serialNumber === week) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      return;
    }
    const x: number = this.chipOffsetVp(index);
    const w: number | undefined = this.chipW.get(week);
    const ready: boolean = x >= 0 && w !== undefined && this.viewportWidth > 0;
    // ⚠️ 最好等**所有**胶囊都量完宽度再滚 ——
    //    Scroll 的可滚动范围是按「当前内容宽度」算的，内容还没铺完就发滚动指令，
    //    会被钳制在当时的最大 offset 上（实测只滚到第 8 周那一段，后面就滚不动了）。
    const allMeasured: boolean = this.chipW.size >= this.model.weeks.length;
    if (!ready || (!allMeasured && this.retryCount < 12)) {
      // 首帧还没量到尺寸 → 下一帧再来（最多重试 12 次 ≈ 1 秒）
      if (this.retryCount < 12) {
        this.retryCount++;
        setTimeout(() => {
          this.scrollWeekIntoView(week);
        }, 80);
        return;
      }
      if (!ready) {
        return; // 连最基本的尺寸都没有，放弃（下次换周还会再试）
      }
      // 尺寸齐了但内容可能还没铺完 → 尽力而为地滚过去
    }
    this.retryCount = 0;
    // 单位统一用 vp：`Area` 给的是 vp，`scrollTo` 的 xOffset 也是 vp
    const chipWidth: number = w ?? 0;
    const target: number = Math.max(0, x + chipWidth / 2 - this.viewportWidth / 2);
    setTimeout(() => {
      try {
        // ⚠️ 这个 SDK 的 ScrollOptions 里 xOffset / yOffset 都是必填
        this.scroller.scrollTo({ xOffset: target, yOffset: 0, animation: true });
      } catch (e) {
        // Scroll 还没挂载就忽略
      }
    }, 0);
  }

  build() {
    Scroll(this.scroller) {
      Row({ space: AppSize.gapSmall }) {
        ForEach(this.model.weeks, (item: Week) => {
          Text(item.name.length > 0 ? item.name : item.serialNumber.toString())
            .fontSize(AppFont.caption)
            .fontColor(item.serialNumber === this.model.currentWeek ? Color.White : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            // 未选中：普通高斯模糊 + 半透明底；选中：实心品牌色，模糊置 0（省一次采样）。
            .backdropBlur(item.serialNumber === this.model.currentWeek ? 0 : AppMaterial.blurSmall)
            .backgroundColor(item.serialNumber === this.model.currentWeek ? AppColor.brand : AppColor.glassSurface)
            .onClick(() => {
              if (item.serialNumber !== this.model.currentWeek) {
                this.model.onSelectWeek(item.serialNumber);
              }
            })
            // 实测胶囊宽度（px）—— 宽度与滚动位置无关，用来算目标偏移
            .onAreaChange((oldArea: Area, newArea: Area) => {
              this.chipW.set(item.serialNumber, this.toNumber(newArea.width));
            })
        }, (item: Week) => item.serialNumber.toString())
      }
      // 左右留白写在这里：HDS 的 titleBar padding 对 bottomBuilder 里的自定义内容不生效
      // （实测学期胶囊依旧贴着屏幕左边）。这样第一个 / 最后一个周次胶囊也不会顶到屏幕边。
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .padding({ bottom: AppSize.gapSmall })
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.viewportWidth = this.toNumber(newArea.width);
    })
    .onAppear(() => {
      this.scrollWeekIntoView(this.model.currentWeek);
    })
  }
}

/**
 * 课表标题栏里的「周几 + 日期」行。
 *
 * 放在 HDS 标题栏的 bottomBuilder 里（与周次胶囊同属标题栏），这样它直接使用
 * 标题栏那层系统材质/渐变模糊 —— 模糊自然从顶部延伸到这里截止，而不是页面里
 * 另铺一条独立的模糊带。
 */
@Component
export struct ScheduleDayHeader {
  @ObjectLink model: ScheduleHeaderModel;

  private weekStart(): Date | null {
    for (let i = 0; i < this.model.weeks.length; i++) {
      if (this.model.weeks[i].serialNumber === this.model.currentWeek) {
        return DateUtil.parse(this.model.weeks[i].startDate);
      }
    }
    return null;
  }

  private dateLabel(index: number): string {
    const start = this.weekStart();
    if (start === null) {
      return '';
    }
    const day = DateUtil.addDays(start, index);
    return DateUtil.pad(day.getMonth() + 1) + '/' + DateUtil.pad(day.getDate());
  }

  build() {
    Row() {
      Blank()
        .width(24)

      ForEach(['周一', '周二', '周三', '周四', '周五', '周六', '周日'], (name: string, index: number) => {
        Column({ space: 2 }) {
          Text(name)
            .fontSize(AppFont.caption)
            .fontColor($r('app.color.header_text'))
            .fontWeight(index + 1 === DateUtil.currentWeekday() ? FontWeight.Bold : FontWeight.Normal)
            .textShadow({
              radius: $r('app.float.header_shadow_radius'),
              color: $r('app.color.header_shadow'),
              offsetX: 0,
              offsetY: 0
            })
          Text(this.dateLabel(index))
            .fontSize(10)
            .fontColor($r('app.color.header_text'))
        }
        .height(44)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }, (name: string, index: number) => index.toString())
    }
    .width('100%')
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
  }
}
