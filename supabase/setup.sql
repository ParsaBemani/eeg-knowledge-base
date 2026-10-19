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

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

drop policy if exists "Admins can see admins" on public.admins;
create policy "Admins can see admins" on public.admins for select using (public.is_admin());
drop policy if exists "Admins can see invites" on public.admin_invites;
create policy "Admins can see invites" on public.admin_invites for select using (public.is_admin());
drop policy if exists "Admins can read activity" on public.activity;
create policy "Admins can read activity" on public.activity for select using (public.is_admin());
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

-- Readable names for a suggestion, whether it uses existing records or proposes new ones.
create or replace function public._sub_summary(p jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'signal', coalesce(
      (select doc->>'name' from public.kb_records where collection = 'measures' and id = p->>'measureId'),
      (p->'newMeasure'->>'name') || ' (new signal)', 'Unknown signal'),
    'topic', coalesce(
      (select doc->>'name' from public.kb_records where collection = 'constructs' and id = p->>'constructId'),
      (p->'newConstruct'->>'name') || ' (new topic)', 'Unknown topic'),
    'paper', coalesce(
      (select doc->>'cite' from public.kb_records where collection = 'sources' and id = p->>'sourceId'),
      p->'reference'->>'cite', 'Unknown paper'),
    'pages', coalesce(p->>'pages', ''),
    'claim', coalesce(p->>'claim', ''),
    'claimType', coalesce(p->>'claimType', ''),
    'evidence', coalesce(p->>'evidence', ''));
$$;

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
  new.created_at := now();
  new.status := 'pending';
  new.review_note := null; new.reviewed_by := null; new.reviewer_email := null; new.reviewed_at := null; new.entry_id := null;
  if (select count(*) from public.submissions
      where submitted_by = new.submitted_by and created_at > now() - interval '1 day') >= 20 then
    raise exception 'You have reached the limit of 20 suggestions a day. Try again tomorrow.';
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
  v_details text;
begin
  perform public._log('submitted', jsonb_build_object('submission', new.id, 'signal', s->>'signal', 'topic', s->>'topic'),
                      new.submitted_by, new.submitter_email);
  v_details :=
       '<p><b>EEG signal:</b> ' || public._esc(s->>'signal') || '<br><b>Topic:</b> ' || public._esc(s->>'topic')
    || '<br><b>Paper:</b> ' || public._esc(s->>'paper') || '<br><b>Page(s):</b> ' || public._esc(s->>'pages') || '</p>'
    || '<p><b>What the paper says:</b> ' || public._esc(s->>'claim') || '</p>'
    || '<p style="color:#475665;font-size:13.5px">Suggested by ' || public._esc(coalesce(new.submitter_email, 'unknown'))
    || ' · link strength: ' || public._esc(s->>'claimType') || ' · evidence: ' || public._esc(s->>'evidence') || '</p>';
  for a in select user_id, email from public.admins loop
    v_token := encode(gen_random_bytes(24), 'hex');
    insert into public.review_tokens (token_hash, submission_id, admin_id, admin_email)
    values (encode(digest(v_token, 'sha256'), 'hex'), new.id, a.user_id, a.email);
    v_link := v_site || '?review=' || v_token;
    perform public._send_email(a.email,
      'New suggestion: ' || (s->>'signal') || ' → ' || (s->>'topic'),
      public._email_page('A new link was suggested', v_details
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
begin
  select * into s from public.submissions where id = p_sub for update;
  if not found then raise exception 'This suggestion no longer exists.'; end if;
  if s.status <> 'pending' then raise exception 'This suggestion was already %.', s.status; end if;
  p := s.payload;

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
        'window', null, 'windowNote', '', 'bands', '[]'::jsonb, 'bandsNote', '', 'sites', '[]'::jsonb, 'sitesNote', '',
        'inferred', '[]'::jsonb, 'lateralized', false, 'caveats', '[]'::jsonb, 'methods', '[]'::jsonb,
        'feasibility', jsonb_build_object('passive', null, 'infants', null, 'note', '', 'refs', '[]'::jsonb),
        'provenance', 'contributed', 'order', 500, 'addedAt', v_now, 'submissionId', s.id));
    end if;
  end if;

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
    'behaviour', coalesce(p->>'behaviour', ''), 'cites', coalesce(p->>'cites', ''),
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
  perform public._log('rejected', jsonb_build_object('submission', s.id, 'signal', sm->>'signal', 'topic', sm->>'topic', 'note', v_note), p_actor, p_email);
  perform public._send_email(s.submitter_email, 'Your suggestion was not accepted',
    public._email_page('Your suggestion was not accepted',
      '<p>Your link between <b>' || public._esc(sm->>'signal') || '</b> and <b>' || public._esc(sm->>'topic')
      || '</b> was reviewed and not added.</p>'
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
  delete from public.admin_invites where lower(email) = lower(trim(coalesce(p_email, '')));
  perform public._log('invite_cancelled', jsonb_build_object('email', lower(trim(coalesce(p_email, '')))));
end $$;

create or replace function public.step_down() returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'You are not an admin.'; end if;
  if (select count(*) from public.admins) <= 1 then
    raise exception 'You are the only admin. Add another admin before stepping down, so someone can still review suggestions.';
  end if;
  perform public._log('admin_stepped_down', '{}'::jsonb);
  delete from public.review_tokens where admin_id = auth.uid();
  delete from public.admins where user_id = auth.uid();
end $$;

-- Someone invited before they had an account becomes an admin when they first sign in.
create or replace function public._claim_invite() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_by uuid;
begin
  select invited_by into v_by from public.admin_invites where lower(email) = lower(new.email) limit 1;
  if found then
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
  select * into a from public.activity where id = p_activity and action = 'deleted';
  if not found then raise exception 'Nothing to restore.'; end if;
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
grant select on public.admins, public.admin_invites, public.activity to authenticated;
grant execute on function
  public.is_admin(), public.my_status(), public.get_review(text), public.review_by_token(text, text, text),
  public.accept_submission(uuid), public.reject_submission(uuid, text), public.add_admin(text), public.cancel_invite(text),
  public.step_down(), public.delete_record(text, text), public.restore_record(bigint), public.import_kb(jsonb)
  to anon, authenticated;

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
