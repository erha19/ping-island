import Foundation
import AppKit

/// QuickPick 命令项模型
struct QuickPickCommand: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let command: String
    let icon: String
    let description: String
    
    static let defaultCommands: [QuickPickCommand] = [
        QuickPickCommand(
            name: "Claude Code",
            command: "claude code",
            icon: "brain",
            description: "启动 Claude Code 对话"
        ),
        QuickPickCommand(
            name: "Codex",
            command: "codex",
            icon: "terminal",
            description: "启动 Codex CLI"
        ),
        QuickPickCommand(
            name: "Qoder",
            command: "qodercli",
            icon: "hammer",
            description: "启动 Qoder CLI"
        ),
        QuickPickCommand(
            name: "VS Code",
            command: "code .",
            icon: "chevron.left.forwardslash.chevron.right",
            description: "在 VS Code 中打开"
        ),
    ]
}

/// QuickPick 目录项模型
struct QuickPickDirectory: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let name: String
    
    var displayName: String {
        (path as NSString).lastPathComponent
    }
    
    var parentPath: String {
        (path as NSString).deletingLastPathComponent
    }
}

/// 命令执行服务
final class CommandExecutor {
    static let shared = CommandExecutor()
    
    private init() {}
    
    /// 在指定目录执行命令
    func execute(_ command: String, in directory: String, completion: @escaping (Bool) -> Void) {
        // 构建完整的 shell 命令
        let fullCommand = "cd '\(directory)' && \(command) > /dev/null 2>&1 &"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", fullCommand]
        
        do {
            try process.run()
            process.waitUntilExit()
            completion(process.terminationStatus == 0)
        } catch {
            print("Command execution failed: \(error)")
            completion(false)
        }
    }
    
    /// 使用 iTerm2 打开终端并执行命令
    func executeInTerminal(_ command: String, in directory: String) {
        let script = """
        tell application "iTerm2"
            activate
            create window with default profile
            tell current session of current window
                write text "cd '\(directory)'"
                write text "\(command)"
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript error: \(error)")
            }
        }
    }
    
    /// 使用系统终端执行命令
    func executeInSystemTerminal(_ command: String, in directory: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "cd '\(directory)' && \(command)"
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }
}