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

# 本文件在两套环境里跑（dev.sh probes 和 e2e 的 smoke.sh）。钩子可用面是套件契约：
# 变量 SMOKE_STATE、SMOKE_JAR、SMOKE_WEB_URL、SMOKE_OWNER、SMOKE_BASE、SMOKE_TOKEN、
# SMOKE_INSTANCE，助手 web_get、dweb。会话交给 dweb 自己管（e2e 在身份项前用 web_login
# 预热持久 jar；dev.sh probes 的 dweb 自带 SMOKE_JAR），探针不手动传 cookie，也不假设
# SMOKE_* 在每个钩子里都已导出。应用容器名从 docker ps 自取（id 派生前缀 com-sftpgo-sftpgo）。

# dweb / 落在 SFTPGo 自己的页面：还没有管理员时是 WebAdmin 初始化页（应用把客户端登录重定向过去），
# 有管理员时是 WebClient 登录页（带 OpenID 入口）。两种都是应用真实页面。
web_assert() { grep -q 'data-i18n="title.setup"\|web/client/oidclogin'; }

# SMOKE_STATE 在 dev.sh probes 里是目录（.wonton），在 e2e 里是文件：标记存成跟它配套的路径。
marker_file() { if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/sftpgo-data-marker"; else printf '%s' "${SMOKE_STATE}.sftpgo-marker"; fi; }

csrf_from() { # <文件页 HTML>：页面内嵌的 X-CSRF-TOKEN
  sed -n "s/.*'X-CSRF-TOKEN': '\([^']*\)'.*/\1/p" <<<"$1" | head -1
}

client_session() { # 走 dweb 的当前会话（e2e 已由 web_login 预热，dev.sh probes 的 dweb 自带 SMOKE_JAR），输出文件页
  local page
  page="$(dweb /web/client/oidclogin -L -w '\n%{http_code} %{url_effective}')" ||
    { echo "OIDC 链失败：$page"; return 1; }
  if grep -q 'file_manager_list' <<<"$page"; then
    printf '%s' "$page"
  else
    echo "落点不是文件页（末行是状态码和最终 URL）：$(tail -1 <<<"$page")；页面开头：$(head -c 600 <<<"$page")"
    return 1
  fi
}

identity_check() { # 走完整 OIDC 链落到 WebClient 文件页；dweb 的会话就是主人的（web_login 预热），
  # 到达文件页即 OIDC 映射和 pre-login 建号成立。不引用 SMOKE_OWNER：身份项路径契约变量未注入。
  local page
  page="$(client_session)" || {
    echo "$page"
    # 应用侧日志：hook 报错、令牌校验失败都在这里
    docker ps -aq --filter name=com-sftpgo-sftpgo | while read -r c; do docker logs "$c" 2>&1 | tail -25; done || true
    return 1
  }
}

data_write() { # 用 WebClient 的上传接口在用户主目录写一个带随机标记的文件
  local marker page csrf mf code body
  mf="$(marker_file)"
  marker="$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  printf '%s' "$marker" >"$mf"
  page="$(client_session)" || { echo "$page"; return 1; }
  csrf="$(csrf_from "$page")"
  [[ -n "$csrf" ]] || { echo "文件页里没有 CSRF token"; return 1; }
  body="$(dweb "/web/client/file?path=/wonton-smoke-$marker.txt" \
    -H "X-CSRF-TOKEN: $csrf" -H 'Content-Type: application/octet-stream' \
    --data-binary "$marker" -w '\n%{http_code}' 2>&1)" || true
  code="$(tail -1 <<<"$body")"
  [[ "$code" == 2* ]] || {
    echo "上传失败（$code）：$(head -c 300 <<<"$body")"
    docker ps -aq --filter name=com-sftpgo-sftpgo | while read -r c; do docker logs "$c" 2>&1 | grep -i "csrf\|forbidden\|permission\|error" | tail -8; done || true
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
  got="$(dweb "/web/client/file?path=/wonton-smoke-$marker.txt" \
    -H "X-CSRF-TOKEN: $csrf")" || { echo "读不回文件：$got"; return 1; }
  [[ "$got" == "$marker" ]] || { echo "文件内容对不上：$(head -c 120 <<<"$got")"; return 1; }
}

# ---------- 邮件（notify）：用应用自己的 SMTP 配置真发信，核对核心投进私聊（extra_check 由 e2e 冒烟跑） ----------

sftpgo_container() { # 应用容器名按核心规则拼（wonton-<实例>--com-sftpgo-sftpgo--sftpgo），查不到再按标签兜底
  local inst="${SMOKE_INSTANCE:-}"
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  if [[ -n "$inst" ]]; then
    local name="wonton-${inst}--com-sftpgo-sftpgo--sftpgo"
    docker inspect "$name" >/dev/null 2>&1 && { printf '%s\n' "$name"; return 0; }
  fi
  docker ps --format '{{.Names}}' \
    --filter label=wonton.plugin=com.sftpgo.sftpgo --filter label=wonton.service=sftpgo | head -1
}

core_container() { # 核心容器：名字按核心规则拼（wonton-<实例>--core），兜底走 compose 项目标签
  local inst="${SMOKE_INSTANCE:-}"
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  if [[ -n "$inst" ]]; then
    local name="wonton-${inst}--core"
    docker inspect "$name" >/dev/null 2>&1 && { printf '%s\n' "$name"; return 0; }
  fi
  local project
  project="$(docker inspect "$(sftpgo_container)" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)" ||
    { echo "读不到插件容器的 compose 项目"; return 1; }
  [[ -n "$project" ]] || { echo "读不到插件容器的 compose 项目"; return 1; }
  docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$project" |
    grep -E -- '--core$' | head -1
}

mailpit_messages() { # 经核心的网络栈读 Mailpit 收件箱 API（SMTP 25/HTTP 8025 都不发布到宿主）。
  # API 要 Basic 认证（core:<密钥>，密钥在核心数据目录，核心的 mailbox 组件生成）。
  local pwd
  pwd="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/mailpit/api-password"')" ||
    { echo "读不到 Mailpit API 密钥"; return 1; }
  docker run --rm --network "container:$(core_container)" curlimages/curl:8.23.0 --noproxy '*' -s \
    -u "core:$pwd" "http://mailpit.wonton.internal:8025/api/v1/messages?limit=50"
}

_ours_in_mailpit() { # <owner 邮箱>：SFTPGo 发的、还没被核心取走的信
  mailpit_messages | jq -r --arg f "com.sftpgo.sftpgo@plugins.wonton.internal" --arg t "$1" '
    [.messages[] | select((.From.Address == $f) and ([.To[].Address] | index($t)))] | length'
}

wonton_chat_events() { # <条数>：核心投递事件的房间最近消息。核心实测亚秒取走信件（投完即删），
  # 在 Mailpit 里几乎抓不到中间态，投进主人 Wonton 私聊的房间事件才是权威证据。
  local mu room adm
  mu="$(docker exec "$(core_container)" printenv WONTON_MATRIX_URL)"
  room="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-notice-room"')" ||
    { echo "读不到通知房间 id"; return 1; }
  adm="$(docker exec "$(core_container)" sh -c 'cat "$WONTON_DATA_DIR/core/matrix-admin-token"')" ||
    { echo "读不到 Matrix 管理令牌"; return 1; }
  docker run --rm --network "container:$(core_container)" curlimages/curl:8.23.0 --noproxy '*' -s \
    -H "Authorization: Bearer $adm" "$mu/_matrix/client/v3/rooms/$room/messages?limit=$1&dir=b"
}

_delivered_after() { # <插件 id> <发送时刻毫秒>：发送之后投进主人 Wonton 私聊的新邮件事件数
  wonton_chat_events 30 | jq -r --arg p "$1" --argjson ts "$2" '
    [.chunk[] | select(.origin_server_ts > $ts and .content["app.wonton.plugin_mail"].plugin_id == $p)] | length'
}

extra_check() { # 邮件专项：sftpgo smtptest 用应用配置真发一封（收件人主人的内部邮箱），核对核心
  # 投进私聊后把信取走；再发外部地址，核对应用拿到 SMTP 阶段的 550 失败。
  local container owner_email out i sent_at
  container="$(sftpgo_container)"
  [[ -n "$container" ]] || { echo "找不到 sftpgo 容器（wonton.instance 标签）"; return 1; }
  [[ -n "${SMOKE_OWNER:-}" ]] || { echo "缺 SMOKE_OWNER" >&2; return 1; }
  # 主人的内部邮箱：规范固定 <用户名>@wonton.internal（冒烟工具按形状拼；应用的账号邮箱由 pre-login
  # hook 按 OIDC 声明填，就是这个地址）。
  owner_email="$SMOKE_OWNER@wonton.internal"
  out="$(docker exec "$container" printenv SFTPGO_SMTP__HOST SFTPGO_SMTP__PORT SFTPGO_SMTP__FROM)" ||
    { echo "容器里没有 SFTPGO_SMTP_* 变量"; return 1; }
  grep -qx 'smtp.wonton.internal' <<<"$out" || { echo "SMTP host 不对：$out"; return 1; }
  grep -qx '25' <<<"$out" || { echo "SMTP port 不对：$out"; return 1; }
  grep -qx 'com.sftpgo.sftpgo@plugins.wonton.internal' <<<"$out" || { echo "SMTP from 不对：$out"; return 1; }
  echo "容器里 SMTP 三件套就位：$(head -c 120 <<<"$out" | tr '\n' ' ')"

  # 内部收件人：smtptest 同步发信；核心亚秒取走，直接等主人私聊里的投递事件
  sent_at="$(date +%s%3N)"
  out="$(docker exec "$container" sftpgo smtptest --recipient "$owner_email" 2>&1)" ||
    { echo "发给 $owner_email 失败：$out"; return 1; }
  echo "smtptest 发送成功：$(head -c 200 <<<"$out" | tr '\n' ' ')"
  local seen=0
  for i in {1..12}; do
    sleep 5
    out="$(_delivered_after com.sftpgo.sftpgo "$sent_at")" || { echo "$out"; return 1; }
    if [[ "$out" != 0 ]]; then seen=1; break; fi
  done
  [[ "$seen" == 1 ]] || { echo "等了 1 分钟没看到信投进主人的 Wonton 私聊（投递失败？）"; return 1; }
  for i in {1..12}; do
    sleep 5
    out="$(_ours_in_mailpit "$owner_email")" || { echo "$out"; return 1; }
    [[ "$out" == 0 ]] && break
    [[ "$i" == 12 ]] && { echo "信投进了私聊，但 Mailpit 里还有滞留（核心没删？）"; return 1; }
  done
  echo "信已投进主人的 Wonton 私聊，Mailpit 没有滞留"

  # 外部收件人：核心在 SMTP 阶段 550 拒收，smtptest 要带着失败退出
  if out="$(docker exec "$container" sftpgo smtptest --recipient wonton-smoke-external@example.com 2>&1)"; then
    echo "发往外部地址竟然成功：$(head -c 200 <<<"$out")"
    return 1
  fi
  grep -q '550' <<<"$out" || { echo "外部收件人的失败不是 550 拒收：$(head -c 300 <<<"$out")"; return 1; }
  echo "外部地址被核心在 SMTP 阶段 550 拒收，应用拿到失败"
}
