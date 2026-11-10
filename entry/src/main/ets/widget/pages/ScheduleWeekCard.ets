/**
 * 周课表 · 桌面卡片（4×4 / 6×4 两种尺寸，可拖拽调整）。
 *
 * ## 版式：像素级复刻北航官方课表
 *
 * | 元素 | 官方实测 | 实现 |
 * |---|---|---|
 * | 卡片底色 | `#2F3034` | 资源 `card_surface` |
 * | 标题 / 今天列 | 品牌橙 | `$r('app.color.card_accent')` |
 * | 左列宽 | 14.5% 卡宽 | `width('15%')` |
 * | 节高 | 网格区均分 | 每节 `layoutWeight(1)` |
 * | 课程块 | 深色底、白字 | 上游给什么色就什么色 |
 *
 * ## ⚠️⚠️ 布局踩过的三个坑（改这文件前务必读完）
 *
 * **① `layoutWeight` 在横向 `Row` 里控制的是「宽度」，不是高度。**
 * 最初写成「每行一个 `Row`（行高 `layoutWeight(1)`）+ 课块 `layoutWeight(10/span)`」，
 * 结果每门课**整体下沉一整行**、宽度也被挤乱。
 *
 * **② 纯 flex 表达不了「一个块跨 N 行」。**
 * 每格高度被父容器锁死为一行，无论怎么算权重都拼不出连续的块。
 *
 * **③ 绝对定位也走不通。**
 * `position` 的**百分比**偏移实测被解析成 0（项目早就踩过）；
 * 而要按**像素**定位就得先知道卡片多高，但 `onAreaChange` / `display`
 * 全部被编译器拦（`11706006 can't support form application`）—— 拿不到实测尺寸。
 *
 * **现在这版（唯一可行的）**：**每列是一个竖向 `Column`**，
 * 列里按节次顺序流出格子 —— 有课就画课块、没课就画一个透明占位，
 * 课块用 `layoutWeight(span)`。竖向 `Column` 里的 `layoutWeight` **确实是高度**。
 *
 * 一门跨 3 节的课占 3 份重量，正好吃掉它后面 2 个占位的高度，
 * 节次严格对齐，**且完全不需要知道任何绝对尺寸**。
 *
 * ## ⚠️ 卡片里不能滚动
 *
 * `Scroll` / `List` / `scrollBar` / `edgeEffect` / `onAreaChange` / `display`
 * 全部被编译器拦，所以节次一次性全画出来。
 *
 * ## 数据从哪来
 *
 * FRS 进程与主应用内存隔离，只能靠 `formProvider.updateForm` 推数据，
 * key 注入本页 `LocalStorage`，用**`@LocalStorageProp`** 接收。
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
const KEY_WEEK_VIEW: string = 'weekViewJson';
const KEY_UPDATED_W: string = 'updatedAt';

/** 一节课（与主应用 CardCache 的 CardSlot 同形）。 */
interface WeekViewSlot {
  day: number;
  begin: number;
  end: number;
  time: string;
  courseName: string;
  place: string;
  color: string;
}

/** 周课表卡数据（与主应用 CardCache 的 CardWeekView 同形）。 */
interface WeekViewData {
  termName: string;
  weekLabel: string;
  dates: string[];
  slots: WeekViewSlot[];
  sections: number;
  times: string[];
  today: number;
  /** 本学期总周数（左右箭头做边界判断用）。 */
  totalWeeks: number;
  ready: boolean;
}

/** 一周固定 7 天。 */
const DAYS: number = 7;
/** 网格行数上限。 */
const MAX_ROWS: number = 14;
/** 左列（节次号 + 时间）占卡宽比例 —— 官方实测 14.5%。 */
const SIDE_COL_RATIO: string = '15%';

/* ------------------------- 以下设计参数全部等比取自 App 内课表页 -------------------------
 * App 侧（`SchedulePage.ets`）：`SCHEDULE_COLUMN_WIDTH = 24`（左列宽 vp）、
 * `SECTION_CELL_HEIGHT = 56`（节高 vp）、节次号 `AppFont.caption = 12`、
 * 网格线 `width: 0.5`。
 *
 * 卡片只有 1180px 宽（≈ 394vp）且高度固定，**装不下 App 那个 24vp 左列 + 56vp 节高**
 * （13 节 × 56 = 728vp，6×4 卡才 ~250vp）。所以下面的值是**按比例缩小的同构设计**：
 * 左列宽 15%（App 是 24/394 ≈ 6%，这里给得更宽以容纳两行文字）、
 * 节高用权重均分（视觉上与 App 的等高网格一致）、字号 11→课程名 8 / 地点 7。
 *
 * **结构与 App 完全一致**（这两条不能改，否则视觉就不是同一个东西）：
 * 1. **网格线全宽通栏**，独立于课程列 —— 先画一整块线，再把课程块浮在上面；
 * 2. 课程块**不占据格子的布局位**（App 用 `position` 绝对定位浮在网格上）。
 */
