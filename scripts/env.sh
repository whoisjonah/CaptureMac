developer_dir=$(xcode-select -p 2>/dev/null || true)
if [[ "$developer_dir" == *CommandLineTools* && -z "${SDKROOT:-}" ]]; then
  sdk=$(ls -d "$developer_dir"/SDKs/MacOSX26*.sdk 2>/dev/null | grep -E 'MacOSX26(\.[0-9]+)?\.sdk$' | sort -V | tail -1 || true)
  if [[ -n "$sdk" ]]; then
    export SDKROOT="$sdk"
  fi
fi

testing_plugins="$developer_dir/usr/lib/swift/host/plugins/testing"
