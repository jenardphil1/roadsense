# Task List: ASCII Open World Hub & Tower Conqueror

- [x] UI & Style Updates
  - [x] Add Gold counter to stats bar in [index.html](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/index.html).
  - [x] Style town tiles (`T`, `~`, `D`, `N`, `U`) with theme colors in [styles.css](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/styles.css).
- [x] Core Engine Refactoring
  - [x] Add `gold` and start player at floor `0` (Town) in [game.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/game.js).
  - [x] Update [game.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/game.js) movement loop to handle:
    - `N` (NPC interaction)
    - `D` (Building/Shop doors)
    - `U` (Tower entry portal)
  - [x] Add shop transaction logic (purchasing upgrades with gold) to narrative choices.
  - [x] Add gold rewards to combat rewards.
- [x] World Map Design
  - [x] Create Town Hub (Floor 0) map in [map.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/map.js) with roads, trees, houses, and gate.
- [x] Interactive Narrative & Shops
  - [x] Create town folk dialogue nodes in [story.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/story.js).
  - [x] Create shop interaction nodes (Blacksmith, Tavern, Inn) in [story.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/story.js).
- [x] Enemy Tuning
  - [x] Add `goldReward` values to all enemies in [enemies.js](file:///C:/Users/jenar/.gemini/antigravity/scratch/tower_manager/enemies.js).
