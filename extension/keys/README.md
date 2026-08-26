# Extension signing key

`duck.pem` is the private key that fixes the extension's id to:

```
plhnfefaihmkhbhbgkbhjlcmffjgdclb
```

`key.txt` is the matching public key, injected into the manifest at build time.
Chrome derives the id from it, so an unpacked build and a published build share
one id.

Two things break without that:

- **Native messaging** — the host manifest lists the id in `allowed_origins`.
  A shifting id means the bridge silently refuses every connection.
- **Enterprise policy** — `ExtensionInstallForcelist` targets an id. Content
  Guard cannot be made unremovable without one that holds still.

## Do not commit the private key

`duck.pem` is gitignored. Losing it means a new id, which means reinstalling the
native host and rewriting the policy on every machine. Keep it in your password
manager, not only on this disk.

To regenerate the public half after restoring the private key:

```bash
openssl rsa -in keys/duck.pem -pubout -outform DER | base64 > keys/key.txt
```
