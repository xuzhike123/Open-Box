#!/bin/sh
# Open-Box 发布打包脚本(POSIX sh,不依赖 bash;OpenWrt 上不会跑这个脚本,
# 但保持 POSIX 兼容以便在任意构建机——本机 macOS / GitHub Actions ubuntu-latest——
# 都能用 sh 直接执行,不引入 bashism)。
#
# 用法: sh scripts/build-release.sh <x64|arm64> <outdir>
#
# 产出 <outdir>/open-box-<version>-linux-<arch>.tar.gz 与同名 .sha256(留档用),
# 以及内容完全一致但文件名不带版本号的 <outdir>/open-box-linux-<arch>.tar.gz 与
# 同名 .sha256(install.sh / update.sh 靠这份稳定资产名通过
# github.com/<repo>/releases/latest/download/<asset> 直链拿最新版,不查询
# api.github.com——见 Important 5;两者内容字节级相同,只是文件名不同)。
# tarball 解开后即 /opt/open-box 的内容:
#   node/            musl Node 运行时(bin/node;lib/ 里是否捆绑 musl 版
#                    libstdc++.so.6 / libgcc_s.so.1 由 node 自己的 DT_NEEDED 决定,
#                    见下方 Critical 1)。SLIM=1 时 bin/node 是 UPX 压缩过的,
#                    体积约为原来的三成,代价见下文"精简打包(SLIM)"一节
#   panel/dist/      前端构建产物(SLIM=1 时为 no-fonts 构建,不含子集化字体)
#   panel/server/    corepack pnpm deploy --prod 产出的自包含后端
#   bin/sing-box     钦定版本 sing-box 二进制(SLIM=1 时按精简 tag 从源码现场编译)
#   openwrt/         initd/ 与 luci/(供安装脚本铺到系统路径)
#   uninstall.sh     卸载脚本(供 LuCI 兜底页与离线卸载调用)
#   update.sh        升级脚本(供 LuCI 兜底页一键升级调用;支持 --detach 后台执行)
#   meta.json        {version, singboxVersion, nodeVersion, arch, slim, nodeCompression,
#                     singboxBuild, singboxTags, builtAt}
#
# 关于体积:面向小 flash 路由器的"精简打包(SLIM)"默认开启,配置项与实测数据见下方
# 同名注释块。不想精简就 OPENBOX_SLIM=0。
#
# 关键事实,不要"简化"掉:OpenWrt 用 musl libc,官方 nodejs.org 的 linux-x64/arm64
# 二进制是 glibc 链接的,在路由器上起不来。必须用 unofficial-builds 的 musl 构建。
# sing-box 的架构命名和 Node 不同:x64 → amd64,arm64 → arm64,不要写反。
#
# sing-box 同样有这个坑:SagerNet 发布的不带后缀的 `sing-box-<ver>-linux-<arch>.tar.gz`
# 是动态链接 glibc 的(还附带 libcronet.so,实测 `file` 显示
# `interpreter /lib64/ld-linux-x86-64.so.2`),在 OpenWrt 上同样起不来。必须用带
# `-musl` 后缀的资产(`sing-box-<ver>-linux-<arch>-musl.tar.gz`),实测为 statically
# linked,不依赖任何动态链接器。
#
# 还有一层更深的坑(P6 终审 Critical 1):x64 的 musl Node 二进制本身又动态依赖
# `libstdc++.so.6`(`DT_NEEDED`:libstdc++.so.6 / libgcc_s.so.1 /
# libc.musl-x86_64.so.1),而 OpenWrt 官方 `DEFAULT_PACKAGES` 只带 `libgcc`、
# **不带 `libstdcpp`**——stock x86_64 镜像上 musl 加载器会直接报
# "Error loading shared library libstdc++.so.6",面板被 procd 无限重启。arm64
# 的 Node 不需要 libstdc++(其 C++ 运行时是静态链接进二进制的),但为防上游哪天
# 改成动态链接,两个架构都统一从 Alpine 拿 musl 版 libstdc++ / libgcc 塞进
# `node/lib/`,并配合 `openwrt/initd/openbox-panel` 里的
# `LD_LIBRARY_PATH=/opt/open-box/node/lib` 生效。
#
# 打包前会用 dt-needed.py(见同目录,纯 Python,不依赖 readelf/objdump——这两个
# 工具在 macOS 上要么没有要么对交叉架构 ELF 不可靠)解析 node 二进制的真实
# DT_NEEDED,任何一条"既不在 node/lib/ 里、也不属于 OpenWrt 默认可用集"的依赖都
# 会让构建直接失败——上游把 Node 换成依赖更多动态库的构建时,这里会当场炸,而不是
# 装到用户路由器上才发现面板起不来。
#
# 经验证:musl 的动态链接器(ldso/dynlink.c)把所有形如 `libc.*` /
# `libpthread.*` / `librt.*` / `libm.*` / `libdl.*` / `libutil.*` / `libxnet.*`
# 的 DT_NEEDED 名字都当成"指向 libc 自身"的保留名直接自解析,不做文件查找——这解释
# 了为什么 arm64 版 Node 的 DT_NEEDED 里出现的是字面量 `libc.so` 而不是
# `libc.musl-aarch64.so.1`:两者都无需在 node/lib/ 或系统里能找到同名文件,守卫的
# 允许集必须把这两种写法都算作"OpenWrt 默认可用"。

set -eu

NODE_VERSION="24.18.0"
SINGBOX_VERSION="1.13.14"

