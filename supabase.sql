-- TOKOPRO: jalankan seluruh SQL ini di Supabase SQL Editor.
-- Catatan: akun Auth dibuat dari Supabase Dashboard. Setelah itu buat profilnya.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 email text, full_name text not null default '',
 role text not null check (role in ('master','admin','cashier')),
 created_at timestamptz not null default now()
);
create table if not exists public.products (
 id uuid primary key default gen_random_uuid(),
 sku text unique, name text not null, brand text, series text, category text,
 base_unit text not null default 'pcs',
 buy_price numeric(14,2) not null default 0 check(buy_price>=0),
 sell_price numeric(14,2) not null default 0 check(sell_price>=0),
 stock_qty numeric(14,3) not null default 0 check(stock_qty>=0),
 min_stock numeric(14,3) not null default 0,
 is_active boolean not null default true,
 created_by uuid references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.product_units (
 id uuid primary key default gen_random_uuid(),
 product_id uuid not null references public.products(id) on delete cascade,
 unit_name text not null, factor numeric(14,3) not null check(factor>0),
 unique(product_id,unit_name)
);
create table if not exists public.sales (
 id uuid primary key default gen_random_uuid(), invoice_no text unique not null,
 cashier_id uuid not null references public.profiles(id),
 total_amount numeric(14,2) not null check(total_amount>=0),
 status text not null default 'paid' check(status in ('paid','void')),
 note text, created_at timestamptz not null default now()
);
create table if not exists public.sale_items (
 id uuid primary key default gen_random_uuid(), sale_id uuid not null references public.sales(id) on delete cascade,
 product_id uuid not null references public.products(id), product_name text not null, series text,
 qty numeric(14,3) not null, unit text not null, base_qty numeric(14,3) not null,
 unit_price numeric(14,2) not null, line_total numeric(14,2) not null
);
create table if not exists public.payments (
 id uuid primary key default gen_random_uuid(), sale_id uuid not null references public.sales(id) on delete cascade,
 method text not null check(method in ('cash','transfer','qris')),
 amount numeric(14,2) not null check(amount>0), reference text
);
create table if not exists public.stock_movements (
 id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id),
 movement_type text not null check(movement_type in ('opening','in','out','adjustment')),
 qty numeric(14,3) not null, note text, reference_id uuid, created_by uuid references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.store_settings (
 id integer primary key default 1 check(id=1), store_name text not null default 'TOKOPRO',
 store_description text, bank_account text, bank_holder text, qris_image_url text,
 updated_by uuid references public.profiles(id), updated_at timestamptz not null default now()
);
insert into public.store_settings(id) values(1) on conflict do nothing;
create table if not exists public.audit_logs (
 id uuid primary key default gen_random_uuid(), user_id uuid references public.profiles(id),
 action text not null, details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);

create or replace function public.my_role() returns text language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() $$;
create or replace function public.log_action(p_action text,p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path=public
as $$ begin insert into public.audit_logs(user_id,action,details) values(auth.uid(),p_action,p_details); end $$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.product_units enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.payments enable row level security;
alter table public.stock_movements enable row level security;
alter table public.store_settings enable row level security;
alter table public.audit_logs enable row level security;

-- Profiles: semua pengguna terautentikasi dapat melihat nama/role; hanya master mengelola.
create policy "profiles read authenticated" on public.profiles for select to authenticated using(true);
create policy "master manages profiles" on public.profiles for all to authenticated using(public.my_role()='master') with check(public.my_role()='master');
create policy "products read authenticated" on public.products for select to authenticated using(true);
create policy "admin master manage products" on public.products for all to authenticated using(public.my_role() in ('admin','master')) with check(public.my_role() in ('admin','master'));
create policy "units read authenticated" on public.product_units for select to authenticated using(true);
create policy "admin master manage units" on public.product_units for all to authenticated using(public.my_role() in ('admin','master')) with check(public.my_role() in ('admin','master'));
create policy "sales read role scope" on public.sales for select to authenticated using(public.my_role() in ('admin','master') or cashier_id=auth.uid());
create policy "sales insert own" on public.sales for insert to authenticated with check(cashier_id=auth.uid());
create policy "sale items read scope" on public.sale_items for select to authenticated using(exists(select 1 from public.sales s where s.id=sale_id and (public.my_role() in ('admin','master') or s.cashier_id=auth.uid())));
create policy "payments read scope" on public.payments for select to authenticated using(exists(select 1 from public.sales s where s.id=sale_id and (public.my_role() in ('admin','master') or s.cashier_id=auth.uid())));
create policy "stock movements read" on public.stock_movements for select to authenticated using(public.my_role() in ('admin','master') or created_by=auth.uid());
create policy "stock movement insert admin" on public.stock_movements for insert to authenticated with check(public.my_role() in ('admin','master'));
create policy "settings read" on public.store_settings for select to authenticated using(true);
create policy "settings update admin master" on public.store_settings for all to authenticated using(public.my_role() in ('admin','master')) with check(public.my_role() in ('admin','master'));
create policy "logs read master" on public.audit_logs for select to authenticated using(public.my_role()='master');
create policy "logs insert authenticated" on public.audit_logs for insert to authenticated with check(user_id=auth.uid());

-- Semua stok keluar dan pembayaran diproses dalam satu transaksi database (atomic).
create or replace function public.checkout_sale(p_items jsonb,p_payments jsonb,p_note text default null)
returns text language plpgsql security definer set search_path=public
as $$
declare v_sale_id uuid; v_invoice text; v_total numeric(14,2):=0; v_paid numeric(14,2):=0;
 v_item jsonb; v_pay jsonb; v_product public.products%rowtype; v_qty numeric(14,3); v_price numeric(14,2); v_line numeric(14,2);
begin
 if auth.uid() is null then raise exception 'Silakan login'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Keranjang kosong'; end if;
 if jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)=0 then raise exception 'Pembayaran belum diisi'; end if;
 -- Kunci baris produk supaya dua kasir tidak mengurangi stok yang sama secara bersamaan.
 for v_item in select * from jsonb_array_elements(p_items) loop
   select * into v_product from public.products where id=(v_item->>'product_id')::uuid and is_active=true for update;
   if not found then raise exception 'Produk tidak ditemukan atau nonaktif'; end if;
   v_qty:=(v_item->>'qty')::numeric; v_price:=(v_item->>'unit_price')::numeric;
   if v_qty<=0 or v_price<0 then raise exception 'Jumlah/harga tidak valid'; end if;
   if v_product.stock_qty<v_qty then raise exception 'Stok % tidak cukup. Tersedia % %',v_product.name,v_product.stock_qty,v_product.base_unit; end if;
   v_total:=v_total+(v_qty*v_price);
 end loop;
 for v_pay in select * from jsonb_array_elements(p_payments) loop
   if (v_pay->>'method') not in ('cash','transfer','qris') then raise exception 'Metode pembayaran tidak valid'; end if;
   if (v_pay->>'amount')::numeric<=0 then raise exception 'Nominal pembayaran harus lebih dari nol'; end if;
   v_paid:=v_paid+(v_pay->>'amount')::numeric;
 end loop;
 if abs(v_total-v_paid)>0.01 then raise exception 'Total pembayaran harus sama dengan total transaksi'; end if;
 v_invoice:='INV-'||to_char(now(),'YYYYMMDD-HH24MISS')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,5));
 insert into public.sales(invoice_no,cashier_id,total_amount,note) values(v_invoice,auth.uid(),v_total,p_note) returning id into v_sale_id;
 for v_item in select * from jsonb_array_elements(p_items) loop
   select * into v_product from public.products where id=(v_item->>'product_id')::uuid for update;
   v_qty:=(v_item->>'qty')::numeric;v_price:=(v_item->>'unit_price')::numeric;v_line:=v_qty*v_price;
   update public.products set stock_qty=stock_qty-v_qty where id=v_product.id;
   insert into public.sale_items(sale_id,product_id,product_name,series,qty,unit,base_qty,unit_price,line_total)
   values(v_sale_id,v_product.id,v_product.name,v_product.series,v_qty,v_product.base_unit,v_qty,v_price,v_line);
   insert into public.stock_movements(product_id,movement_type,qty,note,reference_id,created_by)
   values(v_product.id,'out',-v_qty,'Penjualan '||v_invoice,v_sale_id,auth.uid());
 end loop;
 for v_pay in select * from jsonb_array_elements(p_payments) loop
   insert into public.payments(sale_id,method,amount,reference) values(v_sale_id,v_pay->>'method',(v_pay->>'amount')::numeric,nullif(v_pay->>'reference',''));
 end loop;
 insert into public.audit_logs(user_id,action,details) values(auth.uid(),'checkout_sale',jsonb_build_object('invoice',v_invoice,'total',v_total));
 return v_invoice;
