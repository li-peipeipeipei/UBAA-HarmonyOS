import { AppRouter, RouteName } from '../common/AppRouter';
import { AppConfig, connectionModeName } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiService } from '../network/ApiService';
import { TokenStore } from '../network/TokenStore';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { SectionCard } from '../components/CommonViews';

/**
 * 「我的」页。
 *
 * 上半部分为身份卡片（品牌渐变 + 沉浸底色），下半部分为功能列表。
 */
@Component
export struct MinePage {
  stack: NavPathStack = new NavPathStack();

  @State private userName: string = '';
  @State private schoolId: string = '';
  @State private loggingOut: boolean = false;

  onLogout: () => void = () => {};

  aboutToAppear(): void {
    const session = TokenStore.getSession();
    this.userName = session.userName.length > 0 ? session.userName : '未设置姓名';
    this.schoolId = session.schoolId.length > 0 ? session.schoolId : session.username;
  }

  @Builder
  profileCard() {
    Row({ space: AppSize.gapLarge }) {
      Column() {
        Text(this.userName.substring(0, 1))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .backgroundColor('#33000000')
      .justifyContent(FlexAlign.Center)

      Column({ space: 4 }) {
        Text(this.userName)
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('学号 ' + this.schoolId)
          .fontSize(AppFont.caption)
          .fontColor('#D9ECFF')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadiusLarge)
    .linearGradient({
      angle: 135,
      colors: [
        [AppColor.brand, 0.0],
        [AppColor.brandDark, 1.0]
      ]
    })
  }

  @Builder
  menuRow(title: string, subtitle: string, symbol: Resource, onClick: () => void) {
    Row({ space: AppSize.gap }) {
      Column() {
        SymbolGlyph(symbol)
          .fontSize(20)
          .fontColor([Color.White])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(AppColor.brand)
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(title)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
        Text(subtitle)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([AppColor.textTertiary])
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .onClick(() => {
      onClick();
    })
  }

  private async doLogout(): Promise<void> {
    if (this.loggingOut) {
      return;
    }
    this.loggingOut = true;
    try {
      await ApiService.logout();
      Toast.show('已退出登录');
      this.clearLocalData();
      this.onLogout();
    } catch (error) {
      Logger.warn('注销异常：' + (error as Error).message);
      this.clearLocalData();
      this.onLogout();
    } finally {
      this.loggingOut = false;
    }
  }

  /**
   * 退出登录时**不再清课表缓存**。
   *
   * 缓存里已经记了它属于哪个账号（学号 + 登录名）。同一个账号重新登录时直接复用，
   * 打开课表零等待；换成别的账号登录，SchedulePage.restoreFromCache 会发现账号
   * 对不上并整体清空，隐私同样有保障 —— 不需要在退出时“宁可错杀”。
   */
  private clearLocalData(): void {
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        this.profileCard()

        SectionCard({ title: '账户', subtitle: '学籍与连接配置' }) {
          Column() {
            this.menuRow('个人资料', '查看学籍信息与联系方式', $r('sys.symbol.person'), () => {
              AppRouter.push(this.stack, RouteName.USER_INFO);
            })
            Divider().color(AppColor.divider).strokeWidth(0.5)
            this.menuRow('连接设置', '当前：' + connectionModeName(TokenStore.getConnectionMode()),
              $r('sys.symbol.wifi'), () => {
                AppRouter.push(this.stack, RouteName.SETTINGS);
              })
          }
          .width('100%')
        }

        SectionCard({ title: '关于', subtitle: '版本与开源信息' }) {
          Column() {
            this.menuRow('关于 UBAA', '版本 ' + AppConfig.APP_VERSION, $r('sys.symbol.info_circle'), () => {
              AppRouter.push(this.stack, RouteName.ABOUT);
            })
          }
          .width('100%')
        }

        Button('退出登录')
          .width('100%')
          .height(48)
          .fontSize(AppFont.subtitle)
          .fontColor(AppColor.danger)
          .backgroundColor(AppColor.surface)
          .onClick(() => {
            this.doLogout();
          })

        Blank()
          .height(AppSize.contentBottomInset)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。状态栏那一段的模糊由
        // PageShell 的磨砂层补上，视口必须从屏幕顶开始（见 MainPage.PageShell）；
        // 留白只能写在这里，写到外壳上会把视口压低、内容就滑不进磨砂层了。
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
      })
      .constraintSize({ minHeight: '100%' })
      // 一级页内容整体上移一点（纯视觉位移，见 AppSize.contentTopLift）
      .translate({ y: -AppSize.contentTopLift })
    }
    .scrollBar(BarState.Off)
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    //   clip(false)      —— 允许内容画到自身布局矩形之外；
    //   expandSafeArea() —— 绘制区延伸进标题栏声明的组件安全区。
    // 缺了这两个，内容上滑时不会从标题栏底下钻进去，渐变模糊「没东西可糊」。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    // 顶部留白不写在 Scroll 上 —— ArkUI 会把 Scroll 的 padding 当 contentInset，
    // 把滚动内容整体上移（实测反而顶到时钟上）；留白写在滚动内容的内边距里。
    .backgroundColor(AppColor.pageBackground)
  }
}
