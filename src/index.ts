import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import express from "express";
import cors from "cors";
import { randomUUID } from "crypto";
import { execFile } from "child_process";
import { readFile, unlink } from "fs/promises";
import { tmpdir } from "os";
import { join } from "path";

const PROTOCOL_VERSION = 2;
const SERVER_VERSION = "4.0.0";

// ===== Studio Plugin との通信用 Express サーバー =====
const app = express();
app.use(cors({ origin: false })); // 外部ブラウザからのアクセスは許可しない
app.use(express.json({ limit: "50mb" }));

// ===== コマンドキュー（id 相関） =====
interface PendingCommand {
  id: string;
  command: string;
  params: any;
  resolve: (r: any) => void;
  reject: (e: any) => void;
  timeoutHandle: NodeJS.Timeout;
}

const commandQueue: PendingCommand[] = []; // 未送信のキュー
const inflight: Map<string, PendingCommand> = new Map(); // 送信済で待機中

// Plugin がポーリングしてコマンドを取得
app.get("/poll", (req, res) => {
  const next = commandQueue.shift();
  if (next) {
    inflight.set(next.id, next);
    res.json({ id: next.id, command: next.command, params: next.params });
  } else {
    res.json({});
  }
});

// Plugin が結果を返す
app.post("/result", (req, res) => {
  const { id, result } = req.body || {};
  if (!id) {
    res.status(400).json({ error: "missing id" });
    return;
  }
  const cmd = inflight.get(id);
  if (cmd) {
    clearTimeout(cmd.timeoutHandle);
    inflight.delete(id);
    cmd.resolve(result);
    res.json({ ok: true });
  } else {
    // 未知 or タイムアウト済み id
    res.status(404).json({ error: "unknown or expired id" });
  }
});

function sendCommand(command: string, params: any = {}): Promise<any> {
  return new Promise((resolve, reject) => {
    const id = randomUUID();
    const timeoutHandle = setTimeout(() => {
      // キューにあるなら除去、inflight なら除去
      const qIdx = commandQueue.findIndex((c) => c.id === id);
      if (qIdx >= 0) commandQueue.splice(qIdx, 1);
      inflight.delete(id);
      reject(new Error(`Command timed out: ${command}`));
    }, 30000);

    commandQueue.push({
      id,
      command,
      params,
      resolve,
      reject,
      timeoutHandle,
    });
  });
}

// 起動（localhost のみ）
const PORT = 3002;
const HOST = "127.0.0.1";
const httpServer = app.listen(PORT, HOST, () => {
  console.error(`[MCP Bridge] Listening on ${HOST}:${PORT} (v${SERVER_VERSION})`);
});
httpServer.on("error", (e) => {
  console.error(`[MCP Bridge] Listen failed: ${e.message}`);
  process.exit(1);
});

// 終了時クリーンアップ
const shutdown = (signal: string) => () => {
  console.error(`[MCP Bridge] Received ${signal}, shutting down`);
  httpServer.close();
  process.exit(0);
};
process.on("SIGINT", shutdown("SIGINT"));
process.on("SIGTERM", shutdown("SIGTERM"));

// ===== MCP Server =====
const server = new McpServer({
  name: "roblox-studio-ultimate",
  version: SERVER_VERSION,
});

// ツール登録ヘルパー
function registerTool(
  name: string,
  description: string,
  schema: any
) {
  server.tool(name, description, schema, (async (params: any) => {
    const result = await sendCommand(name, params);
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }) as any);
}

// ----- スクリプト操作 -----

registerTool("getScript", "スクリプトのソースコード全文を取得", {
  path: z.string().describe("スクリプトのパス (例: game.ServerScriptService.MyScript)"),
});

registerTool("setScript", "スクリプトを丸ごと書き換え（構文チェック＋自動バックアップ付き）", {
  path: z.string().describe("スクリプトのパス"),
  source: z.string().describe("新しいソースコード全文"),
  skipSyntaxCheck: z.boolean().optional().describe("構文チェックをスキップ"),
});

registerTool("editScript", "スクリプトの特定行を差分編集", {
  path: z.string().describe("スクリプトのパス"),
  startLine: z.number().describe("開始行番号"),
  endLine: z.number().describe("終了行番号"),
  newCode: z.string().describe("新しいコード"),
  skipSyntaxCheck: z.boolean().optional().describe("構文チェックをスキップ"),
});

