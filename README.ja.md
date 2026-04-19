# 🎮 Roblox Studio Ultimate MCP Server

Roblox Studio を完全制御する MCP（Model Context Protocol）サーバー。Claude Code や MCP 対応 AI アシスタントから **41個のツール** で Studio を操作できます。

[English](README.md) | **日本語**

## ✨ なぜ作ったのか

デフォルトの Roblox Studio MCP は `run_code` しか提供していません。スクリプトの修正は文字列操作（`gsub`）で行うしかなく：
- ❌ パターンマッチの失敗
- ❌ `end)` の破壊
- ❌ 書き換えが反映されず無言ロールバック
- ❌ 構文チェックなし
- ❌ 簡単な修正に何時間もかかる

**この MCP がすべて解決します。**

## 🚀 機能一覧

### スクリプト操作（最大の特長）
| ツール | 説明 |
|--------|------|
| `getScript` | ソースコード全文取得 |
| `setScript` | ソース丸ごと書き換え（構文チェック＋自動バックアップ付き） |
| `editScript` | 特定行だけ差分編集 |
| `insertCode` | 指定行の後にコード挿入 |
| `removeLines` | 特定行を削除 |
| `replaceInScript` | 文字列置換（プレーンテキスト、安全） |
| `getLines` | 特定行範囲だけ取得（軽量） |
| `getFunctionList` | 全関数名＋行番号一覧 |
| `getScriptSummary` | 概要：関数/require/グローバル変数 |
| `listScripts` | 全スクリプト一覧 |
| `getAllScripts` | 全ソース一括取得 |
| `searchInScripts` | 全スクリプト横断キーワード検索 |
| `getReferences` | 変数/関数の全使用箇所検索 |
| `getModuleDependencies` | require() 依存一覧 |

### 安全機構
| 機能 | 説明 |
|------|------|
| 🔒 **構文チェック** | 書き込み前に自動検証。エラーなら書き込み拒否 |
| 💾 **自動バックアップ** | 編集前のソースを自動保存（10世代） |
| 🛑 **Playモードガード** | Play中の書き込みを即エラーに（無言ロールバック防止） |
| 📝 **UpdateSourceAsync** | ScriptEditorService 経由で競合なし書き込み |

### バックアップ＆復元
| ツール | 説明 |
|--------|------|
| `restoreBackup` | バックアップから復元 |
| `listBackups` | バックアップ一覧 |

### 検証
| ツール | 説明 |
|--------|------|
| `checkSyntax` | 構文チェックのみ（書き込みなし） |
| `verifyScript` | 行数/ソース長の確認 |
| `validateAllScripts` | 全スクリプト一括構文チェック |

### インスタンス操作
| ツール | 説明 |
|--------|------|
| `getTree` | インスタンス階層取得 |
| `getChildren` | 子要素一覧（軽量） |
| `getProperty` / `setProperty` | プロパティ取得/設定 |
| `createInstance` | インスタンス作成 |
| `deleteInstance` | 削除 |
| `cloneInstance` | クローン |
| `renameInstance` | リネーム |
| `moveInstance` | 別の親に移動 |
| `findInstances` | 名前/クラスで検索 |

### その他
| ツール | 説明 |
|--------|------|
| `runCode` | Luau コード実行（出力キャプチャ付き） |
| `batch` | 複数コマンド一括実行 |
| `getAttribute` / `setAttribute` | Attribute 操作 |
| `getErrors` / `clearErrors` | エラーログ管理 |
| `undo` / `redo` | 元に戻す/やり直す |
| `getSelection` | 選択取得 |
| `getStudioInfo` | Studio 情報取得 |

## 📦 インストール

### 1. クローン＆ビルド
```bash
git clone https://github.com/jundayoo/roblox-studio-ultimate-mcp.git
cd roblox-studio-ultimate-mcp
npm install
npm run build
```

### 2. Studio Plugin インストール
Plugins フォルダにコピー：

**Mac:**
```bash
cp plugin/UltimateMCP.rbxmx ~/Documents/Roblox/Plugins/
```

**Windows:**
```bash
copy plugin\UltimateMCP.rbxmx %LOCALAPPDATA%\Roblox\Plugins\
```

または生成スクリプトで：
```bash
bash generate-plugin.sh
```

### 3. Studio で HTTP 有効化
Roblox Studio のコマンドバー（表示 → コマンドバー）で：
```lua
game:GetService("HttpService").HttpEnabled = true
```

### 4. Claude Code に登録
`~/.claude.json` のプロジェクト設定に追加：
```json
{
  "mcpServers": {
    "roblox_ultimate": {
      "type": "stdio",
      "command": "node",
      "args": ["/path/to/roblox-studio-ultimate-mcp/dist/index.js"],
      "env": {}
    }
  }
}
```

### 5. 再起動
- Roblox Studio を再起動（Plugin 読み込み）
- Claude Code を再起動（MCP 接続）

## 🏗️ アーキテクチャ

```
Claude Code ←(stdio)→ MCP Server (Node.js) ←(HTTP)→ Studio Plugin (Luau)
                         ポート 3002
```

- **MCP Server** (`src/index.ts`): MCP ツール呼び出しを HTTP コマンドに変換
- **Studio Plugin** (`plugin/RobloxMCP.lua`): サーバーをポーリングし、Studio 内でコマンド実行
- 通信方式: HTTP ポーリング（300ms 間隔）

## 🔧 公式 MCP との併用

公式 Roblox Studio MCP と**併用推奨**：

| 用途 | 使う MCP |
|------|----------|
| スクリプト読み書き | **Ultimate** |
| プレイテスト | **公式**（start_stop_play） |
| コンソール確認 | **公式**（get_console_output） |
| インスタンス操作 | **Ultimate** |
| プロパティ変更 | **Ultimate** |

## 📝 実際の効果

このMCP以前は、260行スクリプトの1行修正に：
1. `run_code` でソース取得
2. `gsub` でパターンマッチ（失敗多発）
3. `run_code` で書き戻し
4. 反映されてるか確認
5. 3〜5回繰り返し

**今は：** `editScript(path, 103, 103, "新コード")` → 完了。一発。

## 📄 ライセンス

MIT
