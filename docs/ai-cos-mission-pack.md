# AI-COS Mission Pack

Ping Island can hand an **AI-COS protocol prompt** to an installed Integration agent:

1. Configure the protocol root under **Settings → Integration → AI-COS 技能路径**.
2. Choose an installed Integration agent under **AI-COS 启动目标** (Settings and/or the Mission panel; both write `AICOS.launchTargetProfileID.v1`).
3. Open the Island, tap the **flag** icon to the left of mute in the opened header, choose **L1 / L2 / L3** and confirm the agent, then click **Copy Protocol & Open [agent]**.
4. Optional dedicated entry: **投资决策 / Investment Decision** always packs **L3** plus the decision skill (`SKILL.md` + `references/investment-adapter.md`), then opens the same selected agent.

Island then:

- copies a paste-ready prompt that includes the selected protocol, a short summary, and that level’s default reading paths
- for Investment Decision, also lists the decision skill paths and investment-safety constraints (user confirmation required; no orders / broker connection)
- opens or focuses the selected agent

Paste once in that agent, then type the actual task there. This flow does not install skills into agent skill directories.

Protocol title, summary, and clipboard scaffolding follow **Settings → General → Language** (简体中文 / English / System).

## Protocol / skills root

Configure under **Settings → Integration → AI-COS 技能路径**.

Default root (when present):

`~/wiki/claude-obsidian/.worktrees/ai-cos-execution-protocol/ai-cos`

The chosen folder must contain `PROTOCOL.md`. The path is stored under UserDefaults key `AICOS.protocolRootPath.v1`.

## Decision skill root (Investment Decision)

Default root (when present):

`~/wiki/claude-obsidian/skills/decision`

Required files: `SKILL.md` and `references/investment-adapter.md`. Optional override key: `AICOS.decisionSkillRootPath.v1`.

## Code map

| Piece | Path |
| --- | --- |
| Models | `PingIsland/Models/AICOSMissionModels.swift` |
| Catalog / pack / launch target / activation | `PingIsland/Services/AICOS/` |
| Decision skill path | `PingIsland/Services/AICOS/AICOSDecisionSkillCatalog.swift` |
| UI | `PingIsland/UI/Views/AICOSMissionPanelView.swift` |
| Entry | Opened-header flag in `NotchView.swift`; panel host in `SessionListView.swift`; skills path and launch target in Settings → Integration (`SettingsWindowView`) |
| Docs / agent routing | `AGENTS.md`, this file |
| Prototype text-shape tests | `Prototype/Sources/IslandShared/AICOSMissionPack.swift` |

## Out of scope (v1)

- Auto-injecting the prompt into a new Codex app-server thread
- Writing `AI_COS_MISSION.md` into a workspace
- Full AI-COS state machine (`NEEDS_CLARIFICATION` write-back)
- Settings UI for choosing the decision skill root (override via UserDefaults only)
