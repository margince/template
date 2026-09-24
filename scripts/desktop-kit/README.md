# Margince @@VERSION@@

Margince in one folder. It brings its own database and web server. It writes
nothing outside this folder and needs no internet connection.

<!--MACOS-->
## First, let macOS open it

This folder was downloaded, so macOS has marked every file in it and will refuse
the first one you open — a dialog saying it cannot be verified. Margince carries
an ad-hoc signature rather than a registered developer's, and that dialog is
what it means.

**Right-click @@SETUP@@, choose Open, then confirm.** Once, for that one file:
@@SETUP@@ clears the mark from the rest of the folder, so @@START@@ and
everything behind it open normally afterwards.
<!--/MACOS-->

<!--SETUP-->
## Set it up, once

Double-click **@@SETUP@@** before the first start.

It generates the keys this installation seals its credentials with, and asks for
the two shared ones — a model provider key and your Google app. For the provider
it offers a choice of OpenRouter or Google Gemini, and asks only for the one you
pick. Leave anything blank to skip it; you can run this again at any time.

It has to run **before** the first start. Margince decides its currency, its
timezone and its admin address on that first start and keeps them for good, so
setting them afterwards means deleting `data@@SEP@@` and beginning again.
<!--/SETUP-->

## Start it

Double-click **@@START@@**.

A terminal window opens. That window is Margince, so leave it open. Press Ctrl-C
in it to stop.

The first start takes about a minute. It prints your sign-in password:

    admin@demo.test / <the password it prints>

Your browser opens. If it does not, go to http://127.0.0.1:8800.

<!--CONNECT-->
## Connect it to Claude

Margince can be a connector in Claude or ChatGPT: the agent reads and writes
your records through Margince's own tool surface.

An agent runs on someone else's machine, so it can only reach an installation
that has a public address. Double-click **@@CONNECT@@** instead of
**@@START@@**. It opens one, turns the connector on, and prints the address to
paste into Claude:

    Settings -> Connectors -> Add custom connector

Sign in on that address, as you do here, and approve the connection. Then stop
Margince the way you always do; Ctrl-C closes the tunnel with it.

It needs no account and asks for nothing. The tunnel is
[cloudflared](https://developers.cloudflare.com/cloudflare-tunnel/), which it
downloads the first time.

**The address is temporary.** It changes each time, and the connector has to be
added again each time. For one that never changes you need a reserved domain,
which means [ngrok](https://ngrok.com) and its free account: put the domain in
`margince.env` as `NGROK_DOMAIN=` and the token as `NGROK_AUTHTOKEN=`, and this
switches over on its own.

**A public address publishes the whole installation, not just the connector.**
The sign-in page is on it too — it has to be, because approving the agent is a
browser sign-in on that address. Anyone who has the URL reaches your login page.
Treat it as private, and run @@CONNECT@@ only while you are using it.

<!--/CONNECT-->
<!--SEEDED-->
## It already has the demo data

This folder arrives with the demo already in it — companies, people, deals and
mailboxes. There is nothing to load.

Sign in with:

    admin@demo.test / demo-password-123

The demo colleagues all use the password `1234`.
<!--/SEEDED-->
<!--LOADER-->
## Load the demo data

A new installation is empty. To fill it:

1. Get the demo database folder. It is not in this download — ask your
   administrator for it. The folder contains a `datasets` directory.
2. Copy it into `data@@SEP@@demo@@SEP@@`, inside this folder.
3. Start Margince and leave it running.
4. Double-click **@@LOADER@@**.

This takes a few minutes. When it finishes, sign in with:

    admin@demo.test / demo-password-123

The loader changes the sign-in password, so the first one no longer works. The
demo colleagues all use the password `1234`.

Two options, if you run the loader from a terminal:

- `-limit 25` loads 25 companies instead of all of them.
- `--verify` checks an installation you already loaded. It writes nothing.
<!--/LOADER-->

## What is in the folder

- `@@START@@` — starts Margince.
<!--CONNECT-->
- `@@CONNECT@@` — starts Margince with a public address, for Claude.
<!--/CONNECT-->
<!--LOADER-->
- `@@LOADER@@` — loads the demo data.
<!--/LOADER-->
- `data@@SEP@@` — your database, files and passwords. Back up this folder.
<!--LOADER-->
- `data@@SEP@@demo@@SEP@@` — put the demo database here.
<!--/LOADER-->
- `margince.yaml` — workspace name, currency, time zone.
- `margince.env` — the port and other settings.
- `runtime@@SEP@@` — the programs. An update replaces them.
- `BUILD-INFO.txt` — which build this is. Quote it if you report a problem.

An update replaces the programs only. `data@@SEP@@` — which holds your
records and the demo database — `margince.yaml` and `margince.env` stay as
they are.

## If something goes wrong

<!--LOADER-->
**"Margince is not running."** Start it first and leave its window open. Then
run the loader again.

**The loader stops with a currency error.** The demo data is priced in euros,
and this installation uses another currency. The currency is set on the first
start and cannot be changed later, so you need a new installation: stop
Margince, delete `data@@SEP@@` and `margince.yaml`, set `base_currency: EUR` in
the new `margince.yaml`, and start again.

**Move `data@@SEP@@demo@@SEP@@` somewhere else first, and put it back
afterwards.** The demo database lives inside `data@@SEP@@`, so deleting that
folder deletes the copy you were given — and it is not part of this download,
so nothing here can fetch it again.

**"neither data@@SEP@@admin-password nor the seeded password signs in."** The
password changed after the installation was created. Run the loader from a
terminal with `MARGINCE_SEED_PASSWORD` set to the current password.

**The loader cannot find the demo data.** It must sit in `data@@SEP@@demo@@SEP@@` and
must contain a `datasets` folder.
<!--/LOADER-->
<!--SEEDED-->
**"neither data@@SEP@@admin-password nor demo-password-123 signs in."**
`data@@SEP@@admin-password` is the password this installation generated for
itself, and filling it with the demo replaced that password without rewriting
the file — so the file is out of date and `demo-password-123` is the one that
works. If neither signs in, the password was changed after this folder was
built. Nothing here can recover it: start again from a fresh copy of the
download.

**The AI features answer from a stand-in.** If Setup wrote a model binding for
you, this settles itself on the first start and there is nothing to do. If your
`margince.yaml` was already here when you ran Setup, the binding could not be
added to it — open Settings → AI and bind the tiers there; it opens on your
provider's defaults. Until a tier is bound, the AI surfaces reply with canned
text rather than nothing, which is why they can look like a rejected key.
Everything else in this folder works normally.

**Do not delete `data@@SEP@@`.** Advice for an empty installation says to
delete it and start again. This folder is not empty — the demo database is
inside `data@@SEP@@` and came with the download, so deleting it throws the demo
away and nothing here can rebuild it. Download the folder again instead.
<!--/SEEDED-->
