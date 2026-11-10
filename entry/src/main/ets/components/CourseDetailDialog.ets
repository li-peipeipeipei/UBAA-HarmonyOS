import { AppColor, AppFont, AppMaterial, AppSize } from './AppTheme';
import { MaterialCardLayer } from './MaterialCardLayer';
import { immersiveMaterialActive } from '../common/SystemMaterial';
import { CourseClass } from '../model/ApiTypes';

/**
 * 课程详情弹窗。
 *
 * 数据全部来自课表系统（byxt）的同一份课表响应，不额外打接口 —— 课表项本身就带
 * 任课教师 / 周次 / 学分 / 学时 / 类别 / 考核方式等字段（详见 buildCourseDetail）。
 */

/** 详情里的一行「标签 + 值」。 */
export interface CourseDetailRow {
  label: string;
  value: string;
}

/** 弹窗内容：标题（课程名）+ 若干信息行。 */
@Observed
export class CourseDetail {
  title: string = '';
  rows: CourseDetailRow[] = [];

  /**
   * 原地更新内容。
   *
   * 必须**原地改字段**、不能换一个新对象 —— 弹窗用 `@ObjectLink` 订阅这个实例，
   * 换对象会断开订阅。调用方拿到更完整的课表项后，就地再 `apply` 一次即可刷新。
   */
  apply(title: string, rows: CourseDetailRow[]): void {
    this.title = title;
    this.rows = rows;
  }
}

/** 组装一行，值为空时留给弹窗显示占位符。 */
function row(label: string, value: string): CourseDetailRow {
  return { label: label, value: value };
}

/** 构造一个 CourseDetail（@Observed 类不能用对象字面量）。 */
function makeDetail(title: string, rows: CourseDetailRow[]): CourseDetail {
  const detail = new CourseDetail();
  detail.title = title;
  detail.rows = rows;
  return detail;
}

/** 把空值统一折成空串。 */
function textOf(value: string | undefined): string {
  return value === undefined || value === null ? '' : value;
}

/** 节次补零成两位：`01` / `02`。 */
function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

/** 周次 + 教师的解析结果。 */
interface WeeksTeachers {
  weeks: string;
  teachers: string;
}

/** 去掉 `[理论]` / `[主讲]` / `（本）` 这类标注。 */
function stripTags(text: string): string {
  return text.replace(/\[[^\]]*\]/g, '').replace(/（[^）]*）/g, '').trim();
}

/**
 * 解析课表项的 `weeksAndTeachers`。
 *
 * 实测格式 `1-16周[理论]/李翠萍[主讲]`：多段用 `/` 分隔、多组用 `,` 分隔。
 * 含「周」的段是周次，其余是教师；两边都可能出现多次，去重后用「、」拼起来。
 */
function parseWeeksAndTeachers(raw: string): WeeksTeachers {
  const weeks: string[] = [];
  const teachers: string[] = [];
  if (raw.length === 0) {
    return { weeks: '', teachers: '' };
  }
  const groups: string[] = raw.split(',');
  for (let i = 0; i < groups.length; i++) {
    const segments: string[] = groups[i].split('/');
    for (let j = 0; j < segments.length; j++) {
      const text: string = stripTags(segments[j]);
      if (text.length === 0) {
        continue;
      }
      if (text.indexOf('周') >= 0) {
        if (weeks.indexOf(text) < 0) {
          weeks.push(text);
        }
      } else if (teachers.indexOf(text) < 0) {
        teachers.push(text);
      }
    }
  }
  return { weeks: weeks.join('、'), teachers: teachers.join('、') };
}

/**
 * 标签别名：把上游 `titleDetail` 里的叫法映射到我们用的叫法，避免同一个信息出两行。
 *
 * 形如 `上游标签|本弹窗标签`。
 */
const LABEL_ALIASES: string[] = [
  '课程号|课程编号',
  '上课教师|任课教师',
  '上课地点|地点',
  '上课时间|时间',
  '课程名|课程名称'
];

/** 取标签的规范名（用于去重）。 */
function canonicalLabel(label: string): string {
  for (let i = 0; i < LABEL_ALIASES.length; i++) {
    const pair: string[] = LABEL_ALIASES[i].split('|');
    if (pair[0] === label) {
      return pair[1];
    }
  }
  return label;
}

