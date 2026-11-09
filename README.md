# TokoPro — Starter aplikasi toko

## Isi
- `index.html` dan `app.js`: antarmuka web login, dashboard berdasarkan role, stok, kasir, pembayaran campuran, laporan CSV dan cetak PDF.
- `supabase.sql`: tabel, Row Level Security (RLS), dan fungsi transaksi atomik untuk mengurangi stok serta mencatat pembayaran.

## Langkah pemasangan
1. Buat project di Supabase.
2. Buka SQL Editor, jalankan seluruh isi `supabase.sql`.
3. Buka Authentication → Users, buat akun pengguna.
4. Salin User UID, lalu di SQL Editor jalankan contoh berikut (ganti nilai):
   ```sql
   insert into public.profiles(id,email,full_name,role)
   values ('UUID_USER','email@toko.com','Nama Pengguna','master');
   ```
   Ulangi untuk role `admin` dan `cashier`. Role hanya boleh `master`, `admin`, atau `cashier`.
5. Di `app.js`, isi `SUPABASE_URL` dan `SUPABASE_ANON_KEY` dengan Project URL dan anon/public atau publishable key. Jangan pernah menaruh `service_role` key di browser.
6. Upload `index.html` dan `app.js` ke GitHub. Aktifkan GitHub Pages, atau deploy repository ke Vercel/Netlify.
7. Buka alamat web, login memakai akun yang dibuat.

## Hak akses rancangan
- MASTER: ringkasan, produk/stok, barang masuk, penjualan/laporan, pengguna, identitas toko, aktivitas.
- ADMIN: produk/stok, barang masuk, penjualan/laporan, pengaturan identitas dan pembayaran.
- KASIR: POS, cek stok, transaksi milik sendiri. Tidak dapat mengubah stok atau master produk.

## Catatan penting sebelum dipakai operasional
- Ini adalah starter awal untuk diuji, bukan sistem produksi siap pakai.
- Saat ini stok dasar produk adalah satuan utama. Kolom kemasan tambahan menyimpan faktor konversi, tetapi pilihan kemasan saat POS dan konversi otomatis (contoh 1 dus = 12 pcs) perlu tahap implementasi berikutnya. Jangan gunakan penjualan kemasan besar sampai fitur itu diselesaikan.
- Data transaksi dicatat di Supabase. CSV/PDF dibuat saat diminta; CSV dapat dibuka di Excel, PDF melalui dialog Cetak → Save as PDF. Arsip file PDF/Excel ke Supabase Storage belum diaktifkan.
- Pembuatan akun dilakukan dari Supabase Dashboard; menu pengguna saat ini menampilkan daftar profil.
- Foto/logo toko dan upload QRIS ke Storage masih berupa URL konfigurasi, belum ada uploader.
- Pengaturan role di database harus dilakukan oleh MASTER tepercaya. Jangan memberi hak MASTER kepada pengguna biasa.
- Sebelum penggunaan nyata, lakukan uji transaksi, stok bersamaan dari dua kasir, backup, pajak/diskon, pembatalan/refund, printer struk, dan audit keamanan RLS dengan data uji.
