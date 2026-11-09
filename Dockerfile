# Clever Cloud xray (VLESS+WS) — B 路线 Docker 镜像
# 多阶段构建：官方 xray 镜像只拷二进制，叠到带 shell 的 Alpine。
# 官方镜像是 distroless、无 shell，直接用它起不来（也跑不了 entrypoint），
# 所以必须把二进制拷出来。不要把 UUID/WS 路径写进镜像，
# 它们只在运行时由环境变量 UUID / WS_PATH 注入（见 entrypoint.sh）。
#
# Clever Cloud 部署方式（部署时以面板为准，见 README.md）：
#   Docker 应用。部署来源：Git 推送（git push clever master）或 GitHub 仓库。
#   公开仓库只放 Dockerfile + entrypoint.sh + proxy.py，绝不放凭据文件
#   （UUID/WS_PATH 只在面板环境变量里设）。不要为此新建/动用主人自己的 GitHub。
#   环境变量在面板里设，改完要重新部署才生效。
#
# 端口：Clever Cloud 要求 Docker 容器监听 8080（HTTP 流量），
#   entrypoint 优先读 $PORT，未注入默认 8080。
#   平台给应用分配域名 + 自动 HTTPS（443），TLS 由平台边缘终止，
#   xray 内部只讲明文 WS/XHTTP。
#   就绪检查：proxy.py 在 $PORT 上接管：GET /healthz 与 GET / 在 xray 存活时
#   返回 200，否则 503（xray 的 WS 入站对普通 GET / 回 404）。
#
# 固定 xray 版本，避免 latest 在重建时悄悄变版本。
# 当前 pin：26.10.31（与 Cloady / RumptyCloud / HostStack / DockHosting / Suga / Voroa 包同一版本）。
ARG XRAY_VERSION=26.10.31

# ---- stage 1: 官方 xray 镜像，只取二进制 + geodat ----
FROM ghcr.io/xtls/xray-core:${XRAY_VERSION} AS xray

# ---- stage 2: 带 shell 的 Alpine 运行时 ----
FROM alpine:3.22

# ca-certificates：xray 出站若走 TLS 域名需要；curl 仅用于本地调试，不作他用。
# python3：proxy.py 在 $PORT 上做健康检查（GET /healthz、GET / 返回 200）
# 并把其余流量原样代理给 xray（xray 本身对 GET / 回 404，过不了平台就绪检查）。
RUN apk add --no-cache ca-certificates curl python3 \
    && update-ca-certificates

# 官方镜像里的二进制与数据文件位置：
#   二进制 /usr/local/bin/xray ，geodat /usr/local/share/xray/*.dat
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray/ /usr/local/share/xray/
ENV XRAY_LOCATION_ASSET=/usr/local/share/xray

# entrypoint：容器启动时按 $PORT / $UUID / $WS_PATH 生成配置并拉起 xray。
# 配置写到 /tmp（任何标准 Docker 宿主都可写）。
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY proxy.py /usr/local/bin/proxy.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/xray

# 端口：Clever Cloud 要求容器监听 8080（HTTP）。EXPOSE 8080 只是声明。
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
