#!/bin/bash

# Only run for Debug builds
if [ "$CONFIGURATION" != "Debug" ]; then
    exit 0
fi

BUNDLE_ID="com.tk.My-Mac-App"
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

if [ ! -f "$TCC_DB" ]; then
    echo "warning: TCC database not found at $TCC_DB"
    exit 0
fi

if [ ! -w "$TCC_DB" ]; then
    echo "warning: Cannot write to TCC database — grant Full Disk Access to Xcode in System Settings > Privacy & Security > Full Disk Access"
    exit 0
fi

sqlite3 "$TCC_DB" \
    "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version) \
     VALUES ('kTCCServiceAccessibility', '$BUNDLE_ID', 0, 2, 4, 1);" 2>/dev/null

if [ $? -eq 0 ]; then
    echo "note: Accessibility permission granted for $BUNDLE_ID"
else
    echo "warning: sqlite3 failed — grant Full Disk Access to Xcode and try again"
fi