end $$;

create or replace function public.receive_stock(p_product_id uuid,p_qty numeric,p_note text default null)
returns void language plpgsql security definer set search_path=public
as $$
begin
 if public.my_role() not in ('admin','master') then raise exception 'Hanya admin/master yang boleh input barang masuk'; end if;
 if p_qty<=0 then raise exception 'Jumlah harus lebih dari nol'; end if;
 update public.products set stock_qty=stock_qty+p_qty where id=p_product_id;
 if not found then raise exception 'Produk tidak ditemukan'; end if;
 insert into public.stock_movements(product_id,movement_type,qty,note,created_by) values(p_product_id,'in',p_qty,p_note,auth.uid());
 insert into public.audit_logs(user_id,action,details) values(auth.uid(),'receive_stock',jsonb_build_object('product_id',p_product_id,'qty',p_qty,'note',p_note));
end $$;

grant execute on function public.checkout_sale(jsonb,jsonb,text) to authenticated;
grant execute on function public.receive_stock(uuid,numeric,text) to authenticated;
grant execute on function public.log_action(text,jsonb) to authenticated;
grant usage on schema public to authenticated;
grant select,insert,update on public.profiles,public.products,public.product_units,public.sales,public.sale_items,public.payments,public.stock_movements,public.store_settings,public.audit_logs to authenticated;