# ---- 供应链固定:版本号旁边固定对应资产的 sha256,下载后(含缓存命中时)校验,
# 不匹配就构建失败。避免"每次发版都重新下载却从不校验"的静默供应链口子——
# 这些哈希是筛查时从各自的官方发布源现取现算的(见下方各资产的 URL),下次升级
# 版本号务必同步重新计算并写入,不要凭旧哈希手改版本号。----
NODE_SHA256_X64="b818a0c3857272329cad4d575abf49e5060215858c9c3015437366f8adc7b85d"
NODE_SHA256_ARM64="b32d834975b3b38cf3226e220d3e1fcb5959047f0b2e184fffb709d9a69ed434"

# sing-box 官方不单独发布 checksums 文件,这两个哈希是从
# https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/ 下的
# sing-box-${SINGBOX_VERSION}-linux-{amd64,arm64}-musl.tar.gz 现下现算的(键名用
# sing-box 自己的架构命名 amd64/arm64,与下方 $SINGBOX_ARCH 对应)。
SINGBOX_SHA256_AMD64="d5b46de6498427bccfeb87dbafcde4dbefdfe35680020d07d286ad915f0bfb34"
SINGBOX_SHA256_ARM64="edec18488af35a93cf8b362063146fdd7b557ef9862710ee77a1f4adb5c70118"

# Alpine 的 musl 版 libstdc++ / libgcc(见文件头 Critical 1 说明)。latest-stable
# 仓库里 x86_64 与 aarch64 目前恰好是同一个包版本,但两个架构的资产是分别构建的
# 独立二进制,哈希必须分开固定,不能假设永远同版本号就直接共用。
ALPINE_GCC_PKG_VERSION="15.2.0-r5"
ALPINE_LIBSTDCPP_SHA256_X86_64="14c987b556f5385a5db18376e788c75f37d85321b8dc1920d926ea7daac1d6f6"
ALPINE_LIBSTDCPP_SHA256_AARCH64="2302e766d4e4926038ec166ecb85837ee884576115236ddb565e3a5fca4a11d7"
ALPINE_LIBGCC_SHA256_X86_64="393dcd32629f06d7d85409c272d142d0c082772d10b87ef55ee82f47de3be637"
ALPINE_LIBGCC_SHA256_AARCH64="369aaa6e9d099a737bad6dd3e6c2fe7bb1547ca26d22b94ee0411228f709b403"

# ---- 精简打包(SLIM):面向小 flash 设备 ----
# 默认开启。目标机型是 128MB NAND 的路由器(如红米 AX6:IPQ8071A / aarch64 /
# 512MB RAM,刷 ImmortalWrt 并扩容 overlay)。README 里"可用存储 ≥512MB"的门槛
# 这类机器根本达不到,按原样打出来的包也就装不进去。SLIM 做四件事,每一件都实测过:
#
#   1. 前端用 `pnpm run build:no-fonts`(--mode SystemUI)构建。默认构建会把
#      Fira Sans / MiSans / SarasaUiSC / PingFangSC 四套子集化字体全打进 dist,
#      实测 dist 9.99MB → 3.53MB(省 6.46MB)。代价是界面回落到浏览器系统字体,
#      桌面浏览器上中文显示照常。
#
#   2. sing-box 由源码按精简 build tag 现场编译,而不是下载 SagerNet 的全功能
#      发布资产(arm64 40.83MB)。tag 集合取自 OpenWrt packages feed 的
#      sing-box-tiny 变体,并补上 Open-Box 面板真正用到的协议。实测 arm64 静态二进制:
#        core only                     22.56MB
#        +gvisor                       26.31MB   tun(stack: mixed)
#        +clash_api                    26.69MB   面板流量/连接/穿透查询要靠它
#        +utls                         26.88MB   vless REALITY
#        +quic                         29.63MB   hysteria2 / tuic
#        +wireguard                    30.19MB   wireguard 端点
#        +grpc                         33.25MB   vmess/vless 的 grpc 传输
#      默认带 grpc:机场订阅里 grpc 节点很常见,缺这个 tag sing-box 会在 check
#      阶段直接 FATAL,整个内核起不来。想再省 3MB 就从 OPENBOX_SINGBOX_TAGS 里去掉。
#
#   3. arm64 不再无条件铺 node/lib 里的 musl libstdc++ / libgcc(2.82MB → 0.13MB)。
#      上游注释自己写过 arm64 的 Node 不需要 libstdc++——实测确实如此:arm64 的 musl
#      Node 24.18.0 的 DT_NEEDED 只有 libgcc_s.so.1 与 libc.so 两条。SLIM 下改为
#      "只铺 DT_NEEDED 真正点名要的库,而且只要点名了才去下对应的 Alpine 包",
#      由下面第 5 步的构建期守卫兜底——真缺了会当场构建失败,不会装到路由器上才发现
#      面板起不来。
#
#   4. 裁剪并压缩 node/bin/node。这是省得最多的一条:Node 运行时占了整包一半以上。
#      分两步,顺序不能反(见下面第 5b 步;数字是 arm64 Node 24.18.0 的实测值):
#        原始                            121.83MB
#        裁掉非 PT_LOAD 的节表/调试段     93.76MB   (scripts/elf-strip.py)
#        UPX --lzma 压缩后                23.85MB
#      代价必须说清楚:UPX 是 exec 时把整个二进制解压到匿名内存里跑的,面板进程
#      常驻内存会多出约一个 node 二进制的量(几十 MB)。AX6 有 512MB 内存,余量够;
#      内存只有 256MB 的机型请设 OPENBOX_UPX=0(裁剪省的 28MB 仍然拿得到),
#      OPENBOX_STRIP=0 可以把裁剪也一起关掉,只保留另外三条。
#
# 四条合计:arm64 解包后从约 179MB 降到约 70MB。
# 完全关掉精简行为:OPENBOX_SLIM=0 sh scripts/build-release.sh arm64 dist-release
SLIM="${OPENBOX_SLIM:-1}"