/** 上课时间：`08:00-09:35`。 */
function timeRange(course: CourseClass): string {
  const begin: string = textOf(course.beginTime);
  const end: string = textOf(course.endTime);
  if (begin.length > 0 && end.length > 0) {
    return begin + '-' + end;
  }
  return begin.length > 0 ? begin : end;
}

/** 上课节次：`0102`（起止节次各两位）。 */
function sectionText(course: CourseClass): string {
  const begin: number | undefined = course.beginSection;
  const end: number | undefined = course.endSection;
  if (begin !== undefined && begin > 0 && end !== undefined && end > 0) {
    return pad2(begin) + pad2(end);
  }
  if (begin !== undefined && begin > 0) {
    return pad2(begin);
  }
  return '';
}

/**
 * 由课表项组装详情。
 *
 * 字段来源（实测 `getMyScheduleDetail.do` 的课表项）：
 * - 任课教师 / 上课周次 ← `weeksAndTeachers`（如 `1-16周[理论]/李翠萍[主讲]`）
 * - 时间 ← `beginTime` + `endTime`；地点 ← `placeName`；学分 ← `credit`
 * - 课程编号 ← `courseCode`；课序号 ← `courseSerialNo`；上课节次 ← 起止节次
 * - 其余 ← `titleDetail`（上游预置的「标签：值」行，如「本研标识：本」），
 *   已覆盖的标签不重复添加。
 */
export function buildCourseDetail(course: CourseClass): CourseDetail {
  const merged: WeeksTeachers = parseWeeksAndTeachers(textOf(course.weeksAndTeachers));

  const rows: CourseDetailRow[] = [];
  rows.push(row('任课教师', merged.teachers));
  rows.push(row('时间', timeRange(course)));
  rows.push(row('地点', textOf(course.placeName)));
  rows.push(row('上课周次', merged.weeks));
  rows.push(row('课程编号', textOf(course.courseCode)));
  rows.push(row('课序号', textOf(course.courseSerialNo)));
  rows.push(row('课程学分', textOf(course.credit)));
  rows.push(row('上课节次', sectionText(course)));
  const extra: string[] = course.titleDetail === undefined ? [] : course.titleDetail;
  for (let i = 0; i < extra.length; i++) {
    const item: string = extra[i];
    const sep: number = item.indexOf('：');
    if (sep <= 0) {
      continue;
    }
    const label: string = item.substring(0, sep).trim();
    const value: string = item.substring(sep + 1).trim();
    const canonical: string = canonicalLabel(label);
    // 课程名就是标题，不必再来一行
    if (canonical === '课程名' || canonical === '课程名称') {
      continue;
    }
    let exists: boolean = false;
    for (let k = 0; k < rows.length; k++) {
      if (rows[k].label === canonical) {
        exists = true;
        break;
      }
    }
    if (!exists) {
      rows.push(row(canonical, value));
    }
  }

  return makeDetail(textOf(course.courseName), rows);
}

/**
 * 由「今日课程」的简要信息组装详情。
 *
 * 今日课程接口只给课程名 / 时间 / 地点，且课表里可能存在同名多个时段，
 * 调用方应先尝试用课表里的完整项构造（见 buildCourseDetail）；这里只是兜底。
 */
export function buildSimpleDetail(title: string, time: string, place: string): CourseDetail {
  const rows: CourseDetailRow[] = [];
  rows.push(row('时间', time));
  rows.push(row('地点', place));
  return makeDetail(title, rows);
}

@CustomDialog
export struct CourseDetailDialog {
  controller?: CustomDialogController;
  /**
   * 详情内容（`@Observed` 实例，`@ObjectLink` 订阅）。
   *
   * 这样弹窗**打开之后**仍能被刷新：调用方原地改 `detail` 的字段即可（见
   * `CourseDetail.apply`）。首页「点了立刻弹、详情稍后补全」就靠这条 ——
   * 换成 `@Prop` 是收不到后续更新的（弹窗不在父组件渲染树里，实测过）。
   */
  @ObjectLink detail: CourseDetail;

