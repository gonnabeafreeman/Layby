#!/bin/bash
set -euo pipefail

# Build the distributable archives with package.sh, then create a GitHub Release.
# Usage: bash scripts/package-and-release.sh [--dry-run] [--draft] [--prerelease] vX.Y.Z

readonly repository="gonnabeafreeman/Layby"

usage() {
    cat <<'USAGE'
用法：scripts/package-and-release.sh [选项] <vX.Y.Z>

选项：
  --dry-run     只检查输入并打印将执行的发布命令，不打包、不上传
  --draft       创建 GitHub 草稿 Release，不发布为 Latest
  --prerelease  创建 GitHub 预发布 Release，不发布为 Latest
  -h, --help    显示帮助

准备：
  1. 本地 HEAD 必须是已推送到 GitHub 的同名 tag
  2. dist/<tag>/Layby.app 必须已完成最终构建和签名
  3. dist/<tag>/release-desc.md 必须包含 Release 描述

脚本会调用根目录 package.sh，生成 Layby.zip、Layby.dmg、签名 appcast.xml 和
SHA256SUMS，然后用 gh 发布到 gonnabeafreeman/Layby。

Sparkle 的私钥默认从登录钥匙串读取。可通过 SPARKLE_GENERATE_APPCAST 指定
generate_appcast 路径；未指定时，脚本会从 Xcode 的 Sparkle 缓存中查找。
USAGE
}

dry_run=false
draft=false
prerelease=false
version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        --draft) draft=true ;;
        --prerelease) prerelease=true ;;
        -h|--help) usage; exit 0 ;;
        v[0-9]*.[0-9]*.[0-9]*)
            if [[ -n "$version" ]]; then
                printf '错误：只能指定一个版本号\n' >&2
                exit 1
            fi
            version="$1"
            ;;
        *)
            printf '错误：未知选项或无效版本号：%s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '错误：版本号必须形如 v1.2.3\n' >&2
    exit 1
fi
if [[ "$draft" == true && "$prerelease" == true ]]; then
    printf '错误：--draft 与 --prerelease 不能同时使用\n' >&2
    exit 1
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '错误：打包需要在 macOS 上执行\n' >&2
    exit 1
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
release_dir="$project_root/dist/$version"
app="$release_dir/Layby.app"
info_plist="$app/Contents/Info.plist"
description="$release_dir/release-desc.md"
packaged_zip="$release_dir/Layby.zip"
packaged_dmg="$release_dir/Layby.dmg"
zip="$packaged_zip"
dmg="$packaged_dmg"
checksums="$release_dir/SHA256SUMS"
appcast="$release_dir/appcast.xml"
marketing_version="${version#v}"
download_prefix="https://github.com/$repository/releases/download/$version/"
appcast_source_dir=""

cleanup() {
    if [[ -n "$appcast_source_dir" && -d "$appcast_source_dir" ]]; then
        rm -rf "$appcast_source_dir"
    fi
}
trap cleanup EXIT

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf '错误：缺少命令 %s\n' "$1" >&2
        exit 1
    fi
}

require_command git
require_command plutil
require_command gh
require_command shasum

find_generate_appcast() {
    if [[ -n "${SPARKLE_GENERATE_APPCAST:-}" ]]; then
        if [[ ! -x "$SPARKLE_GENERATE_APPCAST" ]]; then
            printf '错误：SPARKLE_GENERATE_APPCAST 不可执行：%s\n' "$SPARKLE_GENERATE_APPCAST" >&2
            exit 1
        fi
        printf '%s\n' "$SPARKLE_GENERATE_APPCAST"
        return
    fi

    local tool
    tool="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' \
        -type f -perm -u+x -print -quit 2>/dev/null || true)"
    if [[ -z "$tool" ]]; then
        printf '%s\n' '错误：找不到 Sparkle generate_appcast。请先在 Xcode 解析依赖，或设置 SPARKLE_GENERATE_APPCAST。' >&2
        exit 1
    fi
    printf '%s\n' "$tool"
}

if [[ ! -d "$app" || ! -f "$info_plist" ]]; then
    printf '错误：找不到待发布应用：%s\n' "$app" >&2
    exit 1
fi
if [[ ! -s "$description" ]]; then
    printf '错误：Release 描述必须存在且非空：%s\n' "$description" >&2
    exit 1