# sing-box 精简构建的 tag 集合(见上面第 2 条)。
SINGBOX_TAGS="${OPENBOX_SINGBOX_TAGS:-with_gvisor,with_quic,with_utls,with_clash_api,with_wireguard,with_grpc,badlinkname,tfogo_checklinkname0}"
# Go 交叉编译的目标架构名(sing-box 用 Go 的命名,与 $SINGBOX_ARCH 恰好一致)。
SINGBOX_GOARCH=""
# 裁剪 node 二进制里不加载的节表/调试段(见上面第 4 条,仅 SLIM=1 时生效)。
STRIP="${OPENBOX_STRIP:-1}"
# UPX 压缩 node 二进制(见上面第 4 条,仅 SLIM=1 时生效)。
UPX="${OPENBOX_UPX:-1}"
# --lzma 比默认的 NRV 压得更狠(同一个未裁剪二进制上实测 30.18MB vs 38.48MB),
# 启动时多花一点解压时间,对小 flash 更划算。
UPX_ARGS="${OPENBOX_UPX_ARGS:---lzma -9}"

usage() {
  echo "usage: $0 <x64|arm64> <outdir>" >&2
  exit 1
}

[ "$#" -eq 2 ] || usage
ARCH="$1"
OUTDIR_ARG="$2"

case "$ARCH" in
  x64)
    SINGBOX_ARCH="amd64"
    SINGBOX_GOARCH="amd64"
    ALPINE_ARCH="x86_64"
    NODE_SHA256="$NODE_SHA256_X64"
    SINGBOX_SHA256="$SINGBOX_SHA256_AMD64"
    ALPINE_LIBSTDCPP_SHA256="$ALPINE_LIBSTDCPP_SHA256_X86_64"
    ALPINE_LIBGCC_SHA256="$ALPINE_LIBGCC_SHA256_X86_64"
    ;;
  arm64)
    SINGBOX_ARCH="arm64"
    SINGBOX_GOARCH="arm64"
    ALPINE_ARCH="aarch64"
    NODE_SHA256="$NODE_SHA256_ARM64"
    SINGBOX_SHA256="$SINGBOX_SHA256_ARM64"
    ALPINE_LIBSTDCPP_SHA256="$ALPINE_LIBSTDCPP_SHA256_AARCH64"
    ALPINE_LIBGCC_SHA256="$ALPINE_LIBGCC_SHA256_AARCH64"
    ;;
  *)
    echo "ERROR: unsupported arch '$ARCH' (expected x64 or arm64)" >&2
    exit 1
    ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "ERROR: 需要 python3 来解析构建产物的 DT_NEEDED(见 dt-needed.py,构建期依赖守卫)" >&2
  exit 1
}

# SLIM 下 sing-box 是现场编译的,先确认构建机有够新的 Go——sing-box 的 go.mod
# 声明了 go 1.24.7。宁可在这里明确报错,也不要让 go build 半路抛一段难读的报错。
if [ "$SLIM" = "1" ]; then
  command -v go >/dev/null 2>&1 || {
    echo "ERROR: OPENBOX_SLIM=1 需要 Go 工具链来精简编译 sing-box(用 OPENBOX_SLIM=0 可退回官方发布资产)" >&2
    exit 1
  }
  GO_VERSION=$(go env GOVERSION 2>/dev/null | sed -n 's/^go//p')
  if ! awk -v v="$GO_VERSION" 'BEGIN { split(v, a, "."); if (a[1] > 1 || (a[1] == 1 && a[2] > 24) || (a[1] == 1 && a[2] == 24 && a[3] >= 7)) exit 0; exit 1 }'; then
    echo "ERROR: sing-box $SINGBOX_VERSION 要求 Go >= 1.24.7,当前构建机是 go${GO_VERSION:-未知}" >&2
    exit 1
  fi
fi

if [ "$SLIM" = "1" ] && [ "$UPX" = "1" ]; then
  command -v upx >/dev/null 2>&1 || {
    echo "ERROR: OPENBOX_UPX=1 需要 upx(apt-get install -y upx-ucl,或从 upx/upx releases 取官方二进制);" >&2
    echo "       不想装就设 OPENBOX_UPX=0——包会大到约 130MB,小 flash 机型装不下。" >&2
    exit 1
  }
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PANEL_DIR="$ROOT/panel"
CACHE_DIR="$ROOT/.build-cache"

mkdir -p "$CACHE_DIR" "$OUTDIR_ARG"
OUTDIR=$(CDPATH= cd -- "$OUTDIR_ARG" && pwd)

