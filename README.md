# ByteCode Discord Obfuscator

Bot Discord yang dikhususkan untuk **obfuscation Lua/LuaU** menggunakan engine Prometheus internal. Project ini tidak lagi menyertakan AI chat, pemilihan model AI, web search, atau fitur deobfuscation.

## Fitur

- Command `/obf` untuk meng-obfuscate file Lua atau source code yang ditempel langsung.
- Preset: `Minify`, `Weak`, `Medium`, `Strong`, dan `Extreme`. Preset `Roblox` sudah dihapus; default sekarang memakai `Medium` yang diperkuat untuk LuaU/Roblox.
- Target: **LuaU (Roblox)** secara default, dengan opsi **Lua 5.1** jika dibutuhkan.
- Opsi `pretty_print` dan custom random `seed`.
- Dukungan pembatasan penggunaan berdasarkan channel dan role Discord.
- File input maksimal 5 MB dan source maksimal 1.000.000 karakter.

## Instalasi

```bash
npm install
```

Buat file `.env` berdasarkan `.env.example`, lalu isi token dan ID aplikasi Discord.

Daftarkan slash command:

```bash
npm run register
```

Jalankan bot:

```bash
npm start
```

## Environment Variables

- `DISCORD_BOT_TOKEN` — token bot Discord, wajib.
- `DISCORD_CLIENT_ID` — application/client ID Discord, wajib.
- `DISCORD_GUILD_ID` — opsional; jika diisi, `/obf` didaftarkan khusus ke guild tersebut dan update command lebih cepat.
- `DISCORD_ALLOWED_CHANNEL_ID_OBF` — opsional; satu atau beberapa channel ID dipisahkan koma.
- `DISCORD_ALLOWED_ROLE_ID` — opsional; satu atau beberapa role ID dipisahkan koma.
- `PORT` — opsional; port HTTP health check, default `3000`.

## Slash Command

`/obf` menerima salah satu dari:

- `file`: upload file Lua.
- `code`: paste source Lua secara langsung.

Opsi tambahan:

- `preset`: preset obfuscation, default `Medium` hardened.
- `lua_version`: `Lua51` atau `LuaU`, default `LuaU`.
- `pretty_print`: format output agar lebih mudah dibaca, default `false`.
- `seed`: seed acak agar hasil dapat direproduksi.

Output dikirim kembali sebagai file `bytecode.lua`.


## Medium hardened note

Medium sekarang memakai `ConstantArray.Encoding = "masked"`, bukan base64/base85/mixed. Payload string disimpan sebagai byte-mask mentah yang di-escape oleh Lua unparser, lalu di-unmask saat runtime. Jadi hasil decode base64/base85 biasa tidak akan mengembalikan string asli.
