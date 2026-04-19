import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import express from "express";
import cors from "cors";

// ===== Studio Plugin との通信用 Express サーバー =====
const app = express();
app.use(cors());
app.use(express.json({ limit: "50mb" }));

let pendingCommand: { id: string; command: string; params: any } | null = null;
let pendingResolve: ((result: any) => void) | null = null;
let commandId = 0;

app.get("/poll", (req, res) => {
  if (pendingCommand) {
    res.json(pendingCommand);
    pendingCommand = null;
  } else {
    res.json({});
  }
});

app.post("/result", (req, res) => {
  if (pendingResolve) {
    pendingResolve(req.body.result);
    pendingResolve = null;
  }
  res.json({ ok: true });
});

function sendCommand(command: string, params: any = {}): Promise<any> {
  return new Promise((resolve, reject) => {
    const id = String(++commandId);
    pendingCommand = { id, command, params };
    pendingResolve = resolve;
    setTimeout(() => {
      if (pendingResolve === resolve) {
        pendingResolve = null;
        pendingCommand = null;
        reject(new Error("Command timed out: " + command));
      }
    }, 30000);
  });
}

const PORT = 3002;
app.listen(PORT, () => {
  console.error(`[MCP Bridge] Listening on port ${PORT}`);
});

// ===== MCP Server =====
const server = new McpServer({
  name: "roblox-studio-ultimate",
  version: "2.0.0",
});

// ----- スクリプト操作 -----