log() {
  echo "[build-release] $*" >&2
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# SLIM 用:删掉自包含后端里对运行毫无用处、却要跟着进 flash 的东西。
# 只删证据确凿的几类,不做"猜着瘦身":
#   - *.test.mjs 等测试文件,以及 node_modules 里的 test/tests/__tests__ 目录
#     (npm 生态里包内 test/ 就是上游测试,没有运行时会被 require)
#   - *.md / CHANGELOG*:LICENSE 一律保留——删许可证不是省空间,是找麻烦
#   - *.map:sourcemap 只在浏览器 devtools 里用得上
#   - pnpm 的 lockfile:部署产物不需要它
# node_modules/.bin 保留:里面是 pnpm 的符号链接,删了将来改用 npm script 启服务
# 会踩空,而它本身几乎不占空间。
prune_server_payload() {
  root="$1"
  [ -d "$root" ] || return 0
  find "$root" -type f \( -name '*.test.mjs' -o -name '*.test.js' -o -name '*.spec.js' \) -delete 2>/dev/null || true
  if [ -d "$root/node_modules" ]; then
    find "$root/node_modules" -type d \( -name test -o -name tests -o -name __tests__ -o -name __mocks__ \) -exec rm -rf {} + 2>/dev/null || true
  fi
  find "$root" -type f \( -name '*.md' -o -name '*.markdown' -o -name 'CHANGELOG*' -o -name '*.map' \) -delete 2>/dev/null || true
  rm -f "$root/pnpm-lock.yaml" 2>/dev/null || true
}

# 下载前先用 Range 请求探活(比 HEAD 更可靠:GitHub/S3 的预签名下载链接常常只对
# GET 方法签名,HEAD 会被拒绝而 GET 能成功);探活失败或下载失败都直接非零退出,
# 不留半成品。命中本地缓存(.build-cache/)时跳过网络请求,但——无论是缓存命中
# 还是刚下载完——都会校验 sha256;不匹配直接构建失败(供应链完整性,见 Important
# 6):不这样做的话,缓存目录一旦被污染(或者版本号改了但哈希没跟着改)就会被
# 无声无息地打进产物里,谁都不会发现。
fetch_cached() {
  url="$1"
  dest="$2"
  label="$3"
  expected_sha256="$4"

  if [ -s "$dest" ]; then
    log "命中缓存: $label ($(basename -- "$dest"))"
  else
    log "探活: $label"
    if ! curl -fsSL -o /dev/null --range 0-0 "$url"; then
      echo "ERROR: $label 不可达: $url" >&2
      exit 1
    fi

    log "下载: $label"
    tmp="$dest.part"
    rm -f "$tmp"
    if ! curl -fsSL -o "$tmp" "$url"; then
      rm -f "$tmp"
      echo "ERROR: 下载失败: $label ($url)" >&2
      exit 1
    fi
    mv "$tmp" "$dest"
  fi

  actual_sha256=$(sha256_of "$dest")
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    rm -f "$dest"
    echo "ERROR: $label 的 sha256 不匹配,已删除该文件(供应链校验失败,拒绝使用)" >&2
    echo "  URL:  $url" >&2
    echo "  期望: $expected_sha256" >&2
    echo "  实际: $actual_sha256" >&2
    echo "  如果是有意升级版本号,请重新下载并把新的 sha256 写回脚本顶部。" >&2
    exit 1
  fi
}

# ---- 版本号:优先用调用方传入的 OPENBOX_VERSION(CI 里由 tag 提供),
# 本地试跑则退化为 git describe,再退化为固定占位符。----
VERSION="${OPENBOX_VERSION:-}"
if [ -z "$VERSION" ] && command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  VERSION=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || true)
fi
[ -z "$VERSION" ] && VERSION="0.0.0-dev"

log "打包 open-box $VERSION,目标 linux-$ARCH(sing-box 架构名: $SINGBOX_ARCH)"

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/open-box-release.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT INT TERM

mkdir -p "$STAGE/node/lib" "$STAGE/panel" "$STAGE/bin" "$STAGE/openwrt"

# ---- 1. 构建前端 ----
# SLIM 走 build:no-fonts(--mode SystemUI,见文件头第 1 条):四套子集化字体不进 dist。
if [ "$SLIM" = "1" ]; then
  log "构建面板前端 (vite build,no-fonts 精简模式)..."
  (cd "$PANEL_DIR" && corepack pnpm run build:no-fonts)
else
  log "构建面板前端 (vite build)..."
  (cd "$PANEL_DIR" && corepack pnpm run build)
fi
cp -R "$PANEL_DIR/dist" "$STAGE/panel/dist"

# ---- 2. pnpm deploy 出自包含 server ----
log "打包面板后端 (pnpm deploy --prod)..."
(cd "$PANEL_DIR" && corepack pnpm --filter=./server deploy --prod "$STAGE/panel/server")

if [ "$SLIM" = "1" ]; then
  log "裁剪后端产物(测试、文档、sourcemap、lockfile)..."
  prune_server_payload "$STAGE/panel/server"
fi

# ---- 3. 下载并解出 musl Node ----
NODE_TARBALL="node-v${NODE_VERSION}-linux-${ARCH}-musl.tar.xz"
NODE_URL="https://unofficial-builds.nodejs.org/download/release/v${NODE_VERSION}/${NODE_TARBALL}"
NODE_CACHE="$CACHE_DIR/$NODE_TARBALL"
fetch_cached "$NODE_URL" "$NODE_CACHE" "musl Node $NODE_VERSION ($ARCH)" "$NODE_SHA256"

