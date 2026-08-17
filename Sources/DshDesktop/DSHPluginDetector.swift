import Foundation

/// Detects the `dsh-desktop-bridge` plugin inside the user's dsh profile.
///
/// The wrapper needs to know four things about the plugin on every launch:
///
///   1. **Installed?** — does the profile's cordis.yml / cordis.patch.yml
///      contain an entry with id `dsh-desktop-bridge`?
///   2. **Version** — what version does the installed patch declare? (we read
///      it from the YAML, not from the plugin's package.json, so a missing
///      plugin directory doesn't lie to us)
///   3. **Disabled?** — has someone added `- id: dsh-desktop-bridge\n  disabled: true`
///      on a later layer? (HOME-level patch is the typical culprit)
///   4. **Reachable?** — does the path in the patch actually exist on disk?
///
/// On first launch this is run synchronously inside `DshApp.init()` so we can
/// either silently continue (everything good) or show a one-time alert before
/// the window opens (something needs the user's attention). After that, the
/// user can re-trigger via the 控制 menu's "Check Plugin Status" item.
///
/// Per AGENTS.md, this MUST stay out of the dsh-spawning code path: the
/// detection runs against the user's `~/.dsh/profiles/<name>/` directly, not
/// against the running dsh process, so it works regardless of whether dsh is
/// up or down.
public enum DSHPluginDetector {

    // MARK: - Public types

    /// Current version of the bridge protocol the wrapper expects from the
    /// plugin. Bumped when we add/remove RPC methods.
    public static let expectedPluginVersion = "0.1.0"

    /// The id the patch row must use. Matches `name` in the plugin's
    /// package.json and the `id:` field in cordis.patch.yml.
    public static let pluginID = "dsh-desktop-bridge"

    /// Conventional install location the wrapper assumes. Update if you
    /// relocate the plugins repo.
    public static let defaultPluginPath = "/Users/coderstory/CodeSource/plugins/dsh-desktop-bridge/src/index.ts"

    /// npm `link:` value the wrapper writes into the profile's
    /// `package.json` `dependencies`. `link:` is preferred over `file:`
    /// because pnpm will symlink rather than copy — the plugin's `node_modules`
    /// (e.g. `@deepseek-ai/cordis`) stay in its real tree and don't get
    /// re-resolved against the profile's flat fallback. See:
    ///   https://pnpm.io/cli/install#--link-bare
    public static let defaultPackageLink = "link:" + defaultPluginPath

    /// Result of one detection pass. `state` is the actionable verdict;
    /// `details` carries context for logs / alerts.
    public struct Status: Equatable {
        public enum State: Equatable {
            case installedCurrent          // Patch row present, enabled, version matches, file exists.
            case installedOutdated(expected: String, found: String)
            case notInstalled              // No patch row referencing our id anywhere.
            case disabled                  // Patch row present but `disabled: true` on a later layer.
            case brokenPath(expected: String) // Patch row references a path that no longer exists.
        }

        public let state: State
        /// Free-form context the UI can show in alerts.
        public let details: String

        /// True if the wrapper can rely on the plugin for completion
        /// notifications right now. When false, the wrapper falls back to
        /// its own (DOM-probe) notification path.
        public var pluginOperational: Bool {
            if case .installedCurrent = state { return true }
            return false
        }
    }

    // MARK: - Public API

