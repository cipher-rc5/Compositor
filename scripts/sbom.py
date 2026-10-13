#!/usr/bin/python3 -I
"""Prints an SPDX 2.3 JSON software bill of materials for one Compositor release.

The app's only third-party code is what Swift Package Manager resolves, so the bill lists Compositor itself
and every pin in the Xcode project's Package.resolved, each with the exact version and git revision shipped.
scripts/publish.sh uploads the output beside the DMG as Compositor.spdx.json.

    /usr/bin/python3 -I scripts/sbom.py --version 1.2.2 --repo owner/Compositor --commit <sha>
"""
from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOLVED = ROOT / "Compositor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"


def spdx_id(name: str) -> str:
    return "SPDXRef-Package-" + "".join(c if c.isalnum() or c in ".-" else "-" for c in name)


def github_path(location: str) -> str | None:
    for prefix in ("https://github.com/", "git@github.com:"):
        if location.startswith(prefix):
            return location[len(prefix):].removesuffix(".git").strip("/")
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--repo", required=True, help="owner/name on GitHub")
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()

    pins = json.loads(RESOLVED.read_text())["pins"]
    app_id = spdx_id("Compositor")
    packages = [{
        "SPDXID": app_id,
        "name": "Compositor",
        "versionInfo": args.version,
        "supplier": "NOASSERTION",
        "downloadLocation": f"git+https://github.com/{args.repo}.git@{args.commit}",
        "filesAnalyzed": False,
        "licenseConcluded": "MIT",
        "licenseDeclared": "MIT",
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "APPLICATION",
        "externalRefs": [{
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": f"pkg:github/{args.repo}@v{args.version}",
        }],
    }]
    relationships = [{
        "spdxElementId": "SPDXRef-DOCUMENT",
        "relationshipType": "DESCRIBES",
        "relatedSpdxElement": app_id,
    }]
    for pin in pins:
        location = pin["location"]
        state = pin.get("state", {})
        version = state.get("version") or state.get("branch") or state.get("revision", "NOASSERTION")
        revision = state.get("revision")
        package = {
            "SPDXID": spdx_id(pin["identity"]),
            "name": pin["identity"],
            "versionInfo": version,
            "supplier": "NOASSERTION",
            "downloadLocation": f"git+{location}" + (f"@{revision}" if revision else ""),
            "filesAnalyzed": False,
            # Not concluded here: Sparkle, for one, bundles code under more than one license.
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "NOASSERTION",
            "primaryPackagePurpose": "LIBRARY",
        }
        path = github_path(location)
        if path:
            package["externalRefs"] = [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:swift/github.com/{path}@{version}",
            }]
        packages.append(package)
        relationships.append({
            "spdxElementId": app_id,
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": package["SPDXID"],
        })

    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Compositor-{args.version}",
        "documentNamespace": f"https://github.com/{args.repo}/releases/tag/v{args.version}/sbom-{uuid.uuid4()}",
        "creationInfo": {
            "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "creators": ["Tool: Compositor scripts/sbom.py"],
        },
        "packages": packages,
        "relationships": relationships,
    }
    json.dump(document, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
