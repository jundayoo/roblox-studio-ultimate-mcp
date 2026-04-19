#!/bin/bash
# Luaソースを.rbxmxプラグインに変換
SOURCE=$(cat plugin/RobloxMCP.lua)

cat > ~/Documents/Roblox/Plugins/UltimateMCP.rbxmx << EOF
<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">
  <Item class="Script" referent="RBX0">
    <Properties>
      <string name="Name">UltimateMCP</string>
      <ProtectedString name="Source"><![CDATA[
${SOURCE}
]]></ProtectedString>
      <bool name="Disabled">false</bool>
    </Properties>
  </Item>
</roblox>
EOF
echo "Plugin generated: ~/Documents/Roblox/Plugins/UltimateMCP.rbxmx"
