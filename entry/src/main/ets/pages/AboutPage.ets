import { AppConfig } from '../common/AppConfig';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { InfoRow, SectionCard } from '../components/CommonViews';

/**
 * 关于页。
 *
 * 展示版本、技术栈与后端契约，便于排查问题时快速对齐环境。
 */
@Component
export struct AboutPage {
  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        Column({ space: AppSize.gap }) {
          Image($r('app.media.app_icon'))
            .width(80)
            .height(80)
            .borderRadius(20)
            .draggable(false)
          Text('智慧北航')
            .fontSize(AppFont.titleLarge)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
          Text('UBAA · HarmonyOS 原生版')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
        .width('100%')
        .padding({ top: 24, bottom: 8 })

        SectionCard({ title: '版本信息', showAction: false }) {
          Column() {
            InfoRow({ label: '应用版本', value: AppConfig.APP_VERSION })
            InfoRow({ label: '目标 API', value: 'HarmonyOS 6.1.0(23)' })
            InfoRow({ label: 'UI 框架', value: 'ArkUI / ArkTS' })
            InfoRow({ label: '设计套件', value: 'UI Design Kit（HDS）', showDivider: false })
          }
          .width('100%')
        }

        SectionCard({ title: '运行模式', showAction: false }) {
          Column() {
            InfoRow({ label: '认证方式', value: '客户端本地统一认证（CAS）' })
            InfoRow({ label: '认证入口', value: AppConfig.UPSTREAM_SSO_HOST })
            InfoRow({ label: '会话校验', value: AppConfig.UPSTREAM_UC_HOST })
            InfoRow({ label: '教务数据源', value: AppConfig.UPSTREAM_BYXT_HOST, showDivider: false })
          }
          .width('100%')
        }

        SectionCard({ title: '已适配的鸿蒙特性', showAction: false }) {
          Column({ space: 6 }) {
            Text('· HdsTabs 悬浮底栏（barFloatingStyle + barOverlap）')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('· 沉浸光感材质（systemMaterialEffect = ADAPTIVE）')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('· HdsNavigation 标题栏渐变模糊（GRADIENT_BLUR）')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('· 全屏布局 + 状态栏 / 导航条安全区避让')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
            Text('· 深色模式（resources/dark 色板）')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textSecondary)
              .width('100%')
          }
          .width('100%')
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
    //   clip(false)       —— 允许内容画到自身布局矩形之外；
    //   expandSafeArea()  —— 绘制区延伸进标题栏声明的组件安全区。
    // 缺了这两个，内容永远停在标题栏下沿，标题栏的渐变模糊「没东西可糊」。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }
}
