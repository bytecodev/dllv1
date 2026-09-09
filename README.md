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


## Medium numeric VM

Medium memakai compiler custom bytecode di `Prometheus/prometheus/compiler/bytecode.lua` dan generator interpreter di `bytecode_runtime.lua`. Pipeline utamanya:

```text
AST source -> numeric instructions -> encrypted four-word stream per function
           -> generated polymorphic VM -> renamed/minified Lua compatible with Luau
```

Opcode memiliki dua sampai empat alias acak, dengan urutan dan mask operand berbeda per alias. Register/cell ID dan stack position memakai encoding affine; PC memakai encoding affine dengan offset yang berubah setiap instruction. State dispatch dan nama field frame diacak per build. Setiap prototype memilih satu dari tiga skema keystream instruction dengan parameter aritmetika per build dan feedback antar-word. Cache instruction callback menyimpan opcode yang masih disegel serta operand yang masih bermask; prototype entry tidak disimpan. Decoy instruction yang dijalankan hanya mengubah state noise privat; dead handler tidak memanggil API host.

Emitter Medium memakai `MixedHex`: integer VM yang cocok ditulis sebagai campuran desimal dan literal `0x...` yang dipilih per build. Hex hanya dipakai jika tidak memperbesar literal, sehingga variasi source tidak menambah operasi runtime atau ukuran output. Karakter seperti `!` dan `#` tidak dapat dipakai di identifier Luau; memasukkannya sebagai string decoy hanya menambah beban dan tidak menghambat dumper runtime.

Constant pool berisi byte numerik terenkripsi, termasuk type tag. Setiap constant memakai salah satu dari tiga decoder per build dan baru didekripsi oleh instruction yang memerlukannya. Cache plaintext dibatasi 32 slot per frame aktif dan dibersihkan saat frame selesai; tidak ada plaintext constant array permanen. Nilai program yang masih hidup, misalnya local string atau upvalue milik source, tetap harus tersedia sesuai semantik program.

Medium memverifikasi seluruh word instruction sekali saat prototype pertama dipakai, termasuk metadata parameter/capture dan key cache. Setiap constant diverifikasi atas seluruh byte pada saat lazy decode. Tabel dispatch juga memeriksa jumlah handler dan seal atas key opcode. Jalur scheduler dan trace guard tidak dipancarkan ketika pengaturannya nol agar startup Medium tetap ringan.

Global lookup, member indexing, dan method resolution ditangani intrinsic VM. Pemanggilan method meneruskan object sebagai `self`. Medium tidak memasang debug hook, mengganti environment dengan `setfenv`, atau menjalankan loader untuk source tersembunyi. `getgenv`, `task`, `typeof`, `pcall`, dan `coroutine` diteruskan ke environment host.

Default API, Discord, dan CLI adalah Medium + LuaU. Alias input lama `Roblox` dialihkan ke Medium. Seed eksplisit reproducible; seed otomatis memakai `crypto.randomInt`. `src/bytecode.js` meneruskan ke engine yang sama.

Encoding dan integrity check ini merupakan perlindungan obfuscation dengan decoder/key tertanam, bukan jaminan kriptografi terhadap pihak yang mengendalikan runtime. Attacker yang dapat mengubah runtime juga dapat menonaktifkan atau menghitung ulang check lokal. Dump sederhana tetap memperlihatkan interpreter generik; instrumentasi saat API dipanggil dapat melihat nilai yang memang harus diberikan kepada API tersebut.

## Front-end Luau bertipe

Parser menerima dan menghapus sintaks tipe sebelum AST executable dikompilasi ke VM. Cakupannya meliputi `type`/`export type`, user-defined `type function`, anotasi local/parameter/return/variadic/loop, generic dan type pack beserta default, union/intersection/optional, singleton/qualified/`typeof`/table/function types, modifier properti `read`/`write`, cast `::`, dan explicit generic instantiation `fn<<T>>()`. Cast tetap mempertahankan aturan Luau yang membatasi multi-return menjadi satu nilai.

Ini bukan type checker; validitas relasi tipe tetap menjadi tugas Luau analyzer. Front end belum mengimplementasikan seluruh grammar runtime terbaru seperti function attributes, deklarasi `const`, dan interpolated backtick strings.

## CLI dan validasi

```bash
npm run obfuscate -- input.lua output.lua 42
npm test
```

CLI menolak overwrite input atau output yang sudah ada. Tes dasar memakai Lua 5.4 Wasmoon; tes Luau native memakai `LUAU_BIN` dan `LUAU_COMPILE_BIN`, atau executable di `test-results/tools/luau/`. Jika runner tidak tersedia, tes native ditandai skipped secara eksplisit. Runner yang dipakai pada audit ini: [Luau 0.737 resmi](https://github.com/luau-lang/luau/releases/tag/0.737).

Untuk menguji file target dengan host fixture yang sesuai (PowerShell):

```powershell
$env:ROBLOX_SCRIPT = 'C:\path\04_stealanegg.lua'
$env:ROBLOX_SETUP = 'C:\path\script-specific-host.lua'
$env:LUAU_BIN = 'C:\path\luau.exe'
npm test
```

Jika `04_stealanegg.lua` ada di root workspace, test otomatis memakainya. Fixture startup khusus membandingkan source/output pada kedua jalur pemuatan UI dan pembukaan Config tab. Game feature dan input callbacks tetap di luar cakupannya; `ROBLOX_SETUP` dapat dipakai untuk host fixture tambahan. Hasil mock/CLI Luau tidak membuktikan keberhasilan pada Roblox executor live. Run terbaru: 31 tests, 30 passed, 0 failed, 1 skipped (host fixture eksternal belum tersedia). Lihat `VM_AUDIT.md` untuk hasil dan batas pengujian.