const CARD_GRID_LINE_WIDTH: number = 0.5;

let weekCardStorage: LocalStorage = new LocalStorage();

@Entry(weekCardStorage)
@Component
struct ScheduleWeekCard {
  @LocalStorageProp(KEY_WEEK_VIEW) weekViewJson: string = '';
  @LocalStorageProp(KEY_UPDATED_W) updatedAt: string = '';

  @State private view: WeekViewData | null = null;

  aboutToAppear(): void {
    this.parse();
  }

  private parse(): void {
    if (this.weekViewJson.length === 0) {
      this.view = null;
      return;
    }
    try {
      this.view = JSON.parse(this.weekViewJson) as WeekViewData;
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

  /** 网格要画几行（= 该学期的节次数）。 */
  private rowCount(): number {
    const n = this.view?.sections ?? 0;
    if (n < 1) {
      return 6;
    }
    return n > MAX_ROWS ? MAX_ROWS : n;
  }

  /** 1..sections 的行号数组。 */
  private rowList(): number[] {
    const out: number[] = [];
    for (let i = 1; i <= this.rowCount(); i++) {
      out.push(i);
    }
    return out;
  }

  /** 某一天（1~7）的课程。 */
  private slotsOfDay(day: number): WeekViewSlot[] {
    const slots = this.view?.slots ?? [];
    const out: WeekViewSlot[] = [];
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].day === day) {
        out.push(slots[i]);
      }
    }
    return out;
  }

  /**
   * **从第 row 节开始**的课（不是「覆盖 row 的课」）。
   *
   * 跨节课只在它起始的那一节画一次，高度靠权重吃掉后面几节。
   */
  private slotsStartingAt(day: number, row: number): WeekViewSlot[] {
    const all = this.slotsOfDay(day);
    const out: WeekViewSlot[] = [];
    for (let i = 0; i < all.length; i++) {
      const begin = all[i].begin < 1 ? 1 : all[i].begin;
      if (begin === row) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /** 这门课占几节（至少 1，且不超网格行数）。 */
  private spanOf(slot: WeekViewSlot): number {
    const rows = this.rowCount();
    const begin = slot.begin < 1 ? 1 : slot.begin;
    const end = slot.end > rows ? rows : slot.end;
    return end - begin + 1 > 0 ? end - begin + 1 : 1;
  }

  /**
   * 第 row 节在某一天占多少份权重。
   *
   * - 该节有课开始 → 这门课跨几节就占几份；
   * - 该节被**别的**跨节课覆盖 → **0 份**（不占高度）；
   * - 真的没课 → 1 份。
   *
   * ⚠️ 「被覆盖 → 0 份」是**权重总量能对齐**的关键：
   * 每一列的权重总量恒等于节次数，左列（每节恒 1 份）才能与它对齐。
   */
  private weightAtRow(day: number, row: number): number {
    const starts = this.slotsStartingAt(day, row);
    if (starts.length > 0) {
      return this.spanOf(starts[0]);
    }
    const all = this.slotsOfDay(day);
    for (let i = 0; i < all.length; i++) {
      const begin = all[i].begin < 1 ? 1 : all[i].begin;
      if (row > begin && row <= all[i].end) {
        return 0;
      }
    }
    return 1;
  }

  /** 这门课的底色（上游给空/ 格式异常时退回深棕）。 */
  private blockColor(slot: WeekViewSlot): string {
    return slot.color.length >= 7 ? slot.color : '#583830';
  }

  /**
   * 课程块上的文字色 —— **按底色亮度自动选黑/白**。
   *
   * 上游给的课块颜色深浅不一，固定白字在浅色块上完全看不清。
   * 卡片里不能调任何系统 API，所以纯字符串解析 + WCAG 相对亮度公式。
   */
  private textColorOn(slot: WeekViewSlot): string {
    const hex: string = this.blockColor(slot);
    const lum: number = (0.299 * this.channelOf(hex, 0) + 0.587 * this.channelOf(hex, 1) +
      0.114 * this.channelOf(hex, 2)) / 255;
    return lum > 0.5 ? '#1A1A1A' : '#FFFFFF';
  }

  /** 次要文字（地点）色。 */
  private subTextColorOn(slot: WeekViewSlot): string {
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

  private weekdayText(day: number): string {
    const names: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const i: number = day - 1;
    if (i < 0 || i >= names.length) {
      return '';
    }
    return names[i];
  }

  private dateOf(day: number): string {
    const dates = this.view?.dates ?? [];
    const i: number = day - 1;
    if (i < 0 || i >= dates.length) {
      return '';
    }
    return dates[i];
  }

  private isToday(day: number): boolean {
    return (this.view?.today ?? 0) === day;
  }

  @Builder
  emptyView() {
    Column({ space: 6 }) {
      Text('周课表')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.card_accent'))
      Text('打开 App 获取本学期课表')
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
   * 一个课程块。
   *
   * **高度由外层格子 `Row` 的 `layoutWeight(span)` 给** —— 跨 N 节的课占 N 份，
   * 正好与下面 N 个透明占位等高。这里**不能自己设 height**，否则会覆盖掉权重高度。
   *
   * ## 文字排布照抄 App 内课表页（SchedulePage.courseBlock）
   *
   * **课程名 `layoutWeight(1)` 撑满 + 教室贴底**，不写 `SpaceBetween`：
   * 教室按自然高度完整占位，课程名拿剩下的空间，不够时自己收成省略号。
   * 反过来写（课程名固定行数、教室兜底）就会出现「教室名被截断」。
   */
  @Builder
  courseBlock(slot: WeekViewSlot) {
    Column() {
      // 课程名贴顶，占满可用宽度；撑高时显式贴顶（盒子被 layoutWeight 撑开默认会居中）
      Text(slot.courseName)
        .fontSize(8)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.textColorOn(slot))
        .maxLines(9)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
      // 教室贴底：给足行数优先完整显示
      if (slot.place.length > 0) {
        Text(slot.place)
          .fontSize(7)
          .fontColor(this.subTextColorOn(slot))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .align(Alignment.BottomStart)
      }
    }
    .width('100%')
    .height('100%')
    // **块间距用 margin，且要大于竖线宽（0.5）** —— 这样块的左边缘正好停在
    // 竖线内侧，整块完全落在「竖线 × 下一条竖线」围成的格子里，
    // 既不压线，宽度又几乎顶满（用户要求「加宽 + 左侧更接近数字列」）。
    // 用 margin 不用 padding：margin 落在 border 之外，不影响分隔线的绘制。
    .margin({ left: 2, right: 1, top: 1.5, bottom: 1.5 })
    .padding({ left: 2, right: 2, top: 1, bottom: 1 })
    .alignItems(HorizontalAlign.Start)
    // 不写 SpaceBetween —— 课程名靠 layoutWeight 撑满，教室自然被顶到最底部
    .justifyContent(FlexAlign.Start)
    .backgroundColor(this.blockColor(slot))
    // ⚠️ **`borderRadius` 必须写在 `clip` 之前声明** —— 顺序反了 clip 会作用在
    // 未圆角的矩形上（用户实机看到课程块左侧「圆角外还有文字」的乱象）。
    .borderRadius(5)
    .clip(true)
  }

  /**
   * 网格背景线 —— **全宽通栏**（照抄 App 内课表页 `scheduleGrid` 的做法）。
   *
   * App 的实现是「先画一整块通栏的线，再把课程块浮在上面」：
   * ```
   * Column {                       // 背景网格线
   *   ForEach(sections, Row().width('100%').height(SECTION_CELL_HEIGHT).border(0.5))
   * }
   * Stack {                        // 课程块浮在上面
   *   ForEach(dayClusters, courseCluster)
   * }
   * ```
   *
   * ## 为什么这一改就修好了横线断点（连报三轮的bug）
   *
   * 之前每一列各画各的 `border(bottom)`，任何一列只要有 padding / 权重不一致，
   * 线就会错位或断开。**通栏一整块线根本不存在「列」的概念** —— 它是连续的，
   * 因此**不可能有断点**。课程块只是浮在它上面，不需要参与线的绘制。
   *
   * 线宽用 App 同款 `0.5`（比之前 1 更细，正好落在「能看见但不抢眼」的档位）。
   */
  @Builder
  gridLines() {
    Column() {
      ForEach(this.rowList(), (row: number) => {
        Row()
          .width('100%')
          .layoutWeight(1)
          .border({
            width: { bottom: CARD_GRID_LINE_WIDTH },
            color: $r('app.color.card_divider'),
            style: BorderStyle.Solid
          })
      }, (row: number) => 'line' + row.toString())
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 竖线**画在块列的左侧 border 上**，而不是独立的竖条元素。
   *
   * ## 为什么不用独立竖条
   *
   * 独立 `Row().width(0.5)` 会**占掉0.5vp 的布局宽度** ——
   * 七列各让出 0.5vp，块全都被推离左侧数字列，看起来「块离数字很远」。
   * 改成 `border({ width: { left: 0.5 } })` 画在列容器上：
   * border 在**盒子内部**，不占布局宽度 → 块紧贴竖线内侧，宽度也顶满。
   *
   * App 内课表页也是这个思路（`layoutWeight(1)×7` 严格对齐，线是背景层画的）。
   */

  /**
   * 网格的一列（某一天）：**只放课程块，不画线**（线由 `gridLines` 通栏负责）。
   *
   * 竖向 `Column` + `layoutWeight` 的权重规则与左列一致，
   * 保证每门课的纵向位置与左列节次号严格对齐。
   */
  @Builder
  dayColumn(day: number) {
    Column() {
      ForEach(this.rowList(), (row: number) => {
        Row() {
          ForEach(this.slotsStartingAt(day, row), (slot: WeekViewSlot) => {
            this.courseBlock(slot)
          }, (slot: WeekViewSlot) =>
            // key 带全部身份字段：同一时段可能有**同名同色**的两门实验班
            'b' + slot.day + '-' + slot.begin + '-' + slot.end + '-' +
            slot.courseName + '-' + slot.place)
        }
        .width('100%')
        .layoutWeight(this.weightAtRow(day, row))
        .alignItems(VerticalAlign.Top)
      }, (row: number) => 'r' + row.toString() + '-d' + day.toString())
    }
    .layoutWeight(1)
    .height('100%')
    // 左侧竖线：画在 border 上（border 在盒子**内部**，不占布局宽度），
    // 这样块能紧贴竖线内侧，宽度也顶满 —— 独立竖条元素会把块推开 0.5vp
    .border({
      width: { left: CARD_GRID_LINE_WIDTH },
      color: $r('app.color.card_divider'),
      style: BorderStyle.Solid
    })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      if (this.view === null) {
        this.emptyView()
      } else {
        // 顶部：左学期名（品牌橙粗体）· 右「‹ 第 N 周 ›」周次控件
        Row() {
          Text(this.view?.termName ?? '')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.card_accent'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 周次：**纯文本，不做互动控件**（用户明确要求 —— 卡片里的箭头
          // 只能靠 postCardAction 拉起 App，交互路径太长，体验反而差）
          Text(this.view?.weekLabel ?? '')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 6 })

        // 星期表头：星期（今天染橙）+ 下方日期；左侧留一个与网格左列同宽的占位
        Row() {
          Column() {}
            .width(SIDE_COL_RATIO)
          ForEach(Array.from({ length: DAYS }, (_: number, i: number) => i + 1),
            (day: number) => {
              Column({ space: 1 }) {
                Text(this.weekdayText(day))
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.isToday(day) ?
                    $r('app.color.card_accent') : $r('app.color.text_primary'))
                  .maxLines(1)
                Text(this.dateOf(day))
                  .fontSize(9)
                  .fontColor(this.isToday(day) ?
                    $r('app.color.card_accent') : $r('app.color.text_secondary'))
                  .maxLines(1)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
            }, (day: number) => 'h' + day.toString())
        }
        .width('100%')
        .margin({ bottom: 4 })

        // 网格：**结构与 App 内课表页完全一致** ——
        // `Stack { ① 通栏网格线（底层） ② 左列节次号 + 七天课块 }`。
        //
        // 这就是App 的 `scheduleGrid()`：线是**一整块通栏**的，课程块浮在上面，
        // 不参与线的绘制。所以线**不可能断**（前几轮各列各画线才是断点根源）。
        Stack({ alignContent: Alignment.TopStart }) {
          // ① 底层：全宽通栏网格线（同时覆盖左列区域，App 也是整块线）
          this.gridLines()

          // ② 上层：左列节次号 + 七天课块（透明，只放内容）
          Row() {
            // 左列：只显示节次号，**贴左**（App 里是 `width(SCHEDULE_COLUMN_WIDTH)` 居中，
            // 这里左对齐是用户上一轮明确要求的）
            Column() {
              ForEach(this.rowList(), (row: number) => {
                Text(row.toString())
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .width('100%')
                  .layoutWeight(1)
                  .align(Alignment.Start)
              }, (row: number) => 'sec' + row.toString())
            }
            .width(SIDE_COL_RATIO)
            .height('100%')
            // 左列右边界竖线（同样用 border 画，不占布局宽度）
            .border({
              width: { right: CARD_GRID_LINE_WIDTH },
              color: $r('app.color.card_divider'),
              style: BorderStyle.Solid
            })

            // 七天列：每列一个竖向 Column（只放课块，竖线由列自身的 border 画）
            Row() {
              ForEach(Array.from({ length: DAYS }, (_: number, i: number) => i + 1),
                (day: number) => {
                  this.dayColumn(day)
                }, (day: number) => 'col' + day.toString())
            }
            .layoutWeight(1)
            .height('100%')
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .clip(false)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.card_surface'))
    .onClick(() => {
      this.openApp();
    })
  }
}