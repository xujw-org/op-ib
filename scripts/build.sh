#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET="${1:-}"
SUBTARGET="${2:-}"
PROFILE="${3:-}"
PACKAGES_PROFILE="${4:-}"
VERSION="${5:-}"
UPSTREAM="${6:-openwrt}"

if [ -z "$TARGET" ] || [ -z "$SUBTARGET" ] || [ -z "$PROFILE" ] || [ -z "$PACKAGES_PROFILE" ]; then
    echo "Usage: $0 <TARGET> <SUBTARGET> <PROFILE> <PACKAGES_PROFILE> [VERSION] [UPSTREAM]" >&2
    exit 1
fi

log() {
    printf '[%s] %s\n' "$(date +'%T')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date +'%T')" "$*" >&2
    exit 1
}

case "$UPSTREAM" in
    openwrt)
        UPSTREAM_URL="https://downloads.openwrt.org"
        UPSTREAM_GIT="https://github.com/openwrt/openwrt.git"
        ;;
    immortalwrt)
        UPSTREAM_URL="https://downloads.immortalwrt.org"
        UPSTREAM_GIT="https://github.com/immortalwrt/immortalwrt.git"
        ;;
    istoreos)
        UPSTREAM_URL="https://fw20.koolcenter.com"
        UPSTREAM_GIT=""
        ;;
    *)
        die "Unsupported upstream: ${UPSTREAM} (expected: openwrt, immortalwrt, istoreos)"
        ;;
esac

resolve_version() {
    local req="${1:-}"
    local default_major="25.12"
    if [ -z "$req" ] || [ "$req" = "latest" ]; then
        req="$default_major"
    fi

    local versions
    versions=$(curl -fsSL --retry 3 "${UPSTREAM_URL}/releases/" 2>/dev/null | \
        grep -oE 'href="[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?/"' | \
        sed 's/href="//;s/\///;s/"//' | sort -V || true)

    if [ -z "$versions" ]; then
        versions=$(git ls-remote --tags --refs "${UPSTREAM_GIT}" 2>/dev/null | awk -F'/' '{print $NF}' | sed 's/^v//' || true)
    fi

    if echo "$versions" | grep -qx "$req"; then
        echo "$req"
        return
    fi

    local matched
    local escaped_req="${req//./\\.}"
    matched=$(echo "$versions" | grep -E "^${escaped_req}\.[0-9]+" | grep -v 'rc' | sort -V | tail -n 1 || true)
    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    matched=$(echo "$versions" | grep -E "^${escaped_req}" | grep -v 'rc' | sort -V | tail -n 1 || true)
    if [ -n "$matched" ]; then
        echo "$matched"
        return
    fi

    echo "${req:-25.12.6}"
}

if [ "$UPSTREAM" = "istoreos" ]; then
    [ "$TARGET" = "x86" ] || die "iStoreOS ImageBuilder is x86 only"
    [ -n "$VERSION" ] && [ "$VERSION" != "latest" ] || VERSION="snapshot"
else
    VERSION=$(resolve_version "$VERSION")
fi
log "Using ${UPSTREAM} release: ${VERSION}"

case "$TARGET" in
    x86)
        ARCH="x86_64"
        ;;
    rockchip)
        ARCH="aarch64_generic"
        ;;
    *)
        die "Unsupported target: ${TARGET}"
        ;;
esac

WORK_DIR="${ROOT_DIR}/build_${UPSTREAM}_${TARGET}_${SUBTARGET}_${PROFILE}"
OUTPUT_DIR="${ROOT_DIR}/artifact"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

if [ "$UPSTREAM" = "istoreos" ]; then
    IB_NAME="istoreos-imagebuilder-x86-64.Linux-x86_64"
    IB_URL="https://fw20.koolcenter.com/iStoreOS/ib/x86_64/${IB_NAME}.tar.zst"
else
    IB_NAME="${UPSTREAM}-imagebuilder-${VERSION}-${TARGET}-${SUBTARGET}.Linux-x86_64"
    IB_URL="${UPSTREAM_URL}/releases/${VERSION}/targets/${TARGET}/${SUBTARGET}/${IB_NAME}.tar.zst"
fi
IB_DIR="${WORK_DIR}/${IB_NAME}"

