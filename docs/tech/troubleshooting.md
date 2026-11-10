# 排障指南

## 编译期

| 报错 / 现象 | 原因 | 修法 |
| --- | --- | --- |
| `00303313 compileSdkVersion is incompatible` | 显式写了低版本 | 删掉 `compileSdkVersion` |
| `import { NavPathStack } from '@kit.ArkUI'` 报错 | `NavPathStack` 是全局声明类，不在 kit 导出表 | 去掉 import 直接用 |
| `ConfigurationConstant.Configuration` 不可用 | 该模块只导出 `ColorMode/Direction/ScreenDensity` | 从 `@kit.AbilityKit` 导入 `Configuration` |
| `@Builder toolbar()` 类型冲突 | `toolbar` 与 `CommonAttribute` 内置属性重名 | 换名（本项目用 `termBar()`） |
| `10903329 Unknown resource name 'sys.symbol.xxx'` | 系统符号表没有这一项（如 `sys.symbol.info`） | 改用存在的（`info_circle`） |
| `promptAction.showToast` 废弃告警 | API 26 起废弃 | 统一走 `common/Toast.ets` |
| `px2vp()` 废弃 | 全局函数废弃 | `window.getUIContext().px2vp()` |
| 改了代码但行为没变 | 增量缓存被上次失败构建污染 | `--no-incremental` 全量重编 |

系统符号的权威清单在 SDK 的
`sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js` 的 `sys.symbol` 段。

## 运行时

| 现象 | 判据 / 原因 | 处理 |
| --- | --- | --- |
| 白屏但无 JS 日志 | 进程被系统杀掉 | `hdc shell pidof <bundleName>`，无输出即崩溃 |
| `aa start` 报 `10106102` | 设备锁屏 | 物理解锁后再启动，自动化脚本无法绕过 |
| `hdc install` 只报 `Error opening file` | hap 没产出（构建失败但打印了 finished） | 检查 `.hap` 时间戳 |
| 弹窗刚开就闪退 | Builder 直接传方法引用丢了 `this` | 用箭头函数包一层 |
| 页面白屏、编译通过 | `@Builder` 用了泛型 | 改为非泛型或拆组件 |
| 列表少元素 | `ForEach` key 重复 | key 带唯一 id 且反映数据身份 |
| `Select` 显示异常 | 缺少 `.value()` 或 `.selected()` | 两者成对出现 |

## 网络

详见 [登录与连接模式](../features/auth-and-connection.md#排查顺序)，核心一条：
**返回 HTML 时按状态码分流**——`5xx` 是上游挂了，`2xx` 才是被登录页替换，
`404` 是地址错，不能用「响应体是 HTML」一刀切。

其他：

- `405 Method Not Allowed`：先确认没被 `302` 把 POST 改成 GET，再对请求头与表单字段。
- 切换连接模式后仍用旧会话：Cookie 按模式隔离，**必须重新登录**。
- WebVPN 下接口 404：只填了网关根域不行，必须用完整资源地址（由 `LocalWebVpn` 改写）。

## 真机调试速查

```bash
hdc list targets
hdc install -r entry-default-signed.hap
hdc shell pidof cn.edu.ubaa          # 有输出=活着
hdc shell hilog | grep -i ubaa       # 应用日志
hdc file recv /data/log/hilog/x.log  # 落盘时本地路径写相对文件名
```
