#!/usr/bin/env python3
"""Summarise Grype JSON results for the image's Alpine packages as Markdown.

Usage: report-vulns.py [--fail-on-fixed] [--fixed-out FILE] grype-<variant>.json...

A "fixed" vulnerability is one where Alpine already ships a newer package
that fixes it, so a rebuild (which installs the newest packages) clears it.
Unfixed ones are listed for information: there is nothing to install yet.

--fail-on-fixed  exit 1 if any fixed vulnerability is present (CI).
--fixed-out      write only the fixed findings, as Markdown, to FILE (the
                 advisory watch puts them in its issue). Empty if none.
"""
import json
import os
import sys

SEVERITY_ORDER = ["Critical", "High", "Medium", "Low", "Negligible", "Unknown"]


def load(path):
    with open(path) as f:
        data = json.load(f)
    if "matches" not in data:
        sys.exit(f"ERROR: {path} is not Grype JSON output (no 'matches')")
    # Grype reports "0 known" for an empty or unreadable folder. Without a
    # detected Alpine release the scan saw no packages: stop, do not report
    # all clear.
    distro = data.get("distro") or {}
    if distro.get("name") != "alpine" or not distro.get("version"):
        sys.exit(f"ERROR: {path}: Grype did not detect an Alpine release, so it scanned no packages. Check the unpacked package list.")
    variant = os.path.basename(path).removeprefix("grype-").removesuffix(".json")
    rows = []
    for m in data["matches"] or []:
        v = m["vulnerability"]
        a = m["artifact"]
        rows.append({
            "variant": variant,
            "id": v["id"],
            "severity": v.get("severity") or "Unknown",
            "state": v.get("fix", {}).get("state", "unknown"),
            "fixed_in": ", ".join(v.get("fix", {}).get("versions") or []),
            "package": a["name"],
            "version": a["version"],
        })
    return variant, rows


def table(rows, with_fix):
    head = "| Variant | Package | Installed | Vulnerability | Severity |" + (" Fixed in |" if with_fix else "")
    sep = "|---|---|---|---|---|" + ("---|" if with_fix else "")
    lines = [head, sep]
    for r in sorted(rows, key=lambda r: (SEVERITY_ORDER.index(r["severity"]) if r["severity"] in SEVERITY_ORDER else 99, r["package"], r["id"])):
        line = f"| {r['variant']} | {r['package']} | {r['version']} | {r['id']} | {r['severity']} |"
        if with_fix:
            line += f" {r['fixed_in']} |"
        lines.append(line)
    return "\n".join(lines)


def main(argv):
    fail_on_fixed = False
    fixed_out = None
    files = []
    it = iter(argv)
    for arg in it:
        if arg == "--fail-on-fixed":
            fail_on_fixed = True
        elif arg == "--fixed-out":
            fixed_out = next(it, None) or sys.exit("ERROR: --fixed-out needs a file name")
        else:
            files.append(arg)
    if not files:
        sys.exit(__doc__)

    all_rows = []
    out = ["## Alpine package vulnerabilities", ""]
    for path in files:
        variant, rows = load(path)
        all_rows += rows
        fixed = sum(1 for r in rows if r["state"] == "fixed")
        out.append(f"- **{variant}**: {len(rows)} known, {fixed} with a fix available")
    out.append("")

    fixed_rows = [r for r in all_rows if r["state"] == "fixed"]
    if fixed_rows:
        out += ["### Fix available (a rebuild installs it)", "", table(fixed_rows, True), ""]
    serious_unfixed = [r for r in all_rows if r["state"] != "fixed" and r["severity"] in ("Critical", "High")]
    if serious_unfixed:
        out += ["### Critical and high, no fix in this Alpine branch yet", "", table(serious_unfixed, False), ""]
    out.append("Packages that the device takes from the boot media (busybox, musl, openrc, apk-tools, "
               "wpa_supplicant, ifupdown-ng) run at the version of `ALPINE_RELEASE` in build.sh, "
               "not the versions scanned here.")
    print("\n".join(out))

    if fixed_out:
        with open(fixed_out, "w") as f:
            if fixed_rows:
                f.write(table(fixed_rows, True) + "\n")

    if fail_on_fixed and fixed_rows:
        print(f"\n{len(fixed_rows)} vulnerabilities have a fix in Alpine but are still in the build.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
