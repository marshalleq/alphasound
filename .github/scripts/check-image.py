#!/usr/bin/env python3
"""Daily checks that Dependabot cannot do for this image.

Writes Markdown findings to OUTPUT_FILE (empty when nothing applies) and
prints them. Exits non-zero if any source cannot be read: a gap must not
look like "all clear".

Environment:
  OUTPUT_FILE     where to write the findings
  PACKAGES_DIRS   space-separated unpacked .packages.tar.gz folders of the
                  latest release, one per variant (folder name ends -<variant>)
  FIXED_VULNS     Markdown table from report-vulns.py --fixed-out (may be empty)
  RELEASE_TAG     tag of the latest release
  RELEASE_DATE    its creation time (ISO 8601)
  REBUILD_STARTED "true" if the workflow started a rebuild for fixed vulns

Checks:
  1. The Alpine branch pinned in build.sh is past (or near) end of life.
  2. The branch is not Alpine's latest stable: packages from the community
     repository only get security fixes on the latest stable branch.
  3. ALPINE_RELEASE is behind the branch's newest point release. The boot
     media (kernel, busybox, musl, openrc, wpa_supplicant) comes from it.
  4. The latest release ships packages with a fixed vulnerability.
  5. A package licence is not on .github/licence-allowlist.txt.
  6. The latest release is more than 8 days old (the weekly build stopped).
"""
import datetime as dt
import io
import json
import os
import re
import sys
import tarfile
import urllib.request

UA = {"User-Agent": "alphasound-advisory-watch"}
TODAY = dt.date.today()


def fetch(url):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def build_sh_value(name):
    with open("build.sh") as f:
        m = re.search(rf'^{name}="([^"]+)"$', f.read(), re.M)
    if not m:
        sys.exit(f"ERROR: {name} not found in build.sh")
    return m.group(1)


def version_tuple(v):
    return tuple(int(x) for x in v.split("."))


def read_apk_db(path):
    """Yield dicts of P (name), V (version), L (licence) from an apk database."""
    pkg = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if pkg:
                    yield pkg
                pkg = {}
            elif len(line) > 2 and line[1] == ":" and line[0] in "PVL":
                pkg[line[0]] = line[2:]
    if pkg:
        yield pkg


def licence_ids(expr):
    parts = re.split(r"\s+(?:AND|OR|WITH)\s+", expr.replace("(", " ").replace(")", " ").strip())
    return {p.strip() for p in parts if p.strip()}


def main():
    out_file = os.environ["OUTPUT_FILE"]
    packages_dirs = os.environ["PACKAGES_DIRS"].split()
    if not packages_dirs:
        sys.exit("ERROR: PACKAGES_DIRS is empty")
    findings = []

    branch = build_sh_value("ALPINE_VERSION")
    release = build_sh_value("ALPINE_RELEASE")

    data = json.loads(fetch("https://alpinelinux.org/releases.json"))
    branches = {b["rel_branch"]: b for b in data["release_branches"]}
    latest_stable = data["latest_stable"]
    ours = branches.get(f"v{branch}")
    if ours is None:
        sys.exit(f"ERROR: Alpine v{branch} is not in releases.json")

    # 1. End of life of the main repository.
    eol = dt.date.fromisoformat(ours["eol_date"])
    if eol <= TODAY:
        findings.append(
            f"### Alpine {branch} is end of life\n\n"
            f"Alpine stopped security fixes for {branch} on {eol}. Every weekly rebuild now ships "
            f"packages that will never be patched. Move `ALPINE_VERSION`/`ALPINE_RELEASE` in build.sh "
            f"to the latest stable release ({latest_stable}), test on a Pi, and reflash devices "
            f"(an apkovl update cannot cross Alpine releases).")
    elif (eol - TODAY).days <= 60:
        findings.append(
            f"### Alpine {branch} reaches end of life on {eol}\n\n"
            f"Plan the move to {latest_stable} before then.")

    # 2. Community packages are only supported on the latest stable branch.
    if f"v{branch}" != latest_stable:
        index = fetch(f"https://dl-cdn.alpinelinux.org/alpine/v{branch}/community/aarch64/APKINDEX.tar.gz")
        with tarfile.open(fileobj=io.BytesIO(index)) as t:
            text = t.extractfile("APKINDEX").read().decode()
        community = set(re.findall(r"^P:(.+)$", text, re.M))
        installed = set()
        for d in packages_dirs:
            installed |= {p["P"] for p in read_apk_db(os.path.join(d, "lib/apk/db/installed"))}
        ours_community = sorted(installed & community)
        if ours_community:
            findings.append(
                f"### {len(ours_community)} shipped packages get no security fixes on Alpine {branch}\n\n"
                f"Alpine only patches its `community` repository on the latest stable branch "
                f"({latest_stable}). These shipped packages come from it: "
                f"{', '.join(ours_community)}.")

    # 3. Boot media point release.
    newest = ours["releases"][0]["version"]
    if version_tuple(newest) > version_tuple(release):
        findings.append(
            f"### Boot media is Alpine {release}; {newest} is available\n\n"
            f"The kernel, firmware, busybox, musl, openrc and wpa_supplicant on a device come from the "
            f"boot media, not the apkovl, so weekly rebuilds do not update them. Set `ALPINE_RELEASE=\"{newest}\"` "
            f"in build.sh; devices get it by reflashing the new `.img.xz`.")

    # 4. Fixed vulnerabilities still shipped in the latest release.
    fixed = os.environ.get("FIXED_VULNS", "").strip()
    if fixed:
        started = os.environ.get("REBUILD_STARTED") == "true"
        findings.append(
            f"### Release {os.environ['RELEASE_TAG']} ships packages with fixed vulnerabilities\n\n"
            + ("A rebuild has been started to pick up the fixes. If this is still here tomorrow, the "
               "rebuild failed: check the Build Alphasound Image runs.\n\n" if started else "")
            + fixed)

    # 5. Licences.
    with open(".github/licence-allowlist.txt") as f:
        allowed = {l.strip() for l in f if l.strip() and not l.startswith("#")}
    unknown = {}
    for d in packages_dirs:
        for p in read_apk_db(os.path.join(d, "lib/apk/db/installed")):
            if "L" not in p:
                sys.exit(f"ERROR: package {p.get('P')} in {d} has no licence field")
            for lic in licence_ids(p["L"]) - allowed:
                unknown.setdefault(lic, set()).add(p["P"])
    if unknown:
        rows = "\n".join(f"| {lic} | {', '.join(sorted(pk))} |" for lic, pk in sorted(unknown.items()))
        findings.append(
            "### Licences not on the allow-list\n\n"
            "A shipped package uses a licence that has not been reviewed. Check it allows free use and "
            "redistribution, then add it to `.github/licence-allowlist.txt`, or replace the package.\n\n"
            "| Licence | Packages |\n|---|---|\n" + rows)

    # 6. Stale release.
    created = dt.datetime.fromisoformat(os.environ["RELEASE_DATE"].replace("Z", "+00:00")).date()
    age = (TODAY - created).days
    if age > 8:
        findings.append(
            f"### The latest release is {age} days old\n\n"
            f"{os.environ['RELEASE_TAG']} was published on {created}. The weekly build should publish "
            f"every Monday, so it has been failing or is disabled.")

    body = ""
    if findings:
        body = ("The daily advisory watch found the items below. This issue is updated each day and "
                "closed automatically when nothing applies.\n\n" + "\n\n".join(findings) + "\n")
    with open(out_file, "w") as f:
        f.write(body)
    print(body or "No findings: the checks ran and nothing applies.")


if __name__ == "__main__":
    main()
