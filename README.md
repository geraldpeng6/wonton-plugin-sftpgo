# 云吞插件：SFTPGo

把 [SFTPGo](https://sftpgo.com)（上游 [drakkan/sftpgo](https://github.com/drakkan/sftpgo)）装进云吞：手机和电脑用 SFTP、WebDAV 客户端直连家里的文件，浏览器里也能上传下载和分享。装上后打开网页直接进 WebClient，用的是云吞账号。

## 工作方式

- **镜像**：上游官方镜像 `drakkan/sftpgo`。选 alpine 变体（`v2.7.6-alpine`）而不是默认的 debian 变体，因为后者不带任何 HTTP 客户端（wget/curl 都没有），写不了健康检查；两个变体由上游同一套 CI（`.github/workflows/docker.yml`）从同一份代码发布，alpine 版自带 jq（pre-login hook 用）。按多架构清单列表的摘要固定（amd64、arm64）。
- **登录**：SFTPGo 原生支持 OIDC（v2.7 起按绑定配置）。`sso: oidc`，issuer、客户端和回调基址全部来自核心注入的 `WONTON_OIDC_*` 变量；`implicit_roles: true` 让角色由登录入口决定，不依赖身份提供方的角色声明。打开网页直接进 WebClient 的 OpenID 登录入口（`webui.path: /web/client/oidclogin`），不经过应用的登录页。
- **建号**：SFTPGo 的 OIDC 映射账号必须已存在（[OIDC 文档](https://docs.sftpgo.com/latest/oidc/)）。WebClient 用户账号用上游的 pre-login hook（`data_provider.pre_login_hook`，上游动态建号机制）在首次登录时创建，见 `prelogin-hook.sh`：账号不存在就用身份提供方认出的用户名建号（主目录在 `/srv/sftpgo/data/<用户名>`，首次登录可写），已存在的用户一律不碰。WebAdmin 没有对应的自动建号机制，需要的用户在 `/web/admin` 的初始化页自己建（用户名填云吞用户名即可走 OIDC 进管理员）。
- **存储**：共享文件夹（文档、下载、传输、照片）挂进主人主目录的子目录，Web 客户端和 SFTP 的根目录就是这几个文件夹，传进来的文件别的插件共用；数据库、备份和所有用户主目录在应用数据目录里。
- **SFTP 端口**：经 `lan.client` 提供第三方客户端的连接信息（地址、用户名、密码），由核心生成密码。按平台规则，声明了 `lan.client` 的局域网端口默认关，用户在插件详情里打开开关后才发布。
- **健康检查**：`wget` 访问 httpd 的 `/healthz`（真实可用性，不只是进程活着）。

## 图标

`icon.png` 取自上游仓库 `img/logo.png`，按原样使用（仅等比缩放并置于白色底上）。SFTPGo 的名称和标志是 Nicola Murino（drakkan）的标志，本插件与上游没有隶属或背书关系。来源、版权和许可见 [NOTICE](NOTICE)。

## 开发

流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

```bash
scripts/check.sh --official
scripts/dev.sh probes   # 对已装的开发环境跑探针
scripts/dev.sh smoke    # 端到端冒烟
```