log "解出 Node 运行时..."
NODE_EXTRACT_DIR="$STAGE/.node-extract"
mkdir -p "$NODE_EXTRACT_DIR"
tar -xJf "$NODE_CACHE" -C "$NODE_EXTRACT_DIR"
NODE_INNER_DIR="$NODE_EXTRACT_DIR/node-v${NODE_VERSION}-linux-${ARCH}-musl"
if [ ! -f "$NODE_INNER_DIR/bin/node" ]; then
  echo "ERROR: Node tarball 内部布局与预期不符,找不到 $NODE_INNER_DIR/bin/node" >&2
  exit 1
fi
# 只留运行 `node server/index.mjs` 真正要用到的东西:bin/node 本身 + LICENSE。
# include/(native addon 头文件)、lib/node_modules/{npm,corepack}、share/(man 页)
# 路由器上用不到,却占掉 include+lib 近 80MB——路由器 flash 紧张,不值得白白带上。
mkdir -p "$STAGE/node/bin"
cp "$NODE_INNER_DIR/bin/node" "$STAGE/node/bin/node"
chmod +x "$STAGE/node/bin/node"
cp "$NODE_INNER_DIR/LICENSE" "$STAGE/node/LICENSE"
rm -rf "$NODE_EXTRACT_DIR"

# ---- 3b. 解析 node 真实的 DT_NEEDED,据此决定要铺哪几个 musl 动态库 ----
# 先解析、再决定要不要去下载 Alpine 的包。实测 arm64 的 musl Node 24.18.0 只点名
# libgcc_s.so.1 与 libc.so,libstdc++ 一个字节都不需要——那种情况下根本没必要去
# dl-cdn.alpinelinux.org 拉两个 apk 再解一遍。非 SLIM 走老路径(两个都铺),所以
# 这里仍然把 NEED_* 按"要铺"算。
log "解析 node 的 DT_NEEDED..."
NODE_NEEDED=$(python3 "$SCRIPT_DIR/dt-needed.py" "$STAGE/node/bin/node") || {
  echo "ERROR: 无法解析 $STAGE/node/bin/node 的 DT_NEEDED" >&2
  exit 1
}
# 去掉行尾可能带的 CR:Python 在 Windows 上写 stdout 是文本模式,会把每个 \n 变成
# \r\n,于是每一行都拖着个 \r,下面按行比对的 case 就会把 libgcc_s.so.1 判成"不在
# 允许集里",报出来的却是"依赖未捆绑进 node/lib/"——方向完全错了。Linux CI 上不会
# 触发,但本地用 Git bash 复现构建时会,而且排查成本远高于这一行。
NODE_NEEDED=$(printf '%s\n' "$NODE_NEEDED" | tr -d '\r')
NEED_STDCPP=0
NEED_LIBGCC=0
OLD_IFS=$IFS
IFS='
'
set -f
for lib in $NODE_NEEDED; do
  case "$lib" in
    libstdc++.so.*) NEED_STDCPP=1 ;;
    libgcc_s.so.*) NEED_LIBGCC=1 ;;
  esac
done
set +f
IFS="$OLD_IFS"
if [ "$SLIM" != "1" ]; then
  # 非 SLIM:保持老行为,两个架构都统一带上,不赌上游的链接方式。
  NEED_STDCPP=1
  NEED_LIBGCC=1
fi
log "DT_NEEDED 对 musl 库的需求:libstdc++=$NEED_STDCPP libgcc_s=$NEED_LIBGCC"

# ---- 4. 下载并解出 Alpine 的 musl 版 libstdc++ / libgcc(Critical 1)----
# apk 包本质是 gzip 的 tar,直接 tar -xzf 就能取出 usr/lib/ 下的 .so;不解 .PKGINFO
# 也不装 apk 工具本身。只有真的要点名铺库里至少一个时才做这一步(见上一步)。
if [ "$NEED_STDCPP" = "1" ] || [ "$NEED_LIBGCC" = "1" ]; then
  ALPINE_BASE_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/${ALPINE_ARCH}"
  ALPINE_EXTRACT_DIR="$STAGE/.alpine-extract"
  mkdir -p "$ALPINE_EXTRACT_DIR"

  # 只取真正要铺的那一个包:arm64 上往往只需要 libgcc,那就没必要把 2.7MB 的
  # libstdc++ 包也拉一遍、解一遍。
  if [ "$NEED_STDCPP" = "1" ]; then
    ALPINE_LIBSTDCPP_PKG="libstdc++-${ALPINE_GCC_PKG_VERSION}.apk"
    ALPINE_LIBSTDCPP_CACHE="$CACHE_DIR/alpine-${ALPINE_ARCH}-${ALPINE_LIBSTDCPP_PKG}"
    fetch_cached "$ALPINE_BASE_URL/$ALPINE_LIBSTDCPP_PKG" "$ALPINE_LIBSTDCPP_CACHE" \
      "Alpine musl libstdc++ $ALPINE_GCC_PKG_VERSION ($ALPINE_ARCH)" "$ALPINE_LIBSTDCPP_SHA256"
    log "解出 Alpine musl libstdc++..."
    tar -xzf "$ALPINE_LIBSTDCPP_CACHE" -C "$ALPINE_EXTRACT_DIR" usr/lib/
    if [ ! -e "$ALPINE_EXTRACT_DIR/usr/lib/libstdc++.so.6" ]; then
      echo "ERROR: Alpine apk 包内部布局与预期不符,找不到 libstdc++.so.6" >&2
      exit 1
    fi
    # -P 保留符号链接本身(libstdc++.so.6 -> libstdc++.so.6.0.x),不展开成两份拷贝。
    cp -P "$ALPINE_EXTRACT_DIR"/usr/lib/libstdc++.so.6* "$STAGE/node/lib/"
  fi

  if [ "$NEED_LIBGCC" = "1" ]; then
    ALPINE_LIBGCC_PKG="libgcc-${ALPINE_GCC_PKG_VERSION}.apk"
    ALPINE_LIBGCC_CACHE="$CACHE_DIR/alpine-${ALPINE_ARCH}-${ALPINE_LIBGCC_PKG}"
    fetch_cached "$ALPINE_BASE_URL/$ALPINE_LIBGCC_PKG" "$ALPINE_LIBGCC_CACHE" \
      "Alpine musl libgcc $ALPINE_GCC_PKG_VERSION ($ALPINE_ARCH)" "$ALPINE_LIBGCC_SHA256"
    log "解出 Alpine musl libgcc..."
    tar -xzf "$ALPINE_LIBGCC_CACHE" -C "$ALPINE_EXTRACT_DIR" usr/lib/
    if [ ! -e "$ALPINE_EXTRACT_DIR/usr/lib/libgcc_s.so.1" ]; then
      echo "ERROR: Alpine apk 包内部布局与预期不符,找不到 libgcc_s.so.1" >&2
      exit 1
    fi
    cp -P "$ALPINE_EXTRACT_DIR"/usr/lib/libgcc_s.so.1* "$STAGE/node/lib/"
  fi

  rm -rf "$ALPINE_EXTRACT_DIR"
