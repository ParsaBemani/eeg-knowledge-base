-- EEG Construct–Measure Knowledge Base: database, sign-in roles and email approvals.
--
-- Run this whole file once in Supabase: Dashboard → SQL Editor → New query → paste → Run.
-- It is safe to run again; it updates functions and keeps existing data.
-- Personal settings (your sender address, Brevo key, first admin) are a separate
-- step in SETUP.md, so nothing private is stored in this public file.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Site settings read only by the functions below (no one can read them through the API).
create table if not exists public.settings (
  key text primary key,
  value text not null
);
alter table public.settings enable row level security;
insert into public.settings (key, value) values
  ('site_url', 'https://parsabemani.github.io/eeg-knowledge-base/'),
  ('sender_email', 'CHANGE-ME@example.com'),
  ('sender_name', 'EEG Knowledge Base')
on conflict (key) do nothing;

-- Every record on the site: papers, signals, topics, links, guidance and dataset info.
create table if not exists public.kb_records (
  collection text not null check (collection in ('meta', 'sources', 'guidance', 'measures', 'constructs', 'entries')),
  id text not null check (id ~ '^[A-Za-z0-9_.:-]{1,100}$'),
  doc jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (collection, id)
);
alter table public.kb_records enable row level security;
drop policy if exists "Anyone can read the knowledge base" on public.kb_records;
create policy "Anyone can read the knowledge base" on public.kb_records for select using (true);
-- No write policies: records change only through the admin functions below.

create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  added_by uuid,
  added_at timestamptz not null default now()
);
alter table public.admins enable row level security;

create table if not exists public.admin_invites (
  email text primary key,
  invited_by uuid,
  invited_at timestamptz not null default now()
);
alter table public.admin_invites enable row level security;

create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  submitted_by uuid default auth.uid() references auth.users (id) on delete set null,
  submitter_email text,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  payload jsonb not null check (octet_length(payload::text) < 12000),
  review_note text,
  reviewed_by uuid,
  reviewer_email text,
  reviewed_at timestamptz,
  entry_id text
);
alter table public.submissions enable row level security;

-- One single-use token per admin per suggestion, for the Accept / Reject buttons in emails.
-- Only a hash is stored; the token itself exists only in the email.
create table if not exists public.review_tokens (
  token_hash text primary key,
  submission_id uuid not null references public.submissions (id) on delete cascade,
  admin_id uuid not null references auth.users (id) on delete cascade,
  admin_email text not null,
  expires_at timestamptz not null default now() + interval '14 days'
);
alter table public.review_tokens enable row level security;

create table if not exists public.activity (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid,
  actor_email text,
  action text not null,
  detail jsonb not null default '{}'
);
alter table public.activity enable row level security;

-- The site's owner: an admin who can also remove admins and block emails. Set in SETUP.md, not here.
create table if not exists public.owners (
  email text primary key check (email = lower(email)),
  added_at timestamptz not null default now()
);
alter table public.owners enable row level security;

-- Emails that may not sign in, suggest links or review. Managed by the owner on the Admin page.
create table if not exists public.blocked_emails (
  email text primary key check (email = lower(email)),
  note text not null default '',
  blocked_by uuid,
  blocked_at timestamptz not null default now()
);
alter table public.blocked_emails enable row level security;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.owners o join auth.users u on lower(u.email) = o.email where u.id = auth.uid());
$$;

-- The owner is always an admin.
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid()) or public.is_owner();
$$;

drop policy if exists "Admins can see admins" on public.admins;
create policy "Admins can see admins" on public.admins for select using (public.is_admin());
drop policy if exists "Admins can see invites" on public.admin_invites;
create policy "Admins can see invites" on public.admin_invites for select using (public.is_admin());
drop policy if exists "Admins can read activity" on public.activity;
create policy "Admins can read activity" on public.activity for select using (public.is_admin());
drop policy if exists "Admins can see the owner" on public.owners;
create policy "Admins can see the owner" on public.owners for select using (public.is_admin());
drop policy if exists "The owner can see blocked emails" on public.blocked_emails;
create policy "The owner can see blocked emails" on public.blocked_emails for select using (public.is_owner());
drop policy if exists "Signed-in users can suggest links" on public.submissions;
create policy "Signed-in users can suggest links" on public.submissions for insert to authenticated
  with check (submitted_by = auth.uid() and status = 'pending');
drop policy if exists "Contributors see their own suggestions, admins see all" on public.submissions;
create policy "Contributors see their own suggestions, admins see all" on public.submissions for select to authenticated
  using (submitted_by = auth.uid() or public.is_admin());

