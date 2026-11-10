import { LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import {
  BykcLibBookArea,
  BykcLibBookLibrary,
  BykcLibBookSeat,
  BykcLibBookStorey
} from '../model/ApiTypes';
import { LibBookSlot, LocalLibBookService } from '../network/LocalLibBookService';

/**
 * 图书馆座位 · 预约座位（对齐原版 `LibBookReserveScreen.kt`）。
 *
 * 版式：**楼馆 / 楼层 / 分区** 三行横向 chip（各自带「剩余/总数」），
 * 下面是座位网格（每行 4 个），底部是预约信息 + 「确认预约」按钮。
 *
 * ## 加载链（照抄原版，是 5 步不是 4 步）
 *
 * ```
 * loadLibraries          楼馆（楼层嵌在楼馆的 storeys 里，不用单独请求）
 *   → loadAreas          分区（按楼馆 + 楼层 + 日期）
 *     → loadAreaDetail   分区详情（一次性带回可预约日期 + 时段）
 *       → loadSeats      座位（必须带 day + 时段的起止时间）
 * ```
 *
 * **自动选中策略**贯穿全程：优先保留用户已有选择（若在新数据里仍存在），
 * 否则取列表第一个。日期与时段**不给用户选**，自动取上游数组第一个
 * （与原版一致 —— 原版的 `selectSlot` 是死代码，UI 从不调用）。
 */
@Component
export struct LibBookReservePage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private libraries: BykcLibBookLibrary[] = [];
  @State private areas: BykcLibBookArea[] = [];
  @State private seats: BykcLibBookSeat[] = [];
  @State private slots: LibBookSlot[] = [];
  @State private selectedLibraryId: string = '';
  @State private selectedStoreyId: string = '';
  @State private selectedAreaId: string = '';
  @State private selectedSeatId: string = '';
  @State private selectedDay: string = '';
  @State private areasLoading: boolean = false;
  @State private seatsLoading: boolean = false;
  @State private submitting: boolean = false;
  @State private showAllSeats: boolean = false;

  aboutToAppear(): void {
    this.selectedDay = LocalLibBookService.today();
    this.loadLibraries();
  }

  /* ------------------------------ 数据加载 ------------------------------ */

  private async loadLibraries(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      const list = await LocalLibBookService.fetchLibraries(this.selectedDay);
      this.libraries = list;
      // 自动选楼馆
      let libId: string = this.selectedLibraryId;
      let found: boolean = false;
      for (let i = 0; i < list.length; i++) {
        if (list[i].id === libId) {
          found = true;
          break;
        }
      }
      if (!found) {
        libId = list.length > 0 ? list[0].id : '';
        this.selectedLibraryId = libId;
      }
      // 自动选楼层（楼层嵌在楼馆里）
      let storeyId: string = this.selectedStoreyId;
      let storeyFound: boolean = false;
      for (let i = 0; i < list.length; i++) {
        if (list[i].id !== libId) {
          continue;
        }
        for (let j = 0; j < list[i].storeys.length; j++) {
          if (list[i].storeys[j].id === storeyId) {
            storeyFound = true;
            break;
          }
        }
        if (!storeyFound && list[i].storeys.length > 0) {
          storeyId = list[i].storeys[0].id;
          this.selectedStoreyId = storeyId;
        }
        break;
      }
      this.loadState = LoadState.SUCCESS;
      if (libId.length > 0) {
        this.loadAreas();
      }
    } catch (error) {
      this.errorMessage = '加载楼馆失败：' + (error as Error).message;
      this.loadState = LoadState.ERROR;
      Logger.error('图书馆楼馆加载失败：' + (error as Error).message);
    }
  }

  private async loadAreas(): Promise<void> {
    this.areasLoading = true;
    this.areas = [];
    this.seats = [];
    this.selectedAreaId = '';
    this.selectedSeatId = '';
    try {
      const list = await LocalLibBookService.fetchAreas(
        this.selectedLibraryId, this.selectedStoreyId, this.selectedDay);
      this.areas = list;
      if (list.length > 0) {
        this.selectedAreaId = list[0].id;
        this.loadAreaDetailAndSeats();
      }
    } catch (error) {
      Logger.warn('图书馆分区加载失败：' + (error as Error).message);
    } finally {
      this.areasLoading = false;
    }
  }

  private async loadAreaDetailAndSeats(): Promise<void> {
    this.seatsLoading = true;
    this.seats = [];
    this.slots = [];
    this.selectedSeatId = '';
    try {
      const detail = await LocalLibBookService.fetchAreaDetail(this.selectedAreaId);
      // 自动取第一个可预约日期
      if (detail.dates.length > 0) {
        this.selectedDay = detail.dates[0];
      }
      this.slots = detail.slots;
      if (detail.slots.length === 0) {
        this.seatsLoading = false;
        return;
      }
      await this.loadSeats();
    } catch (error) {
      Logger.warn('图书馆分区详情加载失败：' + (error as Error).message);
    } finally {
      this.seatsLoading = false;
    }
  }

  private async loadSeats(): Promise<void> {
    if (this.slots.length === 0) {
      return;
    }
    this.seatsLoading = true;
    try {
      const slot = this.slots[0];
      const list = await LocalLibBookService.fetchSeats(
        this.selectedAreaId, this.selectedDay, slot.start, slot.end);
      this.seats = list;
    } catch (error) {
      Logger.warn('图书馆座位加载失败：' + (error as Error).message);
    } finally {
      this.seatsLoading = false;
    }
  }

  /* ------------------------------ 选择动作 ------------------------------ */

  private selectLibrary(id: string): void {
    if (this.selectedLibraryId === id) {
      return;
    }
    this.selectedLibraryId = id;
    // 楼层重置
    for (let i = 0; i < this.libraries.length; i++) {
      if (this.libraries[i].id === id && this.libraries[i].storeys.length > 0) {
        this.selectedStoreyId = this.libraries[i].storeys[0].id;
        break;
      }
    }
    this.loadAreas();
  }

  private selectStorey(id: string): void {
    if (this.selectedStoreyId === id) {
      return;
    }
    this.selectedStoreyId = id;
    this.loadAreas();
  }

  private selectArea(id: string): void {
    if (this.selectedAreaId === id) {
      return;
    }
    this.selectedAreaId = id;
    this.loadAreaDetailAndSeats();
  }

  private selectSeat(seat: BykcLibBookSeat): void {
    if (!seat.isAvailable) {
      Toast.show('该座位当前不可预约');
      return;
    }
    // 再点一次同一个座位 = 取消选择
    this.selectedSeatId = this.selectedSeatId === seat.id ? '' : seat.id;
  }

  /* ------------------------------ 写操作 ------------------------------ */

  private async submitReservation(): Promise<void> {
    if (this.submitting) {
      return;
    }
    if (this.selectedAreaId.length === 0) {
      Toast.show('请先选择分区');
      return;
    }
    if (this.selectedSeatId.length === 0) {
      Toast.show('请先选择可预约座位');
      return;
    }
    if (this.slots.length === 0) {
      Toast.show('请先选择预约时段');
      return;
    }
    this.submitting = true;
    try {
      const message: string = await LocalLibBookService.reserve(
        this.selectedAreaId, this.selectedSeatId, this.selectedDay, this.slots[0]);
      Toast.show(message);
      this.selectedSeatId = '';
      // 预约成功后刷新座位与记录
      await this.loadSeats();
    } catch (error) {
      Toast.show('预约失败：' + (error as Error).message);
      Logger.warn('图书馆预约失败：' + (error as Error).message);
    } finally {
      this.submitting = false;
    }
  }

  /* ------------------------------ 派生数据 ------------------------------ */

  private currentLibrary(): BykcLibBookLibrary | null {
    for (let i = 0; i < this.libraries.length; i++) {
      if (this.libraries[i].id === this.selectedLibraryId) {
        return this.libraries[i];
      }
    }
    return null;
  }

  private currentStoreys(): BykcLibBookStorey[] {
    const lib = this.currentLibrary();
    return lib === null ? [] : lib.storeys;
  }

  private currentArea(): BykcLibBookArea | null {
    for (let i = 0; i < this.areas.length; i++) {
      if (this.areas[i].id === this.selectedAreaId) {
        return this.areas[i];
      }
    }
    return null;
  }

  private currentSeat(): BykcLibBookSeat | null {
    for (let i = 0; i < this.seats.length; i++) {
      if (this.seats[i].id === this.selectedSeatId) {
        return this.seats[i];
      }
    }
    return null;
  }

  /** 可预约的座位（网格只显示这些 —— 与原版 `visibleLibBookSeats` 一致）。 */
  private visibleSeats(): BykcLibBookSeat[] {
    if (this.showAllSeats) {
      return this.seats;
    }
    const out: BykcLibBookSeat[] = [];
    for (let i = 0; i < this.seats.length; i++) {
      if (this.seats[i].isAvailable) {
        out.push(this.seats[i]);
      }
    }
    return out;
  }

  /* ------------------------------ 界面 ------------------------------ */

  /**
   * 一行横向 chip（楼馆 / 楼层 / 分区三处用同一套外观）。
   *
   * ⚠️ **拆成三个专用 Builder 而不用泛型** —— ArkUI 的 `@Builder` **不支持泛型参数**
   * （`<T>` 会在运行期炸掉，表现为进页面直接白屏/闪退）。
   * 三处 chip 的元素类型不同（楼馆 / 楼层 / 分区），只能各写一份。
   *
   * ⚠️ **横滑能生效，关键是内容 Row 不能设 `.width('100%')`**。
   * 先后踩过：
   *   - `Row.width('100%')` → 内容被压成容器宽，**没有溢出量就没得滑**（滑不动）；
   *   - `List` + `listDirection(Axis.Horizontal)` → `List` 嵌在 `Scroll` 里
   *     **直接白屏崩溃**（进程消失，且没有 JS 日志）。
   * 正解参照 `ScheduleWeekChips`（课表页周次条）：`Scroll` +
   * `.scrollable(ScrollDirection.Horizontal)`，内容 `Row` **只设 padding 不设宽度**。
   */
  @Builder
  libraryChips() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.libraries, (item: BykcLibBookLibrary) => {
          Text(item.name + ' ' + item.freeNum.toString() + '/' + item.totalNum.toString())
            .fontSize(AppFont.caption)
            .fontColor(item.id === this.selectedLibraryId ? AppColor.brand : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(item.id === this.selectedLibraryId ?
              AppColor.brandContainer : AppColor.surfaceSubtle)
            .maxLines(1)
            .onClick(() => {
              this.selectLibrary(item.id);
            })
        }, (item: BykcLibBookLibrary) => item.id)
      }
      // ⚠️ **内容 Row 绝不能设 `.width('100%')`** —— 那会把内容压成容器宽，
      // 没有溢出量就没有可滚区域。参照 `ScheduleWeekChips`（课表周次条）的写法。
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .height(38)
  }

  @Builder
  storeyChips() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.currentStoreys(), (item: BykcLibBookStorey) => {
          Text(item.name + ' ' + item.freeNum.toString() + '/' + item.totalNum.toString())
            .fontSize(AppFont.caption)
            .fontColor(item.id === this.selectedStoreyId ? AppColor.brand : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(item.id === this.selectedStoreyId ?
              AppColor.brandContainer : AppColor.surfaceSubtle)
            .maxLines(1)
            .onClick(() => {
              this.selectStorey(item.id);
            })
        }, (item: BykcLibBookStorey) => item.id)
      }
      // 内容 Row 不设 width('100%')（否则压成容器宽，没得滑）—— 见 libraryChips 注释
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .height(38)
  }

  @Builder
  areaChips() {
    Scroll() {
      Row({ space: 6 }) {
        ForEach(this.areas, (item: BykcLibBookArea) => {
          Text(item.name + ' ' + item.freeNum.toString() + '/' + item.totalNum.toString())
            .fontSize(AppFont.caption)
            .fontColor(item.id === this.selectedAreaId ? AppColor.brand : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(16)
            .backgroundColor(item.id === this.selectedAreaId ?
              AppColor.brandContainer : AppColor.surfaceSubtle)
            .maxLines(1)
            .onClick(() => {
              this.selectArea(item.id);
            })
        }, (item: BykcLibBookArea) => item.id)
      }
      // 内容 Row 不设 width('100%')（否则压成容器宽，没得滑）—— 见 libraryChips 注释
    }
    .scrollBar(BarState.Off)
    .scrollable(ScrollDirection.Horizontal)
    .width('100%')
    .height(38)
  }

  @Builder
  sectionTitle(title: string, trailing?: string) {
    Row() {
      Text(title)
        .fontSize(AppFont.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .layoutWeight(1)
      if (trailing !== undefined) {
        Text(trailing)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.brand)
          .onClick(() => {
            this.loadLibraries();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  seatCard(seat: BykcLibBookSeat) {
    Column({ space: 4 }) {
      Text(seat.no.length > 0 ? seat.no : (seat.name.length > 0 ? seat.name : seat.id))
        .fontSize(AppFont.caption)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
      Text(this.selectedSeatId === seat.id ? '已选' : (seat.isAvailable ? '可预约' : '不可预约'))
        .fontSize(10)
        .fontColor(this.selectedSeatId === seat.id ? AppColor.brand : AppColor.textTertiary)
        .maxLines(1)
    }
    .width('100%')
    .height(64)
    .padding(8)
    .borderRadius(8)
    .backgroundColor(this.selectedSeatId === seat.id ? AppColor.brandContainer : AppColor.surfaceSubtle)
    .onClick(() => {
      this.selectSeat(seat);
    })
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapSmall }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在加载图书馆楼馆…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.loadLibraries();
            }
          })
        } else {
          // 楼馆
          this.sectionTitle('楼馆', '刷新')
          this.libraryChips()

          // 楼层（仅当选中的楼馆有楼层时才显示）
          if (this.currentStoreys().length > 0) {
            this.sectionTitle('楼层')
            this.storeyChips()
          }

          // 分区
          this.sectionTitle('分区')
          if (this.areasLoading) {
            Text('正在加载分区…')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          } else if (this.areas.length === 0) {
            Text('当前楼层暂无可预约分区')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          } else {
            this.areaChips()
          }

          // 座位
          Row() {
            Text('座位')
              .fontSize(AppFont.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
              .layoutWeight(1)
            Text(this.showAllSeats ? '只看可预约' : '看全部座位')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.brand)
              .onClick(() => {
                this.showAllSeats = !this.showAllSeats;
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.seatsLoading) {
            Text('正在加载座位…')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          } else if (this.seats.length === 0) {
            Text('当前分区暂无座位数据')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          } else if (this.visibleSeats().length === 0) {
            Text('当前分区暂无可预约座位')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          } else {
            // 座位网格：每行 4 个（与原版一致）
            //
            // ⚠️ **必须用 `Grid` 而不是 `Flex` + `layoutWeight`** ——
            // `layoutWeight` 只在 `Row`/`Column` 里生效，`Flex` 里设了也没用
            // （实测每行只排下一个座位，卡片被拉成整行宽）。
            Grid() {
              ForEach(this.visibleSeats(), (seat: BykcLibBookSeat) => {
                GridItem() {
                  this.seatCard(seat)
                }
              }, (seat: BykcLibBookSeat) => seat.id)
            }
            .columnsTemplate('1fr 1fr 1fr 1fr')
            .columnsGap(8)
            .rowsGap(8)
            .width('100%')
          }

          // 预约信息
          Column({ space: 6 }) {
            Text('预约信息')
              .fontSize(AppFont.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
            Text('日期：' + (this.selectedDay.length > 0 ? this.selectedDay : '-'))
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('分区：' + (this.currentArea() === null ? '-' : this.currentArea()?.name ?? '-'))
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('座位：' + this.seatText())
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            if (this.slots.length > 0) {
              Text('时段：' + this.slots[0].start + ' - ' + this.slots[0].end)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .width('100%')
            }
          }
          .width('100%')
          .padding(AppSize.cardPadding)
          .borderRadius(AppSize.cardRadius)
          .backgroundColor(AppColor.surface)
          .alignItems(HorizontalAlign.Start)

          Button(this.submitting ? '提交中…' : '确认预约')
            .width('100%')
            .height(44)
            .fontSize(AppFont.body)
            .fontColor(AppColor.textOnBrand)
            .backgroundColor(AppColor.brand)
            .enabled(!this.submitting && this.selectedSeatId.length > 0)
            .onClick(() => {
              this.submitReservation();
            })
        }

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: AppSize.contentBottomInset
      })
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }

  private seatText(): string {
    const seat = this.currentSeat();
    if (seat === null) {
      return '-';
    }
    return seat.no.length > 0 ? seat.no : seat.name;
  }
}