else
  log "node 不需要捆绑任何 musl 动态库,跳过 Alpine 包的下载与铺装。"
fi

# ---- 5. 构建期依赖守卫(Critical 1):复核 node 二进制真实的 DT_NEEDED,任何一条
# 既没被捆绑进 node/lib/、又不属于 OpenWrt 默认可用集的依赖都直接构建失败。允许集:
#   - node/lib/ 里已捆绑的文件名(见上一步)
#   - libc.musl-*(Alpine/OpenWrt 风格 soname)与字面量 libc.so(musl 动态链接器把
#     libc./libpthread./librt./libm./libdl./libutil./libxnet. 开头的 NEEDED 名字
#     都当保留名直接自解析,不做文件查找——已用 musl 官方源码交叉验证,见文件头注释)
#   - libgcc_s.so.1(OpenWrt DEFAULT_PACKAGES 自带 libgcc)
log "复核 node 的 DT_NEEDED(构建期依赖守卫)..."

BAD_NEEDED=""
OLD_IFS=$IFS
IFS='
'
set -f  # 逐行取 NEEDED 名字,禁掉通配展开,避免万一某个库名里出现 */? 之类字符被误展开
for lib in $NODE_NEEDED; do
  case "$lib" in
    libc.musl-*|libc.so|libgcc_s.so.1) ;;
    *)
      if [ ! -e "$STAGE/node/lib/$lib" ]; then
        BAD_NEEDED="$BAD_NEEDED $lib"
      fi
      ;;
  esac
done
set +f
IFS="$OLD_IFS"
if [ -n "$BAD_NEEDED" ]; then
  echo "ERROR: node($ARCH) 的以下 DT_NEEDED 依赖既未捆绑进 node/lib/,又不属于 OpenWrt 默认可用集:$BAD_NEEDED" >&2
  echo "  上游 Node 构建可能新增了动态依赖。请在 node/lib/ 里补上对应的 musl 动态库," >&2
  echo "  或者(如果确认该库属于系统默认可用集)更新本脚本里的允许名单。" >&2
  exit 1
fi
log "DT_NEEDED 校验通过($ARCH): $(printf '%s' "$NODE_NEEDED" | tr '\n' ' ')"

# ---- 5b. 裁剪 + 压缩 node 二进制(SLIM,见文件头第 4 条)----
# 两步都必须排在第 5 步之后:守卫解析的是真实 ELF 的程序头,而这两步都会改变文件
# 形态(先裁掉节表、再整体压缩),顺序反了守卫会直接解析失败。
#
# 先裁后压,顺序不能反。实测 arm64 Node 24.18.0(121.83MB)里有 28.27MB 是
# .symtab / .strtab / .debug_*,它们不在任何 PT_LOAD 段里、运行时一个字节都用不到,
# 但照样会被 UPX 压进产物。裁掉再压 = 23.85MB,直接压 = 28.78MB,同一个二进制差 4.9MB。
# (上游自己的发布包里 node 正是 93.76MB,等于裁完的大小,说明他们也是 strip 过的。)
if [ "$SLIM" = "1" ] && [ "$STRIP" = "1" ]; then
  NODE_BYTES_BEFORE=$(wc -c < "$STAGE/node/bin/node")
  python3 "$SCRIPT_DIR/elf-strip.py" "$STAGE/node/bin/node" || {
    echo "ERROR: 裁剪 node 二进制失败(elf-strip.py)" >&2
    exit 1
  }
  NODE_BYTES_STRIPPED=$(wc -c < "$STAGE/node/bin/node")
  log "node 二进制裁剪:$((NODE_BYTES_BEFORE / 1024))KB -> $((NODE_BYTES_STRIPPED / 1024))KB"
fi

