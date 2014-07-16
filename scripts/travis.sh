#!/bin/sh -e

tmpdir="$(pwd)/tmp"
rm -rf "$tmpdir"
mkdir -p "$tmpdir"
suppressions="$(pwd)/.valgrind.supp"

valgrind_check() {
    (
    cd $1
    set -- valgrind-[*] valgrind-*
    case $1$2 in
        'valgrind-[*]valgrind-*')
            ;;
        *)
            shift
            local err=''
            for valgrind_log in "$@"; do
                # Remove useless warning
                sed -i "$valgrind_log" \
                    -e '/Warning: noted but unhandled ioctl/d' \
                    -e '/could cause spurious value errors to appear/d' \
                    -e '/See README_MISSING_SYSCALL_OR_IOCTL for guidance/d'
                if [ "$(stat -c %s $valgrind_log)" != "0" ]; then
                    # if after removing the warning, the log still has errors, show its
                    # contents and set the flag so we exit with non-zero status
                    cat "$valgrind_log"
                    err=1
                fi
            done
            if [ -n "$err" ]; then
                echo "Runtime errors detected"
                exit 1
            fi
            ;;
    esac
    )
}

asan_check() {
    (
    cd $1
    set -- [*]san.[*] *san.*
    case $1$2 in
        '[*]san.[*]*san.*')
            ;;
        *)
            shift
            cat "$@"
            echo "Runtime errors detected"
            exit 1
            ;;
    esac
    )
}

set_environment() {
    local prefix="$1"
    eval $($prefix/bin/luarocks path)
    export PATH="$prefix/bin:$PATH"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
    export USE_BUNDLED_DEPS=OFF
}

# install prebuilt dependencies
if [ ! -d /opt/neovim-deps ]; then
    cd /opt
    sudo git clone --depth=1 git://github.com/neovim/deps neovim-deps
    cd -
fi

# Travis reports back that it has 32-cores via /proc/cpuinfo, but it's not
# what we really have available.  According to their documentation, it only has
# 1.5 virtual cores.
# See:
#   http://docs.travis-ci.com/user/speeding-up-the-build/#Paralellizing-your-build-on-one-VM
# for more information.
MAKE_CMD="make -j2"

if [ "$TRAVIS_BUILD_TYPE" = "coverity" ]; then
    # temporarily disable error checking, the coverity script exits with
    # status code 1 whenever it (1) fails OR (2) is not on the correct
    # branch.
    set +e
    curl -s https://scan.coverity.com/scripts/travisci_build_coverity_scan.sh |
        COVERITY_SCAN_PROJECT_NAME="neovim/neovim" \
        COVERITY_SCAN_NOTIFICATION_EMAIL="coverity@aktau.be" \
        COVERITY_SCAN_BRANCH_PATTERN="coverity-scan" \
        COVERITY_SCAN_BUILD_COMMAND_PREPEND="$MAKE_CMD deps" \
        COVERITY_SCAN_BUILD_COMMAND="$MAKE_CMD nvim" \
        bash
    set -e
    exit 0
