#!/bin/sh
# 云吞插件：SFTPGo 的 pre-login hook（上游动态建号机制，见 docs.sftpgo.com/latest/oidc/）。
# SFTPGo 在每次用户登录前调用本脚本：SFTPGO_LOGIND_USER 是用户 JSON（不存在时 id 为 0），
# 标准输出是要保存的完整用户 JSON；空输出表示不做任何改动。
#
# 注意：SFTPGo 起 hook 时不继承容器环境（internal/command.GetConfig 只给 config.Env，
# 默认为空），所以 jq 用绝对路径，SFTP 密码从 configs 写入的文件里读。
#
# 用途只有一个：OIDC 登录的用户在 SFTPGo 里还没有账号时，用身份提供方认出的用户名建号。
# 主目录在 users_base_dir（/srv/sftpgo/data）下，和 compose 里挂进来的共享文件夹子目录
# 对齐，Web 客户端和 SFTP 看到的根目录就是那几个共享文件夹。已存在的用户一律不碰——
# 密码、配额这些改动都可能来自用户自己。
set -eu

in="${SFTPGO_LOGIND_USER:-}"
[ -n "$in" ] || exit 0

JQ=/usr/bin/jq

id="$(printf '%s' "$in" | $JQ -r '.id // 0')"
username="$(printf '%s' "$in" | $JQ -r '.username // empty')"
[ -n "$username" ] || exit 0
[ "$id" = "0" ] || exit 0

# 建号时给用户的 SFTP 密码：configs 写入的文件，内容是 secrets 生成的值（去尾换行）。
# 拿不到就留空：WebClient 照常能用，SFTP 要等用户在 WebClient 里自己改密码。
password="$(cat /etc/sftpgo/wonton-sftp-password 2>/dev/null || true)"

$JQ -n \
  --arg username "$username" \
  --arg password "$password" \
  '{
    username: $username,
    home_dir: ("/srv/sftpgo/data/" + $username),
    status: 1,
    password: $password,
    permissions: {"/": ["*"]}
  }'
