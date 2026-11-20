# RoadSense AI agent instructions

Read `CLAUDE.md` for project architecture, platform separation, and verification commands.

## Using skills

- Use the catalog below to select skills relevant to the task; honor skills explicitly named by the user.
- Open the selected `SKILL.md` before using it and follow its instructions and referenced resources. Resolve relative resources from that skill directory.
- Apply relevant skills automatically; do not load every skill into every task.
- User instructions and host system/developer rules take precedence over skill guidance.
- Skills do not grant tool access, permission for external actions, or authorization to spawn agents.
- If a skill is missing or requires unavailable tools, report the limitation and use an appropriate available approach.
- Local skills are portable with this repository. Machine-installed skills below require the listed installation paths and, for plugins, their connected tools.

## Project skills

| Skill | Instructions |
| --- | --- |
| api-security-testing | [api-security-testing](.agents/skills/api-security-testing/SKILL.md) |
| application-security-testing | [application-security-testing](.agents/skills/application-security-testing/SKILL.md) |
| ci-security-scanning-with-strix | [ci-security-scanning-with-strix](.agents/skills/ci-security-scanning-with-strix/SKILL.md) |
| find-security-vulnerabilities-in-code | [find-security-vulnerabilities-in-code](.agents/skills/find-security-vulnerabilities-in-code/SKILL.md) |
| fix-security-vulnerabilities-with-strix | [fix-security-vulnerabilities-with-strix](.agents/skills/fix-security-vulnerabilities-with-strix/SKILL.md) |
| honey | [honey](.agents/skills/honey/SKILL.md) |
| honey-ccr | [honey-ccr](.agents/skills/honey-ccr/SKILL.md) |
| honey-chat | [honey-chat](.agents/skills/honey-chat/SKILL.md) |
| honey-compress | [honey-compress](.agents/skills/honey-compress/SKILL.md) |
| honey-debt | [honey-debt](.agents/skills/honey-debt/SKILL.md) |
| honey-design | [honey-design](.agents/skills/honey-design/SKILL.md) |
| honey-eco | [honey-eco](.agents/skills/honey-eco/SKILL.md) |
| honey-gain | [honey-gain](.agents/skills/honey-gain/SKILL.md) |
| honey-hive | [honey-hive](.agents/skills/honey-hive/SKILL.md) |
| honey-loop | [honey-loop](.agents/skills/honey-loop/SKILL.md) |
| honey-memory | [honey-memory](.agents/skills/honey-memory/SKILL.md) |
| honey-px | [honey-px](.agents/skills/honey-px/SKILL.md) |
| honey-review | [honey-review](.agents/skills/honey-review/SKILL.md) |
| honey-superpowers | [honey-superpowers](.agents/skills/honey-superpowers/SKILL.md) |
| managed-pentesting-with-strix | [managed-pentesting-with-strix](.agents/skills/managed-pentesting-with-strix/SKILL.md) |
| owasp-top-10-testing | [owasp-top-10-testing](.agents/skills/owasp-top-10-testing/SKILL.md) |
| penetration-testing-with-strix | [penetration-testing-with-strix](.agents/skills/penetration-testing-with-strix/SKILL.md) |
| ui-ux-pro-max | [ui-ux-pro-max](.agents/skills/ui-ux-pro-max/SKILL.md) |
| web-app-penetration-testing | [web-app-penetration-testing](.agents/skills/web-app-penetration-testing/SKILL.md) |

## Machine-installed skills

| Skill | Instructions |
| --- | --- |
| imagegen | [imagegen](C:/Users/jenar/.codex/skills/.system/imagegen/SKILL.md) |
| openai-docs | [openai-docs](C:/Users/jenar/.codex/skills/.system/openai-docs/SKILL.md) |
| skill-creator | [skill-creator](C:/Users/jenar/.codex/skills/.system/skill-creator/SKILL.md) |
| skill-installer | [skill-installer](C:/Users/jenar/.codex/skills/.system/skill-installer/SKILL.md) |
| reverse-engineer-anything | [reverse-engineer-anything](C:/Users/jenar/.agents/skills/reverse-engineer-anything/SKILL.md) |
| plugin-management | [plugin-management](C:/Users/jenar/.codex/plugins/cache/openai-curated-remote/plugin-management/0.1.0/skills/plugin-management/SKILL.md) |
| sites | [sites](C:/Users/jenar/.codex/plugins/cache/openai-curated-remote/sites/1.1.2/skills/sites/SKILL.md) |
| sites-remix | [sites-remix](C:/Users/jenar/.codex/plugins/cache/openai-curated-remote/sites/1.1.2/skills/sites-remix/SKILL.md) |
| create-pet | [create-pet](C:/Users/jenar/.codex/plugins/cache/openai-curated-remote/work-pets/0.1.6/skills/create-pet/SKILL.md) |
| pets | [pets](C:/Users/jenar/.codex/plugins/cache/openai-curated-remote/work-pets/0.1.6/skills/pets/SKILL.md) |
| update-pet | [update-pet](C:/Users/jenar/.codex/plugins/cache/openai-curated-remote/work-pets/0.1.6/skills/update-pet/SKILL.md) |
