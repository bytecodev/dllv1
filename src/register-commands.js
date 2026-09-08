require("dotenv").config();

const { REST, Routes } = require("discord.js");
const { obfuscateCommand } = require("./commandDefinitions.js");

const TOKEN = process.env.DISCORD_BOT_TOKEN;
const CLIENT_ID = process.env.DISCORD_CLIENT_ID;
const GUILD_ID = process.env.DISCORD_GUILD_ID;

if (!TOKEN) {
  console.error("Missing DISCORD_BOT_TOKEN environment variable");
  process.exit(1);
}
if (!CLIENT_ID) {
  console.error("Missing DISCORD_CLIENT_ID environment variable");
  process.exit(1);
}

// Script berdiri sendiri untuk register/re-register slash command secara manual,
// tanpa perlu restart proses bot utama (index.js). Jalankan lewat: npm run register
async function main() {
  const rest = new REST({ version: "10" }).setToken(TOKEN);
  const commandData = [obfuscateCommand.toJSON()];


  try {
    console.log("Registering slash commands...");

    if (GUILD_ID) {
      // Guild commands = instant
      await rest.put(Routes.applicationGuildCommands(CLIENT_ID, GUILD_ID), {
        body: commandData,
      });
      console.log(`Slash commands registered to guild ${GUILD_ID}!`);
    } else {
      // Global commands = bisa sampai 1 jam untuk propagasi
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

main();
