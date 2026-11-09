#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Laavat Oy
"""Stub LAAVAT signing service for the hermetic do_laavat_sign smoke.

Mirrors the signing-tool client's own test stub: add -> presigned upload ->
PUT -> get(Ready) -> download. Signing is b"SIGNED(" + uploaded + b")" computed per request, so
the digests it reports are real rather than canned and any payload works.

An upload that is a tar.gz holding a request.json is answered in hab-archive-v1
mode instead: every CSF comes back as a result and each binary as signed/<name>.
CST is not involved either way, so the output is not a real HAB signature.

--corrupt-digest reports a digest the artifact does not have: the task must
fail without writing LAAVAT_SIGN_OUTPUT.
"""

import argparse
import base64
import hashlib
import io
import json
import tarfile
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE_READY = 16

# A fixed RSA-2048 public key, base64 of the DER SubjectPublicKeyInfo - the
# shape `product getpubkey` expects. Fixed rather than generated so the fingerprint
# below is stable and a kas file can pin it; this stub carries no private half
# and signs nothing with it.
#
#   SHA-256 of the DER SPKI: 6ee04e1973b43e0eede638c61d24f5d4e3b176d38b57a27a97f0fa0d9522e68f
#
# That is what LAAVAT_PUBKEY_SHA256 / LAAVAT_FIT_PUBKEY_SHA256 must be set to
# when building against this stub.
STUB_PUBLIC_KEY_B64 = (
    "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAv0DTUTAFeC4YOfzUfRJ1lf5CIxqc"
    "DMM23Ri5fuNsLRYcUOTdKZ/jHQkwc7heXUKLsEsK/9+RVK5xxYPelQIgSbLuaTvfRQM7abLb"
    "pc/mpwpeEvntkkMQiERhGGY9bAU2h+Dz8qinuWCwZwFpMrdsbNzDxm2WhLez6zYQpmXyB6kn"
    "pwc0asFArq98d7KLUGNfhDK6uGZkWC1Td0ig722Rxr2F/SrE5SXUvebohwicHuX8ICwX4Dfr"
    "WSVOmzRYBUNNfUKIXCC0YXA6v5EciMHaXIkxfgnoPn9DT+lkJqLBpYsTxNDityV4N5tx3g6G"
    "Z+XsGpxZ9GftXOOTrSaQ6+EiKwIDAQAB")

state = {"uploaded": None, "signed": None}
args = None


def sign_archive(upload):
    """hab-archive-v1: request.json + binaries in -> response.json + signed/ out.

    Returns None when the upload is not an archive, so file mode is unchanged.
    Every CSF is echoed back as a result because the client matches all of them;
    the signature itself is the same SIGNED(...) wrap file mode uses.
    """
    try:
        with tarfile.open(fileobj=io.BytesIO(upload), mode="r:gz") as tf:
            members = {m.name: tf.extractfile(m).read() for m in tf
                       if m.isfile()}
    except (tarfile.TarError, OSError):
        return None
    if "request.json" not in members:
        return None

    doc = json.loads(members["request.json"].decode())
    csfs = doc.get("csfs") or [doc]
    # RAUC's resign payload also tars up a "request.json" (inputFile/format/resign, no
    # binaryFilename) - only a real hab-archive-v1 doc has that key on every CSF.
    if not all(isinstance(c, dict) and "binaryFilename" in c for c in csfs):
        return None
    signed = {name: b"SIGNED(" + blob + b")"
              for name, blob in members.items() if name != "request.json"}

    results = []
    for i, csf in enumerate(csfs):
        name = csf["binaryFilename"]
        patched = csf.get("output", "patched") != "raw"
        out_sha = hashlib.sha256(signed[name]).hexdigest()
        results.append({
            "id": csf.get("id") or "csf-%d" % i,
            "binaryFilename": name,
            "mode": csf.get("mode"),
            "patched": patched,
            "sha256_input": hashlib.sha256(members[name]).hexdigest(),
            "sha256_output": out_sha if patched else None,
            "signatureOffset": csf.get("signatureOffset"),
        })

    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz") as tf:
        entries = [("response.json",
                    json.dumps({"version": "1", "csfs": results}).encode())]
        entries += [("signed/" + n, b) for n, b in sorted(signed.items())]
        for name, blob in entries:
            info = tarfile.TarInfo(name)
            info.size = len(blob)
            tf.addfile(info, io.BytesIO(blob))
    return out.getvalue()


