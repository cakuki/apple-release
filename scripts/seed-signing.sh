#!/usr/bin/env bash
#
# seed-signing.sh — one-time signing setup for a bundle id.
# Registers the App ID (if missing) and runs `match appstore` to CREATE + store
# the distribution cert + provisioning profile in the cakuki/ios-signing repo.
#
# Requires an App Store Connect API key with the **Admin** role (only Admin keys
# can create certificates/identifiers/profiles). Run once per app from a dev
# machine; CI then consumes the stored assets read-only.
#
# Usage:
#   ADMIN_KEY_ID=ABC123XYZ \
#   ADMIN_P8=~/Downloads/AuthKey_ABC123XYZ.p8 \
#   ASC_ISSUER_ID=<your-issuer-uuid> \
#   MATCH_PASSWORD="$(cat /tmp/match_password.txt)" \
#   ./scripts/seed-signing.sh com.example.App
#
# Env:
#   ADMIN_KEY_ID    (required) Key ID of the Admin ASC API key
#   ADMIN_P8        (required) path to the Admin key's .p8 file
#   MATCH_PASSWORD  (required) match encryption passphrase
#   ASC_ISSUER_ID   (required) App Store Connect issuer id
set -euo pipefail

BUNDLE="${1:?usage: seed-signing.sh <bundle_id>}"
: "${ADMIN_KEY_ID:?set ADMIN_KEY_ID}"
: "${ADMIN_P8:?set ADMIN_P8 (path to Admin .p8)}"
: "${MATCH_PASSWORD:?set MATCH_PASSWORD}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
ISSUER="$ASC_ISSUER_ID"
SIGNING_REPO="git@github.com:cakuki/ios-signing.git"

# Homebrew ruby (system ruby 2.6 can't build fastlane native gems)
export PATH="/usr/local/opt/ruby/bin:$PATH"
cd "$(dirname "$0")/.."   # apple-release repo root (has the Gemfile)

# Build the fastlane api_key JSON from the Admin .p8
JSON="$(mktemp -t asc_admin_key).json"
trap 'rm -f "$JSON"' EXIT
ruby -rjson -e 'File.write(ARGV[3], JSON.pretty_generate({"key_id"=>ARGV[0],"issuer_id"=>ARGV[1],"key"=>File.read(ARGV[2]),"duration"=>1200,"in_house"=>false}))' \
  "$ADMIN_KEY_ID" "$ISSUER" "$ADMIN_P8" "$JSON"

# 1) Register the App ID (idempotent)
echo "==> Registering bundle id $BUNDLE (if missing)"
KEY_ID="$ADMIN_KEY_ID" ISSUER="$ISSUER" P8="$ADMIN_P8" BUNDLE="$BUNDLE" \
bundle exec ruby -e '
require "spaceship"
t = Spaceship::ConnectAPI::Token.create(key_id: ENV["KEY_ID"], issuer_id: ENV["ISSUER"], filepath: ENV["P8"])
Spaceship::ConnectAPI.token = t
id = ENV["BUNDLE"]
b = Spaceship::ConnectAPI::BundleId.all.find { |x| x.identifier == id }
if b then puts "    exists: #{b.identifier}"
else
  nm = id.split(".").map(&:capitalize).join(" ")
  Spaceship::ConnectAPI::BundleId.create(name: nm, identifier: id, platform: "IOS")
  puts "    created: #{id}"
end'

# 2) Create + store signing assets
echo "==> Running match appstore for $BUNDLE"
bundle exec fastlane match appstore \
  --app_identifier "$BUNDLE" \
  --git_url "$SIGNING_REPO" \
  --api_key_path "$JSON" \
  --readonly false

echo "==> Done. Encrypted certs/profiles pushed to cakuki/ios-signing for $BUNDLE."
echo "    CI can now consume them read-only."
