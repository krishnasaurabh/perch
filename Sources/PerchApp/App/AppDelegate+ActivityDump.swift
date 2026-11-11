#if DEBUG || PERCH_TESTING
    import Foundation

    extension AppDelegate {
        /// `--dump-activity <path>`: one JSON line per timeline pass (what shows, what the notch shows, next wake).
        func setupActivityDump() {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--dump-activity"), i + 1 < args.count else { return }
            let url = URL(fileURLWithPath: args[i + 1])
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            services.timeline.onPass = { [weak self] showing, wake in
                let row: [String: Any] = [
                    "at": iso.string(from: Date()), "showing": showing ?? NSNull(),
                    "notch": self?.model.activity?.title ?? NSNull(),
                    "nextWake": wake.map(iso.string(from:)) ?? NSNull(),
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                    let h = try? FileHandle(forWritingTo: url)
                else { return }
                h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try? h.close()
            }
            services.timeline.refresh()
        }
    }
#endif
