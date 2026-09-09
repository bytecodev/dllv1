# Audit numeric VM — 2026-09-10

Status: file `04_stealanegg.lua` berhasil diuji dengan Medium pada kompilasi Luau, static/binary dump scan, dan bounded startup mock. Pengguna kemudian melaporkan bahwa output terbaru sudah diuji pada executor Roblox dan berjalan tanpa kendala; jenis executor, log, dan cakupan fitur live tidak tersedia untuk verifikasi independen.

## Temuan dan perubahan

- `Vmify` sebelumnya membangun AST blok dan threshold dispatcher. Sekarang ia memanggil compiler instruction tersendiri; emitter legacy hanya dipertahankan untuk kompatibilitas internal dan regresi.
- Medium sekarang hanya memakai `Vmify` numerik, kemudian rename/minify bawaan pipeline. Lapisan AntiDump, EncryptStrings, AntiTamper, ConstantArray dan GlobalProxy tidak lagi menjadi dasar Medium.
- Setiap function menjadi prototype dengan flat stream empat word terenkripsi per instruction. Prototype entry didekripsi per instruction tanpa cache permanen; callback berulang memakai cache opcode tersegel dan operand bermask. Tidak ada handler berisi blok source.
- Opcode map, dua sampai empat alias per operasi, permutasi dan mask operand, bentuk handler, tag state, encoding register/stack/PC, key, nama field frame, serta decoy berbeda antar-seed. PC memiliki offset berubah per instruction. Runtime tidak menyimpan daftar opcode semantik sebagai string.
- Register/cell **alamatnya** encoded; nilai object/function dan nilai program aktif tetap native agar identitas object, metamethod dan host API terjaga. Ini tidak mengklaim semua nilai hidup selalu terenkripsi di memori.
- Constant/string pool tetap terenkripsi. Tiga skema decoder dipilih per constant. Decoder dipanggil saat CONST/GLOBAL/METHOD/GREF dijalankan; cache plaintext dibatasi 32 slot pada frame aktif dan dibersihkan saat selesai. Closure hanya menangkap cell yang dirujuknya.
- Return/argument pack menyimpan jumlah hasil eksplisit, termasuk nil akhir. Compiler menangani closure, recursion/tail call, short circuit, multi-assignment, table, loop, Luau continue/compound/if expression, serta ordinary generalized table iteration.
- Commit multi-assignment mengikuti target: Lua51 dari kanan ke kiri; LuaU dari kiri ke kanan. RHS dan target indexing dievaluasi sebelum commit.
- Intrinsic global/member/method mengambil nama dari pool. Method dipanggil dengan object asli sebagai self. Medium tidak memerlukan debug dan tidak memanggil setfenv. Guard debug legacy Strong/Extreme dinonaktifkan saat target LuaU.
- `src/bytecode.js` sebelumnya menunjuk folder engine yang tidak tersedia; sekarang menjadi alias `src/prometheus.js`. API, bot, CLI dan harness memakai default Medium + LuaU; preset Roblox lama dialihkan ke Medium pada API/bot.
- `emit.lua` pada checkout awal sudah memakai compact array, begitu juga `createBlock`. Regresi 20 build mengawasi array tepat sebelum table.sort dan memverifikasi comparator tidak menerima nil. Tidak perlu menambahkan mapping ID ke sequence tersebut.

### Temuan reverse engineering dan hardening terbaru

| Kelemahan yang ditemukan | Perubahan engine | Dampak terhadap reverse engineering |
| --- | --- | --- |
| Modulus, multiplier, formula digest, dan state modulus tetap sehingga mudah difingerprint antar-output | Parameter cipher/digest/state diacak per build; instruction dan constant masing-masing memiliki tiga mode decode | Signature lintas-build dan decoder statis tunggal tidak lagi cukup untuk semua output |
| Layout prototype `[stream,key,params,captures,digest]` dan constant `[key,bytes]` selalu sama | Posisi tujuh field prototype dan empat field constant dipermutasi per build | Dumper tabel harus memulihkan layout build sebelum menafsirkan data |
| Cache instruction menyimpan opcode dan operand hasil decode secara langsung | Prototype entry tidak dicache; cache callback menyimpan `opcode + cacheKey` dan operand yang masih memakai mask alias handler | Snapshot cache tidak langsung menjadi instruction semantik |
| Cache constant frame dapat tumbuh sebanyak semua constant yang disentuh | Cache direct-mapped dibatasi 32 slot dan nilainya dihapus saat frame selesai | Jendela plaintext dan penggunaan memori lebih kecil |
| Checksum instruction hanya sampling dengan offset tetap, metadata prototype tidak terikat, constant tidak diperiksa | Medium memeriksa semua word sekali per prototype, mengikat mode/cache key/parameter/capture, dan memeriksa seluruh byte constant saat lazy decode | Edit stream, metadata, atau byte constant biasa gagal sebelum nilai dipakai |
| Dispatch guard hanya memeriksa jumlah handler | Jumlah, tipe key/value, dan seal key opcode diverifikasi saat startup | Penggantian key opcode sederhana terdeteksi |
| Nama field `status`, `position`, `stack`, `cells`, dan lainnya stabil | Tiga belas nama field frame dibuat acak per build | Fingerprint state VM dan script tracer berbasis nama kehilangan anchor tetap |
| Helper scheduler/trace dan cabang counter tetap ada meski dinonaktifkan | Source helper serta counter tidak dipancarkan saat setting nol | Medium lebih kecil dan menghindari biaya cabang per instruction |