if [ "$SLIM" = "1" ] && [ "$UPX" = "1" ]; then
  NODE_BYTES_BEFORE=$(wc -c < "$STAGE/node/bin/node")
  log "UPX 压缩 node ($UPX_ARGS)..."
  upx $UPX_ARGS -q "$STAGE/node/bin/node" || {
    echo "ERROR: UPX 压缩 node 失败(可用 OPENBOX_UPX=0 跳过,但包会大到约 130MB)" >&2
    exit 1
  }
  # upx -t 是 UPX 自己的完整性校验,不会执行目标二进制,所以交叉架构下也能用。
  # 校验不过就当场失败,不把可能损坏的二进制打进产物。
  upx -t -q "$STAGE/node/bin/node" >/dev/null 2>&1 || {
    echo "ERROR: UPX 压缩后的 node 未通过 upx -t 完整性校验" >&2
    exit 1
  }
  NODE_BYTES_AFTER=$(wc -c < "$STAGE/node/bin/node")
  log "node 二进制压缩:$((NODE_BYTES_BEFORE / 1024))KB -> $((NODE_BYTES_AFTER / 1024))KB"
fi

# ---- 6. sing-box ----
if [ "$SLIM" = "1" ]; then
  # SLIM:从源码按精简 tag 现场编译(见文件头第 2 条),不下载 40.83MB 的全功能资产。
  command -v git >/dev/null 2>&1 || {
    echo "ERROR: OPENBOX_SLIM=1 需要 git 来取 sing-box 源码" >&2
    exit 1
  }
  SB_SRC="$CACHE_DIR/sing-box-src-$SINGBOX_VERSION"
  if [ -d "$SB_SRC/.git" ]; then
    log "命中缓存的 sing-box 源码: $SB_SRC"
  else
    log "克隆 sing-box v$SINGBOX_VERSION 源码..."
    rm -rf "$SB_SRC"
    git clone --depth 1 --branch "v$SINGBOX_VERSION" \
      https://github.com/SagerNet/sing-box.git "$SB_SRC" || {
      echo "ERROR: 克隆 sing-box 源码失败" >&2
      exit 1
    }
  fi

  log "精简编译 sing-box (GOARCH=$SINGBOX_GOARCH, tags: $SINGBOX_TAGS)..."
  (
    cd "$SB_SRC" &&
      CGO_ENABLED=0 GOOS=linux GOARCH="$SINGBOX_GOARCH" \
        go build -tags "$SINGBOX_TAGS" -trimpath \
          -ldflags "-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=$SINGBOX_VERSION" \
          -o "$STAGE/bin/sing-box" ./cmd/sing-box
  ) || {
    echo "ERROR: sing-box 精简编译失败" >&2
    exit 1
  }
  chmod +x "$STAGE/bin/sing-box"
  log "精简 sing-box 构建完成($(du -h "$STAGE/bin/sing-box" | awk '{print $1}'))"
else
  # ---- 原路径:下载并解出 sing-box(注意 x64→amd64 映射;必须是 -musl 资产,见上)----
  SINGBOX_TARBALL="sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}-musl.tar.gz"
  SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${SINGBOX_TARBALL}"
  SINGBOX_CACHE="$CACHE_DIR/$SINGBOX_TARBALL"
  fetch_cached "$SINGBOX_URL" "$SINGBOX_CACHE" "sing-box $SINGBOX_VERSION ($SINGBOX_ARCH)" "$SINGBOX_SHA256"

  log "解出 sing-box..."
  SINGBOX_EXTRACT_DIR="$STAGE/.singbox-extract"
  mkdir -p "$SINGBOX_EXTRACT_DIR"
  tar -xzf "$SINGBOX_CACHE" -C "$SINGBOX_EXTRACT_DIR"
  SINGBOX_BIN=$(find "$SINGBOX_EXTRACT_DIR" -type f -name sing-box | head -n 1)
  if [ -z "$SINGBOX_BIN" ]; then
    echo "ERROR: sing-box tarball 里找不到 sing-box 二进制" >&2
    exit 1
  fi
  cp "$SINGBOX_BIN" "$STAGE/bin/sing-box"
  chmod +x "$STAGE/bin/sing-box"
  rm -rf "$SINGBOX_EXTRACT_DIR"
fi

# ---- 7. 构建期依赖守卫(P6 复审 Minor):确认 sing-box 二进制真正静态链接。
# 上面第 6 步只是"下载了带 -musl 后缀的资产名",并不能保证 SagerNet 未来某天不会
# 把这份资产悄悄换成动态链接构建(第 5 步的 node DT_NEEDED 白名单守卫覆盖不到
# sing-box,只测了 node 自己的二进制)。dt-needed.py 已经在解析 ELF 程序头了,这里
# 复用同一份解析逻辑断言:既没有 PT_INTERP(没有指定动态链接器路径),也没有
# PT_DYNAMIC(没有动态段/DT_NEEDED 列表)——两者皆无才是真正的静态二进制。任何一个
# 存在都直接构建失败,而不是打进产物里到用户路由器上才发现起不来。
log "校验 sing-box 静态链接(构建期依赖守卫)..."
python3 "$SCRIPT_DIR/dt-needed.py" --assert-static "$STAGE/bin/sing-box" || {
  echo "ERROR: sing-box($ARCH) 不是纯静态链接(存在 PT_INTERP 或 PT_DYNAMIC 段)。" >&2
  echo "  SagerNet 的 -musl 资产可能已改成动态链接构建。请确认该资产的链接方式," >&2
  echo "  必要时改为像 node 一样把所需的 musl 动态库一并捆绑进 node/lib/ 或 bin/。" >&2
  exit 1
}
log "sing-box 静态链接校验通过($ARCH)。"