server.tool("getScript", "スクリプトのソースコード全文を取得", {
  path: z.string().describe("スクリプトのパス (例: game.ServerScriptService.MyScript)"),
}, async ({ path }) => {
  const result = await sendCommand("getScript", { path });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("setScript", "スクリプトを丸ごと書き換え（構文チェック＋自動バックアップ付き）", {
  path: z.string().describe("スクリプトのパス"),
  source: z.string().describe("新しいソースコード全文"),
  skipSyntaxCheck: z.boolean().optional().describe("構文チェックをスキップ"),
}, async ({ path, source, skipSyntaxCheck }) => {
  const result = await sendCommand("setScript", { path, source, skipSyntaxCheck });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("editScript", "スクリプトの特定行を差分編集", {
  path: z.string().describe("スクリプトのパス"),
  startLine: z.number().describe("開始行番号"),
  endLine: z.number().describe("終了行番号"),
  newCode: z.string().describe("新しいコード"),
  skipSyntaxCheck: z.boolean().optional().describe("構文チェックをスキップ"),
}, async ({ path, startLine, endLine, newCode, skipSyntaxCheck }) => {
  const result = await sendCommand("editScript", { path, startLine, endLine, newCode, skipSyntaxCheck });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("checkSyntax", "Luauコードの構文チェック（書き込みなし）", {
  source: z.string().describe("チェックするソースコード"),
}, async ({ source }) => {
  const result = await sendCommand("checkSyntax", { source });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("listScripts", "全スクリプトの一覧を取得", {}, async () => {
  const result = await sendCommand("listScripts");
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("getAllScripts", "全スクリプトのソースを一括取得", {}, async () => {
  const result = await sendCommand("getAllScripts");
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("searchInScripts", "全スクリプト内をキーワード検索", {
  query: z.string().describe("検索キーワード"),
}, async ({ query }) => {
  const result = await sendCommand("searchInScripts", { query });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

// ----- バックアップ -----

server.tool("restoreBackup", "スクリプトをバックアップから復元", {
  path: z.string().describe("スクリプトのパス"),
  index: z.number().optional().describe("バックアップのインデックス（省略で最新）"),
}, async ({ path, index }) => {
  const result = await sendCommand("restoreBackup", { path, index });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("listBackups", "スクリプトのバックアップ一覧", {
  path: z.string().describe("スクリプトのパス"),
}, async ({ path }) => {
  const result = await sendCommand("listBackups", { path });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

// ----- エラーログ -----

server.tool("getErrors", "直近のエラーログを取得", {
  count: z.number().optional().describe("取得件数（省略で全件）"),
}, async ({ count }) => {
  const result = await sendCommand("getErrors", { count });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("clearErrors", "エラーログをクリア", {}, async () => {
  const result = await sendCommand("clearErrors");
  return { content: [{ type: "text", text: JSON.stringify(result) }] };
});

// ----- インスタンス操作 -----

server.tool("getTree", "インスタンスツリーを取得", {
  path: z.string().optional().describe("ルートパス (省略でgame全体)"),
  depth: z.number().optional().describe("探索深度（省略で2）"),
}, async ({ path, depth }) => {
  const result = await sendCommand("getTree", { path, depth });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("getProperty", "インスタンスのプロパティを取得", {
  path: z.string().describe("インスタンスのパス"),
  property: z.string().describe("プロパティ名"),
}, async ({ path, property }) => {
  const result = await sendCommand("getProperty", { path, property });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("setProperty", "インスタンスのプロパティを設定", {
  path: z.string().describe("インスタンスのパス"),
  property: z.string().describe("プロパティ名"),
  value: z.string().describe("値"),
  valueType: z.string().optional().describe("型 (string/number/boolean/Vector3/Color3/CFrame/UDim2/Enum)"),
}, async ({ path, property, value, valueType }) => {
  const result = await sendCommand("setProperty", { path, property, value, valueType });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("createInstance", "新しいインスタンスを作成", {
  className: z.string().describe("クラス名 (Part, Script, etc)"),
  parent: z.string().describe("親のパス"),
  name: z.string().optional().describe("名前"),
}, async ({ className, parent, name }) => {
  const result = await sendCommand("createInstance", { className, parent, name });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("deleteInstance", "インスタンスを削除", {
  path: z.string().describe("削除するインスタンスのパス"),
}, async ({ path }) => {
  const result = await sendCommand("deleteInstance", { path });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("cloneInstance", "インスタンスをクローン", {
  path: z.string().describe("クローン元のパス"),
  newParent: z.string().optional().describe("クローン先の親パス"),
  newName: z.string().optional().describe("新しい名前"),
}, async ({ path, newParent, newName }) => {
  const result = await sendCommand("cloneInstance", { path, newParent, newName });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("findInstances", "インスタンスを検索", {
  name: z.string().optional().describe("名前で検索"),
  className: z.string().optional().describe("クラス名で検索"),
  root: z.string().optional().describe("検索ルート"),
}, async ({ name, className, root }) => {
  const result = await sendCommand("findInstances", { name, className, root });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

// ----- 新機能 v3 -----

server.tool("getFunctionList", "スクリプト内の全関数名と行番号を取得", {
  path: z.string().describe("スクリプトのパス"),
}, async ({ path }) => {
  const result = await sendCommand("getFunctionList", { path });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("getLines", "スクリプトの特定行範囲だけ取得", {
  path: z.string().describe("スクリプトのパス"),
  startLine: z.number().describe("開始行"),
  endLine: z.number().describe("終了行"),
}, async ({ path, startLine, endLine }) => {
  const result = await sendCommand("getLines", { path, startLine, endLine });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("insertCode", "指定行の後にコードを挿入", {
  path: z.string().describe("スクリプトのパス"),
  afterLine: z.number().describe("この行の後に挿入"),
  code: z.string().describe("挿入するコード"),
}, async ({ path, afterLine, code }) => {
  const result = await sendCommand("insertCode", { path, afterLine, code });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("removeLines", "指定行を削除", {
  path: z.string().describe("スクリプトのパス"),
  startLine: z.number().describe("開始行"),
  endLine: z.number().describe("終了行"),
}, async ({ path, startLine, endLine }) => {
  const result = await sendCommand("removeLines", { path, startLine, endLine });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("replaceInScript", "スクリプト内の文字列を置換", {
  path: z.string().describe("スクリプトのパス"),
  oldText: z.string().describe("置換前の文字列"),
  newText: z.string().describe("置換後の文字列"),
  replaceAll: z.boolean().optional().describe("全箇所置換"),
  skipSyntaxCheck: z.boolean().optional().describe("構文チェックスキップ"),
}, async ({ path, oldText, newText, replaceAll, skipSyntaxCheck }) => {
  const result = await sendCommand("replaceInScript", { path, oldText, newText, replaceAll, skipSyntaxCheck });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("verifyScript", "スクリプトの行数/長さを確認", {
  path: z.string().describe("スクリプトのパス"),
}, async ({ path }) => {
  const result = await sendCommand("verifyScript", { path });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("validateAllScripts", "全スクリプトの構文チェック", {}, async () => {
  const result = await sendCommand("validateAllScripts");
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("getModuleDependencies", "スクリプトのrequire依存一覧", {
  path: z.string().describe("スクリプトのパス"),
}, async ({ path }) => {
  const result = await sendCommand("getModuleDependencies", { path });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("getReferences", "全スクリプトから変数/関数の使用箇所を検索", {
  query: z.string().describe("検索する変数名や関数名"),
}, async ({ query }) => {
  const result = await sendCommand("getReferences", { query });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("getScriptSummary", "スクリプトの概要（関数/require/グローバル変数一覧）", {
  path: z.string().describe("スクリプトのパス"),
}, async ({ path }) => {
  const result = await sendCommand("getScriptSummary", { path });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("renameInstance", "インスタンスをリネーム", {
  path: z.string().describe("インスタンスのパス"),
  newName: z.string().describe("新しい名前"),
}, async ({ path, newName }) => {
  const result = await sendCommand("renameInstance", { path, newName });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("moveInstance", "インスタンスを別の親に移動", {
  path: z.string().describe("インスタンスのパス"),
  newParent: z.string().describe("新しい親のパス"),
}, async ({ path, newParent }) => {
  const result = await sendCommand("moveInstance", { path, newParent });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("getChildren", "子要素の一覧を軽量取得", {
  path: z.string().optional().describe("親のパス（省略でgame）"),
}, async ({ path }) => {
  const result = await sendCommand("getChildren", { path });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

// ----- バッチ処理 -----

server.tool("batch", "複数コマンドを一括実行", {
  commands: z.array(z.object({
    command: z.string(),
    params: z.any().optional(),
  })).describe("コマンド配列 [{command, params}, ...]"),
}, async ({ commands }) => {
  const result = await sendCommand("batch", { commands });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

// ----- コード実行 -----

server.tool("runCode", "Luauコードを実行", {
  code: z.string().describe("実行するLuauコード"),
}, async ({ code }) => {
  const result = await sendCommand("runCode", { code });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

// ----- Attribute操作 -----

server.tool("getAttribute", "Attributeを取得", {
  path: z.string().describe("インスタンスのパス"),
  attribute: z.string().describe("Attribute名"),
}, async ({ path, attribute }) => {
  const result = await sendCommand("getAttribute", { path, attribute });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("setAttribute", "Attributeを設定", {
  path: z.string().describe("インスタンスのパス"),
  attribute: z.string().describe("Attribute名"),
  value: z.any().describe("値"),
}, async ({ path, attribute, value }) => {
  const result = await sendCommand("setAttribute", { path, attribute, value });
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

// ----- Studio制御 -----

server.tool("undo", "操作を元に戻す", {}, async () => {
  const result = await sendCommand("undo");
  return { content: [{ type: "text", text: JSON.stringify(result) }] };
});

server.tool("redo", "操作をやり直す", {}, async () => {
  const result = await sendCommand("redo");
  return { content: [{ type: "text", text: JSON.stringify(result) }] };
});

server.tool("getSelection", "現在選択中のインスタンスを取得", {}, async () => {
  const result = await sendCommand("getSelection");
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

server.tool("getStudioInfo", "Studio情報を取得", {}, async () => {
  const result = await sendCommand("getStudioInfo");
  return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
});

// ===== 起動 =====
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("[MCP Server v2] Roblox Studio Ultimate MCP started!");
}

main().catch(console.error);
