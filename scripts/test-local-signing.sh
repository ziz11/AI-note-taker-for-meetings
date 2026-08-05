#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_SCRIPT="$ROOT_DIR/scripts/setup-local-signing.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/recordly-local-signing-test.XXXXXX")"
FAKE_SECURITY="$TEST_ROOT/security"
FAKE_STATE="$TEST_ROOT/state"
PROJECT_JSON="$TEST_ROOT/project.json"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -x "$SETUP_SCRIPT" ]] || fail "setup-local-signing.sh is missing or not executable"

mkdir -p "$FAKE_STATE"

cat > "$FAKE_SECURITY" <<'FAKE_SECURITY_EOF'
#!/bin/zsh

set -euo pipefail

STATE_DIR="${RECORDLY_FAKE_SECURITY_STATE:?}"
command_name="${1:-}"

case "$command_name" in
  default-keychain)
    echo '"/tmp/fake-login.keychain-db"'
    ;;
  find-identity)
    if [[ -f "$STATE_DIR/installed" ]]; then
      echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Recordly Local Development"'
      echo '     1 valid identities found'
    else
      echo '     0 valid identities found'
    fi
    ;;
  import)
    touch "$STATE_DIR/installed"
    echo import >> "$STATE_DIR/mutations"
    ;;
  add-trusted-cert)
    [[ -f "$STATE_DIR/installed" ]] || exit 1
    echo trust >> "$STATE_DIR/mutations"
    ;;
  *)
    echo "Unexpected fake security command: $command_name" >&2
    exit 64
    ;;
esac
FAKE_SECURITY_EOF
chmod +x "$FAKE_SECURITY"

first_output="$(
  RECORDLY_FAKE_SECURITY_STATE="$FAKE_STATE" \
  RECORDLY_SECURITY_BIN="$FAKE_SECURITY" \
  RECORDLY_KEYCHAIN_PATH="$TEST_ROOT/login.keychain-db" \
  "$SETUP_SCRIPT"
)"

second_output="$(
  RECORDLY_FAKE_SECURITY_STATE="$FAKE_STATE" \
  RECORDLY_SECURITY_BIN="$FAKE_SECURITY" \
  RECORDLY_KEYCHAIN_PATH="$TEST_ROOT/login.keychain-db" \
  "$SETUP_SCRIPT"
)"

[[ "$first_output" == *"Created code-signing identity: Recordly Local Development"* ]] || \
  fail "first setup run did not report identity creation"
[[ "$second_output" == *"already exists"* ]] || \
  fail "second setup run did not report the existing identity"

mutation_count="$(wc -l < "$FAKE_STATE/mutations" | tr -d ' ')"
[[ "$mutation_count" == "2" ]] || \
  fail "expected one import and one trust mutation, got $mutation_count"

/usr/bin/plutil -convert json -o "$PROJECT_JSON" \
  "$ROOT_DIR/Recordly.xcodeproj/project.pbxproj"

/usr/bin/ruby -rjson -e '
  project = JSON.parse(File.read(ARGV.fetch(0)))
  objects = project.fetch("objects")
  target = objects.values.find do |object|
    object["isa"] == "PBXNativeTarget" && object["name"] == "Recordly"
  end
  abort "FAIL: Recordly native target not found" unless target

  configuration_list = objects.fetch(target.fetch("buildConfigurationList"))
  debug_id = configuration_list.fetch("buildConfigurations").find do |identifier|
    objects.fetch(identifier)["name"] == "Debug"
  end
  abort "FAIL: Recordly Debug configuration not found" unless debug_id

  settings = objects.fetch(debug_id).fetch("buildSettings")
  expected = {
    "CODE_SIGN_STYLE" => "Manual",
    "CODE_SIGN_IDENTITY" => "Recordly Local Development",
    "DEVELOPMENT_TEAM" => "",
    "PROVISIONING_PROFILE_SPECIFIER" => "",
    "PRODUCT_BUNDLE_IDENTIFIER" => "com.local.Recordly"
  }

  expected.each do |key, value|
    actual = settings[key]
    abort "FAIL: expected #{key}=#{value.inspect}, got #{actual.inspect}" unless actual == value
  end
' "$PROJECT_JSON"

echo "PASS"
