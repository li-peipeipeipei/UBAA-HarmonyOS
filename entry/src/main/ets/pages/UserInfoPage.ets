import { LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { TokenStore } from '../network/TokenStore';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { ErrorView, InfoRow, LoadingView, SectionCard } from '../components/CommonViews';
import { UserInfo } from '../model/ApiTypes';

/**
 * 个人资料。
 *
 * 字段直接映射服务端 /api/v1/user/info 的返回结构。
 */
@Component
export struct UserInfoPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private info: UserInfo = {};

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      this.info = await ApiService.fetchUserInfo();
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '个人信息加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('个人信息加载失败：' + (error as Error).message);
    }
  }

  private value(text: string | undefined): string {
    return text !== undefined && text.length > 0 ? text : '—';
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取学籍信息…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          SectionCard({ title: '基本信息', showAction: false }) {
            Column() {
              InfoRow({ label: '姓名', value: this.value(this.info.name) })
              InfoRow({ label: '学号', value: this.value(this.info.schoolid) })
              InfoRow({ label: '用户名', value: this.value(this.info.username) })
              InfoRow({ label: '证件类型', value: this.value(this.info.idCardTypeName), showDivider: false })
            }
            .width('100%')
          }

          SectionCard({ title: '联系方式', showAction: false }) {
            Column() {
              InfoRow({ label: '手机号', value: this.value(this.info.phone) })
              InfoRow({ label: '邮箱', value: this.value(this.info.email), showDivider: false })
            }
            .width('100%')
          }

          Text('信息来源于学校统一身份认证，如需修改请前往学校门户。')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .width('100%')
            .padding({ left: 4, right: 4 })
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
