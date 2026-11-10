import {
  HdsNavDestination,
  HdsNavigationTitleBarOptions,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { RouteName } from '../common/AppRouter';
import { GradeHeaderModel, GradeTermTitle } from '../components/GradeHeader';
import { ExamPage } from './ExamPage';
import { GradePage } from './GradePage';
import { ClassroomPage } from './ClassroomPage';
import { SigninPage } from './SigninPage';
import { EvaluationPage } from './EvaluationPage';
import { JudgePage } from './JudgePage';
import { JudgeDetailPage } from './JudgeDetailPage';
import { IhomePage } from './IhomePage';
import { IhomeDetailPage } from './IhomeDetailPage';
import { SpocPage } from './SpocPage';
import { YgdkPage } from './YgdkPage';
import { BykcPage } from './BykcPage';
import { BykcCoursesPage } from './BykcCoursesPage';
import { BykcChosenPage } from './BykcChosenPage';
import { BykcStatisticsPage } from './BykcStatisticsPage';
import { BykcDetailPage } from './BykcDetailPage';
import { LibBookHomePage } from './LibBookHomePage';
import { LibBookReservePage } from './LibBookReservePage';
import { LibBookBookingsPage } from './LibBookBookingsPage';
import { UserInfoPage } from './UserInfoPage';
import { SettingsPage } from './SettingsPage';
import { AboutPage } from './AboutPage';
import { WidePlaceholder } from '../components/WidePlaceholder';
import { WIDE_PLACEHOLDER_ROUTE } from '../common/AppRouter';

/**
 * 成绩页的 NavDestination 外壳（**必须**做成组件）。
 *
 * ## 为什么不能像其它二级页那样在 routeBuilder 里直接写
 *
 * 成绩页的标题栏要放「学期名 + ← →」，而 HDS 的 `content.stackBuilder` 是由
 * 原生侧（hdsBaseComponent.js）回调执行的。回调里的 @Builder 依赖
 * `this.observeComponentCreation2`：
 *
 * - 在**普通函数**里写箭头函数 → `this` 是 undefined → 闪退；
 * - 在 routeBuilder（全局 @Builder）里包一层全局 @Builder → 同样没有组件实例 →
 *   `Cannot read property observeComponentCreation2 of undefined`。
 *
 * 真机实测两种写法都会在点「成绩查询」时必现。把整个 destination 收进一个
 * @Component，让箭头函数捕获组件实例（与 MainPage.scheduleTitleBar 同一套写法），
 * 标题栏里的 @Builder 才能正常创建组件。
 */
@Component
struct GradeDestination {
  stack: NavPathStack = new NavPathStack();

  /** 标题栏与页面共用同一个 @Observed 实例（换学期时两边一起刷新）。 */
  @State private header: GradeHeaderModel = new GradeHeaderModel();

  @Builder
  termTitle() {
    GradeTermTitle({ model: this.header });
  }

  private titleBarOptions(): HdsNavigationTitleBarOptions {
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        // 箭头函数捕获本组件实例，HDS 原生回调时 @Builder 仍在实例上执行
        stackBuilder: (): void => {
          this.termTitle();
        }
      }
    };
  }

  build() {
    HdsNavDestination() {
      DestShell({ stack: this.stack }) {
        GradePage({ header: this.header })
      }
    }
    .titleBar(this.titleBarOptions())
    .backgroundColor($r('app.color.page_background'))
  }
}

/**
 * 全局路由表（供四个页签的 HdsNavigation 共用）。
 *
 * 二级页面用 **HdsNavDestination**（而不是原生 NavDestination），原因有三：
 *   1. 底板半透明：二级页面的标题栏也能拿到与主页同款的「沉浸光感」材质，
 *      滚动时内容从毛玻璃下透出，而不是一条死黑/死白的实心条；
 *   2. 顶部避让：HdsNavDestination 的标题栏自行避让状态栏，不必再手写 padding
 *      （原生 NavDestination 会直接把标题压在状态栏时钟上）；
 *   3. 返回按钮沿用 HDS 规范样式，与系统应用一致。
 */
