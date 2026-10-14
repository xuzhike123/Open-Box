#!/usr/bin/env python3
"""裁剪 ELF 文件尾部不属于任何 PT_LOAD 段的内容,等价于 strip 的效果。

为什么需要它:上游 unofficial-builds 的 musl Node 二进制是**没 strip 过**的,
arm64 那份 121.83MB 里有 28.27MB 是 .symtab / .strtab / .debug_* ——这些节不在任何
PT_LOAD 段里,运行时一个字节都用不到,却要跟着进路由器 flash。实测 arm64 Node
24.18.0:121.83MB -> 93.76MB,再经 UPX 压缩是 23.85MB;不先裁剪直接 UPX 要 28.78MB,
即这一步额外省下约 4.9MB。而上游自己的发布包里 node/bin/node 正是 93.76MB,说明
他们也是(用 binutils 的 strip)这么做的。

为什么不用 binutils 的 strip / objcopy:与 dt-needed.py 同一个理由——构建机可能是
macOS,也可能是 x86_64 的 Linux,而目标是 aarch64 的 ELF;`strip` 需要装了对应交叉
架构的 binutils(apt 的 binutils-aarch64-linux-gnu),这在本地构建机上是个额外前置。
这里只做一件事实清楚的事:保留 ELF 头与全部程序头,把文件截断到最后一个 PT_LOAD
段结束的位置,并清掉节表指针(e_shoff/e_shnum/e_shstrndx)。

这么做是安全的:内核装载器与 musl 动态链接器只看程序头——PT_LOAD / PT_DYNAMIC /
PT_INTERP 及 DT_* 指向的内容(动态符号表 .dynsym、.dynstr、.gnu.hash、重定位表等)
都在 PT_LOAD 段内,一个都不会被裁掉。裁掉的只有节表区和"不加载"的节。
反过来,这也意味着**不能**在同一个文件上再用带节表的工具做检查:本脚本跑完之后
文件已经没有节表了,所以 build-release.sh 里它排在 dt-needed.py 的守卫之后。

用法:
  python3 elf-strip.py <elf 文件>           原地裁剪(必要时保留原文件备份)
  python3 elf-strip.py --check <elf 文件>   只报告能裁掉多少,不修改文件

两个用法都以退出码表达结果:0 = 成功(含"本来就没什么可裁"),非 0 = 失败。
失败时把原因打到 stderr,构建脚本据此直接中止。
"""
import os
import stat as stat_mod
import struct
import sys

PT_LOAD = 1

# ELF 头里各字段的偏移。32/64 位两套。
HDR_OFF = {
    32: {"e_phoff": 28, "e_shoff": 32, "e_phentsize": 42, "e_phnum": 44,
         "e_shentsize": 46, "e_shnum": 48, "e_shstrndx": 50},
    64: {"e_phoff": 32, "e_shoff": 40, "e_phentsize": 54, "e_phnum": 56,
         "e_shentsize": 58, "e_shnum": 60, "e_shstrndx": 62},
}


def die(msg):
    print(f"elf-strip.py: {msg}", file=sys.stderr)
    sys.exit(1)


def read_elf(path):
    with open(path, "rb") as fh:
        data = fh.read()

    if len(data) < 64 or data[:4] != b"\x7fELF":
        die(f"{path}: 不是 ELF 文件")

    ei_class = data[4]  # 1 = 32 位, 2 = 64 位
    ei_data = data[5]   # 1 = 小端, 2 = 大端
    if ei_class not in (1, 2):
        die(f"{path}: 未知 EI_CLASS {ei_class}")
    if ei_data not in (1, 2):
        die(f"{path}: 未知 EI_DATA {ei_data}")

    is64 = ei_class == 2
    endian = "<" if ei_data == 1 else ">"
    bits = 64 if is64 else 32
    off = HDR_OFF[bits]
    q = endian + ("Q" if is64 else "I")
    h = endian + "H"

    hdr = {
        "phoff": struct.unpack_from(q, data, off["e_phoff"])[0],
        "shoff": struct.unpack_from(q, data, off["e_shoff"])[0],
        "phentsize": struct.unpack_from(h, data, off["e_phentsize"])[0],
        "phnum": struct.unpack_from(h, data, off["e_phnum"])[0],
        "shnum": struct.unpack_from(h, data, off["e_shnum"])[0],
        "shstrndx": struct.unpack_from(h, data, off["e_shstrndx"])[0],
    }
    return data, is64, endian, bits, hdr


