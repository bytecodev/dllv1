require("dotenv").config();

const {
  Client,
  GatewayIntentBits,
  REST,
  Routes,
  EmbedBuilder,
  MessageFlags,
} = require("discord.js");

const { runPrometheus, PRESETS, LUA_VERSIONS } = require("./prometheus.js");
const { obfuscateCommand } = require("./commandDefinitions.js");


// ─── Configuration ───────────────────────────────────────────────────────────
const TOKEN = process.env.DISCORD_BOT_TOKEN;
const CLIENT_ID = process.env.DISCORD_CLIENT_ID;
const GUILD_ID = process.env.DISCORD_GUILD_ID;
// Optional channel restriction for /obf
const ALLOWED_CHANNELS_OBF = process.env.DISCORD_ALLOWED_CHANNEL_ID_OBF
  ? process.env.DISCORD_ALLOWED_CHANNEL_ID_OBF.split(",").map((id) => id.trim())
  : null;


const ALLOWED_ROLES = process.env.DISCORD_ALLOWED_ROLE_ID
  ? process.env.DISCORD_ALLOWED_ROLE_ID.split(",").map((id) => id.trim())
  : null;

if (!TOKEN) {
  console.error("Missing DISCORD_BOT_TOKEN environment variable");
  process.exit(1);
}
if (!CLIENT_ID) {
  console.error("Missing DISCORD_CLIENT_ID environment variable");
  process.exit(1);
}

if (ALLOWED_CHANNELS_OBF) {
  console.log(`[/obf] Channel restriction enabled: ${ALLOWED_CHANNELS_OBF.join(", ")}`);
}

const MAX_CODE_LENGTH = 1_000_000; // 1,000,000 characters (~1 MB)
const MAX_FILE_SIZE = 5_000_000; // 5 MB


// ─── Embed Colors ────────────────────────────────────────────────────────────
const COLOR_ERROR = 0x992222;   // dark red
const COLOR_SUCCESS = 0x000000; // black

// ─── Helper: format Lua version label ───────────────────────────────────────
const LUA_VERSION_LABELS = {
  Lua51: "Lua 5.1",
  LuaU: "LuaU (Roblox)",
};

// ─── Helper: download attachment content ────────────────────────────────────
async function fetchAttachmentContent(attachment) {
  const response = await fetch(attachment.url);
  if (!response.ok) {
    throw new Error(
      `Failed to download attachment: ${response.status} ${response.statusText}`,
    );
  }
  const text = await response.text();
  return text;
}

// ─── Register Commands ──────────────────────────────────────────────────────
async function registerCommands() {
  const rest = new REST({ version: "10" }).setToken(TOKEN);

  try {
    console.log("Registering slash commands...");
    const commandData = [obfuscateCommand.toJSON()];


    if (GUILD_ID) {
      // Guild commands = instant
      await rest.put(
        Routes.applicationGuildCommands(CLIENT_ID, GUILD_ID),
        { body: commandData },
      );
      console.log(`Slash commands registered to guild ${GUILD_ID}!`);
    } else {
      // Global commands = may take up to 1 hour
      await rest.put(Routes.applicationCommands(CLIENT_ID), {
        body: commandData,
      });
      console.log("Global slash commands registered (may take up to 1 hour)!");
    }
  } catch (error) {
    console.error("Failed to register commands:", error);
    process.exit(1);
  }
}

// ─── Bot Client ──────────────────────────────────────────────────────────────
const client = new Client({
  intents: [GatewayIntentBits.Guilds],
});

client.once("clientReady", () => {
  console.log(`Logged in as ${client.user?.tag}!`);

  if (!GUILD_ID) {
    console.log(
      "Tip: Set DISCORD_GUILD_ID in .env for instant command registration.",
    );
  }

  console.log(
    `Invite URL: https://discord.com/oauth2/authorize?client_id=${CLIENT_ID}&scope=bot+applications.commands`,
  );
});

const LV = (v) => LUA_VERSION_LABELS[v] || v;

