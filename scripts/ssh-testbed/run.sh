#!/bin/sh
# SSH 検証用の Linux ホスト群を建てる／畳む。
#
#   sh run.sh keys     鍵を作る（初回のみ。keys/ は git 管理外）
#   sh run.sh up       建てる
#   sh run.sh up-big   testdata/test_10gb.log を deb に差し込んで建てる
#   sh run.sh config   ~/.ssh/config に貼る設定を出す
#   sh run.sh check    5 ホストに実際に繋がるか確かめる
#   sh run.sh down     畳む（鍵は残る）
set -eu

cd "$(dirname "$0")"
DIR=$(pwd)
KEY="$DIR/keys/id_ed25519"

compose() { docker compose "$@"; }

cmd_keys() {
    mkdir -p keys/host
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N '' -C mreditor-testbed -f "$KEY"
    [ -f keys/host/ssh_host_ed25519_key ] || \
        ssh-keygen -t ed25519 -N '' -C testbed-host -f keys/host/ssh_host_ed25519_key
    cp "$KEY.pub" keys/authorized_keys
    echo "鍵は $DIR/keys/ に置いた（git 管理外）"
}

cmd_config() {
    cat <<EOF
# --- MrEditor ssh-testbed ここから ---
Host mred-deb mred-alma mred-pw mred-jump
    HostName 127.0.0.1
    User mred
    IdentityFile $KEY
    IdentitiesOnly yes
    # 建て直すたびにホスト鍵が変わっても手元を汚さない
    UserKnownHostsFile $DIR/keys/known_hosts
    StrictHostKeyChecking accept-new

Host mred-deb
    Port 2201
Host mred-alma
    Port 2202
Host mred-pw
    Port 2203
    PubkeyAuthentication no
    PasswordAuthentication yes
Host mred-jump
    Port 2204

# ポート非公開。踏み台経由でしか届かない = ProxyJump の実地検証先
Host mred-inner
    HostName inner
    User mred
    IdentityFile $KEY
    IdentitiesOnly yes
    UserKnownHostsFile $DIR/keys/known_hosts
    StrictHostKeyChecking accept-new
    ProxyJump mred-jump
# --- ここまで ---
EOF
}

cmd_check() {
    for h in mred-deb mred-alma mred-jump mred-inner; do
        printf '%-11s ' "$h"
        ssh -F "${SSH_CONFIG:-$HOME/.ssh/config}" -o ConnectTimeout=5 -o BatchMode=yes \
            "$h" 'uname -s; head -1 /srv/logs/app.log' 2>&1 | tr '\n' ' '
        echo
    done
    echo 'mred-pw     (パスワード認証のみ。対話で mred / mred を入れて確かめること)'
}

case "${1:-}" in
    keys)   cmd_keys ;;
    up)     cmd_keys; compose up -d --build ;;
    up-big) cmd_keys; compose -f compose.yaml -f compose.bigfile.yaml up -d --build ;;
    config) cmd_config ;;
    check)  cmd_check ;;
    down)   compose down ;;
    ps)     compose ps ;;
    *)      sed -n '2,12p' "$0"; exit 1 ;;
esac
