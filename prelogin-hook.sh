#!/bin/sh
# 云吞插件：SFTPGo 的 pre-login hook（上游动态建号机制，见 docs.sftpgo.com/latest/oidc/）。
# SFTPGo 在每次用户登录前调用本脚本：SFTPGO_LOGIND_USER 是用户 JSON（不存在时 id 为 0），
# 标准输出是要保存的完整用户 JSON；空输出表示不做任何改动。
#
# 注意：SFTPGo 起 hook 时不继承容器环境（internal/command.GetConfig 只给 config.Env，
# 默认为空），所以 jq 用绝对路径，SFTP 密码从 configs 写入的文件里读。
#
# 用途一：OIDC 登录的用户在 SFTPGo 里还没有账号时，用身份提供方认出的用户名建号。
# 主目录在 users_base_dir（/srv/sftpgo/data）下，和 compose 里挂进来的共享文件夹子目录
# 对齐，Web 客户端和 SFTP 看到的根目录就是那几个共享文件夹。
#
# 用途二：给账号带邮箱。SFTPGo 发信（找回密码等）收件人取自账号里的邮箱，而 SFTPGo 的
# OIDC 映射不落 email 声明，邮箱只能在这里带上。binding 配了 custom_fields=["email"]
# 后，SFTPGo 把令牌里的 email 声明经 SFTPGO_LOGIND_USER 的 oidc_custom_fields 递给
# hook（internal/httpd/oidc.go 的 custom_fields 提取、dataprovider.go 的
# OIDCCustomFields；保存前上游会清掉这个字段，不会入库）：云吞给每个人的 email 声明
# 就是其内部邮箱 <用户名>@wonton.internal，主人家人一样，按声明填即可。新账号建号时
# 写上；老账号（内部邮箱上线前建的）在邮箱还空着时补一次——只补空值，用户自己改过的
# 不碰。声明拿不到（非 OIDC 登录、声明缺失）就不填。
# 除邮箱外，已存在的用户一律不碰——密码、配额这些改动都可能来自用户自己。
set -eu

in="${SFTPGO_LOGIND_USER:-}"
[ -n "$in" ] || exit 0

JQ=/usr/bin/jq

id="$(printf '%s' "$in" | $JQ -r '.id // 0')"
username="$(printf '%s' "$in" | $JQ -r '.username // empty')"
[ -n "$username" ] || exit 0

# 建号时给用户的 SFTP 密码：configs 写入的文件，内容是 secrets 生成的值（去尾换行）。
# 拿不到就留空：WebClient 照常能用，SFTP 要等用户在 WebClient 里自己改密码。
password="$(cat /etc/sftpgo/wonton-sftp-password 2>/dev/null || true)"

# 登录者的内部邮箱：来自 OIDC 的 email 声明（经 custom_fields 传入）。
email="$(printf '%s' "$in" | $JQ -r '.oidc_custom_fields.email // empty')"

if [ "$id" != "0" ]; then
  # 已存在的账号：只在邮箱还空着时按声明补上，其余改动一律不做。
  [ -n "$email" ] || exit 0
  current="$(printf '%s' "$in" | $JQ -r '.email // empty')"
  [ -z "$current" ] || exit 0
  printf '%s' "$in" | $JQ --arg email "$email" '.email = $email'
  exit 0
fi

$JQ -n \
  --arg username "$username" \
  --arg password "$password" \
  --arg email "$email" \
  '{
    username: $username,
    home_dir: ("/srv/sftpgo/data/" + $username),
    status: 1,
    password: $password,
    permissions: {"/": ["*"]}
  } | if $email != "" then .email = $email else . end'
