#!/usr/bin/env bash
set -eu

# OUT_DIR is for everything except the exe. The exe needs to stay in root
# folder so it sees the assets folder, without having to copy it.
OUT_DIR=build/hot_reload
case $(uname) in
MINGW*|MSYS*) EXE=game_hot_reload.exe ;;
*)            EXE=game_hot_reload.bin ;;
esac

mkdir -p $OUT_DIR

# root is a special command of the odin compiler that tells you where the Odin
# compiler is located.
ROOT=$(odin root)

# Figure out which DLL extension to use based on platform. Also copy the Linux
# so libs.
case $(uname) in
"Darwin")
    DLL_EXT=".dylib"
    EXTRA_LINKER_FLAGS="-Wl,-rpath $ROOT/vendor/raylib/macos"
    ;;
MINGW*|MSYS*)
    DLL_EXT=".dll"
    EXTRA_LINKER_FLAGS=""

    # Copy raylib.dll next to the executable so the game DLL can find it.
    if [ ! -f "raylib.dll" ]; then
        cp "$ROOT/vendor/raylib/windows/raylib.dll" .
    fi
    ;;
*)
    DLL_EXT=".so"
    EXTRA_LINKER_FLAGS="'-Wl,-rpath=\$ORIGIN/linux'"

    # Copy the linux libraries into the project automatically.
    if [ ! -d "$OUT_DIR/linux" ]; then
        mkdir -p $OUT_DIR/linux
        cp -r $ROOT/vendor/raylib/linux/libraylib*.so* $OUT_DIR/linux
    fi
    ;;
esac

# Build the game. Note that the game goes into $OUT_DIR while the exe stays in
# the root folder.
echo "Building game$DLL_EXT"
LINKER_FLAG_ARG=""
if [ -n "$EXTRA_LINKER_FLAGS" ]; then
    LINKER_FLAG_ARG="-extra-linker-flags:$EXTRA_LINKER_FLAGS"
fi
odin build source $LINKER_FLAG_ARG -define:RAYLIB_SHARED=true -build-mode:dll -out:$OUT_DIR/game_tmp$DLL_EXT -strict-style -debug

# Need to use a temp file on Linux because it first writes an empty `game.so`,
# which the game will load before it is actually fully written.
mv $OUT_DIR/game_tmp$DLL_EXT $OUT_DIR/game$DLL_EXT

# If the executable is already running, then don't try to build and start it.
if command -v pgrep > /dev/null 2>&1; then
    if pgrep -f $EXE > /dev/null; then
        echo "Hot reloading..."
        exit 0
    fi
elif command -v tasklist > /dev/null 2>&1; then
    if tasklist | grep -q $EXE; then
        echo "Hot reloading..."
        exit 0
    fi
fi

echo "Building $EXE"
odin build source/main_hot_reload -out:$EXE -strict-style -debug

if [ $# -ge 1 ] && [ $1 == "run" ]; then
    echo "Running $EXE"
    ./$EXE &
fi
