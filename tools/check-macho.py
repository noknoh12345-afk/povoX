#!/usr/bin/env python3
"""IPA / .app の中の実行ファイルが、iPhone に無いファイルを読み込もうとしていないかを調べる。

iPhone でアプリが読み込めるライブラリ(Mach-O の LC_LOAD_DYLIB など)は
  - OS のもの        /System/Library/... と /usr/lib/...
  - アプリの中のもの  @rpath/... @executable_path/... @loader_path/... で、実際に .app の中にあるもの
のどちらかだけ。それ以外(例: ビルドした Mac の /Users/runner/...)を参照していると、
起動した瞬間に dyld が止めてアプリが落ちる。シミュレータはビルドした Mac の上で動くので
この種の誤りに気づけない(build-9/10 で実際に起きた)。そこで IPA を毎回これで検査する。

ほかに見ること:
  - LC_RPATH にビルドした Mac の場所が入っていない
  - --platform を指定したら、すべての実行ファイルがその向け(ios = 実機 / iossim = シミュレータ)
  - 実行ファイルの最低 iOS(minos)が Info.plist の MinimumOSVersion を超えていない
  - Info.plist の CFBundleExecutable の実行ファイルがある

使い方: check-macho.py [--platform ios|iossim] [--expect-plugins N] <ipa または .app> ...
問題があれば終了コード 1。Mac の otool に頼らず Python だけで動く(Linux でも使える)。
"""
import argparse
import os
import plistlib
import posixpath
import stat
import struct
import sys
import zipfile

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32

DYLIB_CMDS = {
    LC_LOAD_DYLIB: "load",
    LC_LOAD_WEAK_DYLIB: "weak",
    LC_REEXPORT_DYLIB: "reexport",
    LC_LAZY_LOAD_DYLIB: "lazy",
    LC_LOAD_UPWARD_DYLIB: "upward",
}
PLATFORMS = {1: "macos", 2: "ios", 3: "tvos", 4: "watchos", 6: "maccatalyst", 7: "iossim"}
SYSTEM_PREFIXES = ("/System/Library/", "/usr/lib/")

MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
FILETYPES = {2: "executable", 6: "dylib", 8: "bundle"}


def version(x):
    return (x >> 16, (x >> 8) & 0xFF, x & 0xFF)


def vtext(v):
    return "%d.%d.%d" % v if v else "?"


def parse_version_text(s):
    parts = [int(p) for p in str(s).split(".") if p.isdigit()]
    return tuple((parts + [0, 0, 0])[:3])


def thin_slices(data):
    """data の中の Mach-O(アーキテクチャごと)の開始位置。Mach-O でなければ空。"""
    if len(data) < 32:
        return []
    be = struct.unpack_from(">I", data, 0)[0]
    if be in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack_from(">I", data, 4)[0]
        if n == 0 or n > 16:  # Java の class ファイルも CAFEBABE で始まる
            return []
        out = []
        for i in range(n):
            if be == FAT_MAGIC:
                _, _, off, size, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            else:
                _, _, off, size, _, _ = struct.unpack_from(">iiQQII", data, 8 + i * 32)
            if off + size <= len(data):
                out.append(off)
        return out
    le = struct.unpack_from("<I", data, 0)[0]
    if le in (MH_MAGIC, MH_MAGIC_64):
        return [0]
    return []


def cstr(data, start, end):
    e = data.find(b"\0", start, end)
    return data[start:(e if e >= 0 else end)].decode("utf-8", "replace")


def parse_macho(data, off):
    magic, cputype, _, filetype, ncmds, sizeofcmds, _ = struct.unpack_from("<IiiIIII", data, off)
    p = off + (32 if magic == MH_MAGIC_64 else 28)
    end = p + sizeofcmds
    info = {"cputype": cputype, "filetype": filetype, "dylibs": [], "rpaths": [],
            "id": None, "platform": None, "minos": None, "sdk": None}
    for _ in range(ncmds):
        if p + 8 > end:
            raise ValueError("ロードコマンドが壊れています")
        cmd, cmdsize = struct.unpack_from("<II", data, p)
        if cmdsize < 8 or p + cmdsize > end:
            raise ValueError("ロードコマンドの大きさが不正です")
        if cmd in DYLIB_CMDS or cmd == LC_ID_DYLIB:
            name = cstr(data, p + struct.unpack_from("<I", data, p + 8)[0], p + cmdsize)
            if cmd == LC_ID_DYLIB:
                info["id"] = name
            else:
                info["dylibs"].append((DYLIB_CMDS[cmd], name))
        elif cmd == LC_RPATH:
            info["rpaths"].append(cstr(data, p + struct.unpack_from("<I", data, p + 8)[0], p + cmdsize))
        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", data, p + 8)
            info.update(platform=platform, minos=version(minos), sdk=version(sdk))
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            minos, sdk = struct.unpack_from("<II", data, p + 8)
            info.update(platform=2, minos=version(minos), sdk=version(sdk))
        p += cmdsize
    return info


