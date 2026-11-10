import { LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { BykcLibBookBooking } from '../model/ApiTypes';
import {
  LIBBOOK_BOOKING_CANCEL_KEYWORDS,
  LIBBOOK_BOOKING_UNCANCELLABLE,
  LocalLibBookService
} from '../network/LocalLibBookService';

/**
 * 图书馆座位 · 我的座位预约（对齐原版 `LibBookBookingsScreen.kt`）。
 *
 * 列表项：标题（分区/座位）+ 右侧状态 + 日期时间段 + 座位号 + 取消按钮。
 *
 * ## 取消预约的判定（原版 `canCancelBooking`）
 *
 * 不可取消的情况：
 * - `status` 是 `6`（用户取消）或 `8`（已结束）；
 * - `statusName` 含「取消 / 结束 / 已完成 / 过期 / 失效」。
 *
 * 不可取消时**整个按钮不渲染**（不是置灰）。
 */
@Component
export struct LibBookBookingsPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private bookings: BykcLibBookBooking[] = [];
  @State private cancelingId: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      this.bookings = await LocalLibBookService.fetchBookings(1, 50);
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = '加载预约记录失败：' + (error as Error).message;
      this.loadState = LoadState.ERROR;
      Logger.error('图书馆预约记录加载失败：' + (error as Error).message);
    }
  }

  /** 这条记录能不能取消。 */
  private canCancel(booking: BykcLibBookBooking): boolean {
    if (booking.id.length === 0) {
      return false;
    }
    if (LIBBOOK_BOOKING_UNCANCELLABLE.indexOf(booking.status.trim()) >= 0) {
      return false;
    }
    for (let i = 0; i < LIBBOOK_BOOKING_CANCEL_KEYWORDS.length; i++) {
      if (booking.statusName.indexOf(LIBBOOK_BOOKING_CANCEL_KEYWORDS[i]) >= 0) {
        return false;
      }
    }
    return true;
  }

  private async cancel(booking: BykcLibBookBooking): Promise<void> {
    if (this.cancelingId.length > 0) {
      return;
    }
    if (!this.canCancel(booking)) {
      Toast.show('该预约已结束或已取消，无需取消');
      return;
    }
    this.cancelingId = booking.id;
    try {
      const message: string = await LocalLibBookService.cancelBooking(booking.id);
      Toast.show(message);
      await this.load();
    } catch (error) {
      Toast.show('取消预约失败：' + (error as Error).message);
      Logger.warn('图书馆取消预约失败：' + (error as Error).message);
    } finally {
      this.cancelingId = '';
    }
  }

  /** 标题：nameMerge → 「分区 / 座位」→ 兜底。 */
  private titleOf(booking: BykcLibBookBooking): string {
    if (booking.nameMerge.length > 0) {
      return booking.nameMerge;
    }
    const parts: string[] = [];
    if (booking.areaName.length > 0) {
      parts.push(booking.areaName);
    }
    if (booking.seatNo.length > 0) {
      parts.push(booking.seatNo);
    }
    return parts.length > 0 ? parts.join(' / ') : '图书馆座位';
  }

  /** 状态：statusName → status → 兜底「已预约」。 */
  private statusOf(booking: BykcLibBookBooking): string {
    if (booking.statusName.length > 0) {
      return booking.statusName;
    }
    if (booking.status.length > 0) {
      return booking.status;
    }
    return '已预约';
  }

  /** 时间行：`日期 起~止`（空字段剔除）。 */
  private timeOf(booking: BykcLibBookBooking): string {
    const parts: string[] = [];
    if (booking.day.length > 0) {
      parts.push(booking.day);
    }
    const times: string[] = [];
    if (booking.beginTime.length > 0) {
      times.push(booking.beginTime);
    }
    if (booking.endTime.length > 0) {
      times.push(booking.endTime);
    }
    if (times.length > 0) {
      parts.push(times.join('~'));
    }
    return parts.join(' ');
  }

  @Builder
  bookingCard(booking: BykcLibBookBooking) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(this.titleOf(booking))
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.statusOf(booking))
          .fontSize(AppFont.caption)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.brand)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.timeOf(booking).length > 0) {
        Text(this.timeOf(booking))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .width('100%')
          .maxLines(2)
      }

      if (booking.seatNo.length > 0) {
        Text('座位：' + booking.seatNo)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .width('100%')
      }

      if (this.canCancel(booking)) {
        Button(this.cancelingId === booking.id ? '取消中…' : '取消预约')
          .height(30)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.danger)
          .backgroundColor(AppColor.surfaceSubtle)
          .enabled(this.cancelingId.length === 0)
          .onClick(() => {
            this.cancel(booking);
          })
      }
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取预约记录…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          // 标题行（原文案「预约记录」）
          Row() {
            Text('预约记录')
              .fontSize(AppFont.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
              .layoutWeight(1)
            Text('刷新')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.brand)
              .onClick(() => {
                this.load();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          if (this.bookings.length === 0) {
            EmptyView({ message: '当前暂无图书馆座位预约' })
          } else {
            ForEach(this.bookings, (booking: BykcLibBookBooking) => {
              this.bookingCard(booking)
            }, (booking: BykcLibBookBooking) => booking.id)
          }
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
}
