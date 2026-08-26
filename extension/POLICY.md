# Locking Duck Content Guard to the machine

The extension blocks well, but on its own it is removable from the browser's
extensions page in two clicks. This closes that, and the DNS gap with it.

Everything here needs an administrator password **once**. After that, undoing it
also needs an administrator password — which is the entire point. If the person
being protected has the admin password, this is a speed bump, not a wall. On a
family device, keep the admin account separate.

## The four layers

| Layer | Covers | Undone by |
| --- | --- | --- |
| Cloudflare DNS `1.1.1.3` | every browser and app on the machine | changing DNS (admin) |
| Locked DoH | browsers bypassing that DNS | policy change (admin) |
| Force-installed extension | the extension being removed or disabled | policy change (admin) |
| Guard's PIN and waiting period | the impulse itself | the wait elapsing |

---

## 1. DNS — the widest net

Cloudflare's family resolver blocks adult content for the whole machine, not
just one browser.

| | IPv4 | IPv6 |
| --- | --- | --- |
| Malware + adult | `1.1.1.3`, `1.0.0.3` | `2606:4700:4700::1113`, `2606:4700:4700::1003` |

**macOS** — System Settings → Network → your connection → Details → DNS, then
replace every entry with `1.1.1.3` and `1.0.0.3`.

Or from the terminal, replacing `Wi-Fi` with your service name if it differs:

```bash
sudo networksetup -setdnsservers Wi-Fi 1.1.1.3 1.0.0.3
networksetup -getdnsservers Wi-Fi        # verify
```

Setting it on the **router** instead covers every device on the network and is
harder to change from any single machine.

## 2. Close the DNS-over-HTTPS bypass

This step is the one people miss, and skipping it makes step 1 decorative.

Modern browsers can resolve names themselves over HTTPS, ignoring the DNS you
just set. Turning that off has to be done by policy — a settings toggle can be
flipped back.

Create the policy file for Brave:

```bash
sudo mkdir -p "/Library/Managed Preferences"
sudo tee /Library/Managed\ Preferences/com.brave.Browser.plist >/dev/null <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>DnsOverHttpsMode</key>
  <string>off</string>
  <key>BuiltInDnsClientEnabled</key>
  <false/>
</dict>
</plist>
PLIST
```

For Chrome, the same file at `com.google.Chrome.plist`.

Restart the browser and confirm at `brave://policy` (or `chrome://policy`) that
`DnsOverHttpsMode` shows as `off` and its source is a platform policy.

## 3. Make the extension unremovable

A force-installed extension cannot be removed or disabled by the user — its
toggle and its Remove button are greyed out.

This requires the extension to have a stable ID, which means publishing it to the
Chrome Web Store, or self-hosting a signed `.crx` with an update manifest. A
`--load-extension` build gets a new ID each time it moves and cannot be pinned.

Once you have the store ID, add it to the same plist:

```xml
<key>ExtensionInstallForcelist</key>
<array>
  <string>YOUR_EXTENSION_ID;https://clients2.google.com/service/update2/crx</string>
</array>
<key>ExtensionSettings</key>
<dict>
  <key>YOUR_EXTENSION_ID</key>
  <dict>
    <key>installation_mode</key>
    <string>force_installed</string>
    <key>toolbar_pin</key>
    <string>force_pinned</string>
  </dict>
</dict>
```

Reload the policy and restart:

```bash
sudo killall cfprefsd
```

Verify at `brave://extensions` — the extension should now say it is installed by
your administrator, with no way to turn it off.

## 4. Optional: block the other browsers

None of the above helps if a second browser gets installed. On macOS, Screen Time
(System Settings → Screen Time → Content & Privacy) can restrict which apps run
and can itself be locked with a separate passcode.

Set that passcode to something different from the login password, or the whole
chain unravels at the first step.

---

## What is still open, honestly

- **Admin access.** Every layer here answers to the administrator password. If
  that is known, everything above can be undone.
- **Another device.** This machine is covered; a phone is not. The Duck mobile
  app has its own blocking.
- **A VPN or a different network.** Router-level DNS stops applying. Setting DNS
  on the machine as well as the router covers this.
- **Storage tampering.** Someone who knows their way around the browser's
  developer tools can clear the extension's stored state, which resets the PIN
  and the pending wait. Force-installing does not prevent that. Nothing an
  extension can do prevents it — this is the honest ceiling of the browser layer,
  and the reason DNS matters more than the extension does.
