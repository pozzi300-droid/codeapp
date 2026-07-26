#!/usr/bin/env bash
set -euo pipefail

DOTNET_RUNTIME_VERSION="${DOTNET_RUNTIME_VERSION:-8.0.11}"
ROSLYN_VERSION="${ROSLYN_VERSION:-4.11.0}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="$ROOT_DIR/Resources/Mono"
WORK_DIR="${RUNNER_TEMP:-/tmp}/codeapp-mono-ios"

rm -rf "$WORK_DIR" "$OUTPUT_DIR"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR/MonoManaged/runtime" "$OUTPUT_DIR/MonoManaged/ref" "$OUTPUT_DIR/MonoManaged/tools"

download_nuget_package() {
    local package_id="$1"
    local version="$2"
    local destination="$3"
    local lower_id
    lower_id="$(printf '%s' "$package_id" | tr '[:upper:]' '[:lower:]')"
    mkdir -p "$destination"
    curl --fail --location --retry 4 --retry-all-errors \
        "https://api.nuget.org/v3-flatcontainer/$lower_id/$version/$lower_id.$version.nupkg" \
        --output "$WORK_DIR/$lower_id.nupkg"
    unzip -q "$WORK_DIR/$lower_id.nupkg" -d "$destination"
}

download_nuget_package \
    "Microsoft.NETCore.App.Runtime.Mono.ios-arm64" \
    "$DOTNET_RUNTIME_VERSION" \
    "$WORK_DIR/runtime-pack"
download_nuget_package \
    "Microsoft.NETCore.App.Ref" \
    "$DOTNET_RUNTIME_VERSION" \
    "$WORK_DIR/reference-pack"
download_nuget_package \
    "Microsoft.Net.Compilers.Toolset" \
    "$ROSLYN_VERSION" \
    "$WORK_DIR/roslyn-pack"

NATIVE_DIR="$WORK_DIR/runtime-pack/runtimes/ios-arm64/native"
if [[ ! -d "$NATIVE_DIR" ]]; then
    echo "Expected native runtime directory was not found: $NATIVE_DIR" >&2
    find "$WORK_DIR/runtime-pack" -maxdepth 5 -type d -print
    exit 1
fi

MONO_LIBRARY="$NATIVE_DIR/libmonosgen-2.0.a"
if [[ ! -f "$MONO_LIBRARY" ]]; then
    echo "The iOS runtime pack does not contain libmonosgen-2.0.a." >&2
    find "$NATIVE_DIR" -maxdepth 2 -type f -print | sort
    exit 1
fi

HEADER_DIR="$NATIVE_DIR/include/mono-2.0"
if [[ ! -f "$HEADER_DIR/mono/jit/jit.h" ]]; then
    echo "Mono embedding headers are missing from the iOS runtime pack." >&2
    exit 1
fi

RUNTIME_LIBRARIES=("$MONO_LIBRARY")
while IFS= read -r library; do
    case "$(basename "$library")" in
        libmonosgen-2.0.a|libmono-component-*.a) ;;
        *) RUNTIME_LIBRARIES+=("$library") ;;
    esac
done < <(find "$NATIVE_DIR" -maxdepth 1 -type f -name '*.a' | sort)

while IFS= read -r stub; do
    RUNTIME_LIBRARIES+=("$stub")
done < <(find "$NATIVE_DIR" -maxdepth 1 -type f -name 'libmono-component-*-stub-static.a' | sort)

MARSHAL_COMPONENT="$NATIVE_DIR/libmono-component-marshal-ilgen-static.a"
if [[ -f "$MARSHAL_COMPONENT" ]]; then
    filtered=()
    for library in "${RUNTIME_LIBRARIES[@]}"; do
        if [[ "$(basename "$library")" != "libmono-component-marshal-ilgen-stub-static.a" ]]; then
            filtered+=("$library")
        fi
    done
    RUNTIME_LIBRARIES=("${filtered[@]}" "$MARSHAL_COMPONENT")
fi

echo "Native Mono libraries selected for Code App:"
printf '  %s\n' "${RUNTIME_LIBRARIES[@]}"

