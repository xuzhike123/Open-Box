#!/bin/sh
# Open-Box 固件烘焙脚本:把精简版 Open-Box 直接打进 ImmortalWrt 固件镜像。
#
# 用法(在 Linux x86_64 构建机上;GitHub Actions 的 ubuntu-latest 可以直接跑):
#   sh scripts/build-firmware.sh <outdir> [profile]
#
#   profile 默认 redmi_ax6,即红米 AX6 的 "(OpenWrt expand layout)" 变体——
#   也就是社区说的"扩容布局"。设备刷的是 stock / 自定义 U-Boot 布局就传
#   redmi_ax6-stock。两者是两套分区方案,弄错会刷不进去(风险说明见本文件末尾
#   脚本输出,以及 README 的"烘焙进固件"一节)。
#
# 产出:<outdir>/immortalwrt-...-<profile>-squashfs-sysupgrade.bin 与同名 .sha256。
#
# ---------------------------------------------------------------------------
# 为什么固件路线比装 overlay 更好
#
# 装 overlay:63.2MB 未压缩内容全部落在可写的 UBIFS overlay 上,吃满用户那
# 80~120MB 的可写空间,而且为了压到 63MB 不得不对 node 用 UPX(代价:面板进程
# 常驻内存多几十 MB,且 UPX 产物在 aarch64 上没法在 x86 构建机上验活)。
#
# 烘焙进固件:内容进只读的 squashfs 层,由 xz 压缩,overlay 一个字节不占。
# 实测(arm64):
#     node 裁剪后 93.76MB  -> xz 23.61MB
#     sing-box 精简 33.25MB -> xz  8.16MB
#     panel 5.6MB           -> 约 1.5MB
#   净增 ≈ 33MB。基础镜像本身 15.0MB,所以新镜像约 48MB;扩容布局的 rootfs
#   约 102MB(社区实测),刷完还剩 50MB 上下给 overlay 与 data/。
#
# 而且这条路**不需要 UPX**:压缩交给 squashfs(xz)做得更好——UPX 之后的 node
# 已经是高熵数据,squashfs 几乎压不动,等于白白换来"多占内存 + 没法验活"两个
# 缺点。所以下面第一步刻意用 OPENBOX_UPX=0 打包,只保留"裁掉非加载节"那一步。
#
# ---------------------------------------------------------------------------
# 没做、也不该做的事
#
# - 不启用 sing-box 内核服务的开机自启:用户还没配任何东西,内核起来也没意义。
#   与 scripts/install.sh 的行为一致,只开面板。
# - 不把 update.sh / 面板里的"检查更新"当成升级手段:那套流程会把新版本解到
#   /opt/open-box 下再替换,而烘焙安装的 /opt/open-box 是只读 squashfs——
#   替换会把 63MB 拷进 overlay,白瞎了烘焙的意义。烘焙版升级应当重新刷固件。
# ---------------------------------------------------------------------------

set -eu

IMAGEBUILDER_RELEASE="24.10.0"
IMAGEBUILDER_TARGET="qualcommax"
IMAGEBUILDER_SUBTARGET="ipq807x"
IMAGEBUILDER_HOST="Linux-x86_64"
IMAGEBUILDER_ARCHIVE="immortalwrt-imagebuilder-${IMAGEBUILDER_RELEASE}-${IMAGEBUILDER_TARGET}-${IMAGEBUILDER_SUBTARGET}.${IMAGEBUILDER_HOST}.tar.zst"
IMAGEBUILDER_URL="https://downloads.immortalwrt.org/releases/${IMAGEBUILDER_RELEASE}/targets/${IMAGEBUILDER_TARGET}/${IMAGEBUILDER_SUBTARGET}/${IMAGEBUILDER_ARCHIVE}"
# 取自同一目录下的 sha256sums(2025-02-06 那份 release 的实测值)。
IMAGEBUILDER_SHA256="e046d4cc9d70e82ecfc3d5a02c9386e645db7def370205cf533e9c7e9b46fccb"