Handler tetap melakukan operasi Lua yang pada akhirnya dapat dikenali secara semantik setelah runtime berhasil diinstrumentasi. Integrity seal tidak memiliki secret eksternal; attacker yang menguasai client dapat mempatch checker atau menghitung ulang nilai. Perubahan ini menaikkan biaya otomatisasi dan pemetaan lintas-build, bukan membuat devirtualization mustahil.

## Bukti pengujian

Perintah utama: `npm test`. Node 24.18.0; compiler dan differential Lua dijalankan melalui Wasmoon (Lua 5.4). Runtime Luau memakai executable resmi 0.737. SHA256 arsip `luau-windows.zip`: `8cd28be648f3e5cc4bfc977d2344e43540ade5f3524440b171eecf54d3a4fb7c`.

Hasil run terbaru setelah hardening VM: **31 tests, 30 passed, 0 failed, 1 skipped**, exit code 0, sekitar 68,8 detik. Skip tersisa adalah eksekusi otomatis dengan host fixture eksternal yang mencakup API game; bounded startup fixture bawaan dan laporan live pengguna sudah tersedia. `git diff --check` juga lulus.

| Pemeriksaan | Bukti |
| --- | --- |
| Smoke VM | `return 1+2` menghasilkan 3 |
| Differential Lua | Semantics fixture sama pada seed 1, 42, 987654; termasuk nil/vararg, upvalue, metamethod, assignment, loop, pcall dan coroutine yield/resume |
| Sample repository | sample.lua, sample2.lua, sample3.lua sama dengan source |
| CLI/default pipeline | Default API/pipeline Medium + LuaU; CLI mengobfuscate sample.lua dan hasil Luau sama |
| Preset eksplisit | Minify, Weak, Strong menjalankan print(7) di Luau dengan debug=nil; Strong + LuaU juga menghasilkan output sama dengan source pada fixture Roblox berisi RemoteEvent/RemoteFunction, task, typeof, pcall dan getgenv |
| Luau native | Semantics, Luau syntax, dan mock Roblox sama pada 3 seed; 9 pasangan eksekusi |
| Typed Luau | Alias/type function, anotasi, generic/type pack, union/intersection/optional, table/function/qualified/typeof type, read/write property, cast, dan generic instantiation lulus differential pada 3 seed; identifier type-only tidak bocor ke output |
| Lazy pool | Branch belum dijalankan tidak mendekripsi constant; traversal upvalue closure setelah pemanggilan tidak menemukan plaintext constant/cache |
| Tail call dan byte string | Rekursi tail 2.000 langkah, method tail call, UTF-8 dan byte NUL/255/128 lulus differential |
| Legacy sort | 20 build dengan randomized sparse block IDs; block sequence tetap compact dan comparator tidak menerima nil |
| Stream besar | 350 branch; source 17.306 byte menjadi output 392.833 byte; output sama di Luau |
| Static output dan Lua binary dump | Tidak ada game:GetService, ReplicatedStorage, HttpGet, RemoteEvent, RemoteFunction, AskWearStill, CodexUI |
| Disassembly Luau | Baseline mengekspos 7 nama penting; dump VM mengekspos 0. Ukuran dump 2.526 -> 121.962 byte. GetService diperiksa tersendiri karena NAMECALL memisahkannya dari global game |
| 04_stealanegg.lua Medium | Build, kompilasi Luau native, static scan dan binary dump scan lulus. Source dan output memiliki startup trace identik pada local UI loader dan mock HTTP fallback; Config tab juga dibangun |
| Roblox executor live / Instance asli | Pengguna melaporkan output Medium berjalan tanpa kendala; hasil ini belum memiliki log/cakupan fitur untuk verifikasi otomatis |

