#!/bin/bash
# 创建独立的代码签名钥匙串 + 自签名证书 "MouseFix Dev"（幂等，无 GUI 弹窗）。
#
# 为什么需要：ad-hoc 签名（codesign --sign -）每次构建 cdhash 都会变，
# macOS TCC（辅助功能 / 屏幕录制）授权绑定 cdhash，每次重新构建授权全部失效。
# 改用固定证书签名后，授权锚定「证书 + Bundle ID」，跨构建持续有效，只需授权一次。
#
# 为什么用独立钥匙串：放登录钥匙串会在首次签名时弹「允许访问私钥」系统对话框；
# 独立钥匙串的密码由本脚本生成并保存在 .codesign/ 内，可直接设置 partition list，全程无弹窗。
set -euo pipefail

cd "$(dirname "$0")"

NAME="MouseFix Dev"
DIR=".codesign"
# security 工具对相对路径解析有怪癖（会误解析到 ~/Library/Keychains 下的 GUID 文件），必须用绝对路径
KC="$PWD/$DIR/mousefix.keychain-db"
PW_FILE="$DIR/keychain-password"

mkdir -p "$DIR"

# 首次生成随机密码并保存（仅本机使用，勿提交 git）
if [ ! -f "$PW_FILE" ]; then
  openssl rand -hex 24 > "$PW_FILE"
  chmod 600 "$PW_FILE"
fi
PASS="$(cat "$PW_FILE")"

if [ ! -f "$KC" ]; then
  echo "==> 创建独立签名钥匙串"
  security create-keychain -P "$PASS" "$KC"
  # 禁止自动锁定
  security set-keychain-settings -lut 21600 "$KC"

  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT

  cat > "$TMP/openssl.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = MouseFix Dev
[ ext ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/openssl.cnf" 2>/dev/null

  # -legacy：macOS security 工具对 OpenSSL 3 默认的 PKCS#12 MAC 算法不兼容
  openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$PASS" -name "$NAME" 2>/dev/null

  security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
  rm -rf "$TMP"; trap - EXIT

  # 允许 codesign 等工具无弹窗使用私钥
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
fi

security unlock-keychain -p "$PASS" "$KC"

# 加入用户钥匙串搜索列表（幂等），否则 codesign 找不到身份
if ! security list-keychains -d user | tr -d ' "' | grep -qx "$KC"; then
  # shellcheck disable=SC2046
  security list-keychains -d user -s $(security list-keychains -d user | tr -d ' "') "$KC"
fi
echo "签名钥匙串就绪：${KC}（身份：${NAME}）"
