/**
 * 考试倒计时 · 桌面卡片（1×2）。
 *
 * ## 数据从哪来
 *
 * 卡片 UI 跑在系统 FRS 进程里，**与主应用内存隔离**。官方唯一的推数据通道是
 * `formProvider.updateForm(formId, FormBindingData)`，推过来的 key 会被注入
 * 本页的 `LocalStorage`，所以必须用 **`@LocalStorageProp` 接收**（不能用 @State，
 * 也不能用 getContext）。
 *
 * 官方还明确：「接收数据时，卡片数据会被转换成 string 类型」——
 * 所以 `examJson` 收到的是字符串，这里自己 `JSON.parse`。
 *
 * ## ⚠️ 本文件为什么这么「空」
 *
 * 1. **不能用 hilog** —— 编译器会直接报
 *    `'hilog' can't support form application`（SDK 给不支持卡片的 API 打了标记，
 *    构建期就拦）。所以这里连日志都没有，解析失败就静默显示空态。
 * 2. **不 import 项目的任何 .ets** —— 官方 FAQ：卡片的 FormExtensionAbility 不支持
 *    particleAbility / audio / camera / media / backgroundTaskManager，
 *    「强行加载得到的对象是 undefined，使用时就会产生 JS crash」。
 *    只用 ArkUI 内置组件+ `$r('app.color.*')` 资源（颜色随系统深浅色自动切换）。
 */

/** LocalStorage key（必须与 UBAAFormAbility 推送的字段名完全一致）。 */
const KEY_EXAM: string = 'examJson';
const KEY_EXAM_UPDATED: string = 'updatedAt';  // ⚠️ 模块级常量是**全局作用域**，不能与其他卡片同名

/** 考试卡片数据（与主应用 CardCache 的 CardExam 同形）。 */
interface ExamCardData {
  countdown: string;
  dateText: string;
  timeText: string;
  courseName: string;
  placeText: string;
  ready: boolean;
}

let examCardStorage: LocalStorage = new LocalStorage();

@Entry(examCardStorage)
@Component
struct ExamCard {
  @LocalStorageProp(KEY_EXAM) examJson: string = '';
  @LocalStorageProp(KEY_EXAM_UPDATED) updatedAt: string = '';

  @State private exam: ExamCardData | null = null;

  aboutToAppear(): void {
    this.parse();
  }

  private parse(): void {
    if (this.examJson.length === 0) {
      this.exam = null;
      return;
    }
    try {
      this.exam = JSON.parse(this.examJson) as ExamCardData;
    } catch (error) {
      this.exam = null;
    }
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        target: 'feature',
        page: 'exam'
      }
    });
  }

  /** 没缓存 / 没考试时的空态。 */
  @Builder
  emptyView() {
    Column({ space: 5 }) {
      Text('考试安排')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text(this.exam !== null ? '近期没有考试' : '打开 App 获取考试安排')
        .fontSize(11)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
      Text(this.updatedAt.length > 0 ? '更新于 ' + this.updatedAt : '')
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      if (this.exam === null) {
        this.emptyView()
      } else {
        Row() {
          Text('考试安排')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          Text(this.exam?.countdown ?? '')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.brand'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 10 }) {
          // 倒计时数字做成视觉锚点：一眼看到「还剩几天」
          Column({ space: 0 }) {
            Text(this.exam?.dateText ?? '')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.exam?.timeText ?? '')
              .fontSize(9)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          }
          .width(64)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 2 }) {
            Text(this.exam?.courseName ?? '')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.exam?.placeText ?? '')
              .fontSize(10)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.surface'))
    .onClick(() => {
      this.openApp();
    })
  }
}