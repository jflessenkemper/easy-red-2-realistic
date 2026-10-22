# shellcheck shell=bash
# Source me: puts the review toolchain (luarocks --local, pipx, ~/.local/bin) on PATH/LUA_PATH.
export PATH="$HOME/.luarocks/bin:$HOME/.local/bin:$PATH"
command -v luarocks >/dev/null 2>&1 && eval "$(luarocks --lua-version 5.1 path 2>/dev/null)"
# luarocks' LUA_PATH replaces the default search path, which hides luajit's own jit.* modules and
# breaks `luajit -bl` (the bytecode listing checks 2/4d depend on). ';;' re-appends the defaults.
export LUA_PATH="${LUA_PATH:-};;" LUA_CPATH="${LUA_CPATH:-};;"
