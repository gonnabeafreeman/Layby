#!/bin/bash
set -euo pipefail

# 用法：./package.sh v1.2.3（也接受 1.2.3）
# 输入：dist/v1.2.3/Layby.app；输出：同目录下的 Layby.dmg 和 Layby.zip
usage() {
    printf '用法：%s <vX.X.X>\n依赖：brew install create-dmg\n' "$(basename "$0")"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 1
fi

version="v${1#v}"
if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '错误：版本号必须形如 v1.2.3 或 1.2.3\n' >&2
    exit 1
fi

project_root="$(cd "$(dirname "$0")" && pwd)"
release_dir="$project_root/dist/$version"
app="$release_dir/Layby.app"
icon="$project_root/assets/app-icon.png"
output="$release_dir/Layby.dmg"
zip_output="$release_dir/Layby.zip"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '错误：请在 macOS 上运行此脚本\n' >&2
    exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
    printf '错误：缺少 create-dmg，请先执行 brew install create-dmg\n' >&2
    exit 1
fi
if [[ ! -d "$app/Contents" || ! -f "$app/Contents/Info.plist" ]]; then
    printf '错误：请先将构建好的应用放到 %s\n' "$app" >&2
    exit 1
fi
if [[ ! -f "$icon" ]]; then
    printf '错误：找不到图标 %s\n' "$icon" >&2
    exit 1
fi
for destination in "$output" "$zip_output"; do
    if [[ -e "$destination" ]]; then
        printf '错误：输出文件已存在，请先移走或删除：%s\n' "$destination" >&2
        exit 1
    fi
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/layby-dmg.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$work_dir/source" "$work_dir/Layby.iconset"

# 仅复制应用，避免把版本目录中的其他文件打入镜像
ditto "$app" "$work_dir/source/Layby.app"

# 从 PNG 生成卷图标所需的完整 ICNS 尺寸集合
for size in 16 32 128 256 512; do
    sips -s format png -z "$size" "$size" "$icon" \
        --out "$work_dir/Layby.iconset/icon_${size}x${size}.png" >/dev/null
    sips -s format png -z "$((size * 2))" "$((size * 2))" "$icon" \
        --out "$work_dir/Layby.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$work_dir/Layby.iconset" -o "$work_dir/Layby.icns"

# 将内嵌的纯白像素扩展为 600 × 400 背景，无需额外图片依赖
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC' \
    | base64 -D > "$work_dir/background.png"
sips -z 400 600 "$work_dir/background.png" >/dev/null

create-dmg \
    --volname "Layby $version" \
    --volicon "$work_dir/Layby.icns" \
    --background "$work_dir/background.png" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --text-size 14 \
    --icon "Layby.app" 150 180 \
    --hide-extension "Layby.app" \
    --app-drop-link 450 180 \
    --format UDZO \
    "$work_dir/Layby.dmg" \
    "$work_dir/source"

# ZIP 保留应用包目录及 macOS 元数据，两个归档都完成后再移入版本目录
ditto -c -k --sequesterRsrc --keepParent \
    "$work_dir/source/Layby.app" "$work_dir/Layby.zip"

mv "$work_dir/Layby.dmg" "$output"
mv "$work_dir/Layby.zip" "$zip_output"
printf 'DMG 已生成：%s\n' "$output"
printf 'ZIP 已生成：%s\n' "$zip_output"
