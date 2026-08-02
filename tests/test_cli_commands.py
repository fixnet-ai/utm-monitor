#!/usr/bin/env python3
"""
CLI 命令全量测试脚本 — utmm 命令行接口验证

用法:
    sudo python3 tests/test_cli_commands.py [./zig-out/bin/utmm]

覆盖 CLI 命令:
    --version, --status, --ping, --exec, --upload, --download, sshpass

要求:
    - Host utmm daemon 运行中（sudo utmm --status 可见节点）
    - Python 3.6+

注意:
    - utmm CLI 将命令输出写入 stderr（非 stdout），脚本统一合并 stdout+stderr
    - sshpass 错误密码测试需禁用 SSH 密钥认证，否则密钥认证成功会绕过密码检查
"""

import subprocess, sys, os


def run(cmd, timeout=60):
    """执行命令，合并 stdout+stderr 返回。"""
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    combined = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, combined


def run_tests(bin_path="zig-out/bin/utmm"):
    """运行全部 CLI 命令测试，返回 (passed, failed) 计数。"""

    passed = 0
    failed = 0

    def check(ok, label, detail=""):
        nonlocal passed, failed
        if ok:
            print(f"  ✅ {label}{' — ' + detail if detail else ''}")
            passed += 1
        else:
            print(f"  ❌ {label}{' — ' + detail if detail else ''}")
            failed += 1

    # ── 前置检查：Host 是否在运行 ──
    _, status_out = run(["sudo", bin_path, "--status"], timeout=10)
    has_linuxvm = "linuxvm" in status_out and "serving" in status_out
    has_macvm = "macvm" in status_out and "serving" in status_out
    if not has_linuxvm and not has_macvm:
        print("  ⚠️  No Guests online — connectivity tests will be skipped.\n")

    # ═══════════════════════════════════════════════════════════════
    # 1. --version
    # ═══════════════════════════════════════════════════════════════
    print("── CLI: --version ──")
    rc, out = run([bin_path, "--version"], timeout=5)
    check(rc == 0, "--version exit=0")
    # 输出格式："utmm v0.17.11"
    check("utmm" in out and "v0." in out, "--version prints version", out.strip())

    # ═══════════════════════════════════════════════════════════════
    # 2. --status
    # ═══════════════════════════════════════════════════════════════
    print("\n── CLI: --status ──")
    rc, out = run(["sudo", bin_path, "--status"], timeout=10)
    check(rc == 0, "--status exit=0")

    # 表格格式：表头有 "Role" 和 "Hostname" 列
    has_header = "Role" in out and "Hostname" in out
    check(has_header, "--status has table header")

    # 至少应有 Host 自身
    has_host = out.count("host") >= 1
    check(has_host, "--status shows host role entries")

    # 检查已知 Guest
    check("linuxvm" in out, "--status shows linuxvm")
    check("macvm" in out, "--status shows macvm")

    # ═══════════════════════════════════════════════════════════════
    # 3. --ping
    # ═══════════════════════════════════════════════════════════════
    print("\n── CLI: --ping ──")
    for vm in ["linuxvm", "macvm"]:
        rc, out = run(["sudo", bin_path, "--ping", vm], timeout=30)
        check(rc == 0, f"--ping {vm} exit=0")
        # 输出是 JSON：{"hostname":"linuxvm","mac":"...","rtt_ms":1}
        has_rtt = "rtt_ms" in out
        check(has_rtt, f"--ping {vm} shows rtt_ms", out.strip()[:80])

    # ═══════════════════════════════════════════════════════════════
    # 4. --exec
    # ═══════════════════════════════════════════════════════════════
    print("\n── CLI: --exec ──")

    for vm, marker, expect_arch in [
        ("linuxvm", "CLI-EXEC-LINUXVM-OK", "aarch64"),
        ("macvm", "CLI-EXEC-MACVM-OK", "arm64"),
    ]:
        rc, out = run(
            ["sudo", bin_path, "--exec", vm, f"echo {marker} && uname -m"],
            timeout=15,
        )
        check(rc == 0, f"--exec {vm} exit=0")
        check(marker in out, f"--exec {vm} output contains marker")
        check(expect_arch in out, f"--exec {vm} shows {expect_arch}")

    # ═══════════════════════════════════════════════════════════════
    # 5. --upload
    # ═══════════════════════════════════════════════════════════════
    print("\n── CLI: --upload ──")

    test_content = "CLI_UPLOAD_TEST_v0.17.11_" + os.urandom(8).hex() + "\n"
    src_path = "/tmp/cli_upload_src.txt"
    with open(src_path, "w") as f:
        f.write(test_content)

    upload_ok = True
    rc, out = run(
        ["sudo", bin_path, "--upload", src_path, "linuxvm"], timeout=15
    )
    check(rc == 0, f"--upload linuxvm exit=0", f"got rc={rc}")
    # 成功输出："[upload] Uploading ... -> ..." 且不含 "error:"
    has_upload = "[upload]" in out and "error:" not in out.lower()
    check(has_upload, "--upload linuxvm success", out.strip()[:100])
    if not has_upload:
        upload_ok = False

    # ═══════════════════════════════════════════════════════════════
    # 6. --download
    # ═══════════════════════════════════════════════════════════════
    print("\n── CLI: --download ──")

    remote_path = f"/opt/utmm/{os.path.basename(src_path)}"
    dst_path = "/tmp/cli_download_dst.txt"
    rc, out = run(
        ["sudo", bin_path, "--download", "linuxvm", remote_path, dst_path],
        timeout=15,
    )
    check(rc == 0, f"--download linuxvm exit=0", f"got rc={rc}")
    # 成功输出："[download] Downloading ... -> ..." 且不含 "error:"
    has_download = "[download]" in out and "error:" not in out.lower()
    check(has_download, "--download linuxvm success", out.strip()[:100])

    # 内容校验（仅 upload 成功时下载才有意义，但脚本仍尽力验证）
    try:
        with open(dst_path, "r") as f:
            dl_content = f.read()
        match = dl_content == test_content
        check(
            match,
            "--download content match",
            f"src={test_content.strip()!r} dst={dl_content.strip()!r}",
        )
    except Exception as e:
        check(False, "--download content verify", str(e))

    # ═══════════════════════════════════════════════════════════════
    # 7. sshpass subcommand
    # ═══════════════════════════════════════════════════════════════
    print("\n── CLI: sshpass ──")

    # sshpass -V
    rc, out = run([bin_path, "sshpass", "-V"], timeout=5)
    check(rc == 0, "sshpass -V exit=0")
    check("sshpass" in out, "sshpass -V prints version", out.strip())

    # sshpass -h
    rc, out = run([bin_path, "sshpass", "-h"], timeout=5)
    check(rc == 0, "sshpass -h exit=0")
    check("-p" in out, "sshpass -h shows usage (-p flag)")

    # sshpass execute (password auth)
    marker = "CLI-SSHPASS-OK"
    rc, out = run(
        [
            bin_path, "sshpass", "-p", "111",
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "root@192.168.64.6", f"echo {marker}",
        ],
        timeout=15,
    )
    check(rc == 0, "sshpass exec exit=0")
    check(marker in out, "sshpass exec output correct")

    # sshpass wrong password — 必须禁用密钥认证才能测试密码认证失败
    rc, out = run(
        [
            bin_path, "sshpass", "-p", "WRONG",
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=yes",
            "root@192.168.64.6", "echo X",
        ],
        timeout=15,
    )
    check(
        rc == 5,
        "sshpass wrong password exit=5",
        f"got rc={rc}",
    )

    # sshpass -f (password from file)
    with open("/tmp/cli_sshpass_pw.txt", "w") as f:
        f.write("111\n")
    rc, out = run(
        [
            bin_path, "sshpass", "-f", "/tmp/cli_sshpass_pw.txt",
            "ssh",
            "-o", "StrictHostKeyChecking=no",
            "root@192.168.64.6", f"echo {marker}",
        ],
        timeout=15,
    )
    check(rc == 0, "sshpass -f exit=0")
    check(marker in out, "sshpass -f output correct")

    # ═══════════════════════════════════════════════════════════════
    # 清理
    # ═══════════════════════════════════════════════════════════════
    for f in [src_path, dst_path, "/tmp/cli_sshpass_pw.txt"]:
        try:
            os.remove(f)
        except Exception:
            pass

    return passed, failed


if __name__ == "__main__":
    bin_path = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/utmm"

    print(f"=== CLI Command Test Suite ===")
    print(f"Binary: {bin_path}")

    # 显示当前版本
    _, ver_out = run([bin_path, "--version"], timeout=5)
    print(f"Version: {ver_out.strip()}")
    print(f"")

    passed, failed = run_tests(bin_path)

    total = passed + failed
    print(f"\n=== CLI Test Results: {passed}/{total} passed ===")
    sys.exit(0 if failed == 0 else 1)
