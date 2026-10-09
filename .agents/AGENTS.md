# Workspace Rules

## 1. Strict Platform Separation & UI Independence
- The **Web App** and **Mobile App** are separate applications with **completely independent UIs**.
- **Web App Codebase**:
  - Entry point: `lib/web_main.dart`
  - Screens: `lib/web_map_screen.dart`, `lib/web_profile_screen.dart`, `lib/admin_dashboard_screen.dart`
  - Reference Source: `/media/jen/NewVolume/ssdd/flutter`
- **Mobile App Codebase**:
  - Entry point: `lib/main.dart`
  - Screens: `lib/map_screen.dart`, `lib/profile_screen.dart`

## 2. Mandatory Verification & Review Directive
- **CRITICAL**: Any changes intended for the Mobile App MUST NEVER touch or alter the Web App files (`lib/web_main.dart`, `lib/web_map_screen.dart`, `lib/web_profile_screen.dart`).
- **MANDATORY REVIEW**: Before concluding any task, verify that all Web App files remain intact, independent, and compile cleanly with `flutter analyze lib/web_main.dart lib/web_map_screen.dart lib/web_profile_screen.dart`.
