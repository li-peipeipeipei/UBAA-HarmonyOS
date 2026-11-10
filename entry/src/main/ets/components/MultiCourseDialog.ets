import { AppColor, AppFont, AppMaterial, AppSize } from './AppTheme';
import { MaterialCardLayer } from './MaterialCardLayer';
import { immersiveMaterialActive } from '../common/SystemMaterial';
import { CourseClass } from '../model/ApiTypes';

/**
 * 「同时段多节课」的选择弹窗。
 *
 * 对应官方课表里那块占满整列宽的「N节课 / 查看」—— 点开后列出这一时段的全部课程
 * （课程名 / 教室 / 节次 / 周次），点哪一行就看哪门课的详情。
 *
 * 为什么不把两门课并排画：一列只有约 168px，分成两半每块只剩 ~84px，两门**同名实验班**
 * 挤在窄块里既读不清课程名也分不清谁是谁；合成一块反而一眼看出「这里有 N 节课」。
 */
@CustomDialog
export struct MultiCourseDialog {
  /** 同时段的课程（由课表页的冲突簇给出，已按开始节次排序）。 */
  courses: CourseClass[] = [];

  /** 选中某门课：父组件负责关掉本弹窗、再打开该课详情。 */
  onPick: (course: CourseClass) => void = () => {};

  /** 框架注入的弹窗控制器（必须自己声明，不声明编译期报 `Property 'controller' does not exist`）。 */
  controller?: CustomDialogController;

  private readonly materialActive: boolean = immersiveMaterialActive();

  private textOf(value: string | undefined): string {
    return value === undefined || value === null ? '' : value;
  }

  /** 这门课的节次文案：`3节` / `2-5节`。 */
  private sectionOf(course: CourseClass): string {
    const begin: number = course.beginSection !== undefined && course.beginSection > 0 ? course.beginSection : 1;
    const end: number = course.endSection !== undefined && course.endSection >= begin ? course.endSection : begin;
    return begin === end ? begin.toString() + '节' : begin.toString() + '-' + end.toString() + '节';
  }

  /** 周次：课表项里形如 `1-16周[理论]/李翠萍[主讲]`，只取斜杠前那半。 */
  private weeksOf(course: CourseClass): string {
    const raw: string = this.textOf(course.weeksAndTeachers);
    if (raw.length === 0) {
      return '';
    }
    const slash: number = raw.indexOf('/');
    return slash > 0 ? raw.substring(0, slash) : raw;
  }

  @Builder
  header() {
    Row() {
      Text('同时段 ' + this.courses.length.toString() + ' 门课')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)

      // 关闭按钮：40vp 圆底，底板改用系统沉浸材质（与其它弹窗统一）
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
    .height(48)
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.SpaceBetween)
  }

  @Builder
  courseRow(course: CourseClass) {
    Column({ space: 4 }) {
      Text(course.courseName)
        .fontSize(AppFont.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.textOf(course.placeName))
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 8 }) {
        Text(this.sectionOf(course))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.brand)
        if (this.weeksOf(course).length > 0) {
          Text(this.weeksOf(course))
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surfaceSubtle)
    .onClick(() => {
      // 先关掉自己，父组件收到回调后再打开课程详情（避免两层弹窗互相顶掉）
      if (this.controller !== undefined) {
        this.controller.close();
      }
      this.onPick(course);
    })
  }

  /**
 * 弹窗本体。
 *
 * **宽 / 圆角 / 内边距与「课程详情」弹窗完全一致**（`width('86%') + maxWidth 400`、
 * `cardRadiusLarge`、`cardPadding + 4`）—— 两个弹窗会在同一页里先后出现，规格统一才不跳。
 * **高度由内容决定**：只有「门课列表超出 380vp」时才变成滚动区，
 * 两门课就只占两门课的高度（与详情弹窗的 `constraintSize({ maxHeight: 380 })` 同一套做法）。
 */
build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge, layerShadow: false })
      }

      Column({ space: AppSize.gap }) {
        this.header()

        Scroll() {
          Column({ space: AppSize.gap }) {
            ForEach(this.courses, (course: CourseClass) => {
              this.courseRow(course)
            }, (course: CourseClass) => course.courseCode + '-' + course.courseName + '-' +
              this.textOf(course.placeName) + '-' +
              (course.beginSection === undefined ? '' : course.beginSection.toString()))
          }
          .width('100%')
          // Scroll 会把比视口矮的子节点垂直居中，必须撑满才从顶部排起
          .constraintSize({ minHeight: '100%' })
        }
        .width('100%')
        .scrollBar(BarState.Off)
        // 与课程详情弹窗同一条：超过 380vp 才滚；不满时也靠 alwaysEnabled 响应手势回弹
        .constraintSize({ maxHeight: 380 })
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
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