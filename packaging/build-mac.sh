#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
version=1.0.30
case "${1:-}" in
  apple-silicon) chip=apple-silicon; platform=mac-aarch64; architecture=arm64 ;;
  intel) chip=intel; platform=mac; architecture=x86_64 ;;
  *) printf 'Specify apple-silicon or intel.\n' >&2; exit 1 ;;
esac
[[ $(uname -s) == Darwin && $(uname -m) == "$architecture" ]]
[[ -n ${JAVA_HOME:-} && -n ${RUNNER_TEMP:-} ]]
work=$(mktemp -d "$RUNNER_TEMP/kodaris-mac.XXXXXX")
mkdir -p "$work/download" "$work/lib" "$work/javafx" "$root/dist"

# Hashes bind the installer to the already signed and published release.
# No private source repository or signing key is accessed by this workflow.
for file in release.txt release.sig kodaris-update.zip; do
  curl --fail --show-error --silent --location --retry 3 \
    "https://github.com/Efirios/kodaris-updates/releases/download/v$version/$file" \
    --output "$work/download/$file"
done
(cd "$work/download" && shasum -a 256 -c "$root/packaging/release-1.0.30.sha256")
grep -qx "version=$version" "$work/download/release.txt"
unzip -q "$work/download/kodaris-update.zip" -d "$work/lib"

for module in base graphics controls; do
  name="javafx-$module-27.0.1-$platform.jar"
  curl --fail --show-error --silent --location --retry 3 \
    "https://repo.maven.apache.org/maven2/org/openjfx/javafx-$module/27.0.1/$name" \
    --output "$work/javafx/$name"
  (cd "$work/javafx" && grep -F "  $name" "$root/packaging/javafx.sha256" | shasum -a 256 -c -)
done

"$JAVA_HOME/bin/jpackage" --type dmg --name Kodaris --app-version "$version" \
  --icon "$root/packaging/Kodaris.icns" --resource-dir "$root/packaging/mac" \
  --input "$work/lib" --main-jar kodaris.jar --main-class ru.kodaris.boot.Loader \
  --arguments --window --module-path "$work/javafx" \
  --add-modules java.base,java.desktop,java.net.http,java.security.jgss,java.sql,java.xml.crypto,javafx.controls \
  --java-options -Dstdout.encoding=UTF-8 --java-options -Dstderr.encoding=UTF-8 \
  --java-options -Dlog4j2.statusLoggerLevel=OFF \
  --java-options --enable-native-access=ALL-UNNAMED,javafx.graphics \
  --dest "$work/installer"

mounted=false
cleanup() { if [[ $mounted == true ]]; then hdiutil detach "$work/mount" || true; fi; }
trap cleanup EXIT
hdiutil attach "$work/installer/Kodaris-$version.dmg" -mountpoint "$work/mount" -nobrowse
mounted=true
cp -R "$work/mount/Kodaris.app" "$work/Kodaris.app"
hdiutil detach "$work/mount"
mounted=false
app="$work/Kodaris.app/Contents/MacOS/Kodaris"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$work/Kodaris.app/Contents/Info.plist") == "$version" ]]
mkdir -p "$work/check-home/.kodaris"
export JAVA_TOOL_OPTIONS="-Duser.home=$work/check-home"

# Exercise the packaged runtime, window, notifications and license signature.
python3 - "$app" "$work/license-check.txt" <<'PY'
import pathlib
import subprocess
import sys

app, report = sys.argv[1:]
for flag, expected in [
    ("--check", "Уведомлен"),
    ("--notice-check", "Щелчок обработан: да"),
    ("--fx-check", "Окно показано: да"),
]:
    result = subprocess.run([app, flag], capture_output=True, text=True, encoding="utf-8", timeout=180)
    print(result.stdout)
    print(result.stderr, file=sys.stderr)
    result.check_returncode()
    if expected not in result.stdout:
        raise SystemExit(f"Self-check failed: {flag}")
subprocess.run([app, "--license-check", report], timeout=180, check=True)
lines = pathlib.Path(report).read_text(encoding="utf-8").splitlines()
print("\n".join(lines))
if not {"result=OK", "license=enabled", "payments=server", "signature=Ed25519"}.issubset(lines):
    raise SystemExit("License self-check failed")
PY

output="Kodaris-$version-$chip.dmg"
[[ ! -e "$root/dist/$output" ]]
cp "$work/installer/Kodaris-$version.dmg" "$root/dist/$output"
(cd "$root/dist" && shasum -a 256 "$output" > "$output.sha256")
printf 'Verified installer: %s\n' "$output"
