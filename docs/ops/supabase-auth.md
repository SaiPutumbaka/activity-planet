# Supabase Auth settings for the product app

These are dashboard settings (Authentication section) that Claude's MCP access cannot change. Apply
them to **staging** (`activity-planet-staging`, `gzrscndzzggxmcwnvvcq`) first so the local app can be
tested end to end, then to **production** (`gtesfiqxqontescqpllo`) before the week-3 build goes live.

## 1. URL configuration

| Setting | Staging | Production |
| --- | --- | --- |
| Site URL | `http://localhost:3001` | `https://app.activityplanet.app` |
| Redirect URLs | `http://localhost:3001/**` | `https://app.activityplanet.app/**`, `https://activity-planet-app.vercel.app/**`, `http://localhost:3001/**` |

The app sends people to `/auth/confirm` (sign-up, magic link, email change), `/auth/reset` (password
reset) and `/auth/callback` (Google). A redirect that is not on this list silently falls back to the
Site URL and the link fails with "missing its code".

## 2. Email templates (token_hash links)

The default templates use `{{ .ConfirmationURL }}`, which only works in the browser that started the
request. These versions work from any device, including a phone that opens the email while the
sign-up happened on a laptop. In Authentication, Email Templates, replace the link in each:

**Confirm signup**

```html
<h2>Confirm your email</h2>
<p>Tap the link below to finish creating your Activity Planet account.</p>
<p><a href="{{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=email">Confirm email</a></p>
<p>If you didn't create an account, you can ignore this email.</p>
```

**Magic link**

```html
<h2>Your sign-in link</h2>
<p>Tap the link below to sign in to Activity Planet. It expires in an hour.</p>
<p><a href="{{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=email">Sign in</a></p>
```

**Reset password**

```html
<h2>Reset your password</h2>
<p>Tap the link below to choose a new password. It expires in an hour.</p>
<p><a href="{{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=recovery">Choose a new password</a></p>
<p>If you didn't ask for this, you can ignore this email; your password has not changed.</p>
```

**Change email address**

```html
<h2>Confirm your new email</h2>
<p>Tap the link below to confirm the change from {{ .Email }} to {{ .NewEmail }}.</p>
<p><a href="{{ .RedirectTo }}?token_hash={{ .TokenHash }}&type=email_change">Confirm new email</a></p>
```

Subjects: "Confirm your Activity Planet email", "Your Activity Planet sign-in link", "Reset your
Activity Planet password", "Confirm your new email". Sender name "Activity Planet".

## 3. Attack protection and providers

- **Attack Protection**: turn on *Leaked password protection* (HaveIBeenPwned check at sign-up and
  password change). Leave CAPTCHA off until Turnstile keys exist; the week-5 build adds the widget.
- **Providers, Email**: keep *Confirm email* on. Set the minimum password length to 8.
- **Providers, Google**: paste the Web client ID and secret from Google Cloud (founder to-do 4), then
  set `VITE_AUTH_GOOGLE=1` in the app's environment so the button renders.
- **Rate limits**: the defaults are fine for launch.

## 4. SMTP

Supabase's built-in mailer sends at most two emails an hour and only to members of the Supabase
organization, so sign-up on staging works only with the founder's own address until this is done.
In Project Settings, Authentication, SMTP Settings, enter the Resend SMTP credentials
(host `smtp.resend.com`, port 465, user `resend`, password = a Resend API key kept in Resend and
Supabase only). Sender `hello@activityplanet.app` once the domain verifies. Do staging as well as
production so testing is realistic.

## 5. Verify

1. `pnpm dev:app`, open `http://localhost:3001`, create an account with a real inbox.
2. Open the confirmation email on a different device; it must land on `/auth/confirm` and sign in.
3. Finish onboarding; the Home tab should greet you by first name and show your hubs.
4. Sign out, use "Forgot password?", open the email, choose a new password, sign in with it.
5. Sign out, use "Email me a link instead", open the email, confirm you land on Home.
