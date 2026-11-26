#!/bin/sh
# Exercise real compilers and runtimes inside isolate, with production paths.
set -eu
family=${1:?runner family required}
mkdir -p /sys/fs/cgroup/isolate /sys/fs/cgroup/init
for pid in $(cat /sys/fs/cgroup/cgroup.procs 2>/dev/null); do
    echo "$pid" > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
done
echo '+cpu +memory +pids' > /sys/fs/cgroup/cgroup.subtree_control
echo '+cpu +memory +pids' > /sys/fs/cgroup/isolate/cgroup.subtree_control
mkdir -p /run/isolate/locks /var/local/lib/isolate
echo /sys/fs/cgroup/isolate > /run/isolate/cgroup
cleanup() { isolate --cg -b 42 --cleanup; }
trap cleanup EXIT HUP INT TERM
box=$(isolate --cg -b 42 --init)/box
chmod 777 "$box"
compile() {
    cpu=60 wall=120 memory=1048576 file_size=131072 address_limit=
    if [ "${2:-}" = native ]; then
        cpu=10 wall=12 memory=262144 file_size=10240 address_limit=--mem=262144
    fi
    isolate --cg -b 42 --run --processes=128 --time="$cpu" --wall-time="$wall" \
        --cg-mem="$memory" --fsize="$file_size" $address_limit --env=PATH=/usr/local/bin:/usr/bin:/bin \
        --env=HOME=/box --env=TMPDIR=/tmp --env=LANG=en_US.UTF-8 --env=LC_ALL=en_US.UTF-8 -- /bin/sh -ec "$1"
}
run() {
    address_limit=
    if [ "${2:-}" = address ]; then address_limit=--mem=65536; fi
    isolate --cg -b 42 --run --processes=64 --time=10 --wall-time=20 --fsize=1024 \
        --cg-mem=65536 $address_limit --env=PATH=/usr/local/bin:/usr/bin:/bin \
        --env=HOME=/box --env=TMPDIR=/tmp --env=LANG=en_US.UTF-8 --env=LC_ALL=en_US.UTF-8 --env=NODE_OPTIONS=--max-old-space-size=32 \
        --env=DOTNET_GCHeapHardLimit=2000000 --env=DOTNET_PROCESSOR_COUNT=1 --env=DOTNET_EnableDiagnostics=0 \
        --env=DOTNET_EnableWriteXorExecute=0 -- /bin/sh -ec "$1" > "$box/result"
    test "$(cat "$box/result")" = '42'
}
case "$family" in
    runner-compiled)
        printf '#include <stdio.h>\nint main(void){puts("42");}\n' > "$box/main.c"
        compile 'gcc -std=c17 -O2 main.c -o out -lm' native; run './out' address
        printf '#include <iostream>\nint main(){std::cout << 42 << "\\n";}\n' > "$box/main.cpp"
        compile 'g++ -O3 main.cpp -o out' native; run './out' address
        printf 'package main\nimport "fmt"\nfunc main(){fmt.Println(42)}\n' > "$box/main.go"
        compile '
            export GOMAXPROCS=2 GOCACHE="$PWD/.cache/go" GOPATH="$PWD/.cache/gopath"
            export GOENV=off GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local CGO_ENABLED=0
            if command -v athena-go-cache >/dev/null 2>&1; then
                export GOCACHEPROG="$(command -v athena-go-cache)"
            fi
            go build -trimpath -o out main.go
        '; run './out'
        printf 'import Foundation\nprint(42)\n' > "$box/main.swift"
        compile '
            mkdir -p "$PWD/.cache/swift"
            swiftc -swift-version 6 -O -module-cache-path "$PWD/.cache/swift" -Xlinker -rpath -Xlinker /usr/local/swift/usr/lib/swift/linux main.swift -o out
        '; run './out'
        printf 'fn main(){println!("42");}\n' > "$box/main.rs"
        compile 'rustc --edition=2024 -C linker=/usr/bin/gcc -O main.rs -o out'; run './out' address
        # libc output avoids depending on changing Zig std.io APIs.
        printf 'extern "c" fn puts([*:0]const u8) c_int;\npub fn main() void { _ = puts("42"); }\n' > "$box/main.zig"
        compile '
            export ZIG_GLOBAL_CACHE_DIR="$PWD/.cache/zig-global" ZIG_LOCAL_CACHE_DIR="$PWD/.cache/zig-local"
            # Private caches and one job allow advisory lock emulation.
            # Keep the syscall filter enabled; trace only compilation.
            strace -f -qq -o /dev/null -e trace=flock -e inject=flock:retval=0 -- zig build-exe -j1 main.zig -lc -O ReleaseSafe -femit-bin=out
        '; run './out' address
        ;;
    runner-script)
        printf 'print(42)\n' > "$box/main.py"
        run 'python3 main.py' address
        printf 'console.log(42);\n' > "$box/main.js"
        run 'node main.js'
        printf 'import { readFileSync } from "node:fs";\nconst answer: number = 42; console.log(answer);\n' > "$box/main.ts"
        compile '
            export NODE_OPTIONS=--max-old-space-size=512
            type_roots="$(npm root --global)/@types"
            tsc --strict --noEmitOnError --target ES2022 --module node16 --moduleResolution node16 --typeRoots "$type_roots" --types node main.ts
        '; run 'node main.js'
        printf 'const broken: number = "wrong";\n' > "$box/main.ts"
        rm "$box/main.js"
        if compile '
            export NODE_OPTIONS=--max-old-space-size=512
            type_roots="$(npm root --global)/@types"
            tsc --strict --noEmitOnError --target ES2022 --module node16 --moduleResolution node16 --typeRoots "$type_roots" --types node main.ts
        '; then
            echo 'TypeScript accepted a type error' >&2; exit 1
        fi
        test ! -e "$box/main.js"
        ;;
    runner-jvm)
        printf 'public class Main { public static void main(String[] args) { System.out.println(42); } }\n' > "$box/Main.java"
        compile 'javac -J-XX:ActiveProcessorCount=2 -J-Xmx512m --release 21 Main.java'
        run 'java -XX:ActiveProcessorCount=1 -XX:+UseSerialGC -Xms8m -Xmx32m -cp /box Main'
        printf 'fun main() { println(42) }\n' > "$box/Main.kt"
        compile 'kotlinc -J-XX:ActiveProcessorCount=2 -J-Xmx512m -jvm-target 21 Main.kt -include-runtime -d main.jar'
        run 'java -XX:ActiveProcessorCount=1 -XX:+UseSerialGC -Xms8m -Xmx32m -jar main.jar'
        ;;
    runner-dotnet)
        printf 'using System;\nclass MainClass { static void Main() { Console.WriteLine(42); } }\n' > "$box/Main.cs"
        mkdir -p "$box/out"
        chmod 777 "$box/out"
        cat > "$box/ImplicitUsings.g.cs" <<'CS'
