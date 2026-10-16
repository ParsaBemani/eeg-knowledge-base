# Switching on sign-in, admins and email approvals

Until this is set up, the site runs from `data/kb.json` and the Contribute page opens GitHub issues. After setup:

- Contributors sign in with their email (a code is emailed to them; no password) and send suggestions from the Contribute page.
- Every admin gets an email for each suggestion, with **Accept** and **Reject** buttons. Each button opens a page on the site where they confirm. Accepted links appear on the site immediately.
- Admins can also review suggestions, delete links (with undo), add other admins and step down from the **Admin** page (under More).
- The last remaining admin cannot step down, so someone can always review suggestions.

Allow about 45 minutes. Everything below is free and done in a web browser.

## What you need

- A **Supabase** account (the database and sign-in): https://supabase.com
- A **Brevo** account (sends the emails): https://www.brevo.com
- An email address to send from. A shared lab address is best, so the system doesn't depend on one person's inbox.

## 1. Create the database

1. Sign in to Supabase and click **New project**.
2. Name it (for example `eeg-knowledge-base`), choose a strong database password and save it somewhere safe, and pick a region near you (for example Canada Central).
3. Wait a minute or two for the project to start.

## 2. Load the setup script

1. In the project, open **SQL Editor** and start a **new query**.
2. Open [`supabase/setup.sql`](supabase/setup.sql) in this repository, copy all of it, paste it into the editor and click **Run**.
3. It should finish with "Success. No rows returned".

## 3. Set up email sending in Brevo

1. Sign in to Brevo.
2. Add and verify your sender address: **Senders, Domains & Dedicated IPs → Senders → Add a sender**. Brevo emails that address a confirmation link.
3. Create an API key: **SMTP & API → API Keys → Generate a new API key**. Copy it; it starts with `xkeysib-`.
4. On the **SMTP** tab of the same page, note the **SMTP server** (`smtp-relay.brevo.com`), **port** (587) and **login**, and generate an **SMTP key**. You need these in step 5.

## 4. Add your personal settings

Back in Supabase **SQL Editor**, start a new query, paste the lines below, replace the three placeholder values, and click **Run**:

```sql
-- 1. The verified sender address from Brevo
update public.settings set value = 'your.sender@example.com' where key = 'sender_email';

-- 2. Your Brevo API key, stored encrypted
select vault.create_secret('PASTE-YOUR-BREVO-API-KEY', 'brevo_api_key');

-- 3. Make yourself the first admin (use the email you will sign in with)
insert into public.admin_invites (email) values ('you@example.com') on conflict do nothing;
insert into public.admins (user_id, email)
  select id, lower(email) from auth.users where lower(email) = 'you@example.com'
  on conflict do nothing;
```

These values stay inside your Supabase project; they are never stored in this repository.

## 5. Configure sign-in emails

In Supabase, open **Authentication**:

1. **URL Configuration → Site URL:** `https://parsabemani.github.io/eeg-knowledge-base/`
2. **Emails → SMTP Settings:** turn on custom SMTP and enter the Brevo values from step 3: host `smtp-relay.brevo.com`, port `587`, your Brevo SMTP login as the username, the SMTP key as the password, and your verified sender address and a sender name.
   Without this, Supabase's built-in email only reaches a handful of addresses an hour.
3. **Emails → Templates:** the site signs people in with a code, not a link. Replace the body of both the **Magic Link** and the **Confirm signup** templates with:

```html
<h2>Your sign-in code</h2>
<p>Enter this code on the EEG Construct–Measure Knowledge Base to sign in:</p>
<p style="font-size:28px;font-weight:bold;letter-spacing:4px">{{ .Token }}</p>
<p>The code expires in one hour. If you did not ask for it, you can ignore this email.</p>
```

Codes are used instead of sign-in links because university email scanners often open links before you do, which uses them up.

## 6. Connect the website

1. In Supabase, open **Project Settings → API Keys** (or **Data API**). Copy the **Project URL** and the **anon / public** key (newer projects call it the **publishable** key).
   Do **not** use the `service_role` or **secret** key; that one must never be shared.
2. On GitHub, open [`config.js`](config.js), click the pencil icon, paste the two values between the quotes:

```js
  supabaseUrl: 'https://YOUR-PROJECT.supabase.co',
  supabaseAnonKey: 'YOUR-ANON-OR-PUBLISHABLE-KEY'
```

3. Click **Commit changes**. The site updates within a couple of minutes.

The anon key is designed to be public. The setup script's security rules decide what it can do: anyone can read the knowledge base, signed-in people can send suggestions, and only admins can change anything.

## 7. Move the data into the database

1. Open the site and click **Sign in** (top right). Enter the email from step 4 and then the code you receive.
2. You should see an **Admin** badge. Open **More → Admin** and click **Import the starter data**. This copies the 99 links from `data/kb.json` into the database.

## 8. Test it

1. Open **More → Contribute** and send a test suggestion.
2. Check your inbox for "New suggestion: …" and click **Accept** or **Reject**, then confirm on the page that opens.
3. On the Admin page, add a second admin by email. They get an invitation and become an admin the first time they sign in.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| No sign-in code arrives | Check spam. Recheck the SMTP settings in step 5 and that the Brevo sender is verified. |
| "Token has expired or is invalid" | Codes expire after an hour and work once; ask for a new one. |
| No suggestion emails | Recheck step 4: the sender address must be the verified one and the Brevo API key must be correct. To replace the key, run `select vault.update_secret((select id from vault.secrets where name = 'brevo_api_key'), 'NEW-KEY');` |
| Emails land in spam | Common for new senders using a free address. Mark them "not spam". A lab or university address with its own domain verified in Brevo delivers best. |
| The site says it is showing a saved copy | The database could not be reached. Free Supabase projects pause after a period of inactivity; restore it from the Supabase dashboard. |
| Every admin lost access | Run part 3 of step 4 again with a new email address. |

## Limits of the free plans

- Supabase's free plan comfortably holds this site's data, but projects pause after about a week with no activity and must be restored by hand.
- Brevo's free plan sends a few hundred emails a day.
