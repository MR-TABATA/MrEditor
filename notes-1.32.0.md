## 1.32.0

• `$EDITOR` として使えるようにしました（`mreditor --wait`）:
`git commit` などが MrEditor でファイルを開き、タブを閉じるまで待ちます。設定例は `git config --global core.editor "mreditor --wait"` です（先に `sh scripts/install-cli.sh` で `mreditor` コマンドを入れてください）。`crontab -e` や `kubectl edit` など、`$EDITOR` を呼ぶものなら同じです。
• 呼び出し元に戻る操作は、タブを閉じる、または MrEditor の終了（⌘Q）です。⌘S（保存）だけでは戻りません。保存せずに閉じても終了コードは 0 です（git はメッセージが空なら中止します）。待っている間は、タブの左下に「呼び出し元が待っています」の帯が出ます。
• 存在しないパス・フォルダ・圧縮ファイル（gzip・zip）・読めないファイルは、エラー（終了コード 1）になります。MrEditor が落ちたときも 1 です。ターミナルで Ctrl-C を押すと 130 で終わり、タブは開いたままの普通のタブに戻ります。