PROFILE_DEFAULT="redmi_ax6"
# PACKAGES 是**追加**到 ImageBuilder 默认包集上的(见 target/imagebuilder/files/Makefile
# 里的 BUILD_PACKAGES 拼装),所以这里只列默认没有、而 Open-Box 需要的东西:
#   kmod-tun / kmod-inet-diag  sing-box 的 tun 入站与 net-guard 要用;
#                              OpenWrt 自己的 sing-box 包也依赖这两个
#   ca-bundle                  订阅与规则集走 HTTPS
# 想额外装什么就往后加,想剔除默认包用 -pkgname(例如 -wpad-basic-mbedtls)。
EXTRA_PACKAGES="${OPENBOX_FIRMWARE_PACKAGES:-kmod-tun kmod-inet-diag ca-bundle}"

usage() {
  echo "usage: $0 <outdir> [profile]" >&2
  echo "  profile 默认 $PROFILE_DEFAULT(AX6 扩容布局);stock/U-Boot 布局用 redmi_ax6-stock" >&2
  exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
OUTDIR_ARG="$1"
PROFILE="${2:-$PROFILE_DEFAULT}"

log() { echo "[build-firmware] $*" >&2; }

die() {
  echo "[build-firmware] 错误:$*" >&2
  exit 1
}

# ---- 环境检查 ----
[ "$(uname -s)" = "Linux" ] || die "本脚本只能在 Linux x86_64 上跑:ImageBuilder 是 Linux 宿主工具"
[ "$(uname -m)" = "x86_64" ] || die "ImageBuilder 只有 Linux-x86_64 版本,当前是 $(uname -m)"
for tool in make python3 tar curl; do
  command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool"
done
command -v sha256sum >/dev/null 2>&1 || die "缺少 sha256sum"
# ImageBuilder 的归档是 .tar.zst,解包需要 zstd。
command -v zstd >/dev/null 2>&1 || die "缺少 zstd(解 .tar.zst 用:apt-get install -y zstd)"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CACHE_DIR="$ROOT/.build-cache"
mkdir -p "$CACHE_DIR"
OUTDIR=$(mkdir -p "$OUTDIR_ARG" && CDPATH= cd -- "$OUTDIR_ARG" && pwd)

sha256_of() {
  sha256sum "$1" | awk '{print $1}'
}

log "目标: profile=$PROFILE, 额外包=[$EXTRA_PACKAGES]"
log "产物目录: $OUTDIR"

# ---- 1. 先打一个"不开 UPX"的精简发布包 ----
# 复用发布脚本的全部裁剪与守卫(前端 no-fonts、sing-box 精简编译、DT_NEEDED 守卫、
# node 裁剪),只把 UPX 关掉——压缩交给固件里的 squashfs。
# 注意版本号:烘焙进固件时面板显示的版本号来自这份 meta.json。
PANEL_OUT="$CACHE_DIR/firmware-payload"
log "构建精简载荷(OPENBOX_SLIM=1 OPENBOX_UPX=0)..."
( cd "$ROOT" && OPENBOX_SLIM=1 OPENBOX_UPX=0 \
    sh scripts/build-release.sh arm64 "$PANEL_OUT" ) || die "构建精简载荷失败"

PAYLOAD_TAR="$PANEL_OUT/open-box-linux-arm64.tar.gz"
[ -f "$PAYLOAD_TAR" ] || die "找不到 $PAYLOAD_TAR"

# ---- 2. 组装 ImageBuilder 的 FILES 目录 ----
# FILES= 的语义是"该目录的内容原样铺到 rootfs 根",所以这里的目录结构就是
# 目标系统上的绝对路径去掉开头的 /。
FILES_DIR="$CACHE_DIR/firmware-files"
log "组装 FILES 目录..."
rm -rf "$FILES_DIR"
mkdir -p "$FILES_DIR/opt/open-box" "$FILES_DIR/etc/init.d" "$FILES_DIR/etc/uci-defaults" \
  "$FILES_DIR/www/luci-static/resources/view/openbox" \
  "$FILES_DIR/usr/share/luci/menu.d" "$FILES_DIR/usr/share/rpcd/acl.d"

tar -xzf "$PAYLOAD_TAR" -C "$FILES_DIR/opt/open-box"

# initd
cp "$ROOT/openwrt/initd/openbox" "$FILES_DIR/etc/init.d/openbox"
cp "$ROOT/openwrt/initd/openbox-panel" "$FILES_DIR/etc/init.d/openbox-panel"
chmod 0755 "$FILES_DIR/etc/init.d/openbox" "$FILES_DIR/etc/init.d/openbox-panel"

# LuCI 三文件。仓库里 openwrt/luci/htdocs/* 对应系统上的 /www/*,
# openwrt/luci/root/* 对应系统根。
cp "$ROOT/openwrt/luci/htdocs/luci-static/resources/view/openbox/status.js" \
  "$FILES_DIR/www/luci-static/resources/view/openbox/status.js"
cp "$ROOT/openwrt/luci/root/usr/share/luci/menu.d/luci-app-openbox.json" \
  "$FILES_DIR/usr/share/luci/menu.d/luci-app-openbox.json"
cp "$ROOT/openwrt/luci/root/usr/share/rpcd/acl.d/luci-app-openbox.json" \
  "$FILES_DIR/usr/share/rpcd/acl.d/luci-app-openbox.json"

# 首启准备脚本(建 data/、修权限、开面板自启)
cp "$ROOT/firmware/uci-defaults/99-openbox" "$FILES_DIR/etc/uci-defaults/99-openbox"
chmod 0755 "$FILES_DIR/etc/uci-defaults/99-openbox"

# 兜底:把载荷里该可执行的都置上执行位。tar 一般已经带好了,但这一步很便宜,
# 而且能挡住"解包丢了权限位 -> 刷完机面板起不来"这种在设备上才发现的炸法。
find "$FILES_DIR/opt/open-box" -type f \
  \( -name node -o -name sing-box -o -name '*.sh' \) -exec chmod 0755 {} +

log "FILES 目录大小: $(du -sh "$FILES_DIR" | awk '{print $1}')"

# 调试用:只想看看"会被铺进固件的到底是什么",不想真下 ImageBuilder(97MB)跑一遍
# make image 时用这个。它同时是这条流水线上唯一能在非 Linux 上自测的一段。
if [ "${OPENBOX_FIRMWARE_FILES_ONLY:-0}" = "1" ]; then
  log "OPENBOX_FIRMWARE_FILES_ONLY=1:FILES 目录已就绪,停在打镜像之前。"
  log "  $FILES_DIR"
  exit 0
fi

# ---- 3. 取 ImageBuilder(带 sha256 固定) ----
IB_ARCHIVE="$CACHE_DIR/$IMAGEBUILDER_ARCHIVE"
if [ -s "$IB_ARCHIVE" ]; then
  log "命中缓存的 ImageBuilder"
else
  log "下载 ImageBuilder($IMAGEBUILDER_RELEASE,$IMAGEBUILDER_TARGET/$IMAGEBUILDER_SUBTARGET)..."
  tmp="$IB_ARCHIVE.part"
  rm -f "$tmp"
  curl -fsSL --retry 3 -o "$tmp" "$IMAGEBUILDER_URL" || die "下载 ImageBuilder 失败:$IMAGEBUILDER_URL"
  mv "$tmp" "$IB_ARCHIVE"
fi
actual=$(sha256_of "$IB_ARCHIVE")
if [ "$actual" != "$IMAGEBUILDER_SHA256" ]; then
  rm -f "$IB_ARCHIVE"
  echo "  期望: $IMAGEBUILDER_SHA256" >&2
  echo "  实际: $actual" >&2
  die "ImageBuilder 的 sha256 不匹配,已删除该文件(供应链校验失败,拒绝使用)"
fi
log "ImageBuilder 校验通过。"

IB_DIR="$CACHE_DIR/imagebuilder"
if [ ! -d "$IB_DIR" ]; then
  log "解出 ImageBuilder..."
  rm -rf "$IB_DIR" "$CACHE_DIR/.ib-extract"
  mkdir -p "$CACHE_DIR/.ib-extract"
  tar --zstd -xf "$IB_ARCHIVE" -C "$CACHE_DIR/.ib-extract"
  inner=$(find "$CACHE_DIR/.ib-extract" -maxdepth 1 -mindepth 1 -type d | head -n 1)
  [ -n "$inner" ] || die "ImageBuilder 归档内部布局与预期不符"
  mv "$inner" "$IB_DIR"
  rm -rf "$CACHE_DIR/.ib-extract"
fi

# ---- 4. 打镜像 ----
log "开始打镜像(这一步只装包 + 压缩 rootfs,通常 3~8 分钟)..."
(
  cd "$IB_DIR" &&
    make image \
      PROFILE="$PROFILE" \
      PACKAGES="$EXTRA_PACKAGES" \
      FILES="$FILES_DIR"
) || die "make image 失败"

BUILT_DIR="$IB_DIR/bin/targets/$IMAGEBUILDER_TARGET/$IMAGEBUILDER_SUBTARGET"
[ -d "$BUILT_DIR" ] || die "找不到镜像输出目录 $BUILT_DIR"

# ---- 5. 自检:确认 FILES 真的进了"要打进去的那个 rootfs" ----
# 这里一开始写错了:去 build_dir 下找 ImageBuilder 的 TARGET_DIR,但它在 24.10 里是
# build_dir/target-<arch>_<libc>/root-<profile>/,找错了一层就静默跳过——等于没检查。
# 改成直接核对 ImageBuilder 刚生成的那个 root.squashfs:它就是会被写进 sysupgrade
# 镜像的文件系统,拿它做断言才真正回答了"镜像里到底有什么"。
SQUASHFS_IMG=$(find "$IB_DIR/build_dir" -type f -name 'root.squashfs' 2>/dev/null | head -n 1)
[ -n "$SQUASHFS_IMG" ] || die "找不到 ImageBuilder 生成的 root.squashfs,无法核对镜像内容"
command -v unsquashfs >/dev/null 2>&1 || \
  die "需要 unsquashfs 来核对镜像内容(apt-get install -y squashfs-tools)"
log "核对 $(basename "$SQUASHFS_IMG") 的内容..."
SQUASHFS_LIST=$(unsquashfs -l "$SQUASHFS_IMG" 2>/dev/null) || die "无法列出 $SQUASHFS_IMG"
for f in opt/open-box/bin/sing-box \
         opt/open-box/node/bin/node \
         opt/open-box/node/lib \
         opt/open-box/panel/server/index.mjs \
         opt/open-box/panel/dist/index.html \
         opt/open-box/meta.json \
         opt/open-box/uninstall.sh \
         opt/open-box/update.sh \
         etc/init.d/openbox \
         etc/init.d/openbox-panel \
         etc/uci-defaults/99-openbox \
         www/luci-static/resources/view/openbox/status.js \
         usr/share/luci/menu.d/luci-app-openbox.json \
         usr/share/rpcd/acl.d/luci-app-openbox.json; do
  printf '%s\n' "$SQUASHFS_LIST" | grep -q "/$f" || \
    die "root.squashfs 里缺少 /$f —— FILES 没有正确铺进去,这个镜像不能刷"
done
log "root.squashfs 自检通过:/opt/open-box 与 init/LuCI 文件都在镜像里(共 $(printf '%s\n' "$SQUASHFS_LIST" | grep -c 'opt/open-box') 个相关条目)。"

# 只挑 sysupgrade(升级/刷机都用它);factory 镜像是给第一次从原厂固件刷过去用的。
IMG=$(find "$BUILT_DIR" -maxdepth 1 -type f -name "*${PROFILE}-squashfs-sysupgrade.bin" | head -n 1)
[ -n "$IMG" ] || die "在 $BUILT_DIR 里找不到 ${PROFILE} 的 sysupgrade 镜像"

cp "$IMG" "$OUTDIR/"
( cd "$OUTDIR" && sha256sum "$(basename "$IMG")" > "$(basename "$IMG").sha256" )

IMG_PATH="$OUTDIR/$(basename "$IMG")"
log "完成: $IMG_PATH"
log "$(cat "$IMG_PATH.sha256")"
log "镜像大小: $(du -h "$IMG_PATH" | awk '{print $1}')"
log ""
log "刷机前请确认:"
log "  1) 设备当前是 $( [ "$PROFILE" = "redmi_ax6" ] && echo '扩容布局(OpenWrt expand layout)' || echo 'stock / 自定义 U-Boot 布局' );"
log "     两种布局的镜像是不可互换的,刷错会起不来。"
log "  2) 在路由器上核对分区: ubinfo -a  /  cat /proc/mtd"
log "  3) 保留一份原厂/当前固件与分区表备份(例如 mtd 全量 dump),再动手。"
log "  4) 用 sysupgrade -n 刷(不保留配置)还是不加 -n(保留配置),按需选择。"
