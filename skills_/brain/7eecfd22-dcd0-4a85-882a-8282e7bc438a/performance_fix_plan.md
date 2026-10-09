# Implementation Plan: Fix Store Performance & Lag

You reported that the store is "lagging" or "not displaying anything." My research shows that your local server is taking over **2 seconds** just to send the initial page, which is why it feels broken over the internet.

## User Review Required

> [!IMPORTANT]
> **MySQL Status:**
> I detected that your database (MySQL) might be struggling or unresponsive. This is likely due to the massive amount of **Magic: The Gathering** data recently imported. 

## Proposed Changes

### 1. Stabilize the Database
I will verify the MySQL connection settings and ensure the database is healthy.
- **Action:** Check `application/config/database.php` for the correct port.
- **Action:** Add necessary **Indexes** to your database tables (`mtg_cards`, `store_inventory`). Without indexes, searching millions of rows takes forever.

### 2. Make the Website "Tunnel Friendly"
The website currently expects to be at `http://localhost:81/coolex_shop/`. When accessed through a tunnel, this can cause "lag" because your browser keeps trying to find files on `localhost` instead of the tunnel.
- **Action:** I will make the `base_url` in CodeIgniter dynamic so it automatically adapts to your Cloudflare link.

### 3. Optimize Slow Queries
The current store pages are trying to load too much data at once.
- **Action:** Modify the MTG and Pokemon models to use **pagination** or **limits** (e.g., show only 20 cards at a time instead of hundreds).

### 4. Clear Process Conflicts
You had multiple Cloudflare Tunnels running at once. I have cleared these and will ensure only one clean process starts.

## Open Questions

1. **Did you recently finish the MTG import?** If it crashed halfway, the database might be corrupted or stuck in a long operation.
2. **Are you seeing any specific error messages** on your screen (e.g., "Database Error" or "504 Gateway Timeout")?

## Verification Plan

### Automated Tests
- I will use `Measure-Command` in PowerShell to ensure local response time drops below **200ms**.
- I will verify the tunnel URL again once the local speed is fixed.

### Manual Verification
- You should try refreshing the page after I apply the database indexes.