    /// Run detection against the user's current dsh profile. Safe to call
    /// from any thread; does no I/O on the main thread.
    public static func detect(
        dshHome: String,
        profile: String = "web"
    ) -> Status {
        let profileDir = URL(fileURLWithPath: dshHome)
            .appendingPathComponent("profiles")
            .appendingPathComponent(profile)

        let cordisYml = profileDir.appendingPathComponent("cordis.yml")
        let patchYml = profileDir.appendingPathComponent("cordis.patch.yml")

        // Read both files (they may not both exist; the .yml is the bundles
        // list and the .patch.yml is the user-editable overlay).
        let rootRows = readPatchRows(from: cordisYml)
        let patchRows = readPatchRows(from: patchYml)

        // Find the entry — could be in either file, or both (patch wins).
        guard let entry = findEntry(in: rootRows + patchRows, id: pluginID) else {
            Log.pluginDetector.notice("plugin not installed (no '\(self.pluginID)' row in \(cordisYml.lastPathComponent, privacy: .public) or \(patchYml.lastPathComponent, privacy: .public))")
            return Status(
                state: .notInstalled,
                details: "Expected patch row id: \(pluginID)\nProfile dir: \(profileDir.path)"
            )
        }

        // Disabled?
        if entry.disabled {
            Log.pluginDetector.error("plugin disabled by patch layer")
            return Status(
                state: .disabled,
                details: "Patch row has `disabled: true` in \(patchYml.lastPathComponent).\nThis usually happens when a HOME-level patch or another plugin-manager overrode our entry.\n\nRaw entry: \(entry.raw)"
            )
        }

        // Version check.
        let foundVersion = entry.version ?? "unknown"
        if foundVersion != expectedPluginVersion {
            Log.pluginDetector.notice("plugin version mismatch: found \(foundVersion, privacy: .public), expected \(self.expectedPluginVersion, privacy: .public)")
            return Status(
                state: .installedOutdated(expected: expectedPluginVersion, found: foundVersion),
                details: "Installed: \(foundVersion)\nWrapper expects: \(expectedPluginVersion)\n\nRun `cd \(URL(fileURLWithPath: defaultPluginPath).deletingLastPathComponent().deletingLastPathComponent().path) && git pull && npm run build` then restart DshDesktop."
            )
        }

        // Path reachable?
        let mainPath = entry.main ?? defaultPluginPath
        if !FileManager.default.fileExists(atPath: mainPath) {
            Log.pluginDetector.error("plugin main file missing at \(mainPath, privacy: .public)")
            return Status(
                state: .brokenPath(expected: mainPath),
                details: "Patch row says `main: \(mainPath)` but the file does not exist.\nRe-run the plugin install, or fix the path in \(patchYml.lastPathComponent)."
            )
        }

        Log.pluginDetector.notice("plugin OK (v\(foundVersion, privacy: .public))")
        return Status(
            state: .installedCurrent,
            details: "Installed at \(mainPath)"
        )
    }

    // MARK: - Patch-row parsing

    /// One row from a cordis patch file. We only model the fields we care
    /// about; the rest of the YAML is opaque to us.
    fileprivate struct PatchEntry: Equatable {
        let id: String
        let name: String?
        let version: String?
        let disabled: Bool
        let main: String?
        let raw: String  // original text, for error messages
    }

    /// Minimal YAML pull-parser for cordis patch files. We deliberately do NOT
    /// depend on a YAML library: the patch files are small, line-oriented, and
    /// we only need a handful of fields. If a future feature needs richer
    /// parsing, swap this for Yams and keep the public API the same.
    ///
    /// Recognised shapes:
    ///   - id: foo                     (disable row)
    ///     disabled: true
    ///   - id: foo
    ///     name: bar
    ///     version: 1.2.3
    ///     main: /abs/path/to/index.ts
    fileprivate static func readPatchRows(from url: URL) -> [PatchEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        var entries: [PatchEntry] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Top-level list entry: starts with `- id:` (allow leading spaces).
            guard trimmed.hasPrefix("- ") else { i += 1; continue }

            // Extract the inline fields on the `- id:` line.
            var id: String?
            var name: String?
            var version: String?
            var main: String?
            var disabled = false

            for inline in parseInlineFields(String(trimmed.dropFirst(2))) {
                switch inline.key {
                case "id":       id = inline.value
                case "name":     name = inline.value
                case "version":  version = inline.value
                case "main":     main = inline.value
                default: break
                }
            }

            // Collect indented continuation lines until we hit another top-level
            // entry or end of file. We only look for known scalar keys.
            var raw = line
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextTrim = next.trimmingCharacters(in: .whitespaces)
                if nextTrim.hasPrefix("- ") || nextTrim.isEmpty || nextTrim.hasPrefix("#") {
                    // Blank line / comment / next entry: stop scanning this row.
                    // (Comment is safe to break on; if the user did something
                    // exotic we'll just re-read the file next launch.)
                    break
                }
                raw += "\n" + next
                for inline in parseInlineFields(nextTrim) {
                    switch inline.key {
                    case "id":       if id == nil { id = inline.value }
                    case "name":     if name == nil { name = inline.value }
                    case "version":  if version == nil { version = inline.value }
                    case "main":     if main == nil { main = inline.value }
                    case "disabled":
                        disabled = (inline.value == "true")
                    default: break
                    }
                }
                i += 1
            }