if [ ! -d "$IB_DIR" ]; then
    IB_ARCHIVE="${WORK_DIR}/$(basename "$IB_URL")"
    log "Downloading ImageBuilder: ${IB_URL}"
    curl -fL --http1.1 --retry 5 --retry-all-errors --retry-delay 3 -o "$IB_ARCHIVE" "$IB_URL" || die "Failed to download ImageBuilder archive"
    case "$IB_ARCHIVE" in
        *.tar.xz) tar -xJf "$IB_ARCHIVE" -C "$WORK_DIR" ;;
        *) tar --zstd -xf "$IB_ARCHIVE" -C "$WORK_DIR" ;;
    esac
    rm -f "$IB_ARCHIVE"
fi

mkdir -p "${IB_DIR}/keys"
[ -f "${IB_DIR}/repositories" ] || : > "${IB_DIR}/repositories"
KEY_URL="https://qiusimons.github.io/OpenWrt-Add/keys/custom-feed.rsa.pub"
log "Fetching feed signing key: ${KEY_URL}"
curl -fsSL --retry 3 --retry-delay 2 "$KEY_URL" -o "${IB_DIR}/keys/custom-feed.rsa.pub" || die "Failed to download feed signing key"

FEED_URL="https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb"
if [ ! -s "${IB_DIR}/repositories" ]; then
    printf '%s\n' "$FEED_URL" > "${IB_DIR}/repositories"
elif ! grep -qxF "$FEED_URL" "${IB_DIR}/repositories"; then
    sed -i "1i ${FEED_URL}" "${IB_DIR}/repositories"
fi

# iStoreOS ships a reduced package set; third-party packages need the
# matching OpenWrt release feeds for their base libraries.
if [ "$UPSTREAM" = "istoreos" ]; then
    owrt_version=$(sed -nE 's/^VERSION_NUMBER:=.*,([0-9]+\.[0-9]+\.[0-9]+)\)$/\1/p' "${IB_DIR}/include/version.mk" | tail -n 1)
    [ -n "$owrt_version" ] || owrt_version="25.12.6"
    if ! grep -qF "downloads.openwrt.org/releases/${owrt_version}/targets/${TARGET}" "${IB_DIR}/repositories"; then
        {
            printf '%s\n' "https://downloads.openwrt.org/releases/${owrt_version}/targets/${TARGET}/${SUBTARGET}/packages/packages.adb"
            for feed in base luci packages routing telephony; do
                printf '%s\n' "https://downloads.openwrt.org/releases/${owrt_version}/packages/${ARCH}/${feed}/packages.adb"
            done
        } >> "${IB_DIR}/repositories"
    fi
fi

if [ "$UPSTREAM" = "immortalwrt" ]; then
    sed -i -E 's/^(CONFIG_(QCOW2|VDI|VMDK|VHDX)_IMAGES)=y/# \1 is not set/' "${IB_DIR}/.config"
fi

# ISO images are live-only: rebooting discards every configuration change, so
# they are unsuitable for production. Disable them for every upstream.
if grep -q '^CONFIG_ISO_IMAGES=y' "${IB_DIR}/.config"; then
    sed -i 's/^CONFIG_ISO_IMAGES=y/# CONFIG_ISO_IMAGES is not set/' "${IB_DIR}/.config"
elif ! grep -q '^# CONFIG_ISO_IMAGES is not set' "${IB_DIR}/.config"; then
    printf '# CONFIG_ISO_IMAGES is not set\n' >> "${IB_DIR}/.config"
fi

OVERLAY_DIR="${WORK_DIR}/overlay"
rm -rf "$OVERLAY_DIR"
mkdir -p "$OVERLAY_DIR"

if [ -d "${ROOT_DIR}/files" ]; then
    cp -af "${ROOT_DIR}/files/." "$OVERLAY_DIR/"
fi

mkdir -p "${OVERLAY_DIR}/usr/bin"
FUCK_URL="https://raw.githubusercontent.com/QiuSimons/OpenWrt-Add/master/core/tools/clean-overlay.sh"
log "Fetching fuck utility: ${FUCK_URL}"
curl -fsSL --retry 3 --retry-delay 2 "$FUCK_URL" -o "${OVERLAY_DIR}/usr/bin/fuck" || die "Failed to download clean-overlay.sh"
chmod +x "${OVERLAY_DIR}/usr/bin/fuck"

