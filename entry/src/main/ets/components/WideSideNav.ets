import { AppColor, AppFont, AppMaterial, AppSize } from './AppTheme';
import { MaterialCardLayer } from './MaterialCardLayer';
import { immersiveMaterialActive } from '../common/SystemMaterial';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { sideNavWidthOf } from '../common/Breakpoint';

/**
 * 宽屏侧边导航栏（平板 / 折叠展开 / 2in1 / 宽自由窗口）。
 *
 * 只在 isWideScreen=true 时渲染；手机端完全不创建这个组件。
 *
 * 材质：普通 Column 在内容区挂 systemMaterial 静默不渲染，底板必须交给
 * MaterialCardLayer（不可交互 ToggleType.Button 画布），菜单项作为 Stack 兄弟叠上去。
 * 选中态用半透明品牌色写在**内容层**，不能写成不透明底（会盖死材质）。
 */
@Component
export struct WideSideNav {
  @Prop currentIndex: number = 0;
  @Prop bp: string = 'sm';
  onSelect: (index: number) => void = () => {};

  private readonly materialActive: boolean = immersiveMaterialActive();

  @Builder
  navItem(index: number, icon: Resource, label: string) {
    Row({ space: 12 }) {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.currentIndex === index ? AppColor.brand : AppColor.textSecondary)
      // md 档只放图标（72vp），lg / xxl 才带文字
      if (this.bp !== 'md') {
        Text(label)
          .fontSize(AppFont.subtitle)
          .fontColor(this.currentIndex === index ? AppColor.brand : AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .height(48)
    .padding({
      left: this.bp === 'md' ? 0 : 12,
      right: this.bp === 'md' ? 0 : 8
    })
    .justifyContent(this.bp === 'md' ? FlexAlign.Center : FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(this.currentIndex === index ? AppColor.brandContainerGlass : Color.Transparent)
    .onClick(() => {
      this.onSelect(index);
    })
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: 0, layerSquareBottom: true, layerShadow: false })
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(AppColor.glassSurface)
          .backdropBlur(AppMaterial.blurLarge)
      }

      Column({ space: 8 }) {
        Blank().height(topSafeInsetVp() + 16)
        this.navItem(0, $r('app.media.ic_home'), '主页')
        this.navItem(1, $r('app.media.ic_schedule'), '课表')
        this.navItem(2, $r('app.media.ic_apps'), '功能')
        this.navItem(3, $r('app.media.ic_person'), '我的')
      }
      .width('100%')
      .height('100%')
      .padding({ left: 8, right: 8 })
      .alignItems(HorizontalAlign.Start)
    }
    .width(sideNavWidthOf(this.bp))
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
