# 🧠 MCP 機能アイデア帳

作業中に「あったら楽だな」と感じた機能を随時追加する。
実装検討は後日、思いついた瞬間の気付きを逃さない用。

## ステータス凡例
- 🆕 新規アイデア
- 🔍 調査中（実装可否、設計検討）
- 🚧 実装予定
- ✅ 実装済み

---

## 📝 アイデア

### 🆕 `searchAndEdit(keyword, newCode)`
**痛点**: `searchInScripts` の結果を使って editScript すると、その間に行番号変わっててズレる
**効果**: 原子的に検索→編集できる
**難易度**: 小

### ✅ `autoStopPlay: true` オプション (v5.2)
registerTool wrapper が Play モードエラーを検知したら osascript で Stop→再試行

### ✅ `findInvisibleObstacles()` (v5.2)
透明 + CanCollide=true な Part を列挙する

### 🆕 `summarizeGui(path)`
**痛点**: ScreenGui のツリー構造と各要素のサイズ/位置をまとめて見たい時、手書き
**効果**: 1コマンドで「GameHUD → HPBar(Frame 200x20 top-left), Kills(TextLabel ...), ...」
**難易度**: 小

### 🆕 `liveSelectionSync`
**痛点**: Studio で「このPart何？」ってクリックしても MCP 側に伝わらない
**効果**: Plugin が Selection 変更を自動 Push、MCP 側で「今ユーザーが選んでるのはこれ」と分かる
**難易度**: 中（常時接続的な仕組み必要）

### ✅ `diagnoseStuckCharacter(playerName)` (v5.2)
プレイヤーの位置 / 6方向raycast / 触れてるパーツ を一発で返す

### 🆕 `hotReloadScript(path)`
**痛点**: スクリプト書換後、Play 中はロールバックされるので毎回 Stop→Play
**効果**: Edit モードで編集済スクリプトを手動で reload（Script.Disabled 切替で近似）
**難易度**: 小

### ✅ `balanceReport()` (v5.2)
GameConfig.WEAPONS の武器全部の DPS/TTK 自動計算

### 🆕 `profileRunCode(code)`
**痛点**: `runCode` が遅い時、どこが重いか分からない
**効果**: 実行前後で `os.clock()` 取り、Stats から FPS 変化も見る
**難易度**: 小

### 🆕 `recordAndAnnotate`（録画式スクショ）
**痛点**: バグが連続動作中にしか出ない。単発スクショじゃ不足
**効果**: N秒間キャプチャして gif or mp4 として返す（ffmpeg）
**難易度**: 中（Node側で ffmpeg 呼出）

### 🆕 `snapshotUndo`
**痛点**: snapshot を取った後、Ctrl+Z で Studio 状態を snapshot 時点に戻したい
**効果**: snapshot を取った時点で ChangeHistoryService の recordId も記録、undo で戻せる
**難易度**: 中

### 🆕 `assertState(expectations)`
**痛点**: テスト的に「A は存在すべき、B のCanCollide は false べき」を毎回手書き
**効果**: JSON で期待値渡し、満たしてるかチェック
**難易度**: 小

---

## 📌 実装済み（参考）

- ✅ getOutput — Play中ログ捕捉
- ✅ captureScreen studio-mode
- ✅ findPartsNear
- ✅ bulkUpdate
- ✅ snapshot / diffFromSnapshot
- ✅ measureDistance / measureBounds
- ✅ getPerformanceStats
- ✅ generateUIFromSpec

---

## ✍️ 追加方法

作業中に気付いたら、このファイルの「アイデア」セクションに追記：

```markdown
### 🆕 `featureName(args)`
**痛点**: （何が不便だったか）
**効果**: （何ができるようになるか）
**難易度**: 小/中/大
```
