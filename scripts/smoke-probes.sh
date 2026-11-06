# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测，跟着插件走。没写的项会 FAIL 并给出写法，不会默认放行。
#
# 页面：web_assert 从标准输入读页面，命中的确是应用的真实页面时返回 0。
# 身份：identity_check 用应用自己的“当前用户”接口断言认出的是用户管理员。没有用户体系时写 IDENTITY_NA=1，
#       并在 SMOKE_NOTE 里写原因。dweb / web_get 是带用户会话的请求助手，可继续走应用自己的登录链。
# 工具：MCP_TOOL 写一个只读工具名（可带插件前缀），MCP_ARGS 是 JSON 参数；mcp_assert 从标准输入读调用结果。
#       要断言多个工具时改成写 mcp_check；调用前要备数据时写 before_mcp。
# 数据：合并前要验证“升级/重装不丢用户数据”时写 data_write 和 data_check（两个都写才跑）：data_write 用随机标记写
#       一条数据并把标记原样存进 $SMOKE_STATE，data_check 读回标记去应用里找，对不上就打印看到了什么并返回非 0。
#       应用不存用户数据时写 DATA_NA=1（两项记 N/A）。
# 装之前要准备（如先配出口代理）：写 before_install。

# dweb / 落在 WebClient 登录页；页面上有 OpenID 登录入口（/web/client/oidclogin）才说明 OIDC 接上了。
web_assert() { grep -q 'web/client/oidclogin'; }

identity_check() { # 走完整 OIDC 链落到 WebClient 文件页，页面回显登录用户名
  local page
  # /web/client/oidclogin → 核心身份提供方（核心会话自动放行）→ /web/oidc/redirect →
  # pre-login hook 首次登录建号 → WebClient 文件页。
  page="$(dweb /web/client/oidclogin -L)" || { echo "OIDC 链失败：$page"; return 1; }
  grep -q 'file_manager_list' <<<"$page" ||
    { echo "落点不是 WebClient 文件页：$(head -c 200 <<<"$page")"; return 1; }
  grep -qF "$SMOKE_OWNER" <<<"$page" ||
    { echo "文件页没回显用户 $SMOKE_OWNER：$(head -c 200 <<<"$page")"; return 1; }
}

csrf_from() { # <文件页 HTML>：页面内嵌的 X-CSRF-TOKEN
  sed -n "s/.*'X-CSRF-TOKEN': '\([^']*\)'.*/\1/p" <<<"$1" | head -1
}

client_session() { # 确保 $1（cookie jar）里有 WebClient 会话，输出文件页
  local page
  page="$(dweb /web/client/oidclogin -L -b "$1" -c "$1")" ||
    { echo "OIDC 链失败：$page"; return 1; }
  grep -q 'file_manager_list' <<<"$page" || { echo "落点不是文件页：$(head -c 200 <<<"$page")"; return 1; }
  printf '%s' "$page"
}

data_write() { # 用 WebClient 的上传接口在用户主目录写一个带随机标记的文件
  local marker page csrf
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s' "$marker" >"$SMOKE_STATE/sftpgo-data-marker"
  page="$(client_session "$SMOKE_JAR")" || { echo "$page"; return 1; }
  csrf="$(csrf_from "$page")"
  [[ -n "$csrf" ]] || { echo "文件页里没有 CSRF token"; return 1; }
  dweb "/web/client/file?path=/wonton-smoke-$marker.txt" -b "$SMOKE_JAR" \
    -H "X-CSRF-TOKEN: $csrf" -H 'Content-Type: application/octet-stream' \
    --data-binary "$marker" >/dev/null ||
    { echo "上传失败"; return 1; }
}

data_check() { # 升级/重装后重新走 OIDC，读回文件内容核对标记
  local marker page csrf got
  marker="$(cat "$SMOKE_STATE/sftpgo-data-marker" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "没有 data-write 留下的标记"; return 1; }
  page="$(client_session "$SMOKE_JAR")" || { echo "$page"; return 1; }
  csrf="$(csrf_from "$page")"
  [[ -n "$csrf" ]] || { echo "文件页里没有 CSRF token"; return 1; }
  got="$(dweb "/web/client/file?path=/wonton-smoke-$marker.txt" -b "$SMOKE_JAR" \
    -H "X-CSRF-TOKEN: $csrf")" || { echo "读不回文件：$got"; return 1; }
  [[ "$got" == "$marker" ]] || { echo "文件内容对不上：$(head -c 120 <<<"$got")"; return 1; }
}
