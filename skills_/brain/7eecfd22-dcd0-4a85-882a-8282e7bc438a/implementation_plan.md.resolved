# Ecommerce-Style Store Landing Redesign

This plan outlines the steps to transform the current `Store/index` page from a simple category list into a high-conversion ecommerce landing page, featuring a "Best Sellers" card slider and premium category banners.

## Proposed Changes

### [Store Component]

#### [MODIFY] [Store_model.php](file:///f:/UniServerZ/www/coolex_shop/application/models/Store_model.php)
- Add `get_featured_cards($limit = 6)`: This method will query the `store_inventory` table to find a diverse selection of cards across all categories (Pokemon, Magic, One Piece, Lorcana) that are currently in stock.
- It will join with the respective card tables to get images and names.

#### [MODIFY] [Store.php](file:///f:/UniServerZ/www/coolex_shop/application/controllers/Store.php)
- Update `index()` method:
    - Call `Store_model->get_featured_cards()`.
    - Pass the featured cards data to the `store/landing` view.

#### [MODIFY] [modern.css](file:///f:/UniServerZ/www/coolex_shop/assets/css/modern.css)
- Add `.banner-category`: Large, responsive banner cards with background images and centered text.
- Add `.product-card-sm`: Smaller, compact card styles for the "Best Sellers" row.
- Add hover effects for banners and product items.

#### [MODIFY] [landing.php](file:///f:/UniServerZ/www/coolex_shop/application/views/store/landing.php)
- Implement the "Best Sellers" section at the top using a responsive grid/row.
- Implement the "Explore Categories" section below with large, thematic banners for:
    - Disney Lorcana
    - Magic: The Gathering
    - One Piece TCG
    - Pokemon TCG
    - Custom Merchandise

## Open Questions

- **Banners Content**: For the category banners, should I use static high-quality images from the web (e.g., promotional TCG art) or try to pull dynamic card art?
  - *Recommendation*: Use curated high-quality static assets or CSS gradients with TCG logos for a cleaner "Storefront" look, similar to the reference image provided.

## Verification Plan

### Automated Tests
- N/A (Visual/Browser based)

### Manual Verification
- Use the browser tool to navigate to `http://localhost:81/coolex_shop/index.php/Store`.
- Verify the "Best Sellers" section loads cards from different categories.
- Verify the banners are responsive and lead to the correct category indices.
- Verify the overall aesthetic matches the "premium ecommerce" feel.
