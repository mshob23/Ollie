#!/usr/bin/env python3
"""ASC beta-tester ops for app 6785293567 (pure stdlib + openssl-CLI ES256 JWT).

Usage:
  asc-beta.py groups                        # list beta groups (id | name | internal?)
  asc-beta.py testers                       # list current testers
  asc-beta.py grouptesters GROUP_ID         # members of one group
  asc-beta.py groupbuilds GROUP_ID          # builds attached to a group
  asc-beta.py buildid N                     # ASC build id for build number N
  asc-beta.py attachbuild GROUP_ID BUILD_ID # attach a build to a group
  asc-beta.py submitreview BUILD_ID         # submit for Beta App Review (external needs it)
  asc-beta.py reviewstate BUILD_ID          # WAITING_FOR_REVIEW -> APPROVED
  asc-beta.py add EMAIL GROUP_ID            # create tester + attach to group (sends invite)

RELEASE.md §iOS step 4 documents the per-ship sequence (buildid -> attachbuild ->
submitreview) — external testers only see builds explicitly attached to their group.
Key expected at ~/.appstoreconnect/private_keys/AuthKey_V2S345C7SB.p8.
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error

KEY = os.path.expanduser("~/.appstoreconnect/private_keys/AuthKey_V2S345C7SB.p8")
ISS = "5ec716ff-5d65-4f02-87f7-66a3825024eb"
KID = "V2S345C7SB"
APP = "6785293567"
API = "https://api.appstoreconnect.apple.com"


def b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(d: bytes) -> bytes:
    assert d[0] == 0x30
    i = 2 if d[1] < 0x80 else 2 + (d[1] & 0x7F)
    vals = []
    for _ in range(2):
        assert d[i] == 0x02
        length = d[i + 1]
        vals.append(int.from_bytes(d[i + 2 : i + 2 + length], "big"))
        i += 2 + length
    r, s = vals
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def jwt() -> str:
    h = b64u(json.dumps({"alg": "ES256", "kid": KID, "typ": "JWT"}).encode())
    now = int(time.time())
    p = b64u(json.dumps(
        {"iss": ISS, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    ).encode())
    msg = f"{h}.{p}".encode()
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", KEY, "-binary"],
        input=msg, capture_output=True, check=True,
    ).stdout
    return f"{h}.{p}.{b64u(der_to_raw(der))}"


def call(method: str, path: str, body=None):
    req = urllib.request.Request(
        API + path, method=method,
        headers={"Authorization": f"Bearer {jwt()}",
                 "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None,
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw.decode(errors="replace")[:500]}


cmd = sys.argv[1] if len(sys.argv) > 1 else "groups"

if cmd == "groups":
    st, d = call("GET", f"/v1/betaGroups?filter[app]={APP}")
    print("HTTP", st)
    for g in d.get("data", []):
        a = g.get("attributes", {})
        print(f'{g["id"]} | {a.get("name")} | internal={a.get("isInternalGroup")} '
              f'| publicLink={a.get("publicLinkEnabled")}')

elif cmd == "testers":
    st, d = call("GET", f"/v1/betaTesters?filter[apps]={APP}&limit=50")
    print("HTTP", st)
    for t in d.get("data", []):
        a = t.get("attributes", {})
        print(f'{t["id"]} | {a.get("email")} | inviteType={a.get("inviteType")} '
              f'| state={a.get("state")}')

elif cmd == "groupbuilds":
    gid = sys.argv[2]
    st, d = call("GET", f"/v1/betaGroups/{gid}/builds?limit=10")
    print("HTTP", st)
    for b in d.get("data", []):
        a = b.get("attributes", {})
        print(f'{a.get("version")} | {a.get("processingState")} '
              f'| expired={a.get("expired")}')

elif cmd == "add":
    email, gid = sys.argv[2], sys.argv[3]
    st, d = call("POST", "/v1/betaTesters", {
        "data": {
            "type": "betaTesters",
            "attributes": {"email": email},
            "relationships": {
                "betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}
            },
        }
    })
    print("HTTP", st)
    print(json.dumps(d, indent=1)[:1500])

elif cmd == "grouptesters":
    gid = sys.argv[2]
    st, d = call("GET", f"/v1/betaGroups/{gid}/betaTesters?limit=50")
    print("HTTP", st)
    for t in d.get("data", []):
        a = t.get("attributes", {})
        print(f'{a.get("email")} | state={a.get("state")}')

elif cmd == "buildid":
    ver = sys.argv[2]
    st, d = call("GET", f"/v1/builds?filter[app]={APP}&filter[version]={ver}&limit=2")
    print("HTTP", st)
    for b in d.get("data", []):
        a = b.get("attributes", {})
        print(f'{b["id"]} | v{a.get("version")} | {a.get("processingState")}')

elif cmd == "attachbuild":
    gid, bid = sys.argv[2], sys.argv[3]
    st, d = call("POST", f"/v1/betaGroups/{gid}/relationships/builds",
                 {"data": [{"type": "builds", "id": bid}]})
    print("HTTP", st)
    if d:
        print(json.dumps(d, indent=1)[:1000])

elif cmd == "submitreview":
    bid = sys.argv[2]
    st, d = call("POST", "/v1/betaAppReviewSubmissions", {
        "data": {"type": "betaAppReviewSubmissions",
                 "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}
    })
    print("HTTP", st)
    a = (d.get("data") or {}).get("attributes", {})
    print("betaReviewState:", a.get("betaReviewState") or json.dumps(d)[:600])

elif cmd == "reviewstate":
    bid = sys.argv[2]
    st, d = call("GET", f"/v1/builds/{bid}/betaAppReviewSubmission")
    print("HTTP", st)
    a = (d.get("data") or {}).get("attributes", {})
    print("betaReviewState:", a.get("betaReviewState"))

else:
    sys.exit(f"unknown cmd {cmd!r}")
