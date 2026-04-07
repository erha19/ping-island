import Foundation
import AppKit

/// 检测用户当前工作目录的优先级：
/// 1. 前台终端 (iTerm2/Terminal) 当前目录
/// 2. Finder 窗口当前路径
/// 3. 最近访问的目录
/// 4. 默认桌面目录
final class DirectoryDetector {
    static let shared = DirectoryDetector()
    
    private let fileManager = FileManager.default
    
    private init() {}
    
    /// 获取当前工作目录
    func detectCurrentDirectory() -> String {
        // 1. 优先检测前台终端
        if let terminalDir = detectTerminalDirectory() {
            return terminalDir
        }
        
        // 2. 检测 Finder 窗口
        if let finderDir = detectFinderDirectory() {
            return finderDir
        }
        
        // 3. 回退到桌面
        return NSHomeDirectory() + "/Desktop"
    }
    
    /// 检测前台终端的当前目录
    private func detectTerminalDirectory() -> String? {
        // 先尝试 iTerm2
        if let itermDir = getITermDirectory() {
            return itermDir
        }
        
        // 再尝试 Terminal
        if let terminalDir = getTerminalDirectory() {
            return terminalDir
        }
        
        return nil
    }
    
    private func getITermDirectory() -> String? {
        let script = """
        tell application "iTerm2"
            activate
            if (count of windows) > 0 then
                tell current session of current window
                    return pwd
                end tell
            end if
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil {
                return result.stringValue
            }
        }
        return nil
    }
    
    private func getTerminalDirectory() -> String? {
        let script = """
        tell application "Terminal"
            if (count of windows) > 0 then
                return do shell script "pwd"
            end if
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil {
                return result.stringValue
            }
        }
        return nil
    }
    
    /// 检测 Finder 当前窗口路径
    private func detectFinderDirectory() -> String? {
        let script = """
        tell application "Finder"
            if (count of windows) > 0 then
                return POSIX path of (target of front window as alias)
            end if
        end tell
        """
        
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil, let path = result.stringValue, !path.isEmpty {
                return path
            }
        }
        return nil
    }
    
    /// 扫描常见项目目录
    func scanProjectDirectories() -> [String] {
        let projectRoots = [
            NSHomeDirectory() + "/code",
            NSHomeDirectory() + "/projects",
            NSHomeDirectory() + "/workspace",
            NSHomeDirectory() + "/Develop",
            NSHomeDirectory() + "/island",
        ]
        
        var directories: [String] = []
        
        for root in projectRoots {
            if fileManager.fileExists(atPath: root) {
                do {
                    let contents = try fileManager.contentsOfDirectory(atPath: root)
                    for item in contents {
                        let fullPath = (root as NSString).appendingPathComponent(item)
                        var isDirectory: ObjCBool = false
                        if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue {
                            // 跳过隐藏目录
                            if !item.hasPrefix(".") {
                                directories.append(fullPath)
                            }
                        }
                    }
                } catch {
                    continue
                }
            }
        }
        
        return directories.sorted()
    }
}