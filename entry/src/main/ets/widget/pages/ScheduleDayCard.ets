/**
 * 日课表 · 桌面卡片（4×4 / 2×4 两种尺寸，可拖拽调整）。
 *
 * ## 版式：像素级复刻北航官方课表卡的「日视图」
 *
 * ```
 * ┌───────────────────────────────────────┐
 * │ 10月11日 星期日·  第 5 周              │  ← 日期橙 + 星期白 / 右侧周次
 * │            今日无课程                │  ← 空态居中
 * │ 明天  ③│  ← 分组标题 + 节数
 * │ ┌───────────────────────────────────┐ │
 * │ │ 理论力学A（1）        14:00 │ 15:35 │ │  ← 左课名+地点 / 右时间两行
 * │ │ J3-212 | 吕敬│ │
 * │ └───────────────────────────────────┘ │
 * └───────────────────────────────────────┘
 * ```
 *
 * 实测规格（官方截图 1249×552px）：卡片底色 `#2F3034`、课程块 `#602030`、标题橙 `#F76045`。
 *
 * ## 为什么「今天没课时把明天的课顶上来」
 *
 * 官方就是这么做的 —— 今天是周日没课，它把**明天（周一）的第一节**顶上来，
 * 并在左侧标「明天 ③」（③ = 明天有 3 节课）。空白卡没有任何信息量，
 * 「下一节课」才是用户真正想知道的。
 *
 * 数据由主应用算好推过来（`dayLabel` / `dayCount`），卡片不自己判断时间 ——
 * 卡片渲染进程与主应用的时间可能差几秒，让卡片自己算会显示错。
 *
 * ## ⚠️ 卡片里不能滚动
 *
 * `Scroll` / `List` / `scrollBar` / `edgeEffect` 全部被编译器拦
 *（`'Scroll' can't support form application`，错误码 11706006）——
 * 所以课程一次性全画出来，不做滚动。
 *
 * ## 数据从哪来
 *
 * FRS 进程与主应用内存隔离，靠 `formProvider.updateForm` 推数据，
 * key 注入本页 `LocalStorage`，用 **`@LocalStorageProp`** 接收。
 * 官方明写「接收数据时会被转换成 string 类型」，所以收到的是 JSON 串。
 *
 * ## ⚠️ 本文件为什么这么「空」
 *
 * 1. **不能用 hilog** —— `'hilog' can't support form application`，构建期就拦；
 * 2. **不 import 项目的任何 .ets** —— 官方 FAQ：卡片不支持加载
 *    particleAbility / audio / camera / media / backgroundTaskManager，
 *    「强行加载得到的对象是 undefined，使用时就会产生 JS crash」。
 */

/** LocalStorage key（必须与 UBAAFormAbility 推送的字段名完全一致）。 */
const KEY_DAY_VIEW: string = 'dayViewJson';
const KEY_UPDATED_D: string = 'updatedAt';

/** 一节课（与主应用 CardCache 的 CardSlot 同形）。 */
interface DayViewSlot {
  day: number;
  begin: number;
  end: number;
  time: string;
  courseName: string;
  place: string;
  color: string;
}

/**
 * 日课表卡数据。
 *
 * 与主应用 `CardCache.CardDayView` 同形，额外两个字段服务于「今天没课」的顶替显示：
 * - `dayLabel`：`今天` / `明天` / `周三` —— 空态时顶上来的那天的名字；
 * - `dayCount`：那一天有几节课（官方在分组标题后跟一个数字）。
 */
interface DayViewData {
  headline: string;
  day: number;
  slots: DayViewSlot[];
  sections: number;
  times: string[];
  dayLabel: string;
  dayCount: number;
  ready: boolean;
}

let dayCardStorage: LocalStorage = new LocalStorage();

@Entry(dayCardStorage)
@Component
struct ScheduleDayCard {
  @LocalStorageProp(KEY_DAY_VIEW) dayViewJson: string = '';
  @LocalStorageProp(KEY_UPDATED_D) updatedAt: string = '';

  @State private view: DayViewData | null = null;

  aboutToAppear(): void {
    this.parse();
  }

