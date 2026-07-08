#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/rustpush"

ensure_submodule() {
  local name="$1"
  local url="$2"
  local path="$VENDOR/$name"
  if [[ ! -d "$path/.git" ]]; then
    echo "Cloning $name..."
    git clone "$url" "$path"
  fi
}

if [[ -d "$VENDOR/.git" ]]; then
  echo "Updating vendor/rustpush..."
  git -C "$VENDOR" pull --ff-only
else
  echo "Cloning OpenBubbles/rustpush..."
  git clone https://github.com/OpenBubbles/rustpush.git "$VENDOR"
fi

# rustpush .gitmodules uses git@ URLs; use HTTPS clones (SSH fails in many CI/dev shells).
ensure_submodule "apple-private-apis" "https://github.com/OpenBubbles/apple-private-apis.git"
ensure_submodule "open-absinthe" "https://github.com/OpenBubbles/OpenAbsinthe-Stub.git"

# Nested submodule in apple-private-apis uses git@ URL; clone stub via HTTPS if missing.
ensure_clearadi_stub() {
  local clearadi="$VENDOR/apple-private-apis/clearadi"
  if [[ ! -f "$clearadi/Cargo.toml" ]]; then
    echo "Cloning clearadi-stub..."
    rm -rf "$clearadi"
    git clone --depth 1 https://github.com/OpenBubbles/clearadi-stub.git "$clearadi"
  fi
}

echo "Pinned rustpush: $(git -C "$VENDOR" rev-parse HEAD)"
echo "Pinned apple-private-apis: $(git -C "$VENDOR/apple-private-apis" rev-parse HEAD)"
echo "Pinned open-absinthe: $(git -C "$VENDOR/open-absinthe" rev-parse HEAD)"

# rustpush embeds FairPlay certs at compile time; real keys are gitignored.
# CI copies legacy stubs into certs/fairplay/ — mirror that here.
setup_fairplay_certs() {
  local legacy="$VENDOR/certs/legacy-fairplay"
  local fairplay="$VENDOR/certs/fairplay"
  local cert_names=(
    "4056631661436364584235346952193"
    "4056631661436364584235346952194"
    "4056631661436364584235346952195"
    "4056631661436364584235346952196"
    "4056631661436364584235346952197"
    "4056631661436364584235346952198"
    "4056631661436364584235346952199"
    "4056631661436364584235346952200"
    "4056631661436364584235346952201"
    "4056631661436364584235346952208"
  )

  if [[ ! -f "$legacy/fairplay.crt" || ! -f "$legacy/fairplay.pem" ]]; then
    echo "Missing $legacy/fairplay.{crt,pem}; cannot set up FairPlay certs." >&2
    exit 1
  fi

  mkdir -p "$fairplay"
  for name in "${cert_names[@]}"; do
    cp "$legacy/fairplay.pem" "$fairplay/$name.pem"
    cp "$legacy/fairplay.crt" "$fairplay/$name.crt"
  done
  echo "Set up ${#cert_names[@]} FairPlay cert stubs in certs/fairplay/"
}

# Spike implements OSConfig outside rustpush; upstream keeps ActivationInfo private.
ensure_rustpush_exports() {
  local lib="$VENDOR/src/lib.rs"
  if ! grep -q 'pub use activation::ActivationInfo;' "$lib"; then
    perl -i -pe 's/^mod activation;$/mod activation;\npub use activation::ActivationInfo;/' "$lib"
    perl -i -pe 's/^use activation::ActivationInfo;\n//' "$lib"
    echo "Patched rustpush to export ActivationInfo"
  fi
}

ensure_carrier_config_accessors() {
  local util="$VENDOR/src/util.rs"
  if ! grep -q 'fn supports_smsless' "$util"; then
    perl -i -0pe 's/(pub struct CarrierConfig \{\n    pub gateway: String,\n    carrier: Option<CarrierEntitlements>,\n\})\n\npub async fn get_gateways_for_mccmnc/\1\n\nimpl CarrierConfig {\n    pub fn supports_smsless(\&self) -> bool {\n        self.carrier.is_some()\n    }\n\n    pub fn entitlement_server_url(\&self) -> Option<\&str> {\n        self.carrier.as_ref().map(|c| c.server_address.as_str())\n    }\n\n    pub fn entitlement_protocol_version(\&self) -> Option<\&str> {\n        self.carrier\n            .as_ref()\n            .and_then(|c| c.protocol_version.as_deref())\n    }\n}\n\npub async fn get_gateways_for_mccmnc/s' "$util"
    echo "Patched rustpush CarrierConfig SMSLess accessors"
  fi
}

setup_fairplay_certs
ensure_rustpush_exports
ensure_carrier_config_accessors
ensure_clearadi_stub