fi

app_version="$(plutil -extract CFBundleShortVersionString raw "$info_plist" 2>/dev/null || true)"
app_build="$(plutil -extract CFBundleVersion raw "$info_plist" 2>/dev/null || true)"
if [[ "$app_version" != "$marketing_version" ]]; then
    printf '错误：应用版本为 %s，和 tag %s 不一致\n' "${app_version:-<缺失>}" "$version" >&2
    exit 1
fi
if [[ ! "$app_build" =~ ^[0-9]+$ ]] || [[ "$app_build" == "0" ]]; then
    printf '错误：CFBundleVersion 必须是正整数，当前为 %s\n' "${app_build:-<缺失>}" >&2
    exit 1
fi

if ! git -C "$project_root" show-ref --verify --quiet "refs/tags/$version"; then
    printf '错误：本地不存在 tag %s\n' "$version" >&2
    exit 1
fi
tag_commit="$(git -C "$project_root" rev-parse "$version^{commit}")"
head_commit="$(git -C "$project_root" rev-parse HEAD)"
if [[ "$tag_commit" != "$head_commit" ]]; then
    printf '错误：tag %s 未指向当前 HEAD；请从已标记的提交构建后再发布\n' "$version" >&2
    exit 1
fi

if [[ "$dry_run" == true ]]; then
    generate_appcast="$(find_generate_appcast)"
    printf '%s\n' '输入检查通过。将执行：'
    printf '  %q %q\n' "$project_root/package.sh" "$version"
    printf '  %q --download-url-prefix %q --versions %q %q\n' \
        "$generate_appcast" "$download_prefix" "$app_build" "$release_dir"
    printf '  gh release create %q --repo %q --verify-tag --title %q --notes-file %q <assets>\n' \
        "$version" "$repository" "Layby $marketing_version" "$description"
    exit 0
fi

if [[ -e "$zip" || -e "$dmg" || -e "$checksums" || -e "$appcast" ]]; then
    printf '错误：发布目录已存在归档或校验文件；请确认版本目录是新的：%s\n' "$release_dir" >&2
    exit 1
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    printf '%s\n' '错误：gh 未登录 GitHub。请先执行 gh auth login。' >&2
    exit 1
fi

"$project_root/package.sh" "$version"

if [[ ! -s "$packaged_zip" || ! -s "$packaged_dmg" ]]; then
    printf '%s\n' '错误：package.sh 未生成预期的 ZIP 和 DMG。' >&2
    exit 1
fi

generate_appcast="$(find_generate_appcast)"
# Sparkle examines every archive in its input directory. The DMG is a manual
# installation artifact, while the ZIP is the only self-update package.
appcast_source_dir="$(mktemp -d "$release_dir/.appcast.XXXXXX")"
cp "$zip" "$appcast_source_dir/"
# Sparkle matches release notes to the archive basename. A temporary symlink
# lets it embed release-desc.md without creating or publishing a duplicate file.
ln -s "$description" "$appcast_source_dir/Layby.md"
"$generate_appcast" \
    --download-url-prefix "$download_prefix" \
    --link "https://github.com/$repository" \
    --embed-release-notes \
    --versions "$app_build" \
    "$appcast_source_dir"

if [[ ! -s "$appcast_source_dir/appcast.xml" ]]; then
    printf '错误：generate_appcast 未生成 appcast.xml：%s\n' "$appcast" >&2
    exit 1
fi
mv "$appcast_source_dir/appcast.xml" "$appcast"

(
    cd "$release_dir"
    shasum -a 256 "$(basename "$zip")" "$(basename "$dmg")" > "$(basename "$checksums")"
)

release_args=(
    release create "$version"
    --repo "$repository"
    --verify-tag
    --title "Layby $marketing_version"
    --notes-file "$description"
)
if [[ "$draft" == true ]]; then
    release_args+=(--draft)
elif [[ "$prerelease" == true ]]; then
    release_args+=(--prerelease --latest=false)
else
    release_args+=(--latest)
fi
release_args+=(
    "$zip#Layby $marketing_version (ZIP)"
    "$dmg#Layby $marketing_version (DMG)"
    "$checksums#SHA-256 checksums"
    "$appcast#Sparkle appcast"
)

gh "${release_args[@]}"
