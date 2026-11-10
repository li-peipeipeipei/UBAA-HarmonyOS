import { LoadState } from '../common/AppRouter';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { SigninClass } from '../model/ApiTypes';

/**
 * 课堂签到（iclass 一体化课堂）。
 *
 * 数据来自校内上游：登录后用 SSO 跳转链换一次 iclass 会话，再取「今日课堂 +
 * 签到状态」。签到提交是不可撤销的真实动作，只由用户点击触发，不自动补签。
 *
 * 交互刻意做得「一屏一件事」：列表本身就是操作面板，未签到的课右侧直接给按钮，
 * 已签到的显示状态，不额外套一层详情页 —— 上课前那几十秒不该用来点三次。
 */
@Component
export struct SigninPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private classes: SigninClass[] = [];
  /** 正在提交签到的课程 id；空串表示当前没有进行中的签到。 */
  @State private pendingCourseId: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      this.classes = await ApiService.fetchSigninClasses();
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '签到课堂加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('签到课堂加载失败：' + (error as Error).message);
    }
  }

  /**
   * 提交一次签到。
   *
   * 用 `pendingCourseId` 做互斥：签到本身有网络往返，期间再次点击会重复提交，
   * 而上游对重复提交只会回「已签到」，界面看着像成功、实际白跑一趟。
   */
  private async doSignin(item: SigninClass): Promise<void> {
    if (this.pendingCourseId.length > 0) {
      return;
    }
    this.pendingCourseId = item.courseId;
    try {
      const result = await ApiService.performSignin(item.courseId);
      Toast.show(result.message);
      if (result.success) {
        await this.load();
      }
    } catch (error) {
      const message = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '签到失败，请稍后重试';
      Toast.show(message);
      Logger.error('签到失败：' + (error as Error).message);
    } finally {
      this.pendingCourseId = '';
    }
  }

  private timeRange(item: SigninClass): string {
    if (item.classBeginTime.length === 0 && item.classEndTime.length === 0) {
      return '上课时间待定';
    }
    if (item.classEndTime.length === 0) {
      return item.classBeginTime;
    }
    return item.classBeginTime + ' - ' + item.classEndTime;
  }

  private signedCount(): number {
    let count = 0;
    for (let i = 0; i < this.classes.length; i++) {
      if (this.classes[i].signStatus === 1) {
        count++;
      }
    }
    return count;
  }

  @Builder
  summaryBar() {
    Row() {
      Column({ space: 2 }) {
        Text('今天 · ' + DateUtil.today())
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text(this.classes.length === 0
          ? '暂无可签到的课堂'
          : '共 ' + this.classes.length + ' 堂 · 已签 ' + this.signedCount() + ' 堂')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('刷新')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.brand)
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor(AppColor.brandContainer)
        .borderRadius(999)
        .onClick(() => {
          this.load();
        })
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  classCard(item: SigninClass) {
    Row({ space: AppSize.gap }) {
      Column({ space: 4 }) {
        Text(item.courseName)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.timeRange(item))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (item.signStatus === 1) {
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(14)
            .fontColor([AppColor.success])
          Text('已签到')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.success)
        }
      } else if (this.pendingCourseId === item.courseId) {
        // 提交中：占位尺寸与按钮接近，避免列表在结果回来时跳一下
        Row() {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(AppColor.brand)
        }
        .width(64)
        .height(32)
        .justifyContent(FlexAlign.Center)
      } else {
        Text('签到')
          .fontSize(AppFont.caption)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .width(64)
          .padding({ top: 8, bottom: 8 })
          .backgroundColor(AppColor.brand)
          .borderRadius(999)
          .onClick(() => {
            this.doSignin(item);
          })
      }
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        this.summaryBar()

        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取今日课堂…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else if (this.classes.length === 0) {
          EmptyView({ message: '今天没有需要签到的课堂' })
        } else {
          ForEach(this.classes, (item: SigninClass) => {
            this.classCard(item);
          }, (item: SigninClass) => item.courseId + '-' + item.signStatus)
        }

        Text('签到由任课教师开启窗口后有效；点击「签到」即向课堂系统提交，无法撤销。' +
          '若提示不在签到范围，请确认已连接校园网或已切到 WebVPN 模式。')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
          .padding({ left: 4, right: 4 })

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。留白必须写在滚动内容里、
        // 而不是外壳上：视口仍从屏幕顶开始，内容才能滑进标题栏那一段毛玻璃底板。
        top: AppSize.destTopInset(topSafeInsetVp()),
        // 底部为悬浮底栏留白，同样留在滚动内容里（见 RouteBuilder 的说明）。
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