# ---- 8. 拷 openwrt/(initd 与 luci)----
log "拷贝 openwrt/ init 与 LuCI 文件..."
cp -R "$ROOT/openwrt/initd" "$STAGE/openwrt/initd"
cp -R "$ROOT/openwrt/luci" "$STAGE/openwrt/luci"

# ---- 8b. 卸载脚本 ----
# 随产物一起铺到 /opt/open-box/uninstall.sh:LuCI 兜底页要能在「面板已经坏了、
# 也可能没有外网」的情况下调起卸载,所以不能只依赖从 GitHub 现下。
log "拷贝 uninstall.sh..."
cp "$ROOT/scripts/uninstall.sh" "$STAGE/uninstall.sh"
chmod +x "$STAGE/uninstall.sh"

# ---- 8c. 升级脚本 ----
# 同理随产物铺到 /opt/open-box/update.sh:LuCI 兜底页的一键升级只能 exec 本地
# 文件,不能到 GitHub 上现下一份脚本再跑。install.sh 解包整个 tarball 到
# $INSTALL_ROOT,这份文件会跟着自动落地,不需要 install.sh 另外处理。
log "拷贝 update.sh..."
cp "$ROOT/scripts/update.sh" "$STAGE/update.sh"
chmod +x "$STAGE/update.sh"

# ---- 9. meta.json ----
# slim / nodeCompression / singboxBuild 让面板和排障能一眼看出这份产物是按哪种模式
# 打的——"装上去是 60MB 还是 130MB"全取决于这几个值,不该只能翻 CI 日志才知道。
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ "$SLIM" = "1" ]; then SLIM_JSON="true"; else SLIM_JSON="false"; fi
if [ "$SLIM" = "1" ] && [ "$UPX" = "1" ]; then NODE_COMPRESSION="upx"; else NODE_COMPRESSION="none"; fi
if [ "$SLIM" = "1" ]; then SINGBOX_BUILD="source-slim"; else SINGBOX_BUILD="official-release"; fi
cat > "$STAGE/meta.json" <<EOF
{
  "version": "$VERSION",
  "singboxVersion": "$SINGBOX_VERSION",
  "nodeVersion": "$NODE_VERSION",
  "arch": "$ARCH",
  "slim": $SLIM_JSON,
  "nodeCompression": "$NODE_COMPRESSION",
  "singboxBuild": "$SINGBOX_BUILD",
  "singboxTags": "$SINGBOX_TAGS",
  "builtAt": "$BUILT_AT"
}
EOF

# ---- 10. 打包:带版本号的资产(留档)+ 不带版本号的稳定资产名(install.sh /
# update.sh 依赖它,见 Important 5——两者内容完全一致,只是文件名不同,避免
# install/update 依赖 GitHub API 查询最新版本号)----
VERSIONED_NAME="open-box-${VERSION}-linux-${ARCH}.tar.gz"
STABLE_NAME="open-box-linux-${ARCH}.tar.gz"
VERSIONED_PATH="$OUTDIR/$VERSIONED_NAME"
STABLE_PATH="$OUTDIR/$STABLE_NAME"
log "打包 $VERSIONED_NAME..."
(cd "$STAGE" && tar -czf "$VERSIONED_PATH" node panel bin openwrt meta.json uninstall.sh update.sh)
cp "$VERSIONED_PATH" "$STABLE_PATH"

# ---- 11. sha256(分别对两个文件名各算一份,sha256sum -c 依赖文件名匹配)----
log "计算 sha256..."
(
  cd "$OUTDIR"
  for name in "$VERSIONED_NAME" "$STABLE_NAME"; do
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$name" > "$name.sha256"
    else
      shasum -a 256 "$name" > "$name.sha256"
    fi
  done
)

log "完成: $VERSIONED_PATH"
log "$(cat "$VERSIONED_PATH.sha256")"
log "稳定资产名: $STABLE_PATH"
log "$(cat "$STABLE_PATH.sha256")"

# ---- 12. 体积报告 ----
# 这次改造的核心指标就是"装到路由器上占多少",所以直接打在构建日志里:每个顶层目录
# 的未压缩体积 + 单独压一次后的体积,外加整包。省得每次都把产物拉下来再 du 一遍,
# 也方便在 CI 上直接看出哪次改动把体积吃回去了。
report_sizes() {
  log "体积明细(目录:未压缩 -> 单独 tar.gz 后,单位 MB)"
  for entry in node panel bin openwrt; do
    [ -e "$STAGE/$entry" ] || continue
    raw_kb=$(du -sk "$STAGE/$entry" | awk '{print $1}')
    packed_b=$(cd "$STAGE" && tar -czf - "$entry" 2>/dev/null | wc -c)
    log "$(printf '  %-8s %7.1f  ->  %6.1f' "$entry" "$(awk -v k="$raw_kb" 'BEGIN {print k/1024}')" "$(awk -v b="$packed_b" 'BEGIN {print b/1048576}')")"
  done
  raw_kb=$(du -sk "$STAGE" 2>/dev/null | awk '{print $1}')
  packed_kb=$(du -k "$VERSIONED_PATH" | awk '{print $1}')
  log "$(printf '  %-8s %7.1f  ->  %6.1f  (%s)' "合计" "$(awk -v k="$raw_kb" 'BEGIN {print k/1024}')" "$(awk -v k="$packed_kb" 'BEGIN {print k/1024}')" "$(basename "$VERSIONED_PATH")")"
}
report_sizes
