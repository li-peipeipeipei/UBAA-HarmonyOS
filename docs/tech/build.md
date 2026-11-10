# 构建与签名

## 环境

| 项 | 值 |
| --- | --- |
| DevEco Studio | 26.0.0（自带 HarmonyOS SDK 26.0.0） |
| `compatibleSdkVersion` | `6.1.0(23)` —— HDS 悬浮底栏与沉浸光感自该版本起提供 |
| `compileSdkVersion` | **不配置**，跟随 DevEco 自带 SDK |
| 构建工具 | Hvigor |
| 产物 | `entry/build/default/outputs/default/entry-default-signed.hap` |

**不要显式写 `compileSdkVersion`**：写死低版本会触发
`hvigor ERROR 00303313 Configuration Error: compileSdkVersion is incompatible with the
current DevEco Studio version`。

## 首次构建

仓库**不含** `build-profile.json5` —— 它含本机调试签名凭据（`keyPassword` / `storePassword`
与证书绝对路径），已在 `.gitignore` 排除。

1. 复制模板：`build-profile.example.json5` → `build-profile.json5`
2. DevEco Studio 打开工程根目录，等 Hvigor 同步完成
3. `File > Project Structure > Signing Configs` 勾选 **Automatically generate signature**
   （需要登录华为开发者账号）
4. 连接 **HarmonyOS 6.1.0(23) 及以上** 的真机或模拟器，Run `entry`

模板里的 `signingConfigs` 留空，签名材料由 IDE 生成到
`~/.ohos/config/`，**不要提交**。

## 命令行构建

```bash
hvigorw assembleHap --mode module -p product=default
```

两条经验：

- **失败的构建会污染增量缓存**：之后仍打印 `BUILD SUCCESSFUL`，但日志里是
  `CompileArkTS is up-to-date` 而没重编。改代码没生效时用全量：
  `hvigorw clean assembleHap --no-incremental`。
- **以产物时间戳为准**：`SignHap` 失败时构建同样会打印 finished，
  `hdc install` 只会静默报 `Error opening file`。装之前先看
  `entry-default-signed.hap` 的修改时间是不是刚才。
  `unsigned.hap` + `modules.abc` 都正常产出，说明 ArkTS 编译实际是通过的。

## 签名注意

调试证书默认 **14 天过期**，过期后 `SignHap` 报
`11013002 / The certificate has expired!`（ArkTS 全部通过，只有签名阶段失败）。

这种情况下命令行改不了：`.p7b` 是华为签名服务签发的 CMS，必须在
`Project Structure > Signing Configs` 里重新自动签名。查证书有效期：

```bash
keytool -printcert -file ~/.ohos/config/default_*.cer
```

> 工程改名后，IDE 可能重新生成一套签名材料，导致 profile 里的设备 UDID 失效、
> 已装应用需卸载重装。改名后请检查 Signing Configs 是否被改写。
