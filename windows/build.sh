#!/bin/zsh
# Builds the Windows app into dist/ from macOS, Linux or Windows (Git Bash):
#   AccountSwitcher-win-x64.zip, AccountSwitcher-win-arm64.zip
# Each zip holds one self-contained AccountSwitcher.exe (no .NET install needed).
# Runs the Core tests first. Code signing happens separately (see README).
set -e
cd "$(dirname "$0")"
DOTNET="${DOTNET:-$(command -v dotnet || echo "$HOME/.dotnet/dotnet")}"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

"$DOTNET" run --project tests/CoreTests -c Release

rm -rf dist && mkdir -p dist
for rid in win-x64 win-arm64; do
  out="dist/$rid"
  "$DOTNET" publish src/App/App.csproj -c Release -r "$rid" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -p:DebugType=none -o "$out" -v q
  (cd "$out" && zip -q -9 "../AccountSwitcher-$rid.zip" AccountSwitcher.exe)
  echo "dist/AccountSwitcher-$rid.zip  ($(du -h "dist/AccountSwitcher-$rid.zip" | cut -f1))"
done