elif [ "$TRAVIS_BUILD_TYPE" = "clang/asan" ]; then
    clang_version=3.4
    if [ ! -d /usr/local/clang-$clang_version ]; then
        echo "Downloading clang $clang_version..."
        sudo mkdir /usr/local/clang-$clang_version
        wget -q -O - http://llvm.org/releases/$clang_version/clang+llvm-$clang_version-x86_64-unknown-ubuntu12.04.xz \
            | sudo tar xJf - --strip-components=1 -C /usr/local/clang-$clang_version
        export CC=/usr/local/clang-$clang_version/bin/clang
    else
        export CC=clang
    fi
    symbolizer=/usr/local/clang-$clang_version/bin/llvm-symbolizer

    sudo pip install cpp-coveralls
    set_environment /opt/neovim-deps

    export SANITIZE=1
    export ASAN_SYMBOLIZER_PATH=$symbolizer
    export ASAN_OPTIONS="detect_leaks=1:log_path=$tmpdir/asan"
    export TSAN_OPTIONS="external_symbolizer_path=$symbolizer:log_path=$tmpdir/tsan"

    export SKIP_UNITTEST=1
    export UBSAN_OPTIONS="log_path=$tmpdir/ubsan" # not sure if this works

    install_dir="$(pwd)/dist"
    $MAKE_CMD cmake CMAKE_EXTRA_FLAGS="-DTRAVIS_CI_BUILD=ON -DCMAKE_INSTALL_PREFIX=$install_dir -DUSE_GCOV=ON"
    $MAKE_CMD
    if ! $MAKE_CMD test; then
        reset
        asan_check "$tmpdir"
        exit 1
    fi
    asan_check "$tmpdir"
    coveralls --encoding iso-8859-1 || echo 'coveralls upload failed.'
    $MAKE_CMD install
elif [ "$TRAVIS_BUILD_TYPE" = "gcc/unittest" ]; then
    sudo pip install cpp-coveralls
    export CC=gcc
    set_environment /opt/neovim-deps
    export SKIP_EXEC=1
    $MAKE_CMD CMAKE_EXTRA_FLAGS="-DTRAVIS_CI_BUILD=ON -DBUSTED_OUTPUT_TYPE=TAP -DUSE_GCOV=ON" unittest
    coveralls --encoding iso-8859-1 || echo 'coveralls upload failed.'
elif [ "$TRAVIS_BUILD_TYPE" = "gcc/ia32" ]; then
    set_environment /opt/neovim-deps/32

    # Pins the version of the java package installed on the Travis VMs
    # and avoids a lengthy upgrade process for them.
    sudo apt-mark hold oracle-java7-installer oracle-java8-installer

    sudo apt-get update

    # Need this to keep apt-get from removing gcc when installing libncurses
    # below.
    sudo apt-get install libc6-dev libc6-dev:i386

    # Do this separately so that things get configured correctly, otherwise
    # libncurses fails to install.
    sudo apt-get install gcc-multilib g++-multilib

    # Install the dev version to get the pkg-config and symlinks installed
    # correctly.
    sudo apt-get install libncurses5-dev:i386

    CMAKE_EXTRA_FLAGS="-DTRAVIS_CI_BUILD=ON -DBUSTED_OUTPUT_TYPE=TAP \
        -DCMAKE_SYSTEM_PROCESSOR=i386 \
        -DCMAKE_SYSTEM_LIBRARY_PATH=/lib32:/usr/lib32:/usr/local/lib32 \
        -DFIND_LIBRARY_USE_LIB64_PATHS=OFF \
        -DCMAKE_IGNORE_PATH=/lib:/usr/lib:/usr/local/lib \
        -DCMAKE_TOOLCHAIN_FILE=cmake/i386-linux-gnu.toolchain.cmake"
    $MAKE_CMD CMAKE_EXTRA_FLAGS="${CMAKE_EXTRA_FLAGS}" unittest
    $MAKE_CMD test
elif [ "$TRAVIS_BUILD_TYPE" = "clint" ]; then
    ./scripts/clint.sh
elif [ "$TRAVIS_BUILD_TYPE" = "api/python" ]; then
    set_environment /opt/neovim-deps
    $MAKE_CMD
    sudo apt-get install expect valgrind
    git clone --depth=1 -b master git://github.com/neovim/python-client
    cd python-client
  sudo pip install .
  sudo pip install nose
    test_cmd="nosetests --verbosity=2"
    nvim_cmd="valgrind -q --track-origins=yes --leak-check=yes --suppressions=$suppressions --log-file=$tmpdir/valgrind-%p.log ../build/bin/nvim -u NONE"
    if ! ../scripts/run-api-tests.exp "$test_cmd" "$nvim_cmd"; then
        valgrind_check "$tmpdir"
        exit 1
    fi
    valgrind_check "$tmpdir"
fi
