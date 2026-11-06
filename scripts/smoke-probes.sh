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

# 本文件在两套环境里跑：dev.sh probes 导出 SMOKE_*（模板约定的名字），e2e 的 smoke.sh
# 导出 E2E_*（同名含义的变量，另加 SMOKE_STATE；赋值发生在 source 本文件之后）。
# 这里用惰性求值，函数运行时才解析，不能在 source 时做静态快照。
smoke_jar() { printf '%s' "${SMOKE_JAR:-${E2E_JAR:-}}"; }
smoke_owner() { printf '%s' "${SMOKE_OWNER:-${E2E_OWNER:-owner}}"; }
smoke_instance() { printf '%s' "${SMOKE_INSTANCE:-${E2E_INSTANCE:-}}"; }
smoke_slug() { printf '%s' "${SMOKE_SLUG:-${E2E_SLUG:-}}"; }

# dweb / 落在 SFTPGo 自己的页面：还没有管理员时是 WebAdmin 初始化页（应用把客户端登录重定向过去），
# 有管理员时是 WebClient 登录页（带 OpenID 入口）。两种都是应用真实页面。
web_assert() { grep -q 'data-i18n="title.setup"\|web/client/oidclogin'; }

# SMOKE_STATE 在 dev.sh probes 里是目录（.wonton），在 e2e 里是文件：标记存成跟它配套的路径。
marker_file() { if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/sftpgo-data-marker"; else printf '%s' "${SMOKE_STATE}.sftpgo-marker"; fi; }

csrf_from() { # <文件页 HTML>：页面内嵌的 X-CSRF-TOKEN
  sed -n "s/.*'X-CSRF-TOKEN': '\([^']*\)'.*/\1/p" <<<"$1" | head -1
}

client_session() { # 确保会话 jar（当前环境默认那份）里有 WebClient 会话，输出文件页
  local page jar
  jar="$(smoke_jar)"
  page="$(dweb /web/client/oidclogin -L -b "$jar" -c "$jar" -w '\n%{http_code} %{url_effective}')" ||
    { echo "OIDC 链失败：$page"; return 1; }
  if grep -q 'file_manager_list' <<<"$page"; then
    printf '%s' "$page"
  else
    echo "落点不是文件页（末行是状态码和最终 URL）：$(tail -1 <<<"$page")；页面开头：$(head -c 600 <<<"$page")"
    return 1
  fi
}

identity_check() { # 走完整 OIDC 链落到 WebClient 文件页，页面回显登录用户名
  local page
  page="$(client_session)" || {
    echo "$page"
    # 应用侧日志：hook 报错、令牌校验失败都在这里
    docker logs "wonton-$(smoke_instance)--$(smoke_slug)--sftpgo" 2>&1 | tail -25 || true
    return 1
  }
  grep -qF "$(smoke_owner)" <<<"$page" ||
    { echo "文件页没回显用户 $(smoke_owner)：$(head -c 200 <<<"$page")"; return 1; }
}

data_write() { # 用 WebClient 的上传接口在用户主目录写一个带随机标记的文件
  local marker page csrf mf code body
  mf="$(marker_file)"
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s' "$marker" >"$mf"
  page="$(client_session)" || { echo "$page"; return 1; }
  csrf="$(csrf_from "$page")"
  [[ -n "$csrf" ]] || { echo "文件页里没有 CSRF token"; return 1; }
  body="$(dweb "/web/client/file?path=/wonton-smoke-$marker.txt" -b "$(smoke_jar)" \
    -H "X-CSRF-TOKEN: $csrf" -H 'Content-Type: application/octet-stream' \
    --data-binary "$marker" -w '\n%{http_code}' 2>&1)" || true
  code="$(tail -1 <<<"$body")"
  [[ "$code" == 2* ]] || {
    echo "上传失败（$code）：$(head -c 300 <<<"$body")"
    docker logs "wonton-$(smoke_instance)--$(smoke_slug)--sftpgo" 2>&1 | grep -i "csrf\|forbidden\|permission\|error" | tail -8 || true
    return 1
  }
}

data_check() { # 升级/重装后重新走 OIDC，读回文件内容核对标记
  local marker page csrf got mf
  mf="$(marker_file)"
  marker="$(cat "$mf" 2>/dev/null)"
  [[ -n "$marker" ]] || { echo "没有 data-write 留下的标记（$mf）"; return 1; }
  page="$(client_session)" || { echo "$page"; return 1; }
  csrf="$(csrf_from "$page")"
  [[ -n "$csrf" ]] || { echo "文件页里没有 CSRF token"; return 1; }
  got="$(dweb "/web/client/file?path=/wonton-smoke-$marker.txt" -b "$(smoke_jar)" \
    -H "X-CSRF-TOKEN: $csrf")" || { echo "读不回文件：$got"; return 1; }
  [[ "$got" == "$marker" ]] || { echo "文件内容对不上：$(head -c 120 <<<"$got")"; return 1; }
}