client.on("interactionCreate", async (interaction) => {
  try {
    if (!interaction.isChatInputCommand()) return;

    // ─── /obf — Obfuscation ──────────────────────────────────────────────────
    if (interaction.commandName !== "obf") return;


    // ── Channel restriction ────────────────────────────────────────────────────
    if (ALLOWED_CHANNELS_OBF && !ALLOWED_CHANNELS_OBF.includes(interaction.channelId)) {
      return interaction.reply({
        content: "This command can only be used in designated channels.",
        flags: MessageFlags.Ephemeral,
      });
    }

    // ── Role restriction ───────────────────────────────────────────────────────
    if (ALLOWED_ROLES) {
      const memberRoles = interaction.member?.roles?.cache;
      const hasRole = ALLOWED_ROLES.some((roleId) => memberRoles?.has(roleId));
      if (!hasRole) {
        return interaction.reply({
          content: "You do not have the required role to use this command.",
          flags: MessageFlags.Ephemeral,
        });
      }
    }

    console.log(`[${new Date().toISOString()}] /obf received from ${interaction.user.tag}`);

    try {
      await interaction.deferReply();
    } catch {
      return;
    }

    // ── Read input: file attachment or code string ────────────────────────────
    const attachment = interaction.options.getAttachment("file");
    const rawCode = interaction.options.getString("code");

    let code;
    let sourceName = "input.lua";

    if (attachment) {
      if (attachment.size > MAX_FILE_SIZE) {
        const embed = new EmbedBuilder()
          .setColor(COLOR_ERROR)
          .setTitle("File Too Large")
          .setDescription(
            `Maximum file size is ${(MAX_FILE_SIZE / 1_000_000).toFixed(0)} MB. "${attachment.name}" is ${(attachment.size / 1000).toFixed(0)} KB.`,
          );
        return interaction.editReply({ embeds: [embed] });
      }

      try {
        code = await fetchAttachmentContent(attachment);
      } catch (err) {
        const embed = new EmbedBuilder()
          .setColor(COLOR_ERROR)
          .setTitle("Failed to Read File")
          .setDescription(`\`\`\`\n${err.message}\n\`\`\``);
        return interaction.editReply({ embeds: [embed] });
      }

      sourceName = attachment.name;
    } else if (rawCode) {
      code = rawCode;
    } else {
      const embed = new EmbedBuilder()
        .setColor(COLOR_ERROR)
        .setTitle("Input Required")
        .setDescription(
          "Upload a **.lua** file using the `file` option, or paste code directly into the `code` option.",
        );
      return interaction.editReply({ embeds: [embed] });
    }

    const preset = interaction.options.getString("preset") ?? "Medium";
    const luaVersion = interaction.options.getString("lua_version") ?? "Lua51";
    const prettyPrint = interaction.options.getBoolean("pretty_print") ?? false;
    const seed =
      interaction.options.getInteger("seed") ??
      Math.floor(Math.random() * 999999) + 1;

    if (!PRESETS.includes(preset)) {
      return interaction.editReply({
        embeds: [
          new EmbedBuilder()
            .setColor(COLOR_ERROR)
            .setTitle("Invalid Preset")
            .setDescription(`Valid presets: ${PRESETS.join(", ")}`),
        ],
      });
    }
    if (!LUA_VERSIONS.includes(luaVersion)) {
      return interaction.editReply({
        embeds: [
          new EmbedBuilder()
            .setColor(COLOR_ERROR)
            .setTitle("Invalid Lua Version")
            .setDescription(`Valid versions: ${LUA_VERSIONS.join(", ")}`),
        ],
      });
    }

    if (code.length > MAX_CODE_LENGTH) {
      const embed = new EmbedBuilder()
        .setColor(COLOR_ERROR)
        .setTitle("Code Too Long")
        .setDescription(
          `Maximum code length is ${MAX_CODE_LENGTH.toLocaleString()} characters. Yours is ${code.length.toLocaleString()}.`,
        );
      return interaction.editReply({ embeds: [embed] });
    }

    // ── Obfuscate with timeout ────────────────────────────────────────────────
    const TIMEOUT_MS = 120_000; // 2 menit
    let result;

    try {
      result = await Promise.race([
        runPrometheus({
          source: code,
          filename: sourceName,
          preset,
          luaVersion,
          prettyPrint,
          seed,
        }),
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error("Obfuscation timed out after 2 minutes")), TIMEOUT_MS),
        ),
      ]);
    } catch (err) {
      console.error("Obfuscation error:", err);
      const embed = new EmbedBuilder()
        .setColor(COLOR_ERROR)
        .setTitle("Obfuscation Error")
        .setDescription(`\`\`\`\n${String(err.message || err).slice(0, 4000)}\n\`\`\``);
      return interaction.editReply({ embeds: [embed] });
    }

    if (!result.ok) {
      const errorLogs = result.logs
        .filter((l) => l.level === "error")
        .map((l) => l.message)
        .join("\n");

      const embed = new EmbedBuilder()
        .setColor(COLOR_ERROR)
        .setTitle("Obfuscation Failed")
        .setDescription(
          `\`\`\`\n${(errorLogs || result.error).slice(0, 4000)}\n\`\`\``,
        )
        .setFooter({ text: `Preset: ${preset}  |  Lua: ${LV(luaVersion)}` });

      return interaction.editReply({ embeds: [embed] });
    }

    const output = result.output;
    const ratio = ((output.length / code.length) * 100).toFixed(1);
    const outputBuffer = Buffer.from(output, "utf-8");
    const outputName = "bytecode.lua";

    const embed = new EmbedBuilder()
      .setColor(COLOR_SUCCESS)
      .setTitle("Obfuscation Complete")
      .setDescription(
        `**${sourceName}** obfuscated with preset **${preset}**`,
      )
      .addFields(
        { name: "Preset", value: preset, inline: true },
        { name: "Lua Version", value: LV(luaVersion), inline: true },
        { name: "Seed", value: String(seed), inline: true },
        { name: "Size Ratio", value: `${ratio}%`, inline: true },
        { name: "Output", value: `${(output.length / 1000).toFixed(1)} KB`, inline: true },
      )
      .setFooter({ text: "ByteCode Obfuscator" });

    return interaction.editReply({
      embeds: [embed],
      files: [{ attachment: outputBuffer, name: outputName }],
    });
  } catch (error) {
    console.error("Interaction error:", error);
    if (error instanceof Error) {
      console.error("Error stack:", error.stack);
    }
    try {
      const embed = new EmbedBuilder()
        .setColor(COLOR_ERROR)
        .setTitle("Internal Error")
        .setDescription(`\`\`\`\n${String(error).slice(0, 4000)}\n\`\`\``);
      await interaction.editReply({ embeds: [embed] });
    } catch (replyErr) {
      console.error("Failed to send error embed:", replyErr);
      // nothing to do
    }
  }
});


// ─── Web Server Keep-Alive (For Render / Web Service compatibility) ──────────
const http = require("http");
const PORT = process.env.PORT || 3000;
http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("Bot is online!");
}).listen(PORT, () => {
  console.log(`HTTP health check server listening on port ${PORT}`);
});

// ─── Start ───────────────────────────────────────────────────────────────────
async function main() {
  await registerCommands();
  await client.login(TOKEN);
}

main().catch(console.error);

