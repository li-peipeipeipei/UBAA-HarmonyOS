import { AppRouter, LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { BykcCourseDetail } from '../model/ApiTypes';
import { BykcNav } from '../components/BykcNav';

/**
 * 博雅课程 · 课程详情（对齐原版 `BykcCourseDetailScreen.kt`）。
 *
 * 原版是**独立页面**，不是弹窗 —— 这里也做成独立页（由 `BykcPage` 的状态机切换）。
 *
 * 底部操作区与原版一致：
 * - **已选**：签到 / 签退 两个并排按钮（各自按可用性禁用）+ 一句说明
 *   「经纬度由系统在签到范围内随机生成」+ 退选按钮（整行）；
 * - **未选**：整行「选择课程」按钮（按状态禁用）+ 禁用原因说明。
 *
 * 已考核通过（`pass === 1`）时**不显示签到按钮**，改为一句「课程已考核完成，无需签到」。
 */
@Component
export struct BykcDetailPage {
  /** 页签的导航栈（操作完成后 pop 回列表）。 */
  stack: NavPathStack = new NavPathStack();

  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private detail: BykcCourseDetail | null = null;
  /** 有写操作在途：连点只发一次。 */
  @State private acting: boolean = false;

  aboutToAppear(): void {
    // 课程 id 来自共享模型（路由参数没法穿过 DestShell 传到子组件，见 BykcNav 注释）
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      this.detail = await ApiService.fetchBykcCourseDetail(BykcNav.shared.courseId);
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '课程详情加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('博雅课程详情加载失败：' + (error as Error).message);
    }
  }

  /**
   * 「选择课程」按钮是否可用。
   *
   * 只有「可选」且名额没满才能选 —— 与原版 `resolveBykcSelectButtonState` 一致。
   */
  private canSelect(): boolean {
    const d = this.detail;
    if (d === null) {
      return false;
    }
    if (d.course.selected) {
      return false;
    }
    if (d.course.status !== 'AVAILABLE') {
      return false;
    }
    const current: number = d.course.currentCount === undefined ? 0 : d.course.currentCount;
    return !(current > 0 && d.course.maxCount > 0 && current >= d.course.maxCount);
  }

  /** 选课按钮的禁用原因（没有就返回空串）。 */
  private selectDisabledReason(): string {
    const d = this.detail;
    if (d === null || d.course.selected) {
      return '';
    }
    if (d.course.status === 'EXPIRED') {
      return '课程已结束，不能再选';
    }
    if (d.course.status === 'ENDED') {
      return '选课已结束';
    }
    if (d.course.status === 'FULL') {
      return '人数已满';
    }
    if (d.course.status === 'PREVIEW') {
      return '选课尚未开始';
    }
    const current: number = d.course.currentCount === undefined ? 0 : d.course.currentCount;
    if (current > 0 && d.course.maxCount > 0 && current >= d.course.maxCount) {
      return '人数已满';
    }
    return '';
  }

  /** 签到 / 签退的禁用原因。 */
  private attendanceDisabledReason(): string {
    const d = this.detail;
    if (d === null) {
      return '';
    }
    if (d.pass === 1) {
      return '课程已考核完成，无需签到。';
    }
    if (!d.canSign && !d.canSignOut) {
      if (d.signWindow === undefined) {
        return '当前不在签到时间内。';
      }
      return '当前不在签到时间内（' + d.signWindow + '）。';
    }
    return '';
  }

  /* ------------------------------ 写操作 ------------------------------ */

  private showConfirm(title: string, message: string, confirmText: string,
    confirmColor: Resource, onConfirm: () => void): void {
    AlertDialog.show({
      title: title,
      message: message,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: confirmText,
        fontColor: confirmColor,
        action: onConfirm
      }
    });
  }

  private confirmChoose(): void {
    const d = this.detail;
    if (d === null) {
      return;
    }
    this.showConfirm('确认选课',
      '确定选「' + d.course.courseName + '」吗？选课后在退选截止前可以退选。',
      '选课', AppColor.brand, () => {
        this.runAction(() => ApiService.chooseBykcCourse(d.course.id));
      });
  }

  private confirmDrop(): void {
    const d = this.detail;
    if (d === null) {
      return;
    }
    this.showConfirm('确认退选',
      '确定退选「' + d.course.courseName + '」吗？' +
        (d.course.cancelEndDate === undefined ? '' : ('（退选截止 ' + d.course.cancelEndDate + '）')),
      '退选', AppColor.danger, () => {
        this.runAction(() => ApiService.dropBykcCourse(d.course.id));
      });
  }

  private confirmSign(signType: number): void {
    const d = this.detail;
    if (d === null) {
      return;
    }
    const isSignIn: boolean = signType === 1;
    this.showConfirm(isSignIn ? '确认签到' : '确认签退',
      '确定对「' + d.course.courseName + '」' + (isSignIn ? '签到' : '签退') + '吗？' +
        '（签到坐标会在课程签到点范围内自动生成）',
      isSignIn ? '签到' : '签退', AppColor.brand, () => {
        this.runAction(() => ApiService.signBykcCourse(d.course.id, signType));
      });
  }

  /** 跑一次写操作：互斥 + 结果提示 + 成功后重新拉详情。 */
  private async runAction(action: () => Promise<string>): Promise<void> {
    if (this.acting) {
      return;
    }
    this.acting = true;
    try {
      const message: string = await action();
      Toast.show(message);
      await this.load();
      AppRouter.back(this.stack);
    } catch (error) {
      Toast.show(error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '操作失败，请稍后重试');
      Logger.warn('博雅写操作失败：' + (error as Error).message);
    } finally {
      this.acting = false;
    }
  }

  /* ------------------------------ 展示 ------------------------------ */

  @Builder
  infoRow(label: string, value: string) {
    if (value.length > 0) {
      Row({ space: 2 }) {
        Text(label + ': ')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
        Text(value)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    }
  }

  @Builder
  tag(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(AppColor.textSecondary)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(4)
      .backgroundColor(AppColor.surfaceSubtle)
  }

  @Builder
  detailCard() {
    if (this.detail === null) {
      EmptyView({ message: '课程不存在或已下线' })
    } else {
      Column({ space: 10 }) {
        // 课程名 + 状态
        Row({ space: 8 }) {
          Text(this.detail?.course.courseName ?? '')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.detail?.course.selected ? '✓ 已选' : (this.detail?.course.statusText ?? ''))
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textOnBrand)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor(AppColor.brand)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        this.infoRow('任课教师', this.detail?.course.teacher ?? '')
        this.infoRow('上课地点', this.detail?.course.position ?? '')
        this.infoRow('上课时间', this.rangeText(this.detail?.course.startDate, this.detail?.course.endDate))
        this.infoRow('报名时间', this.rangeText(this.detail?.course.selectStartDate, this.detail?.course.selectEndDate))
        this.infoRow('退选截止', this.detail?.course.cancelEndDate ?? '')
        this.infoRow('名额', this.countText())
        this.infoRow('类别', this.categoryText())
        this.infoRow('受众', this.audienceText())
        this.infoRow('开课单位', this.detail?.organizer ?? '')
        this.infoRow('联系方式', this.contactText())
        this.infoRow('考勤', this.attendanceText())
        if ((this.detail?.signWindow ?? '').length > 0) {
          this.infoRow('签到窗口', this.detail?.signWindow ?? '')
        }

        // 分类标签
        if ((this.detail?.course.subCategory ?? '').length > 0) {
          Row({ space: 4 }) {
            this.tag(this.detail?.course.subCategory ?? '')
            if (this.detail?.course.hasSignPoints === true) {
              this.tag('自主签到')
            }
          }
          .width('100%')
        }

        // 课程简介
        if ((this.detail?.description ?? '').length > 0) {
          Divider()
            .color(AppColor.divider)
            .strokeWidth(0.5)
          Column({ space: 4 }) {
            Text('课程简介')
              .fontSize(AppFont.caption)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.textPrimary)
            Text(this.detail?.description ?? '')
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }
      .width('100%')
      .padding(16)
      .borderRadius(12)
      .backgroundColor(AppColor.surface)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  actionArea() {
    if (this.detail === null) {
    } else if (this.detail?.course.selected === true) {
      Column({ space: 8 }) {
        // 签到 / 签退（并排，各占一半）
        if (this.detail?.pass !== 1) {
          Row({ space: 12 }) {
            Button(this.acting ? '处理中…' : '签到')
              .layoutWeight(1)
              .height(40)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textOnBrand)
              .backgroundColor(AppColor.brand)
              .enabled(!this.acting && this.detail?.canSign === true)
              .onClick(() => {
                this.confirmSign(1);
              })
            Button(this.acting ? '处理中…' : '签退')
              .layoutWeight(1)
              .height(40)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textOnBrand)
              .backgroundColor(AppColor.brand)
              .enabled(!this.acting && this.detail?.canSignOut === true)
              .onClick(() => {
                this.confirmSign(2);
              })
          }
          .width('100%')

          Text('经纬度由系统在签到范围内随机生成，无需手动填写。')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
            .width('100%')

          if (this.attendanceDisabledReason().length > 0) {
            Text(this.attendanceDisabledReason())
              .fontSize(AppFont.caption)
              .fontColor(AppColor.danger)
              .width('100%')
          }
        } else {
          Text('课程已考核完成，无需签到。')
            .fontSize(AppFont.body)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.brand)
            .width('100%')
            .textAlign(TextAlign.Center)
        }

        // 退选（整行）
        Button(this.acting ? '处理中…' : '退选')
          .width('100%')
          .height(40)
          .fontSize(AppFont.body)
          .fontColor(AppColor.danger)
          .backgroundColor(AppColor.surfaceSubtle)
          .enabled(!this.acting && this.detail?.course.status !== 'EXPIRED')
          .onClick(() => {
            this.confirmDrop();
          })
      }
      .width('100%')
    } else {
      Column({ space: 8 }) {
        Button(this.acting ? '处理中…' : '选择课程')
          .width('100%')
          .height(40)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textOnBrand)
          .backgroundColor(AppColor.brand)
          .enabled(!this.acting && this.canSelect())
          .onClick(() => {
            this.confirmChoose();
          })
        if (this.selectDisabledReason().length > 0) {
          Text(this.selectDisabledReason())
            .fontSize(AppFont.caption)
            .fontColor(AppColor.danger)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
      }
      .width('100%')
    }
  }

  private countText(): string {
    const d = this.detail;
    if (d === null) {
      return '';
    }
    const current: number = d.course.currentCount === undefined ? 0 : d.course.currentCount;
    return current.toString() + ' / ' + d.course.maxCount.toString();
  }

  private categoryText(): string {
    const d = this.detail;
    if (d === null) {
      return '';
    }
    const main: string = d.course.category === undefined ? '' : d.course.category;
    const sub: string = d.course.subCategory === undefined ? '' : d.course.subCategory;
    if (main.length > 0 && sub.length > 0) {
      return main + ' / ' + sub;
    }
    return main.length > 0 ? main : sub;
  }

  /** 受众文案：校区 + 学院 / 年级 / 人群，去重后再拼。 */
  private audienceText(): string {
    const d = this.detail;
    if (d === null) {
      return '';
    }
    const parts: string[] = [];
    for (let i = 0; i < d.course.campuses.length; i++) {
      if (d.course.campuses[i].length > 0 && parts.indexOf(d.course.campuses[i]) < 0) {
        parts.push(d.course.campuses[i]);
      }
    }
    if (d.audiences !== undefined) {
      const items: string[] = d.audiences.split('、');
      for (let i = 0; i < items.length; i++) {
        const text: string = items[i].trim();
        if (text.length > 0 && parts.indexOf(text) < 0) {
          parts.push(text);
        }
      }
    }
    return parts.join('、');
  }

  private contactText(): string {
    const d = this.detail;
    if (d === null || d.contact === undefined) {
      return '';
    }
    return d.contactMobile === undefined ? d.contact : d.contact + ' ' + d.contactMobile;
  }

  private attendanceText(): string {
    const d = this.detail;
    if (d === null || !d.course.selected) {
      return '';
    }
    return (d.pass === 1 ? '已通过' : '未通过') + ' · 已签到 ' +
      (d.checkin === undefined ? 0 : d.checkin).toString() + ' 次';
  }

  private rangeText(start: string | undefined, end: string | undefined): string {
    const from: string = start === undefined ? '' : start;
    const to: string = end === undefined ? '' : end;
    if (from.length === 0 && to.length === 0) {
      return '';
    }
    if (from.length > 0 && to.length > 0) {
      return from + ' - ' + to;
    }
    return from.length > 0 ? from : to;
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取课程详情…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          this.detailCard()
          this.actionArea()
        }

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        top: 0,
        bottom: 0
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
