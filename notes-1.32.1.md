## 1.32.1

• 修正: `/usr/local/bin/mreditor`（ヘルプの「ターミナルから使う…」で入れるコマンド）から起動すると、起動中の MrEditor を見つけられない不具合を直しました:
1.32.0 では、`mreditor --wait` が「MrEditor が終了しました」ですぐ戻りました。`mreditor ファイル` や `| mreditor` も、起動中の MrEditor に渡さず、別の MrEditor が立ち上がっていました（1.31.1 の受け渡しも同じ原因です）。コマンドの実際の場所から、起動中の MrEditor を探すようにしました。
• ヘルプの「ターミナルから使う…」に、`$EDITOR` として使う設定（`git config --global core.editor "mreditor --wait"`）を足しました。`mreditor` コマンドは、ヘルプのこの画面から入れます。
