/**
 * 成绩概览 · 桌面卡片（1×2）。
 *
 * 与考试 / 空闲教室两张卡**共用同一套机制**：数据由主应用写 Preferences、
 * 卡片侧只读（见 CardCache 的注释：卡片进程活不过 10 秒，不能联网）。
 *
 * 显示的是**本学期概览**：平均绩点 + 已修学分 + 最高分课程 —— 三个都是
 * 「看一眼就知道要不要点进去」的指标。完整成绩单得点进 App。
 *
 * 同样不 import 项目里的任何 .ets（见 ExamCard 的注释：卡片导入链的雷区）。
 */

/** LocalStorage key（必须与 UBAAFormAbility 推送的字段名完全一致）。 */
const KEY_GRADE: string = 'gradeJson';
const KEY_GRADE_UPDATED: string = 'updatedAt';  // ⚠️ 模块级常量是**全局作用域**，不能与其他卡片同名

/** 成绩卡片数据（与主应用 CardCache 的 CardGrade 同形）。 */
interface GradeCardData {
  termName: string;
  gpa: string;
  credit: string;
  bestText: string;
  ready: boolean;
}

let gradeCardStorage: LocalStorage = new LocalStorage();

@Entry(gradeCardStorage)
@Component
struct GradeCard {
  @LocalStorageProp(KEY_GRADE) gradeJson: string = '';
  @LocalStorageProp(KEY_GRADE_UPDATED) updatedAt: string = '';

  @State private grade: GradeCardData | null = null;

  aboutToAppear(): void {
    this.parse();
  }

  private parse(): void {
    if (this.gradeJson.length === 0) {
      this.grade = null;
      return;
    }
    try {
      this.grade = JSON.parse(this.gradeJson) as GradeCardData;
    } catch (error) {
      this.grade = null;
    }
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        target: 'feature',
        page: 'grade'
      }
    });
  }

  @Builder
  emptyView() {
    Column({ space: 5 }) {
      Text('成绩查询')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('打开 App 获取本学期成绩')
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
      if (this.grade === null) {
        this.emptyView()
      } else {
        Row() {
          Text(this.grade?.termName !== undefined && (this.grade?.termName ?? '').length > 0 ?
            this.grade?.termName ?? '' : '本学期成绩')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          // 绩点是这张卡的主角：数字大、单位小
          Row({ space: 2 }) {
            Text(this.grade?.gpa ?? '—')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.brand'))
            Text('GPA')
              .fontSize(9)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 8 })
          }
          .alignItems(VerticalAlign.Bottom)

          Column({ space: 3 }) {
            Text(this.grade?.credit ?? '')
              .fontSize(11)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.grade?.bestText ?? '')
              .fontSize(9)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 2 })
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