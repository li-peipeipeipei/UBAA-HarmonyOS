# 登录与连接模式

## 两种模式

登录页与「我的 → 连接设置」共用同一份枚举（`common/AppConfig.ets`）：

| 模式 | 枚举 | 访问方式 | 适用场景 |
| --- | --- | --- | --- |
| 校内直连 | `ConnectionMode.DIRECT` | 直接访问 `sso.buaa.edu.cn` / `uc.buaa.edu.cn` / 教务系统 | 连着校园网或校园 VPN |
| WebVPN | `ConnectionMode.WEBVPN` | 同样是校内上游，但地址经 `d.buaa.edu.cn` 加密转发 | 校外，需先过统一认证 |

- **没有自建服务端**。上游 UBAA 的 Ktor 网关（`/api/v1/*`、JWT、refresh）已停止部署，
  代码里的 `/api/v1` 常量只是历史遗留，登录链路不再经过它。
- **登录态是上游 Cookie，不是 JWT**。所以没有 accessToken / refreshToken，
  会话是否有效靠实时请求 `uc/api/uc/status` 判定。
- **两种模式各存一份 Cookie 罐**（`TokenStore.modeScopedKey`），切换模式必须重新登录，
  互不污染。凭据在本地加密保存（`CREDENTIAL_SALT` 派生密钥）。

## 登录链路

`network/LocalAuthService.ets` 完整实现 CAS（参考上游 Kotlin 的 `LocalConnectionAuth`）：

```text
GET  sso.buaa.edu.cn/login          → 取 execution 隐藏字段，探测是否触发验证码
POST sso.buaa.edu.cn/login (表单)   → 不自动跟随重定向，逐跳读 Location + Set-Cookie
GET  uc.buaa.edu.cn/api/login?…     → 用 SSO 会话换 UC 会话
GET  uc.buaa.edu.cn/api/uc/status   → code == 0 且带 data 才算登录成功
```

要点：

- `UpstreamClient` 对 CAS 流程强制 `followRedirects: false`，逐跳处理 `3xx`，
  否则会丢掉中间的 `Set-Cookie`。
- **`POST /login` 返回 200 不代表成功**：账号密码错误时 CAS 也是 200 + 登录页 HTML。
  必须再打 `uc/status` 校验，不能只看状态码。
- 需要验证码时抛 `CaptchaRequiredError`，登录页切到验证码输入态，
  图片走 `binary: true` 取 `Uint8Array` 渲染。
- 页面解析在 `network/CasParser.ets`，与请求逻辑分离，上游改版时只改这一处。

## WebVPN 地址改写

北航 WebVPN 用「域名加密」代理内网资源（`network/LocalWebVpn.ets`）：

```text
https://d.buaa.edu.cn/<协议>[-<端口>]/<加密主机名><原路径>
例：sso.buaa.edu.cn/login → https://d.buaa.edu.cn/https/<32位IV+密文>/login
```

算法（网关侧固定约定）：明文主机名按 16 字节分块、末尾补 `'0'`，
AES-128 / CFB / NoPadding，密钥与 IV 同为 `wrdvpnisthebest!`；
输出 = IV 的 32 位十六进制 + 密文十六进制截断到「明文长度 × 2」位。

所以**业务代码里不要手拼 WebVPN 地址**：只用逻辑地址（真实上游域名 + 路径），
由 `UpstreamClient` 统一过 `LocalWebVpn.rewrite()`。它还负责两件事：

- 从网关返回的加密 URL 反解回逻辑地址（`fromWebVpnUrl`），保证重定向能继续走；
- 对 HTTPS 做 HSTS 升级（`secureCasTransportUrl`）。

## 排查顺序

接口返回 HTML 时，**先看状态码再下结论**（`ApiError.fromHtmlResponse()` 已按此分流）：

| 状态码 | 真实性质 | 该做什么 |
| --- | --- | --- |
| 5xx + HTML | 反向代理自产错误页，上游服务没起来 | 等后端恢复，客户端改不出来 |
| 404 + HTML | 地址或路径不对，打到别的站点 | 改地址 / 检查是否漏了路径段 |
| 2xx + HTML | 接口位置对，内容被登录门户替换 | 先在浏览器完成统一认证 |
| 3xx 循环 | CAS / WebVPN 反复跳转 | 检查 WebVPN 是否填了完整资源地址 |

> 教训：早期只判断「响应体是 HTML」就一律报「被 CAS 拦截」，结果 `502` 的 nginx
> 错误页也被误报成登录拦截，排查方向被带偏。

其他两条硬规矩：

- `HttpEngine` 的 `catch` 必须放行已经是 `ApiError` 的异常，否则业务异常会被二次
  包装成网络错误，错误码变成 `错误码 portal_page` 这种噪音。
- 出现 `405 Method Not Allowed`，先确认路径与方法没被 `302` 改成 `GET`，
  再确认请求体 `Content-Type` 与上游要求一致。