mkdir -p "${OVERLAY_DIR}/etc/apk/keys"
cp -af "${IB_DIR}/keys/custom-feed.rsa.pub" "${OVERLAY_DIR}/etc/apk/keys/"

mkdir -p "${OVERLAY_DIR}/etc/apk/repositories.d"
echo "https://qiusimons.github.io/OpenWrt-Add/${ARCH}/packages.adb" > "${OVERLAY_DIR}/etc/apk/repositories.d/customfeeds.list"

if [ "$TARGET" = "rockchip" ]; then
    mkdir -p "${OVERLAY_DIR}/etc/apk"
    echo "aarch64_generic" >> "${OVERLAY_DIR}/etc/apk/arch"
fi

load_packages() {
    local file="$1"
    [ -f "$file" ] || die "Package profile not found: $file"
    grep -v '^[[:space:]]*#' "$file" | grep -v '^[[:space:]]*$' | tr '\n' ' '
}

PACKAGES="$(load_packages "${ROOT_DIR}/profiles/packages.common") $(load_packages "${ROOT_DIR}/profiles/${PACKAGES_PROFILE}")"

# ImmortalWrt's ImageBuilder already ships packages that own files ours provide.
if [ "$UPSTREAM" = "immortalwrt" ]; then
    PACKAGES=$(printf '%s\n' "$PACKAGES" | tr ' ' '\n' | grep -vx 'autocore-x86' | tr '\n' ' ')
    PACKAGES="${PACKAGES} -default-settings -default-settings-chn -kmod-usb-net-rtl8152-vendor"
fi
BUILD_LOG="${WORK_DIR}/build.log"
SKIPPED_PACKAGES=""
MAX_SKIP_ROUNDS=5
MAX_DOWNLOAD_RETRIES=2

build_firmware() {
    local packages="$1"
    make -C "$IB_DIR" image \
        PROFILE="$PROFILE" \
        PACKAGES="$packages" \
        FILES="$OVERLAY_DIR" \
        ROOTFS_PARTSIZE="1024" 2>&1 | tee "$BUILD_LOG"
}

missing_packages_from_log() {
    local log_file="$1"
    # apk (OpenWrt 25.x): "<pkg> (no such package):"
    sed -nE 's/^[[:space:]]*([^ ]+) \(no such package\):[[:space:]]*$/\1/p' "$log_file"
    # opkg (OpenWrt 24.x and older): "opkg_install_cmd: Cannot install package <pkg>."
    sed -nE 's/.*opkg_install_cmd: Cannot install package ([^ ]+)\.$/\1/p' "$log_file"
}

# apk (OpenWrt 25.x) refuses packages whose "kernel=" dependency was built for a
# different kernel ABI. The third-party feed is built against the latest OpenWrt
# release, so its kmods break whenever another upstream still ships an older
# kernel (ImmortalWrt). Their "<pkg>-<version>[kernel=...]" tokens end up under
# "breaks:".
conflicting_packages_from_log() {
    local log_file="$1"
    local kernel_abi
    kernel_abi=$(sed -n '/ERROR: unable to select packages:/,$p' "$log_file" |
        sed -n 's/^.*\[kernel=\([0-9][0-9.]*\)[~].*$/\1/p' | head -n 1)
    [ -n "$kernel_abi" ] || return 0
    sed -n '/ERROR: unable to select packages:/,$p' "$log_file" |
        sed -n '/breaks:/,/satisfies:/p' |
        tr -s ' \t' '\n\n' |
        sed 's/\[.*//' |
        grep -E '^kmod-.*-[0-9]' |
        sed "s/-${kernel_abi}.*//" | sort -u
}

# Feed hiccups are worth a full rebuild; a broken package is not.
download_failure_in_log() {
    local log_file="$1"
    grep -qE 'wget: exited with error|unexpected end of file|opkg_download: Failed to download|wget returned [0-9]+|Connection (timed out|reset by peer)|HTTP/1\.[01] (429|5[0-9][0-9])' "$log_file"
}

