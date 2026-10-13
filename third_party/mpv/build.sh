#!/usr/bin/env bash
set -euo pipefail

if [[ "${MSYSTEM:-}" != UCRT64 ]]; then
  echo 'Run this script from an MSYS2 UCRT64 terminal.' >&2
  exit 1
fi
package=$(cd -- "$(dirname -- "$0")" && pwd)
workspace=$(cd -- "$package/../.." && pwd)
build="$workspace/build/mpv"
mkdir -p "$build"

# 源码和编译缓存都在 build 下，仓库仅保存经过校验的源码归档。
python "$package/package-runtime.py" extract "$package" "$build"
meson setup "$build/compile" "$build/source/mpv" --reconfigure \
  --buildtype=debugoptimized --auto-features=disabled --werror \
  -Dlibmpv=true -Dcplayer=false -Dtests=true -Dbuild-date=false \
  -Degl-angle=enabled -Degl-angle-lib=enabled -Degl-angle-win32=enabled \
  -Dd3d-hwaccel=enabled -Dd3d11=enabled -Dshaderc=enabled -Dspirv-cross=enabled -Dwasapi=enabled \
  -Dplain-gl=enabled -Dgl=enabled -Dgl-win32=enabled -Dwin32-threads=enabled \
  -Diconv=enabled -Dzlib=enabled -Djpeg=enabled -Dlcms2=enabled -Dlibavdevice=enabled \
  -Dlibcurl=enabled \
  -Dzimg=enabled -Dlua=disabled -Dmanpage-build=disabled -Dpdf-build=disabled
meson compile -C "$build/compile" -j "${MPV_JOBS:-4}"
env -i PATH="$build/compile:$PATH" SYSTEMROOT="$SYSTEMROOT" WINDIR="$WINDIR" \
  TMP="$TMP" TEMP="$TEMP" HOME="$HOME" LANG=C.UTF-8 \
  GGML_NO_BACKTRACE=1 meson test -C "$build/compile" --print-errorlogs
pacman -Q > "$build/packages.txt"
python "$package/package-runtime.py" package "$package" "$build" "$(cygpath -w "$MINGW_PREFIX")"