class Bundle:
    """.app の中身(IPA の zip でもフォルダでもよい)。パスは .app からの相対(区切りは /)。"""

    def __init__(self, label, files, read):
        self.label = label
        self.files = files  # 相対パス -> "file" | "link"
        self._read = read

    def read(self, rel):
        return self._read(rel)

    @staticmethod
    def from_ipa(path):
        z = zipfile.ZipFile(path)
        apps = sorted({n.split("/")[1] for n in z.namelist()
                       if n.startswith("Payload/") and n.count("/") >= 2 and n.split("/")[1].endswith(".app")})
        if len(apps) != 1:
            raise SystemExit("%s: Payload/*.app が1つではありません: %s" % (path, apps))
        root = "Payload/%s/" % apps[0]
        files = {}
        for i in z.infolist():
            if not i.filename.startswith(root) or i.filename.endswith("/"):
                continue
            mode = i.external_attr >> 16
            files[i.filename[len(root):]] = "link" if stat.S_ISLNK(mode) else "file"
        return Bundle("%s (%s)" % (os.path.basename(path), apps[0]), files, lambda rel: z.read(root + rel))

    @staticmethod
    def from_dir(path):
        path = path.rstrip("/")
        files = {}
        for d, _, names in os.walk(path):
            for n in names:
                full = os.path.join(d, n)
                rel = os.path.relpath(full, path).replace(os.sep, "/")
                files[rel] = "link" if os.path.islink(full) else "file"

        def read(rel):
            with open(os.path.join(path, rel), "rb") as f:
                return f.read()
        return Bundle(os.path.basename(path), files, read)


def bundle_root_of(rel):
    """実行ファイルが属するバンドル(.app 本体なら "" / 拡張なら "PlugIns/X.appex")。"""
    parts = rel.split("/")
    for i in range(len(parts) - 1, -1, -1):
        if parts[i].endswith(".appex"):
            return "/".join(parts[:i + 1])
    return ""


def check(bundle, platform=None, expect_plugins=None):
    errors, warnings, report = [], [], []

    def err(msg):
        errors.append("%s: %s" % (bundle.label, msg))

    def warn(msg):
        warnings.append("%s: %s" % (bundle.label, msg))

    # Info.plist(本体と拡張)
    plists = {}
    for rel in bundle.files:
        if rel == "Info.plist" or (rel.endswith(".appex/Info.plist") and rel.count("/") == 2):
            try:
                plists[posixpath.dirname(rel)] = plistlib.loads(bundle.read(rel))
            except Exception as e:  # noqa: BLE001
                err("%s を読めません: %s" % (rel, e))
    if "" not in plists:
        err("Info.plist がありません")
    for root, pl in sorted(plists.items()):
        exe = pl.get("CFBundleExecutable")
        exe_rel = posixpath.join(root, exe) if exe else None
        if not exe or exe_rel not in bundle.files:
            err("%s: CFBundleExecutable(%s)の実行ファイルがありません" % (root or ".app", exe))
        report.append("  %-28s id=%s 最低iOS=%s" % (root or "(app)", pl.get("CFBundleIdentifier"),
                                                   pl.get("MinimumOSVersion")))
    plugins = sorted(r for r in plists if r)
    if expect_plugins is not None and len(plugins) != expect_plugins:
        err("拡張の数が %d(期待 %d): %s" % (len(plugins), expect_plugins, plugins))

    checked = 0
    for rel in sorted(bundle.files):
        if bundle.files[rel] != "file":
            continue
        data = bundle.read(rel)
        offs = thin_slices(data)
        if not offs:
            continue
        broot = bundle_root_of(rel)
        pl = plists.get(broot, {})
        exe_dir = broot  # @executable_path は、そのバンドルの実行ファイルの場所
        min_ios = parse_version_text(pl.get("MinimumOSVersion")) if pl.get("MinimumOSVersion") else None
        for off in offs:
            try:
                info = parse_macho(data, off)
            except (ValueError, struct.error) as e:
                err("%s: Mach-O を読めません: %s" % (rel, e))
                continue
            checked += 1
            pname = PLATFORMS.get(info["platform"], str(info["platform"]))
            report.append("  %s [%s, %s, minos %s, sdk %s]" % (rel, FILETYPES.get(info["filetype"], info["filetype"]),
                                                              pname, vtext(info["minos"]), vtext(info["sdk"])))
            for rp in info["rpaths"]:
                report.append("      rpath    %s" % rp)
            if platform and pname != platform:
                err("%s: %s 向けの実行ファイルです(期待: %s)" % (rel, pname, platform))
            if min_ios and info["minos"] and info["minos"] > min_ios:
                err("%s: 最低 iOS %s が Info.plist の %s より新しい" % (rel, vtext(info["minos"]), vtext(min_ios)))
            for rp in info["rpaths"]:
                if rp.startswith("/") and not rp.startswith(SYSTEM_PREFIXES) and rp not in ("/usr/lib", "/System/Library"):
                    err("%s: LC_RPATH にビルドした Mac の場所が入っています: %s" % (rel, rp))
            for kind, name in info["dylibs"]:
                where = resolve(name, rel, exe_dir, info["rpaths"], bundle.files)
                report.append("      %-8s %s%s" % (kind, name, "" if where in ("system", None) else "  -> " + where))
                if where is not None:
                    continue
                if name.startswith("/"):
                    err("%s: iPhone に無い場所のライブラリを読み込みます(起動直後に落ちる): %s" % (rel, name))
                elif kind == "weak":
                    warn("%s: 見つからない weak ライブラリ: %s" % (rel, name))
                else:
                    err("%s: アプリの中に見つからないライブラリを読み込みます: %s" % (rel, name))
    if checked == 0:
        err("Mach-O の実行ファイルが見つかりません")
    return errors, warnings, report, checked


