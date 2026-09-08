const { SlashCommandBuilder } = require("discord.js");

// ─── Slash Command Definition ────────────────────────────────────────────────
const obfuscateCommand = new SlashCommandBuilder()
  .setName("obf")
  .setDescription("Obfuscate Lua/LuaU code using ByteCode")
  .addAttachmentOption((opt) =>
    opt
      .setName("file")
      .setDescription("Upload a .lua file to obfuscate")
      .setRequired(false),
  )
  .addStringOption((opt) =>
    opt
      .setName("code")
      .setDescription("Or paste Lua code directly")
      .setRequired(false),
  )
  .addStringOption((opt) =>
    opt
      .setName("preset")
      .setDescription("Obfuscation preset (default: Medium)")
      .setRequired(false)
      .addChoices(
        { name: "Minify", value: "Minify" },
        { name: "Weak", value: "Weak" },
        { name: "Medium", value: "Medium" },
        { name: "Strong", value: "Strong" },
        { name: "Extreme", value: "Extreme" },
      ),
  )
  .addStringOption((opt) =>
    opt
      .setName("lua_version")
      .setDescription("Target Lua version (default: LuaU / Roblox)")
      .setRequired(false)
      .addChoices(
        { name: "Lua 5.1", value: "Lua51" },
        { name: "LuaU (Roblox)", value: "LuaU" },
      ),
  )
  .addBooleanOption((opt) =>
    opt
      .setName("pretty_print")
      .setDescription("Pretty-print the output (default: false)")
      .setRequired(false),
  )
  .addIntegerOption((opt) =>
    opt
      .setName("seed")
      .setDescription("Random seed for reproducible results")
      .setRequired(false)
      .setMinValue(1),
  );

module.exports = { obfuscateCommand };