  /**
   * 沉浸材质是否可用（API ≥ 26、应用级没被 DISABLE、材质构造成功）。
   * 不可用时走兜底的手动玻璃样式，避免卡片变成一块全透明空壳。
   */
  private readonly materialActive: boolean = immersiveMaterialActive();

  build() {
    if (this.materialActive) {
      this.immersiveCard();
    } else {
      // API 26 以下的设备取不到系统材质，退回「半透明玻璃底 + 高斯模糊」的手动样式
      this.glassCard();
    }
  }

  /**
   * 卡片内容：标题 + 分隔线 + 信息行 + 关闭按钮。
   * 两种外观共用同一份内容，保证它们**只有底色/材质不同**，其余完全一致。
   */
  @Builder
  cardContent() {
    Column() {
      Text(this.detail.title)
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ bottom: 8 })

      Divider()
        .color(AppColor.divider)
        .strokeWidth(0.5)

      Scroll() {
        Column() {
          ForEach(this.detail.rows, (item: CourseDetailRow) => {
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
          }, (item: CourseDetailRow) => item.label)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      // 滑动到上限有回弹（`Spring`），而且**内容不满也响应手势**（`alwaysEnabled`）：
      // 只写 `Spring` 时，内容短于 maxHeight 的这块是「没可滚区间却吞手势」的死区，
      // 手按上去拖不动也没反馈 —— 加上 alwaysEnabled 才会跟着手指弹一下再回位。
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .constraintSize({ maxHeight: 380 })
      .margin({ top: 4 })

      // 「确定」按钮：**沉浸材质 + 一层半透明品牌蓝**。
      //
      // 材质只能由「按钮 / 选择类」承载，而且**不能挂在 Button 自己身上**
      // （真机实测普通 Button 挂 systemMaterial 不渲染），所以在 Button 下面垫一块
      // `MaterialCardLayer`；蓝色写在 Button 上（= 材质之上的内容层）—— 与半模态里
      // 「选中态品牌色」是同一套规矩（材质画在 `backgroundColor` 之上，写在底色会被盖掉）。
      // 蓝色留 55% 不透明：既保住主按钮的蓝，又让玻璃那层光透出来（见 AppColor.brandGlass）。
      Stack() {
        if (this.materialActive) {
          MaterialCardLayer({ layerRadius: 22, layerShadow: false })
        }
        Button('确定')
          .width('100%')
          .height(44)
          .fontSize(AppFont.subtitle)
          .fontColor(AppColor.textOnBrand)
          .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }
      .width('100%')
      .height(44)
      .margin({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 沉浸材质卡（与底部页签栏同一套系统光感）。
   *
   * ⚠️ **不能把 `systemMaterial` 直接挂在这个 `Column` 上** —— 普通布局容器在内容区
   * 挂材质是「静默不渲染」的（不报错、不警告，只是什么都不画，卡片会变成全透明）。
   * 材质必须由「按钮 / 选择类」组件承载，所以这里叠了一层
   * `MaterialCardLayer`（不可交互的 `ToggleType.Button` 画布），内容画在它之上。
   *
   * `Stack` 自身刻意**不设底色**（材质之下必须透明，任何不透明底色都会把材质盖住），
   * 也不设内边距（承载层按父级实测尺寸铺满，留白交给内容层，免得材质盖不满卡片）。
   */
  @Builder
  immersiveCard() {
    Stack() {
      MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      Column() {
        this.cardContent()
      }
      .width('100%')
      .padding(AppSize.cardPadding + 4)
      .alignItems(HorizontalAlign.Start)
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .borderRadius(AppSize.cardRadiusLarge)
    .backgroundColor(Color.Transparent)
  }

  /** 兜底玻璃卡（API 26 以下设备）：半透明底 + 大半径高斯模糊 + 细描边。 */
  @Builder
  glassCard() {
    Column() {
      this.cardContent()
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .padding(AppSize.cardPadding + 4)
    // 只有一个弹窗，大半径高斯模糊的开销可接受（页面里十几个课程块才不能用）
    .backdropBlur(AppMaterial.blurLarge)
    .backgroundColor(AppColor.glassSurface)
    .border({ width: 0.5, color: AppColor.divider })
    .borderRadius(AppSize.cardRadiusLarge)
    .alignItems(HorizontalAlign.Start)
  }
}