create or replace function public._user_email(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select lower(email) from auth.users where id = p_user;
$$;

create or replace function public._log(p_action text, p_detail jsonb, p_actor uuid default auth.uid(), p_email text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.activity (actor, actor_email, action, detail)
  values (p_actor, coalesce(p_email, public._user_email(p_actor)), p_action, coalesce(p_detail, '{}'::jsonb));
end $$;

create or replace function public._esc(t text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
$$;

create or replace function public._slug(t text) returns text
language sql immutable as $$
  select coalesce(nullif(left(trim(both '-' from regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', '-', 'g')), 40), ''), 'x');
$$;

create or replace function public._rid() returns text
language sql volatile as $$
  select substr(md5(random()::text || clock_timestamp()::text), 1, 5);
$$;

-- Sends one email through Brevo's HTTP API. Does nothing until the sender and key are set.
create or replace function public._send_email(p_to text, p_subject text, p_html text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_key text;
  v_from text := (select value from public.settings where key = 'sender_email');
  v_name text := coalesce((select value from public.settings where key = 'sender_name'), 'EEG Knowledge Base');
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  if p_to is null or v_key is null or v_from is null or v_from like 'CHANGE-ME%' then
    raise notice 'Email not sent (email settings incomplete): %', p_subject;
    return;
  end if;
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object(
      'sender', jsonb_build_object('email', v_from, 'name', v_name),
      'to', jsonb_build_array(jsonb_build_object('email', p_to)),
      'subject', p_subject,
      'htmlContent', p_html),
    headers := jsonb_build_object('Content-Type', 'application/json', 'accept', 'application/json', 'api-key', v_key)
  );
end $$;

create or replace function public._email_page(p_title text, p_body text)
returns text language sql immutable as $$
  select '<div style="font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#14202A;max-width:600px">'
      || '<h2 style="font-size:19px;margin:0 0 12px">' || public._esc(p_title) || '</h2>' || p_body
      || '<p style="color:#6F7D8A;font-size:12.5px;margin-top:24px">EEG Construct–Measure Knowledge Base</p></div>';
$$;

-- Electrode names a suggestion may use (10–20 style, e.g. Fz, C3, PO8, M1), without duplicates, at most 30.
create or replace function public._sites(v jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(x.value order by x.ord), '[]'::jsonb) from (
    select t.value, min(t.ord) as ord
    from jsonb_array_elements_text(case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end) with ordinality as t(value, ord)
    where t.value ~ '^[A-Z][A-Za-z]{0,2}(z|[0-9]{1,2})$'
    group by t.value order by min(t.ord) limit 30) x;
$$;

-- The first frequency range of a suggestion, if it is two numbers with 0 <= from < to <= 1000 Hz.
create or replace function public._band(v jsonb) returns jsonb
language sql immutable as $$
  select case
    when jsonb_typeof(v) = 'array' and jsonb_typeof(v->0) = 'object'
     and (v->0->>'lo') ~ '^[0-9]+(\.[0-9]+)?$' and (v->0->>'hi') ~ '^[0-9]+(\.[0-9]+)?$'
     and (v->0->>'lo')::numeric < (v->0->>'hi')::numeric and (v->0->>'hi')::numeric <= 1000
    then jsonb_build_array(jsonb_build_object('lo', (v->0->>'lo')::numeric, 'hi', (v->0->>'hi')::numeric, 'label', left(coalesce(v->0->>'label', ''), 30)))
    else '[]'::jsonb end;
$$;

-- Every valid frequency range in a list (at most 8), for edits that keep a signal's other ranges.
create or replace function public._bands(v jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('lo', (x.b->>'lo')::numeric, 'hi', (x.b->>'hi')::numeric, 'label', left(coalesce(x.b->>'label', ''), 30)) order by x.ord), '[]'::jsonb)
  from (
    select t.b, t.ord
    from jsonb_array_elements(case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end) with ordinality as t(b, ord)
    where jsonb_typeof(t.b) = 'object'
      and (t.b->>'lo') ~ '^[0-9]+(\.[0-9]+)?$' and (t.b->>'hi') ~ '^[0-9]+(\.[0-9]+)?$'
      and (t.b->>'lo')::numeric < (t.b->>'hi')::numeric and (t.b->>'hi')::numeric <= 1000
    order by t.ord limit 8) x;
$$;

-- One field of a suggested edit as readable text, for emails.
create or replace function public._edit_val(k text, v jsonb) returns text
language sql immutable set search_path = '' as $$
  select coalesce(nullif(case
    when k = 'sites' then (select string_agg(t.x, ', ') from jsonb_array_elements_text(case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end) as t(x))
    when k = 'bands' then (select string_agg(trim(coalesce(t.b->>'label', '') || ' ' || (t.b->>'lo') || '–' || (t.b->>'hi') || ' Hz'), ', ')
                           from jsonb_array_elements(case when jsonb_typeof(v) = 'array' then v else '[]'::jsonb end) as t(b))
    when k = 'claimType' then case v #>> '{}' when 'attributed' then 'Stated by the paper' when 'inferred' then 'Used to infer'
      when 'causal' then 'Causal test' when 'hypothesis' then 'Hypothesis' when 'debated' then 'Debated' else v #>> '{}' end
    when k = 'evidence' then case v #>> '{}' when 'human-eeg' then 'Human EEG/ERP' when 'stimulation' then 'Brain or sensory stimulation'
      when 'intracranial' then 'Animal or intracranial' when 'review' then 'Review-level summary' else v #>> '{}' end
    else v #>> '{}' end, ''), '(none)');
$$;

-- Readable names for a suggestion, whether it uses existing records, proposes new ones, or edits a link.
create or replace function public._sub_summary(p jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  with e as (
    select doc from public.kb_records where collection = 'entries' and id = p->>'entryId' and p->>'kind' = 'edit'
  ), ids as (
    select case when p->>'kind' = 'edit' then coalesce((select doc->>'measureId' from e), p->>'measureId') else p->>'measureId' end as mid,
           case when p->>'kind' = 'edit' then (select doc->>'constructId' from e) else p->>'constructId' end as cid,
           case when p->>'kind' = 'edit' then (select doc->>'sourceId' from e) else p->>'sourceId' end as sid
  )
  select jsonb_build_object(
    'kind', coalesce(p->>'kind', 'link'),
    'signal', coalesce(
      (select r.doc->>'name' from public.kb_records r, ids where r.collection = 'measures' and r.id = ids.mid),
      (p->'newMeasure'->>'name') || ' (new signal)', 'Unknown signal'),
    'topic', coalesce(
      (select r.doc->>'name' from public.kb_records r, ids where r.collection = 'constructs' and r.id = ids.cid),
      (p->'newConstruct'->>'name') || ' (new topic)',
      case when p->>'kind' = 'edit' and coalesce(p->>'entryId', '') = '' then 'electrodes and frequency' end, 'Unknown topic'),
    'paper', coalesce(
      (select r.doc->>'cite' from public.kb_records r, ids where r.collection = 'sources' and r.id = ids.sid),
      p->'reference'->>'cite', case when p->>'kind' = 'edit' then '' end, 'Unknown paper'),
    'reason', left(coalesce(p->>'reason', ''), 500),
    'pages', coalesce(p->>'pages', ''),
    'claim', coalesce(p->>'claim', ''),
    'claimType', coalesce(p->>'claimType', ''),
    'evidence', coalesce(p->>'evidence', ''),
    'sites', concat_ws(' ',
      (select string_agg(value, ', ') from jsonb_array_elements_text(public._sites(p->'sites'))),
      case when coalesce(p->>'sitesNote', '') <> '' then '(' || left(p->>'sitesNote', 200) || ')' end),
    'band', coalesce((select trim(coalesce(t.b->>'label', '') || ' ' || (t.b->>'lo') || '–' || (t.b->>'hi') || ' Hz')
                      from jsonb_array_elements(public._band(p->'bands')) as t(b) limit 1), ''));
$$;

-- The changes in a suggested edit, one line each: what the site says now → what is suggested.
create or replace function public._edit_html(p jsonb) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  ch jsonb := case when jsonb_typeof(p->'changes') = 'object' then p->'changes' else '{}'::jsonb end;
  e jsonb; m jsonb; f record; v_out text := '';
begin
  select doc into e from public.kb_records where collection = 'entries' and id = p->>'entryId';
  select doc into m from public.kb_records where collection = 'measures' and id = coalesce(e->>'measureId', p->>'measureId');
  for f in select * from (values
      (1, 'claim', 'What the paper says'), (2, 'pages', 'Page(s)'), (3, 'claimType', 'Link strength'), (4, 'evidence', 'Kind of evidence'),
      (5, 'paradigm', 'Task'), (6, 'population', 'Population'), (7, 'behaviour', 'Behavioural outcome'), (8, 'cites', 'Original studies cited'),
      (9, 'sites', 'Electrodes'), (10, 'sitesNote', 'Location in the paper''s words'), (11, 'bands', 'Frequency range')) as v(n, k, label) order by n
  loop
    if ch ? f.k then
      v_out := v_out || '<br><b>' || f.label || ':</b> ' || public._esc(public._edit_val(f.k, case when f.n <= 8 then e->f.k else m->f.k end))
        || ' → <b>' || public._esc(public._edit_val(f.k, case f.k when 'sites' then public._sites(ch->f.k) when 'bands' then public._bands(ch->f.k) else ch->f.k end)) || '</b>';
    end if;
  end loop;
  return nullif(substr(v_out, 5), '');
end $$;

-- ---------------------------------------------------------------------------
-- New suggestions: fill in who sent it, limit volume, email every admin
-- ---------------------------------------------------------------------------

create or replace function public._before_submission() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in to suggest a link.';
  end if;
  new.submitted_by := auth.uid();
  new.submitter_email := public._user_email(auth.uid());
  if exists (select 1 from public.blocked_emails where email = new.submitter_email) then
    raise exception 'This account is blocked from the EEG Knowledge Base.';
  end if;
  new.created_at := now();
  new.status := 'pending';
  new.review_note := null; new.reviewed_by := null; new.reviewer_email := null; new.reviewed_at := null; new.entry_id := null;
  if (select count(*) from public.submissions
      where submitted_by = new.submitted_by and created_at > now() - interval '1 day') >= 20 then
    raise exception 'You have reached the limit of 20 suggestions a day. Try again tomorrow.';
  end if;
  if new.payload->>'kind' = 'edit' then
    if coalesce(jsonb_typeof(new.payload->'changes'), '') <> 'object' or new.payload->'changes' = '{}'::jsonb then
      raise exception 'The edit has no changes.';
    end if;
    if coalesce(new.payload->>'entryId', '') <> '' then
      if not exists (select 1 from public.kb_records where collection = 'entries' and id = new.payload->>'entryId') then
        raise exception 'That link is no longer on the site.';
      end if;
    elsif not exists (select 1 from public.kb_records where collection = 'measures' and id = new.payload->>'measureId') then
      raise exception 'That EEG signal is no longer on the site.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists submissions_before_insert on public.submissions;
create trigger submissions_before_insert before insert on public.submissions
  for each row execute function public._before_submission();

create or replace function public._after_submission() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  a record;
  v_token text;
  v_link text;
  v_site text := (select value from public.settings where key = 'site_url');
  s jsonb := public._sub_summary(new.payload);
  v_edit boolean := coalesce(new.payload->>'kind', '') = 'edit';
  v_details text;
begin
  perform public._log('submitted', jsonb_build_object('submission', new.id, 'signal', s->>'signal', 'topic', s->>'topic', 'kind', s->>'kind'),
                      new.submitted_by, new.submitter_email);
  if v_edit then
    v_details :=
         '<p><b>EEG signal:</b> ' || public._esc(s->>'signal')
      || case when coalesce(new.payload->>'entryId', '') <> '' then '<br><b>Topic:</b> ' || public._esc(s->>'topic') || '<br><b>Paper:</b> ' || public._esc(s->>'paper') else '' end || '</p>'
      || '<p><b>Changes</b> (on the site now → suggested):<br>' || coalesce(public._edit_html(new.payload), 'none') || '</p>'
      || case when s->>'reason' <> '' then '<p><b>Why:</b> ' || public._esc(s->>'reason') || '</p>' else '' end
      || '<p style="color:#475665;font-size:13.5px">Suggested by ' || public._esc(coalesce(new.submitter_email, 'unknown')) || '</p>';
  else
    v_details :=
         '<p><b>EEG signal:</b> ' || public._esc(s->>'signal') || '<br><b>Topic:</b> ' || public._esc(s->>'topic')
      || '<br><b>Paper:</b> ' || public._esc(s->>'paper') || '<br><b>Page(s):</b> ' || public._esc(s->>'pages')
      || case when s->>'sites' <> '' then '<br><b>Electrodes:</b> ' || public._esc(s->>'sites') else '' end
      || case when s->>'band' <> '' then '<br><b>Frequency range:</b> ' || public._esc(s->>'band') else '' end || '</p>'
      || '<p><b>What the paper says:</b> ' || public._esc(s->>'claim') || '</p>'
      || '<p style="color:#475665;font-size:13.5px">Suggested by ' || public._esc(coalesce(new.submitter_email, 'unknown'))
      || ' · link strength: ' || public._esc(s->>'claimType') || ' · evidence: ' || public._esc(s->>'evidence') || '</p>';
  end if;
  for a in select user_id, email from public.admins loop
    v_token := encode(gen_random_bytes(24), 'hex');
    insert into public.review_tokens (token_hash, submission_id, admin_id, admin_email)
    values (encode(digest(v_token, 'sha256'), 'hex'), new.id, a.user_id, a.email);
    v_link := v_site || '?review=' || v_token;
    perform public._send_email(a.email,
      case when v_edit then 'Suggested edit: ' else 'New suggestion: ' end || (s->>'signal') || ' → ' || (s->>'topic'),
      public._email_page(case when v_edit then 'An edit was suggested' else 'A new link was suggested' end, v_details
        || '<p style="margin:20px 0">'
        || '<a href="' || v_link || '&decision=accept" style="background:#0A6A6A;color:#fff;padding:10px 18px;border-radius:6px;text-decoration:none;font-weight:bold">Accept</a> &nbsp; '
        || '<a href="' || v_link || '&decision=reject" style="background:#fff;color:#AE3D0C;border:1px solid #AE3D0C;padding:9px 17px;border-radius:6px;text-decoration:none;font-weight:bold">Reject</a></p>'
        || '<p style="color:#475665;font-size:13.5px">Each button opens a page on the site where you confirm your choice. '
        || 'The buttons work once and expire after 14 days. You can also review every suggestion on the Admin page.</p>'));
  end loop;
  return new;
end $$;

drop trigger if exists submissions_after_insert on public.submissions;
create trigger submissions_after_insert after insert on public.submissions
  for each row execute function public._after_submission();

-- ---------------------------------------------------------------------------
-- Accepting and rejecting
-- ---------------------------------------------------------------------------

create or replace function public._accept(p_sub uuid, p_actor uuid, p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare
  s public.submissions%rowtype;
  p jsonb;
  mid text; cid text; sid text; eid text;
  v_name text; v_sig text; v_fam text; v_cite text; v_doi text; v_short text; v_surname text; v_year text;
  v_now text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  sm jsonb;
  v_sites jsonb; v_band jsonb; v_snote text; v_spec text;
begin
  select * into s from public.submissions where id = p_sub for update;
  if not found then raise exception 'This suggestion no longer exists.'; end if;
  if s.status <> 'pending' then raise exception 'This suggestion was already %.', s.status; end if;
  p := s.payload;
  if p->>'kind' = 'edit' then return public._accept_edit(s.id, p_actor, p_email); end if;
  v_sites := public._sites(p->'sites');
  v_band := public._band(p->'bands');
  v_snote := left(trim(coalesce(p->>'sitesNote', '')), 200);
  v_spec := concat_ws('; ',
    case when jsonb_array_length(v_sites) > 0 then 'Electrodes: ' || (select string_agg(value, ', ') from jsonb_array_elements_text(v_sites)) end,
    case when jsonb_array_length(v_band) > 0 then trim(coalesce(v_band->0->>'label', '') || ' ' || (v_band->0->>'lo') || '–' || (v_band->0->>'hi') || ' Hz') end);

  -- Paper: an existing one, a matching one (same DOI or citation), or a new record.
  sid := nullif(p->>'sourceId', '');
  if sid is not null and not exists (select 1 from public.kb_records where collection = 'sources' and id = sid) then
    raise exception 'The chosen paper is no longer on the site.';
  end if;
  if sid is null then
    v_cite := trim(coalesce(p->'reference'->>'cite', ''));
    v_doi := trim(coalesce(p->'reference'->>'doi', ''));
    if v_cite = '' then raise exception 'The suggestion has no paper citation.'; end if;
    select id into sid from public.kb_records
      where collection = 'sources' and ((v_doi <> '' and lower(doc->>'doi') = lower(v_doi)) or lower(doc->>'cite') = lower(v_cite))
      limit 1;
    if sid is null then
      v_surname := substring(v_cite from '^([^,(]+),');
      v_year := substring(v_cite from '\((\d{4})');
      v_short := case
        when v_surname is not null and v_year is not null then
          trim(v_surname) || case when v_cite ~ '(&| and |et al)' then ' et al.' else '' end || ' (' || v_year || ')'
        when length(v_cite) > 48 then left(v_cite, 46) || '…'
        else v_cite end;
      sid := 'src-' || left(public._slug(v_cite), 24) || '-' || public._rid();
      insert into public.kb_records (collection, id, doc) values ('sources', sid, jsonb_build_object(
        'short', v_short, 'cite', v_cite, 'title', '', 'venue', '', 'doi', v_doi,
        'year', case when v_year is null then null else v_year::int end,
        'type', 'Contributed reference', 'scope', '', 'note', '', 'order', 500,
        'provenance', 'contributed', 'addedAt', v_now));
    end if;
  end if;

  -- EEG signal.
  mid := nullif(p->>'measureId', '');
  if mid is not null and not exists (select 1 from public.kb_records where collection = 'measures' and id = mid) then
    raise exception 'The chosen EEG signal is no longer on the site.';
  end if;
  if mid is null then
    v_name := trim(coalesce(p->'newMeasure'->>'name', ''));
    if v_name = '' then raise exception 'The suggestion has no EEG signal.'; end if;
    select id into mid from public.kb_records where collection = 'measures' and lower(doc->>'name') = lower(v_name) limit 1;
    if mid is null then
      v_sig := case when p->'newMeasure'->>'signal' in ('time', 'freq', 'phase') then p->'newMeasure'->>'signal' else 'time' end;
      mid := 'm-' || public._slug(v_name) || '-' || public._rid();
      insert into public.kb_records (collection, id, doc) values ('measures', mid, jsonb_build_object(
        'name', v_name, 'short', '', 'aka', '[]'::jsonb,
        'domain', case v_sig when 'freq' then 'Frequency' when 'phase' then 'Frequency / phase' else 'Time (ERP)' end,
        'signal', v_sig, 'spec', coalesce(p->'newMeasure'->>'spec', ''),
        'specRefs', jsonb_build_array(jsonb_build_object('s', sid, 'p', coalesce(p->>'pages', ''))),
        'window', null, 'windowNote', '', 'bands', v_band, 'bandsNote', '', 'sites', v_sites, 'sitesNote', v_snote,
        'inferred', '[]'::jsonb, 'lateralized', false, 'caveats', '[]'::jsonb, 'methods', '[]'::jsonb,
        'feasibility', jsonb_build_object('passive', null, 'infants', null, 'note', '', 'refs', '[]'::jsonb),
        'provenance', 'contributed', 'order', 500, 'addedAt', v_now, 'submissionId', s.id));
    end if;
  end if;
  -- Fill in electrode sites or a frequency range the signal does not have yet (never overwrites existing ones).
  update public.kb_records set
    doc = doc
      || case when jsonb_array_length(v_sites) > 0
               and (case when jsonb_typeof(doc->'sites') = 'array' then jsonb_array_length(doc->'sites') else 0 end) = 0
              then jsonb_build_object('sites', v_sites, 'sitesNote', v_snote) else '{}'::jsonb end
      || case when jsonb_array_length(v_band) > 0
               and (case when jsonb_typeof(doc->'bands') = 'array' then jsonb_array_length(doc->'bands') else 0 end) = 0
              then jsonb_build_object('bands', v_band, 'bandsNote', '') else '{}'::jsonb end,
    updated_at = now()
  where collection = 'measures' and id = mid;

  -- Topic.
  cid := nullif(p->>'constructId', '');
  if cid is not null and not exists (select 1 from public.kb_records where collection = 'constructs' and id = cid) then
    raise exception 'The chosen topic is no longer on the site.';
  end if;
  if cid is null then
    v_name := trim(coalesce(p->'newConstruct'->>'name', ''));
    if v_name = '' then raise exception 'The suggestion has no topic.'; end if;
    select id into cid from public.kb_records where collection = 'constructs' and lower(doc->>'name') = lower(v_name) limit 1;
    if cid is null then
      v_fam := case when p->'newConstruct'->>'family' in ('hearing', 'attention', 'memory', 'language', 'development', 'emotion',
                    'control', 'motor', 'sensory', 'state', 'clinical', 'other') then p->'newConstruct'->>'family' else 'other' end;
      cid := 'c-' || public._slug(v_name) || '-' || public._rid();
      insert into public.kb_records (collection, id, doc) values ('constructs', cid, jsonb_build_object(
        'name', v_name, 'family', v_fam, 'definition', '', 'defRefs', '[]'::jsonb,
        'provenance', 'contributed', 'addedAt', v_now, 'submissionId', s.id));
    end if;
  end if;

  -- The link itself. No email addresses go into public records.
  eid := 'e-c-' || to_char(now(), 'YYMMDDHH24MISS') || public._rid();
  insert into public.kb_records (collection, id, doc) values ('entries', eid, jsonb_build_object(
    'measureId', mid, 'constructId', cid, 'sourceId', sid, 'pages', coalesce(p->>'pages', ''),
    'claim', coalesce(p->>'claim', ''),
    'claimType', case when p->>'claimType' in ('attributed', 'inferred', 'causal', 'hypothesis', 'debated') then p->>'claimType' else 'attributed' end,
    'evidence', case when p->>'evidence' in ('human-eeg', 'stimulation', 'intracranial', 'review') then p->>'evidence' else 'human-eeg' end,
    'paradigm', coalesce(p->>'paradigm', ''), 'population', coalesce(p->>'population', ''),
    'behaviour', coalesce(p->>'behaviour', ''), 'cites', coalesce(p->>'cites', ''), 'specUsed', v_spec,
    'provenance', 'contributed', 'status', 'accepted', 'addedAt', to_char(now(), 'YYYY-MM-DD'), 'submissionId', s.id));

  update public.submissions
    set status = 'accepted', reviewed_by = p_actor, reviewer_email = p_email, reviewed_at = now(), entry_id = eid
    where id = s.id;
  delete from public.review_tokens where submission_id = s.id;

  sm := public._sub_summary(p);
  perform public._log('accepted', jsonb_build_object('submission', s.id, 'entry', eid, 'signal', sm->>'signal', 'topic', sm->>'topic'), p_actor, p_email);
  perform public._send_email(s.submitter_email, 'Your suggestion was accepted',
    public._email_page('Your suggestion was accepted',
      '<p>Your link between <b>' || public._esc(sm->>'signal') || '</b> and <b>' || public._esc(sm->>'topic')
      || '</b> is now on the site. Thank you.</p><p><a href="' || (select value from public.settings where key = 'site_url')
      || '">Open the knowledge base</a></p>'));
  return eid;
end $$;

-- Applies an accepted edit to a link and its signal. An approved edit may replace what is there;
-- the previous versions are kept in the activity list so the edit can be undone.
create or replace function public._accept_edit(p_sub uuid, p_actor uuid, p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare
  s public.submissions%rowtype;
  p jsonb; ch jsonb;
  eid text; mid text; k text;
  e_old jsonb; e_new jsonb; m_old jsonb; m_new jsonb;
  sm jsonb;
  v_today text := to_char(now(), 'YYYY-MM-DD');
begin
  select * into s from public.submissions where id = p_sub;
  p := s.payload;
  ch := case when jsonb_typeof(p->'changes') = 'object' then p->'changes' else '{}'::jsonb end;
  eid := nullif(p->>'entryId', '');
  if eid is not null then
    select doc into e_old from public.kb_records where collection = 'entries' and id = eid;
    if not found then raise exception 'The link this edit changes is no longer on the site.'; end if;
    mid := e_old->>'measureId';
  else
    mid := nullif(p->>'measureId', '');
  end if;
  select doc into m_old from public.kb_records where collection = 'measures' and id = mid;
  if not found then raise exception 'The EEG signal this edit changes is no longer on the site.'; end if;

  -- The link: only these fields, cleaned the same way as new suggestions.
  e_new := e_old;
  if eid is not null then
    foreach k in array array['claim', 'pages', 'paradigm', 'population', 'behaviour', 'cites'] loop
      if ch ? k then
        e_new := e_new || jsonb_build_object(k, left(trim(coalesce(ch->>k, '')), case k when 'claim' then 700 when 'pages' then 40 when 'cites' then 300 else 200 end));
      end if;
    end loop;
    if ch->>'claimType' in ('attributed', 'inferred', 'causal', 'hypothesis', 'debated') then e_new := e_new || jsonb_build_object('claimType', ch->>'claimType'); end if;
    if ch->>'evidence' in ('human-eeg', 'stimulation', 'intracranial', 'review') then e_new := e_new || jsonb_build_object('evidence', ch->>'evidence'); end if;
    if coalesce(e_new->>'claim', '') = '' or coalesce(e_new->>'pages', '') = '' then
      raise exception 'A link needs page numbers and a description of what the paper says.';
    end if;
  end if;

  -- The signal: electrodes, the paper's wording for them, and frequency ranges. Edited values are no longer marked as inferred.
  m_new := m_old;
  if ch ? 'sites' then
    m_new := m_new || jsonb_build_object('sites', public._sites(ch->'sites'),
      'inferred', case when jsonb_typeof(m_new->'inferred') = 'array' then (m_new->'inferred') - 'sites' else '[]'::jsonb end);
  end if;
  if ch ? 'sitesNote' then m_new := m_new || jsonb_build_object('sitesNote', left(trim(coalesce(ch->>'sitesNote', '')), 200)); end if;
  if ch ? 'bands' then
    m_new := m_new || jsonb_build_object('bands', public._bands(ch->'bands'),
      'inferred', case when jsonb_typeof(m_new->'inferred') = 'array' then (m_new->'inferred') - 'bands' else '[]'::jsonb end);
  end if;

  if e_new is not distinct from e_old and m_new is not distinct from m_old then
    raise exception 'This edit no longer changes anything on the site. Reject it instead.';
  end if;
  if e_new is distinct from e_old then
    update public.kb_records set doc = e_new || jsonb_build_object('editedAt', v_today), updated_at = now() where collection = 'entries' and id = eid;
  end if;
  if m_new is distinct from m_old then
    update public.kb_records set doc = m_new || jsonb_build_object('editedAt', v_today), updated_at = now() where collection = 'measures' and id = mid;
  end if;

  update public.submissions
    set status = 'accepted', reviewed_by = p_actor, reviewer_email = p_email, reviewed_at = now(), entry_id = eid
    where id = s.id;
  delete from public.review_tokens where submission_id = s.id;

  sm := public._sub_summary(p);
  perform public._log('edited', jsonb_build_object('submission', s.id, 'signal', sm->>'signal', 'topic', sm->>'topic', 'entry', eid, 'measure', mid,
    'before', jsonb_build_object('entries', case when e_new is distinct from e_old then e_old end, 'measures', case when m_new is distinct from m_old then m_old end)),
    p_actor, p_email);
  perform public._send_email(s.submitter_email, 'Your suggested edit was accepted',
    public._email_page('Your suggested edit was accepted',
      '<p>Your edit to <b>' || public._esc(sm->>'signal') || '</b> → <b>' || public._esc(sm->>'topic')
      || '</b> is now on the site. Thank you.</p><p><a href="' || (select value from public.settings where key = 'site_url')
      || '">Open the knowledge base</a></p>'));
  return coalesce(eid, mid);
end $$;

create or replace function public._reject(p_sub uuid, p_actor uuid, p_email text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare
  s public.submissions%rowtype;
  sm jsonb;
  v_note text := left(trim(coalesce(p_note, '')), 500);
begin
  select * into s from public.submissions where id = p_sub for update;
  if not found then raise exception 'This suggestion no longer exists.'; end if;
  if s.status <> 'pending' then raise exception 'This suggestion was already %.', s.status; end if;
  update public.submissions
    set status = 'rejected', reviewed_by = p_actor, reviewer_email = p_email, reviewed_at = now(), review_note = v_note
    where id = s.id;
  delete from public.review_tokens where submission_id = s.id;
  sm := public._sub_summary(s.payload);
  perform public._log('rejected', jsonb_build_object('submission', s.id, 'signal', sm->>'signal', 'topic', sm->>'topic', 'note', v_note, 'kind', sm->>'kind'), p_actor, p_email);
  perform public._send_email(s.submitter_email,
    case when sm->>'kind' = 'edit' then 'Your suggested edit was not made' else 'Your suggestion was not accepted' end,
    public._email_page(case when sm->>'kind' = 'edit' then 'Your suggested edit was not made' else 'Your suggestion was not accepted' end,
      case when sm->>'kind' = 'edit'
        then '<p>Your edit to <b>' || public._esc(sm->>'signal') || '</b> → <b>' || public._esc(sm->>'topic') || '</b> was reviewed and not made.</p>'
        else '<p>Your link between <b>' || public._esc(sm->>'signal') || '</b> and <b>' || public._esc(sm->>'topic') || '</b> was reviewed and not added.</p>' end
      || case when v_note <> '' then '<p><b>Reviewer''s note:</b> ' || public._esc(v_note) || '</p>' else '' end));
end $$;

-- Called from the Admin page by a signed-in admin.
create or replace function public.accept_submission(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can accept suggestions.'; end if;
  return public._accept(p_id, auth.uid(), public._user_email(auth.uid()));
end $$;

create or replace function public.reject_submission(p_id uuid, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can reject suggestions.'; end if;
  perform public._reject(p_id, auth.uid(), public._user_email(auth.uid()), p_note);
end $$;

-- Called from the page an email button opens. Works without signing in; the token is the proof.
create or replace function public.get_review(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  t public.review_tokens%rowtype;
  s public.submissions%rowtype;
begin
  select * into t from public.review_tokens where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found or t.expires_at < now() or not exists (select 1 from public.admins where user_id = t.admin_id) then
    return jsonb_build_object('ok', false, 'reason',
      'This review link no longer works. The suggestion may already have been reviewed, the link may have expired, or the admin it was sent to has stepped down.');
  end if;
  select * into s from public.submissions where id = t.submission_id;
  return jsonb_build_object('ok', true, 'status', s.status, 'admin_email', t.admin_email,
    'submitted_at', s.created_at, 'submitter_email', s.submitter_email,
    'summary', public._sub_summary(s.payload), 'payload', s.payload);
end $$;

create or replace function public.review_by_token(p_token text, p_decision text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  t public.review_tokens%rowtype;
  eid text;
begin
  select * into t from public.review_tokens where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  if not found or t.expires_at < now() or not exists (select 1 from public.admins where user_id = t.admin_id) then
    raise exception 'This review link no longer works.';
  end if;
  if p_decision = 'accept' then
    eid := public._accept(t.submission_id, t.admin_id, t.admin_email);
    return jsonb_build_object('ok', true, 'status', 'accepted', 'entry', eid);
  elsif p_decision = 'reject' then
    perform public._reject(t.submission_id, t.admin_id, t.admin_email, p_note);
    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;
  raise exception 'Choose accept or reject.';
end $$;

-- ---------------------------------------------------------------------------
-- Admins: who am I, add an admin, cancel an invite, step down
-- ---------------------------------------------------------------------------

create or replace function public.my_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'signed_in', auth.uid() is not null,
    'email', public._user_email(auth.uid()),
    'is_admin', public.is_admin(),
    'is_owner', public.is_owner(),
    'admin_count', case when public.is_admin() then (select count(*) from public.admins) else null end);
$$;

create or replace function public.add_admin(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_user uuid;
  v_site text := (select value from public.settings where key = 'site_url');
begin
  if not public.is_admin() then raise exception 'Only admins can add admins.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  if exists (select 1 from public.blocked_emails where email = v_email) then
    raise exception 'That email is blocked. The owner can unblock it on the Admin page.';
  end if;
  select id into v_user from auth.users where lower(email) = v_email limit 1;
  if v_user is not null then
    if exists (select 1 from public.admins where user_id = v_user) then return 'already'; end if;
    insert into public.admins (user_id, email, added_by) values (v_user, v_email, auth.uid());
    delete from public.admin_invites where lower(email) = v_email;
    perform public._log('admin_added', jsonb_build_object('email', v_email));
    perform public._send_email(v_email, 'You are now an admin of the EEG Knowledge Base',
      public._email_page('You are now an admin',
        '<p>' || public._esc(public._user_email(auth.uid())) || ' made you an admin. You will get an email whenever a link is suggested, '
        || 'and you can accept, reject or delete links and add other admins.</p><p><a href="' || v_site || '">Open the knowledge base</a></p>'));
    return 'added';
  end if;
  insert into public.admin_invites (email, invited_by) values (v_email, auth.uid()) on conflict (email) do nothing;
  perform public._log('admin_invited', jsonb_build_object('email', v_email));
  perform public._send_email(v_email, 'You have been invited to be an admin of the EEG Knowledge Base',
    public._email_page('You have been invited to be an admin',
      '<p>' || public._esc(public._user_email(auth.uid())) || ' invited you to help review the EEG Construct–Measure Knowledge Base.</p>'
      || '<p>Open the site and choose <b>Sign in</b> with this email address (' || public._esc(v_email) || '). '
      || 'You will become an admin as soon as you sign in.</p><p><a href="' || v_site || '">Open the knowledge base</a></p>'));
  return 'invited';
end $$;

create or replace function public.cancel_invite(p_email text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Only admins can manage invites.'; end if;
  if exists (select 1 from public.owners where email = lower(trim(coalesce(p_email, '')))) then
    raise exception 'The owner''s invite cannot be cancelled.';
  end if;
  delete from public.admin_invites where lower(email) = lower(trim(coalesce(p_email, '')));
  perform public._log('invite_cancelled', jsonb_build_object('email', lower(trim(coalesce(p_email, '')))));
end $$;

create or replace function public.step_down() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'You are not an admin.'; end if;
  if public.is_owner() then
    raise exception 'You are the owner, so you stay an admin. Ownership can only be changed in the database.';
  end if;
  if (select count(*) from public.admins) <= 1 then
    raise exception 'You are the only admin. Add another admin before stepping down, so someone can still review suggestions.';
  end if;
  perform public._log('admin_stepped_down', '{}'::jsonb);
  delete from public.review_tokens where admin_id = auth.uid();
  delete from public.admins where user_id = auth.uid();
end $$;

-- ---------------------------------------------------------------------------
-- Owner only: remove an admin, block and unblock emails
-- ---------------------------------------------------------------------------

create or replace function public.remove_admin(p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_user uuid;
begin
  if not public.is_owner() then raise exception 'Only the owner can remove admins.'; end if;
  if exists (select 1 from public.owners where email = v_email) then raise exception 'The owner cannot be removed.'; end if;
  select user_id into v_user from public.admins where lower(email) = v_email limit 1;
  if v_user is null then
    if exists (select 1 from public.admin_invites where lower(email) = v_email) then
      delete from public.admin_invites where lower(email) = v_email;
      perform public._log('invite_cancelled', jsonb_build_object('email', v_email));
      return;
    end if;
    raise exception 'That email is not an admin.';
  end if;
  delete from public.review_tokens where admin_id = v_user;
  delete from public.admins where user_id = v_user;
  perform public._log('admin_removed', jsonb_build_object('email', v_email));
  perform public._send_email(v_email, 'You are no longer an admin of the EEG Knowledge Base',
    public._email_page('You are no longer an admin',
      '<p>The owner of the EEG Construct–Measure Knowledge Base removed you from its admins. You can still sign in and suggest links.</p>'));
end $$;

-- A blocked email cannot sign in or create an account. Anyone signed in with it is signed out
-- (within the hour, when their current access expires), loses admin rights and cannot suggest links.
create or replace function public.block_email(p_email text, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_user uuid;
begin
  if not public.is_owner() then raise exception 'Only the owner can block emails.'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address.'; end if;
  if exists (select 1 from public.owners where email = v_email) then raise exception 'The owner cannot be blocked.'; end if;
  if exists (select 1 from public.blocked_emails where email = v_email) then return 'already'; end if;
  insert into public.blocked_emails (email, note, blocked_by) values (v_email, left(trim(coalesce(p_note, '')), 200), auth.uid());
  delete from public.admin_invites where lower(email) = v_email;
  select id into v_user from auth.users where lower(email) = v_email limit 1;
  if v_user is not null then
    delete from public.review_tokens where admin_id = v_user;
    delete from public.admins where user_id = v_user;
    update auth.users set banned_until = now() + interval '100 years' where id = v_user;
    delete from auth.sessions where user_id = v_user;
  end if;
  perform public._log('blocked', jsonb_build_object('email', v_email));
  return 'blocked';
end $$;

create or replace function public.unblock_email(p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  if not public.is_owner() then raise exception 'Only the owner can unblock emails.'; end if;
  delete from public.blocked_emails where email = v_email;
  if not found then raise exception 'That email is not blocked.'; end if;
  update auth.users set banned_until = null where lower(email) = v_email;
  perform public._log('unblocked', jsonb_build_object('email', v_email));
end $$;

-- Blocked emails cannot create an account, or change an account to that email.
create or replace function public._block_signup() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is not null and exists (select 1 from public.blocked_emails where email = lower(new.email)) then
    raise exception 'This email is blocked from the EEG Knowledge Base.';
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_blocked on auth.users;
create trigger on_auth_user_blocked before insert or update of email on auth.users
  for each row execute function public._block_signup();

-- Someone invited before they had an account, and the owner, become admins when they first sign in.
create or replace function public._claim_invite() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_by uuid;
begin
  select invited_by into v_by from public.admin_invites where lower(email) = lower(new.email) limit 1;
  if found or exists (select 1 from public.owners where email = lower(new.email)) then
    insert into public.admins (user_id, email, added_by) values (new.id, lower(new.email), v_by) on conflict (user_id) do nothing;
    delete from public.admin_invites where lower(email) = lower(new.email);
    insert into public.activity (actor, actor_email, action, detail) values (new.id, lower(new.email), 'admin_joined', '{}'::jsonb);
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created_claim_admin on auth.users;
create trigger on_auth_user_created_claim_admin after insert on auth.users
  for each row execute function public._claim_invite();

-- ---------------------------------------------------------------------------
-- Deleting (with undo) and importing
-- ---------------------------------------------------------------------------

create or replace function public.delete_record(p_collection text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_doc jsonb;
  v_field text := case p_collection when 'measures' then 'measureId' when 'constructs' then 'constructId' when 'sources' then 'sourceId' end;
begin
  if not public.is_admin() then raise exception 'Only admins can delete records.'; end if;
  if p_collection not in ('entries', 'measures', 'constructs', 'sources') then raise exception 'That kind of record cannot be deleted here.'; end if;
  select doc into v_doc from public.kb_records where collection = p_collection and id = p_id;
  if not found then raise exception 'That record is already gone.'; end if;
  if v_field is not null and exists (select 1 from public.kb_records where collection = 'entries' and doc->>v_field = p_id) then
    raise exception 'Links still use this record. Delete those links first.';
  end if;
  if p_collection = 'sources' and exists (
      select 1 from public.kb_records where collection <> 'entries' and doc::text like '%"s": "' || p_id || '"%') then
    raise exception 'Signal notes or guidance still cite this paper.';
  end if;
  delete from public.kb_records where collection = p_collection and id = p_id;
  perform public._log('deleted', jsonb_build_object('collection', p_collection, 'id', p_id,
    'label', coalesce(v_doc->>'name', v_doc->>'short', v_doc->>'claim', p_id), 'doc', v_doc));
end $$;

create or replace function public.restore_record(p_activity bigint) returns void
language plpgsql security definer set search_path = public as $$
declare
  a public.activity%rowtype;
begin
  if not public.is_admin() then raise exception 'Only admins can restore records.'; end if;
  select * into a from public.activity where id = p_activity and action in ('deleted', 'edited');
  if not found then raise exception 'Nothing to restore.'; end if;
  -- Undo an accepted edit: put back the versions from before it.
  if a.action = 'edited' then
    if exists (select 1 from public.activity where action = 'edit_undone' and detail->>'activity' = p_activity::text) then
      raise exception 'That edit was already undone.';
    end if;
    if jsonb_typeof(a.detail->'before'->'entries') = 'object' then
      update public.kb_records set doc = a.detail->'before'->'entries', updated_at = now() where collection = 'entries' and id = a.detail->>'entry';
    end if;
    if jsonb_typeof(a.detail->'before'->'measures') = 'object' then
      update public.kb_records set doc = a.detail->'before'->'measures', updated_at = now() where collection = 'measures' and id = a.detail->>'measure';
    end if;
    perform public._log('edit_undone', jsonb_build_object('activity', p_activity, 'signal', a.detail->>'signal', 'topic', a.detail->>'topic'));
    return;
  end if;
  if exists (select 1 from public.kb_records where collection = a.detail->>'collection' and id = a.detail->>'id') then
    raise exception 'That record is already back.';
  end if;
  insert into public.kb_records (collection, id, doc) values (a.detail->>'collection', a.detail->>'id', a.detail->'doc');
  perform public._log('restored', jsonb_build_object('collection', a.detail->>'collection', 'id', a.detail->>'id', 'label', a.detail->>'label'));
end $$;

-- Loads the starter data (data/kb.json) into an empty database.
create or replace function public.import_kb(p_data jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare
  c text;
  r jsonb;
  n integer := 0;
begin
  if not public.is_admin() then raise exception 'Only admins can import data.'; end if;
  if exists (select 1 from public.kb_records) then
    raise exception 'The database already has records, so nothing was imported.';
  end if;
  foreach c in array array['meta', 'sources', 'guidance', 'measures', 'constructs', 'entries'] loop
    for r in select value from jsonb_array_elements(coalesce(p_data->c, '[]'::jsonb)) loop
      insert into public.kb_records (collection, id, doc) values (c, r->>'id', r - 'id');
      n := n + 1;
    end loop;
  end loop;
  perform public._log('imported', jsonb_build_object('records', n));
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- What the website may use. Row-level security above still limits every row.
-- ---------------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select on public.kb_records to anon, authenticated;
grant select, insert on public.submissions to authenticated;
grant select on public.admins, public.admin_invites, public.activity, public.owners, public.blocked_emails to authenticated;
grant execute on function
  public.is_admin(), public.my_status(), public.get_review(text), public.review_by_token(text, text, text),
  public.accept_submission(uuid), public.reject_submission(uuid, text), public.add_admin(text), public.cancel_invite(text),
  public.step_down(), public.delete_record(text, text), public.restore_record(bigint), public.import_kb(jsonb)
  to anon, authenticated;
-- Owner tools are only for signed-in users (each still checks that the caller is the owner).
revoke execute on function public.is_owner(), public.remove_admin(text), public.block_email(text, text), public.unblock_email(text) from public, anon;
grant execute on function public.is_owner(), public.remove_admin(text), public.block_email(text, text), public.unblock_email(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Internal functions (names starting with _) cannot be called through the API.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like '\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;
