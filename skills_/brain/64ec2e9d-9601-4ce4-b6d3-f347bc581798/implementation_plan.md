# Pokemon TCG Viewer Implementation Plan

## Goal Description
Build a beautiful UI in CodeIgniter 3 to display Pokemon TCG sets and cards using the local JSON data provided in `pokemon-tcg-data`. The UI will feature a modern, responsive design with grid layouts, utilizing glassmorphism and vibrant styling for a premium feel.

## Proposed Changes

### Configuration
#### [MODIFY] [routes.php](file:///f:/UniServerZ/www/pokemon/application/config/routes.php)
- Set default controller to `pokemon`.

### Controller Layer
#### [NEW] [Pokemon.php](file:///f:/UniServerZ/www/pokemon/application/controllers/Pokemon.php)
- Creates a `Pokemon` controller.
- `index()`: fetches all sets from the model and loads the `sets` view.
- `cards($set_id)`: fetches cards for a specific set from the model and loads the `cards` view.

### Model Layer
#### [NEW] [Pokemon_model.php](file:///f:/UniServerZ/www/pokemon/application/models/Pokemon_model.php)
- Defines methods to interact with the local JSON files.
- `get_sets()`: reads `pokemon-tcg-data-master/pokemon-tcg-data-master/sets/en.json` and decodes it.
- `get_cards_by_set($set_id)`: reads `pokemon-tcg-data-master/pokemon-tcg-data-master/cards/en/{$set_id}.json` and decodes it.

### View Layer
#### [NEW] [header.php](file:///f:/UniServerZ/www/pokemon/application/views/templates/header.php)
- HTML5 boilerplate with beautiful custom CSS to establish a premium app feel (custom fonts, dynamic backgrounds).
#### [NEW] [footer.php](file:///f:/UniServerZ/www/pokemon/application/views/templates/footer.php)
- Close out HTML.
#### [NEW] [sets.php](file:///f:/UniServerZ/www/pokemon/application/views/pokemon/sets.php)
- UI to display a grid of all available sets (showing set logo/symbol, name, and release date). Interactive cards with hover micro-animations.
#### [NEW] [cards.php](file:///f:/UniServerZ/www/pokemon/application/views/pokemon/cards.php)
- UI to display a grid of cards from the selected set. Includes a "Back to Sets" button and beautiful card presentations.

## Verification Plan

### Automated Tests
- Load `http://localhost:81/pokemon/index.php/pokemon/` and confirm data renders from the local JSON.
- Click a card and verify the details and `tcgplayer` market price loads correctly via the real-time TCGDex API.

### Manual Verification
- Visual inspection of layouts, typography, and image loading.
- Verify fallback UI mechanisms if images or prices are missing.

---

## Phase 3: Auto-Sync Data Feature
Create a feature for the user to automatically synchronize the TCG database directly from the browser without opening a computer terminal.

### 1. Backend PHP Migration (Native Scraper)
- Translate the `download_tcgdex.py` logic directly into a native `sync_data()` method inside the CodeIgniter `Pokemon` Controller.
- **Optimization:** The PHP script will check if a set's `.json` file already exists on the hard drive. If it does, it skips it! This takes the sync time down from 15 minutes to literally **1 second** because it will only download brand-new sets that just released.

### 2. Frontend Sync Button
- Add a beautiful "Sync Data" button to the main navigation bar in `header.php`.
- Add an AJAX fetch request so clicking the button shows a loading spinner, silently hits the `/pokemon/sync_data` route, and then alerts the user when the download is complete so they can refresh the page.
- Click on a set (e.g., Base Set) and verify that it navigates to the Cards page.
- Ensure all images load and the general aesthetic matches the premium requirement.
