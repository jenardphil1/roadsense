# Implementation Plan - Lorcana & One Piece UI Modernization

Modernize the Lorcana and One Piece card detail pages to match the premium "white panel" design language established for Pokémon and MTG. This also includes standardizing breadcrumb alignment across all category pages to ensure visual stability.

## Proposed Changes

### [Lorcana Modernization]

#### [MODIFY] [view_lorcana_card.php](file:///f:/UniServerZ/www/coolex_shop/application/views/store/view_lorcana_card.php)
- Replace the `.glass-card` layout with the `.product-container` white panel.
- Implement the baseline-aligned pricing row with a 40px gap and `Live Market Price` label.
- Standardize the quantity stepper and "Add to Cart" button to 60px height on the same row.
- Move breadcrumbs outside the container with `px-4 px-md-5` padding.

#### [MODIFY] [lorcana_index.php](file:///f:/UniServerZ/www/coolex_shop/application/views/store/lorcana_index.php)
- Standardize breadcrumb padding to `px-4 px-md-5`.
- Simplify breadcrumb to `Store / Disney Lorcana TCG`.

#### [MODIFY] [view_lorcana_set.php](file:///f:/UniServerZ/www/coolex_shop/application/views/store/view_lorcana_set.php)
- Standardize breadcrumb and header padding to `px-4 px-md-5`.

---

### [One Piece Modernization]

#### [MODIFY] [view_onepiece_card.php](file:///f:/UniServerZ/www/coolex_shop/application/views/store/view_onepiece_card.php)
- Replace the `.glass-card` layout with the `.product-container` white panel.
- Implement the baseline-aligned pricing row.
- Standardize the quantity stepper and "Add to Cart" button to 60px height.
- Update stats section (Cost, Power, Counter) and color badges to match the premium aesthetic.
- Move breadcrumbs outside the container with `px-4 px-md-5` padding.

#### [MODIFY] [onepiece_index.php](file:///f:/UniServerZ/www/coolex_shop/application/views/store/onepiece_index.php)
- Standardize breadcrumb padding to `px-4 px-md-5`.
- Simplify breadcrumb to `Store / One Piece TCG`.

#### [MODIFY] [view_onepiece_set.php](file:///f:/UniServerZ/www/coolex_shop/application/views/store/view_onepiece_set.php)
- Standardize breadcrumb and header padding to `px-4 px-md-5`.

## Verification Plan

### Automated Tests
- Use the browser subagent to verify navigation stability across all 4 TCG categories.
- Verify that the "Add to Cart" buttons and quantity steppers are correctly aligned and functional.

### Manual Verification
- Navigating between Store -> Category -> Set -> Card to ensure breadcrumbs never "jump" horizontally.
- Verifying the price layout responsiveness when simulating large prices (e.g. ₱10,000).