def resolve(name, rel, exe_dir, rpaths, files):
    """読み込み先がどこにあるか。OS のものは "system"、アプリの中は相対パス、見つからなければ None。"""
    if name.startswith(SYSTEM_PREFIXES):
        return "system"
    loader_dir = posixpath.dirname(rel)

    def inside(path):
        """.app からの相対パスに正規化する。.app の外に出たら None。"""
        out = posixpath.normpath(path) if path else "."
        if out == ".":
            return ""
        return None if out == ".." or out.startswith("../") or out.startswith("/") else out

    def expand(p):
        for prefix, base in (("@executable_path", exe_dir), ("@loader_path", loader_dir)):
            if p == prefix or p.startswith(prefix + "/"):
                return inside(posixpath.join(base, p[len(prefix) + 1:]))
        return None

    if name.startswith("@rpath/"):
        rest = name[len("@rpath/"):]
        for rp in rpaths:
            if rp.startswith("@"):
                base = expand(rp)
                if base is not None:
                    cand = inside(posixpath.join(base, rest))
                    if cand and cand in files:
                        return cand
            elif rp.startswith(SYSTEM_PREFIXES) or rp in ("/usr/lib", "/System/Library"):
                # 例: @rpath/libswiftCore.dylib と /usr/lib/swift(OS の Swift)
                return "system"
        return None
    if name.startswith("@"):
        cand = expand(name)
        return cand if cand is not None and cand in files else None
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--platform", choices=["ios", "iossim"], help="すべての実行ファイルがこの向けであること")
    ap.add_argument("--expect-plugins", type=int, help="拡張(.appex)の数")
    ap.add_argument("paths", nargs="+")
    a = ap.parse_args()
    gha = bool(os.environ.get("GITHUB_ACTIONS"))
    all_errors = []
    for path in a.paths:
        if os.path.isdir(path):
            b = Bundle.from_dir(path)
        elif zipfile.is_zipfile(path):
            b = Bundle.from_ipa(path)
        else:
            print("%s: IPA でも .app でもありません" % path)
            all_errors.append(path)
            continue
        errors, warnings, report, checked = check(b, a.platform, a.expect_plugins)
        print("== %s: 実行ファイル %d 個" % (b.label, checked))
        print("\n".join(report))
        for w in warnings:
            print(("::warning::" if gha else "注意: ") + w)
        for e in errors:
            print(("::error::" if gha else "エラー: ") + e)
        if not errors:
            print("OK: 読み込むライブラリはすべて OS かアプリの中のものです")
        all_errors += errors
    sys.exit(1 if all_errors else 0)


if __name__ == "__main__":
    main()
