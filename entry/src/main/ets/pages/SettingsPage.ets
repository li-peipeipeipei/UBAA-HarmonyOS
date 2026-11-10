import { AppConfig, ConnectionMode, ConnectionModeMeta, DEFAULT_CONNECTION_MODE, allConnectionModes, connectionModeName } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiService } from '../network/ApiService';
import { DiagnosticResult, NetworkDiagnostics } from '../network/NetworkDiagnostics';
import { TokenStore } from '../network/TokenStore';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { SectionCard, InfoRow } from '../components/CommonViews';

/**
 * 设置页。
 *
 * 只暴露真正会影响请求链路的项：认证入口（只读）、连接诊断、连接模式、
 * 演示模式、版本检查、缓存清理。
 *
 * 「服务地址」与「WebVPN 地址助手」已移除：服务端下线后客户端直连校内上游，
 * 没有需要用户填写的地址；WebVPN 的入口固定是网关域名（d.buaa.edu.cn），
 * 具体资源地址由客户端按统一算法现算（见 LocalWebVpn）。
 */
@Component
export struct SettingsPage {
  @State private mode: ConnectionMode = DEFAULT_CONNECTION_MODE;
  @State private checking: boolean = false;
  @State private diagnosing: boolean = false;
  @State private diagnoseHeadline: string = '';
  @State private diagnoseDetail: string = '';
  @State private diagnoseOk: boolean = false;
  @State private demoMode: boolean = false;
  @State private loggedIn: boolean = false;

  aboutToAppear(): void {
    this.mode = TokenStore.getConnectionMode();
    this.demoMode = TokenStore.getDemoMode();
    this.loggedIn = TokenStore.hasLocalSession();
  }

  private async runDiagnostics(): Promise<void> {
    if (this.diagnosing) {
      return;
    }
    this.diagnosing = true;
    this.diagnoseHeadline = '正在检测…';
    this.diagnoseDetail = '';
    try {
      const result: DiagnosticResult = await NetworkDiagnostics.probe(this.mode);
      this.diagnoseOk = result.reachable;
      this.diagnoseHeadline = result.headline;
      this.diagnoseDetail = result.detail;
    } catch (error) {
      this.diagnoseOk = false;
      this.diagnoseHeadline = '检测失败';
      this.diagnoseDetail = (error as Error).message;
    } finally {
      this.diagnosing = false;
    }
  }