class Handler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *a):
        print("stub: " + fmt % a, flush=True)

    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _response(self, payload=None):
        doc = {"id": "req-1", "name": "n", "description": "d",
               "idProduct": "prod-uuid", "idProductOperation": "oper-uuid",
               "state": STATE_READY}
        if payload is not None:
            doc["payload"] = payload
        return doc

    def do_GET(self):
        # /s3/* is the presigned link itself: the real client hits it with
        # plain requests, no bearer token, same as real S3.
        if not self.path.startswith("/s3/") and not self.headers.get("Authorization"):
            return self.send_error(401)
        if self.path.endswith("/presigneduploadlinks"):
            return self._json({"s3Url": "http://127.0.0.1:%d/s3/put" % args.port,
                               "s3ResourceID": "rid-1"})
        if self.path.startswith("/s3/get"):
            body = state["signed"] or b""
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            return self.wfile.write(body)
        if "/products/" in self.path and "/imagesignings/" not in self.path:
            # `product getpubkey` reads the operation out of the product and
            # takes the key from token.public_key. Without this route the two
            # tasks that fetch a key - do_laavat_fitkey and
            # do_laavat_fetch_pubkey - could only be exercised against a live
            # service, which is to say not in a hermetic build.
            # Every field the generated SDK's Product/ProductOperation models
            # refuse to deserialise as None, not just the ones read here.
            return self._json({
                "id": "prod-uuid",
                "name": "stub-product",
                "description": "stub product",
                "enabled": True,
                "state": STATE_READY,
                "productType": "Generic",
                "externalRequestID": "ext-1",
                "caInfo": {},
                "productConfigItems": [],
                "rndKeys": [],
                "productOperations": [{
                    "id": "oper-uuid",
                    "name": "stub-operation",
                    "description": "stub operation",
                    "operationType": "SignKernel",
                    "approvalRule": {"name": "none", "description": "no approval",
                                     "allowedGroups": [], "approvalGroups": [],
                                     "blanketGroups": []},
                    "caUseCase": "None",
                    "profileID": "profile-1",
                    "token": {
                        "name": "stub-key",
                        "description": "stub signing key",
                        "keyType": "RSA_2048",
                        "extractable": False,
                        "keyOverrideID": "",
                        "publicKey": STUB_PUBLIC_KEY_B64,
                    },
                }],
            })
        if "/imagesignings/" in self.path:
            digest = ("00" * 32 if args.corrupt_digest
                      else hashlib.sha256(state["signed"] or b"").hexdigest())
            return self._json(self._response({
                "name": "payload.bin",
                "modifiedSHA256": digest,
                "originalSHA256": hashlib.sha256(
                    state["uploaded"] or b"").hexdigest(),
                "s3Url": "http://127.0.0.1:%d/s3/get" % args.port,
            }))
        self.send_error(404)

    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0))
        state["uploaded"] = base64.b64decode(self.rfile.read(n))
        try:
            state["signed"] = (sign_archive(state["uploaded"])
                               or b"SIGNED(" + state["uploaded"] + b")")
        except KeyError as e:
            return self.send_error(400, "request.json names missing binary %s" % e)
        self.send_response(200)
        self.send_header("ETag", '"etag-1"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if not self.headers.get("Authorization"):
            return self.send_error(401)
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        if self.path.endswith("/approvals"):
            self.send_response(200)
            self.send_header("Content-Length", "0")
            return self.end_headers()
        self._json(self._response())


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", type=int, default=8943)
    p.add_argument("--corrupt-digest", action="store_true",
                   help="report a digest the signed artifact does not have")
    args = p.parse_args()
    print("stub listening on 127.0.0.1:%d" % args.port, flush=True)
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
