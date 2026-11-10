import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { GlobalContext } from '../common/GlobalContext';
import curves from '@ohos.curves';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { LocalSpocService } from '../network/LocalSpocService';
import { AppColor, AppFont, AppMaterial, AppSize } from '../components/AppTheme';
import { MaterialCardLayer } from '../components/MaterialCardLayer';
import { immersiveMaterialActive } from '../common/SystemMaterial';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { SpocAssignment, SpocAssignmentDetail } from '../model/ApiTypes';

function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

/** 当前时间，格式与接口归一化后的时间一致，便于直接做字符串比较。 */
function nowText(): string {
  const date = new Date();
  return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) +
    ' ' + pad2(date.getHours()) + ':' + pad2(date.getMinutes()) + ':' + pad2(date.getSeconds());
}

/** SPOC 网页首页 —— 提交作业的兜底入口用它。 */
const SPOC_WEB_HOME: string = 'https://spoc.buaa.edu.cn/spocnewht/';

/** 空详情（避免用 null，省掉 @Builder 里的空判断）。 */
function emptyDetail(): SpocAssignmentDetail {  return {
    assignmentId: '',
    courseName: '',
    title: '',
    submissionStatusText: '',
    submitted: false
  };
}

/**
 * SPOC 作业页。
 *
 * 数据链路：`/spocnewht/cas` 跳转链取 token → `casLogin` 换 roleCode →
 * 当前学期 → 课程（补教师名）→ 作业分页列表；点条目再拉详情与提交记录。
 * 全部逻辑在 `LocalSpocService`（照抄原 UBAA 的 spoc 模块）。
 */
/** 作业详情里的一行。 */
interface SpocRow {
  label: string;
  value: string;
}

/** 作业详情弹窗：尺寸/设计/动画与课程详情弹窗完全一致的 @CustomDialog。 */
@CustomDialog
struct SpocDetailDialog {
  controller?: CustomDialogController;
  course: string = '';
  title: string = '';
  statusText: string = '';
  submitted: boolean = false;
  rows: SpocRow[] = [];
  contentText: string = '';
  onWeb: () => void = () => {
  };
  private readonly materialActive: boolean = immersiveMaterialActive();

  build() {
    Stack() {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      }

      Column() {
        Row() {
          Text('作业详情')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
            .maxLines(1)

          Stack() {
            if (this.materialActive) {
              MaterialCardLayer({ layerRadius: 20, layerShadow: false })
            } else {
              Column()
                .width('100%')
                .height('100%')
                .borderRadius(20)
                .backgroundColor(AppColor.circleButtonSurface)
            }
            Button({ type: ButtonType.Normal, stateEffect: false }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(24)
                .fontColor([AppColor.textPrimary])
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
            })
          }
          .width(40)
          .height(40)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        Divider()
          .color(AppColor.divider)
          .strokeWidth(0.5)

        Scroll() {
          Column() {
            if (this.course.length > 0) {
              Text(this.course)
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .width('100%')
            }
            Row({ space: 8 }) {
              Text(this.title)
                .fontSize(AppFont.subtitle)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.statusText)
                .fontSize(11)
                .fontColor(this.submitted ? AppColor.success : AppColor.warning)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(6)
                .backgroundColor(AppColor.surfaceSubtle)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: 4, bottom: 12 })

            Column() {
              ForEach(this.rows, (item: SpocRow) => {
                Row() {
                  Text(item.label)
                    .fontSize(AppFont.body)
                    .fontColor(AppColor.textSecondary)
                    .width(72)
                  Text(item.value.length > 0 ? item.value : '—')
                    .fontSize(AppFont.body)
                    .fontColor(AppColor.textPrimary)
                    .layoutWeight(1)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .alignItems(VerticalAlign.Top)
                .padding({ top: 7, bottom: 7 })
              }, (item: SpocRow) => item.label)
            }
            .width('100%')
            .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding, top: 6, bottom: 6 })
            .borderRadius(AppSize.cardRadius)
            .backgroundColor(AppColor.surface)

            if (this.contentText.length > 0) {
              Text('作业要求')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
                .width('100%')
                .margin({ top: 14, bottom: 6 })
              Text(this.contentText)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textSecondary)
                .width('100%')
                .padding(AppSize.cardPadding)
                .borderRadius(AppSize.cardRadius)
                .backgroundColor(AppColor.surface)
            }
          }
          .width('100%')
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .constraintSize({ maxHeight: 380 })
        .margin({ top: 4 })

        Stack() {
          if (this.materialActive) {
            MaterialCardLayer({ layerRadius: 22, layerShadow: false })
          }
          Button('去网页提交')
            .width('100%')
            .height(44)
            .fontSize(AppFont.subtitle)
            .fontColor(AppColor.textOnBrand)
            .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
            .onClick(() => {
              this.onWeb();
              if (this.controller !== undefined) {
                this.controller.close();
              }
            })
        }
        .width('100%')
        .height(44)
        .borderRadius(22)
        .margin({ top: 16 })
      }
      .width('100%')
      .padding(AppSize.cardPadding + 4)
      .alignItems(HorizontalAlign.Start)
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .borderRadius(AppSize.cardRadiusLarge)
    .backgroundColor(this.materialActive ? Color.Transparent : AppColor.glassSurface)
    .backdropBlur(this.materialActive ? 0 : AppMaterial.blurLarge)
  }
}

