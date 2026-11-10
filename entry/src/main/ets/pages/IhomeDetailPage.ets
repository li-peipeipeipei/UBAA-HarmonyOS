import { LoadState } from '../common/AppRouter';
import { IhomeNav } from '../common/IhomeNav';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { ErrorView, LoadingView } from '../components/CommonViews';
import {
  IhomeAppeal,
  IhomeEvaluation,
  IhomeHistory,
  IhomeReaction,
  IhomeReactionResult,
  IhomeReply
} from '../model/ApiTypes';

/**
 * iHome 诉求详情。
 *
 * 关注 / 支持是**写操作**，但上游是「切换」接口：这里按目标状态提交（见
 * LocalIhomeService.setReaction），并且**结果不明时不重发** —— 重发会反向切回去。
 * 写失败只提示、不自动重试；用户回到列表或重新打开详情会看到真实状态。
 */
@Component
export struct IhomeDetailPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private appeal: IhomeAppeal | null = null;
  @State private supportEnabled: boolean = false;
  @State private supportLabel: string = '支持';
  /** 正在提交的写操作；空串表示空闲。 */
  @State private pending: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      this.appeal = await ApiService.fetchIhomeDetail(IhomeNav.id, IhomeNav.mine);
      try {
        const config = await ApiService.fetchIhomeConfig();
        this.supportEnabled = config.supportEnabled;
        this.supportLabel = config.supportLabel;
      } catch (error) {
        Logger.warn('iHome 配置加载失败：' + (error as Error).message);
      }
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '诉求详情加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('iHome 详情加载失败：' + (error as Error).message);
    }
  }

  private async react(reaction: IhomeReaction): Promise<void> {
    const appeal = this.appeal;
    if (appeal === null || this.pending.length > 0) {
      return;
    }
    const current = reaction === IhomeReaction.FOLLOW ? appeal.isFollowed : appeal.isSupported;
    if (current === undefined) {
      Toast.show('无法确认当前状态，请刷新后重试');
      return;
    }
    this.pending = reaction;
    try {
      const result: IhomeReactionResult =
        await ApiService.setIhomeReaction(appeal.id, reaction, !current);
      if (result.appeal !== undefined) {
        this.appeal = result.appeal;
      }
      Toast.show(result.confirmed
        ? (reaction === IhomeReaction.FOLLOW
          ? (current ? '已取消关注' : '已关注')
          : (current ? '已取消支持' : '已支持'))
        : result.message);
    } catch (error) {
      const message = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '操作失败，请刷新后重试';
      Toast.show(message);
    } finally {
      this.pending = '';
    }
  }

  private actionText(reaction: IhomeReaction): string {
    const appeal = this.appeal;
    if (appeal === null) {
      return '';
    }
    const active = reaction === IhomeReaction.FOLLOW ? appeal.isFollowed : appeal.isSupported;
    const count = reaction === IhomeReaction.FOLLOW ? appeal.followCount : appeal.supportCount;
    let label = reaction === IhomeReaction.FOLLOW
      ? (active === true ? '已关注' : '关注')
      : (active === true ? '已支持' : this.supportLabel);
    if (count !== undefined) {
      label += ' ' + count;
    }
    return label;
  }

  @Builder
  headerCard() {
    Column({ space: 8 }) {
      Row({ space: AppSize.gapSmall }) {
        Text(this.appeal === null ? '' : this.appeal.status)
          .fontSize(11)
          .fontColor(AppColor.brand)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .backgroundColor(AppColor.brandContainer)
        if (this.appeal !== null && this.appeal.category.length > 0) {
          Text(this.appeal.category)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
        Blank()
        Text(this.appeal === null ? '' : this.appeal.publishedAt)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')

      Text(this.appeal === null ? '' : this.appeal.content)
        .fontSize(AppFont.body)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .lineHeight(22)

      if (this.appeal !== null && this.appeal.departments.length > 0) {
        Text('受理部门：' + this.appeal.departments.join('、'))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .width('100%')
      }

      Row({ space: AppSize.gap }) {
        this.actionChip(IhomeReaction.FOLLOW)
        if (this.supportEnabled) {
          this.actionChip(IhomeReaction.SUPPORT)
        }
      }
      .width('100%')
      .padding({ top: 4 })
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  actionChip(reaction: IhomeReaction) {
    Row({ space: 4 }) {
      SymbolGlyph(this.isActive(reaction)
        ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.heart'))
        .fontSize(14)
        .fontColor([this.isActive(reaction) ? AppColor.brand : AppColor.textSecondary])
      Text(this.pending === reaction ? '提交中…' : this.actionText(reaction))
        .fontSize(AppFont.caption)
        .fontColor(this.isActive(reaction) ? AppColor.brand : AppColor.textSecondary)
    }
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .backgroundColor(AppColor.surfaceSubtle)
    .borderRadius(999)
    .onClick(() => {
      this.react(reaction);
    })
  }

  private isActive(reaction: IhomeReaction): boolean {
    if (this.appeal === null) {
      return false;
    }
    return reaction === IhomeReaction.FOLLOW
      ? this.appeal.isFollowed === true : this.appeal.isSupported === true;
  }

  @Builder
  repliesCard() {
    Column({ space: 8 }) {
      Text('官方回复')
        .fontSize(AppFont.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      if (this.appeal !== null && this.appeal.replies.length > 0) {
        ForEach(this.appeal.replies, (item: IhomeReply, index: number) => {
          Column({ space: 4 }) {
            Row({ space: AppSize.gapSmall }) {
              Text(item.department.length > 0 ? item.department : '相关部门')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.brand)
              Text(item.createdAt)
                .fontSize(11)
                .fontColor(AppColor.textTertiary)
            }
            .width('100%')

            Text(item.content)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textPrimary)
              .width('100%')
              .lineHeight(21)
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
          .alignItems(HorizontalAlign.Start)
        }, (item: IhomeReply, index: number) => item.createdAt + '-' + index.toString())
      } else {
        Text('暂无回复')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
      }
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  historyCard() {
    if (this.appeal !== null && this.appeal.history.length > 0) {
      Column({ space: 8 }) {
        Text('处理进度')
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .width('100%')

        ForEach(this.appeal.history, (item: IhomeHistory, index: number) => {
          Row({ space: AppSize.gap }) {
            Column() {
              Text('')
                .width(8)
                .height(8)
                .borderRadius(4)
                .backgroundColor(index === 0 ? AppColor.brand : AppColor.textTertiary)
            }
            .width(12)

            Column({ space: 2 }) {
              Text(item.content)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textPrimary)
                .width('100%')
              Text(item.createdAt)
                .fontSize(10)
                .fontColor(AppColor.textTertiary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (item: IhomeHistory, index: number) => item.createdAt + '-' + index.toString())
      }
      .width('100%')
      .padding(AppSize.cardPadding)
      .borderRadius(AppSize.cardRadius)
      .backgroundColor(AppColor.surface)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  evaluationCard() {
    if (this.appeal !== null && this.appeal.evaluations.length > 0) {
      Column({ space: 8 }) {
        Text('评价')
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .width('100%')

        ForEach(this.appeal.evaluations, (item: IhomeEvaluation, index: number) => {
          Column({ space: 4 }) {
            Row({ space: AppSize.gapSmall }) {
              Text(item.department.length > 0 ? item.department : '相关部门')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
              Text('速度 ' + item.speed + ' · 满意度 ' + item.satisfaction +
                ' · 解决程度 ' + item.degree)
                .fontSize(11)
                .fontColor(AppColor.textTertiary)
            }
            .width('100%')

            if (item.content.length > 0) {
              Text(item.content)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textPrimary)
                .width('100%')
            }
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
          .alignItems(HorizontalAlign.Start)
        }, (item: IhomeEvaluation, index: number) => item.id.toString() + '-' + index.toString())
      }
      .width('100%')
      .padding(AppSize.cardPadding)
      .borderRadius(AppSize.cardRadius)
      .backgroundColor(AppColor.surface)
      .alignItems(HorizontalAlign.Start)
    }
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在加载诉求详情…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          this.headerCard()
          this.historyCard()
          this.repliesCard()
          this.evaluationCard()
        }

        Blank()
          .height(AppSize.contentBottomInset)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
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