Artefak lokal berada di `test-results/`: output `roblox.medium.lua`, dump `roblox.simple-dump.luac`, disassembly `roblox.luau-disassembly.txt`, `dump-metrics.json`, `size-metrics.json`, dan pasangan source/output untuk tes native. Artefak dan executable tidak masuk git.

### File target yang diterima

- Source: 309.966 byte, SHA256 `0aee51e4ad8e29e13e1a35f3d1eb586eceb4de9c5d51a6ce0c6aaeeceb18d47b`.
- Output terbaru `test-results/04_stealanegg.medium.lua`: 2.040.085 byte, Medium + LuaU, seed 42, build sekitar 16,6 detik.
- SHA256 output terbaru: `1779b947844cd4b16fc0c4a1b8dbf603b6be9b2ce04e796473228158001d7129`. Metadata otomatis ada di `test-results/04_stealanegg.build.json`.
- Emitter `MixedHex` menghasilkan 76.707 literal `0x...` pada output target. Hex merupakan variasi lexical dan tidak diklaim sebagai penghambat dynamic dump.
- Native Luau binary tanpa debug info berhasil dibuat. Tujuh pola yang diminta serta `GetService` tidak ditemukan pada scan dump.
- Startup fixture menghasilkan `STARTUP_OK instances=6 tabs=7 configBuilds=1 pendingJobs=1` untuk source maupun output, pada kedua cabang loader. HTTP mengembalikan mock UI lokal; tidak ada download/jaringan nyata.
- Satu job animasi dijalankan sampai yield pertama. Game feature tab, interaction/input callbacks, getgc terhadap object game, __namecall hooks, respawn dan fitur teleport belum diuji. Semua feature tab tetap lazy; hanya Config yang dibangun dalam tes tambahan.
- File target ini belum dibangun/diuji memakai Strong. Bukti Strong adalah fixture kecil yang terpisah; jangan menganggap kelulusan fixture tersebut sebagai kelulusan seluruh file target di executor.

## Batas yang masih berlaku

Keystream aritmetika dan key tertanam membuat ini obfuscation yang reversibel oleh analis yang menguasai runtime, bukan encryption dengan secret eksternal. Hasil scan/disassembly membuktikan hilangnya pola/source constant pada dump sederhana tersebut; belum ada pembuktian ketahanan terhadap devirtualizer atau instrumentasi instruction/API.

Front end Prometheus sekarang mem-parse lalu menghapus syntax tipe Luau sebelum kompilasi VM: alias dan type function, anotasi binding/fungsi/loop, generic/type pack, bentuk type utama, access modifier, cast, dan generic instantiation masuk regression test. Parser ini bukan type checker dan belum mencakup seluruh grammar runtime Luau terbaru; function attributes, deklarasi `const`, dan interpolated backtick strings masih belum didukung. Mock Instance memverifikasi self dan lookup, tetapi tidak memverifikasi engine Roblox, executor-specific APIs, __namecall hooks, protected __iter metatables, atau semua jenis userdata.

Output VM lebih besar dan lambat daripada source native. Angka stream besar merupakan satu fixture, bukan benchmark umum atau batas kapasitas input. Preset berlapis Strong/Extreme jauh lebih mahal; Medium tetap default utama.

Smoke tambahan Extreme (di luar suite rutin) menghasilkan 7 di Luau, tetapi outputnya 16.230.595 byte untuk `print(7)`, build sekitar 40 detik dan run pertama melewati timeout 5 detik. Eksekusi ulang tanpa batas 5 detik berhasil. Extreme belum mendapat matriks semantik penuh dan tidak layak dijadikan default.

Pengguna sudah menjalankan output Medium pada executor Roblox dan melaporkan hasil tanpa kendala. Karena tidak ada runner/log executor yang dapat diakses dari workspace, laporan tersebut dicatat sebagai validasi pengguna dan tidak menggantikan regression suite otomatis.

### Audit dump dinamis yang diberikan pengguna

`168d7f178546dc3a.lua` berukuran 14.016 byte/617 baris. File itu berisi 11 panggilan `game:GetService`, satu `HttpGet`, dan bagian bootstrap UI, tetapi tidak berisi `RemoteEvent`, `RemoteFunction`, atau `AskWearStill`. Lima callback/Build menjadi function kosong dan tiga jalur berhenti pada penanda `infinitelooperror`. Bukti ini konsisten dengan trace eksekusi parsial: dumper merekam nilai dan host call yang benar-benar dipakai, bukan memperoleh kembali seluruh source asli.

