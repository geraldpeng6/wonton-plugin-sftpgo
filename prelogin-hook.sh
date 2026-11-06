#!/bin/sh
# 云吞插件：SFTPGo 的 pre-login hook（上游动态建号机制，见 docs.sftpgo.com/latest/oidc/）。
# SFTPGo 在每次用户登录前调用本脚本：SFTPGO_LOGIND_USER 是用户 JSON（不存在时 id 为 0），
# 标准输出是要保存的完整用户 JSON；空输出表示不做任何改动。
#
# 用途只有一个：OIDC 登录的用户在 SFTPGo 里还没有账号时，用身份提供方认出的用户名建号，
# 并把插件的共享文件夹挂成虚拟文件夹。已存在的用户只补缺失的虚拟文件夹（插件升级新增
# 共享文件夹时），其余一律不碰——密码、配额这些改动都可能来自用户自己。
set -eu

in="${SFTPGO_LOGIND_USER:-}"
[ -n "$in" ] || exit 0

shares='["documents","downloads","transfers","photos"]'

id="$(printf '%s' "$in" | jq -r '.id // 0')"
username="$(printf '%s' "$in" | jq -r '.username // empty')"
[ -n "$username" ] || exit 0

if [ "$id" = "0" ]; then
  jq -n \
    --arg username "$username" \
    --arg password "${WONTON_SFTP_PASSWORD:-}" \
    --argjson shares "$shares" \
    '{
      username: $username,
      home_dir: ("/srv/sftpgo/data/" + $username),
      status: 1,
      password: $password,
      permissions: {"/": ["*"]},
      virtual_folders: [$shares[]
        | {name: ., mapped_path: ("/shares/" + .), virtual_path: ("/" + .), quota_size: 0, quota_files: 0}]
    }'
else
  # 已有用户：只补缺失的虚拟文件夹；一个不缺就输出空（SFTPGo 视为无改动）。
  printf '%s' "$in" | jq -r --argjson shares "$shares" '
    . as $user
    | [$shares[]
       | select(. as $name | ($user.virtual_folders // []) | map(.name) | index($name) | not)] as $missing
    | if ($missing | length) == 0 then
        ""
      else
        ($user
         | .virtual_folders = ((.virtual_folders // [])
           + [$missing[]
              | {name: ., mapped_path: ("/shares/" + .), virtual_path: ("/" + .), quota_size: 0, quota_files: 0}]))
        | tostring
      end'
fi
