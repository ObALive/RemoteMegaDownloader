#!/bin/bash
# 把内存 dump 出的程序集正确命名成可运行的应用目录，并修补 Blocker A
set -uo pipefail
ISO=/root/mdl_v18_isolated
APP="$ISO/app"
mkdir -p "$APP"
cd "$ISO/dumps" || exit 1

echo "=== 1) 按程序集真实名称归位 ==="
declare -A seen
for f in $(ls -S *.exe); do
    nm=$(monodis --assembly "$f" 2>/dev/null | awk '/^Name:/{print $2}' | head -1)
    [ -z "$nm" ] && continue
    [ -n "${seen[$nm]:-}" ] && continue
    seen[$nm]=1
    if [ "$nm" = "MegaDownloader" ]; then
        cp -f "$f" "$APP/MegaDownloader.exe"
        printf "  %-24s -> MegaDownloader.exe  (%s)\n" "$nm" "$(stat -c %s "$f")"
    else
        cp -f "$f" "$APP/$nm.dll"
        printf "  %-24s -> %s.dll  (%s)\n" "$nm" "$nm" "$(stat -c %s "$f")"
    fi
done

echo
echo "=== 2) 编写并编译 Cecil 补丁器 ==="
CECIL="$(find /usr/lib/mono -name Mono.Cecil.dll 2>/dev/null | head -1)"
echo "  Mono.Cecil: ${CECIL:-未找到}"
[ -z "$CECIL" ] && { echo "  x 无 Cecil"; exit 1; }

cat > "$ISO/SatellitePatcher.cs" <<'CSEOF'
using System;
using Mono.Cecil;
using Mono.Cecil.Cil;

class SatellitePatcher
{
    static int Patch(TypeDefinition t, int n)
    {
        foreach (TypeDefinition nested in t.NestedTypes) n = Patch(nested, n);
        foreach (MethodDefinition m in t.Methods)
        {
            if (m.Name != "LoadDLLFromStream" || !m.HasBody) continue;
            MethodBody body = m.Body;
            body.Instructions.Clear();
            body.Variables.Clear();
            body.ExceptionHandlers.Clear();
            ILProcessor il = body.GetILProcessor();
            il.Append(il.Create(OpCodes.Ldnull));
            il.Append(il.Create(OpCodes.Ret));
            Console.WriteLine("patched " + t.FullName + "::" + m.Name);
            n++;
        }
        return n;
    }

    static int Main(string[] args)
    {
        AssemblyDefinition asm = AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters { ReadWrite = false });
        int total = 0;
        foreach (TypeDefinition t in asm.MainModule.Types) total = Patch(t, total);
        asm.Write(args[1]);
        Console.WriteLine("TOTAL_PATCHED=" + total);
        return 0;
    }
}
CSEOF

mcs -out:"$ISO/patcher.exe" -r:"$CECIL" "$ISO/SatellitePatcher.cs" 2>&1 | head -5
[ -f "$ISO/patcher.exe" ] || { echo "  x 补丁器编译失败"; exit 1; }
echo "  OK 补丁器编译成功"

echo
echo "=== 3) 打补丁 ==="
mono "$ISO/patcher.exe" "$APP/MegaDownloader.exe" "$APP/MegaDownloader.patched.exe" 2>&1 | tail -4
[ -f "$APP/MegaDownloader.patched.exe" ] || { echo "  x 补丁失败"; exit 1; }

echo
echo "=== 4) 验证 ==="
monodis --assembly "$APP/MegaDownloader.patched.exe" 2>/dev/null | grep -E "Name:|Version:" | head -3
echo
echo "=== app 目录 ==="
ls -la "$APP"