registerTool("checkSyntax", "Luauコードの構文チェック（書き込みなし）", {
  source: z.string().describe("チェックするソースコード"),
});

registerTool("listScripts", "全スクリプトの一覧を取得", {});

registerTool("getAllScripts", "全スクリプトのソースを一括取得", {});

registerTool("searchInScripts", "全スクリプト内をキーワード検索", {
  query: z.string().describe("検索キーワード"),
});

// ----- バックアップ -----

registerTool("restoreBackup", "スクリプトをバックアップから復元", {
  path: z.string().describe("スクリプトのパス"),
  index: z.number().optional().describe("バックアップのインデックス（省略で最新）"),
});

registerTool("listBackups", "スクリプトのバックアップ一覧", {
  path: z.string().describe("スクリプトのパス"),
});

// ----- エラーログ -----

registerTool("getErrors", "直近のエラーログを取得", {
  count: z.number().optional().describe("取得件数（省略で全件）"),
});

registerTool("clearErrors", "エラーログをクリア", {});

// ----- インスタンス操作 -----

registerTool("getTree", "インスタンスツリーを取得", {
  path: z.string().optional().describe("ルートパス (省略でgame全体)"),
  depth: z.number().optional().describe("探索深度（省略で2）"),
});

registerTool("getProperty", "インスタンスのプロパティを取得", {
  path: z.string().describe("インスタンスのパス"),
  property: z.string().describe("プロパティ名"),
});

registerTool("setProperty", "インスタンスのプロパティを設定", {
  path: z.string().describe("インスタンスのパス"),
  property: z.string().describe("プロパティ名"),
  value: z.string().describe("値（カンマ区切り可、中括弧OK）"),
  valueType: z.string().optional().describe("型 (string/number/boolean/Vector3/Vector2/Color3/CFrame/UDim2/UDim/NumberRange/Enum)"),
});

registerTool("setProperties", "複数プロパティを一括設定", {
  path: z.string().describe("インスタンスのパス"),
  properties: z.record(z.string(), z.any()).describe("プロパティ名→値のマップ"),
});

registerTool("createInstance", "新しいインスタンスを作成", {
  className: z.string().describe("クラス名 (Part, Script, etc)"),
  parent: z.string().describe("親のパス"),
  name: z.string().optional().describe("名前"),
  properties: z.record(z.string(), z.any()).optional().describe("初期プロパティ"),
});

registerTool("deleteInstance", "インスタンスを削除（保護サービスは拒否）", {
  path: z.string().describe("削除するインスタンスのパス"),
});

registerTool("cloneInstance", "インスタンスをクローン", {
  path: z.string().describe("クローン元のパス"),
  newParent: z.string().optional().describe("クローン先の親パス"),
  newName: z.string().optional().describe("新しい名前"),
});

registerTool("findInstances", "インスタンスを検索", {
  name: z.string().optional().describe("名前で検索"),
  className: z.string().optional().describe("クラス名で検索"),
  root: z.string().optional().describe("検索ルート"),
});

// ----- v3+ 機能 -----

registerTool("getFunctionList", "スクリプト内の全関数名と行番号を取得", {
  path: z.string().describe("スクリプトのパス"),
});

registerTool("getLines", "スクリプトの特定行範囲だけ取得", {
  path: z.string().describe("スクリプトのパス"),
  startLine: z.number().describe("開始行"),
  endLine: z.number().describe("終了行"),
});

registerTool("insertCode", "指定行の後にコードを挿入", {
  path: z.string().describe("スクリプトのパス"),
  afterLine: z.number().describe("この行の後に挿入"),
  code: z.string().describe("挿入するコード"),
});

registerTool("removeLines", "指定行を削除", {
  path: z.string().describe("スクリプトのパス"),
  startLine: z.number().describe("開始行"),
  endLine: z.number().describe("終了行"),
});

registerTool("replaceInScript", "スクリプト内の文字列を置換", {
  path: z.string().describe("スクリプトのパス"),
  oldText: z.string().describe("置換前の文字列"),
  newText: z.string().describe("置換後の文字列"),
  replaceAll: z.boolean().optional().describe("全箇所置換"),
  skipSyntaxCheck: z.boolean().optional().describe("構文チェックスキップ"),
});

registerTool("verifyScript", "スクリプトの行数/長さを確認", {
  path: z.string().describe("スクリプトのパス"),
});

