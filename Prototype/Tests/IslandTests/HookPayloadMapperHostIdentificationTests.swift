import Foundation
import IslandShared
import Testing

@Suite
struct HookPayloadMapperHostIdentificationTests {
    @Test
    func qoderStatisticsSettingsDoNotCreateIDEIdentity() {
        for key in ["QODERCN_DISABLE_STATS", "QODER_CN_DISABLE_STATS", "QODER_DISABLE_STATS"] {
            for value in ["1", "0"] {
                for bundleID: String? in [nil, "com.openai.codex"] {
                    var environment = [key: value]
                    environment["__CFBundleIdentifier"] = bundleID
                    let envelope = makeEnvelope(environment: environment)

                    #expect(envelope.terminalContext.ideName == nil)
                    #expect(envelope.terminalContext.ideBundleID == nil)
                    #expect(envelope.terminalContext.terminalBundleID == bundleID)
                    #expect(envelope.metadata["client_originator"] == nil)
                }
            }
        }
    }

    @Test
    func mixedQoderSettingsDoNotOverrideActualHost() {
        let settings = [
            "QODERCN_DISABLE_STATS": "1",
            "QODER_CN_DISABLE_STATS": "0",
            "QODER_DISABLE_STATS": "1",
            "QODERCN_MODEL": "example-model",
            "QODER_CONFIG_DIR": "/tmp/qoder-config"
        ]
        for (hostEnvironment, expectedIDE, expectedBundleID) in [
            ([:], nil, nil),
            (["__CFBundleIdentifier": "com.openai.codex"], nil, "com.openai.codex"),
            (["TERM_PROGRAM": "vscode"], "VS Code", "com.microsoft.VSCode"),
            (["TERM_PROGRAM": "vscode", "CURSOR_TRACE_ID": "trace-1"], "Cursor", "com.todesktop.230313mzl4w4u92"),
            (["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "terminal-1"], nil, "com.googlecode.iterm2")
        ] as [([String: String], String?, String?)] {
            let envelope = makeEnvelope(environment: settings.merging(hostEnvironment) { _, hostValue in hostValue })

            #expect(envelope.terminalContext.ideName == expectedIDE)
            #expect(envelope.terminalContext.terminalBundleID == expectedBundleID)
            #expect(envelope.metadata["client_originator"] == expectedIDE)
        }
    }

    @Test
    func explicitQoderBundlesRemainRecognizedWithMixedStatisticsSettings() {
        for (bundleID, name) in [
            ("com.qoder.ide", "Qoder IDE"),
            ("com.aliyun.lingma.ide", "Qoder CN IDE")
        ] {
            let envelope = makeEnvelope(environment: [
                "TERM_PROGRAM": "vscode",
                "__CFBundleIdentifier": bundleID,
                "QODERCN_DISABLE_STATS": "1",
                "QODER_CN_DISABLE_STATS": "0",
                "QODER_DISABLE_STATS": "1"
            ])

            #expect(envelope.terminalContext.ideName == name)
            #expect(envelope.terminalContext.ideBundleID == bundleID)
            #expect(envelope.terminalContext.terminalBundleID == bundleID)
        }
    }

    @Test
    func qoderIDEIPCRemainsRecognizedWithoutBundleIdentifier() {
        for ipcKey in ["VSCODE_GIT_IPC_HANDLE", "VSCODE_IPC_HOOK_CLI", "VSCODE_GIT_ASKPASS_MAIN"] {
            for (appName, bundleID, name) in [
                ("Qoder IDE", "com.qoder.ide", "Qoder IDE"),
                ("Qoder CN", "com.aliyun.lingma.ide", "Qoder CN IDE"),
                ("Qoder CN IDE", "com.aliyun.lingma.ide", "Qoder CN IDE")
            ] {
                let envelope = makeEnvelope(environment: [
                    "TERM_PROGRAM": "vscode",
                    ipcKey: "/Applications/\(appName).app/Contents/Resources/app/ide-ipc",
                    "QODERCN_DISABLE_STATS": "0",
                    "QODER_DISABLE_STATS": "1"
                ])

                #expect(envelope.terminalContext.ideName == name)
                #expect(envelope.terminalContext.ideBundleID == bundleID)
                #expect(envelope.terminalContext.terminalBundleID == bundleID)
            }
        }
    }

    @Test
    func qoderNamesInVersionAndWorkspaceValuesAreNotHostEvidence() {
        let versionEnvelope = makeEnvelope(environment: ["TERM_PROGRAM_VERSION": "com.qoder.ide"])
        #expect(versionEnvelope.terminalContext.ideName == nil)
        #expect(versionEnvelope.terminalContext.terminalBundleID == nil)

        let workspaceEnvelope = makeEnvelope(environment: [
            "TERM_PROGRAM": "vscode",
            "VSCODE_CWD": "/tmp/Qoder CN.app/project"
        ])
        #expect(workspaceEnvelope.terminalContext.ideName == "VS Code")
        #expect(workspaceEnvelope.terminalContext.terminalBundleID == "com.microsoft.VSCode")
    }

    @Test
    func externalTerminalBundleWinsOverInheritedQoderIPC() {
        let envelope = makeEnvelope(environment: [
            "TERM_PROGRAM": "iTerm.app",
            "ITERM_SESSION_ID": "terminal-1",
            "VSCODE_GIT_IPC_HANDLE": "/Applications/Qoder CN.app/Contents/Resources/app/ide-ipc",
            "QODERCN_DISABLE_STATS": "1",
            "QODER_DISABLE_STATS": "0"
        ])

        #expect(envelope.terminalContext.terminalBundleID == "com.googlecode.iterm2")
        #expect(envelope.terminalContext.iTermSessionID == "terminal-1")
        #expect(envelope.metadata["terminal_bundle_id"] == "com.googlecode.iterm2")
    }

    private func makeEnvelope(environment: [String: String]) -> BridgeEnvelope {
        HookPayloadMapper.makeEnvelope(
            source: .codex,
            arguments: ["island-bridge", "--source", "codex"],
            environment: environment,
            stdinData: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"host-identification"}"#.utf8)
        )
    }
}