VM dapat menyembunyikan constant dan struktur program dari static/simple bytecode dump, tetapi host call beserta argumennya harus tersedia saat program berjalan. Dumper yang mengendalikan executor dapat merekam nilai tersebut setelah lazy decryption. Mengganti desimal menjadi hex, menambah string simbol acak, atau menambah pemeriksaan API executor tidak dapat membuat client-side code mustahil didump; pemeriksaan seperti itu juga mudah dipalsukan dan berisiko memblokir executor yang sah.

## Diagnosis laporan freeze sebelum UI

Pengguna kemudian melaporkan stuck/crash sebelum UI muncul. Diagnosis read-only terhadap runtime dan benchmark startup dilakukan dengan `node scripts/diagnose-vm.js`. Compiler/proteksi belum diubah dalam tahap diagnosis ini.

File source asli sudah tidak berada di root ketika diagnosis dilakukan. Harness membaca source dari artefak startup sebelumnya dan memverifikasi SHA256-nya terhadap metadata build, tanpa mengembalikan atau mengubah file input pengguna. Output yang diukur memiliki SHA256 `b6024d071720117c9acfbe3226f6aedcfcc5597c08d83e083c4e1af3092ba2a7`.

Scan `getgc(true)` berada sebelum pembuatan UI. Fixture mengganti `getgc` dengan koleksi 0, 1.000, atau 5.000 tabel; setiap tabel memiliki 13 field numerik/string-key dan setiap tabel ke-10 memiliki self-reference. Tidak ada object game, network atau callback input asli yang dijalankan. Semua enam proses selesai dengan exit 0 dan assert startup lulus.

| Tabel pada mock getgc | Startup source | Startup Medium | Heap delta Medium pada akhir startup |
| --- | --- | --- | --- |
| 0 | 0,074 ms | 12,42 ms | 7.568 KB |
| 1.000 | 1,31 ms | 960,98 ms | 9.952 KB |
| 5.000 | 6,67 ms | 4.782,49 ms | 17.514 KB |

Timing startup menggunakan `os.clock` di dalam script; tidak mencakup kompilasi. Heap delta adalah pembacaan `collectgarbage('count')` sesudah dikurangi sebelum startup, **bukan peak memory atau jumlah seluruh alokasi**. Wall time CLI Medium tercatat 499, 1.375, dan 5.257 ms; angka ini juga mencakup proses/parse/compile. Data dan log disimpan di `test-results/vm-diagnostic.json` dan `test-results/diagnostic.*.luau.log`.

Bottleneck yang terlihat pada implementasi:

- `run` membuat ulang dispatch table beserta seluruh handler closure pada setiap pemanggilan fungsi VM.
- Setiap instruction mengalokasikan `words`; operasi scalar memakai table pack, dan beberapa varian operator menambah table operand sementara.
- Constant nama global/member didekripsi ulang saat dipakai; scanner memperbanyak jalur lookup/type-check tersebut.
- Scan awal tidak yield. Ukuran dan struktur koleksi getgc nyata belum diketahui.