global using global::System;
global using global::System.Collections.Generic;
global using global::System.IO;
global using global::System.Linq;
global using global::System.Net.Http;
global using global::System.Threading;
global using global::System.Threading.Tasks;
CS
        cat > "$box/out/Main.runtimeconfig.json" <<'JSON'
{"runtimeOptions":{"tfm":"net10.0","framework":{"name":"Microsoft.NETCore.App","version":"10.0.0"}}}
JSON
        compile '
            export DOTNET_PROCESSOR_COUNT=2 DOTNET_EnableDiagnostics=0
            DOTNET_ROOT="$(dirname "$(readlink -f "$(command -v dotnet)")")"
            export DOTNET_ROOT
            : > references.rsp
            for reference in "$DOTNET_ROOT"/packs/Microsoft.NETCore.App.Ref/*/ref/net10.0/*.dll; do
                test -f "$reference"
                printf -- "-r:%s\n" "$reference" >> references.rsp
            done
            set -- "$DOTNET_ROOT"/sdk/*/Roslyn/bincore/csc.dll
            if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
                echo "Expected exactly one pinned Roslyn compiler" >&2
                exit 1
            fi
            dotnet "$1" -nologo -noconfig -nostdlib+ -target:exe -langversion:14.0 -optimize+ -deterministic+ -out:out/Main.dll @references.rsp ImplicitUsings.g.cs Main.cs
        '
        run 'dotnet out/Main.dll'
        ;;
    *) echo "Unknown family: $family" >&2; exit 1 ;;
esac
echo "Language smoke checks passed: $family"
