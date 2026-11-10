import { LoadState } from '../common/AppRouter';
import { CardCache, CardClassroom } from '../common/CardCache';
import { DateUtil } from '../common/DateUtil';
import { GlobalContext } from '../common/GlobalContext';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { selectMenuMaterial } from '../common/SystemMaterial';
import { EmptyView, ErrorView, LoadingView, SectionCard } from '../components/CommonViews';
import { ClassroomInfo, ClassroomQueryResponse } from '../model/ApiTypes';

/** 校区选项：xqid 与 UBAA 上游保持一致。 */
interface CampusOption {
  id: number;
  name: string;
}

/**
 * 节次列：**单节** 1~14（不是 1-2 / 3-4 那种两节合并）。
 *
 * 上游 `kxsds` 给的就是单节序号（如 `"1,2,5,6"`），**一节一格**才看得出「只空一节」的情况；
 * 两节合并会把「中间空一节」这种信息抹掉（也是原版 App 的做法）。
 */
const PERIODS: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10', '11', '12', '13', '14'];

/** 教室名列宽（vp）—— 窄一点，把宽度让给 14 个节次列。 */
const ROOM_COL_WIDTH: number = 56;
/** 表格距卡片左右边缘的留白（vp）：**左右对称**，卡片内边距 16 靠负外边距抵消。 */
const TABLE_SIDE_INSET: number = 8;
/** 表头 / 数据行高（vp）。 */
const HEAD_ROW_HEIGHT: number = 34;
const DATA_ROW_HEIGHT: number = 38;
/** 普通格线宽度（vp）。 */
const GRID_LINE: number = 0.5;
/**
 * **粗格线**宽度（vp）与位置。
 *
 * 第 5 节之后、第 10 节之后各拉一条更粗的线 —— 这是课表类表格的惯例
 * （上下午 / 大课间的分界），扫一眼就能定位节次，不用一格一格数。
 */
const GRID_LINE_MAJOR: number = 1.6;
const MAJOR_BOUNDARIES: number[] = [5, 10];

/** 第 `section` 节之后是不是「粗线位置」。 */
function isMajorBoundary(section: number): boolean {
  return MAJOR_BOUNDARIES.indexOf(section) >= 0;
}

/**
 * 空闲教室查询。
 *
 * ## 展示参照 UBAA 网页版「空闲教室查询」
 *
 * 校区 → 日期 → 教学楼（可留空）→ 查询 → 说明 → 按教学楼分组的**表格**：
 * 行 = 教室、列 = 节次（双节一组），绿色格 = 该教室这一段空闲。
 *
 * 说明：上游只给「空闲节次」列表（`kxsds`），**没有**「占用」信息，所以表格里
 * 非空闲的格子留空、不做任何标记 —— 与网页版一致。
 *
 * ## 选择器为什么用 `Select` 而不是一排胶囊
 *
 * 参考图的查询卡片就是「标签 + 选择框 + 箭头」两行 + 一个通栏查询按钮；
 * 而且日期 / 教学楼候选项数量随数据变化（教学楼可能十几个），胶囊排不下。
 */