  private parse(): void {
    if (this.dayViewJson.length === 0) {
      this.view = null;
      return;
    }
    try {
      this.view = JSON.parse(this.dayViewJson) as DayViewData;
    } catch (error) {
      this.view = null;
    }
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        target: 'schedule'
      }
    });
  }

  /** 时间拆成起 / 止两行（官方右侧就是两行：`14:00` / `15:35`）。 */
  private timeParts(slot: DayViewSlot): string[] {
    const full: string = slot.time;
    const i: number = full.indexOf('~');
    if (i > 0) {
      return [full.substring(0, i), full.substring(i + 1)];
    }
    return full.length > 0 ? [full, ''] : ['', ''];
  }

  /** 这门课占几节（至少 1）。 */
  private spanOf(slot: DayViewSlot): number {
    const span = slot.end - slot.begin + 1;
    return span > 0 ? span : 1;
  }

  /** 上游颜色为空 / 格式异常时退回官方那个酒红 `#602030`。 */
  private colorOf(slot: DayViewSlot): string {
    return slot.color.length >= 7 ? slot.color : '#602030';
  }

  /**
   * 课块上的文字色 —— **按底色亮度自动选黑/白**。
   *
   * 上游给的课块颜色深浅不一，固定白字在浅色块上完全看不清（用户实机反馈）。
   * 卡片里不能调任何系统 API，所以纯字符串解析 + WCAG 相对亮度公式。
   */
  private textColorOn(slot: DayViewSlot): string {
    const hex: string = this.colorOf(slot);
    const lum: number = (0.299 * this.channelOf(hex, 0) + 0.587 * this.channelOf(hex, 1) +
      0.114 * this.channelOf(hex, 2)) / 255;
    return lum > 0.5 ? '#1A1A1A' : '#FFFFFF';
  }

  /** 次要文字（地点）色。 */
  private subTextColorOn(slot: DayViewSlot): string {
    return this.textColorOn(slot) === '#FFFFFF' ? '#CCFFFFFF' : '#661A1A1A';
  }

  /** 取 `#RRGGBB` 里第 index 个通道（0=红 1=绿 2=蓝）；解析失败返回 0。 */
  private channelOf(hex: string, index: number): number {
    const start: number = 1 + index * 2;
    if (hex.length < start + 2) {
      return 0;
    }
    const v: number = parseInt(hex.substring(start, start + 2), 16);
    return isNaN(v) ? 0 : v;
  }

  @Builder
  emptyView() {
    Column({ space: 6 }) {
      Text('日课表')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.card_accent'))
      Text('打开 App 获取课表')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
      Text(this.updatedAt.length > 0 ? '更新于 ' + this.updatedAt : '')
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 一节课：整条圆角色块，左边课名 + 地点，右边起止时间两行。
   *
   * 高度用 `layoutWeight(span)` 均分 —— 跨节课更高，两张尺寸都自动适配。
   */
  @Builder
  courseCard(slot: DayViewSlot, span: number) {
    Row() {
      Column({ space: 2 }) {
        // 照抄 App 内课表页：课程名 layoutWeight(1) 撑满，地点自然贴底
        Text(slot.courseName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColorOn(slot))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
        // 地点：**只在跨节课上显示**。单节课行高最小，2×4 卡片上
        // 每行都塞地点会被裁成半行（用户实机看到「J3-212」只剩上半截）。
        if (slot.place.length > 0 && span > 1) {
          Text(slot.place)
            .fontSize(10)
            .fontColor(this.subTextColorOn(slot))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .align(Alignment.BottomStart)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 右侧起止时间（官方是上下两行）
      Column({ space: 1 }) {
        Text(this.timeParts(slot)[0])
          .fontSize(12)
          .fontColor(this.textColorOn(slot))
          .maxLines(1)
        Text(this.timeParts(slot)[1])
          .fontSize(12)
          .fontColor(this.textColorOn(slot))
          .maxLines(1)
      }
      .width(46)
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .layoutWeight(span)
    // 块间距：上下各 3vp，相邻两块之间留一道细缝
    .margin({ top: 3, bottom: 3 })
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .alignItems(VerticalAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.colorOf(slot))
    // 矮卡片（2×4）上文字会被裁半行 —— 圆角 + 裁切让溢出部分干脆不可见，
    // 而不是像实机截图那样「J3-212 / 14:00 各切掉下半行」。
    .clip(true)
  }

  build() {
    Column() {
      if (this.view === null) {
        this.emptyView()
      } else {
        // 顶部：左日期 + 星期（橙），右「第 N 周」
        // ⚠️ headline **必须给 layoutWeight** —— 不给的话它会按内容宽度
        // 把右边的「第 N 周」挤到贴在一起（实机挤成「周一 · 10/05第 5 周」）。
        Row() {
          Text(this.view?.headline ?? '')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.card_accent'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('第 5 周')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        if ((this.view?.slots?.length ?? 0) === 0) {
          // 今天真的没课 —— 一句说明，别让上半张卡空着
          Text('今日无课程')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 10, bottom: 10 })
        }

        // 分组标题：`明天 ③` 这种（官方写法）
        Row({ space: 6 }) {
          Text(this.view?.dayLabel ?? '今天')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text((this.view?.dayCount ?? 0).toString())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.card_accent'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        // 课程列表
        Column({ space: 8 }) {
          ForEach(this.view?.slots ?? [], (slot: DayViewSlot) => {
            this.courseCard(slot, this.spanOf(slot))
          }, (slot: DayViewSlot) =>
            // key 带 begin + 全身份：同一天可能有**同名同色**的两门实验班
            'd' + slot.begin + '-' + slot.end + '-' + slot.courseName + '-' + slot.place)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.card_surface'))
    .onClick(() => {
      this.openApp();
    })
  }
}