libtool -static -o "$WORK_DIR/libMonoRuntime.a" "${RUNTIME_LIBRARIES[@]}"

SYMBOLS_FILE="$WORK_DIR/mono-runtime-symbols.txt"
nm -gU "$WORK_DIR/libMonoRuntime.a" > "$SYMBOLS_FILE"

if ! grep -q '_mono_jit_init$' "$SYMBOLS_FILE"; then
    echo "Mono runtime archive has no mono_jit_init symbol." >&2
    exit 1
fi
if ! grep -q '_mono_jit_compile_method$' "$SYMBOLS_FILE"; then
    echo "The official ios-arm64 runtime pack was built without the Mono JIT compiler." >&2
    echo "A source build is required for the StikDebug/JIT configuration." >&2
    exit 1
fi

xcodebuild -create-xcframework \
    -library "$WORK_DIR/libMonoRuntime.a" \
    -headers "$HEADER_DIR" \
    -output "$OUTPUT_DIR/MonoRuntime.xcframework"

CORELIB="$(find "$WORK_DIR/runtime-pack" -type f -name 'System.Private.CoreLib.dll' | head -n 1)"
if [[ -z "$CORELIB" ]]; then
    echo "System.Private.CoreLib.dll is absent from the iOS runtime pack." >&2
    exit 1
fi
RUNTIME_MANAGED_DIR="$(dirname "$CORELIB")"
find "$RUNTIME_MANAGED_DIR" -maxdepth 1 -type f \( -name '*.dll' -o -name '*.json' \) \
    -exec cp {} "$OUTPUT_DIR/MonoManaged/runtime/" \;

REFERENCE_DIR="$WORK_DIR/reference-pack/ref/net8.0"
if [[ ! -f "$REFERENCE_DIR/System.Runtime.dll" ]]; then
    echo "The net8.0 reference pack is incomplete." >&2
    exit 1
fi
cp "$REFERENCE_DIR"/*.dll "$OUTPUT_DIR/MonoManaged/ref/"

ROSLYN_DIR="$WORK_DIR/roslyn-pack/tasks/netcore/bincore"
if [[ ! -f "$ROSLYN_DIR/csc.dll" ]]; then
    echo "Roslyn csc.dll was not found in Microsoft.Net.Compilers.Toolset." >&2
    find "$WORK_DIR/roslyn-pack" -type f -name 'csc.dll' -print
    exit 1
fi
find "$ROSLYN_DIR" -maxdepth 1 -type f \( -name '*.dll' -o -name '*.json' \) \
    -exec cp {} "$OUTPUT_DIR/MonoManaged/tools/" \;

test -f "$OUTPUT_DIR/MonoManaged/runtime/System.Private.CoreLib.dll"
test -f "$OUTPUT_DIR/MonoManaged/ref/System.Runtime.dll"
test -f "$OUTPUT_DIR/MonoManaged/tools/csc.dll"

RUNTIME_SIZE="$(du -sk "$OUTPUT_DIR/MonoRuntime.xcframework" | awk '{print $1}')"
MANAGED_SIZE="$(du -sk "$OUTPUT_DIR/MonoManaged" | awk '{print $1}')"
if (( RUNTIME_SIZE < 5000 )); then
    echo "MonoRuntime.xcframework is suspiciously small: ${RUNTIME_SIZE} KiB" >&2
    exit 1
fi
if (( MANAGED_SIZE < 30000 )); then
    echo "Mono managed payload is suspiciously small: ${MANAGED_SIZE} KiB" >&2
    exit 1
fi

echo "MonoRuntime.xcframework: ${RUNTIME_SIZE} KiB"
echo "MonoManaged: ${MANAGED_SIZE} KiB"
echo "Runtime assemblies: $(find "$OUTPUT_DIR/MonoManaged/runtime" -name '*.dll' | wc -l | tr -d ' ')"
echo "Reference assemblies: $(find "$OUTPUT_DIR/MonoManaged/ref" -name '*.dll' | wc -l | tr -d ' ')"
echo "Roslyn assemblies: $(find "$OUTPUT_DIR/MonoManaged/tools" -name '*.dll' | wc -l | tr -d ' ')"
