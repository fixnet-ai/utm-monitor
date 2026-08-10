#!/usr/bin/env python3
"""
MCP 工具全量测试脚本 — utmm HTTP MCP JSON-RPC 工具验证

用法:
    sudo python3 tests/test_mcp_tools.py [--bin ./zig-out/bin/utmm] [--port 2121]

覆盖所有 7 个 MCP 工具:
    status, exec, ping, upload, download, sshpass, manual

要求:
    - Host utmm daemon 运行中（脚本自动触发 --mcp ensure）
    - Python 3.6+

输出: 每个工具的测试结果 + 最终 pass/fail 汇总。
"""

import subprocess, json, sys, os, urllib.request, urllib.error


def run_tests(bin_path="zig-out/bin/utmm", port=2121):
    """运行全部 MCP 工具测试，返回 (passed, failed) 计数。"""

    # 1. Ensure Host daemon is running via --mcp (auto-starts if needed)
    print(f"  Ensuring Host daemon via: sudo {bin_path} --mcp ...")
    subprocess.run(["sudo", bin_path, "--mcp"], capture_output=True, text=True)

    mcp_url = f"http://127.0.0.1:{port}/"

    def send_request(method, params=None, rid=0, timeout=120):
        """Send a JSON-RPC request via HTTP POST. Returns parsed JSON response."""
        req_body = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            req_body["params"] = params
        data = json.dumps(req_body).encode("utf-8")
        try:
            req = urllib.request.Request(
                mcp_url,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8")
                return json.loads(body) if body else None
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8") if e.fp else ""
            print(f"       HTTP {e.code}: {body[:200]}")
            return None
        except urllib.error.URLError as e:
            print(f"       URL Error: {e.reason}")
            return None
        except Exception as e:
            print(f"       Request error: {e}")
            return None

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

    try:
        # ── 1. initialize ──
        resp = send_request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "mcp-test-suite", "version": "1.0"},
            },
            1,
        )
        ok = resp is not None and "result" in resp
        check(ok, "initialize")
        if ok:
            info = resp["result"].get("serverInfo", {})
            print(f"       Server: {info.get('name', '?')} v{info.get('version', '?')}")

        # notifications/initialized — no response expected
        send_notification_body = json.dumps({
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        }).encode("utf-8")
        try:
            req = urllib.request.Request(
                mcp_url,
                data=send_notification_body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            urllib.request.urlopen(req, timeout=5)
        except Exception:
            pass  # notifications may not return a response

        # ── 2. tools/list ──
        resp = send_request("tools/list", {}, 2)
        ok = resp is not None and "result" in resp
        check(ok, "tools/list")
        if ok:
            tools = [t["name"] for t in resp["result"].get("tools", [])]
            expected = {"status", "exec", "ping", "upload", "download", "sshpass", "manual"}
            all_present = expected.issubset(set(tools))
            check(all_present, f"all 7 tools present", f"got: {tools}")

        # ── 3. status ──
        resp = send_request("tools/call", {"name": "status", "arguments": {}}, 3)
        ok = resp is not None and "result" in resp
        check(ok, "status")
        if ok:
            text = resp["result"]["content"][0]["text"]
            check(len(text) > 50, "status returns data", f"{len(text)} chars")

        # ── 4. ping (linuxvm + macvm) ──
        for vm in ["linuxvm", "macvm"]:
            resp = send_request(
                "tools/call", {"name": "ping", "arguments": {"vm": vm}}, 0
            )
            ok = resp is not None and "result" in resp
            text = (
                resp["result"]["content"][0]["text"]
                if ok
                else resp.get("error", {}).get("message", "?")
            )
            check(ok and "RTT=" in text, f"ping {vm}", text.strip()[:80])

        # ── 5. exec (linuxvm + macvm) ──
        for vm, expect_arch in [("linuxvm", "aarch64"), ("macvm", "arm64")]:
            resp = send_request(
                "tools/call",
                {
                    "name": "exec",
                    "arguments": {
                        "vm": vm,
                        "command": f"echo MCP-TEST-{vm} && uname -m",
                    },
                },
                0,
            )
            ok = resp is not None and "result" in resp
            text = (
                resp["result"]["content"][0]["text"]
                if ok
                else resp.get("error", {}).get("message", "?")
            )
            marker_ok = f"MCP-TEST-{vm}" in text
            arch_ok = expect_arch in text
            check(
                marker_ok and arch_ok,
                f"exec {vm}",
                f"marker={'✓' if marker_ok else '✗'} arch={'✓' if arch_ok else '✗'}",
            )

        # ── 6. upload + download ──
        test_content = "MCP_UPLOAD_v0.17.11_TEST_OK_" + os.urandom(8).hex()
        src_path = "/tmp/mcp_test_upload_src.txt"
        dst_remote = "/opt/utmm/mcp_test_upload_dst.txt"
        dst_local = "/tmp/mcp_test_download_dst.txt"

        with open(src_path, "w") as f:
            f.write(test_content)

        resp = send_request(
            "tools/call",
            {
                "name": "upload",
                "arguments": {
                    "vm": "linuxvm",
                    "local_path": src_path,
                    "remote_path": dst_remote,
                },
            },
            6,
        )
        ok = resp is not None and "result" in resp
        text = (
            resp["result"]["content"][0]["text"]
            if ok
            else resp.get("error", {}).get("message", "?")
        )
        check(ok and "error" not in text.lower(), "upload linuxvm", text.strip()[:100])

        resp = send_request(
            "tools/call",
            {
                "name": "download",
                "arguments": {
                    "vm": "linuxvm",
                    "remote_path": dst_remote,
                    "local_path": dst_local,
                },
            },
            7,
        )
        ok = resp is not None and "result" in resp
        text = (
            resp["result"]["content"][0]["text"]
            if ok
            else resp.get("error", {}).get("message", "?")
        )
        check(ok and "error" not in text.lower(), "download linuxvm", text.strip()[:100])

        # 验证下载内容
        try:
            with open(dst_local, "r") as f:
                dl_content = f.read()
            match = dl_content.strip() == test_content.strip()
            check(match, "content SHA256-equivalent", f"'{test_content}'")
        except Exception as e:
            check(False, "content verify", str(e))

        # ── 7. sshpass ──
        resp = send_request(
            "tools/call",
            {
                "name": "sshpass",
                "arguments": {
                    "host": "192.168.64.6",
                    "user": "root",
                    "password": "111",
                    "command": "echo MCP-SSHPASS-TEST-OK",
                },
            },
            8,
            timeout=120,
        )
        ok = resp is not None and "result" in resp
        text = (
            resp["result"]["content"][0]["text"]
            if ok
            else resp.get("error", {}).get("message", "?")
        )
        has_marker = "MCP-SSHPASS-TEST-OK" in text
        check(has_marker, "sshpass linuxvm", text.strip()[:100])

        # ── 8. manual ──
        resp = send_request("tools/call", {"name": "manual", "arguments": {}}, 9)
        ok = resp is not None and "result" in resp
        text = (
            resp["result"]["content"][0]["text"]
            if ok
            else resp.get("error", {}).get("message", "?")
        )
        has_docs = "utmm" in text.lower() and len(text) > 100
        check(has_docs, "manual", f"{len(text)} chars of docs")

        # ── 清理 ──
        for f in [src_path, dst_local]:
            try:
                os.remove(f)
            except Exception:
                pass

    except Exception as e:
        print(f"\n  💥 EXCEPTION: {e}")
        import traceback

        traceback.print_exc()
        failed += 1

    return passed, failed


if __name__ == "__main__":
    bin_path = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/utmm"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 2121

    print(f"=== MCP Tool Test Suite (HTTP) ===")
    print(f"Binary: {bin_path}")
    print(f"Port:   {port}")
    print(f"")

    passed, failed = run_tests(bin_path, port)

    total = passed + failed
    print(f"")
    print(f"=== MCP Test Results: {passed}/{total} passed ===")
    sys.exit(0 if failed == 0 else 1)
