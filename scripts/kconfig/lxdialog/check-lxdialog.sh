#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Check ncurses compatibility (patched for modern distros)

ldflags()
{
        pkg-config --libs ncursesw 2>/dev/null && exit
        pkg-config --libs ncurses 2>/dev/null && exit
        for ext in so a dll.a dylib ; do
                for lib in ncursesw ncurses curses ; do
                        $cc -print-file-name=lib${lib}.${ext} | grep -q /
                        if [ $? -eq 0 ]; then
                                echo "-l${lib}"
                                exit
                        fi
                done
        done
        exit 1
}

ccflags()
{
        if pkg-config --cflags ncursesw 2>/dev/null; then
                echo '-DCURSES_LOC="<ncurses.h>" -DNCURSES_WIDECHAR=1'
        elif pkg-config --cflags ncurses 2>/dev/null; then
                echo '-DCURSES_LOC="<ncurses.h>"'
        elif [ -f /usr/include/ncursesw/curses.h ]; then
                echo '-I/usr/include/ncursesw -DCURSES_LOC="<curses.h>"'
                echo ' -DNCURSES_WIDECHAR=1'
        elif [ -f /usr/include/ncurses/ncurses.h ]; then
                echo '-I/usr/include/ncurses -DCURSES_LOC="<ncurses.h>"'
        elif [ -f /usr/include/ncurses/curses.h ]; then
                echo '-I/usr/include/ncurses -DCURSES_LOC="<curses.h>"'
        elif [ -f /usr/include/ncurses.h ]; then
                echo '-DCURSES_LOC="<ncurses.h>"'
        else
                echo '-DCURSES_LOC="<curses.h>"'
        fi
}

tmp=.lxdialog.tmp
trap "rm -f $tmp $tmp.c" 0 1 2 3 15

# 直接用 ncurses.h，绕过 CURSES_LOC 传参问题
check() {
        cat > $tmp.c <<'EOF'
#include <ncurses.h>
int main(void) { initscr(); endwin(); return 0; }
EOF
        # 提取编译器名（忽略后面的 flags）
        local_cc=$(echo "$cc" | awk '{print $1}')
        $local_cc -x c $tmp.c -o $tmp -lncursesw 2>/dev/null
        if [ $? != 0 ]; then
            $local_cc -x c $tmp.c -o $tmp -lncurses 2>/dev/null
            if [ $? != 0 ]; then
                echo " *** Unable to find the ncurses libraries or the"       1>&2
                echo " *** required header files."                            1>&2
                echo " *** 'make menuconfig' requires the ncurses libraries." 1>&2
                echo " *** "                                                  1>&2
                echo " *** Install ncurses (ncurses-devel) and try again."    1>&2
                echo " *** "                                                  1>&2
                exit 1
            fi
        fi
}

usage() {
        printf "Usage: $0 [-check compiler options|-ccflags|-ldflags compiler options]\n"
}

if [ $# -eq 0 ]; then
        usage
        exit 1
fi

cc=""
case "$1" in
        "-check")
                shift
                cc="$@"
                check
                ;;
        "-ccflags")
                ccflags
                ;;
        "-ldflags")
                shift
                cc="$@"
                ldflags
                ;;
        "*")
                usage
                exit 1
                ;;
esac
