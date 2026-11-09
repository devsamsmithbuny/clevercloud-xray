#!/bin/sh
# Clever Cloud xray entrypoint — B 路线
# 容器启动时按环境变量生成 xray 配置，拉起 VLESS+WS（默认）或 VLESS+XHTTP（回退）。
#
# 环境变量（面板里注入，见 README.md；改完要重新部署才生效）：
#   PORT            平台注入（Clever Cloud Docker 容器须监听 8080，部署时以面板为准）；
#                   未注入默认 8080。监听 0.0.0.0:$PORT，绝不写死。
#   UUID            必需，VLESS 客户端 id。只存凭据文件 / 平台密文变量，不进镜像、不进日志。
#   WS_PATH         必需，WS/XHTTP 的 URL 路径，如 /<随机串>。不含域名、不含查询串。
#   XRAY_TRANSPORT  可选：ws（默认）| xhttp。WS 两次被网关伤到后改 xhttp 重部署即可，不用重建镜像。
#   LOGLEVEL        可选：warning（默认）| info | debug | error | none
#
# 关键约束：
#   - 配置写到 /tmp（标准 Docker 宿主可写；不在镜像里写配置）。
#   - TLS 由 Clever Cloud 平台边缘终止（平台域名自动 HTTPS，对外 443）：
#     xray 内部只讲明文 WS/XHTTP，streamSettings 里不要再配 TLS。
#   - 就绪检查：平台会轮询健康检查路径并要求 2xx；xray 的 WS 入站对普通 GET /
#     回 404，所以由 proxy.py 在 $PORT 上接管：GET /healthz 与 GET / 在 xray
#     存活时返回 200，否则 503。
#     其余流量由 proxy.py 原样代理给 xray，WebSocket 握手不受影响。
#   - 不要在 entrypoint 里另起一个 HTTP 服务抢 $PORT。
set -eu

PORT="${PORT:-8080}"
UUID="${UUID:?UUID env var is required}"
WS_PATH="${WS_PATH:?WS_PATH env var is required}"
TRANSPORT="${XRAY_TRANSPORT:-ws}"
LOGLEVEL="${LOGLEVEL:-warning}"

# WS_PATH 统一成 / 开头、无尾随斜杠
case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac

# xray 只监听内网 10000 端口；$PORT 由 proxy.py 接管：
# GET /healthz 与 GET / 返回 200（平台就绪检查要求 2xx，xray 本身回 404），
# 其余流量原样代理给 xray（WebSocket 握手不受影响）。
XRAY_PORT=10000

mkdir -p /tmp/xray
CONFIG=/tmp/xray/config.json

if [ "$TRANSPORT" = "xhttp" ]; then
  STREAM_SETTINGS=$(cat <<EOF
"network": "xhttp",
      "xhttpSettings": {
        "path": "$WS_PATH",
        "mode": "packet-up"
      }
EOF
)
elif [ "$TRANSPORT" = "ws" ]; then
  STREAM_SETTINGS=$(cat <<EOF
"network": "ws",
      "wsSettings": {
        "path": "$WS_PATH"
      }
EOF
)
else
  echo "entrypoint: unsupported XRAY_TRANSPORT='$TRANSPORT' (want ws|xhttp)" >&2
  exit 1
fi

# 生成配置：只写 /tmp，绝不把 UUID 打到 stdout（xray -test 的输出不含配置内容）。
cat > "$CONFIG" <<EOF
{
  "log": { "loglevel": "$LOGLEVEL" },
  "inbounds": [
    {
      "port": $XRAY_PORT,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        $STREAM_SETTINGS
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": {} } ]
}
EOF

echo "entrypoint: transport=$TRANSPORT port=$PORT xray-port=$XRAY_PORT path-length=${#WS_PATH} (uuid/path not logged)"
# 先校验配置再拉起；校验失败直接退出，让平台按失败部署处理，不要带病上线。
/usr/local/bin/xray run -test -config "$CONFIG"
/usr/local/bin/xray run -config "$CONFIG" &
XRAY_PID=$!
# 等 xray 起来再交棒给 proxy（proxy 的 /healthz 会据此返回 200/503）。
sleep 2
if ! kill -0 "$XRAY_PID" 2>/dev/null; then
  echo "entrypoint: xray exited early" >&2
  exit 1
fi
exec python3 /usr/local/bin/proxy.py
