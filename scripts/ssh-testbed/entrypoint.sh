#!/bin/sh
# 全コンテナ共通の起動処理。
#   - ホスト鍵は /keys/host から借りる（再ビルドで known_hosts が毎回汚れるのを防ぐ）
#   - 公開鍵は /keys/authorized_keys から借りる
#   - AUTH=pw のときだけパスワード認証のみ（SSH_ASKPASS の検証用）
#   - MOTD を出す（実サーバでは stdout に混ざる。混ざらないことを確かめるために「あえて」出す）
set -eu

mkdir -p /etc/ssh /home/mred/.ssh

# ホスト鍵: 事前生成したものがあれば使い、無ければその場で作る
if [ -d /keys/host ] && [ -f /keys/host/ssh_host_ed25519_key ]; then
    cp /keys/host/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key
    cp /keys/host/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ed25519_key.pub
    chmod 600 /etc/ssh/ssh_host_ed25519_key
else
    ssh-keygen -A
fi

if [ -f /keys/authorized_keys ]; then
    cp /keys/authorized_keys /home/mred/.ssh/authorized_keys
    chmod 700 /home/mred/.ssh
    chmod 600 /home/mred/.ssh/authorized_keys
fi
chown -R mred:mred /home/mred/.ssh

# 認証方式
if [ "${AUTH:-key}" = "pw" ]; then
    # パスワードのみ。鍵は受け付けない = SSH_ASKPASS を必ず通る
    printf 'PasswordAuthentication yes\nPubkeyAuthentication no\n' > /etc/ssh/sshd_config.d/testbed.conf
else
    printf 'PasswordAuthentication no\nPubkeyAuthentication yes\n' > /etc/ssh/sshd_config.d/testbed.conf
fi
echo 'PermitRootLogin no' >> /etc/ssh/sshd_config.d/testbed.conf

# ログイン時に喋る相手（stdout 汚染の検証用）。MOTD_NOISE=0 で黙らせる
if [ "${MOTD_NOISE:-1}" = "1" ]; then
    printf '=== testbed %s ===\nDo not trust this banner.\n' "${HOSTNAME:-unknown}" > /etc/motd
else
    : > /etc/motd
fi

# 中身のあるログを一つ置いておく（無いと繋いでも開くものが無い）
mkdir -p /srv/logs
if [ ! -f /srv/logs/app.log ]; then
    i=1
    while [ "$i" -le 200 ]; do
        printf '2026-08-15T09:%02d:%02dZ %s app[%d]: request id=%d status=%d\n' \
            $((i % 60)) $(((i * 7) % 60)) \
            "$(if [ $((i % 25)) -eq 0 ]; then echo ERROR; else echo INFO; fi)" \
            "$$" "$i" "$(if [ $((i % 25)) -eq 0 ]; then echo 500; else echo 200; fi)"
        i=$((i + 1))
    done > /srv/logs/app.log
fi
chown -R mred:mred /srv/logs

exec /usr/sbin/sshd -D -e
