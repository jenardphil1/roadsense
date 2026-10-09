# Implementation Plan - Redirected Import to 'pokemon' Database

Import the `mtg.sql` file into the existing `pokemon` database instead of creating a new `mtg` database.

## Proposed Changes

### SQL File Modification
- Modify `mtg.sql` to change the target database from `mtg` to `pokemon`.
- Specifically, update `USE mtg;` to `USE pokemon;` and ensure `CREATE DATABASE` doesn't overwrite anything unwanted.

### Database Import
- Run the import command using port **3307** and password **root**:
  `cmd /c "f:\UniServerZ\core\mysql\bin\mysql.exe -h 127.0.0.1 -P 3307 -u root -proot < f:\UniServerZ\www\coolex_shop\assets\mtg.sql"`

## Verification Plan

### Automated Verification
- Run `SELECT COUNT(*) FROM pokemon.mtg_cards_raw;` to confirm data was imported into the correct database.
- Check for existing tables in `pokemon` to ensure no damage was done.

### Manual Verification
- None required.