def load_end(data, is64, endian, hdr):
    """返回最后一个 PT_LOAD 段在文件里的结束偏移。"""
    if hdr["phnum"] == 0:
        die("没有程序头表(可能是个目标文件而不是可执行文件)")
    if hdr["phentsize"] < (56 if is64 else 32):
        die(f"程序头大小异常: {hdr['phentsize']}")

    end = 0
    found = 0
    for i in range(hdr["phnum"]):
        base = hdr["phoff"] + i * hdr["phentsize"]
        if base + hdr["phentsize"] > len(data):
            die("程序头表超出文件末尾,文件可能已损坏")
        if is64:
            p_type, _flags, p_offset, _vaddr, _paddr, p_filesz = \
                struct.unpack_from(endian + "IIQQQQ", data, base)
        else:
            p_type, p_offset, _vaddr, _paddr, p_filesz = \
                struct.unpack_from(endian + "IIIII", data, base)
        if p_type != PT_LOAD:
            continue
        found += 1
        if p_offset + p_filesz > len(data):
            die(f"PT_LOAD 段 #{i} 的 [0x{p_offset:x}, +0x{p_filesz:x}) 超出文件末尾,"
                f"文件已损坏或被截断过")
        end = max(end, p_offset + p_filesz)

    if found == 0:
        die("没有任何 PT_LOAD 段,不是可执行文件")
    return end


def main(argv):
    args = argv[1:]
    check_only = False
    if args and args[0] == "--check":
        check_only = True
        args = args[1:]
    if len(args) != 1:
        die("用法: elf-strip.py [--check] <elf 文件>")

    path = args[0]
    data, is64, endian, bits, hdr = read_elf(path)
    keep = load_end(data, is64, endian, hdr)

    if keep >= len(data):
        # 已经裁剪过(或本来就是 strip 过的):不是错误,构建脚本按"无需处理"继续。
        print(f"elf-strip.py: {path} 已无可裁剪内容"
              f"({len(data)} 字节,最后一个 PT_LOAD 结束于 {keep})")
        return 0

    saved = len(data) - keep
    if check_only:
        print(f"elf-strip.py: {path} 可裁剪 {saved} 字节"
              f"({len(data)} -> {keep},省 {saved * 100.0 / len(data):.1f}%)")
        return 0

    # 保险丝:文件头与程序头必须完整落在裁剪后的范围里,否则裁完就不是合法 ELF 了。
    header_end = max(hdr["phoff"] + hdr["phnum"] * hdr["phentsize"], 64)
    if keep < header_end:
        die(f"裁剪点 {keep} 小于 ELF 头+程序头表末尾 {header_end},拒绝执行")

    out = bytearray(data[:keep])
    off = HDR_OFF[bits]
    q = endian + ("Q" if is64 else "I")
    h = endian + "H"
    # 清掉节表指针。留着它们指向已不存在的区域,会让某些工具认为文件损坏;
    # 置零等于明确宣告"本文件没有节表",这正是 strip 之后的状态。
    struct.pack_into(q, out, off["e_shoff"], 0)
    struct.pack_into(h, out, off["e_shnum"], 0)
    struct.pack_into(h, out, off["e_shstrndx"], 0)

    # 原地替换但保留权限位(可执行位不能丢)。先写临时文件再 rename,避免写到一半
    # 失败时留下半个二进制——构建脚本对"半成品"零容忍。
    mode = stat_mod.S_IMODE(os.stat(path).st_mode)
    tmp = path + ".strip-tmp"
    try:
        with open(tmp, "wb") as fh:
            fh.write(out)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"写回 {path} 失败: {exc}")

    print(f"elf-strip.py: {path} {len(data)} -> {keep} 字节"
          f"(裁掉 {saved},{saved * 100.0 / len(data):.1f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
