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
        compile '/usr/local/bin/athena-go-compile'; run './out'
        printf 'import Foundation\nprint(42)\n' > "$box/main.swift"
        compile '/usr/local/bin/athena-swift-compile'; run './out'
        printf 'fn main(){println!("42");}\n' > "$box/main.rs"
        compile '/usr/local/bin/rustc --edition=2024 -C linker=/usr/bin/gcc -O main.rs -o out'; run './out' address
        # libc output avoids depending on changing Zig std.io APIs.
        printf 'extern "c" fn puts([*:0]const u8) c_int;\npub fn main() void { _ = puts("42"); }\n' > "$box/main.zig"
        compile '/usr/local/bin/athena-zig-compile'; run './out' address
        ;;
    runner-script)
        printf 'print(42)\n' > "$box/main.py"
        run 'python3 main.py' address
        printf 'console.log(42);\n' > "$box/main.js"
        run '/usr/local/bin/node main.js'
        printf 'import { readFileSync } from "node:fs";\nconst answer: number = 42; console.log(answer);\n' > "$box/main.ts"
        compile '/usr/local/bin/athena-typescript-compile'; run '/usr/local/bin/node main.js'
        printf 'const broken: number = "wrong";\n' > "$box/main.ts"
        rm "$box/main.js"
        if compile '/usr/local/bin/athena-typescript-compile'; then
            echo 'TypeScript accepted a type error' >&2; exit 1
        fi
        test ! -e "$box/main.js"
        ;;
    runner-jvm)
        printf 'public class Main { public static void main(String[] args) { System.out.println(42); } }\n' > "$box/Main.java"
        compile '/usr/local/bin/javac -J-XX:ActiveProcessorCount=2 -J-Xmx512m --release 21 Main.java'
        run '/usr/local/bin/java -XX:ActiveProcessorCount=1 -XX:+UseSerialGC -Xms8m -Xmx32m -cp /box Main'
        printf 'fun main() { println(42) }\n' > "$box/Main.kt"
        compile '/usr/local/bin/kotlinc -J-XX:ActiveProcessorCount=2 -J-Xmx512m -jvm-target 21 Main.kt -include-runtime -d main.jar'
        run '/usr/local/bin/java -XX:ActiveProcessorCount=1 -XX:+UseSerialGC -Xms8m -Xmx32m -jar main.jar'
        ;;
    runner-dotnet)
        printf 'using System;\nclass MainClass { static void Main() { Console.WriteLine(42); } }\n' > "$box/Main.cs"
        compile '/usr/local/bin/athena-csharp-compile'
        run '/usr/local/bin/dotnet out/Main.dll'
        ;;
    *) echo "Unknown family: $family" >&2; exit 1 ;;
esac
echo "Language smoke checks passed: $family"
