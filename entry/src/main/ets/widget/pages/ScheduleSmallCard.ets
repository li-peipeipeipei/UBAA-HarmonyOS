/**
 * 课表 · 桌面卡片（次大 1×2）。
 *
 * 与 2×2 大卡**共用同一份数据**（同样的 LocalStorage key），差别只在渲染：
 * 1×2 是横向窄条，塞不下课程列表，所以只放**最有价值的一条 —— 下一节课**。
 * 「下一节」由主应用算好后放进数据里（`next`），卡片不自己判断当前时间，
 * 免得宿主时间与卡片渲染时间不一致。
 *
 * ⚠️ 与大卡同样的两个限制：**不能用 hilog**（编译器报
 * `'hilog' can't support form application`）、**不 import 项目任何 .ets**
 * （卡片导入链的雷区，见官方 FAQ）。
 */

interface SmallCardCourse {
  section: string;
  time: string;
  courseName: string;
  place: string;
}

interface SmallCardToday {
  headline: string;
  summary: string;
  courses: SmallCardCourse[];
  /** 下一节课（没有则为 null）。 */
  next: SmallCardCourse | null;
  ready: boolean;
}

let smallCardStorage: LocalStorage = new LocalStorage();

@Entry(smallCardStorage)
@Component
struct ScheduleSmallCard {
  @LocalStorageProp('scheduleJson') scheduleJson: string = '';
  @LocalStorageProp('weekLabel') weekLabel: string = '';
  @LocalStorageProp('updatedAt') updatedAt: string = '';

  @State private today: SmallCardToday | null = null;

  aboutToAppear(): void {
    this.parse();
  }

  private parse(): void {
    if (this.scheduleJson.length === 0) {
      this.today = null;
      return;
    }
    try {
      this.today = JSON.parse(this.scheduleJson) as SmallCardToday;
    } catch (error) {
      this.today = null;
    }
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        target: 'schedule'
      }
    });
  }

  /** 右侧竖排：今天几节 + 数据时间。 */
  @Builder
  rightColumn() {
    Column({ space: 2 }) {
      Text(this.today !== null ? (this.today?.courses?.length ?? 0).toString() : '0')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.brand'))
      Text('节 / 今天')
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
      Text(this.updatedAt.length > 0 ? this.updatedAt.slice(6) : '')
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
    }
    .alignItems(HorizontalAlign.End)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Row() {
      Column({ space: 3 }) {
        Text(this.weekLabel.length > 0 ? this.weekLabel : (this.today?.headline ?? 'UBAA 课表'))
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.today === null) {
          Text('打开 App 查看课表')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        } else if (this.today?.next !== null && this.today?.next !== undefined) {
          Text(this.today?.next?.time + ' · ' + this.today?.next?.section)
            .fontSize(10)
            .fontColor($r('app.color.brand'))
            .maxLines(1)
          Text(this.today?.next?.courseName ?? '')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.today?.next?.place ?? '')
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        } else {
          Text('今天没有课了')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      this.rightColumn()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.surface'))
    .onClick(() => {
      this.openApp();
    })
  }
}