Luau menjelaskan hubungan antara tingkat alokasi dan beban garbage collection dalam [dokumentasi performanya](https://luau.org/performance/). Benchmark ini menunjukkan overhead startup yang nyata dan sesuai tahap freeze yang dilaporkan, tetapi tidak mereproduksi crash client atau membuktikan kehabisan memori.

Prioritas optimasi berikutnya: bangun handler sekali per interpreter dengan frame terpisah per invocation; hilangkan alokasi decoder per instruction; kurangi table pack untuk jalur single-value sambil menjaga multi-return/nil/yield; profil scan getgc dan callback yang sering dipanggil. Numeric bytecode, opcode polymorphism dan lazy constant tanpa persistent plaintext pool tetap menjadi constraint. Perubahan scheduler/yield memerlukan perhatian khusus terhadap semantik callback dan coroutine.

## Hasil perbaikan freeze startup

Prioritas di atas sudah diterapkan. Dispatch dan handler polymorphic sekarang dibangun satu kali per interpreter dan menerima frame eksplisit, sehingga pemanggilan closure VM berulang tidak lagi membangun ulang seluruh handler table. Constant cache dipindahkan ke frame agar aman terhadap re-entry/coroutine dan dibersihkan saat invocation selesai. Constant yang sama dideduplikasi saat build, tetapi pool runtime tetap encrypted dan plaintext hanya didekripsi secara lazy.

Stack scalar tidak lagi membungkus setiap nilai dalam packet table. Packet hanya dipakai ketika semantik multi-return/vararg memang membutuhkannya. Call yang hasilnya dibuang atau hanya mengambil satu nilai memakai opcode terpisah. Call global, local function, dan method dengan nol sampai tiga argumen memakai intrinsic fixed-arity, sehingga tidak membuat argument packet dan lookup nama global/method tetap terjadi di dalam VM. Perubahan ini juga mempertahankan trailing nil dan multi-return pada jalur umum.

Auto-yield Medium dinonaktifkan (`YieldEvery = 0`). Uji Luau CLI menemukan bahwa yield dari entry thread tertentu dapat berhenti dengan `thread yielded unexpectedly`; `pcall(task.wait)` tidak menjamin kasus itu dapat dipulihkan. Yield tetap tersedia sebagai opsi eksplisit, tetapi bukan mekanisme pencegah freeze default.

Pada tahap optimasi startup sebelumnya, build berkurang dari 2.905.652 menjadi sekitar 2.007.793 byte (sekitar 30,9%). Pada fixture `getgc` yang sama, hasil tahap tersebut adalah:

| Tabel pada mock getgc | Medium sebelum | Medium sesudah | Heap delta sebelum | Heap delta sesudah |
| --- | ---: | ---: | ---: | ---: |
| 0 | 14,55 ms | 6,62 ms | 7.568 KB | 4.033 KB |
| 1.000 | 890,70 ms | 309,32 ms | 10.580 KB | 9.511 KB |
| 5.000 | 4.610,77 ms | 1.567,65 ms | 15.819 KB | 11.066 KB |

Angka dapat berfluktuasi antar-run; perbandingan di setiap baris berasal dari proses benchmark yang sama. Semua varian selesai dengan exit 0. Full suite terbaru menjadi **31 tests: 30 pass, 0 fail, 1 skip**; startup source/output tetap menghasilkan trace identik, kompilasi serta binary dump Luau lulus, dan static scan output tetap nol temuan untuk `game:GetService`, `ReplicatedStorage`, `HttpGet`, `RemoteEvent`, `RemoteFunction`, `AskWearStill`, dan `CodexUI`.

`04_stealanegg.lua` masih melakukan crawl `getgc(true)` sebelum membuat UI. Waktu bagian ini bertambah mengikuti jumlah object/table pada client, jadi VM yang lebih cepat mengurangi stall tetapi tidak dapat membuat scan tanpa batas menjadi konstan. Jika koleksi executor jauh lebih besar daripada fixture, pemindahan scan ke sesudah UI atau pemrosesan batch perlu dilakukan pada source aplikasi agar UI selalu muncul lebih dahulu.

## Regression corpus umum

`04_stealanegg.lua` sekarang hanya menjadi integration fixture. Suite utama juga menjalankan `qa/vm-corpus.test.js`, yang tidak mengambil source, nama, atau struktur dari file tersebut. Corpus menguji control flow Luau, multi-return dan trailing nil, closure/upvalue/tail recursion, coroutine yield/resume, metamethod dan generalized iteration, error/pcall, pola object/method Roblox, serta 2.000 hot callback invocation. Delapan program aritmetika/control-flow tambahan dibuat secara deterministik dengan bentuk dan seed berbeda.

Corpus ditemukan dan memperbaiki perbedaan Luau pada `{fn()}` ketika hasil terakhir memiliki lubang nil. VM sekarang menggunakan reservasi array Luau ketika perlu agar layout table constructor dan hasil operator panjang sesuai source. Run final menjalankan delapan kategori pada seed 13 dan 907, ditambah delapan generated programs: seluruh output sama dengan source.

Benchmark generik `npm run benchmark:vm` membangun workload sendiri dan tidak membaca file pengguna. Tiga run final 5.000 callback menghasilkan `BENCH_OK 50040000`; waktu Medium adalah 811,19 / 820,67 / 822,64 ms, median 820,67 ms, dengan output 37.044 byte. Median ini sekitar 4,3% di atas angka hardening sebelumnya 787,05 ms dan sekitar 15,5% di atas baseline audit 710,62 ms. Biaya utama tambahan berasal dari mask operand, tiga jalur decoder, layout record acak, dan integrity metadata; full checksum hanya berjalan sekali saat tiap prototype pertama dipakai. Angka ini dipakai untuk mendeteksi regresi relatif antar-build, bukan sebagai jaminan waktu pada perangkat Roblox.
