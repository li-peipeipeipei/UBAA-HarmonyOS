/**
 * 空闲教室 · 桌面卡片（1×2）。
 *
 * 显示「哪天 + 空闲几间 + 一个具体教室号」—— 最后一项是关键：
 * 只给「空闲 12 间」用户还得自己点进去查，给了 `J3-101` 才能直接决定去不去。
 *
 * 空闲教室是**按日期查**的，所以卡片上的日期必须显式写出来
 * （`今天 · 10月15日`）—— 用户很容易忘了自己看的是哪天，
 * 而一个「昨天查出来的空闲教室」对今天毫无意义。
 *
 * 同样不 import 项目里的任何 .ets（见 ExamCard 的注释：卡片导入链的雷区）。
 */

/** LocalStorage key（必须与 UBAAFormAbility 推送的字段名完全一致）。 */
const KEY_CLASSROOM: string = 'classroomJson';
const KEY_ROOM_UPDATED: string = 'updatedAt';  // ⚠️ 模块级常量是**全局作用域**，不能与其他卡片同名

/** 空闲教室卡片数据（与主应用 CardCache 的 CardClassroom 同形）。 */
interface ClassroomCardData {
  dateText: string;
  roomText: string;
  summary: string;
  ready: boolean;
}

let classroomCardStorage: LocalStorage = new LocalStorage();

@Entry(classroomCardStorage)
@Component
struct ClassroomCard {
  @LocalStorageProp(KEY_CLASSROOM) classroomJson: string = '';
  @LocalStorageProp(KEY_ROOM_UPDATED) updatedAt: string = '';

  @State private room: ClassroomCardData | null = null;

  aboutToAppear(): void {
    this.parse();
  }

  private parse(): void {
    if (this.classroomJson.length === 0) {
      this.room = null;
      return;
    }
    try {
      this.room = JSON.parse(this.classroomJson) as ClassroomCardData;
    } catch (error) {
      this.room = null;
    }
  }

  private openApp(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        target: 'feature',
        page: 'classroom'
      }
    });
  }

  @Builder
  emptyView() {
    Column({ space: 5 }) {
      Text('空闲教室')
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Text('打开 App 查询空闲教室')
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
      if (this.room === null) {
        this.emptyView()
      } else {
        Row() {
          Text('空闲教室')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          // 日期必须显式带上：空闲教室是按天查的，隔天就过期
          Text(this.room?.dateText ?? '')
            .fontSize(10)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 10 }) {
          Column({ space: 1 }) {
            Text(this.room?.roomText ?? '—')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.brand'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.room?.summary ?? '')
              .fontSize(9)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
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