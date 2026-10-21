import AppKit
import CoreServices

/// Finder's sidebar Favorites, which every Open/Save dialog shows too. Used to pin a folder for a moment
/// (e.g. the Porting Kit games folder while Porting Kit asks for it) and to unpin it again.
/// The LSSharedFileList API is deprecated but is still what Finder reads; every change is checked by
/// reading the list back, so callers can fall back when macOS ignores it.
enum FinderSidebar {
    private static func favorites() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue()
    }

    private static func items(_ list: LSSharedFileList) -> [(item: LSSharedFileListItem, url: URL)] {
        var seed: UInt32 = 0
        guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] else { return [] }
        let flags = LSSharedFileListResolutionFlags(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return snapshot.compactMap { item in
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL? else { return nil }
            return (item, url)
        }
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func contains(_ url: URL) -> Bool {
        guard let list = favorites() else { return false }
        return items(list).contains { same($0.url, url) }
    }

    /// Adds the folder at the top of Favorites; true only when Finder's list now has it.
    @discardableResult
    static func pin(_ url: URL) -> Bool {
        guard let list = favorites() else { return false }
        if !items(list).contains(where: { same($0.url, url) }) {
            _ = LSSharedFileListInsertItemURL(list, kLSSharedFileListItemBeforeFirst.takeUnretainedValue(), nil, nil, url as CFURL, nil, nil)
        }
        return contains(url)
    }

    /// Removes the folder from Favorites; true when it's gone.
    @discardableResult
    static func unpin(_ url: URL) -> Bool {
        guard let list = favorites() else { return false }
        for entry in items(list) where same(entry.url, url) { LSSharedFileListItemRemove(list, entry.item) }
        return !contains(url)
    }
}