@Component
export struct SpocPage {
  stack: NavPathStack = new NavPathStack();

  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private termName: string = '';
  @State private assignments: SpocAssignment[] = [];

  /* 详情半模态 */
  @State private detailVisible: boolean = false;
  /** 作业详情弹窗控制器（CustomDialog，与课程详情同一套动画）。 */
  private spocDialogController: CustomDialogController | null = null;
  /* 站内网页提交（WebView：先登录页拿会话，再跳作业详情） */
  @State private showWeb: boolean = false;
  @State private webLoginUrl: string = '';
  @State private webDetailUrl: string = '';
  private webCtrl: webview.WebviewController = new webview.WebviewController();
  private webLoadedLogin: boolean = false;
  @State private detailLoading: boolean = false;
  @State private detail: SpocAssignmentDetail = emptyDetail();
  /** 被点开的作业所属课程名。详情接口不返回课程名，从列表项带过来。 */
  @State private detailCourse: string = '';
  /** 宽屏分支（键名与 common/Breakpoint.ets 的 KEY_IS_WIDE_SCREEN 一致）。 */
  @StorageProp('isWideScreen') private isWide: boolean = false;

  /**
   * 沉浸材质是否可用（API ≥ 26、应用级没被 DISABLE、材质构造成功）。
   *
   * 半模态面板和弹窗卡片的处境完全一样：**面板本身挂 `systemMaterial` 不生效**，
   * 材质必须由面板内的一层「按钮 / 选择类」承载层去画（见 components/MaterialCardLayer）。
   * 不可用时走「面板自带背景模糊 + 半透明底」的兜底。
   */
  private readonly materialActive: boolean = immersiveMaterialActive();

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      const data = await ApiService.fetchSpocAssignments();
      this.termName = data.termName;
      this.assignments = data.assignments;
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : 'SPOC 作业加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('SPOC 作业加载失败：' + (error as Error).message);
    }
  }

  private async openDetail(item: SpocAssignment): Promise<void> {
    try {
      const d: SpocAssignmentDetail = await ApiService.fetchSpocAssignmentDetail(item.assignmentId);
      const rows: SpocRow[] = [
        { label: '开始', value: d.startTime === undefined ? '' : d.startTime },
        { label: '截止', value: d.dueTime === undefined ? '' : d.dueTime },
        { label: '提交', value: d.submittedAt === undefined ? '' : d.submittedAt },
        { label: '得分', value: d.score === undefined ? '' : d.score }
      ];
      this.spocDialogController = new CustomDialogController({
        builder: SpocDetailDialog({
          course: item.courseName,
          title: d.title,
          statusText: d.submissionStatusText,
          submitted: d.submitted,
          rows: rows,
          contentText: d.contentText === undefined ? '' : d.contentText,
          onWeb: () => {
            this.openSpocWeb(item.assignmentId);
          }
        }),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        customStyle: true
      });
      if (this.spocDialogController !== null) {
        this.spocDialogController.open();
      }
    } catch (error) {
      const message = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '作业详情加载失败';
      Toast.show(message);
      Logger.error('SPOC 作业详情失败：' + (error as Error).message);
    }
  }

  /** 截止时间文案。 */
  private dueText(item: SpocAssignment): string {
    return item.dueTime === undefined || item.dueTime.length === 0 ?
      '截止 —' : '截止 ' + item.dueTime;
  }

  /** 是否已过截止时间。 */
  private isOverdue(item: SpocAssignment): boolean {
    return item.dueTime !== undefined && item.dueTime.length > 0 && item.dueTime < nowText();
  }

  /** 列表项。 */
  @Builder
  assignmentItem(item: SpocAssignment) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(item.courseName)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.submissionStatusText)
          .fontSize(11)
          .fontColor(item.submitted ? AppColor.success : AppColor.warning)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor(AppColor.surfaceSubtle)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(item.title.length > 0 ? item.title : '未命名作业')
        .fontSize(AppFont.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 12 }) {
        Text(this.dueText(item))
          .fontSize(AppFont.caption)
          .fontColor(this.isOverdue(item) ? AppColor.danger : AppColor.textTertiary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.fullScore !== undefined && item.fullScore.length > 0) {
          Text('满分 ' + item.fullScore)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .border({ width: { left: 3 }, color: this.isOverdue(item) ? AppColor.danger : AppColor.surface })
    .onClick(() => {
      this.openDetail(item);
    })
  }

  /** 打开 SPOC 网页（优先直达该作业详情）。 */
  private async openSpocWeb(assignmentId: string): Promise<void> {
    try {
      const loginUrl: string = await LocalSpocService.webLoginUrl();
      const detailUrl: string = assignmentId.length > 0 ?
        await LocalSpocService.assignmentWebUrl(assignmentId) : '';
      AppStorage.setOrCreate('spocWebLogin', loginUrl);
      AppStorage.setOrCreate('spocWebDetail', detailUrl);
      AppStorage.setOrCreate('spocWebOpen', true);
    } catch (error) {
      Logger.warn('准备 SPOC 网页失败：' + (error as Error).message);
      Toast.show('打开 SPOC 网页失败，请稍后重试');
    }
  }

  /* ------------------------------ 详情 ------------------------------ */

  @Builder
  detailRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .width(56)
      Text(value.length > 0 ? value : '—')
        .fontSize(AppFont.body)
        .fontColor(AppColor.textPrimary)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 5, bottom: 5 })
  }

  /** 状态徽标：与列表项同一个观感，省掉信息卡里那一行「状态」。 */
  @Builder
  statusBadge() {
    Text(this.detail.submissionStatusText)
      .fontSize(11)
      .fontColor(this.detail.submitted ? AppColor.success : AppColor.warning)
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .borderRadius(6)
      .backgroundColor(AppColor.surfaceSubtle)
  }

  /**
   * 半模态自绘头部：标题 + 右上角关闭按钮（×）。
   *
   * ## 排版对齐课表页「选择学期」面板的原生标题行
   *
   * 课表页的学期选择面板用 `bindSheet` 原生 `title` + `showClose`，由系统排版。真机实测
   * 其几何（本机 1316×2832、密度 3.5）：面板顶边 y=1362px，
   *   - 标题「选择学期」左缘 x=56px（16vp），文字竖向中心 y≈1487px（约面板顶下 36vp）；
   *   - 关闭按钮（× 圆形按钮）圆心 x≈1190px（距右边 36vp），圆心 y≈1488px（同为 36vp）。
   * 即：**标题左缘 16vp、标题与关闭按钮同一水平中线（距面板顶 36vp）、关闭按钮右缘 16vp
   * （40vp 圆 → 圆心距右 36vp）**，左右内缩对称。本头部按这四个数排，观感与原生标题行一致。
   *
   * ## 为什么不用原生 title / showClose
   *
   * 那两个由系统画在**面板 chrome 区**（内容区之上、面板底板之内）。沉浸材质要求面板底板
   * 透明，一旦透明，chrome 区就没有底板了 —— 标题和关闭按钮会「浮」在面板框外面。
   * 自己画进面板内容里，两者才落在材质上；这里只把**排版**照抄原生行。
   *
   * 本头部是 detailSheet 外层 Stack 的顶层兄弟（全宽），靠 Row 的左右内边距对齐，
   * 不用绝对定位 —— 实测 `markAnchor` 在这条链上不生效、`.align()` 只对组件内部内容
   * 生效而非在父 Stack 里定位，两者都会把按钮摆到面板中间（踩过）。
   */
  @Builder
  sheetHeader() {
    Row() {
      Text('作业详情')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 40vp 圆按钮：右缘内缩 16vp（左右内缩对称）。
      //
      // 规格与**二级页左上角的原生返回按钮**完全一致（真机实测：`Button` 盒 40×40vp、
      // 图标 24vp、圆底是「淡一层的叠加色」`AppColor.circleButtonSurface`，**没有模糊**）。
      // ⚠️ 别给圆底加 `backdropBlur`：加了就变成一团「只有模糊、看不出底板」的糊斑
      //    （用户反馈「目前仅有模糊」）。返回按钮的底板就是干净的一层半透明色。
      // 两个半模态的关闭按钮必须逐字一致，否则沉浸观感不统一。
      Button({ type: ButtonType.Normal, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(24)
          .fontColor([AppColor.textPrimary])
      }
      .width(40)
      .height(40)
      .borderRadius(20)
      .backgroundColor(AppColor.circleButtonSurface)
      .onClick(() => {
        animateTo({ curve: curves.responsiveSpringMotion(0.32, 0.88) }, () => {
          animateTo({ curve: curves.responsiveSpringMotion(0.32, 0.88) }, () => {
          this.detailVisible = false;
        });
        });
      })
    }
    .width('100%')
    // 行高 64vp，顶部再让 8vp → 内容盒 8~64vp（56vp 高、与原生标题行同高），
    // 竖向居中后标题与按钮的中心线落在面板顶下 36vp
    .height(64)
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 8 })
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.SpaceBetween)
  }

  /**
   * 详情半模态面板。
   *
   * 分两层：底层是 `MaterialCardLayer`（Toggle 承载的沉浸材质），上面才是内容。
   * **面板自己不挂材质** —— 普通容器在内容区挂 `systemMaterial` 是静默不渲染的
   * （详见 `common/SystemMaterial.ets` 的文件头）。
   *
   * 高度用 `SheetSize.FIT_CONTENT`（贴合内容），所以：
   *   - 内容列**不再写 `height('100%')`**，让内容自己撑出面板高度，承载层靠
   *     `LayoutPolicy.matchParent` 跟随实测尺寸铺满，不会「下半截没东西可糊」；
   *   - 也不再需要给悬浮底栏留 `contentBottomInset` —— 半模态下面没有底栏，
   *     留那么高会在面板底部空出一大块（之前的观感就是这么塌下来的）。
   *
   * 排版节奏：头部 → 16 → （课程 / 作业名 + 状态徽标）→ 12 → 信息卡 → 16 →
   * 「作业要求」标签 → 8 → 正文卡。段间距写在各块的 `margin` 上，比统一 `space` 更清楚。
   *
   * 圆角：外壳与承载层都是**上圆下方**（半模态从底部升起，下两角贴屏幕边缘要切平）。
   * 由承载层自己画成这个形状，**不要**再用外层 `clip(true)` 去裁 —— 那个 clip 会把材质
   * 自带的边缘高光在圆角处切断，拐角上留下一条断掉的亮边（真机反馈的「圆角处边缘光效
   * 有问题」）。外壳仍写同样的 borderRadius，是为了材质不可用的兜底分支也对得上。
   */
  @Builder
  detailSheet() {
    // alignContent 必须显式置 Top：Stack 默认是 Center，而本头部（64vp）是内容列之外的
    // 兄弟节点 —— 居中会让它跑到面板正中间、压在信息卡上（真机踩过）。
    Stack({ alignContent: Alignment.Top }) {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      }

      // 正文包一层 Scroll：上/下划时**正文弹性回弹**（`EdgeEffect.Spring` + `alwaysEnabled`
      // —— 正文没超出可视区时也照样回弹），而面板本身（承载层 + 面板框）钉在原位不动。
      // 这样「回弹」只发生在内容层，面板始终盖住屏幕底部，**底部遮罩完整、不会露出下面的
      // 页面或悬浮底栏**；单一档位 detents 也保证系统不会把面板拖离屏幕下沿。
      //
      // ⚠️ 自绘头部（标题 + 关闭按钮）留在 Scroll **外面**，作为外层 Stack 的兄弟节点 ——
      //    它固定在面板顶部不跟着正文滚 / 回弹；正文顶部留白（padding.top: 64）为它让位。
      Scroll() {
      Column() {
        if (this.detailLoading) {
          Column() {
            LoadingView({ message: '正在加载作业详情…' })
          }
          .width('100%')
          .margin({ top: 24 })
        } else {
          // 课程名（小声）+ 作业名（主体）+ 状态徽标 —— 层级与列表项保持一致
          Column({ space: 4 }) {
            Text(this.detailCourse.length > 0 ? this.detailCourse : 'SPOC 课程')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Row({ space: 8 }) {
              Text(this.detail.title)
                .fontSize(AppFont.subtitle)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              this.statusBadge()
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 16, bottom: 12 })

          // 时间与得分（状态已在上面的徽标里，不再重复一行）
          Column() {
            this.detailRow('开始', this.detail.startTime === undefined ? '' : this.detail.startTime)
            this.detailRow('截止', this.detail.dueTime === undefined ? '' : this.detail.dueTime)
            this.detailRow('提交', this.detail.submittedAt === undefined ? '' : this.detail.submittedAt)
            this.detailRow('得分', this.detail.score === undefined ? '' : this.detail.score)
          }
          .width('100%')
          .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding, top: 10, bottom: 10 })
          .borderRadius(AppSize.cardRadius)
          .backgroundColor(AppColor.surface)

          if (this.detail.contentText !== undefined && this.detail.contentText.length > 0) {
            Text('作业要求')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .width('100%')
              .margin({ top: 16, bottom: 8 })

            // 正文直接铺在面板内容里，**不再套一层内部 Scroll**。
            //
            // 原先这里是 `Scroll(){...}.constraintSize({maxHeight:240})`：正文短于 240vp 时
            // 它没有可滚动区间，却仍会把手势「吃掉」不往上冒泡 —— 真机反馈的正是
            // 「手指碰到这块滑动无响应，其他位置都正常」。去掉它，整块面板只剩系统给半模态
            // 内容包的那一层滚动上下文，滑动行为处处一致；正文长时由整块面板滚动承载。
            Column() {
              Text(this.detail.contentText)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textSecondary)
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding(AppSize.cardPadding)
            .borderRadius(AppSize.cardRadius)
            .backgroundColor(AppColor.surface)

            // 提交作业的**兜底入口**。
            //
            // 为什么只能兜底：上游仓库里**没有**提交作业的写接口（只有列表与详情），
            // 要接真提交得先抓包确认端点与 multipart 字段。所以这里给一条能走通的路 ——
            // 跳系统浏览器打开 SPOC，登录后在网页里提交。
            Button('去网页提交')
              .width('100%')
              .height(44)
              .fontSize(AppFont.body)
              .fontColor(AppColor.brand)
              .backgroundColor(AppColor.surfaceSubtle)
              .margin({ top: 16 })
              .onClick(() => {
                this.openSpocWeb(this.detail.assignmentId);
              })

          }
        }
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 头部已提为本 Stack 的顶层兄弟（见 sheetHeader），坐标直达面板边缘；
        // 内容列从头部下沿（64vp，对齐「选择学期」原生标题行下方）开始
        top: 64,
        bottom: 20
      })
      .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: 460 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

      // 头部固定在面板顶部：Scroll 的兄弟节点，不随正文滚动 / 回弹一起动
      this.sheetHeader()
    }
    .width('100%')
    .borderRadius(AppSize.cardRadiusLarge)
    // 材质之下必须透明（底色会垫在材质之下叠出灰感）；材质不可用时给兜底半透明玻璃底
    .backgroundColor(this.materialActive ? Color.Transparent : AppColor.glassSurface)
  }

  /* ------------------------------ 主体 ------------------------------ */

  /** 作业详情浮层：居中卡片，尺寸对齐课程详情弹窗。 */
  @Builder
  detailOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .hitTestBehavior(HitTestMode.Block)

      Column() {
        this.detailSheet()
      }
      .width('86%')
      .constraintSize({ maxWidth: 400 })
      .borderRadius(AppSize.cardRadiusLarge)
      .clip(true)
      // 手机端向上补偿到视觉正中；宽屏 Split 右栏标题栏几何不同，不补偿
      .offset({ y: this.isWide ? 0 : -40 })
      .transition(
        TransitionEffect.OPACITY
          .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }))
          .animation({ curve: curves.responsiveSpringMotion(0.32, 0.88) })
      )
    }
    .width('100%')
    .height('100%')
  }

  /** 站内网页提交：先加载带 token 的登录页建立会话，再跳到该作业详情。 */
  @Builder
  webOverlay() {
    Column() {
      Row() {
        Text('网页提交')
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
        Blank()
        Button('关闭')
          .height(32)
          .fontSize(AppFont.body)
          .fontColor(AppColor.brand)
          .backgroundColor(AppColor.brandContainer)
          .onClick(() => {
            this.showWeb = false;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
      .alignItems(VerticalAlign.Center)

      Web({ src: this.webLoginUrl, controller: this.webCtrl })
        .width('100%')
        .layoutWeight(1)
        // SPA 需要本地存储来保存登录会话；不开 domStorage 会出现页面残缺/登录态丢失
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .mixedMode(MixedMode.All)
        .metaViewport(true)
        .zoomAccess(false)
    }
    .width('100%')
    .height('100%')
    // 底部让开悬浮底栏（4 个页签），网页内容停在按钮上方
    .padding({ bottom: AppSize.contentBottomInset })
    .backgroundColor(AppColor.pageBackground)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取 SPOC 作业…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else if (this.assignments.length === 0) {
          EmptyView({ message: '当前学期没有 SPOC 作业' })
        } else {
          if (this.termName.length > 0) {
            Text(this.termName + ' · 共 ' + this.assignments.length.toString() + ' 次作业')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .width('100%')
          }
          ForEach(this.assignments, (item: SpocAssignment) => {
            this.assignmentItem(item)
          }, (item: SpocAssignment) => item.assignmentId + item.title)
        }

        Blank()
          .height(AppSize.contentBottomInset)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部不用再避让「状态栏 + 标题栏」—— HDS 的组件安全区已整块扣掉
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
      })
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感三件套（配合 HDS 标题栏的 enableComponentSafeArea）
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
    }
    .width('100%')
    .height('100%')
  }
}
