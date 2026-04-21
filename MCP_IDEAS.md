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

### 🆕 `autoStopPlay: true` オプション
**痛点**: Play中に editScript 送ると「Play停止して」と失敗する。ユーザーに言ってもらうまで待ち時間
**効果**: Play中なら自動で Stop してから実行
**難易度**: 小〜中（osascript で停止制御可能）

### 🆕 `findInvisibleObstacles()`
**痛点**: 透明で CanCollide=true な Part（今日の MainSpawn みたいなの）を手書きループで毎回探してた
**効果**: 常用コマンド化。CanCollide=true かつ Transparency>0.9 な Part をリスト
**難易度**: 小

### 🆕 `summarizeGui(path)`
**痛点**: ScreenGui のツリー構造と各要素のサイズ/位置をまとめて見たい時、手書き
**効果**: 1コマンドで「GameHUD → HPBar(Frame 200x20 top-left), Kills(TextLabel ...), ...」
**難易度**: 小

### 🆕 `liveSelectionSync`
**痛点**: Studio で「このPart何？」ってクリックしても MCP 側に伝わらない
**効果**: Plugin が Selection 変更を自動 Push、MCP 側で「今ユーザーが選んでるのはこれ」と分かる
**難易度**: 中（常時接続的な仕組み必要）

### 🆕 `diagnoseStuckCharacter(playerName)`
**痛点**: 「動かない」「透明の壁」系の問題で、毎回 DebugPos スクリプトを仕込んで runCode で起動
**効果**: 1コマンドでプレイヤー位置・前後左右 raycast・触れてるパーツをまとめて返す
**難易度**: 小

### 🆕 `hotReloadScript(path)`
**痛点**: スクリプト書換後、Play 中はロールバックされるので毎回 Stop→Play
**効果**: Edit モードで編集済スクリプトを手動で reload（Script.Disabled 切替で近似）
**難易度**: 小

### 🆕 `balanceReport()`
**痛点**: 武器バランスを手計算（TTK、DPS）してた
**効果**: GameConfig.WEAPONS から全武器の DPS / TTK / 1発キル距離を計算して表で返す
**難易度**: 小（ゲーム固有だが汎用化可能）

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
