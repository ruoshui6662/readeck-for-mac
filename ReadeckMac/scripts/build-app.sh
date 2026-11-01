#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
mkdir -p .cache/clang .cache/swiftpm
export XDG_CACHE_HOME="$project_dir/.cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.cache/clang"
export SWIFTPM_CACHE_PATH="$project_dir/.cache/swiftpm"

assert_app_closed() {
    local process_result
    if process_result="$(pgrep -x ReadeckMac 2>&1)"; then
        print -u2 "Readeck Mac 正在运行。请先退出应用再打包，避免替换正在使用的签名与权限身份。"
        exit 1
    else
        local probe_code=$?
        if (( probe_code != 1 )); then
            print -u2 "无法确认应用是否已退出；为保护运行中的应用，本次不替换安装包。可先使用 swift build 只编译源码。"
            exit 1
        fi
    fi
}

app_dir="${READECK_APP_OUTPUT:-$project_dir/dist/Readeck Mac.app}"
if [[ "$app_dir" == "$project_dir/dist/Readeck Mac.app" ]]; then assert_app_closed; fi
swift build --disable-sandbox --scratch-path .build -c debug
if [[ "$app_dir" == "$project_dir/dist/Readeck Mac.app" ]]; then assert_app_closed; fi
mkdir -p "$app_dir/Contents/MacOS"
cp .build/debug/ReadeckMac "$app_dir/Contents/MacOS/ReadeckMac"
cp Info.plist "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources"
cp -Rf Sources/ReadeckMac/Resources/. "$app_dir/Contents/Resources/"
signing_identity="${READECK_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [[ "$signing_identity" == "-" ]]; then
    print -u2 "当前使用临时签名。跨构建稳定识别局域网权限需要 Apple 签发的签名身份；可通过 READECK_SIGN_IDENTITY 配置。"
fi
print "Built $app_dir"
