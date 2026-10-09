# Store Landing Page Ecommerce Redesign

I have transformed your Store landing page into a premium ecommerce storefront. The new design Prioritizes visual impact and easy navigation across your different TCG categories.

## Key Changes

### 🛒 Best Sellers Slider
Added a new "Best Sellers" section at the top that dynamically pulls your latest in-stock cards from Pokémon and Magic: The Gathering.
- **Dynamic Images**: Automatically pulls high-resolution art from the TCG.io and Scryfall APIs.
- **Hover Effects**: Products lift and glow when you hover over them.
- **Mobile Optimized**: The row becomes a smooth horizontal scroller on smartphones.

### 🖼️ Premium Category Banners
Replaced the old simple category cards with high-impact visual banners.
- **Strategic Layout**: Large banners for Magic, Lorcana, and Pokémon help guide customers.
- **Thematic Visuals**: Each banner uses representative art and a custom color palette (e.g., Deep Crimson for MTG, Golden Yellow for Pokémon).
- **Glassmorphic Overlays**: Modern text effects that remain readable over complex backgrounds.

### 🐛 Bug Fixes
- Fixed a `1054 Unknown column 'cards.image_url'` error that occurred during the redesign by correctly mapping the image data for Pokémon cards.

## Technical Details

- **Controller**: `application/controllers/Store.php` (Updated to fetch featured data).
- **Model**: `application/models/Store_model.php` (Added `get_featured_cards` logic).
- **View**: `application/views/store/landing.php` (Complete UI overhaul).
- **CSS**: `assets/css/modern.css` (Added banner and slider utility classes).

## How to Verify
1.  **Open the Store**: Visit [http://localhost:81/coolex_shop/index.php/Store](http://localhost:81/coolex_shop/index.php/Store).
2.  **Check Featured Cards**: Ensure the top row shows cards that are actually in your inventory.
3.  **Explore Banners**: Click the banners to ensure they lead to the correct category pages.