function destTitleBar(title: string): HdsNavigationTitleBarOptions {
  return {
    avoidLayoutSafeArea: true,
    // 组件级安全区：标题栏的材质底板连状态栏一起覆盖，标题文字仍从状态栏下沿开始。
    // 这是「顶部模糊没有横向接缝」的关键 —— 不再需要外壳另外叠一层 backdropBlur
    // 去兜状态栏那一条（那层与标题栏材质强度不一致，接缝正是它造成的）。
    enableComponentSafeArea: true,
    style: {
      // 初始底色显式透明：避免首帧先铺一层实心底色再换挡成材质。
      originalStyle: {
        backgroundStyle: {
          backgroundColor: Color.Transparent
        }
      },
      scrollEffectOpts: {
        enableScrollEffect: true,
        scrollEffectType: ScrollEffectType.GRADIENT_BLUR
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    },
    content: {
      title: {
        mainTitle: title
      }
    }
  };
}

/**
 * 二级页面内容外壳。
 *
 * 2026-09-20 起只是一层「撑满 + 承载 @BuilderParam」的容器，**不再自己补模糊层**。
 * 顶部模糊全部交给 HDS：destTitleBar 里置了 `enableComponentSafeArea: true`，
 * 标题栏被声明成组件级安全区，材质底板一直铺到屏幕顶端（状态栏区域也盖上）。
 *
 * 此前是叠一层 `Column().height(topSafeInsetVp()).backdropBlur(20)` 去盖状态栏，
 * 那一条的模糊强度与标题栏自带材质对不上，交界处有一条明显横向断层（状态栏那段更
 * 「糊」、下面那段更「透」）。现在唯一模糊源是标题栏自己的材质，接缝消失。
 *
 * 外壳本身**不加内边距**：加在外壳上的 padding 会被当成 contentInset 把整块内容
 * 连同滚动视口一起压低，内容就再也滑不进底板。顶部留白由页面自己的滚动内容承担
 * （见各二级页 `.padding({ top: AppSize.destTopInset(topSafeInsetVp()) })`）；
 * 底部同理，留给滚动内容（AppSize.contentBottomInset），否则悬浮底栏背后永远是
 * 一块实心底板，毛玻璃透不出内容。
 *
 * 另外：HdsNavDestination 自身的 padding 作用在整个组件上，会把沉浸式标题栏
 * 一起推下去（实测标题栏从 63vp 掉到 163vp，正好压在第一张卡片上），所以顶部
 * 避让也不能拿它来做。
 */
@Component
struct DestShell {
  @Builder
  empty() {
  }

  @BuilderParam content: () => void = this.empty;
  /**
   * 当前页签的导航栈。
   *
   * 二级页里有的还要**再跳一级**（博雅课程列表 → 课程详情），
   * 而 `navDestination` 的回调拿不到栈 —— 所以从 `MainPage` 一路传下来。
   */
  stack: NavPathStack = new NavPathStack();

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
  }
}

@Builder
export function routeBuilder(name: string, param: object, stack: NavPathStack) {
  if (name === RouteName.EXAM) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        ExamPage()
      }
    }
    .titleBar(destTitleBar('考试安排'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.GRADE) {
    GradeDestination({ stack: stack })
  } else if (name === RouteName.CLASSROOM) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        ClassroomPage()
      }
    }
    .titleBar(destTitleBar('空闲教室'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.IHOME) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        IhomePage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('iHome'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.IHOME_DETAIL) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        IhomeDetailPage()
      }
    }
    .titleBar(destTitleBar('诉求详情'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.JUDGE) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        JudgePage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('希冀作业'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.JUDGE_DETAIL) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        JudgeDetailPage()
      }
    }
    .titleBar(destTitleBar('作业详情'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.EVALUATION) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        EvaluationPage()
      }
    }
    .titleBar(destTitleBar('自动评教'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.SIGNIN) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        SigninPage()
      }
    }
    .titleBar(destTitleBar('课堂签到'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.SPOC) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        SpocPage()
      }
    }
    .titleBar(destTitleBar('SPOC 作业'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.YGDK) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        YgdkPage()
      }
    }
    .titleBar(destTitleBar('阳光打卡'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.BYKC) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcPage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('博雅课程'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.BYKC_COURSES) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcCoursesPage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('选择课程'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.BYKC_CHOSEN) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcChosenPage()
      }
    }
    .titleBar(destTitleBar('我的课程'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.BYKC_STATISTICS) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcStatisticsPage()
      }
    }
    .titleBar(destTitleBar('课程统计'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.BYKC_DETAIL) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        BykcDetailPage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('课程详情'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.LIBBOOK_HOME) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        LibBookHomePage({ stack: stack })
      }
    }
    .titleBar(destTitleBar('图书馆座位'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.LIBBOOK_RESERVE) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        LibBookReservePage()
      }
    }
    .titleBar(destTitleBar('预约座位'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.LIBBOOK_BOOKINGS) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        LibBookBookingsPage()
      }
    }
    .titleBar(destTitleBar('我的座位预约'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.USER_INFO) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        UserInfoPage()
      }
    }
    .titleBar(destTitleBar('个人资料'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.SETTINGS) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        SettingsPage()
      }
    }
    .titleBar(destTitleBar('设置'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === RouteName.ABOUT) {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        AboutPage()
      }
    }
    .titleBar(destTitleBar('关于'))
    .backgroundColor($r('app.color.page_background'))
  } else if (name === WIDE_PLACEHOLDER_ROUTE) {
    // Split 右栏栈空时的占位页；手机端 / md 单栏档从不 push 这个名字。
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        WidePlaceholder()
      }
    }
    .titleBar(destTitleBar(''))
    .backgroundColor($r('app.color.page_background'))
  } else {
    HdsNavDestination() {
      DestShell({ stack: stack }) {
        Column() {
          Text('页面不存在：' + name)
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }
    }
    .titleBar(destTitleBar('出错了'))
    .backgroundColor($r('app.color.page_background'))
  }
}
