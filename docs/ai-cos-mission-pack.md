# AI-COS Mission Pack

Ping Island can hand an **AI-COS protocol prompt** to an installed Integration agent:

1. Configure the protocol root under **Settings → Integration → AI-COS 技能路径**.
2. Choose an installed Integration agent under **AI-COS 启动目标** (Settings and/or the Mission panel; both write `AICOS.launchTargetProfileID.v1`).
3. Open the Island, tap the **flag** icon to the left of mute in the opened header, choose **L1 / L2 / L3** and confirm the agent, then click **Copy Protocol & Open [agent]**.

Island then:

- copies a paste-ready prompt that includes the selected protocol, a short summary, and that level’s default reading paths
- opens or focuses the selected agent

Paste once in that agent, then type the actual task there. This flow does not install skills into agent skill directories.

Protocol title, summary, and clipboard scaffolding follow **Settings → General → Language** (简体中文 / English / System).

## Protocol / skills root

Configure under **Settings → Integration → AI-COS 技能路径**.

Default root (when present):

`~/wiki/claude-obsidian/.worktrees/ai-cos-execution-protocol/ai-cos`

The chosen folder must contain `PROTOCOL.md`. The path is stored under UserDefaults key `AICOS.protocolRootPath.v1`.

## Code map

| Piece | Path |
| --- | --- |
| Models | `PingIsland/Models/AICOSMissionModels.swift` |
| Catalog / pack / launch target / activation | `PingIsland/Services/AICOS/` |
| UI | `PingIsland/UI/Views/AICOSMissionPanelView.swift` |
| Entry | Opened-header flag in `NotchView.swift`; panel host in `SessionListView.swift`; skills path and launch target in Settings → Integration (`SettingsWindowView`) |
| Docs / agent routing | `AGENTS.md`, this file |
| Prototype text-shape tests | `Prototype/Sources/IslandShared/AICOSMissionPack.swift` |

## Out of scope (v1)

- Auto-injecting the prompt into a new Codex app-server thread
- Writing `AI_COS_MISSION.md` into a workspace
- Full AI-COS state machine (`NEEDS_CLARIFICATION` write-back)
