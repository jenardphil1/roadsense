# RoadSense AI — Claude Project Guidelines

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
- **MANDATORY REVIEW**: Before concluding any task, verify that all Web App files remain intact, independent, and compile cleanly with:
  ```bash
  flutter analyze lib/web_main.dart lib/web_map_screen.dart lib/web_profile_screen.dart
  ```

## 3. Running the Applications Locally
- **Mobile App**:
  ```bash
  flutter run -t lib/main.dart
  ```
- **Web App**:
  ```bash
  flutter run -d chrome -t lib/web_main.dart --web-port 8080
  # Or headless web server:
  flutter run -d web-server -t lib/web_main.dart --web-port 8080 --web-hostname localhost
  ```

## 4. Available Agent Skills in `.claude/skills/`
Claude has direct access to the following skills configured in `.claude/skills/`:

### UI/UX & Design:
- **`ui-ux-pro-max`**: Design intelligence for web, mobile, typography, and color tokens.
- **`honey-design`**: Dense, high-polish CSS and responsive UI styling.

### Security & Penetration Testing (Strix):
- **`find-security-vulnerabilities-in-code`**: White-box AI code review.
- **`fix-security-vulnerabilities-with-strix`**: Remediating and proving vulnerability patches.
- **`penetration-testing-with-strix`**: Full pentest runner across apps and APIs.
- **`application-security-testing`**: Stack-wide AppSec audits.
- **`api-security-testing`**: REST / API endpoint vulnerability testing.
- **`web-app-penetration-testing`**: Web frontend and portal penetration testing.
- **`owasp-top-10-testing`**: OWASP compliance and validation.
- **`ci-security-scanning-with-strix`**: Pipeline scanning and PR review.
- **`managed-pentesting-with-strix`**: Cloud pentesting API integration.

### Token & Code Efficiency (Honey Suite):
- **`honey`**, **`honey-chat`**, **`honey-review`**, **`honey-memory`**, **`honey-superpowers`**, **`honey-loop`**, **`honey-ccr`**, **`honey-px`**, **`honey-eco`**, **`honey-debt`**, **`honey-compress`**, **`honey-gain`**, **`honey-hive`**.
