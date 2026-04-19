#!/usr/bin/env bash
# Copyright ©2022-2024 XSans0

# Environment checker
echo "Checking environment ..."
for environment in BRANCH; do
    [ -z "${!environment}" ] && {
        echo "$environment is not set, bailing out"
        exit 1
    }
done
NO_GH=0
if [ -z "$GITHUB_TOKEN" ]; then
    NO_GH=1
fi

NO_TG=0
if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    NO_TG=1
fi

# Get home directory
HOME_DIR="$(pwd)"

# Telegram setup
send_msg() {
    if (( ! NO_TG )); then
        bash "$HOME_DIR/tg_utils.sh" msg "$1"
    fi
}
send_file() {
	if (( ! NO_TG )); then
        bash "$HOME_DIR/tg_utils.sh" up "$1" "$2"
    fi
}

GH_USER=kaguya-ir0p
GH_REPO=tc_builds

# Build LLVM
echo "building LLVM..."
send_msg "gh $RUN_NUM: building LLVM"

./build-llvm.py \
    --defines LLVM_PARALLEL_COMPILE_JOBS="$(nproc)" LLVM_PARALLEL_LINK_JOBS="$(nproc)" CMAKE_C_FLAGS=-O3 CMAKE_CXX_FLAGS=-O3 \
    --install-folder "$HOME_DIR/install" \
    --no-update \
    --no-ccache \
    --quiet-cmake \
    --ref "$BRANCH" \
    --shallow-clone \
    --targets AArch64 ARM X86 \
    --lto thin \
    --clang-vendor-string "Tsukuyomi" \
    --lld-vendor-string "Fushi"

# Check if the final clang binary exists or not
for file in install/bin/clang-[1-9]*; do
    if [ -e "$file" ]; then
        echo "LLVM build successful"
    else
        echo "LLVM build failed"
        send_msg "gh $RUN_NUM: LLVM build failed"
        exit 1
    fi
done

# Build binutils
echo "building binutils..."
send_msg "gh $RUN_NUM: building binutils"
./build-binutils.py \
    --install-folder "$HOME_DIR/install" \
    --targets arm aarch64 x86_64

# Remove unused products
rm -fr install/include
rm -f install/lib/*.a install/lib/*.la install/lib/clang/*/lib/*/*.a install/lib/clang/*/lib/*/*.syms

# Strips remaining products
for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
    strip -s "${f::-1}"
done

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
    # Remove last character from file output (':')
    bin="${bin::-1}"

    echo "$bin"
    patchelf --set-rpath "$DIR/../lib" "$bin"
done

# Get Clang Info
pushd "$HOME_DIR"/src/llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<<"$llvm_commit")"
popd || exit
llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"
clang_version="$("$HOME_DIR"/install/bin/clang --version | head -n1 | cut -d' ' -f4)"
build_date="$(TZ=Asia/Tokyo date +"%Y-%m-%d")"
tags="Tsukuyomi-Clang-$clang_version"
file="Tsukuyomi-Clang-$clang_version.tar.gz"

# Get binutils version
binutils_version=$(grep "LATEST_BINUTILS_RELEASE" build-binutils.py)
binutils_version=$(echo "$binutils_version" | grep -oP '\(\s*\K\d+,\s*\d+,\s*\d+' | tr -d ' ')
binutils_version=$(echo "$binutils_version" | tr ',' '.')

# Create simple info
pushd "$HOME_DIR"/install || exit
{
    echo "build date: $build_date
clang version: $clang_version
binutils version: $binutils_version
llvm commit: $llvm_commit_url"
} > README.md
tar -czvf ../"$file" .
popd || exit

# Check tags already exists or not
overwrite=y
git tag -l | grep "$tags" || overwrite=n

# Upload to github release
failed=n
if [ "$overwrite" == "y" ] && (( ! NO_GH )) ; then
    ./github-release edit \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --description "$(cat "$HOME_DIR"/install/README.md)"

    ./github-release upload \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --name "$file" \
        --file "$HOME_DIR/$file" \
        --replace || failed=y
else
    ./github-release release \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --description "$(cat "$HOME_DIR"/install/README.md)"

    ./github-release upload \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --name "$file" \
        --file "$HOME_DIR/$file" || failed=y
fi

attempts=0
# Handle uploader if upload failed
while [ "$failed" == "y" ] && [ "$attempts" -le "10" ] && (( ! NO_GH )); do
    failed=n
    echo "upload failed, trying again..."
    ./github-release upload \
        --user "$GH_USER" \
        --repo "$GH_REPO" \
        --tag "$tags" \
        --name "$file" \
        --file "$HOME_DIR/$file" \
        --replace || failed=y
    attempts=$(( attempts + 1 ))
done

[ "$failed" == "y" ] && { send_msg "gh $RUN_NUM: failed in $((SECONDS / 60))m and $((SECONDS % 60))s" && exit 1 ; }

# Send message to telegram
send_msg "gh $RUN_NUM: done in $((SECONDS / 60))m and $((SECONDS % 60))s%nlgh $RUN_NUM: clang version: $clang_version%nlgh $RUN_NUM: binutils version: $binutils_version%nlgh $RUN_NUM: llvm commit: $llvm_commit_url"
