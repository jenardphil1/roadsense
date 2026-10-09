# Migration Plan: Moving coolex_shop to Agila Hosting

This document outlines the steps to move your local TCG shop to the new 5GB / 2GB RAM hosting.

## User Review Required

> [!IMPORTANT]
> **Domain Name Servers (NS):** Since you bought your domain at Hostinger, you need to "point" it to your new host. Check your welcome email from Agila Hosting for **Name Servers** (usually something like `ns1.example.com` and `ns2.example.com`).

## Proposed Changes

### Phase 1: Local Backup (Database & Files)
We need to get your local data ready for upload.

#### [NEW] [db_export.php](file:///f:/UniServerZ/www/coolex_shop/db_export.php)
A script to export your local `pokemon` database into a portable `.sql` file.

#### [NEW] [coolex_shop_upload.zip](file:///f:/UniServerZ/www/coolex_shop/coolex_shop_upload.zip)
We will create a zip file of your project, excluding the `.git` folder and unnecessary logs to keep it under your 5GB limit.

### Phase 2: Domain Setup at Hostinger
Instructions on how to point `coolex.shop` to your new hosting account.

### Phase 3: Hosting Setup (HestiaCP)
1. Login to your new Agila Hosting panel.
2. Create the `coolex.shop` website.
3. Upload the `coolex_shop_upload.zip`.
4. Create a new MySQL database and user.
5. Import your `pokemon_backup.sql`.

### Phase 4: Configuration & Verification
1. Update `application/config/database.php` with your new hosting details.
2. Update `application/config/config.php` with `https://coolex.shop/`.
3. Enable SSL (Free Let's Encrypt) in HestiaCP.

## Open Questions

> [!CAUTION]
> **Name Servers:** Do you have the Name Servers from your Agila Hosting welcome email? Please share them so I can tell you exactly what to copy into Hostinger.

## Verification Plan

### Automated Tests
- Check if `https://coolex.shop` loads without errors.
- Test searching for a card (like "Pikachu") to ensure the database is working.

### Manual Verification
- Log in to the admin panel on the new host.
- Verify that card images in `/assets/` are loading correctly.