@Component
export struct ClassroomPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private dates: string[] = [];
  @State private selectedDate: string = '';
  @State private campuses: CampusOption[] = [
    { id: 1, name: '学院路校区' },
    { id: 2, name: '沙河校区' },
    { id: 3, name: '杭州校区' }
  ];
  @State private campusId: number = 2;
  /** 查询卡片里「待提交」的选择；点『查询』才真正生效。 */
  @State private pendingCampusId: number = 2;
  @State private pendingDate: string = '';
  @State private buildings: string[] = [];
  /** 教学楼筛选：空串 = 全部。 */
  @State private pendingBuilding: string = '';
  @State private buildingFilter: string = '';
  /** 教学楼 → 教室列表。非 @State：由 buildings 变化驱动重绘即可。 */
  private roomMap: Record<string, ClassroomInfo[]> = {};

  aboutToAppear(): void {
    this.selectedDate = DateUtil.today();
    this.pendingDate = this.selectedDate;
    const list: string[] = [];
    for (let i = 0; i < 7; i++) {
      list.push(DateUtil.format(DateUtil.addDays(new Date(), i)));
    }
    this.dates = list;
    this.query();
  }

  private async query(): Promise<void> {
    this.loadState = LoadState.LOADING;
    this.selectedDate = this.pendingDate;
    this.campusId = this.pendingCampusId;
    this.buildingFilter = this.pendingBuilding;
    try {
      const data: ClassroomQueryResponse = await ApiService.queryClassroom(this.campusId, this.selectedDate);
      if (data.e !== 0) {
        this.errorMessage = data.m.length > 0 ? data.m : '查询失败';
        this.loadState = LoadState.ERROR;
        return;
      }
      this.roomMap = data.d.list;
      this.buildings = Object.keys(data.d.list);
      // 换过校区 / 日期后，原先选的教学楼可能不存在了 → 落回「全部」
      if (this.buildingFilter.length > 0 && this.buildings.indexOf(this.buildingFilter) < 0) {
        this.buildingFilter = '';
        this.pendingBuilding = '';
      }
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '教室查询失败';
      this.loadState = LoadState.ERROR;
      Logger.error('教室查询失败：' + (error as Error).message);
    }
    this.pushToCards();
  }

  /**
   * 把这次查询的空闲教室写进桌面卡片缓存（空闲间数 + 一个具体教室号）。
   *
   * 与课表卡同样的道理：卡片进程不能联网（见 `CardCache`）。
   *
   * 两个关键取舍：
   * 1. **只记「这一批」不记历史**：卡片上明确写出查询日期，用户能判断新鲜度 ——
   *    空闲教室是按天查的，隔天再显示昨天的结果毫无意义甚至误导；
   * 2. **给一个具体教室号而不只是间数**：「空闲 12 间」用户还得再点进去查，
   *    直接给出 `J3-101` 才能一眼决定去不去。
   */
  private pushToCards(): void {
    try {
      let total: number = 0;
      let firstRoom: string = '';
      let firstBuilding: string = '';
      const buildings: string[] = this.buildings;
      for (let i = 0; i < buildings.length; i++) {
        const rooms: ClassroomInfo[] = this.roomsOf(buildings[i]);
        total += rooms.length;
        if (firstRoom.length === 0 && rooms.length > 0) {
          firstRoom = rooms[0].name;
          firstBuilding = buildings[i];
        }
      }
      const isToday: boolean = this.selectedDate === DateUtil.today();
      const snapshot: CardClassroom = {
        dateText: (isToday ? '今天 · ' : '') + this.dateLabel(this.selectedDate),
        roomText: firstRoom.length > 0 ? firstRoom : '暂无',
        summary: total > 0 ?
          ('空闲 ' + total.toString() + ' 间 · ' + firstBuilding) :
          '当天没有空闲教室',
        ready: true
      };
      Logger.info('写入空闲教室卡片：' + snapshot.dateText + ' ' + snapshot.summary);
      CardCache.saveClassroom(GlobalContext.getContext(), snapshot);
    } catch (error) {
      Logger.warn('写入空闲教室卡片缓存失败：' + (error as Error).message);
    }
  }

  /** `2026-10-15` → `10月15日`；格式不认就原样返回。 */
  private dateLabel(text: string): string {
    if (text.length >= 10) {
      return text.substring(5, 7) + '月' + text.substring(8, 10) + '日';
    }
    return text;
  }

  /* ---------------------------- 选择器候选 ---------------------------- */

  private campusOptions(): SelectOption[] {
    const list: SelectOption[] = [];
    for (let i = 0; i < this.campuses.length; i++) {
      list.push({ value: this.campuses[i].name });
    }
    return list;
  }

  private campusIndex(): number {
    for (let i = 0; i < this.campuses.length; i++) {
      if (this.campuses[i].id === this.pendingCampusId) {
        return i;
      }
    }
    return 0;
  }

  private dateOptions(): SelectOption[] {
    const list: SelectOption[] = [];
    for (let i = 0; i < this.dates.length; i++) {
      list.push({ value: this.dates[i] });
    }
    return list;
  }

  private dateIndex(): number {
    const i: number = this.dates.indexOf(this.pendingDate);
    return i >= 0 ? i : 0;
  }

  private buildingOptions(): SelectOption[] {
    const list: SelectOption[] = [{ value: '全部' }];
    for (let i = 0; i < this.buildings.length; i++) {
      list.push({ value: this.buildings[i] });
    }
    return list;
  }

  private buildingIndex(): number {
    if (this.pendingBuilding.length === 0) {
      return 0;
    }
    const i: number = this.buildings.indexOf(this.pendingBuilding);
    return i >= 0 ? i + 1 : 0;
  }

  private campusName(id: number): string {
    const list: CampusOption[] = this.campuses;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return list[i].name;
      }
    }
    return '校区';
  }

  /* ---------------------------- 数据换算 ---------------------------- */

  private roomsOf(building: string): ClassroomInfo[] {
    const rooms = this.roomMap[building];
    return rooms !== undefined ? rooms : [];
  }

  /** 当前要显示的教学楼（受筛选影响）。 */
  private shownBuildings(): string[] {
    if (this.buildingFilter.length === 0) {
      return this.buildings;
    }
    return this.buildings.indexOf(this.buildingFilter) >= 0 ? [this.buildingFilter] : [];
  }

  /** kxsds（如 "1,2,5,6"）→ 空闲单节集合，便于查表。 */
  private freeSet(kxsds: string): number[] {
    if (kxsds.length === 0) {
      return [];
    }
    const parts: string[] = kxsds.split(',');
    const result: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const n: number = Number.parseInt(parts[i], 10);
      if (!Number.isNaN(n)) {
        result.push(n);
      }
    }
    return result;
  }

  /**
   * 某一**节**（1 基的节次序号）是否空闲。
   *
   * 上游 `kxsds` 就是空闲的单节列表，直接查表即可 —— 不做「两节才算空」的合并，
   * 否则「只空一节」的格子会被吞掉。
   */
  private isFree(room: ClassroomInfo, section: number): boolean {
    return this.freeSet(room.kxsds).indexOf(section) >= 0;
  }

  /** kxsds 形如 "1,2,5,6"，转换为中文节次文案。 */
  private freeSections(kxsds: string): string {
    if (kxsds.length === 0) {
      return '全天空闲';
    }
    return kxsds.split(',').join('、') + ' 节';
  }

  /* ------------------------------ UI ------------------------------ */

  /** 顶部：当前（待查询）校区。点卡片里的「校区」选择框改它。 */
  @Builder
  campusRow() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.location_up_fill'))
        .fontSize(18)
        .fontColor([AppColor.brand])
      Text(this.campusName(this.pendingCampusId))
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 查询卡片：校区 / 日期 / 教学楼 + 通栏「查询」（照参照图的顺序与结构）。
   *
   * 三行选择框是**故意展开写**的，没有抽成带回调参数的 `@Builder` ——
   * ArkTS 里给 `@Builder` 传函数参数容易出问题（本项目一律避开），
   * 而三行结构完全对称，重复的代价很小。
   */
  @Builder
  queryCard() {
    SectionCard({ showAction: false }) {
      Column({ space: AppSize.gapSmall }) {
        Row({ space: AppSize.gapSmall }) {
          Text('校区')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
            .width(48)
          Select(this.campusOptions())
            .selected(this.campusIndex())
            // ⚠️ `value()` 必须给：只设 `selected()` 时选择框里**不显示当前值**（只剩一个箭头），
            //    真机实测如此。三项选择器都要成对写。
            .value(this.campusName(this.pendingCampusId))
            // 下拉菜单也走同一套沉浸光感（系统给 Select 留的口子，见 selectMenuMaterial）
            .menuSystemMaterial(selectMenuMaterial())
            .font({ size: AppFont.body })
            .layoutWeight(1)
            .onSelect((index: number) => {
              this.pendingCampusId = this.campuses[index].id;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: AppSize.gapSmall }) {
          Text('日期')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
            .width(48)
          Select(this.dateOptions())
            .selected(this.dateIndex())
            .value(this.pendingDate)
            .menuSystemMaterial(selectMenuMaterial())
            .font({ size: AppFont.body })
            .layoutWeight(1)
            .onSelect((index: number) => {
              this.pendingDate = this.dates[index];
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: AppSize.gapSmall }) {
          Text('教学楼')
            .fontSize(AppFont.body)
            .fontColor(AppColor.textSecondary)
            .width(48)
          Select(this.buildingOptions())
            .selected(this.buildingIndex())
            .value(this.pendingBuilding.length > 0 ? this.pendingBuilding : '全部')
            .menuSystemMaterial(selectMenuMaterial())
            .font({ size: AppFont.body })
            .layoutWeight(1)
            .onSelect((index: number) => {
              // 第 0 项是「全部」→ 空串表示不筛选
              this.pendingBuilding = index <= 0 ? '' : this.buildings[index - 1];
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Button('查询')
          .width('100%')
          .height(44)
          .fontSize(AppFont.body)
          .backgroundColor(AppColor.brand)
          .margin({ top: 4 })
          .onClick(() => {
            this.query();
          })
      }
      .width('100%')
    }
  }

  /** 说明卡片：绿色格的含义 + 上游的两条限制（照抄网页版的说明文案）。 */
  @Builder
  helpCard() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text('说明：')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
        Column()
          .width(28)
          .height(16)
          .borderRadius(4)
          .backgroundColor(AppColor.classroomFree)
        Text('为该教室空闲的节数')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 第二行图例（浅红）：非空闲格现在有底色，图例不补上就说不清那是什么
      Row({ space: 8 }) {
        Column()
          .width(28)
          .height(16)
          .borderRadius(4)
          .backgroundColor(AppColor.classroomBusy)
        Text('为该节次已被占用')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
      }
      .width('100%')
      // 左边距对齐上一行的色块（「说明：」标签宽 + 间距）
      .padding({ left: 44 })
      .alignItems(VerticalAlign.Center)

      Text('当前时间以前的空教室不显示')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surfaceSubtle)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 一个教学楼的空闲教室表。
   *
   * 行 = 教室、列 = 节次（双节一组）。**表头与数据行必须用同一套宽度结构**
   * （固定教室列 + `layoutWeight(1)` 的节次列）—— 一边写百分比、一边写固定值就对不齐。
   */
  @Builder
  buildingTable(building: string) {
    SectionCard({ showAction: false }) {
      Column() {
        Text(building)
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ bottom: 10 })

        Row() {
          Text('节次/教室')
            .fontSize(10)
            .fontColor(AppColor.textSecondary)
            .width(ROOM_COL_WIDTH)
            .textAlign(TextAlign.Start)
            .padding({ left: 2 })
            .height(HEAD_ROW_HEIGHT)
          ForEach(PERIODS, (label: string, index: number) => {
            Text(label)
              .fontSize(10)
              .fontColor(AppColor.textSecondary)
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .height(HEAD_ROW_HEIGHT)
              // 表头的粗线位置与数据行保持一致，否则上下对不齐
              .border({
                width: { right: isMajorBoundary(index + 1) ? GRID_LINE_MAJOR : GRID_LINE },
                color: AppColor.classroomGrid
              })
          }, (label: string) => label)
        }
        .width('100%')
        .backgroundColor(AppColor.surfaceSubtle)
        .borderRadius({ topLeft: 8, topRight: 8 })

        ForEach(this.roomsOf(building), (room: ClassroomInfo) => {
          Row() {
            Text(room.name)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.brand)
              .width(ROOM_COL_WIDTH)
              .height(DATA_ROW_HEIGHT)
              // 教室名靠左贴边（列也相应缩窄到 56vp），两侧留白对称
              .textAlign(TextAlign.Start)
              .padding({ left: 2 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            ForEach(PERIODS, (label: string, index: number) => {
              Column()
                .layoutWeight(1)
                .height(DATA_ROW_HEIGHT)
                // 格线用 classroomGrid（半透明黑）：压在绿格 / 红格上都看得清。
                // 第 5 / 10 节之后拉粗线（上下午分界），见 MAJOR_BOUNDARIES。
                .border({
                  width: {
                    right: isMajorBoundary(index + 1) ? GRID_LINE_MAJOR : GRID_LINE,
                    bottom: GRID_LINE
                  },
                  color: AppColor.classroomGrid
                })
                // 空闲 = 薄荷绿，**非空闲 = 浅红**（原本透明，看不出哪些节次被占）
                .backgroundColor(this.isFree(room, index + 1) ?
                  AppColor.classroomFree : AppColor.classroomBusy)
            }, (label: string, index: number) => room.id + '-' + index.toString())
          }
          .width('100%')
          .onClick(() => {
            Toast.show(room.name + ' · 空闲：' + this.freeSections(room.kxsds));
          })
        }, (room: ClassroomInfo) => room.id)
      }
      .width('100%')
      // 表格向卡片左右两侧各外扩到距边 8vp（负外边距抵消 SectionCard 的 16vp 内边距），
      // **左右对称**：14 个节次列因此拿到更多宽度，格子更清楚。
      .margin({
        left: TABLE_SIDE_INSET - AppSize.cardPadding,
        right: TABLE_SIDE_INSET - AppSize.cardPadding
      })
    }
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        this.campusRow()
        this.queryCard()
        this.helpCard()

        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在查询空闲教室…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.query();
            }
          })
        } else if (this.shownBuildings().length === 0) {
          EmptyView({ message: '该日期暂无空闲教室数据' })
        } else {
          ForEach(this.shownBuildings(), (building: string) => {
            this.buildingTable(building)
          }, (building: string) => building)
        }

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。留白必须写在滚动内容里、
        // 而不是 DestShell 外壳上：视口仍从屏幕顶开始，内容才能滑进标题栏 + 状态栏
        // 那一段毛玻璃底板（DestShell 用 backdropBlur 补的那层）。
        top: AppSize.destTopInset(topSafeInsetVp()),
        // 底部为悬浮底栏留白。必须留在滚动内容里，不能留给 destination ——
        // 否则底栏背后永远是一块实心底板，毛玻璃透不出内容，看着就是「黑遮罩」。
        bottom: AppSize.contentBottomInset
      })
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    // clip(false) 允许内容画到布局矩形之外，expandSafeArea() 让绘制区延伸进
    // 标题栏声明的组件安全区 —— 缺了它们标题栏的渐变模糊就没东西可糊。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }
}