log "Assembling firmware for ${PROFILE} (${VERSION})..."
skip_round=0
download_retry=0
while :; do
    if build_firmware "$PACKAGES"; then
        break
    fi

    missing="$(missing_packages_from_log "$BUILD_LOG" | sort -u)"
    conflicting="$(conflicting_packages_from_log "$BUILD_LOG" | sort -u)"
    kept=""
    missing_skipped=""
    conflict_skipped=""
    for pkg in $PACKAGES; do
        if printf '%s\n' "$missing" | grep -qxF -- "$pkg"; then
            printf '%s\n' "$missing_skipped" | grep -qxF -- "$pkg" ||
                missing_skipped="${missing_skipped}${missing_skipped:+ }${pkg}"
        elif printf '%s\n' "$conflicting" | grep -qxF -- "$pkg"; then
            printf '%s\n' "$conflict_skipped" | grep -qxF -- "$pkg" ||
                conflict_skipped="${conflict_skipped}${conflict_skipped:+ }${pkg}"
        else
            kept="${kept}${kept:+ }${pkg}"
        fi
    done

    # Target profiles add kernel modules of their own (x86 pulls kmod-r8125 and
    # kmod-r8168), so exclude every conflicting name instead of only the ones
    # requested above.
    for pkg in $conflicting; do
        case " $kept " in
            *" -${pkg} "*) ;;
            *) kept="${kept}${kept:+ }-${pkg}" ;;
        esac
        printf '%s\n' "$conflict_skipped" | grep -qxF -- "$pkg" ||
            conflict_skipped="${conflict_skipped}${conflict_skipped:+ }${pkg}"
    done
    skipped="${missing_skipped}${missing_skipped:+${conflict_skipped:+ }}${conflict_skipped}"

    if [ -z "$skipped" ]; then
        if [ "$download_retry" -lt "$MAX_DOWNLOAD_RETRIES" ] && download_failure_in_log "$BUILD_LOG"; then
            download_retry=$((download_retry + 1))
            log "WARNING: transient download failure, retrying build (${download_retry}/${MAX_DOWNLOAD_RETRIES})"
            sleep 15
            continue
        fi
        die "Firmware build failed (no unavailable package detected). See ${BUILD_LOG}"
    fi

    skip_round=$((skip_round + 1))
    if [ "$skip_round" -gt "$MAX_SKIP_ROUNDS" ]; then
        die "Too many unavailable packages; last skipped: ${skipped}. See ${BUILD_LOG}"
    fi

    [ -z "$missing_skipped" ] || log "WARNING: Package(s) not available in repositories, skipping: ${missing_skipped}"
    [ -z "$conflict_skipped" ] || log "WARNING: Package(s) built for a different kernel ABI, skipping: ${conflict_skipped}"
    SKIPPED_PACKAGES="${SKIPPED_PACKAGES}${SKIPPED_PACKAGES:+ }${skipped}"
    PACKAGES="$kept"
done

if [ -n "$SKIPPED_PACKAGES" ]; then
    log "WARNING: Firmware built without unavailable package(s): ${SKIPPED_PACKAGES}"
fi

IB_BIN_DIR="${IB_DIR}/bin/targets/${TARGET}/${SUBTARGET}"
[ -d "$IB_BIN_DIR" ] || die "Output directory not found: $IB_BIN_DIR"

DATE_STR=$(date +%Y-%m-%d)
PLATFORM_LABEL=$(echo "$PROFILE" | sed 's/^friendlyarm_nanopi-/nanopi-/; s/^generic$/x86-64/')

MATCH_PATTERN="*sysupgrade.img.gz"
if [ "$TARGET" = "x86" ]; then
    MATCH_PATTERN="*combined-efi.img.gz"
fi

find "$IB_BIN_DIR" -type f -name "$MATCH_PATTERN" | while read -r img; do
    fname=$(basename "$img")
    clean_suffix=$(echo "$fname" | sed -E "s/^${UPSTREAM}-(.*-)?${TARGET}-${SUBTARGET}-${PROFILE}-//")
    out_name="${UPSTREAM}-${PLATFORM_LABEL}-${VERSION}-${DATE_STR}-${clean_suffix}"
    cp -f "$img" "${OUTPUT_DIR}/${out_name}"
    log "Saved: ${out_name}"
done

log "Build completed successfully for ${PROFILE}."
