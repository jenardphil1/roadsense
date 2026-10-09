# Implementation Plan: ASCII Open World Hub & Tower Conqueror

We will pivot the game from the linear light novel structure into an ASCII-based open-world RPG where the player starts in a **Town Hub** (with NPCs, shops, and doors) and set off to conquer a giant Tower.

## User Review Required

Please review the proposed ASCII Town Hub mechanics and symbols. We will create an immersive grid map representing the town center.

## Proposed Symbols & Legend
- `@` : Player position
- `#` : Stone Walls / Buildings (impassable)
- `.` : Cobble Street / Path (walkable)
- `T` : Trees / foliage (impassable)
- `~` : Fountain water (impassable)
- `N` : NPCs (bumping or stepping on them starts a conversation)
- `D` : Doors / Building Entrances (takes you inside shops/inn via Narrative panel)
- `U` : Tower Entrance Gate (takes you to Tower Floor 1)

---

## Proposed Changes

### 1. UI updates (`index.html` & `styles.css`)
- **[MODIFY] [index.html](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/index.html)**
  - Add a Gold indicator to the top stats bar (`GOLD: 0`).
  - Keep the D-pad and map container, but adjust styles for a larger 15x15 viewport if needed.
- **[MODIFY] [styles.css](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/styles.css)**
  - Add color coding for town tiles (`T` green, `~` light blue, `D` brown, `N` gold, `U` purple).

### 2. Game Core (`game.js`)
- **[MODIFY] [game.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/game.js)**
  - Add `player.gold` and display it in `updateStatsUI()`.
  - Modify `movePlayer(dx, dy)` to handle interactive tiles:
    - Bumping/stepping on `N` (NPC): Look up NPC ID and launch dialog node.
    - Bumping/stepping on `D` (Door): Load shop/inn interface node.
    - Bumping/stepping on `U` (Tower Gate): Prompt the player to enter the Tower.
  - Implement a shop transaction helper to let players buy stat upgrades with Gold.
  - Award Gold when defeating enemies in combat.

### 3. Maps & Data (`map.js` & `story.js` & `enemies.js`)
- **[MODIFY] [map.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/map.js)**
  - Define area `0` as the "Town Hub" map (15x15 grid).
  - Place `T` trees, `~` fountain, `N` NPCs, `D` building doors, and `U` tower gate.
- **[MODIFY] [story.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/story.js)**
  - Replace the old novel introduction with a new town dialogue system.
  - Add shop inventories (Blacksmith, Alchemist, Inn) and NPC scripts.
- **[MODIFY] [enemies.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/enemies.js)**
  - Add gold drops to enemy data.

---

## Verification Plan

### Manual Verification
- Launch the game. The player starts in the Town Hub map.
- Walk around the town using the D-Pad.
- Step on an NPC (`N`) to talk to them.
- Step on a door (`D`) to enter a Shop, purchase an upgrade, and see Gold deduct correctly.
- Step on the Tower Gate (`U`) to enter Floor 1 of the Tower.