  private async checkVersion(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      const raw: string = await ApiService.checkVersion();
      Toast.show('已是最新版本（' + AppConfig.APP_VERSION + '）');
      Logger.info('版本检查返回：' + raw.substring(0, 200));
    } catch (error) {
      Toast.show('版本检查失败：' + (error as Error).message);
    } finally {
      this.checking = false;
    }
  }

  @Builder
  modeRow(item: ConnectionModeMeta, last: boolean) {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text(item.displayName)
            .fontSize(AppFont.body)
            .fontColor(AppColor.textPrimary)
          Text(item.description)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (item.mode === this.mode) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(18)
            .fontColor([AppColor.brand])
        }
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        if (item.mode === this.mode) {
          return;
        }
        this.mode = item.mode;
        TokenStore.setConnectionMode(item.mode);
        // 换模式 = 换上游域名，上一次的诊断结论已经不适用了
        this.diagnoseHeadline = '';
        this.diagnoseDetail = '';
        this.loggedIn = TokenStore.hasLocalSession(item.mode);
      })

      if (!last) {
        Divider().color(AppColor.divider).strokeWidth(0.5)
      }
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        SectionCard({
          title: '认证入口 · ' + connectionModeName(this.mode),
          subtitle: '客户端直连学校系统，登录态保存在本机',
          showAction: false
        }) {
          Column({ space: AppSize.gapSmall }) {
            InfoRow({
              label: '统一身份认证',
              value: AppConfig.authEntryDisplay(this.mode),
              showDivider: true
            })
            InfoRow({
              label: '会话校验',
              value: AppConfig.sessionCheckDisplay(this.mode),
              showDivider: true
            })
            InfoRow({
              label: '当前会话',
              value: this.loggedIn ? '已登录' : '未登录',
              showDivider: false
            })

            Text(this.mode === ConnectionMode.WEBVPN
              ? 'WebVPN 模式下所有校内地址都会加密后经 d.buaa.edu.cn 转发，校外可用。'
              : '校内直连要求设备处在校园网内（或已连接校园 VPN）；校外请切到 WebVPN 模式。')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          }
          .width('100%')
        }

        SectionCard({ title: '连接诊断', subtitle: '探测统一认证入口与会话状态，区分「不在校园网 / 上游故障 / 未登录」' }) {
          Column({ space: AppSize.gapSmall }) {
            Row({ space: AppSize.gapSmall }) {
              Button(this.diagnosing ? '检测中…' : '开始检测')
                .fontSize(AppFont.body)
                .height(36)
                .backgroundColor(AppColor.brand)
                .fontColor(Color.White)
                .type(ButtonType.Capsule)
                .enabled(!this.diagnosing)
                .onClick(() => {
                  this.runDiagnostics();
                })
            }
            .width('100%')

            if (this.diagnoseHeadline.length > 0) {
              Text(this.diagnoseHeadline)
                .fontSize(AppFont.body)
                .fontColor(this.diagnoseOk ? AppColor.brand : AppColor.warning)
                .width('100%')
            }

            if (this.diagnoseDetail.length > 0) {
              Text(this.diagnoseDetail)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .width('100%')
                .lineHeight(20)
            }
          }
          .width('100%')
        }

        SectionCard({ title: '连接模式', subtitle: '影响网关选择，切换后需重新登录', showAction: false }) {
          Column() {
            ForEach(allConnectionModes(), (item: ConnectionModeMeta, index: number) => {
              this.modeRow(item, index === allConnectionModes().length - 1)
            }, (item: ConnectionModeMeta) => item.mode)
          }
          .width('100%')
        }

        SectionCard({ title: '演示模式', subtitle: '服务端不可用时，用本地示例数据把界面跑通' }) {
          Column({ space: AppSize.gapSmall }) {
            Row() {
              Column({ space: 2 }) {
                Text('启用演示数据')
                  .fontSize(AppFont.body)
                  .fontColor(AppColor.textPrimary)
                Text('开启后所有接口调用返回本地示例，不发起任何网络请求')
                  .fontSize(AppFont.caption)
                  .fontColor(AppColor.textTertiary)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Toggle({ type: ToggleType.Switch, isOn: this.demoMode })
                .selectedColor(AppColor.brand)
                .onChange((isOn: boolean) => {
                  this.demoMode = isOn;
                  TokenStore.setDemoMode(isOn);
                  Toast.show(isOn ? '演示模式已开启' : '演示模式已关闭');
                })
            }
            .width('100%')

            if (this.demoMode) {
              Text('提示：演示模式下任意学号 + 密码均可登录，用于界面验收；' +
                '真实联调前请关闭本开关。')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.warning)
                .width('100%')
            }
          }
          .width('100%')
        }

        SectionCard({ title: '其他', showAction: false }) {
          Column() {
            Row() {
              Text('检查更新')
                .fontSize(AppFont.body)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(1)
              Text('当前 ' + AppConfig.APP_VERSION)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.checkVersion();
            })

            Divider().color(AppColor.divider).strokeWidth(0.5)

            Row() {
              Text('清除本地缓存')
                .fontSize(AppFont.body)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(1)
              Text('保留登录态')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              TokenStore.setSelectedWeek(0);
              TokenStore.setSelectedTerm('', '');
              Toast.show('课表偏好已重置');
            })
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
    // clip(false) 允许内容画到布局矩形之外，expandSafeArea() 让绘制区延伸进
    // 标题栏声明的组件安全区 —— 缺了它们标题栏的渐变模糊就没东西可糊。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }
}
