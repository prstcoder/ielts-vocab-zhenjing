-- ============================================================
-- 雅思词汇站 · 多设备同步（同步码）后端
-- 用法：Supabase 控制台 → SQL Editor → 整段粘贴 → Run
-- 说明：
--   1) 表 sync_docs 存「同步码 → 整份数据」，一个码一行人
--   2) 表上不开任何 RLS 策略，anon 无法直接读写表
--   3) 只暴露两个函数：sync_pull(码) / sync_push(码, 数据, 版本)
--      → 必须知道码才能取到对应那一行，拿不到别人的数据
--   4) sync_push 带乐观锁：版本对不上就返回服务器最新值，客户端合并后重试
-- ============================================================

create table if not exists public.sync_docs (
  code       text primary key,
  payload    jsonb not null default '{}'::jsonb,
  ver        bigint not null default 1,
  updated_at timestamptz not null default now()
);

alter table public.sync_docs enable row level security;
-- 故意不建 policy：anon 直接查表会返回空/拒绝，只能走下面的函数

-- ---------- 读 ----------
create or replace function public.sync_pull(p_code text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'ver',     coalesce((select ver     from public.sync_docs where code = p_code), 0),
    'payload', coalesce((select payload from public.sync_docs where code = p_code), '{}'::jsonb)
  )
$$;

-- ---------- 写（乐观锁） ----------
create or replace function public.sync_push(p_code text, p_payload jsonb, p_base bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ver bigint;
begin
  if p_code is null or length(btrim(p_code)) < 4 then
    return jsonb_build_object('ok', false, 'reason', 'bad_code');
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    return jsonb_build_object('ok', false, 'reason', 'bad_payload');
  end if;

  insert into public.sync_docs(code, payload, ver, updated_at)
  values (btrim(p_code), p_payload, 1, now())
  on conflict (code) do update
     set payload    = excluded.payload,
         ver        = public.sync_docs.ver + 1,
         updated_at = now()
   where p_base is null
      or public.sync_docs.ver = p_base
  returning ver into v_ver;

  if v_ver is null then
    -- 版本冲突：把服务器上的最新副本带回去，让客户端合并后重试
    select ver into v_ver from public.sync_docs where code = btrim(p_code);
    return jsonb_build_object(
      'ok', false,
      'reason', 'conflict',
      'ver', v_ver,
      'payload', (select payload from public.sync_docs where code = btrim(p_code))
    );
  end if;

  return jsonb_build_object('ok', true, 'ver', v_ver);
end $$;

-- ---------- 权限 ----------
revoke all on function public.sync_pull(text)                 from public;
revoke all on function public.sync_push(text, jsonb, bigint)  from public;
grant execute on function public.sync_pull(text)                to anon;
grant execute on function public.sync_push(text, jsonb, bigint) to anon;

-- ---------- 可选：清理半年没动过的码 ----------
-- delete from public.sync_docs where updated_at < now() - interval '180 days';
