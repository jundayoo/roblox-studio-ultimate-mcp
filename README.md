# 🎮 Roblox Studio Ultimate MCP Server

**English** | [日本語](README.ja.md)

The most comprehensive MCP (Model Context Protocol) server for Roblox Studio. **41 tools** for complete Studio control from Claude Code or any MCP-compatible AI assistant.

## ✨ Why This Exists

The default Roblox Studio MCP only provides `run_code` — forcing you to manipulate script sources via string operations (`gsub`). This leads to:
- ❌ Pattern matching failures
- ❌ Broken `end)` statements  
- ❌ Silent rollbacks when scripts revert
- ❌ No syntax checking before writes
- ❌ Hours wasted on simple edits

**This MCP solves all of that.**

## 🚀 Features

### Script Operations (The Game Changer)
| Tool | Description |
|------|-------------|
| `getScript` | Get full source code |
| `setScript` | Replace entire source (with syntax check + auto backup) |
| `editScript` | Edit specific line range (partial edit!) |
| `insertCode` | Insert code after a specific line |
| `removeLines` | Remove specific lines |
| `replaceInScript` | Find & replace text (plain text, safe) |
| `getLines` | Get only specific line range (lightweight) |
| `getFunctionList` | List all functions with line numbers |
| `getScriptSummary` | Overview: functions, requires, globals |
| `listScripts` | List all scripts in the game |
| `getAllScripts` | Get all script sources at once |
| `searchInScripts` | Search keyword across all scripts |
| `getReferences` | Find all usages of a variable/function |
| `getModuleDependencies` | List require() dependencies |

### Safety Mechanisms
| Feature | Description |
|---------|-------------|
| 🔒 **Syntax Check** | Auto-validates before writing. Rejects bad code. |
| 💾 **Auto Backup** | Saves previous version before every edit (10 generations) |
| 🛑 **Play Mode Guard** | Blocks writes during Play mode (prevents silent rollbacks) |
| 📝 **UpdateSourceAsync** | Uses ScriptEditorService for conflict-free writes |

### Backup & Restore
| Tool | Description |
|------|-------------|
| `restoreBackup` | Restore from auto-saved backup |
| `listBackups` | List available backups |

### Validation
| Tool | Description |
|------|-------------|
| `checkSyntax` | Check syntax without writing |
| `verifyScript` | Verify line count / source length |
| `validateAllScripts` | Batch syntax check all scripts |

### Instance Operations
| Tool | Description |
|------|-------------|
| `getTree` | Get instance hierarchy |
| `getChildren` | List children (lightweight) |
| `getProperty` / `setProperty` | Get/set properties |
| `createInstance` | Create new instance |
| `deleteInstance` | Delete instance |
| `cloneInstance` | Clone instance |
| `renameInstance` | Rename instance |
| `moveInstance` | Move to different parent |
| `findInstances` | Search instances by name/class |

### Other
| Tool | Description |
|------|-------------|
| `runCode` | Execute Luau code (with output capture) |
| `batch` | Execute multiple commands at once |
| `getAttribute` / `setAttribute` | Attribute operations |
| `getErrors` / `clearErrors` | Error log management |
| `undo` / `redo` | Undo/redo operations |
| `getSelection` | Get current selection |
| `getStudioInfo` | Get Studio info |

## 📦 Installation

### 1. Clone & Build
```bash
git clone https://github.com/YOUR_USERNAME/roblox-studio-ultimate-mcp.git
cd roblox-studio-ultimate-mcp
npm install
npm run build
```

### 2. Install Studio Plugin
Copy the plugin file to your Roblox Plugins folder:

**Mac:**
```bash
cp plugin/UltimateMCP.rbxmx ~/Documents/Roblox/Plugins/
```

**Windows:**
```bash
copy plugin\UltimateMCP.rbxmx %LOCALAPPDATA%\Roblox\Plugins\
```

Or generate it from source:
```bash
bash generate-plugin.sh
```

### 3. Enable HTTP in Studio
Open Roblox Studio, then in the Command Bar (View → Command Bar):
```lua
game:GetService("HttpService").HttpEnabled = true
```

### 4. Register with Claude Code
Add to your `~/.claude.json` under the appropriate project:
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

### 5. Restart
- Restart Roblox Studio (to load the plugin)
- Restart Claude Code (to connect to the MCP)

## 🏗️ Architecture

```
Claude Code ←(stdio)→ MCP Server (Node.js) ←(HTTP)→ Studio Plugin (Luau)
                         Port 3002
```

- **MCP Server** (`src/index.ts`): Translates MCP tool calls to HTTP commands
- **Studio Plugin** (`plugin/RobloxMCP.lua`): Polls the server, executes commands inside Studio
- Communication: HTTP polling (300ms interval)

## 🔧 Usage with Other MCP Servers

This server is designed to work **alongside** the official Roblox Studio MCP:

| Use Case | Which MCP |
|----------|-----------|
| Script read/write | **Ultimate** (getScript/setScript) |
| Play testing | **Official** (start_stop_play) |
| Console output | **Official** (get_console_output) |
| Instance manipulation | **Ultimate** |
| Property changes | **Ultimate** |

## 📝 Real-World Impact

Before this MCP, a simple one-line fix in a 260-line script required:
1. `run_code` to get the source
2. `gsub` pattern matching (often fails)
3. `run_code` to write back
4. Pray it worked
5. Repeat 3-5 times

**Now:** `editScript(path, 103, 103, "new code")` → Done. First try.

## 🤝 Contributing

PRs welcome! Especially for:
- New tools
- Better error handling
- Performance improvements
- Documentation

## 📄 License

MIT