            if let id {
                entries.append(PatchEntry(
                    id: id, name: name, version: version,
                    disabled: disabled, main: main, raw: raw
                ))
            }
        }
        return entries
    }

    /// Parse all `key: value` pairs on a single line. The value runs to the
    /// next `key:` token or end-of-line, minus trailing whitespace. We
    /// don't try to honour YAML quoting rules because cordis patch files
    /// in practice either use bareword values (paths, identifiers,
    /// booleans) or single-quoted strings without internal colons — both
    /// are safe with this scanner.
    fileprivate static func parseInlineFields(_ line: String) -> [(key: String, value: String)] {
        // Tokenise on `key:` boundaries, where `key` is
        // `[A-Za-z_][A-Za-z0-9_-]*` and must be preceded by start-of-string
        // or whitespace. For each token, the value is everything between
        // the colon and the start of the next token (or end-of-line),
        // trimmed of surrounding whitespace.
        var tokens: [(key: String, valueStart: String.Index)] = []
        var idx = line.startIndex
        while idx < line.endIndex {
            // Skip whitespace.
            while idx < line.endIndex, line[idx].isWhitespace { idx = line.index(after: idx) }
            guard idx < line.endIndex else { break }
            // Read the key.
            let keyStart = idx
            while idx < line.endIndex,
                  line[idx].isLetter || line[idx].isNumber || line[idx] == "_" || line[idx] == "-" {
                idx = line.index(after: idx)
            }
            guard idx > keyStart, idx < line.endIndex, line[idx] == ":" else {
                // Not a `key:` boundary; advance one char and keep scanning.
                if idx < line.endIndex {
                    idx = line.index(after: idx)
                }
                continue
            }
            let key = String(line[keyStart..<idx])
            // Consume the colon.
            idx = line.index(after: idx)
            // valueStart points just past the colon — leading whitespace
            // between `:` and the value will be trimmed by the consumer.
            tokens.append((key, idx))
        }

        var out: [(String, String)] = []
        for (i, token) in tokens.enumerated() {
            let valueStart = token.valueStart
            // The value extends from `valueStart` up to the start of the
            // next `key:` token's identifier. To find that boundary we
            // start at the next token's valueStart and walk backwards:
            //   - skip the colon of the next token
            //   - walk back identifier chars (the next key)
            //   - walk back whitespace (the gap)
            // What remains is the trailing edge of THIS token's value.
            let valueEnd: String.Index
            if i + 1 < tokens.count {
                var j = tokens[i + 1].valueStart
                // Skip the colon.
                if j > valueStart, line[line.index(before: j)] == ":" {
                    j = line.index(before: j)
                }
                // Walk back identifier chars of the next key.
                while j > valueStart,
                      j > line.startIndex,
                      let prev = line.index(j, offsetBy: -1, limitedBy: line.startIndex),
                      line[prev].isLetter || line[prev].isNumber
                      || line[prev] == "_" || line[prev] == "-" {
                    j = prev
                }
                // Walk back any whitespace of this token's value.
                while j > valueStart, line[line.index(before: j)].isWhitespace {
                    j = line.index(before: j)
                }
                valueEnd = j
            } else {
                valueEnd = line.endIndex
            }
            let raw = String(line[valueStart..<valueEnd])
                .trimmingCharacters(in: .whitespaces)
            if !token.key.isEmpty {
                out.append((token.key, raw))
            }
        }
        return out
    }

    fileprivate static func findEntry(in entries: [PatchEntry], id: String) -> PatchEntry? {
        // Later entries win (HOME-level patch overrides profile-level), same
        // as cordis's own layer ordering.
        var found: PatchEntry?
        for e in entries where e.id == id {
            found = e
        }
        return found
    }

    // MARK: - Mutations (install / re-enable)

    /// Append the wrapper-managed patch row to a `cordis.patch.yml`. Returns
    /// `true` if the file was written, `false` if the file already has our
    /// row (idempotent). Throws on I/O error.
    ///
    /// `path` is parameterised so tests can target a scratch file instead of
    /// the user's real `~/.dsh/profiles/web/cordis.patch.yml`.
    public static func installPatchEntry(at path: String) throws -> Bool {
        let snippet = """
            # 2026-08-17: DshDesktop-managed dsh-desktop-bridge entry.
            # Removing this row will silence agent completion notifications.
            - insert:
                - id: \(pluginID)
                  name: \(pluginID)
                  main: \(defaultPluginPath)
                  version: \(expectedPluginVersion)

            """
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if existing.contains("- id: \(pluginID)") {
            Log.pluginDetector.notice("patch entry already present in \(path, privacy: .public) — leaving as-is")
            return false
        }
        try (existing + "\n" + snippet).write(toFile: path, atomically: true, encoding: .utf8)
        Log.pluginDetector.notice("patch entry appended to \(path, privacy: .public)")
        return true
    }

    /// Add the plugin to the profile's `package.json` `dependencies` as a
    /// `link:` entry, so pnpm symlinks the plugin into the profile's
    /// `node_modules` on the next `pnpm install`. Returns `true` if the
    /// dependency was added, `false` if it was already present.
    ///
    /// **Why both this and `installPatchEntry`?** cordis.patch.yml's
    /// `- insert` row only tells dsh to *instantiate* a plugin by id
    /// — dsh still needs the plugin to be Node-resolvable, which means
    /// it must exist in the profile's `node_modules/dsh-desktop-bridge/`.
    /// pnpm only puts it there if `dependencies` lists it. The two
    /// writes are idempotent and can be retried independently.
    public static func installPackageDependency(at profileDir: String) throws -> Bool {
        let pkgPath = profileDir + "/package.json"
        let url = URL(fileURLWithPath: pkgPath)
        let data = try Data(contentsOf: url)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "DSHPluginDetector", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "package.json is not an object"])
        }
        var deps = json["dependencies"] as? [String: Any] ?? [:]
        if let existing = deps[pluginID] as? String, existing == defaultPackageLink {
            Log.pluginDetector.notice("dependency \(self.pluginID, privacy: .public) already in package.json — leaving as-is")
            return false
        }
        if deps[pluginID] != nil {
            // Present but with a different value (e.g. a different path).
            // Don't clobber a user-customised value; surface a warning.
            Log.pluginDetector.notice("dependency \(self.pluginID, privacy: .public) in package.json has unexpected value '\(deps[pluginID] as? String ?? "<non-string>", privacy: .public)' — leaving as-is; the wrapper cannot resolve it correctly. Edit \(pkgPath, privacy: .public) manually.")
            return false
        }
        deps[pluginID] = defaultPackageLink
        json["dependencies"] = deps
        // Use .sortedKeys for diffability (the user will eventually diff
        // this file via git or similar).
        let newData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys, .prettyPrinted]
        )
        try newData.write(to: url, options: .atomic)
        Log.pluginDetector.notice("dependency \(self.pluginID, privacy: .public) added to \(pkgPath, privacy: .public) (link: symlink — pnpm install will materialise node_modules on next dsh launch)")
        return true
    }

    /// Flip `disabled: true` → `disabled: false` inside any `- id: <pluginID>`
    /// block. Returns `true` if a flag was changed, `false` if no such row
    /// existed. Throws on I/O error.
    public static func reenablePatchEntry(at path: String) throws -> Bool {
        let original = try String(contentsOfFile: path, encoding: .utf8)
        let lines = original.components(separatedBy: "\n")
        var inOurBlock = false
        var changed = false
        let updated = lines.map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- id:") {
                inOurBlock = trimmed.contains(pluginID)
                return line
            }
            if inOurBlock, trimmed.hasPrefix("disabled:") {
                changed = true
                return line.replacingOccurrences(of: "true", with: "false")
            }
            return line
        }.joined(separator: "\n")
        if changed {
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            Log.pluginDetector.notice("re-enabled patch entry in \(path, privacy: .public)")
        } else {
            Log.pluginDetector.error("no `disabled: true` row found in our block at \(path, privacy: .public)")
        }
        return changed
    }
}