//
//  SkillVaultUninstaller.swift
//  PingIsland
//
//  Removes a vault skill entry and cleans agent symlinks that pointed at it.
//  External wiki/source directories behind vault hub symlinks are left intact.
//

import Foundation

struct SkillVaultUninstallPreview: Equatable, Sendable {
    var vault_entry_path: String
    var folder_name: String
    var is_vault_symlink: Bool
    var external_target: String?
    var inbound_link_paths: [String]
    var route_keys_to_remove: [String]
}

struct SkillVaultUninstallResult: Equatable, Sendable {
    var removed_vault_entry: Bool
    var removed_inbound_links: Int
    var removed_route_keys: [String]
    var errors: [String]
}

enum SkillVaultUninstaller {
    nonisolated static func preview(
        entry: SkillVaultEntry,
        registry: SkillRouteRegistrySnapshot
    ) -> SkillVaultUninstallPreview {
        let routeKeys = registry.routes.keys.filter { key in
            key == entry.path || entry.inbound_link_paths.contains(key)
        }.sorted()
        return SkillVaultUninstallPreview(
            vault_entry_path: entry.path,
            folder_name: entry.folder_name,
            is_vault_symlink: entry.is_symlink,
            external_target: entry.external_target,
            inbound_link_paths: entry.inbound_link_paths,
            route_keys_to_remove: routeKeys
        )
    }

    /// Removes the vault hub entry and any agent symlinks that target it.
    /// When the vault entry is itself a symlink, only the hub link is removed —
    /// the external target directory is never deleted.
    nonisolated static func uninstall(
        entry: SkillVaultEntry,
        registry: inout SkillRouteRegistrySnapshot,
        fileManager: FileManager = .default
    ) -> SkillVaultUninstallResult {
        var errors: [String] = []
        var removedLinks = 0
        var removedRouteKeys: [String] = []

        for linkPath in entry.inbound_link_paths {
            guard SkillVaultCatalog.isSymlinkPath(linkPath, fileManager: fileManager) else {
                errors.append("Skipped non-symlink inbound path: \(linkPath)")
                continue
            }
            do {
                try fileManager.removeItem(atPath: linkPath)
                removedLinks += 1
            } catch {
                errors.append("Failed to remove link \(linkPath): \(error.localizedDescription)")
            }
        }

        let vaultRemoved: Bool
        do {
            if fileManager.fileExists(atPath: entry.path)
                || SkillVaultCatalog.isSymlinkPath(entry.path, fileManager: fileManager)
            {
                try fileManager.removeItem(atPath: entry.path)
                vaultRemoved = true
            } else {
                vaultRemoved = false
                errors.append("Vault entry missing: \(entry.path)")
            }
        } catch {
            vaultRemoved = false
            errors.append("Failed to remove vault entry \(entry.path): \(error.localizedDescription)")
        }

        let keysToRemove = registry.routes.keys.filter { key in
            key == entry.path || entry.inbound_link_paths.contains(key)
        }
        for key in keysToRemove {
            registry.routes.removeValue(forKey: key)
            removedRouteKeys.append(key)
        }
        removedRouteKeys.sort()

        return SkillVaultUninstallResult(
            removed_vault_entry: vaultRemoved,
            removed_inbound_links: removedLinks,
            removed_route_keys: removedRouteKeys,
            errors: errors
        )
    }
}
