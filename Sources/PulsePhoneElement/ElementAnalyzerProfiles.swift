import PulsePhoneMedia

public enum ElementAnalyzerProfiles {
    public static let omniparser: SnapshotDerivedImageProfile = try! .init(
        profileID: "omniparser-v3-longest-edge-1280.v1",
        resize: .longestEdge(1_280),
        colorSpace: .sRGB,
        encoding: .png
    )

    public static let visionProfileID = "vision-accurate-original-zh-hans-en-us.v1"

    public static let appleRegion: SnapshotDerivedImageProfile = try! .init(
        profileID: "apple-region-longest-edge-1536.v1",
        resize: .longestEdge(1_536),
        colorSpace: .sRGB,
        encoding: .png
    )
}