registerTool("validateAllScripts", "全スクリプトの構文チェック", {});

registerTool("getModuleDependencies", "スクリプトのrequire依存一覧", {
  path: z.string().describe("スクリプトのパス"),
});

registerTool("getReferences", "全スクリプトから変数/関数の使用箇所を検索", {
  query: z.string().describe("検索する変数名や関数名"),
});

registerTool("getScriptSummary", "スクリプトの概要（関数/require/グローバル変数一覧）", {
  path: z.string().describe("スクリプトのパス"),
});

registerTool("renameInstance", "インスタンスをリネーム", {
  path: z.string().describe("インスタンスのパス"),
  newName: z.string().describe("新しい名前"),
});

registerTool("moveInstance", "インスタンスを別の親に移動", {
  path: z.string().describe("インスタンスのパス"),
  newParent: z.string().describe("新しい親のパス"),
});

registerTool("getChildren", "子要素の一覧を軽量取得", {
  path: z.string().optional().describe("親のパス（省略でgame）"),
});

// ----- バッチ処理 -----

registerTool("batch", "複数コマンドを一括実行（per-command pcall）", {
  commands: z
    .array(
      z.object({
        command: z.string(),
        params: z.any().optional(),
      })
    )
    .describe("コマンド配列 [{command, params}, ...]"),
});

// ----- コード実行 -----

registerTool("runCode", "Luauコードを実行（print/warn 出力キャプチャ）", {
  code: z.string().describe("実行するLuauコード"),
});

// ----- Attribute操作 -----

registerTool("getAttribute", "Attributeを取得", {
  path: z.string().describe("インスタンスのパス"),
  attribute: z.string().describe("Attribute名"),
});

registerTool("setAttribute", "Attributeを設定", {
  path: z.string().describe("インスタンスのパス"),
  attribute: z.string().describe("Attribute名"),
  value: z.any().describe("値"),
});

// ----- Studio制御 -----

registerTool("undo", "操作を元に戻す", {});
registerTool("redo", "操作をやり直す", {});
registerTool("getSelection", "現在選択中のインスタンスを取得", {});
registerTool("setSelection", "選択を設定", {
  paths: z.array(z.string()).describe("選択するパスの配列"),
});
registerTool("getStudioInfo", "Studio情報を取得（mode/version等）", {});

// ----- v4.1 Phase1 機能 -----

registerTool("getOutput", "Studioの出力ログ（print/warn/error、Play中含む）を取得", {
  count: z.number().optional().describe("取得件数（省略で200）"),
  levelFilter: z.string().optional().describe("フィルタ (error/warn/info/output)"),
  sinceTime: z.number().optional().describe("この時刻以降（os.time()基準）"),
  onlyPlay: z.boolean().optional().describe("Play中のログのみ"),
});

registerTool("watchAttribute", "Attribute取得（Play中フラグ付き）", {
  path: z.string().describe("インスタンスのパス"),
  attribute: z.string().describe("Attribute名"),
});

// Screenshot は Node 側で実行（macOS screencapture）
server.tool(
  "captureScreen",
  "macOSスクリーンショット取得（フルスクリーン or アクティブウィンドウ）",
  {
    mode: z.enum(["full", "interactive", "window"]).optional().describe("full=画面全体、interactive=範囲選択、window=アクティブウィンドウ"),
  },
  (async ({ mode }: { mode?: string }) => {
    const m = mode || "full";
    const tmpPath = join(tmpdir(), `roblox-mcp-${randomUUID()}.png`);

    const args: string[] = ["-x"];
    if (m === "interactive") args.push("-i");
    else if (m === "window") args.push("-w");
    args.push(tmpPath);

    try {
      await new Promise<void>((resolve, reject) => {
        execFile("screencapture", args, (err) => (err ? reject(err) : resolve()));
      });
      const buf = await readFile(tmpPath);
      await unlink(tmpPath).catch(() => {});
      const base64 = buf.toString("base64");
      return {
        content: [
          { type: "image" as const, data: base64, mimeType: "image/png" },
        ],
      };
    } catch (e: any) {
      return {
        content: [{ type: "text" as const, text: `Error: ${e.message}` }],
      };
    }
  }) as any
);

// ===== 起動 =====
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`[MCP Server v${SERVER_VERSION}] Roblox Studio Ultimate MCP started!`);
}

main().catch(console.error);
