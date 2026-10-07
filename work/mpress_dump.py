#!/usr/bin/env python3
"""
从 Wine 进程内存中 dump 出 MPRESS 解壳后的 .NET 程序集。
原理: MPRESS 的 stub 在内存里还原原始 PE 后才交给 CLR，此时原始镜像存在于
      进程的匿名可读写映射中。扫描这些区域，寻找带 CLI Header 的合法 PE。
用法: mpress_dump.py <输出目录> [扫描秒数]
"""
import os, re, struct, sys, time, glob

outdir = sys.argv[1] if len(sys.argv) > 1 else "."
budget = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
os.makedirs(outdir, exist_ok=True)


def find_pids():
    """找出所有 wine 相关进程"""
    pids = []
    for d in glob.glob("/proc/[0-9]*"):
        try:
            with open(os.path.join(d, "comm")) as f:
                comm = f.read().strip()
        except OSError:
            continue
        if "MegaDownloader" in comm or comm.startswith("wine"):
            pids.append((int(os.path.basename(d)), comm))
    return pids


def parse_pe(buf, off):
    """校验 off 处是否为带 CLI Header 的 PE，返回 (is_managed, size_hint)"""
    if buf[off:off + 2] != b"MZ":
        return False, 0
    try:
        pe = struct.unpack_from("<I", buf, off + 0x3C)[0]
        if buf[off + pe:off + pe + 4] != b"PE\0\0":
            return False, 0
        nsec = struct.unpack_from("<H", buf, off + pe + 6)[0]
        optsz = struct.unpack_from("<H", buf, off + pe + 20)[0]
        opt = off + pe + 24
        magic = struct.unpack_from("<H", buf, opt)[0]
        ddoff = opt + (96 if magic == 0x10B else 112)
        cli_rva, cli_sz = struct.unpack_from("<II", buf, ddoff + 14 * 8)
        if cli_rva == 0 or cli_sz == 0:
            return False, 0
        # 估算镜像大小: 各节 raw 结束位置 + headers
        end = 0
        so = opt + optsz
        for i in range(nsec):
            o = so + i * 40
            _vs, _va, rs, pr = struct.unpack_from("<IIII", buf, o + 8)
            end = max(end, pr + rs)
        return True, max(end, pe + optsz)
    except (struct.error, IndexError):
        return False, 0


seen = set()
deadline = time.time() + budget
scan_round = 0

while time.time() < deadline:
    scan_round += 1
    targets = find_pids()
    if not targets:
        time.sleep(0.5)
        continue

    for pid, comm in targets:
        mpath = f"/proc/{pid}/maps"
        mfile = f"/proc/{pid}/mem"
        try:
            regions = []
            with open(mpath) as f:
                for line in f:
                    m = re.match(r"([0-9a-f]+)-([0-9a-f]+) (\S+)\s+\S+\s+\S+\s+\S+\s*(.*)", line)
                    if not m:
                        continue
                    lo, hi = int(m.group(1), 16), int(m.group(2), 16)
                    perms, name = m.group(3), m.group(4).strip()
                    # 只看可读写的匿名映射（解壳后的镜像通常在此）
                    if "r" in perms and "w" in perms and not name:
                        if 0 < hi - lo <= 64 * 1024 * 1024:
                            regions.append((lo, hi))
        except (OSError, IOError):
            continue

        for lo, hi in regions:
            try:
                with open(mfile, "rb", buffering=0) as f:
                    f.seek(lo)
                    buf = f.read(hi - lo)
            except (OSError, IOError, ValueError):
                continue

            start = 0
            while True:
                idx = buf.find(b"MZ", start)
                if idx < 0:
                    break
                start = idx + 1
                if idx + 0x40 > len(buf):
                    continue
                try:
                    pe = struct.unpack_from("<I", buf, idx + 0x3C)[0]
                except struct.error:
                    continue
                if pe <= 0 or pe > 0x1000 or idx + pe + 4 > len(buf):
                    continue
                ok, size = parse_pe(buf, idx)
                if not ok:
                    continue
                key = (pid, lo + idx)
                if key in seen:
                    continue
                seen.add(key)
                size = min(size, len(buf) - idx)
                out = os.path.join(outdir, f"unpacked_{pid}_{lo+idx:x}.exe")
                with open(out, "wb") as g:
                    g.write(buf[idx:idx + size])
                print(f"[+] 命中托管 PE: pid={pid} addr=0x{lo+idx:x} size={size} -> {out}")
                sys.stdout.flush()
    time.sleep(0.3)

print(f"扫描结束 ({scan_round} 轮)，共 dump {len(seen)} 个候选")
