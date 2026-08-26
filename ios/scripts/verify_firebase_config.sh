#!/bin/sh
#
# Fails the build when GoogleService-Info.plist does not describe this target.
#
# Firebase on Apple platforms matches the app to a Firebase app by bundle id at
# runtime. When they disagree, nothing throws and nothing logs at the default
# level — Crashlytics simply stops delivering, and you find out weeks later
# from a dashboard that has been empty since the rename. This turns that into a
# build error, which is the only moment anyone is looking.
#
# The mismatch is not hypothetical: changing PRODUCT_BUNDLE_IDENTIFIER is a
# normal thing to do before shipping, and regenerating the plist is a separate
# step in a different tool that is easy to forget.

set -e

PLIST="${SRCROOT}/Runner/GoogleService-Info.plist"

if [ ! -f "${PLIST}" ]; then
  echo "error: GoogleService-Info.plist is missing from ios/Runner/." >&2
  echo "note: Run 'flutterfire configure' to generate it, or Crashlytics and" >&2
  echo "note: Analytics will be silently inert on iOS." >&2
  exit 1
fi

PLIST_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :BUNDLE_ID" "${PLIST}" 2>/dev/null || true)

if [ -z "${PLIST_BUNDLE_ID}" ]; then
  echo "error: GoogleService-Info.plist has no BUNDLE_ID key — it is corrupt." >&2
  exit 1
fi

# ${PRODUCT_BUNDLE_IDENTIFIER} is expanded by Xcode from the build settings, so
# this compares against whatever this configuration is actually shipping.
if [ "${PLIST_BUNDLE_ID}" != "${PRODUCT_BUNDLE_IDENTIFIER}" ]; then
  echo "error: Firebase config does not match this target's bundle id." >&2
  echo "note:   Xcode builds: ${PRODUCT_BUNDLE_IDENTIFIER}" >&2
  echo "note:   Firebase expects: ${PLIST_BUNDLE_ID}" >&2
  echo "note: Crashlytics would receive nothing, without any runtime error." >&2
  echo "note: Fix by registering ${PRODUCT_BUNDLE_IDENTIFIER} in the Firebase" >&2
  echo "note: console and re-running 'flutterfire configure'." >&2
  exit 1
fi

echo "Firebase config matches ${PRODUCT_BUNDLE_IDENTIFIER}"
